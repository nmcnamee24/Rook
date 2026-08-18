import Foundation

public enum RookTaskStepState: String, Codable, Equatable, Sendable {
  case pending
  case running
  case succeeded
  case failed
  case blocked
  case skipped
}

/// A deliberately small, provider-safe receipt that may be supplied to a
/// dependent task. Raw provider payloads, credentials, and account identifiers
/// never enter this value.
public struct RookTaskStepEvidence: Codable, Equatable, Sendable {
  public let summary: String
  public let values: [String: String]

  public init(summary: String, values: [String: String] = [:]) {
    self.summary = summary
    self.values = values
  }
}

public struct RookTaskAdapterOutput: Equatable, Sendable {
  public let response: RookResponse
  public let verified: Bool
  public let evidence: RookTaskStepEvidence?

  public init(
    response: RookResponse,
    verified: Bool,
    evidence: RookTaskStepEvidence? = nil
  ) {
    self.response = response
    self.verified = verified
    self.evidence = evidence
  }
}

public struct RookTaskStepExecution: Equatable, Sendable {
  public let order: Int
  public let clause: String
  public let owner: RookHybridStepOwner
  public let capabilities: [RookDirectCapabilityID]
  public let dependsOn: [Int]
  public var state: RookTaskStepState
  public var attemptCount: Int
  public var verified: Bool
  public var response: RookResponse?
  public var evidence: RookTaskStepEvidence?
  public var failureCategory: RookFailureCategory?
  public var recovery: RookRecoveryDecision?
  public var detail: String

  public init(step: RookHybridPlanStep) {
    order = step.order
    clause = step.clause
    owner = step.owner
    capabilities = step.capabilities
    dependsOn = step.dependsOn
    state = .pending
    attemptCount = 0
    verified = false
    response = nil
    evidence = nil
    failureCategory = nil
    recovery = nil
    detail = ""
  }
}

public struct RookTaskExecutionResult: Equatable, Sendable {
  public let steps: [RookTaskStepExecution]

  public init(steps: [RookTaskStepExecution]) {
    self.steps = steps.sorted { $0.order < $1.order }
  }

  public var canStartDependentWork: Bool {
    let central = steps.filter { $0.owner == .central }
    let pawns = steps.filter { $0.owner == .pawnEligible }
    return !central.isEmpty
      && central.allSatisfy { $0.state == .succeeded }
      && pawns.contains { $0.state == .pending }
      && !pawns.contains { $0.state == .skipped || $0.state == .blocked || $0.state == .failed }
  }

  public var blockingStep: RookTaskStepExecution? {
    steps.first { $0.state == .blocked || $0.state == .failed }
  }

  public var verifiedEvidence: [RookTaskStepExecution] {
    steps.filter { $0.state == .succeeded && $0.verified && $0.evidence != nil }
  }

  public var latestNativeResponse: RookResponse? {
    steps.reversed().first { $0.owner == .central && $0.response != nil }?.response
  }

  /// Human-readable trusted context for central Rook. This is intentionally
  /// generated from bounded receipts rather than raw adapter payloads.
  public var promptContext: String {
    steps.map { step in
      var parts = [
        "Step \(step.order)",
        step.owner == .central ? "central" : "pawn-eligible",
        step.state.rawValue,
        "verified=\(step.verified)",
      ]
      if step.attemptCount > 0 { parts.append("attempts=\(step.attemptCount)") }
      if let failure = step.failureCategory { parts.append("failure=\(failure.rawValue)") }
      var line = "- \(parts.joined(separator: "; ")): \(Self.capped(step.clause, length: 240))"
      if let evidence = step.evidence {
        line += "\n  Receipt: \(Self.capped(evidence.summary, length: 300))"
        for key in evidence.values.keys.sorted() {
          guard let value = evidence.values[key], !value.isEmpty else { continue }
          line += "\n  \(Self.capped(key, length: 40)): \(Self.capped(value, length: 300))"
        }
      }
      return line
    }.joined(separator: "\n")
  }

  private static func capped(_ value: String, length: Int) -> String {
    let compact =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    guard compact.count > length else { return compact }
    return String(compact.prefix(max(0, length - 1))) + "…"
  }
}

public enum RookTaskStepEventKind: String, Equatable, Sendable {
  case started
  case retrying
  case succeeded
  case blocked
  case failed
  case skipped
  case ready
}

public struct RookTaskStepEvent: Equatable, Sendable {
  public let kind: RookTaskStepEventKind
  public let step: RookTaskStepExecution

  public init(kind: RookTaskStepEventKind, step: RookTaskStepExecution) {
    self.kind = kind
    self.step = step
  }
}

public enum RookSpotifyTaskStepResolution: Equatable, Sendable {
  case intent(RookSpotifyIntent)
  case clarification(String)
  case unsupported
}

/// Executes the native portion of an eligible hybrid plan before dependent
/// pawn work begins. The first implementation is intentionally restricted to
/// Spotify: unsupported central capabilities continue through the existing
/// central-Rook path rather than being guessed at here.
@MainActor
public final class RookTaskExecutor {
  public typealias SpotifyAdapter = @MainActor (RookSpotifyIntent) async throws -> RookTaskAdapterOutput
  public typealias EventHandler = @MainActor (RookTaskStepEvent) -> Void

