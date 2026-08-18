import Foundation

public enum RookFastPathGateStatus: String, Codable, Equatable, Sendable {
  case passed
  case failed
  case needsData = "needs_data"
}

public struct RookFastPathGate: Codable, Equatable, Sendable {
  public let id: String
  public let status: RookFastPathGateStatus
  public let detail: String

  public init(id: String, status: RookFastPathGateStatus, detail: String) {
    self.id = id
    self.status = status
    self.detail = detail
  }
}

public struct RookFastPathScenarioEvidence: Codable, Equatable, Sendable {
  public let scenarioID: String
  public let command: String
  public let liveTraceCount: Int
  public let completedTraceCount: Int
  public let firstAttemptSuccessRate: Double?
  public let verifiedFirstAttemptSuccessRate: Double?
  public let adapterStartSampleCount: Int
  public let maximumAdapterStartMilliseconds: Double?
  public let medianOutcomeMilliseconds: Double?
  public let forbiddenFallbackCount: Int
  public let manualSampleCount: Int
  public let manualMedianMilliseconds: Double?
  public let attentionAdvantage: Bool
  public let attentionNote: String?
  public let utilityPassed: Bool?
}

public struct RookFastPathReadinessReport: Codable, Equatable, Sendable {
  public static let minimumLiveRunsPerScenario = 100
  public static let minimumManualRunsPerScenario = 5
  public static let minimumStreamingPrewarmRuns = 20
  public static let maximumAdapterStartMilliseconds = 250.0
  public static let minimumFirstAttemptSuccessRate = 0.99

  public let generatedAt: Date
  public let passed: Bool
  public let gates: [RookFastPathGate]
  public let scenarios: [RookFastPathScenarioEvidence]
  public let streamingPrewarmTraceCount: Int

