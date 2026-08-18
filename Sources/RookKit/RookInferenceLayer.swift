import Foundation

public enum RookInferenceBasis: String, Equatable, Sendable {
  case explicit
  case retry
  case recentContext = "recent_context"
  case semanticCapability = "semantic_capability"
  case unresolvedReference = "unresolved_reference"
}

public struct RookInferenceInterpretation: Equatable, Sendable {
  public let originalCommand: String
  public let effectiveCommand: String
  public let displayCommand: String
  public let basis: RookInferenceBasis
  public let confidence: Double
  public let inferredResolution: RookDirectCapabilityResolution?

  public init(
    originalCommand: String,
    effectiveCommand: String,
    displayCommand: String,
    basis: RookInferenceBasis,
    confidence: Double,
    inferredResolution: RookDirectCapabilityResolution?
  ) {
    self.originalCommand = originalCommand
    self.effectiveCommand = effectiveCommand
    self.displayCommand = displayCommand
    self.basis = basis
    self.confidence = confidence
    self.inferredResolution = inferredResolution
  }
}

public struct RookInferenceDecision: Equatable, Sendable {
  public let interpretation: RookInferenceInterpretation
  public let resolution: RookDirectCapabilityResolution

  public init(
    interpretation: RookInferenceInterpretation,
    resolution: RookDirectCapabilityResolution
  ) {
    self.interpretation = interpretation
    self.resolution = resolution
  }
}

/// Rook's deterministic continuity pass. It resolves only high-confidence
/// retries, approvals, and recent referents before the exact fast-path gate.
/// General semantic interpretation and worker ownership belong to Central Rook.
public enum RookInferenceLayer {
  public static func interpret(
    _ rawCommand: String,
    retryResolution: RookConversationResolution? = nil,
    lastResponse: RookResponse? = nil,
    recentEntries: [RookLibraryEntry] = [],
    now: Date = Date()
  ) -> RookInferenceInterpretation {
    let original = cleaned(rawCommand)

    if let retryResolution {
      return RookInferenceInterpretation(
        originalCommand: original,
        effectiveCommand: retryResolution.effectiveCommand,
        displayCommand: retryResolution.displayCommand,
        basis: .retry,
        confidence: 1,
        inferredResolution: nil
      )
    }

    if RookComputerOperatorRouting.isApprovalFollowUp(original),
      let target = recentApprovalTarget(in: recentEntries, now: now)
    {
      let effective = """
        Continue the immediately preceding approval-gated request.
        Previous user request: \(target.command)
        Previous Rook result: \(target.summary)
        User's current action-time approval: \(original)
        Bind this approval only to one exact reviewed recipient, content, destination, and unexpired queue item. Re-read the current queue and app state. If the details changed, were never reviewed, or do not identify one exact action, stop and ask one concise clarification. A Librarian checkpoint is context, not approval.
        """
      return RookInferenceInterpretation(
        originalCommand: original,
        effectiveCommand: effective,
        displayCommand: "\(original)  →  \(target.label)",
        basis: .recentContext,
        confidence: 0.99,
        inferredResolution: .fallThrough(.computerControl)
      )
    }

    if isReferentialSpotifyPlayback(original) {
      if let playlist = recentSpotifyPlaylist(
        lastResponse: lastResponse,
        entries: recentEntries,
        now: now
      ) {
        return RookInferenceInterpretation(
          originalCommand: original,
          effectiveCommand: "Play my \(playlist) playlist on Spotify",
          displayCommand: "\(original)  →  \(playlist)",
          basis: .recentContext,
          confidence: 0.96,
          inferredResolution: .spotify(
            .play(query: playlist, preferredKind: .playlist, libraryOnly: true)
          )
        )
      }
      return RookInferenceInterpretation(
        originalCommand: original,
        effectiveCommand: original,
        displayCommand: original,
        basis: .unresolvedReference,
        confidence: 0,
        inferredResolution: .clarification(
          capability: .spotify,
          message: "Which Spotify playlist do you mean? I don’t have one unique recent playlist to attach “that” to."
        )
      )
    }

    return RookInferenceInterpretation(
      originalCommand: original,
      effectiveCommand: original,
      displayCommand: original,
      basis: .explicit,
      confidence: 1,
      inferredResolution: nil
    )
  }

  public static func decide(
    _ interpretation: RookInferenceInterpretation,
    cachedDecision: LocalRookDecision? = nil
  ) -> RookInferenceDecision {
    let resolution =
      interpretation.inferredResolution
      ?? RookDirectCapabilityGuide.resolve(
        interpretation.effectiveCommand,
        cachedDecision: cachedDecision
      )
    return RookInferenceDecision(interpretation: interpretation, resolution: resolution)
  }

