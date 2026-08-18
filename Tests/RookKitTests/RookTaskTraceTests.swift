import Foundation
import XCTest

@testable import RookKit

final class RookTaskTraceTests: XCTestCase {
  func testTraceRecorderPersistsMonotonicRequestStages() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-trace-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = try RookTaskTraceRecorder(directoryURL: root)
    let id = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_786_577_031)

    try recorder.begin(
      id: id,
      source: .voice,
      at: startedAt,
      uptimeNanoseconds: 1_000_000_000
    )
    try recorder.record(
      id: id,
      stage: .wakeDetected,
      status: .succeeded,
      component: "voice",
      uptimeNanoseconds: 1_100_000_000
    )
    try recorder.record(
      id: id,
      stage: .routeSelected,
      status: .succeeded,
      component: "deliberator",
      detail: "spotify",
      route: "spotify_native",
      adapter: "spotify_web_api",
      uptimeNanoseconds: 1_250_000_000
    )
    try recorder.finish(
      id: id,
      outcome: .succeeded,
      verified: true,
      uptimeNanoseconds: 1_500_000_000
    )

    let trace = try XCTUnwrap(recorder.trace(id: id))
    XCTAssertEqual(trace.source, .voice)
    XCTAssertEqual(trace.route, "spotify_native")
    XCTAssertEqual(trace.adapter, "spotify_web_api")
    XCTAssertEqual(trace.outcome, .succeeded)
    XCTAssertEqual(trace.verified, true)
    XCTAssertEqual(trace.events.map(\.stage), [.wakeDetected, .routeSelected, .completed])
    XCTAssertEqual(trace.events.map(\.elapsedMilliseconds), [100, 250, 500])
    XCTAssertEqual(try recorder.recentTraces(limit: 1), [trace])
  }

  func testFailureClassificationDistinguishesTimeoutFromPermissionAndPolicy() {
    XCTAssertEqual(
      RookFailureClassifier.classify(
        "Computer Use says permission may be missing, but Sky returned -10005 timeoutReached."
      ),
      .timeout
    )
    XCTAssertEqual(
      RookFailureClassifier.classify("Accessibility permission was denied."),
      .permission
    )
    XCTAssertEqual(
      RookFailureClassifier.classify("The final send is blocked before approval."),
      .policyBlocked
    )
    XCTAssertEqual(
      RookFailureClassifier.classify("Open Spotify so Rook has a playback device to use."),
      .providerUnavailable
    )
    XCTAssertEqual(
      RookFailureClassifier.classify("Connect Spotify in Rook Allies, then try again."),
      .authentication
    )
    XCTAssertEqual(
      RookFailureClassifier.classify("I couldn’t find that playlist in Spotify."),
      .ambiguity
    )
    XCTAssertEqual(
      RookFailureClassifier.classify(
        "Spotify verification failed: the accepted playback command returned no readable playback device."
      ),
      .verificationFailed
    )
  }

  func testRecoveryPolicyRetriesAuthoritativeAdapterOnceThenDiagnoses() {
    XCTAssertEqual(
      RookRecoveryPolicy.decide(failure: .timeout, capability: .spotify, attempt: 0).action,
      .retrySameAdapter
    )
    XCTAssertEqual(
      RookRecoveryPolicy.decide(failure: .timeout, capability: .spotify, attempt: 1).action,
      .escalateDeliberation
    )
    XCTAssertEqual(
      RookRecoveryPolicy.decide(failure: .dependencyFailed, capability: .spotify).action,
      .stop
    )
    XCTAssertEqual(
      RookRecoveryPolicy.decide(failure: .rateLimited, capability: .spotify).action,
      .stop
    )
  }

  func testRoutingBenchmarkHandsSemanticSpotifyWorkToCentralRook() throws {
    let report = RookRoutingBenchmarkSuite.run()
    XCTAssertTrue(report.allPassed, report.results.flatMap(\.failures).joined(separator: "\n"))

    let spotify = try XCTUnwrap(
      report.results.first { $0.scenario.id == "spotify_dependent_artist_research" }
    )
    XCTAssertEqual(spotify.observation.route, "central_delegation")
    XCTAssertTrue(spotify.observation.capabilities.isEmpty)
    XCTAssertFalse(spotify.observation.usesComputerOperator)
    XCTAssertEqual(spotify.observation.dependentStepCount, 0)
  }

  func testManualBaselineStoreKeepsSamplesAndMedian() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-baseline-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = RookManualBaselineStore(url: root.appendingPathComponent("baselines.json"))

    _ = try store.record(scenarioID: "spotify_resume", milliseconds: 3_000)
    let result = try store.record(scenarioID: "spotify_resume", milliseconds: 2_000)

    XCTAssertEqual(result.samplesMilliseconds, [3_000, 2_000])
    XCTAssertEqual(result.medianMilliseconds, 2_500)
    XCTAssertEqual(try store.medians()["spotify_resume"], 2_500)
  }

  func testManualBaselineStoreRecordsAttentionAdvantage() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-attention-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = RookManualBaselineStore(url: root.appendingPathComponent("baselines.json"))

    let result = try store.recordAttentionAdvantage(
      scenarioID: "spotify_resume",
      note: "Starts playback hands-free while another app remains focused."
    )

    XCTAssertEqual(result.attentionAdvantage, true)
    XCTAssertEqual(
      result.attentionNote,
      "Starts playback hands-free while another app remains focused."
    )
  }

  func testFastPathReadinessPassesOnlyWithCompleteMeasuredEvidence() {
    let scenarios = RookRoutingBenchmarkSuite.defaults.filter(\.isFastPath)
    var traces: [RookTaskTrace] = []
    for scenario in scenarios {
      for sample in 0..<RookFastPathReadinessReport.minimumLiveRunsPerScenario {
        traces.append(
          successfulTrace(
            scenario: scenario,
            includesStreamingPrewarm: scenario.id == "reflex_calculation"
              && sample < RookFastPathReadinessReport.minimumStreamingPrewarmRuns
          )
        )
      }
    }
    let baselines = scenarios.map {
      RookManualBaseline(
        scenarioID: $0.id,
        samplesMilliseconds: Array(
          repeating: 1_000,
          count: RookFastPathReadinessReport.minimumManualRunsPerScenario
        )
      )
    }

    let report = RookFastPathReadinessReport(
      traces: traces,
      baselines: baselines,
      routingReport: RookRoutingBenchmarkSuite.run()
    )

    XCTAssertTrue(report.passed, report.gates.map { "\($0.id): \($0.status.rawValue)" }.joined(separator: "\n"))
    XCTAssertTrue(report.gates.allSatisfy { $0.status == .passed })
  }

  func testFastPathReadinessDoesNotTreatMissingDataAsPassing() {
    let report = RookFastPathReadinessReport(
      traces: [],
      baselines: [],
      routingReport: RookRoutingBenchmarkSuite.run()
    )

    XCTAssertFalse(report.passed)
    XCTAssertEqual(
      report.gates.first { $0.id == "deterministic_ownership" }?.status,
      .passed
    )
    XCTAssertEqual(
      report.gates.first { $0.id == "first_attempt_99pct" }?.status,
      .needsData
    )
  }

  func testAttentionAdvantageStillRequiresLiveEvidence() {
    let baselines = RookRoutingBenchmarkSuite.defaults.filter(\.isFastPath).map {
      RookManualBaseline(
        scenarioID: $0.id,
        samplesMilliseconds: [],
        attentionAdvantage: true,
        attentionNote: "The voice path keeps the current app focused."
      )
    }
    let report = RookFastPathReadinessReport(
      traces: [],
      baselines: baselines,
      routingReport: RookRoutingBenchmarkSuite.run()
    )

    XCTAssertEqual(
      report.gates.first { $0.id == "manual_utility_advantage" }?.status,
      .needsData
    )
  }

  func testTraceSummaryDoesNotCallARetryAFirstAttemptSuccess() {
    let scenario = RookRoutingBenchmarkSuite.defaults.first { $0.id == "reflex_calculation" }!
    let direct = successfulTrace(scenario: scenario, includesStreamingPrewarm: false)
    var retried = successfulTrace(scenario: scenario, includesStreamingPrewarm: false)
    retried.events.insert(
      event(
        sequence: 2,
        stage: .recoverySelected,
        elapsed: 110,
        metadata: ["action": RookRecoveryAction.retrySameAdapter.rawValue]
      ),
      at: 1
    )

    let summary = RookTaskTraceSummary(traces: [direct, retried])

    XCTAssertEqual(summary.firstAttemptSuccessRate, 0.5)
    XCTAssertEqual(summary.verifiedFirstAttemptSuccessRate, 0.5)
    XCTAssertEqual(summary.retryCount, 1)
    XCTAssertEqual(summary.medianAdapterStartMilliseconds, 20)
  }

  private func successfulTrace(
    scenario: RookRoutingBenchmarkScenario,
    includesStreamingPrewarm: Bool
  ) -> RookTaskTrace {
    var trace = RookTaskTrace(
      requestID: UUID(),
      source: .voice,
      startedAt: Date(timeIntervalSince1970: 1_786_577_031),
      command: scenario.command
    )
    trace.effectiveCommand = scenario.command
    trace.route = nativeRoute(for: scenario)
    trace.adapter = adapter(for: scenario)
    trace.outcome = .succeeded
    trace.verified = true
    var events: [RookTaskTraceEvent] = []
    if includesStreamingPrewarm {
      events.append(event(sequence: 1, stage: .stableIntent, elapsed: 100))
      events.append(
        event(
          sequence: 2,
          stage: .adapterStarted,
          elapsed: 120,
          metadata: ["execution": "private_prewarm"]
        )
      )
      events.append(event(sequence: 3, stage: .prewarmReady, elapsed: 125))
      events.append(event(sequence: 4, stage: .finalTranscript, elapsed: 300))
    } else {
      events.append(event(sequence: 1, stage: .finalTranscript, elapsed: 100))
      events.append(event(sequence: 2, stage: .adapterStarted, elapsed: 120))
    }
    events.append(event(sequence: events.count + 1, stage: .externalOutcome, elapsed: 450))
    events.append(event(sequence: events.count + 1, stage: .completed, elapsed: 500))
    trace.events = events
    return trace
  }

  private func nativeRoute(for scenario: RookRoutingBenchmarkScenario) -> String {
    switch scenario.expectedRoute {
    case RookDirectCapabilityID.spotify.rawValue: "spotify_native"
    case RookDirectCapabilityID.reflex.rawValue: "reflex_native"
    default: "computer_native"
    }
  }

  private func adapter(for scenario: RookRoutingBenchmarkScenario) -> String {
    switch scenario.expectedRoute {
    case RookDirectCapabilityID.spotify.rawValue: "spotify_web_api"
    case RookDirectCapabilityID.reflex.rawValue: "rook_reflex"
    default: "native_mac_controller"
    }
  }

  private func event(
    sequence: Int,
    stage: RookTaskTraceStage,
    elapsed: Double,
    metadata: [String: String] = [:]
  ) -> RookTaskTraceEvent {
    RookTaskTraceEvent(
      sequence: sequence,
      stage: stage,
      status: .succeeded,
      elapsedMilliseconds: elapsed,
      occurredAt: Date(timeIntervalSince1970: 1_786_577_031 + elapsed / 1_000),
      component: "test",
      detail: "",
      metadata: metadata
    )
  }
}
