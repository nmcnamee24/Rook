import Foundation

public enum RookCalculationOperation: String, Equatable, Sendable {
  case add
  case subtract
  case multiply
  case divide
  case percentOf
}

public struct RookCalculation: Equatable, Sendable {
  public let lhs: Double
  public let operation: RookCalculationOperation
  public let rhs: Double

  public init(lhs: Double, operation: RookCalculationOperation, rhs: Double) {
    self.lhs = lhs
    self.operation = operation
    self.rhs = rhs
  }

  public var result: Double? {
    switch operation {
    case .add: lhs + rhs
    case .subtract: lhs - rhs
    case .multiply: lhs * rhs
    case .divide: rhs == 0 ? nil : lhs / rhs
    case .percentOf: lhs / 100 * rhs
    }
  }

  public var expression: String {
    let symbol: String
    switch operation {
    case .add: symbol = "+"
    case .subtract: symbol = "−"
    case .multiply: symbol = "×"
    case .divide: symbol = "÷"
    case .percentOf: symbol = "% of"
    }
    return "\(RookReflexFormatter.number(lhs)) \(symbol) \(RookReflexFormatter.number(rhs))"
  }
}

public enum RookConversionUnit: String, Equatable, Sendable {
  case mile
  case kilometer
  case foot
  case meter
  case inch
  case centimeter
  case pound
  case kilogram
  case fahrenheit
  case celsius
  case hour
  case minute

  fileprivate enum Dimension { case length, mass, temperature, time }

  fileprivate var dimension: Dimension {
    switch self {
    case .mile, .kilometer, .foot, .meter, .inch, .centimeter: .length
    case .pound, .kilogram: .mass
    case .fahrenheit, .celsius: .temperature
    case .hour, .minute: .time
    }
  }

  public var shortLabel: String {
    switch self {
    case .mile: "mi"
    case .kilometer: "km"
    case .foot: "ft"
    case .meter: "m"
    case .inch: "in"
    case .centimeter: "cm"
    case .pound: "lb"
    case .kilogram: "kg"
    case .fahrenheit: "°F"
    case .celsius: "°C"
    case .hour: "hr"
    case .minute: "min"
    }
  }
}

public struct RookConversion: Equatable, Sendable {
  public let value: Double
  public let from: RookConversionUnit
  public let to: RookConversionUnit

  public init(value: Double, from: RookConversionUnit, to: RookConversionUnit) {
    self.value = value
    self.from = from
    self.to = to
  }

  public var result: Double? {
    guard from.dimension == to.dimension else { return nil }
    if from == to { return value }

    switch (from, to) {
    case (.fahrenheit, .celsius): return (value - 32) * 5 / 9
    case (.celsius, .fahrenheit): return value * 9 / 5 + 32
    default: break
    }

    let base: Double
    switch from {
    case .mile: base = value * 1_609.344
    case .kilometer: base = value * 1_000
    case .foot: base = value * 0.3048
    case .meter: base = value
    case .inch: base = value * 0.0254
    case .centimeter: base = value * 0.01
    case .pound: base = value * 0.45359237
    case .kilogram: base = value
    case .hour: base = value * 60
    case .minute: base = value
    case .fahrenheit, .celsius: return nil
    }

    switch to {
    case .mile: return base / 1_609.344
    case .kilometer: return base / 1_000
    case .foot: return base / 0.3048
    case .meter: return base
    case .inch: return base / 0.0254
    case .centimeter: return base / 0.01
    case .pound: return base / 0.45359237
    case .kilogram: return base
    case .hour: return base / 60
    case .minute: return base
    case .fahrenheit, .celsius: return nil
    }
  }

  public var expression: String {
    "\(RookReflexFormatter.number(value)) \(from.shortLabel) → \(to.shortLabel)"
  }
}

public enum RookLocalAlertKind: String, Codable, Equatable, Sendable {
  case timer
  case reminder
}

public enum RookDeviceStatusKind: Equatable, Sendable {
  case battery
  case storage
  case volume
}

public enum RookVolumeAction: Equatable, Sendable {
  case set(Double)
  case adjust(Double)
  case mute
  case unmute
}

public enum RookReflexIntent: Equatable, Sendable {
  case calculation(RookCalculation)
  case conversion(RookConversion)
  case scheduleAlert(kind: RookLocalAlertKind, dueAt: Date, message: String)
  case listAlerts(RookLocalAlertKind?)
  case cancelAlert(RookLocalAlertKind?)
  case deviceStatus(RookDeviceStatusKind)
  case volume(RookVolumeAction)

