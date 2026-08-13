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

public enum LocalRookRouter {
  public static func route(_ command: String) -> LocalRookDecision {
    let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = normalize(cleaned)

    if let answer = instantAnswer(for: normalized) {
      return decision(
        destination: .instant,
        displayText: answer.display,
        spokenText: answer.spoken,
        intent: "answer"
      )
    }

    if needsDeliberation(normalized) {
      let pawns = pawnPlan(for: cleaned)
      let acknowledgment = acknowledgment(for: normalized)
      return decision(
        destination: .deliberate,
        displayText: acknowledgment.display,
        spokenText: acknowledgment.spoken,
        intent: intent(for: normalized),
        pawns: pawns
      )
    }

    return decision(
      destination: .stream,
      displayText: "Thinking…",
      spokenText: "Yeah—one sec.",
      intent: "answer"
    )
  }

  /// Called only after a command matched a known direct domain but its bounded
  /// adapter declined the request. At that point Rook deliberately escalates
  /// the intact command instead of silently treating it as an ordinary answer.
  public static func routeAfterDirectCapabilityMiss(
    _ command: String,
    capability: RookDirectCapabilityID
  ) -> LocalRookDecision {
    let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = normalize(cleaned)
    let title =
      RookDirectCapabilityGuide.cheatSheet.first(where: { $0.id == capability })?.title
      ?? "direct capability"
    return decision(
      destination: .deliberate,
      displayText: "The direct \(title) route couldn’t safely finish that, so I’m checking it more deeply.",
      spokenText: "The direct route couldn’t finish that, so I’m checking it more deeply.",
      intent: intent(for: normalized),
      pawns: pawnPlan(for: cleaned)
    )
  }

  /// Builds one deliberate request where central Rook owns native/computer
  /// steps and pawns are planned only for the remaining independent clauses.
  public static func routeHybrid(
    _ command: String,
    plan: RookHybridCapabilityPlan
  ) -> LocalRookDecision {
    let normalized = normalize(command)
    let capabilityTitles = plan.centralCapabilities.compactMap { capability in
      RookDirectCapabilityGuide.cheatSheet.first(where: { $0.id == capability })?.title
    }
    let title = capabilityTitles.isEmpty ? "the direct steps" : capabilityTitles.joined(separator: " and ")
    let pawnCommand = plan.pawnClauses.joined(separator: " and then ")
    let pawns = pawnPlan(for: pawnCommand)
    return decision(
      destination: .deliberate,
      displayText: "I’ll handle \(title) centrally and use a pawn crew for the independent work.",
      spokenText: "I’ll handle the direct steps and send pawns for the rest.",
      intent: intent(for: normalized),
      pawns: pawns
    )
  }