  private let spotifyAdapter: SpotifyAdapter

  public init(spotifyAdapter: @escaping SpotifyAdapter) {
    self.spotifyAdapter = spotifyAdapter
  }

  public static func supports(_ plan: RookHybridCapabilityPlan) -> Bool {
    let centralSteps = plan.steps.filter { $0.owner == .central }
    guard !centralSteps.isEmpty,
      plan.steps.contains(where: { $0.owner == .pawnEligible }),
      centralSteps.allSatisfy({ Set($0.capabilities) == [.spotify] })
    else { return false }

    return centralSteps.allSatisfy {
      if case .unsupported = spotifyResolution(for: $0.clause) { return false }
      return true
    }
  }

  public static func spotifyResolution(for clause: String) -> RookSpotifyTaskStepResolution {
    if let exact = RookSpotifyCommandParser.parse(clause) { return .intent(exact) }
    switch RookSpotifySemanticResolver.resolve(clause) {
    case .intent(let intent): return .intent(intent)
    case .clarification(let message): return .clarification(message)
    case .notSpotify: return .unsupported
    }
  }

  public static func playbackStepOrder(in plan: RookHybridCapabilityPlan) -> Int? {
    plan.steps.first { step in
      guard step.owner == .central else { return false }
      guard case .intent(let intent) = spotifyResolution(for: step.clause) else { return false }
      return isPlaybackMutation(intent)
    }?.order
  }

  public func execute(
    _ plan: RookHybridCapabilityPlan,
    intentOverrides: [Int: RookSpotifyIntent] = [:],
    onEvent: EventHandler? = nil
  ) async -> RookTaskExecutionResult {
    var executions = plan.steps.map(RookTaskStepExecution.init)

    guard Self.supports(plan) else {
      for index in executions.indices where executions[index].owner == .central {
        executions[index].state = .failed
        executions[index].failureCategory = .adapterDeclined
        executions[index].recovery = RookRecoveryPolicy.decide(
          failure: .adapterDeclined,
          capability: executions[index].capabilities.first
        )
        executions[index].detail = "The native executor does not own this central capability."
        onEvent?(RookTaskStepEvent(kind: .failed, step: executions[index]))
      }
      finalizePawnDependencies(&executions, onEvent: onEvent)
      return RookTaskExecutionResult(steps: executions)
    }

    for index in executions.indices where executions[index].owner == .central {
      let missingDependency = executions[index].dependsOn.first { dependency in
        guard let prerequisite = executions.first(where: { $0.order == dependency }) else { return true }
        return prerequisite.state != .succeeded
      }
      if let missingDependency {
        executions[index].state = .skipped
        executions[index].failureCategory = .dependencyFailed
        executions[index].recovery = RookRecoveryPolicy.decide(
          failure: .dependencyFailed,
          capability: .spotify
        )
        executions[index].detail = "Prerequisite step \(missingDependency) did not succeed."
        onEvent?(RookTaskStepEvent(kind: .skipped, step: executions[index]))
        continue
      }

      let resolution =
        intentOverrides[executions[index].order].map(RookSpotifyTaskStepResolution.intent)
        ?? Self.spotifyResolution(for: executions[index].clause)
      switch resolution {
      case .unsupported:
        fail(
          index: index,
          state: .failed,
          category: .adapterDeclined,
          message: "The Spotify adapter could not resolve this step.",
          executions: &executions,
          onEvent: onEvent
        )
      case .clarification(let message):
        let response = Self.clarificationResponse(message)
        blockForClarification(
          index: index,
          response: response,
          executions: &executions,
          onEvent: onEvent
        )
      case .intent(let intent):
        await executeSpotify(
          intent,
          index: index,
          executions: &executions,
          onEvent: onEvent
        )
      }
    }

    finalizePawnDependencies(&executions, onEvent: onEvent)
    return RookTaskExecutionResult(steps: executions)
  }

