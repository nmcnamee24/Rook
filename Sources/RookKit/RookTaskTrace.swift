import Dispatch
import Foundation

public enum RookTaskInputSource: String, Codable, Equatable, Sendable {
  case voice
  case typed
  case mobile
  case system
  case benchmark
  case unknown
}

public enum RookTaskTraceStage: String, Codable, Equatable, Sendable {
  case requestReceived = "request_received"
  case wakeDetected = "wake_detected"
  case firstTranscript = "first_transcript"
  case finalTranscript = "final_transcript"
  case stableIntent = "stable_intent"
  case promptRefined = "prompt_refined"
  case intentSelected = "intent_selected"
  case routeSelected = "route_selected"
  case adapterStarted = "adapter_started"
  case prewarmReady = "prewarm_ready"
  case externalOutcome = "external_outcome"
  case recoverySelected = "recovery_selected"
  case confirmation = "confirmation"
  case completed
}

public enum RookTaskTraceEventStatus: String, Codable, Equatable, Sendable {
  case started
  case succeeded
  case failed
  case clarified
  case blocked
  case informational
}

public enum RookTaskOutcomeStatus: String, Codable, Equatable, Sendable {
  case succeeded
  case failed
  case clarified
  case blocked
  case cancelled
}

public enum RookFailureCategory: String, Codable, Equatable, Sendable {
  case ambiguity
  case authentication
  case permission
  case providerUnavailable = "provider_unavailable"
  case timeout
  case rateLimited = "rate_limited"
  case adapterDeclined = "adapter_declined"
  case policyBlocked = "policy_blocked"
  case dependencyFailed = "dependency_failed"
  case executionFailed = "execution_failed"
  case verificationFailed = "verification_failed"
  case unknown
}

public enum RookRecoveryAction: String, Codable, Equatable, Sendable {
  case clarify
  case requestSetup = "request_setup"
  case retrySameAdapter = "retry_same_adapter"
  case awaitApproval = "await_approval"
  case escalateDeliberation = "escalate_deliberation"
  case stop
}

public struct RookRecoveryDecision: Codable, Equatable, Sendable {
  public let failure: RookFailureCategory
  public let action: RookRecoveryAction
  public let retryLimit: Int
  public let rationale: String

  public init(
    failure: RookFailureCategory,
    action: RookRecoveryAction,
    retryLimit: Int,
    rationale: String
  ) {
    self.failure = failure
    self.action = action
    self.retryLimit = retryLimit
    self.rationale = rationale
  }
}

public struct RookTaskTraceEvent: Codable, Equatable, Sendable {
  public let sequence: Int
  public let stage: RookTaskTraceStage
  public let status: RookTaskTraceEventStatus
  public let elapsedMilliseconds: Double
  public let occurredAt: Date
  public let component: String
  public let detail: String
  public let metadata: [String: String]

  public init(
    sequence: Int,
    stage: RookTaskTraceStage,
    status: RookTaskTraceEventStatus,
    elapsedMilliseconds: Double,
    occurredAt: Date,
    component: String,
    detail: String,
    metadata: [String: String]
  ) {
    self.sequence = sequence
    self.stage = stage
    self.status = status
    self.elapsedMilliseconds = elapsedMilliseconds
    self.occurredAt = occurredAt
    self.component = component
    self.detail = detail
    self.metadata = metadata
  }
}

public struct RookTaskTrace: Codable, Equatable, Sendable {
  public static let schemaVersion = 1

  public let schemaVersion: Int
  public let requestID: UUID
  public var source: RookTaskInputSource
  public let startedAt: Date
  public var command: String
  public var effectiveCommand: String
  public var route: String
  public var adapter: String
  public var outcome: RookTaskOutcomeStatus?
  public var verified: Bool?
  public var failureCategory: RookFailureCategory?
  public var events: [RookTaskTraceEvent]

  public init(
    requestID: UUID,
    source: RookTaskInputSource,
    startedAt: Date,
    command: String = ""
  ) {
    schemaVersion = Self.schemaVersion
    self.requestID = requestID
    self.source = source
    self.startedAt = startedAt
    self.command = command
    effectiveCommand = ""
    route = ""
    adapter = ""
    outcome = nil
    verified = nil
    failureCategory = nil
    events = []
  }

  public var elapsedToOutcomeMilliseconds: Double? {
    events.last(where: { $0.stage == .externalOutcome || $0.stage == .completed })?
      .elapsedMilliseconds
  }
}

