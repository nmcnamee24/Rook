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
        return locationQuery
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Matches only straightforward forecast lookups. Weather-dependent decisions,
/// safety questions, alerts, radar, and contextual follow-ups keep using deep Rook.
public enum RookWeatherCommandParser {
    public static func parse(_ rawCommand: String) -> RookWeatherRequest? {
        let command = rawCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
        let lower = command.lowercased()
        guard containsWeatherWord(lower) else { return nil }

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
        let cleaned = capture
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned
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
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}
