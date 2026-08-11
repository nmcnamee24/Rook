import Foundation

public enum RookBrowser: String, Codable, Equatable, Sendable {
    case safari
    case chrome
    case firefox
    case arc

    public var displayName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        case .arc: return "Arc"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .safari: return "com.apple.Safari"
        case .chrome: return "com.google.Chrome"
        case .firefox: return "org.mozilla.firefox"
        case .arc: return "company.thebrowser.Browser"
        }
    }
}

public enum RookSpotifyAction: String, Codable, Equatable, Sendable {
    case play
    case pause
    case next
    case previous

    public var label: String {
        switch self {
        case .play: return "Resume playback"
        case .pause: return "Pause playback"
        case .next: return "Next track"
        case .previous: return "Previous track"
        }
    }
}

/// Controls that are safe, deterministic, and fast enough to execute locally
/// without sending the command through a language model.
public enum RookComputerIntent: Equatable, Sendable {
    case openApplication(name: String)
    case webSearch(browser: RookBrowser, query: String)
    case openWebAddress(browser: RookBrowser?, address: String)
    case spotify(RookSpotifyAction)

    public var targetLabel: String {
        switch self {
        case .openApplication(let name): return name
        case .webSearch(let browser, _): return browser.displayName
        case .openWebAddress(let browser, _): return browser?.displayName ?? "Default browser"
        case .spotify: return "Spotify"
        }
    }

    public var progressText: String {
        switch self {
        case .openApplication(let name): return "Opening **\(name)**…"
        case .webSearch(let browser, let query): return "Opening **\(browser.displayName)** and searching for “\(query)”…"
        case .openWebAddress(let browser, _): return "Opening that page in **\(browser?.displayName ?? "your browser")**…"
        case .spotify(let action): return "\(action.label) in **Spotify**…"
        }
    }
}

public enum RookComputerCommandParser {
    public static func parse(_ rawCommand: String) -> RookComputerIntent? {
        let command = cleaned(rawCommand)
        guard !command.isEmpty else { return nil }

        if let captures = captures(
            #"^(?:please\s+)?(?:open\s+)?(safari|google\s+chrome|chrome|firefox|arc)(?:\s+and)?\s+(?:search(?:\s+(?:the\s+)?web)?(?:\s+for)?|google)\s+(.+?)(?:\s+please)?$"#,
            in: command
        ), let browser = browser(named: captures[0]), let query = safeSearchQuery(captures[1]) {
            return .webSearch(browser: browser, query: query)
        }

        if let captures = captures(
            #"^(?:please\s+)?search(?:\s+(?:the\s+)?web)?(?:\s+for)?\s+(.+?)\s+(?:in|on|using|with)\s+(safari|google\s+chrome|chrome|firefox|arc)(?:\s+please)?$"#,
            in: command
        ), let query = safeSearchQuery(captures[0]), let browser = browser(named: captures[1]) {
            return .webSearch(browser: browser, query: query)
        }

        if let captures = captures(
            #"^(?:please\s+)?(?:open|go\s+to|visit)\s+(https?://\S+|[a-z0-9][a-z0-9.-]+\.[a-z]{2,}(?:/\S*)?)(?:\s+(?:in|on|using|with)\s+(safari|google\s+chrome|chrome|firefox|arc))?(?:\s+please)?$"#,
            in: command
        ) {
            let address = captures[0]
            guard isSafeWebAddress(address) else { return nil }
            let browser = captures.count > 1 ? browser(named: captures[1]) : nil
            return .openWebAddress(browser: browser, address: address)
        }

        let lower = command.lowercased()
        if lower.contains("spotify"), !lower.contains("playlist"), !lower.contains("album"), !lower.contains("podcast") {
            if matches(#"^(?:please\s+)?(?:pause|stop)(?:\s+(?:the\s+)?(?:music|song|track|playback))?(?:\s+(?:on|in))?\s+spotify(?:\s+please)?$"#, in: command) {
                return .spotify(.pause)
            }
            if matches(#"^(?:please\s+)?(?:resume|continue|play)(?:\s+(?:the\s+)?(?:music|song|track|playback))?(?:\s+(?:on|in))?\s+spotify(?:\s+please)?$"#, in: command) ||
                matches(#"^(?:please\s+)?play\s+spotify(?:\s+please)?$"#, in: command) {
                return .spotify(.play)
            }
            if matches(#"^(?:please\s+)?(?:skip|next)(?:\s+(?:song|track))?(?:\s+(?:on|in))?\s+spotify(?:\s+please)?$"#, in: command) {
                return .spotify(.next)
            }
            if matches(#"^(?:please\s+)?(?:previous|last|go\s+back)(?:\s+(?:song|track))?(?:\s+(?:on|in))?\s+spotify(?:\s+please)?$"#, in: command) {
                return .spotify(.previous)
            }
        }

        if let captures = captures(
            #"^(?:please\s+)?(?:open|launch|start|show|switch\s+to|bring\s+up)\s+(?:the\s+)?(.+?)(?:\s+app)?(?:\s+please)?$"#,
            in: command
        ), let application = safeApplicationName(captures[0]) {
            return .openApplication(name: application)
        }

        return nil
    }

    private static func cleaned(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func safeSearchQuery(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        let chainedAction = #"\b(?:and|then)\s+(?:open|click|type|send|delete|buy|purchase|install|run|execute|post|publish|book|apply|upload|share)\b"#
        guard result.range(of: chainedAction, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        return result
    }

    private static func browser(named value: String) -> RookBrowser? {
        switch value.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) {
        case "safari": return .safari
        case "chrome", "google chrome": return .chrome
        case "firefox": return .firefox
        case "arc": return .arc
        default: return nil
        }
    }

    private static func safeApplicationName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              name.range(of: #"^[a-z0-9 .+&_'-]+$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        let lower = name.lowercased()
        let compoundActions = [
            " and ", " then ", " search ", " type ", " click ", " send ", " delete ",
            " buy ", " purchase ", " install ", " run ", " execute ", " post ", " publish ",
        ]
        guard !compoundActions.contains(where: lower.contains) else { return nil }
        return name
    }

    private static func isSafeWebAddress(_ value: String) -> Bool {
        let candidate = value.lowercased().hasPrefix("http") ? value : "https://\(value)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.user == nil,
              components.password == nil else { return false }
        return true
    }

    private static func matches(_ pattern: String, in value: String) -> Bool {
        captures(pattern, in: value) != nil
    }

    private static func captures(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.range == NSRange(value.startIndex..., in: value) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return "" }
            return String(value[swiftRange])
        }
    }
}