public struct RookTaskTraceSignal: Equatable, Sendable {
  public let requestID: UUID
  public let source: RookTaskInputSource
  public let stage: RookTaskTraceStage
  public let status: RookTaskTraceEventStatus
  public let detail: String
  public let metadata: [String: String]

  public init(
    requestID: UUID,
    source: RookTaskInputSource,
    stage: RookTaskTraceStage,
    status: RookTaskTraceEventStatus = .informational,
    detail: String = "",
    metadata: [String: String] = [:]
  ) {
    self.requestID = requestID
    self.source = source
    self.stage = stage
    self.status = status
    self.detail = detail
    self.metadata = metadata
  }
}

public final class RookTaskTraceRecorder: @unchecked Sendable {
  private struct ActiveTrace {
    var trace: RookTaskTrace
    let startedUptimeNanoseconds: UInt64
  }

  public let directoryURL: URL
  private let lock = NSLock()
  private var active: [UUID: ActiveTrace] = [:]

  public init(directoryURL: URL) throws {
    self.directoryURL = directoryURL
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
  }

  @discardableResult
  public func begin(
    id: UUID,
    source: RookTaskInputSource,
    command: String = "",
    at date: Date = Date(),
    uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) throws -> RookTaskTrace {
    let snapshot: RookTaskTrace
    lock.lock()
    if var existing = active[id] {
      if existing.trace.source == .unknown, source != .unknown { existing.trace.source = source }
      if existing.trace.command.isEmpty, !command.isEmpty { existing.trace.command = command }
      active[id] = existing
      snapshot = existing.trace
    } else {
      let trace = RookTaskTrace(requestID: id, source: source, startedAt: date, command: command)
      active[id] = ActiveTrace(trace: trace, startedUptimeNanoseconds: uptimeNanoseconds)
      snapshot = trace
    }
    lock.unlock()
    try persist(snapshot)
    return snapshot
  }

  public func ingest(_ signal: RookTaskTraceSignal) throws {
    _ = try begin(id: signal.requestID, source: signal.source)
    try record(
      id: signal.requestID,
      stage: signal.stage,
      status: signal.status,
      component: "voice",
      detail: signal.detail,
      metadata: signal.metadata
    )
  }

  public func record(
    id: UUID,
    stage: RookTaskTraceStage,
    status: RookTaskTraceEventStatus = .informational,
    component: String,
    detail: String = "",
    metadata: [String: String] = [:],
    command: String? = nil,
    effectiveCommand: String? = nil,
    route: String? = nil,
    adapter: String? = nil,
    at date: Date = Date(),
    uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) throws {
    let snapshot: RookTaskTrace
    lock.lock()
    var state =
      active[id]
      ?? ActiveTrace(
        trace: RookTaskTrace(requestID: id, source: .unknown, startedAt: date, command: command ?? ""),
        startedUptimeNanoseconds: uptimeNanoseconds
      )
    if let command, !command.isEmpty { state.trace.command = command }
    if let effectiveCommand, !effectiveCommand.isEmpty { state.trace.effectiveCommand = effectiveCommand }
    if let route, !route.isEmpty { state.trace.route = route }
    if let adapter, !adapter.isEmpty { state.trace.adapter = adapter }
    let elapsed = Self.elapsedMilliseconds(from: state.startedUptimeNanoseconds, to: uptimeNanoseconds)
    state.trace.events.append(
      RookTaskTraceEvent(
        sequence: state.trace.events.count + 1,
        stage: stage,
        status: status,
        elapsedMilliseconds: elapsed,
        occurredAt: date,
        component: component,
        detail: detail,
        metadata: metadata
      ))
    active[id] = state
    snapshot = state.trace
    lock.unlock()
    try persist(snapshot)
  }

  public func finish(
    id: UUID,
    outcome: RookTaskOutcomeStatus,
    verified: Bool,
    failureCategory: RookFailureCategory? = nil,
    detail: String = "",
    at date: Date = Date(),
    uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) throws {
    let snapshot: RookTaskTrace?
    lock.lock()
    guard var state = active[id] else {
      lock.unlock()
      return
    }
    state.trace.outcome = outcome
    state.trace.verified = verified
    state.trace.failureCategory = failureCategory
    let eventStatus: RookTaskTraceEventStatus
    switch outcome {
    case .succeeded: eventStatus = .succeeded
    case .clarified: eventStatus = .clarified
    case .blocked: eventStatus = .blocked
    case .failed, .cancelled: eventStatus = .failed
    }
    state.trace.events.append(
      RookTaskTraceEvent(
        sequence: state.trace.events.count + 1,
        stage: .completed,
        status: eventStatus,
        elapsedMilliseconds: Self.elapsedMilliseconds(from: state.startedUptimeNanoseconds, to: uptimeNanoseconds),
        occurredAt: date,
        component: "orchestrator",
        detail: detail,
        metadata: [:]
      ))
    snapshot = state.trace
    active.removeValue(forKey: id)
    lock.unlock()
    if let snapshot { try persist(snapshot) }
  }

