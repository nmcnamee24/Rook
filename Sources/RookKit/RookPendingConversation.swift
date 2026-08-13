import Foundation

public enum RookPendingConversationDomain: String, Codable, Equatable, Sendable {
  case general
  case spotifyPlaylist = "spotify_playlist"
}

/// The one open question Rook is waiting for the user to answer.
///
/// This is deliberately separate from the Library archive. The archive explains
/// what happened; this record tells the live router what is still unfinished.
public struct RookPendingConversation: Codable, Equatable, Sendable {
  public let id: UUID
  public let sourceCommand: String
  public let question: String
  public let domain: RookPendingConversationDomain
  public let options: [String]
  public let createdAt: Date
  public let expiresAt: Date

  public init(
    id: UUID = UUID(),
    sourceCommand: String,
    question: String,
    domain: RookPendingConversationDomain = .general,
    options: [String] = [],
    createdAt: Date = Date(),
    expiresAt: Date
  ) {
    self.id = id
    self.sourceCommand = sourceCommand
    self.question = question
    self.domain = domain
    self.options = options
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }

  public func continuationCommand(answer: String) -> String {
    """
    Continue the same unfinished request using the user's new answer.
    Original request: \(sourceCommand)
    Rook's unanswered question: \(question)
    User's answer: \(answer)
    Treat the answer as the missing detail. Do not ask what the user means by the answer alone.
    """
  }
}

public struct RookConversationContinuation: Equatable, Sendable {
  public let pending: RookPendingConversation
  public let answer: String

  public init(pending: RookPendingConversation, answer: String) {
    self.pending = pending
    self.answer = answer
  }

  public var effectiveCommand: String { pending.continuationCommand(answer: answer) }
}

public enum RookPendingConversationResolution: Equatable, Sendable {
  case none
  case cancelled(RookPendingConversation)
  case retry(RookPendingConversation)
  case continuation(RookConversationContinuation)
}

public struct RookPendingConversationStore {
  public let documentURL: URL
  public private(set) var pending: RookPendingConversation?

  public init(documentURL: URL) {
    self.documentURL = documentURL
    pending = Self.load(from: documentURL)
  }