  private func executeSpotify(
    _ intent: RookSpotifyIntent,
    index: Int,
    executions: inout [RookTaskStepExecution],
    onEvent: EventHandler?
  ) async {
    var retryAttempt = 0
    while true {
      executions[index].state = .running
      executions[index].attemptCount += 1
      executions[index].detail = intent.progressText
      onEvent?(RookTaskStepEvent(kind: .started, step: executions[index]))

      do {
        let output = try await spotifyAdapter(intent)
        if output.response.intent == "clarification" {
          blockForClarification(
            index: index,
            response: output.response,
            executions: &executions,
            onEvent: onEvent
          )
          return
        }

        let directlyFeedsPawn = executions.contains { step in
          step.owner == .pawnEligible && step.dependsOn.contains(executions[index].order)
        }
        if directlyFeedsPawn, !output.verified {
          fail(
            index: index,
            state: .failed,
            category: .verificationFailed,
            message: "The native Spotify outcome could not be verified for dependent work.",
            response: output.response,
            executions: &executions,
            onEvent: onEvent
          )
          return
        }

        executions[index].state = .succeeded
        executions[index].verified = output.verified
        executions[index].response = output.response
        executions[index].evidence = output.evidence
        executions[index].failureCategory = nil
        executions[index].recovery = nil
        executions[index].detail = output.verified ? "Native Spotify result verified." : "Spotify accepted the request."
        onEvent?(RookTaskStepEvent(kind: .succeeded, step: executions[index]))
        return
      } catch {
        let message = error.localizedDescription
        let category = RookFailureClassifier.classify(message)
        let recovery = RookRecoveryPolicy.decide(
          failure: category,
          capability: .spotify,
          attempt: retryAttempt
        )
        if recovery.action == .retrySameAdapter,
          retryAttempt < recovery.retryLimit,
          Self.isSafeReadRetry(intent)
        {
          executions[index].failureCategory = category
          executions[index].recovery = recovery
          executions[index].detail = message
          onEvent?(RookTaskStepEvent(kind: .retrying, step: executions[index]))
          retryAttempt += 1
          continue
        }

        let effectiveRecovery: RookRecoveryDecision
        if recovery.action == .retrySameAdapter, !Self.isSafeReadRetry(intent) {
          effectiveRecovery = RookRecoveryDecision(
            failure: category,
            action: .stop,
            retryLimit: 0,
            rationale: "Do not repeat a playback mutation when the provider outcome is uncertain."
          )
        } else {
          effectiveRecovery = recovery
        }
        fail(
          index: index,
          state: Self.blockingState(for: category),
          category: category,
          message: message,
          recovery: effectiveRecovery,
          executions: &executions,
          onEvent: onEvent
        )
        return
      }
    }
  }

  private func blockForClarification(
    index: Int,
    response: RookResponse,
    executions: inout [RookTaskStepExecution],
    onEvent: EventHandler?
  ) {
    executions[index].state = .blocked
    executions[index].verified = false
    executions[index].response = response
    executions[index].failureCategory = .ambiguity
    executions[index].recovery = RookRecoveryPolicy.decide(failure: .ambiguity, capability: .spotify)
    executions[index].detail = response.displayText
    onEvent?(RookTaskStepEvent(kind: .blocked, step: executions[index]))
  }

  private func fail(
    index: Int,
    state: RookTaskStepState,
    category: RookFailureCategory,
    message: String,
    response: RookResponse? = nil,
    recovery: RookRecoveryDecision? = nil,
    executions: inout [RookTaskStepExecution],
    onEvent: EventHandler?
  ) {
    executions[index].state = state
    executions[index].verified = false
    executions[index].response = response
    executions[index].failureCategory = category
    executions[index].recovery = recovery ?? RookRecoveryPolicy.decide(failure: category, capability: .spotify)
    executions[index].detail = message
    onEvent?(
      RookTaskStepEvent(
        kind: state == .blocked ? .blocked : .failed,
        step: executions[index]
      ))
  }

  private func finalizePawnDependencies(
    _ executions: inout [RookTaskStepExecution],
    onEvent: EventHandler?
  ) {
    for index in executions.indices where executions[index].owner == .pawnEligible {
      let missing = executions[index].dependsOn.first { dependency in
        guard let prerequisite = executions.first(where: { $0.order == dependency }) else { return true }
        return prerequisite.state != .succeeded || !prerequisite.verified
      }
      if let missing {
        executions[index].state = .skipped
        executions[index].failureCategory = .dependencyFailed
        executions[index].recovery = RookRecoveryPolicy.decide(
          failure: .dependencyFailed,
          capability: executions[index].capabilities.first
        )
        executions[index].detail = "Verified prerequisite step \(missing) is unavailable."
        onEvent?(RookTaskStepEvent(kind: .skipped, step: executions[index]))
      } else {
        onEvent?(RookTaskStepEvent(kind: .ready, step: executions[index]))
      }
    }
  }

  private static func clarificationResponse(_ message: String) -> RookResponse {
    RookResponse(
      displayText: message,
      spokenText: message,
      intent: "clarification",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
  }

  private static func blockingState(for category: RookFailureCategory) -> RookTaskStepState {
    switch category {
    case .ambiguity, .authentication, .permission, .policyBlocked:
      return .blocked
    default:
      return .failed
    }
  }

  private static func isSafeReadRetry(_ intent: RookSpotifyIntent) -> Bool {
    switch intent {
    case .choosePlaylist, .playlists, .recommendPlaylists, .recentlyPlayed, .top, .devices, .nowPlaying:
      return true
    case .resume, .pause, .next, .previous, .play, .playTopTracks, .playAnyPlaylist, .playForPurpose,
      .transferPlayback:
      return false
    }
  }

  private static func isPlaybackMutation(_ intent: RookSpotifyIntent) -> Bool {
    switch intent {
    case .resume, .pause, .next, .previous, .play, .playTopTracks, .playAnyPlaylist, .playForPurpose,
      .transferPlayback:
      return true
    case .choosePlaylist, .playlists, .recommendPlaylists, .recentlyPlayed, .top, .devices, .nowPlaying:
      return false
    }
  }
}