  public var progressText: String {
    switch self {
    case .calculation: "Calculating locally…"
    case .conversion: "Converting locally…"
    case .scheduleAlert(let kind, _, _): "Setting the \(kind.rawValue)…"
    case .listAlerts: "Checking local alerts…"
    case .cancelAlert: "Cancelling the local alert…"
    case .deviceStatus: "Reading this Mac…"
    case .volume: "Adjusting this Mac…"
    }
  }
}

public enum RookReflexFormatter {
  public static func number(_ value: Double) -> String {
    guard value.isFinite else { return "undefined" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 4
    formatter.minimumFractionDigits = 0
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }
}

public enum RookReflexCommandParser {
  public static func parse(
    _ command: String,
    now: Date = Date(),
    calendar suppliedCalendar: Calendar = .current
  ) -> RookReflexIntent? {
    let normalized = normalize(command)
    guard !normalized.isEmpty else { return nil }

    if let status = parseDeviceStatus(normalized) { return status }
    if let volume = parseVolume(normalized) { return volume }
    if let alert = parseAlert(normalized, now: now, calendar: suppliedCalendar) { return alert }
    if let conversion = parseConversion(normalized) { return .conversion(conversion) }
    if let calculation = parseCalculation(normalized) { return .calculation(calculation) }
    return nil
  }

  private static func parseDeviceStatus(_ value: String) -> RookReflexIntent? {
    let exact: [String: RookDeviceStatusKind] = [
      "what is my battery": .battery,
      "what's my battery": .battery,
      "whats my battery": .battery,
      "battery status": .battery,
      "how much battery do i have": .battery,
      "how much storage do i have": .storage,
      "what is my storage": .storage,
      "what's my storage": .storage,
      "whats my storage": .storage,
      "storage status": .storage,
      "what is my volume": .volume,
      "what's my volume": .volume,
      "whats my volume": .volume,
      "volume status": .volume,
    ]
    return exact[value].map(RookReflexIntent.deviceStatus)
  }

  private static func parseVolume(_ value: String) -> RookReflexIntent? {
    switch value {
    case "volume up", "turn the volume up", "turn volume up": return .volume(.adjust(0.10))
    case "volume down", "turn the volume down", "turn volume down": return .volume(.adjust(-0.10))
    case "mute", "mute the volume", "mute my mac": return .volume(.mute)
    case "unmute", "unmute the volume", "unmute my mac": return .volume(.unmute)
    default: break
    }

    guard
      let groups = captures(
        "^(?:set|turn) (?:the )?volume (?:to )?([0-9]{1,3})(?: percent|%)?$",
        in: value
      ), let percent = Double(groups[0]), (0...100).contains(percent)
    else { return nil }
    return .volume(.set(percent / 100))
  }

  private static func parseAlert(_ value: String, now: Date, calendar suppliedCalendar: Calendar) -> RookReflexIntent? {
    switch value {
    case "what timers are running", "list timers", "show timers": return .listAlerts(.timer)
    case "what reminders are set", "list reminders", "show reminders": return .listAlerts(.reminder)
    case "list alerts", "show alerts": return .listAlerts(nil)
    case "cancel my timer", "cancel the timer", "cancel timer": return .cancelAlert(.timer)
    case "cancel my reminder", "cancel the reminder", "cancel reminder": return .cancelAlert(.reminder)
    case "cancel my alert", "cancel the alert", "cancel alert": return .cancelAlert(nil)
    default: break
    }

    if let groups = captures(
      "^(?:set )?(?:a )?timer for ([0-9]+(?:\\.[0-9]+)? (?:seconds?|minutes?|hours?))(?: called (.+))?$",
      in: value
    ), let duration = duration(from: groups[0]), duration >= 1 {
      let label = groups.count > 1 ? groups[1] : "Timer"
      return .scheduleAlert(kind: .timer, dueAt: now.addingTimeInterval(duration), message: label)
    }
    if let groups = captures(
      "^(?:set )?(?:a )?([0-9]+(?:\\.[0-9]+)? (?:second|minute|hour)) timer(?: called (.+))?$",
      in: value
    ), let duration = duration(from: groups[0]), duration >= 1 {
      let label = groups.count > 1 ? groups[1] : "Timer"
      return .scheduleAlert(kind: .timer, dueAt: now.addingTimeInterval(duration), message: label)
    }

    if let groups = captures(
      "^remind me in ([0-9]+(?:\\.[0-9]+)? (?:seconds?|minutes?|hours?|days?)) to (.+)$",
      in: value
    ), let duration = duration(from: groups[0]), duration >= 1 {
      return .scheduleAlert(kind: .reminder, dueAt: now.addingTimeInterval(duration), message: groups[1])
    }

    if let groups = captures(
      "^remind me (tomorrow )?at ([0-9]{1,2})(?::([0-9]{2}))? ?(am|pm) to (.+)$",
      in: value
    ) {
      let calendar = suppliedCalendar
      let tomorrow = !groups[0].isEmpty
      guard let rawHour = Int(groups[1]), (1...12).contains(rawHour) else { return nil }
      let minute = Int(groups[2]) ?? 0
      guard (0...59).contains(minute) else { return nil }
      let meridiem = groups[3]
      let hour = (rawHour % 12) + (meridiem == "pm" ? 12 : 0)
      let base = tomorrow ? calendar.date(byAdding: .day, value: 1, to: now) ?? now : now
      var components = calendar.dateComponents([.year, .month, .day], from: base)
      components.hour = hour
      components.minute = minute
      components.second = 0
      guard var dueAt = calendar.date(from: components) else { return nil }
      if !tomorrow, dueAt <= now {
        dueAt = calendar.date(byAdding: .day, value: 1, to: dueAt) ?? dueAt
      }
      return .scheduleAlert(kind: .reminder, dueAt: dueAt, message: groups[4])
    }
    return nil
  }