  private static func decision(
    destination: LocalRookDestination,
    displayText: String,
    spokenText: String,
    intent: String,
    pawns: [PawnPlan] = []
  ) -> LocalRookDecision {
    LocalRookDecision(
      destination: destination,
      response: QuickRookResponse(
        displayText: displayText,
        spokenText: spokenText,
        route: destination == .deliberate ? "deliberate" : "answer_now",
        intent: intent,
        pawns: pawns
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

    if containsAny(command, ["can you hear me", "do you hear me", "are you listening"]) {
      return ("Yeah—I hear you.", "Yeah, I hear you.")
    }

    if containsAny(command, ["what can you do", "what do you do", "how can you help"]) {
      let display =
        "I can answer questions immediately, then quietly deploy independent pawn crews for research, code, writing, Calendar, Gmail, and verification when the request needs real work."
      return (display, "I can answer quickly, then send real work to silent specialist crews when it helps.")
    }

    return nil
  }

  private static func needsDeliberation(_ command: String) -> Bool {
    let productWork =
      containsAny(
        command,
        [
          "app", "application", "website", "social media", "feature", "following system", "messaging system",
          "friend system",
        ]
      )
      && containsAny(
        command,
        ["add", "adding", "build", "building", "change", "create", "debug", "fix", "implement", "update", "work on"]
      )
    if productWork { return true }

    if containsAny(
      command,
      [
        "calendar", "schedule", "reschedule", "work block", "appointment", "meeting", "availability",
        "gmail", "inbox", "email", "send a message", "reply to", "draft a",
        "document", "meeting notes", "outline", "rewrite", "summarize this",
        "research", "look up", "find out", "compare", "recommend", "latest", "current", "news", "weather", "forecast",
        "temperature",
        "picture", "photo", "image", "diagram", "visualize", "flowchart",
        "safari", "chrome", "firefox", "arc browser", "spotify", "playlist", "browser", "computer", "screen",
        "click", "type into", "open app", "open the app", "launch app", "switch to", "play music", "pause music",
        "next track", "previous track", "close app", "quit app", "move window", "computer control",
        "code", "repository", "repo", "project", "file", "debug", "fix", "implement", "build", "deploy",
        "bug", "error", "link opening", "interrupted", "blocked", "pawn", "crew", "forge", "scribe", "steward",
        "auditor", "scout",
        "librarian", "library", "remember", "memory", "history", "last time", "previous", "previous task",
        "verify", "audit", "double check", "make sure", "conflict", "risk",
        "approve", "approval", "move item", "queue item", "complete item", "reject item",
        "create", "update", "change", "move my", "add to", "delete", "book", "purchase", "apply for",
        "what do i have", "what should i do", "what's next", "whats next", "my hike", "my location",
      ])
    {
      return true
    }

    let planningWords = ["plan", "organize", "prioritize", "strategy", "workflow"]
    if containsAny(command, planningWords), command.split(separator: " ").count >= 7 {
      return true
    }

    let separators = [" and then ", ", and ", ";", " also ", " plus "]
    return separators.filter(command.contains).count >= 2
  }

  private static func pawnPlan(for command: String) -> [PawnPlan] {
    let clauses = taskClauses(command)
    var counts: [String: Int] = [:]
    var plans: [PawnPlan] = []

    for clause in clauses {
      let normalized = normalize(clause)
      var roles: [String] = []

      if containsAny(
        normalized,
        [
          "calendar", "schedule", "reschedule", "work block", "appointment", "meeting", "availability", "gmail",
          "inbox", "email", "reply",
        ])
      {
        roles.append("Steward")
      }
      if containsAny(normalized, ["document", "notes", "outline", "write", "draft", "rewrite", "summary", "summarize"])
      {
        roles.append("Scribe")
      }
      if containsAny(
        normalized,
        [
          "code", "repository", "repo", "project", "file", "debug", "fix", "implement", "build", "deploy", "app", "bug",
          "error", "link opening", "forge",
        ])
      {
        roles.append("Forge")
      }
      if containsAny(
        normalized,
        [
          "research", "look up", "find", "compare", "recommend", "latest", "current", "news", "weather", "forecast",
          "temperature", "picture", "photo", "image", "diagram", "visualize", "flowchart", "location", "options",
          "context", "librarian", "library", "remember", "memory", "history", "last time", "previous", "previous task",
        ])
      {
        roles.append("Scout")
      }
      if containsAny(
        normalized,
        [
          "verify", "audit", "double check", "make sure", "conflict", "risk", "review", "approval", "approve", "delete",
          "purchase", "book", "apply", "interrupted", "blocked", "pawn", "crew", "auditor",
        ])
      {
        roles.append("Auditor")
      }
      if containsAny(
        normalized,
        [
          "safari", "chrome", "firefox", "arc browser", "spotify", "playlist", "browser", "computer", "screen", "click",
          "type into", "switch to", "close app", "quit app", "move window",
        ])
      {
        roles.append("Scout")
        roles.append("Auditor")
      }
      for role in roles.uniqued() {
        appendPlan(role: role, clause: clause, counts: &counts, plans: &plans)
      }
    }

    let normalized = normalize(command)
    let externalAction = containsAny(
      normalized,
      [
        "calendar", "schedule", "reschedule", "gmail", "email", "create", "update", "change", "move my", "add to",
        "delete", "book", "purchase", "apply for",
        "safari", "chrome", "firefox", "arc browser", "spotify", "playlist", "browser", "computer", "screen", "click",
        "type into", "open app", "launch app", "switch to", "close app", "quit app", "move window",
      ])
    if externalAction, !plans.contains(where: { $0.pawn == "Auditor" }) {
      appendPlan(
        role: "Auditor",
        clause: "verify the requested action, ambiguity, conflicts, and safety boundary",
        counts: &counts,
        plans: &plans
      )
    }

    if plans.isEmpty {
      appendPlan(role: "Scout", clause: command, counts: &counts, plans: &plans)
      appendPlan(role: "Auditor", clause: "verify the result and important assumptions", counts: &counts, plans: &plans)
    }

    return Array(plans.prefix(RookConfig.pawnCapacityPerPrompt))
  }

  private static func appendPlan(
    role: String,
    clause: String,
    counts: inout [String: Int],
    plans: inout [PawnPlan]
  ) {
    guard plans.count < RookConfig.pawnCapacityPerPrompt else { return }
    let compactTask =
      clause
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      .split(whereSeparator: \.isWhitespace)
      .prefix(22)
      .joined(separator: " ")
    guard !compactTask.isEmpty else { return }
    if plans.contains(where: { $0.pawn == role && normalize($0.task) == normalize(compactTask) }) { return }

    let key = role.lowercased()
    counts[key, default: 0] += 1
    plans.append(PawnPlan(pawn: role, task: compactTask, id: "\(key)_\(counts[key]!)"))
  }

  private static func taskClauses(_ command: String) -> [String] {
    let normalizedSeparators =
      command
      .replacingOccurrences(of: ";", with: "\n")
      .replacingOccurrences(of: ". ", with: "\n")
      .replacingOccurrences(of: ", and ", with: "\n", options: .caseInsensitive)
      .replacingOccurrences(of: " and then ", with: "\n", options: .caseInsensitive)
      .replacingOccurrences(of: " also ", with: "\n", options: .caseInsensitive)
      .replacingOccurrences(of: " plus ", with: "\n", options: .caseInsensitive)
    let pieces =
      normalizedSeparators
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return pieces.isEmpty ? [command] : pieces
  }

  private static func acknowledgment(for command: String) -> (display: String, spoken: String) {
    if containsAny(
      command,
      [
        "safari", "chrome", "firefox", "arc browser", "spotify", "playlist", "browser", "computer", "screen", "click",
        "type into", "open app", "launch app", "switch to", "close app", "quit app", "move window",
      ])
    {
      return ("I’m handling that on your Mac now.", "I’m handling that on your Mac now.")
    }
    if containsAny(command, ["calendar", "schedule", "meeting", "work block", "appointment"]) {
      return ("I’m checking the schedule and handling that now.", "I’m checking the schedule and handling that now.")
    }
    if containsAny(command, ["document", "notes", "outline", "write", "draft"]) {
      return ("I’m putting that together now.", "I’m putting that together now.")
    }
    if containsAny(command, ["code", "debug", "fix", "implement", "build", "deploy", "project", "repo"]) {
      return ("I’m working through that now.", "I’m working through that now.")
    }
    if containsAny(
      command,
      [
        "research", "look up", "find", "compare", "recommend", "latest", "weather", "forecast", "temperature",
        "picture", "photo", "image", "diagram", "visualize",
      ])
    {
      return ("I’m looking into that now.", "I’m looking into that now.")
    }
    return ("I’m on it.", "I’m on it.")
  }

  private static func intent(for command: String) -> String {
    if containsAny(command, ["approve", "approval", "reject", "complete item"]) { return "approval" }
    if containsAny(
      command,
      [
        "safari", "chrome", "firefox", "arc browser", "spotify", "playlist", "browser", "computer", "screen", "click",
        "type into", "open app", "launch app", "switch to", "close app", "quit app", "move window",
      ])
    {
      return "status"
    }
    if containsAny(command, ["draft", "write", "document", "notes"]) { return "draft" }
    if containsAny(command, ["plan", "schedule", "calendar", "work block"]) { return "plan" }
    return "brief"
  }

  private static func normalize(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: "[^a-z0-9']+", with: " ", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
    let words = Set(value.split(whereSeparator: \.isWhitespace).map(String.init))
    return needles.contains { needle in
      needle.contains(" ") || needle.contains("'")
        ? value.contains(needle)
        : words.contains(needle)
    }
  }
}

private extension Array where Element: Hashable {
  func uniqued() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}