  public mutating func set(_ value: RookPendingConversation) {
    pending = value
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value) {
      try? RookConfig.writePrivate(data, to: documentURL)
    }
  }

  public mutating func clear() {
    pending = nil
    try? FileManager.default.removeItem(at: documentURL)
  }

  public mutating func current(now: Date = Date()) -> RookPendingConversation? {
    guard let pending else { return nil }
    guard pending.expiresAt > now else {
      clear()
      return nil
    }
    return pending
  }

  /// Resolves only clear answers to Rook's open question. A recognizable new
  /// request clears the open loop and is allowed to route normally.
  public mutating func resolve(
    _ rawCommand: String,
    now: Date = Date()
  ) -> RookPendingConversationResolution {
    guard let open = current(now: now) else { return .none }
    let answer = Self.cleaned(rawCommand)
    guard !answer.isEmpty else { return .none }

    if Self.isCancellation(answer) {
      clear()
      return .cancelled(open)
    }
    if Self.isRetry(answer) {
      clear()
      return .retry(open)
    }
    if Self.isIndependentRequest(answer, pending: open) {
      clear()
      return .none
    }

    clear()
    return .continuation(RookConversationContinuation(pending: open, answer: answer))
  }

  private static func load(from url: URL) -> RookPendingConversation? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(RookPendingConversation.self, from: data)
  }

  private static func cleaned(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func isCancellation(_ value: String) -> Bool {
    let normalized = normalize(value)
    return [
      "cancel", "cancel that", "drop it", "forget it", "forget that", "never mind", "nevermind", "stop",
    ].contains(normalized)
  }

  private static func isRetry(_ value: String) -> Bool {
    let normalized = normalize(value)
    return [
      "try again", "try that again", "try it again", "retry", "retry that", "retry it",
      "do that again", "do it again", "run that again", "run it again", "one more time",
    ].contains(normalized)
  }

  private static func isIndependentRequest(
    _ value: String,
    pending: RookPendingConversation
  ) -> Bool {
    let normalized = normalize(value)
    let referential = [
      " it", " that", " one", " instead", "actually", "the first", "the second", "the third", "same one",
    ].contains { normalized == $0.trimmingCharacters(in: .whitespaces) || normalized.contains($0) }

    if pending.domain == .spotifyPlaylist {
      let unrelatedTopics = [
        "weather", "calendar", "email", "gmail", "safari", "browser", "code", "timer", "reminder",
        "screenshot", "document", "resume", "message", "lights", "light", "phone", "facetime",
      ]
      if unrelatedTopics.contains(where: { normalized.contains($0) }) { return true }
      if normalized.hasPrefix("what ") || normalized.hasPrefix("why ") || normalized.hasPrefix("how ")
        || normalized.hasPrefix("tell me ") || normalized.hasPrefix("open ")
        || normalized.hasPrefix("help me ") || normalized.hasPrefix("i need help ")
        || normalized.hasPrefix("lets ") || normalized.hasPrefix("call ")
      {
        return !normalized.contains("spotify") && !normalized.contains("playlist")
      }
      return false
    }

    if referential { return false }
    let newRequestPrefixes = [
      "what ", "whats ", "why ", "how ", "tell me ", "show me ", "open ", "search ", "look up ",
      "play ", "pause ", "email ", "send ", "create ", "add ", "remind me ", "schedule ", "check ",
      "take a screenshot", "help me ", "i need ", "lets ", "call ", "start a ",
    ]
    return newRequestPrefixes.contains(where: { normalized.hasPrefix($0) })
  }

  private static func normalize(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum RookPendingConversationDetector {
  public static func detect(
    response: RookResponse,
    sourceCommand: String,
    route: String,
    now: Date = Date(),
    lifetime: TimeInterval = 30 * 60
  ) -> RookPendingConversation? {
    guard let question = extractQuestion(from: response) else { return nil }
    let normalized = question.lowercased()
    let clarificationSignals = [
      "which ", "what time", "what date", "when ", "where ", "who ", "how long", "do you mean",
      "would you like", "want me to", "should i", "can you tell me", "what city", "what zip",
      "could you clarify", "can you clarify", "please clarify", "please tell me", "please specify",
      "what did you mean",
    ]
    guard
      response.intent == "clarification"
        || clarificationSignals.contains(where: { normalized.contains($0) })
    else { return nil }

    let isPlaylistChoice = route == "spotify_native" && normalized.contains("playlist")
    let domain: RookPendingConversationDomain = isPlaylistChoice ? .spotifyPlaylist : .general
    let asksForChoice = normalized.contains("which") || normalized.contains("choose") || normalized.contains("select")
    let options =
      asksForChoice
      ? response.canvas.flatMap(\.items).map(\.label).filter(Self.isUsefulOption)
      : []

    return RookPendingConversation(
      sourceCommand: sourceCommand,
      question: question,
      domain: domain,
      options: Array(options.prefix(20)),
      createdAt: now,
      expiresAt: now.addingTimeInterval(lifetime)
    )
  }

  private static func extractQuestion(from response: RookResponse) -> String? {
    for candidate in [response.spokenText, response.displayText] where candidate.contains("?") {
      guard let end = candidate.lastIndex(of: "?") else { continue }
      let throughQuestion = candidate[...end]
      let start = throughQuestion.dropLast().lastIndex(where: { ".!?\n".contains($0) })
      let sentence = start.map { throughQuestion[throughQuestion.index(after: $0)...] } ?? throughQuestion[...]
      let cleaned = String(sentence)
        .replacingOccurrences(of: "[*_`#]", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !cleaned.isEmpty { return cleaned }
    }
    return nil
  }

  private static func isUsefulOption(_ value: String) -> Bool {
    let normalized = value.lowercased()
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !["what to say", "needs attention", "next step"].contains(normalized)
  }
}

public enum RookSpotifyPlaylistFollowUpResolver {
  public static func resolve(answer rawAnswer: String, options: [String]) -> RookSpotifyIntent? {
    let answer = rawAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !answer.isEmpty else { return nil }
    let normalized = answer.lowercased()
      .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if normalized.range(of: #"\b(top|most played|favorite|favourite)\b"#, options: .regularExpression) != nil,
      normalized.range(of: #"\b(track|tracks|song|songs)\b"#, options: .regularExpression) != nil
    {
      return .playTopTracks
    }

    if !options.isEmpty,
      normalized.range(
        of: #"^(?:yes|yeah|yep|sure|okay|ok|do it|play it|play that|that one|the best one|best fit)(?: please)?$"#,
        options: .regularExpression
      ) != nil
    {
      return .play(query: options[0], preferredKind: .playlist, libraryOnly: true)
    }

    let purposes = RookSpotifyPurposeMatcher.purposes(in: answer)
    if !purposes.isEmpty,
      normalized.range(of: #"\b(which|best|good|seems|looks|sounds)\b"#, options: .regularExpression) != nil
    {
      return .recommendPlaylists(purposes: purposes)
    }

    let ordinals = [
      (#"\b(?:third|3rd|(?:(?:number|option|choice|playlist)(?:\s+number)?)\s+(?:three|3))\b"#, 2),
      (#"\b(?:second|2nd|(?:(?:number|option|choice|playlist)(?:\s+number)?)\s+(?:two|2))\b"#, 1),
      (#"\b(?:first|1st|(?:(?:number|option|choice|playlist)(?:\s+number)?)\s+(?:one|1))\b"#, 0),
    ]
    for (pattern, index) in ordinals where normalized.range(of: pattern, options: .regularExpression) != nil {
      if options.indices.contains(index) {
        return .play(query: options[index], preferredKind: .playlist, libraryOnly: true)
      }
    }

    if !options.isEmpty {
      let candidates = options.enumerated().map { index, name in
        RookSpotifyCandidate(
          id: "pending-\(index)",
          name: name,
          uri: "spotify:playlist:pending-\(index)",
          kind: .playlist
        )
      }
      if let match = RookSpotifyMatcher.ranked(query: answer, candidates: candidates).first, match.score >= 70 {
        return .play(query: match.candidate.name, preferredKind: .playlist, libraryOnly: true)
      }
    }

    var query =
      answer
      .replacingOccurrences(
        of: #"^(?:please\s+)?(?:play\s+)?(?:my\s+|the\s+)?"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: #"\s+playlist(?:\s+please)?[.!?]*$"#,
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty { query = answer }
    return .play(query: query, preferredKind: .playlist, libraryOnly: true)
  }
}