  public func trace(id: UUID) throws -> RookTaskTrace? {
    lock.lock()
    let inMemory = active[id]?.trace
    lock.unlock()
    if let inMemory { return inMemory }
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try Self.decoder().decode(RookTaskTrace.self, from: Data(contentsOf: url))
  }

  public func recentTraces(limit: Int = 50) throws -> [RookTaskTrace] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    return
      urls
      .filter { $0.pathExtension == "json" }
      .compactMap { url -> (Date, RookTaskTrace)? in
        guard let trace = try? Self.decoder().decode(RookTaskTrace.self, from: Data(contentsOf: url)) else {
          return nil
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return (values?.contentModificationDate ?? trace.startedAt, trace)
      }
      .sorted { $0.0 > $1.0 }
      .prefix(max(0, limit))
      .map(\.1)
  }

  private func persist(_ trace: RookTaskTrace) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try RookConfig.writePrivate(try encoder.encode(trace), to: fileURL(for: trace.requestID))
  }

  private func fileURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent("\(id.uuidString.lowercased()).json")
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> Double {
    guard end >= start else { return 0 }
    return Double(end - start) / 1_000_000
  }
}

public enum RookFailureClassifier {
  public static func classify(_ rawMessage: String) -> RookFailureCategory {
    let message = rawMessage.lowercased()
    if containsAny(
      message,
      [
        "ambiguous", "which one", "which playlist", "more than one", "need one detail", "couldn't find",
        "couldn’t find",
      ]
    ) {
      return .ambiguity
    }
    if containsAny(
      message,
      ["not connected", "connect spotify", "sign in", "authentication", "unauthorized", "token expired"]
    ) {
      return .authentication
    }
    if containsAny(message, ["timeout", "timed out", "-10005"]) { return .timeout }
    if containsAny(message, ["permission", "not allowed", "access denied", "privacy & security"]) {
      return .permission
    }
    if containsAny(message, ["rate limit", "too many requests", "status 429"]) { return .rateLimited }
    if containsAny(message, ["approval", "policy", "blocked before", "requires confirmation"]) {
      return .policyBlocked
    }
    if containsAny(message, ["dependency", "prerequisite", "previous step", "upstream step"]) {
      return .dependencyFailed
    }
    if containsAny(message, ["declined", "unsupported", "not supported", "cannot handle directly"]) {
      return .adapterDeclined
    }
    if containsAny(message, ["could not verify", "not verified", "verification failed", "couldn't safely read"]) {
      return .verificationFailed
    }
    if containsAny(
      message,
      [
        "unavailable", "offline", "service failure", "server error", "no usable device", "playback device",
        "couldn't reach", "couldn’t reach", "rejected that request",
      ]
    ) {
      return .providerUnavailable
    }
    if containsAny(message, ["failed", "couldn't", "could not", "error"]) { return .executionFailed }
    return .unknown
  }

  private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
    candidates.contains(where: value.contains)
  }
}

