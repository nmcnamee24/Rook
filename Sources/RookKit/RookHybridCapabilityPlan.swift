import Foundation

public enum RookHybridStepOwner: String, Equatable, Sendable {
  case central
  case pawnEligible = "pawn_eligible"
}

public struct RookHybridPlanStep: Equatable, Sendable {
  public let order: Int
  public let clause: String
  public let capabilities: [RookDirectCapabilityID]
  public let owner: RookHybridStepOwner
  public let dependsOn: [Int]

  public init(
    order: Int,
    clause: String,
    capabilities: [RookDirectCapabilityID],
    owner: RookHybridStepOwner,
    dependsOn: [Int] = []
  ) {
    self.order = order
    self.clause = clause
    self.capabilities = capabilities
    self.owner = owner
    self.dependsOn = dependsOn
  }
}

public struct RookHybridCapabilityPlan: Equatable, Sendable {
  public let steps: [RookHybridPlanStep]

  public init(steps: [RookHybridPlanStep]) {
    self.steps = steps
  }

  public var centralCapabilities: [RookDirectCapabilityID] {
    var seen = Set<RookDirectCapabilityID>()
    return
      steps
      .filter { $0.owner == .central }
      .flatMap(\.capabilities)
      .filter { seen.insert($0).inserted }
  }

  public var pawnClauses: [String] {
    steps.filter { $0.owner == .pawnEligible }.map(\.clause)
  }

  public var requiresComputerOperator: Bool {
    centralCapabilities.contains(.computerControl)
      || centralCapabilities.contains(.screenCapture)
  }

  /// Inspectable ownership contracts for every native capability in this
  /// plan. Central Rook may use these contracts when it resumes reviewed
  /// hybrid work, while unsupported execution still remains with Central.
  public var executionContracts: [RookCapabilityExecutionContract] {
    centralCapabilities.map(RookDirectCapabilityGuide.executionContract(for:))
  }
}

/// Recognizes compound requests that intentionally combine a central-only
/// native capability with independent work suitable for a pawn. It never
/// executes a clause; it preserves ordered ownership for central Rook.
public enum RookHybridCapabilityPlanner {
  public static func plan(_ rawCommand: String) -> RookHybridCapabilityPlan? {
    let clauses = splitClauses(rawCommand)
    guard clauses.count >= 2 else { return nil }

    let preliminary = clauses.enumerated().map { index, clause in
      let capabilities = capabilities(in: clause)
      return RookHybridPlanStep(
        order: index + 1,
        clause: clause,
        capabilities: capabilities,
        owner: capabilities.isEmpty ? .pawnEligible : .central
      )
    }
    let containsSpotifyOperation = preliminary.contains {
      $0.capabilities.contains(.spotify) && !isSpotifyLaunchClause($0.clause)
    }
    let reassigned = preliminary.map { step in
      guard containsSpotifyOperation, isSpotifyLaunchClause(step.clause) else { return step }
      return RookHybridPlanStep(
        order: step.order,
        clause: step.clause,
        capabilities: [.spotify],
        owner: .central
      )
    }
    let steps = reassigned.map { step in
      RookHybridPlanStep(
        order: step.order,
        clause: step.clause,
        capabilities: step.capabilities,
        owner: step.owner,
        dependsOn: dependencies(for: step, in: reassigned)
      )
    }
    guard steps.contains(where: { $0.owner == .central }),
      steps.contains(where: { $0.owner == .pawnEligible })
    else { return nil }
    return RookHybridCapabilityPlan(steps: steps)
  }

  private static func dependencies(
    for step: RookHybridPlanStep,
    in steps: [RookHybridPlanStep]
  ) -> [Int] {
    guard step.order > 1 else { return [] }
    let lower = step.clause.lowercased()
    let observesPlayback =
      step.capabilities.contains(.spotify)
      && containsAny(lower, ["playing", "current song", "current track", "now playing"])
    let refersToPlaybackResult = containsAny(
      lower,
      ["the artist", "the song", "the track", "artist playing", "song playing", "track playing"]
    )
    guard observesPlayback || refersToPlaybackResult else { return [] }
    return steps.reversed().first {
      $0.order < step.order && $0.capabilities.contains(.spotify)
    }.map { [$0.order] } ?? []
  }

  private static func isSpotifyLaunchClause(_ clause: String) -> Bool {
    let normalized = clause.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ["open spotify", "launch spotify", "switch to spotify", "bring up spotify"].contains(normalized)
  }

  private static func capabilities(in clause: String) -> [RookDirectCapabilityID] {
    var result: [RookDirectCapabilityID] = []
    if RookReflexCommandParser.parse(clause) != nil { result.append(.reflex) }
    if RookWeatherCommandParser.parse(clause) != nil {
      result.append(.weather)
    } else if case .request = RookWeatherSemanticResolver.resolve(clause) {
      result.append(.weather)
    }
    if RookSpotifyCommandParser.parse(clause) != nil {
      result.append(.spotify)
    } else {
      switch RookSpotifySemanticResolver.resolve(clause) {
      case .intent, .clarification:
        result.append(.spotify)
      case .notSpotify:
        break
      }
    }
    if RookScreenCaptureCommandParser.parse(clause) != nil {
      result.append(.screenCapture)
    }
    if RookComputerCommandParser.parse(clause) != nil
      || RookComputerOperatorRouting.requiresComputerUse(clause)
    {
      result.append(.computerControl)
    }
    var seen = Set<RookDirectCapabilityID>()
    return result.filter { seen.insert($0).inserted }
  }

  private static func splitClauses(_ rawCommand: String) -> [String] {
    let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty else { return [] }
    let action =
      #"research|look\s+up|find\s+out|compare|verify|audit|analy[sz]e|summarize|explain|recommend|investigate|check|inspect|open|launch|click|type|search|play|pause|send|draft|write|create|update|fix|build|test|review|ask|have|use|tell"#
    let pattern = #"(?i)\s*(?:;|\band\s+then\b|\bthen\b|\balso\b|\bplus\b|\band(?=\s+(?:"# + action + #")\b))\s*"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [command] }
    let matches = expression.matches(in: command, range: NSRange(command.startIndex..., in: command))
    guard !matches.isEmpty else { return [command] }

    var clauses: [String] = []
    var cursor = command.startIndex
    for match in matches {
      guard let range = Range(match.range, in: command) else { continue }
      let clause = String(command[cursor..<range.lowerBound])
        .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      if !clause.isEmpty { clauses.append(clause) }
      cursor = range.upperBound
    }
    let remainder = String(command[cursor...])
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    if !remainder.isEmpty { clauses.append(remainder) }
    return clauses
  }

  private static func containsAny(_ value: String, _ phrases: [String]) -> Bool {
    phrases.contains(where: value.contains)
  }
}