  private static func parseConversion(_ value: String) -> RookConversion? {
    var candidate = value
    for prefix in ["convert ", "what is ", "what's ", "whats "] where candidate.hasPrefix(prefix) {
      candidate.removeFirst(prefix.count)
      break
    }
    guard
      let groups = captures(
        "^(-?[0-9]+(?:\\.[0-9]+)?) ?([a-z°]+) (?:to|in|into) ([a-z°]+)$",
        in: candidate
      ), let number = Double(groups[0]),
      let from = unit(groups[1]), let to = unit(groups[2]), from.dimension == to.dimension
    else { return nil }
    return RookConversion(value: number, from: from, to: to)
  }

  private static func parseCalculation(_ value: String) -> RookCalculation? {
    var candidate = value
    for prefix in ["calculate ", "what is ", "what's ", "whats "] where candidate.hasPrefix(prefix) {
      candidate.removeFirst(prefix.count)
      break
    }
    guard
      let groups = captures(
        "^(-?[0-9]+(?:\\.[0-9]+)?) ?(percent of|% of|plus|added to|minus|times|multiplied by|divided by) ?(-?[0-9]+(?:\\.[0-9]+)?)$",
        in: candidate
      ), let lhs = Double(groups[0]), let rhs = Double(groups[2])
    else { return nil }
    let operation: RookCalculationOperation
    switch groups[1] {
    case "plus", "added to": operation = .add
    case "minus": operation = .subtract
    case "times", "multiplied by": operation = .multiply
    case "divided by": operation = .divide
    case "percent of", "% of": operation = .percentOf
    default: return nil
    }
    return RookCalculation(lhs: lhs, operation: operation, rhs: rhs)
  }

  private static func unit(_ value: String) -> RookConversionUnit? {
    switch value {
    case "mile", "miles", "mi": .mile
    case "kilometer", "kilometers", "kilometre", "kilometres", "km": .kilometer
    case "foot", "feet", "ft": .foot
    case "meter", "meters", "metre", "metres", "m": .meter
    case "inch", "inches", "in": .inch
    case "centimeter", "centimeters", "centimetre", "centimetres", "cm": .centimeter
    case "pound", "pounds", "lb", "lbs": .pound
    case "kilogram", "kilograms", "kg", "kgs": .kilogram
    case "fahrenheit", "f", "°f": .fahrenheit
    case "celsius", "centigrade", "c", "°c": .celsius
    case "hour", "hours", "hr", "hrs": .hour
    case "minute", "minutes", "min", "mins": .minute
    default: nil
    }
  }

  private static func duration(from value: String) -> TimeInterval? {
    let parts = value.split(separator: " ")
    guard parts.count == 2, let amount = Double(parts[0]) else { return nil }
    switch parts[1] {
    case "second", "seconds": return amount
    case "minute", "minutes": return amount * 60
    case "hour", "hours": return amount * 3_600
    case "day", "days": return amount * 86_400
    default: return nil
    }
  }

  private static func normalize(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "[?,!]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func captures(_ pattern: String, in value: String) -> [String]? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      match.range == NSRange(value.startIndex..., in: value)
    else { return nil }
    return (1..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return "" }
      return String(value[swiftRange])
    }
  }
}