public enum RookRecoveryPolicy {
  public static func decide(
    failure: RookFailureCategory,
    capability: RookDirectCapabilityID?,
    attempt: Int = 0
  ) -> RookRecoveryDecision {
    switch failure {
    case .ambiguity:
      return RookRecoveryDecision(
        failure: failure,
        action: .clarify,
        retryLimit: 0,
        rationale: "Ask for the smallest missing detail instead of guessing."
      )
    case .authentication, .permission:
      return RookRecoveryDecision(
        failure: failure,
        action: .requestSetup,
        retryLimit: 0,
        rationale: "Explain the exact local setup boundary; a pawn cannot repair credentials or permissions."
      )
    case .policyBlocked:
      return RookRecoveryDecision(
        failure: failure,
        action: .awaitApproval,
        retryLimit: 0,
        rationale: "Preserve the action boundary and wait for exact approval or handoff."
      )
    case .timeout, .providerUnavailable:
      if attempt == 0 {
        return RookRecoveryDecision(
          failure: failure,
          action: .retrySameAdapter,
          retryLimit: 1,
          rationale: "Retry the same authoritative adapter once before changing strategy."
        )
      }
      return RookRecoveryDecision(
        failure: failure,
        action: .escalateDeliberation,
        retryLimit: 1,
        rationale: "Diagnose the repeated provider failure without silently switching execution authority."
      )
    case .rateLimited:
      return RookRecoveryDecision(
        failure: failure,
        action: .stop,
        retryLimit: 0,
        rationale: "Respect the provider cooldown instead of making the rate limit worse."
      )
    case .adapterDeclined, .executionFailed, .verificationFailed, .unknown:
      let domain = capability?.rawValue ?? "unclaimed"
      return RookRecoveryDecision(
        failure: failure,
        action: .escalateDeliberation,
        retryLimit: 0,
        rationale: "Preserve the complete goal and diagnose the \(domain) failure before choosing another executor."
      )
    case .dependencyFailed:
      return RookRecoveryDecision(
        failure: failure,
        action: .stop,
        retryLimit: 0,
        rationale: "Do not run dependent work until its prerequisite has a verified result."
      )
    }
  }
}

public struct RookTaskTraceSummary: Codable, Equatable, Sendable {
  public let traceCount: Int
  public let completedCount: Int
  public let firstAttemptSuccessRate: Double
  public let verifiedFirstAttemptSuccessRate: Double
  public let retryCount: Int
  public let medianOutcomeMilliseconds: Double?
  public let p95OutcomeMilliseconds: Double?
  public let medianAdapterStartMilliseconds: Double?
  public let p95AdapterStartMilliseconds: Double?
  public let routes: [String: Int]
  public let failures: [String: Int]

  public init(traces: [RookTaskTrace]) {
    traceCount = traces.count
    let completed = traces.filter { $0.outcome != nil }
    completedCount = completed.count
    let firstAttemptSuccesses = completed.filter {
      $0.outcome == .succeeded && !Self.retried($0)
    }
    let verifiedFirstAttemptSuccesses = firstAttemptSuccesses.filter { $0.verified == true }
    firstAttemptSuccessRate =
      completed.isEmpty
      ? 0
      : Double(firstAttemptSuccesses.count) / Double(completed.count)
    verifiedFirstAttemptSuccessRate =
      completed.isEmpty
      ? 0
      : Double(verifiedFirstAttemptSuccesses.count) / Double(completed.count)
    retryCount = completed.filter(Self.retried).count
    let durations = completed.compactMap(\.elapsedToOutcomeMilliseconds).sorted()
    let adapterStarts = traces.compactMap(Self.adapterStartLatency).sorted()
    medianOutcomeMilliseconds = Self.percentile(durations, percentile: 0.5)
    p95OutcomeMilliseconds = Self.percentile(durations, percentile: 0.95)
    medianAdapterStartMilliseconds = Self.percentile(adapterStarts, percentile: 0.5)
    p95AdapterStartMilliseconds = Self.percentile(adapterStarts, percentile: 0.95)
    routes = Dictionary(grouping: traces.filter { !$0.route.isEmpty }, by: \.route).mapValues(\.count)
    failures = Dictionary(grouping: traces.compactMap(\.failureCategory), by: \.rawValue).mapValues(\.count)
  }

  private static func percentile(_ values: [Double], percentile: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let index = Int((Double(values.count - 1) * percentile).rounded(.up))
    return values[min(max(index, 0), values.count - 1)]
  }

  private static func retried(_ trace: RookTaskTrace) -> Bool {
    trace.events.contains { event in
      if event.stage == .recoverySelected,
        event.metadata["action"] == RookRecoveryAction.retrySameAdapter.rawValue
      {
        return true
      }
      if event.stage == .adapterStarted,
        let attempt = event.metadata["attempt"].flatMap(Int.init),
        attempt > 1
      {
        return true
      }
      return false
    }
  }

  private static func adapterStartLatency(_ trace: RookTaskTrace) -> Double? {
    let anchor =
      trace.events.first(where: { $0.stage == .stableIntent })
      ?? trace.events.first(where: { $0.stage == .finalTranscript })
    guard let anchor,
      let adapter = trace.events.first(where: {
        $0.stage == .adapterStarted && $0.elapsedMilliseconds >= anchor.elapsedMilliseconds
      })
    else { return nil }
    return max(0, adapter.elapsedMilliseconds - anchor.elapsedMilliseconds)
  }
}
