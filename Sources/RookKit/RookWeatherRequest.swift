import Foundation

public struct RookWeatherRequest: Equatable, Sendable {
  public let locationQuery: String?
  public let dayOffset: Int
  public let dayCount: Int

  public init(locationQuery: String?, dayOffset: Int, dayCount: Int) {
    self.locationQuery = locationQuery
    self.dayOffset = dayOffset
    self.dayCount = dayCount
  }

  public var cacheKey: String {
    guard let locationQuery else { return "device" }
    return
      locationQuery
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }
}

/// Matches only straightforward forecast lookups. Weather-dependent decisions,
/// safety questions, alerts, radar, and contextual follow-ups keep using deep Rook.
public enum RookWeatherCommandParser {
  public static func parse(_ rawCommand: String) -> RookWeatherRequest? {
    let command =
      rawCommand
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
    let lower = command.lowercased()
    guard containsWeatherWord(lower) else { return nil }
    guard isDirectForecastLookup(lower) else { return nil }

    let analyticalTerms = [
      "should i", "should we", "safe to", "even with", "because of", "hike", "beach",
      "alert", "warning", "radar", "air quality", "compare", "best day", "what about",
      "do i need", "recommend", "driving", "flight", "cancel", "reschedule",
      "weekend", "this week", "next week", "hourly", "tonight", "later today", "this afternoon", "this evening",
    ]
    guard !analyticalTerms.contains(where: lower.contains) else { return nil }

    let dayOffset = lower.contains("tomorrow") && !lower.contains("today") ? 1 : 0
    let dayCount = requestedDayCount(in: lower, dayOffset: dayOffset)
    guard (1...7).contains(dayCount) else { return nil }

    let location = explicitLocation(in: command)
    return RookWeatherRequest(locationQuery: location, dayOffset: dayOffset, dayCount: dayCount)
  }

  private static func containsWeatherWord(_ value: String) -> Bool {
    let words = Set(value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    return !words.isDisjoint(with: ["weather", "forecast", "temperature", "temp"])
  }

  /// The native path is deliberately a small command grammar, not a keyword
  /// trigger. A longer request may mention a weather Canvas as an example and
  /// must still reach central Rook.
  private static func isDirectForecastLookup(_ value: String) -> Bool {
    guard value.split(whereSeparator: \.isWhitespace).count <= 24 else { return false }
    let patterns = [
      #"^(?:(?:can|could|would)\s+you\s+)?(?:(?:please\s+)?(?:show|give|tell)\s+me\s+)?(?:(?:what(?:'s|\s+is)|how(?:'s|\s+is))\s+)?(?:the\s+)?(?:weather|forecast|temperature|temp)\b"#,
      #"^(?:show|give)\s+me\s+(?:the\s+)?(?:next\s+)?(?:[1-7]|one|two|three|four|five|six|seven)[-\s]?day\s+(?:weather|forecast)\b"#,
    ]
    return patterns.contains { pattern in
      value.range(of: pattern, options: .regularExpression) != nil
    }
  }

  private static func requestedDayCount(in value: String, dayOffset: Int) -> Int {
    if dayOffset == 1 { return 1 }
    let words: [String: Int] = [
      "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    ]
    if let capture = firstCapture(
      in: value,
      pattern: #"\b(?:next\s+)?([1-7]|one|two|three|four|five|six|seven)[-\s]?day(?:s)?\b"#
    ) {
      return Int(capture) ?? words[capture.lowercased()] ?? 1
    }
    return 1
  }

  private static func explicitLocation(in value: String) -> String? {
    let patterns = [
      #"(?i)\b(?:weather|forecast|temperature|temp)\s+(?:like\s+)?in\s+(.+?)(?=\s+(?:over|for)\s+(?:the\s+)?(?:next\s+)?(?:[1-7]|one|two|three|four|five|six|seven|today|tomorrow)|\s+today\b|\s+tomorrow\b|$)"#,
      #"(?i)\b(?:weather|forecast|temperature|temp)\s+(?:today|tomorrow)\s+in\s+(.+)$"#,
      #"(?i)\b(?:weather|forecast|temperature|temp)\s+for\s+(?!the\s+next\b|next\b|today\b|tomorrow\b)(.+)$"#,
    ]
    guard let capture = patterns.lazy.compactMap({ firstCapture(in: value, pattern: $0) }).first else { return nil }
    let cleaned =
      capture
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    guard !cleaned.isEmpty else { return nil }
    let parts =
      cleaned
      .split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if parts.count == 3, parts[0].caseInsensitiveCompare(parts[2]) == .orderedSame {
      return "\(parts[1]), \(parts[2])"
    }
    return String(cleaned.prefix(120))
  }

  private static func firstCapture(in value: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range])
  }
}