  public init(
    traces: [RookTaskTrace],
    baselines: [RookManualBaseline],
    routingReport: RookRoutingBenchmarkReport,
    generatedAt: Date = Date()
  ) {
    self.generatedAt = generatedAt
    let baselineByScenario = Dictionary(uniqueKeysWithValues: baselines.map { ($0.scenarioID, $0) })
    let fastResults = routingReport.results.filter(\.scenario.isFastPath)
    scenarios = fastResults.map { result in
      Self.evidence(
        for: result.scenario,
        traces: traces,
        baseline: baselineByScenario[result.scenario.id]
      )
    }
    streamingPrewarmTraceCount =
      traces
      .filter { trace in
        trace.events.contains(where: { $0.stage == .stableIntent })
          && trace.events.contains(where: {
            $0.stage == .adapterStarted && $0.metadata["execution"] == "private_prewarm"
          })
      }
      .count

    var computedGates: [RookFastPathGate] = []
    let routingFailures = fastResults.filter { !$0.passed }
    computedGates.append(
      RookFastPathGate(
        id: "deterministic_ownership",
        status: routingFailures.isEmpty ? .passed : .failed,
        detail: routingFailures.isEmpty
          ? "Every supported benchmark phrase stayed on its deterministic native route."
          : "\(routingFailures.count) deterministic routing scenario(s) failed."
      )
    )

    let hasEnoughLiveData = scenarios.allSatisfy {
      $0.completedTraceCount >= Self.minimumLiveRunsPerScenario
    }
    let forbiddenFallbacks = scenarios.reduce(0) { $0 + $1.forbiddenFallbackCount }
    computedGates.append(
      RookFastPathGate(
        id: "no_forbidden_fallback",
        status: forbiddenFallbacks > 0 ? .failed : (hasEnoughLiveData ? .passed : .needsData),
        detail: forbiddenFallbacks > 0
          ? "Observed \(forbiddenFallbacks) supported action(s) using Central Rook, pawns, or Computer Use."
          : Self.liveDataDetail(scenarios)
      )
    )

    let latencySamplesReady = scenarios.allSatisfy {
      $0.adapterStartSampleCount >= Self.minimumLiveRunsPerScenario
    }
    let latencyFailures = scenarios.filter {
      ($0.maximumAdapterStartMilliseconds ?? .infinity) > Self.maximumAdapterStartMilliseconds
        && $0.adapterStartSampleCount >= Self.minimumLiveRunsPerScenario
    }
    computedGates.append(
      RookFastPathGate(
        id: "adapter_start_250ms",
        status: !latencyFailures.isEmpty ? .failed : (latencySamplesReady ? .passed : .needsData),
        detail: !latencyFailures.isEmpty
          ? "\(latencyFailures.count) scenario(s) exceeded the 250 ms adapter-start target."
          : "Adapter-start evidence requires \(Self.minimumLiveRunsPerScenario) timed runs per fast-path scenario."
      )
    )

    let successSamplesReady = scenarios.allSatisfy {
      $0.completedTraceCount >= Self.minimumLiveRunsPerScenario
    }
    let successFailures = scenarios.filter {
      ($0.firstAttemptSuccessRate ?? 0) < Self.minimumFirstAttemptSuccessRate
        && $0.completedTraceCount >= Self.minimumLiveRunsPerScenario
    }
    computedGates.append(
      RookFastPathGate(
        id: "first_attempt_99pct",
        status: !successFailures.isEmpty ? .failed : (successSamplesReady ? .passed : .needsData),
        detail: !successFailures.isEmpty
          ? "\(successFailures.count) scenario(s) finished below 99% first-attempt success."
          : "First-attempt evidence requires \(Self.minimumLiveRunsPerScenario) completed runs per scenario."
      )
    )

    let verificationFailures = scenarios.filter {
      ($0.verifiedFirstAttemptSuccessRate ?? 0) < Self.minimumFirstAttemptSuccessRate
        && $0.completedTraceCount >= Self.minimumLiveRunsPerScenario
    }
    computedGates.append(
      RookFastPathGate(
        id: "verified_outcomes_99pct",
        status: !verificationFailures.isEmpty ? .failed : (successSamplesReady ? .passed : .needsData),
        detail: !verificationFailures.isEmpty
          ? "\(verificationFailures.count) scenario(s) finished below 99% verified first-attempt success."
          : "Verified-outcome evidence uses the same completed live-run minimum."
      )
    )

    let utilityFailures = scenarios.filter { $0.utilityPassed == false }
    let utilityReady = scenarios.allSatisfy { $0.utilityPassed != nil }
    computedGates.append(
      RookFastPathGate(
        id: "manual_utility_advantage",
        status: !utilityFailures.isEmpty ? .failed : (utilityReady ? .passed : .needsData),
        detail: !utilityFailures.isEmpty
          ? "\(utilityFailures.count) scenario(s) did not beat the manual median and have no recorded attention advantage."
          : "Each scenario needs \(Self.minimumManualRunsPerScenario) manual samples or an explicit attention-advantage note, plus sufficient live runs."
      )
    )

    computedGates.append(
      RookFastPathGate(
        id: "safe_streaming_prewarm",
        status: streamingPrewarmTraceCount >= Self.minimumStreamingPrewarmRuns ? .passed : .needsData,
        detail:
          "Observed \(streamingPrewarmTraceCount) of \(Self.minimumStreamingPrewarmRuns) "
          + "required side-effect-free stable-intent prewarms."
      )
    )

    gates = computedGates
    passed = computedGates.allSatisfy { $0.status == .passed }
  }

