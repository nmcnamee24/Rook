import Foundation

public enum RookScreenCaptureTarget: Equatable, Sendable {
  case mainDisplay
  case frontmostWindow
  case namedWindow(String)

  public var label: String {
    switch self {
    case .mainDisplay: return "screen"
    case .frontmostWindow: return "frontmost window"
    case .namedWindow(let name): return name
    }
  }
}

public struct RookScreenCaptureRequest: Equatable, Sendable {
  public let target: RookScreenCaptureTarget

  public init(target: RookScreenCaptureTarget) {
    self.target = target
  }

  public var progressText: String {
    switch target {
    case .mainDisplay:
      return "Capturing your screen privately, then I’ll inspect it…"
    case .frontmostWindow:
      return "Capturing the frontmost window privately, then I’ll inspect it…"
    case .namedWindow(let name):
      return "Capturing **\(name)** privately, then I’ll inspect it…"
    }
  }
}

/// Recognizes explicit, read-only requests to capture or visually inspect the
/// screen. The original command still goes to central Rook after capture so
/// any requested analysis remains intact.
public enum RookScreenCaptureCommandParser {
  public static func parse(_ rawCommand: String) -> RookScreenCaptureRequest? {
    let command = cleaned(rawCommand)
    guard !command.isEmpty else { return nil }

    if matches(
      #"^(?:please\s+)?(?:can\s+you\s+)?(?:take|capture|grab)(?:\s+(?:a|the))?\s+screenshot(?:\s+(?:of|from))?(?:\s+(?:my|the))?\s+(?:screen|display|desktop)(?:\s+and\s+.+)?$"#,
      in: command)
      || matches(
        #"^(?:please\s+)?(?:can\s+you\s+)?screenshot(?:\s+(?:my|the))?\s+(?:screen|display|desktop)(?:\s+and\s+.+)?$"#,
        in: command)
      || matches(
        #"^(?:please\s+)?(?:can\s+you\s+)?(?:take|capture|grab)(?:\s+(?:a|the))?\s+screenshot$"#,
        in: command)
      || matches(
        #"^(?:please\s+)?(?:can\s+you\s+)?(?:look\s+at|inspect|check|read|see)(?:\s+what(?:'s|\s+is))?(?:\s+currently)?(?:\s+(?:on|in))?\s+(?:my|the)\s+(?:screen|display|desktop)(?:\s+and\s+.+)?$"#,
        in: command)
      || matches(
        #"^(?:please\s+)?(?:can\s+you\s+)?(?:tell\s+me\s+|show\s+me\s+)?what(?:'s|\s+is)(?:\s+currently)?\s+(?:on|in)\s+(?:my|the)\s+(?:screen|display|desktop)(?:\s+and\s+.+)?$"#,
        in: command)
    {
      return RookScreenCaptureRequest(target: .mainDisplay)
    }

    if matches(
      #"^(?:please\s+)?(?:can\s+you\s+)?(?:take|capture|grab)(?:\s+(?:a|the))?\s+screenshot\s+(?:of|from)\s+(?:my|the)?\s*(?:frontmost|front|active|current)\s+window(?:\s+and\s+.+)?$"#,
      in: command)
      || matches(
        #"^(?:please\s+)?(?:can\s+you\s+)?(?:capture|inspect|check|see)\s+(?:my|the)?\s*(?:frontmost|front|active|current)\s+window(?:\s+and\s+.+)?$"#,
        in: command)
      || matches(
        #"^(?:please\s+)?(?:can\s+you\s+)?(?:look\s+at|inspect|check|read|see)\s+(?:my|the)?\s*(?:frontmost|front|active|current)\s+window(?:\s+and\s+.+)?$"#,
        in: command)
    {
      return RookScreenCaptureRequest(target: .frontmostWindow)
    }

    let namedPatterns = [
      #"^(?:please\s+)?(?:can\s+you\s+)?(?:take|capture|grab)(?:\s+(?:a|the))?\s+screenshot\s+(?:of|from)\s+(?:my|the)?\s*window\s+(?:called|named|titled)\s+(.+?)(?:\s+and\s+.+)?$"#,
      #"^(?:please\s+)?(?:can\s+you\s+)?screenshot\s+(?:my|the)?\s*(.+?)\s+(?:window|app)(?:\s+and\s+.+)?$"#,
      #"^(?:please\s+)?(?:can\s+you\s+)?(?:look\s+at|inspect|check|read|see)\s+(?:my|the)?\s*window\s+(?:called|named|titled)\s+(.+?)(?:\s+and\s+.+)?$"#,
      #"^(?:please\s+)?(?:can\s+you\s+)?(?:take|capture|grab)(?:\s+(?:a|the))?\s+screenshot\s+(?:of|from)\s+(?:my|the)?\s*(.+?)\s+(?:window|app)(?:\s+and\s+.+)?$"#,
      #"^(?:please\s+)?(?:can\s+you\s+)?(?:take|capture|grab)(?:\s+(?:a|the))?\s+screenshot\s+(?:of|from)\s+(?:my|the)?\s*(.+?)(?:\s+and\s+.+)?$"#,
      #"^(?:please\s+)?(?:can\s+you\s+)?(?:look\s+at|inspect|check|read|see)\s+(?:my|the)?\s*(.+?)\s+(?:window|app)(?:\s+and\s+.+)?$"#,
      #"^(?:please\s+)?(?:can\s+you\s+)?(?:tell\s+me\s+|show\s+me\s+)?what(?:'s|\s+is)(?:\s+currently)?\s+(?:on|in)\s+(?:my|the)?\s*(.+?)\s+(?:window|app)(?:\s+and\s+.+)?$"#,
    ]
    for pattern in namedPatterns {
      guard let capture = captures(pattern, in: command)?.first,
        let target = safeTarget(capture)
      else { continue }
      return RookScreenCaptureRequest(target: .namedWindow(target))
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

  private static func safeTarget(_ value: String) -> String? {
    let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty, target.count <= 160,
      target.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    let normalized = target.lowercased()
    guard !["screen", "display", "desktop", "window", "app"].contains(normalized) else { return nil }
    return target
  }

  private static func matches(_ pattern: String, in value: String) -> Bool {
    captures(pattern, in: value) != nil
  }

  private static func captures(_ pattern: String, in value: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      match.range == NSRange(value.startIndex..., in: value)
    else { return nil }
    return (1..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return "" }
      return String(value[swiftRange])
    }
  }
}