public enum RookWeatherSemanticResolution: Equatable, Sendable {
  case request(RookWeatherRequest)
  case requiresDeliberation
  case notWeather
}

/// Gives ordinary forecast language one bounded native attempt after the exact
/// grammar misses. Questions that require alerts, safety judgment, comparison,
/// or unsupported weather data still fall through to central Rook intact.
public enum RookWeatherSemanticResolver {
  public static func resolve(_ rawCommand: String) -> RookWeatherSemanticResolution {
    if let exact = RookWeatherCommandParser.parse(rawCommand) { return .request(exact) }

    let command = cleaned(rawCommand)
    let lower = command.lowercased()
    guard claimsWeatherDomain(lower) else { return .notWeather }
    if containsAny(lower, ["search for", "google", "using chrome", "using safari", "in chrome", "in safari"]) {
      return .notWeather
    }
    guard isForecastLookup(lower) else { return .requiresDeliberation }

    let deliberateTerms = [
      "alert", "warning", "radar", "air quality", "safe to", "even with", "compare",
      "best day", "recommend", "driving", "flight", "cancel", "reschedule", "hike",
      "beach", "hourly", "weekend", "this week", "next week", "humidity", "wind speed",
    ]
    let compoundTerms = [" and ", " and then ", ";", " also ", " plus "]
    guard !deliberateTerms.contains(where: lower.contains),
      !compoundTerms.contains(where: lower.contains),
      lower.split(whereSeparator: \.isWhitespace).count <= 24
    else {
      return .requiresDeliberation
    }

    let dayOffset = lower.contains("tomorrow") && !lower.contains("today") ? 1 : 0
    let dayCount = requestedDayCount(in: lower, dayOffset: dayOffset)
    guard (1...7).contains(dayCount) else { return .requiresDeliberation }
    return .request(
      RookWeatherRequest(
        locationQuery: location(in: command),
        dayOffset: dayOffset,
        dayCount: dayCount
      )
    )
  }

  private static func claimsWeatherDomain(_ value: String) -> Bool {
    let words = Set(value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    if !words.isDisjoint(with: [
      "weather", "forecast", "temperature", "temp", "rain", "raining", "rainy", "snow", "snowing", "umbrella",
    ]) {
      return true
    }
    let casualTemperaturePhrases = [
      "how hot is it", "how cold is it", "how warm is it", "is it hot outside",
      "is it cold outside", "is it warm outside",
    ]
    return casualTemperaturePhrases.contains(where: value.contains)
  }

  private static func isForecastLookup(_ value: String) -> Bool {
    let phrases = [
      "check the weather", "check weather", "get the weather", "get weather",
      "check the forecast", "check forecast", "get the forecast", "get forecast",
      "check the next", "get the next",
      "will it rain", "will it snow", "going to rain", "going to snow",
      "need an umbrella", "need umbrella", "how hot is it", "how cold is it",
      "how warm is it", "is it hot outside", "is it cold outside", "is it warm outside",
    ]
    return phrases.contains(where: value.contains)
  }

  private static func containsAny(_ value: String, _ phrases: [String]) -> Bool {
    phrases.contains(where: value.contains)
  }

  private static func requestedDayCount(in value: String, dayOffset: Int) -> Int {
    if dayOffset == 1 { return 1 }
    let words: [String: Int] = [
      "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    ]
    guard
      let capture = firstCapture(
        in: value,
        pattern: #"\b(?:next\s+)?([1-7]|one|two|three|four|five|six|seven)[-\s]?day(?:s)?\b"#
      )
    else { return 1 }
    return Int(capture) ?? words[capture.lowercased()] ?? 1
  }

  private static func location(in value: String) -> String? {
    let patterns = [
      #"(?i)\b(?:today|tomorrow)\s+in\s+(.+)$"#,
      #"(?i)\bin\s+(.+?)\s+(?:today|tomorrow)$"#,
      #"(?i)\bin\s+(.+)$"#,
    ]
    for pattern in patterns {
      guard let capture = firstCapture(in: value, pattern: pattern) else { continue }
      let result =
        capture
        .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      let lower = result.lowercased()
      guard !result.isEmpty,
        result.count <= 120,
        !["here", "outside", "my area", "the next few days"].contains(lower),
        !lower.hasPrefix("the next ")
      else { continue }
      return result
    }
    return nil
  }

  private static func cleaned(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "’", with: "'")
      .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func firstCapture(in value: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range])
  }
}
