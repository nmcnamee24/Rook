import Foundation

public enum LocalRookDestination: String, Equatable, Sendable {
  case instant
  case stream
  case deliberate
}

public struct LocalRookDecision: Equatable, Sendable {
  public let destination: LocalRookDestination
  public let response: QuickRookResponse

  public init(destination: LocalRookDestination, response: QuickRookResponse) {
    self.destination = destination
    self.response = response
  }
}

/// Rook's deterministic layer is intentionally a gate, not its delegator.
/// It answers only exact, context-free conversational checks. Every other
/// unclaimed request goes to Central Rook, which understands the complete
/// request and decides whether to answer, use a capability, or deploy pawns.
public enum LocalRookRouter {
  public static func route(_ command: String) -> LocalRookDecision {
    let normalized = normalize(command)
    if let answer = instantAnswer(for: normalized) {
      return decision(
        destination: .instant,
        displayText: answer.display,
        spokenText: answer.spoken,
        intent: "answer"
      )
    }
    return centralHandoff()
  }

  /// A known native adapter declined or was intentionally prevented from
  /// guessing. Central Rook receives the intact request and owns recovery.
  public static func routeAfterDirectCapabilityMiss(
    _ command: String,
    capability: RookDirectCapabilityID
  ) -> LocalRookDecision {
    let title =
      RookDirectCapabilityGuide.cheatSheet.first(where: { $0.id == capability })?.title
      ?? "native capability"
    return centralHandoff(
      displayText: "Central Rook is deciding how to handle that after the exact \(title) path declined."
    )
  }

  /// Retained for restored in-flight hybrid requests. Pawn ownership is no
  /// longer guessed here; Central Rook sees the plan and chooses its own crew.
  public static func routeHybrid(
    _ command: String,
    plan: RookHybridCapabilityPlan
  ) -> LocalRookDecision {
    centralHandoff(
      displayText: "Central Rook is coordinating the native and specialist work."
    )
  }

  public static func centralHandoff(
    displayText: String = "Central Rook is deciding the best way to handle that."
  ) -> LocalRookDecision {
    decision(
      destination: .deliberate,
      displayText: displayText,
      spokenText: "Let me work out the right way to handle that.",
      intent: "brief"
    )
  }

  private static func decision(
    destination: LocalRookDestination,
    displayText: String,
    spokenText: String,
    intent: String
  ) -> LocalRookDecision {
    LocalRookDecision(
      destination: destination,
      response: QuickRookResponse(
        displayText: displayText,
        spokenText: spokenText,
        route: destination == .deliberate ? "deliberate" : "answer_now",
        intent: intent,
        pawns: []
      )
    )
  }

  private static func instantAnswer(for command: String) -> (display: String, spoken: String)? {
    let greetings: Set<String> = [
      "hi", "hello", "hey", "hey rook", "hello rook", "good morning", "good afternoon", "good evening",
    ]
    if greetings.contains(command) {
      return ("Hey—what’s up?", "Hey, what’s up?")
    }

    let thanks: Set<String> = ["thanks", "thank you", "thanks rook", "thank you rook", "perfect", "great thanks"]
    if thanks.contains(command) {
      return ("Anytime.", "Anytime.")
    }

    let hearingChecks: Set<String> = [
      "can you hear me", "do you hear me", "are you listening",
    ]
    if hearingChecks.contains(command) {
      return ("Yeah—I hear you.", "Yeah, I hear you.")
    }

    return nil
  }

  private static func normalize(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}