  private static func recentApprovalTarget(
    in entries: [RookLibraryEntry],
    now: Date
  ) -> RookLibraryEntry? {
    entries
      .filter { entry in
        let age = now.timeIntervalSince(entry.updatedAt)
        guard age >= -300, age <= 30 * 60 else { return false }
        guard !RookComputerOperatorRouting.isApprovalFollowUp(entry.command) else { return false }
        let text = "\(entry.command) \(entry.summary)".lowercased()
        let actionSignals = [
          "send", "text", "message", "email", "publish", "post", "purchase", "buy",
          "book", "apply", "delete", "install", "upload", "share", "approval",
          "not typed", "not sent", "nothing was sent", "waiting for review",
        ]
        return actionSignals.contains(where: text.contains)
      }
      .sorted { $0.updatedAt > $1.updatedAt }
      .first
  }

  private static func isReferentialSpotifyPlayback(_ command: String) -> Bool {
    let normalized = normalize(command)
    let patterns = [
      #"^(?:please )?(?:play|start)(?: me)? (?:that|this|it|that one|this one|the one|the same one)(?: spotify)?(?: playlist| music| one)?(?: please)?$"#,
      #"^(?:please )?put on (?:that|this|it|that one|this one|the one|the same one)(?: spotify)?(?: playlist| music| one)?(?: please)?$"#,
    ]
    return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
  }

  private static func recentSpotifyPlaylist(
    lastResponse: RookResponse?,
    entries: [RookLibraryEntry],
    now: Date
  ) -> String? {
    if let lastResponse, let playlist = spotifyPlaylist(from: lastResponse) {
      return playlist
    }

    for entry in entries.sorted(by: { $0.updatedAt > $1.updatedAt }) {
      let age = now.timeIntervalSince(entry.updatedAt)
      guard age >= -300, age <= 2 * 3_600 else { continue }
      let context = [entry.command, entry.summary, entry.route, entry.tags.joined(separator: " ")]
        .joined(separator: " ")
        .lowercased()
      guard context.contains("spotify") || context.contains("playlist") else { continue }

      for report in entry.pawns {
        if let result = report.reportedResult, let playlist = selectedPlaylist(in: result) {
          return playlist
        }
      }
      if let playlist = selectedPlaylist(in: entry.summary) { return playlist }
    }
    return nil
  }

  private static func spotifyPlaylist(from response: RookResponse) -> String? {
    for report in response.pawns {
      if let result = report.reportedResult, let playlist = selectedPlaylist(in: result) {
        return playlist
      }
    }
    if let playlist = selectedPlaylist(in: response.displayText) { return playlist }
    guard response.intent != "error" else { return nil }

    for block in response.canvas where block.kind == .spotify {
      let useful = block.items.compactMap { validatedPlaylist($0.label) }
      if useful.count == 1 { return useful[0] }
      if !useful.isEmpty,
        containsAny(
          response.displayText.lowercased(),
          ["best fit", "strongest match", "playing", "now playing"]
        )
      {
        return useful[0]
      }
    }
    return nil
  }

  private static func selectedPlaylist(in text: String) -> String? {
    let quotedPatterns = [
      #"(?i)(?:selected|recommended|strongest match|best match|best fit|found)\s+(?:the\s+playlist\s+)?[“\"]([^”\"]+)[”\"]"#,
      #"(?i)(?:playing|play)\s+[“\"]([^”\"]+)[”\"]"#,
    ]
    for pattern in quotedPatterns {
      if let candidate = firstCapture(pattern, in: text), let validated = validatedPlaylist(candidate) {
        return validated
      }
    }

    let unquotedPatterns = [
      #"(?i)strongest match(?:\s+is)?\s*:\s*(?:\*\*)?([^.!?\n]+?)(?:\*\*)?(?:[.!?]|$)"#,
      #"(?i)(?:\*\*)?([^.!?\n]+?)(?:\*\*)?\s+looks like the best (?:study|work|focus|playlist)"#,
    ]
    for pattern in unquotedPatterns {
      if let candidate = firstCapture(pattern, in: text), let validated = validatedPlaylist(candidate) {
        return validated
      }
    }
    return nil
  }

  private static func validatedPlaylist(_ rawValue: String) -> String? {
    let value =
      rawValue
      .replacingOccurrences(of: "**", with: "")
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    let rejected: Set<String> = [
      "it", "that", "this", "playlist", "spotify", "that spotify",
      "needs attention", "next step", "not completed", "what to say",
    ]
    guard !value.isEmpty, value.count <= 160, !rejected.contains(value.lowercased()) else { return nil }
    return value
  }

  private static func firstCapture(_ pattern: String, in value: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range])
  }

  private static func containsAny(_ value: String, _ phrases: [String]) -> Bool {
    phrases.contains(where: value.contains)
  }

  private static func containsAnyWord(_ words: [String], in value: String) -> Bool {
    words.contains { containsWord($0, in: value) }
  }

  private static func containsWord(_ word: String, in value: String) -> Bool {
    value.range(
      of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
      options: .regularExpression
    ) != nil
  }

  private static func cleaned(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalize(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
