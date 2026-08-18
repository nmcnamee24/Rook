import AppKit
@preconcurrency import CoreLocation
import Foundation
import RookKit

enum RookWeatherError: LocalizedError {
  case locationPermissionRequired
  case locationUnavailable
  case locationNotFound(String)
  case invalidResponse
  case serviceUnavailable

  var errorDescription: String? {
    switch self {
    case .locationPermissionRequired:
      return
        "Location access is off. Enable it in System Settings, or say a city such as ‘weather in Oakland, New Jersey.’"
    case .locationUnavailable:
      return "I couldn’t get this Mac’s location quickly enough. Say the city once and I’ll cache it."
    case .locationNotFound(let name):
      return "I couldn’t find “\(name).” Try adding the state or country."
    case .invalidResponse:
      return "The forecast service returned incomplete data."
    case .serviceUnavailable:
      return "The live forecast service didn’t answer within Rook’s fast-weather limit."
    }
  }
}

private struct WeatherAPICurrent: Codable {
  let time: String
  let temperature2m: Double
  let apparentTemperature: Double
  let isDay: Int
  let precipitation: Double
  let rain: Double
  let weatherCode: Int
  let windSpeed10m: Double

  enum CodingKeys: String, CodingKey {
    case time
    case temperature2m = "temperature_2m"
    case apparentTemperature = "apparent_temperature"
    case isDay = "is_day"
    case precipitation
    case rain
    case weatherCode = "weather_code"
    case windSpeed10m = "wind_speed_10m"
  }
}

private struct WeatherAPIDaily: Codable {
  let time: [String]
  let weatherCode: [Int]
  let temperature2mMax: [Double]
  let temperature2mMin: [Double]
  let precipitationProbabilityMax: [Double?]

  enum CodingKeys: String, CodingKey {
    case time
    case weatherCode = "weather_code"
    case temperature2mMax = "temperature_2m_max"
    case temperature2mMin = "temperature_2m_min"
    case precipitationProbabilityMax = "precipitation_probability_max"
  }
}

private struct WeatherAPIForecast: Codable {
  let latitude: Double
  let longitude: Double
  let timezone: String
  let current: WeatherAPICurrent
  let daily: WeatherAPIDaily
}

private struct WeatherGeocodingResponse: Decodable {
  let results: [WeatherGeocodingResult]?
}

private struct WeatherGeocodingResult: Decodable {
  let name: String
  let latitude: Double
  let longitude: Double
  let country: String?
  let admin1: String?
}

private struct RookWeatherCacheEntry: Codable {
  let key: String
  let label: String
  let latitude: Double
  let longitude: Double
  let fetchedAt: Date
  let forecast: WeatherAPIForecast
}

private struct RookWeatherCacheDocument: Codable {
  var version = 1
  var entries: [RookWeatherCacheEntry]
}

@MainActor
final class RookWeatherService: NSObject, @preconcurrency CLLocationManagerDelegate {
  typealias Completion = (Result<RookResponse, Error>) -> Void

  private struct DeviceWaiter {
    let id: UUID
    let request: RookWeatherRequest
    let startedAt: Date
    let completion: Completion
  }

  private let config: RookConfig
  private let locationManager = CLLocationManager()
  private let session: URLSession
  private var cache: [String: RookWeatherCacheEntry] = [:]
  private var deviceWaiters: [DeviceWaiter] = []
  private var refreshTimer: Timer?
  private var started = false
  private var isDeviceRefreshInFlight = false

  private let freshInterval: TimeInterval = 10 * 60
  private let staleFallbackInterval: TimeInterval = 2 * 60 * 60
  private let requestLimit: TimeInterval = 2.0
  private let locationLimit: TimeInterval = 3.6

  init(config: RookConfig) {
    self.config = config
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.timeoutIntervalForRequest = 2.5
    sessionConfig.timeoutIntervalForResource = 3.0
    sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
    session = URLSession(configuration: sessionConfig)
    super.init()

    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    locationManager.distanceFilter = 2_000
    loadCache()
  }