  private static func evidence(
    for scenario: RookRoutingBenchmarkScenario,
    traces: [RookTaskTrace],
    baseline: RookManualBaseline?
  ) -> RookFastPathScenarioEvidence {
    let matching = traces.filter { trace in
      let commandMatches =
        normalize(trace.effectiveCommand.isEmpty ? trace.command : trace.effectiveCommand)
        == normalize(scenario.command)
      let isEligibleBenchmark =
        trace.source != .benchmark
        || trace.events.contains(where: {
          $0.stage == .requestReceived && $0.metadata["warm_adapter_state"] == "true"
        })
      return commandMatches && isEligibleBenchmark
    }
    let completed = matching.filter { $0.outcome != nil }
    let firstAttemptSuccesses = completed.filter {
      $0.outcome == .succeeded && !retried($0)
    }
    let verifiedFirstAttemptSuccesses = firstAttemptSuccesses.filter { $0.verified == true }
    let latencies = matching.compactMap(adapterStartLatency).sorted()
    let outcomes = completed.compactMap(\.elapsedToOutcomeMilliseconds).sorted()
    let forbiddenFallbackCount = matching.filter {
      usesForbiddenFallback($0, scenario: scenario)
    }.count
    let manualSamples = baseline?.samplesMilliseconds.count ?? 0
    let manualMedian = baseline?.medianMilliseconds
    let outcomeMedian = percentile(outcomes, percentile: 0.5)
    let attentionAdvantage = baseline?.attentionAdvantage == true
    let utilityPassed: Bool?
    if attentionAdvantage, completed.count >= minimumLiveRunsPerScenario {
      utilityPassed = true
    } else if manualSamples >= minimumManualRunsPerScenario,
      completed.count >= minimumLiveRunsPerScenario,
      let manualMedian,
      let outcomeMedian
    {
      utilityPassed = outcomeMedian < manualMedian
    } else {
      utilityPassed = nil
    }

    return RookFastPathScenarioEvidence(
      scenarioID: scenario.id,
      command: scenario.command,
      liveTraceCount: matching.count,
      completedTraceCount: completed.count,
      firstAttemptSuccessRate: completed.isEmpty
        ? nil
        : Double(firstAttemptSuccesses.count) / Double(completed.count),
      verifiedFirstAttemptSuccessRate: completed.isEmpty
        ? nil
        : Double(verifiedFirstAttemptSuccesses.count) / Double(completed.count),
      adapterStartSampleCount: latencies.count,
      maximumAdapterStartMilliseconds: latencies.last,
      medianOutcomeMilliseconds: outcomeMedian,
      forbiddenFallbackCount: forbiddenFallbackCount,
      manualSampleCount: manualSamples,
      manualMedianMilliseconds: manualMedian,
      attentionAdvantage: attentionAdvantage,
      attentionNote: baseline?.attentionNote,
      utilityPassed: utilityPassed
    )
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

  private static func usesForbiddenFallback(
    _ trace: RookTaskTrace,
    scenario: RookRoutingBenchmarkScenario
  ) -> Bool {
    let allowedRoutes: Set<String>
    switch scenario.expectedRoute {
    case RookDirectCapabilityID.spotify.rawValue:
      allowedRoutes = ["spotify", "spotify_native", "computer_native"]
    case RookDirectCapabilityID.computerControl.rawValue:
      allowedRoutes = ["computer_control", "computer_native"]
    case RookDirectCapabilityID.reflex.rawValue:
      allowedRoutes = ["reflex", "reflex_native"]
    case RookDirectCapabilityID.weather.rawValue:
      allowedRoutes = ["weather", "weather_native"]
    default:
      allowedRoutes = [scenario.expectedRoute]
    }
    if !trace.route.isEmpty, !allowedRoutes.contains(trace.route) { return true }
    return trace.events.contains { event in
      event.metadata["computer_operator"] == "true"
        || event.component.lowercased().contains("computer_operator")
        || (event.metadata["pawn_count"].flatMap(Int.init) ?? 0) > 0
    }
  }

  private static func liveDataDetail(_ scenarios: [RookFastPathScenarioEvidence]) -> String {
    let counts = scenarios.map { "\($0.scenarioID)=\($0.completedTraceCount)" }
      .joined(separator: ", ")
    return
      "No forbidden fallback is recorded; live proof requires "
      + "\(minimumLiveRunsPerScenario) completed runs per scenario (\(counts))."
  }

  private static func normalize(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func percentile(_ values: [Double], percentile: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let index = Int((Double(values.count - 1) * percentile).rounded(.up))
    return values[min(max(index, 0), values.count - 1)]
  }
}