  func start() {
    if started {
      refreshDeviceWeather()
      return
    }
    started = true
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 8 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshDeviceWeather() }
    }
    refreshDeviceWeather()
  }

  func stop() {
    refreshTimer?.invalidate()
    refreshTimer = nil
    session.invalidateAndCancel()
  }

  func fetch(_ request: RookWeatherRequest, completion: @escaping Completion) {
    let startedAt = Date()
    if let fresh = freshEntry(for: request.cacheKey) {
      completion(.success(response(from: fresh, request: request, startedAt: startedAt)))
      return
    }

    if let locationQuery = request.locationQuery {
      fetchNamedLocation(locationQuery, request: request, startedAt: startedAt, completion: completion)
    } else {
      fetchDeviceLocation(request, startedAt: startedAt, completion: completion)
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    switch manager.authorizationStatus {
    case .authorized, .authorizedAlways, .authorizedWhenInUse:
      manager.requestLocation()
    case .denied, .restricted:
      failDeviceWaiters(with: RookWeatherError.locationPermissionRequired)
    case .notDetermined:
      break
    @unknown default:
      failDeviceWaiters(with: RookWeatherError.locationUnavailable)
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard
      let location =
        locations
        .filter({ $0.horizontalAccuracy >= 0 })
        .min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy })
    else {
      failDeviceWaiters(with: RookWeatherError.locationUnavailable)
      return
    }
    fetchDeviceForecast(at: location.coordinate)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    if let coreError = error as? CLError, coreError.code == .locationUnknown { return }
    isDeviceRefreshInFlight = false
    failDeviceWaiters(with: RookWeatherError.locationUnavailable)
  }

  private func refreshDeviceWeather() {
    if let entry = cache["device"], Date().timeIntervalSince(entry.fetchedAt) < freshInterval { return }
    switch locationManager.authorizationStatus {
    case .notDetermined:
      NSApp.activate(ignoringOtherApps: true)
      locationManager.requestWhenInUseAuthorization()
    case .authorized, .authorizedAlways, .authorizedWhenInUse:
      if let location = locationManager.location, location.horizontalAccuracy >= 0 {
        fetchDeviceForecast(at: location.coordinate)
      } else {
        locationManager.requestLocation()
      }
    case .denied, .restricted:
      break
    @unknown default:
      break
    }
  }

  private func fetchDeviceLocation(
    _ request: RookWeatherRequest,
    startedAt: Date,
    completion: @escaping Completion
  ) {
    if let entry = cache["device"] {
      fetchForecast(
        key: "device",
        label: entry.label,
        latitude: entry.latitude,
        longitude: entry.longitude,
        request: request,
        startedAt: startedAt,
        fallback: entry,
        completion: completion
      )
      return
    }

    switch locationManager.authorizationStatus {
    case .denied, .restricted:
      completion(.failure(RookWeatherError.locationPermissionRequired))
    case .authorized, .authorizedAlways, .authorizedWhenInUse:
      if let location = locationManager.location, location.horizontalAccuracy >= 0 {
        fetchForecast(
          key: "device",
          label: "Current location",
          latitude: location.coordinate.latitude,
          longitude: location.coordinate.longitude,
          request: request,
          startedAt: startedAt,
          fallback: nil,
          completion: completion
        )
      } else {
        waitForDeviceLocation(request, startedAt: startedAt, completion: completion)
        locationManager.requestLocation()
      }
    case .notDetermined:
      waitForDeviceLocation(request, startedAt: startedAt, completion: completion)
      NSApp.activate(ignoringOtherApps: true)
      locationManager.requestWhenInUseAuthorization()
    @unknown default:
      completion(.failure(RookWeatherError.locationUnavailable))
    }
  }

  private func waitForDeviceLocation(
    _ request: RookWeatherRequest,
    startedAt: Date,
    completion: @escaping Completion
  ) {
    let id = UUID()
    deviceWaiters.append(DeviceWaiter(id: id, request: request, startedAt: startedAt, completion: completion))
    DispatchQueue.main.asyncAfter(deadline: .now() + locationLimit) { [weak self] in
      guard let self,
        let index = self.deviceWaiters.firstIndex(where: { $0.id == id })
      else { return }
      let waiter = self.deviceWaiters.remove(at: index)
      waiter.completion(.failure(RookWeatherError.locationUnavailable))
    }
  }

  private func fetchDeviceForecast(at coordinate: CLLocationCoordinate2D) {
    guard !isDeviceRefreshInFlight else { return }
    isDeviceRefreshInFlight = true
    let waiters = deviceWaiters
    let fallback = cache["device"]
    fetchForecastData(latitude: coordinate.latitude, longitude: coordinate.longitude) { [weak self] result in
      guard let self else { return }
      self.isDeviceRefreshInFlight = false
      switch result {
      case .success(let forecast):
        let entry = RookWeatherCacheEntry(
          key: "device",
          label: fallback?.label ?? "Current location",
          latitude: coordinate.latitude,
          longitude: coordinate.longitude,
          fetchedAt: Date(),
          forecast: forecast
        )
        self.store(entry)
        self.deviceWaiters.removeAll { waiter in
          guard waiters.contains(where: { $0.id == waiter.id }) else { return false }
          waiter.completion(.success(self.response(from: entry, request: waiter.request, startedAt: waiter.startedAt)))
          return true
        }
      case .failure:
        self.deviceWaiters.removeAll { waiter in
          guard waiters.contains(where: { $0.id == waiter.id }) else { return false }
          if let fallback, Date().timeIntervalSince(fallback.fetchedAt) <= self.staleFallbackInterval {
            waiter.completion(
              .success(self.response(from: fallback, request: waiter.request, startedAt: waiter.startedAt)))
          } else {
            waiter.completion(.failure(RookWeatherError.serviceUnavailable))
          }
          return true
        }
      }
    }
  }

  private func fetchNamedLocation(
    _ locationQuery: String,
    request: RookWeatherRequest,
    startedAt: Date,
    completion: @escaping Completion
  ) {
    if let cached = cache[request.cacheKey] {
      fetchForecast(
        key: request.cacheKey,
        label: cached.label,
        latitude: cached.latitude,
        longitude: cached.longitude,
        request: request,
        startedAt: startedAt,
        fallback: cached,
        completion: completion
      )
      return
    }

    guard var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search") else {
      completion(.failure(RookWeatherError.locationNotFound(locationQuery)))
      return
    }
    components.queryItems = [
      URLQueryItem(name: "name", value: locationQuery),
      URLQueryItem(name: "count", value: "1"),
      URLQueryItem(name: "language", value: "en"),
      URLQueryItem(name: "format", value: "json"),
    ]
    guard let url = components.url else {
      completion(.failure(RookWeatherError.locationNotFound(locationQuery)))
      return
    }

    fetchJSON(WeatherGeocodingResponse.self, from: url) { [weak self] result in
      guard let self else { return }
      guard case .success(let response) = result, let place = response.results?.first else {
        completion(.failure(RookWeatherError.locationNotFound(locationQuery)))
        return
      }
      let label = self.locationLabel(place)
      self.fetchForecast(
        key: request.cacheKey,
        label: label,
        latitude: place.latitude,
        longitude: place.longitude,
        request: request,
        startedAt: startedAt,
        fallback: nil,
        completion: completion
      )
    }
  }

  private func fetchForecast(
    key: String,
    label: String,
    latitude: Double,
    longitude: Double,
    request: RookWeatherRequest,
    startedAt: Date,
    fallback: RookWeatherCacheEntry?,
    completion: @escaping Completion
  ) {
    fetchForecastData(latitude: latitude, longitude: longitude) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let forecast):
        let entry = RookWeatherCacheEntry(
          key: key,
          label: label,
          latitude: latitude,
          longitude: longitude,
          fetchedAt: Date(),
          forecast: forecast
        )
        self.store(entry)
        completion(.success(self.response(from: entry, request: request, startedAt: startedAt)))
      case .failure:
        if let fallback, Date().timeIntervalSince(fallback.fetchedAt) <= self.staleFallbackInterval {
          completion(.success(self.response(from: fallback, request: request, startedAt: startedAt)))
        } else {
          completion(.failure(RookWeatherError.serviceUnavailable))
        }
      }
    }
  }

  private func fetchForecastData(
    latitude: Double,
    longitude: Double,
    completion: @escaping (Result<WeatherAPIForecast, Error>) -> Void
  ) {
    guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
      completion(.failure(RookWeatherError.serviceUnavailable))
      return
    }
    components.queryItems = [
      URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
      URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
      URLQueryItem(
        name: "current",
        value: "temperature_2m,apparent_temperature,is_day,precipitation,rain,weather_code,wind_speed_10m"),
      URLQueryItem(
        name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
      URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
      URLQueryItem(name: "wind_speed_unit", value: "mph"),
      URLQueryItem(name: "precipitation_unit", value: "inch"),
      URLQueryItem(name: "timezone", value: "auto"),
      URLQueryItem(name: "forecast_days", value: "7"),
    ]
    guard let url = components.url else {
      completion(.failure(RookWeatherError.serviceUnavailable))
      return
    }
    fetchJSON(WeatherAPIForecast.self, from: url, completion: completion)
  }

  private func fetchJSON<Value: Decodable>(
    _ type: Value.Type,
    from url: URL,
    completion: @escaping (Result<Value, Error>) -> Void
  ) {
    var request = URLRequest(url: url)
    request.timeoutInterval = requestLimit
    request.setValue("Rook/2.27 personal weather assistant", forHTTPHeaderField: "User-Agent")
    session.dataTask(with: request) { data, response, error in
      let result: Result<Value, Error>
      if let error {
        result = .failure(error)
      } else if let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode),
        let data,
        let decoded = try? JSONDecoder().decode(Value.self, from: data)
      {
        result = .success(decoded)
      } else {
        result = .failure(RookWeatherError.invalidResponse)
      }
      DispatchQueue.main.async { completion(result) }
    }.resume()
  }

  private func response(
    from entry: RookWeatherCacheEntry,
    request: RookWeatherRequest,
    startedAt: Date
  ) -> RookResponse {
    let forecast = entry.forecast
    let daily = forecast.daily
    let available = min(
      daily.time.count,
      daily.weatherCode.count,
      daily.temperature2mMax.count,
      daily.temperature2mMin.count,
      daily.precipitationProbabilityMax.count
    )
    let lower = min(request.dayOffset, max(0, available - 1))
    let upper = min(available, lower + request.dayCount)
    let indices = lower < upper ? Array(lower..<upper) : []
    let isCurrent = request.dayOffset == 0 && request.dayCount == 1
    let items: [RookCanvasItem] = indices.map { index in
      let condition = Self.condition(for: daily.weatherCode[index])
      let rainChance = Int((daily.precipitationProbabilityMax[index] ?? 0).rounded())
      let high = Int(daily.temperature2mMax[index].rounded())
      let low = Int(daily.temperature2mMin[index].rounded())
      if isCurrent {
        let current = Int(forecast.current.temperature2m.rounded())
        let feels = Int(forecast.current.apparentTemperature.rounded())
        return RookCanvasItem(
          id: "weather_today",
          label: "Today",
          detail: "\(condition.name) · Feels \(feels)° · H \(high)° / L \(low)° · \(rainChance)% chance",
          value: "\(current)°",
          symbol: condition.symbol
        )
      }
      return RookCanvasItem(
        id: "weather_day_\(index + 1)",
        label: self.dayLabel(daily.time[index], index: index),
        detail: "\(condition.name) · \(rainChance)% chance",
        value: "\(high)° / \(low)°",
        symbol: condition.symbol
      )
    }

    let displayText: String
    let spokenText: String
    if isCurrent, let index = indices.first {
      let current = Int(forecast.current.temperature2m.rounded())
      let feels = Int(forecast.current.apparentTemperature.rounded())
      let high = Int(daily.temperature2mMax[index].rounded())
      let low = Int(daily.temperature2mMin[index].rounded())
      let rainChance = Int((daily.precipitationProbabilityMax[index] ?? 0).rounded())
      let condition = Self.condition(for: forecast.current.weatherCode).name.lowercased()
      let spokenLocation = entry.key == "device" ? "where you are" : "in \(entry.label)"
      displayText =
        "**\(entry.label):** \(current)°F and \(condition). Feels like \(feels)°. Today’s high is \(high)°, low \(low)°, with a \(rainChance)% chance of rain."
      spokenText =
        "It’s \(current) degrees and \(condition) \(spokenLocation). Today’s high is \(high), with a \(rainChance) percent chance of rain."
    } else if let first = indices.first {
      let condition = Self.condition(for: daily.weatherCode[first]).name.lowercased()
      let high = Int(daily.temperature2mMax[first].rounded())
      let rainChance = Int((daily.precipitationProbabilityMax[first] ?? 0).rounded())
      displayText =
        "**\(entry.label):** your \(request.dayCount == 1 ? "forecast" : "\(request.dayCount)-day forecast") is ready."
      spokenText =
        "The forecast for \(entry.label) is ready. The first day is \(condition), with a high of \(high) and a \(rainChance) percent chance of rain."
    } else {
      displayText = "The forecast for **\(entry.label)** is temporarily incomplete."
      spokenText = "The forecast came back incomplete."
    }

    let elapsed = Date().timeIntervalSince(startedAt)
    let freshness =
      Date().timeIntervalSince(entry.fetchedAt) <= freshInterval ? "Live forecast" : "Recent cached forecast"
    return RookResponse(
      displayText: displayText,
      spokenText: spokenText,
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "instant_weather",
          kind: .weather,
          title: entry.label,
          subtitle: "\(freshness) · Ready in \(Self.duration(elapsed))",
          asOf: ISO8601DateFormatter().string(from: entry.fetchedAt),
          items: items,
          sourceLabel: "Open-Meteo",
          sourceURL: "https://open-meteo.com/"
        )
      ]
    )
  }

  private func dayLabel(_ value: String, index: Int) -> String {
    if index == 0 { return "Today" }
    if index == 1 { return "Tomorrow" }
    let input = DateFormatter()
    input.locale = Locale(identifier: "en_US_POSIX")
    input.dateFormat = "yyyy-MM-dd"
    let output = DateFormatter()
    output.locale = Locale(identifier: "en_US_POSIX")
    output.dateFormat = "EEE, MMM d"
    return input.date(from: value).map(output.string) ?? value
  }

  private func locationLabel(_ place: WeatherGeocodingResult) -> String {
    var components = [place.name]
    if let admin = place.admin1, admin.caseInsensitiveCompare(place.name) != .orderedSame {
      components.append(admin)
    } else if let country = place.country, country.caseInsensitiveCompare(place.name) != .orderedSame {
      components.append(country)
    }
    return components.joined(separator: ", ")
  }

  private func freshEntry(for key: String) -> RookWeatherCacheEntry? {
    guard let entry = cache[key], Date().timeIntervalSince(entry.fetchedAt) <= freshInterval else { return nil }
    return entry
  }

  private func store(_ entry: RookWeatherCacheEntry) {
    cache[entry.key] = entry
    let recent = cache.values
      .sorted { $0.fetchedAt > $1.fetchedAt }
      .prefix(12)
    cache = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0) })
    let document = RookWeatherCacheDocument(entries: Array(cache.values))
    if let data = try? JSONEncoder().encode(document) {
      try? RookConfig.writePrivate(data, to: config.weatherCacheURL)
    }
  }

  private func loadCache() {
    guard let data = try? Data(contentsOf: config.weatherCacheURL),
      let document = try? JSONDecoder().decode(RookWeatherCacheDocument.self, from: data)
    else { return }
    cache = Dictionary(uniqueKeysWithValues: document.entries.map { ($0.key, $0) })
  }

  private func failDeviceWaiters(with error: Error) {
    let waiters = deviceWaiters
    deviceWaiters.removeAll()
    for waiter in waiters { waiter.completion(.failure(error)) }
  }

  private static func condition(for code: Int) -> (name: String, symbol: RookCanvasSymbol) {
    switch code {
    case 0: return ("Clear", .sun)
    case 1: return ("Mostly clear", .sun)
    case 2: return ("Partly cloudy", .partlyCloudy)
    case 3: return ("Overcast", .cloudy)
    case 45, 48: return ("Foggy", .fog)
    case 51...67, 80...82: return ("Rain", .rain)
    case 71...77, 85, 86: return ("Snow", .snow)
    case 95...99: return ("Thunderstorms", .storm)
    default: return ("Mixed conditions", .cloudy)
    }
  }

  private static func duration(_ seconds: TimeInterval) -> String {
    if seconds < 0.1 { return "<0.1s" }
    return String(format: "%.1fs", seconds)
  }
}
