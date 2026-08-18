import Dispatch
import Foundation
import RookKit

struct RookFastPathLiveRunReport: Codable {
  let requestID: UUID
  let scenarioID: String
  let route: String
  let adapter: String
  let succeeded: Bool
  let verified: Bool
  let outcomeMilliseconds: Double
}

enum RookFastPathLiveRunError: LocalizedError {
  case unknownScenario(String)
  case unsupportedResolution(String)

  var errorDescription: String? {
    switch self {
    case .unknownScenario(let scenario):
      "Unknown fast-path benchmark scenario: \(scenario)"
    case .unsupportedResolution(let scenario):
      "The current exact gate did not resolve \(scenario) to a runnable native adapter."
    }
  }
}

/// Runs one explicitly requested real native benchmark action and records it
/// through the same private trace contract used by the app. The caller chooses
/// each run; this harness never loops or generates repeated external actions.
@MainActor
final class RookFastPathLiveRunner {
  typealias Completion = (Result<RookFastPathLiveRunReport, Error>) -> Void

  private let recorder: RookTaskTraceRecorder
  private let computerController = RookComputerController()
  private let oauthCoordinator: RookOAuthCoordinator

  init(config: RookConfig) throws {
    recorder = try RookTaskTraceRecorder(directoryURL: config.tracesURL)
    oauthCoordinator = RookOAuthCoordinator(config: config)
  }

  func run(scenarioID: String, completion: @escaping Completion) {
    guard
      let scenario = RookRoutingBenchmarkSuite.defaults.first(where: {
        $0.id == scenarioID && $0.isFastPath
      })
    else {
      completion(.failure(RookFastPathLiveRunError.unknownScenario(scenarioID)))
      return
    }

    // Credential availability is part of the app's prewarmed connection
    // state. Resolve it before the timed request begins so this command measures
    // the documented warm-action contract rather than a cold Keychain lookup.
    let spotifyConnected =
      scenario.id == "spotify_resume"
      && oauthCoordinator.initialStatuses()[.spotify]?.phase == .connected

    let requestID = UUID()
    let started = DispatchTime.now().uptimeNanoseconds
    do {
      try recorder.begin(
        id: requestID,
        source: .benchmark,
        command: scenario.command,
        uptimeNanoseconds: started
      )
      try record(
        requestID,
        stage: .requestReceived,
        component: "fast_path_live_runner",
        detail: "One explicit live benchmark run started.",
        metadata: ["warm_adapter_state": "true"]
      )
      try record(
        requestID,
        stage: .finalTranscript,
        component: "benchmark_input",
        detail: "Benchmark command is stable and final."
      )
      let interpretation = RookInferenceLayer.interpret(scenario.command)
      let decision = RookInferenceLayer.decide(interpretation)
      let observation = RookRoutingBenchmarkSuite.observe(
        decision.resolution,
        command: interpretation.effectiveCommand
      )
      try record(
        requestID,
        stage: .intentSelected,
        component: "inference",
        detail: interpretation.basis.rawValue,
        effectiveCommand: interpretation.effectiveCommand
      )
      try record(
        requestID,
        stage: .routeSelected,
        component: "direct_capability_guide",
        detail: observation.route,
        metadata: [
          "capabilities": observation.capabilities.map(\.rawValue).joined(separator: ","),
          "computer_operator": String(observation.usesComputerOperator),
          "pawn_count": "0",
        ],
        route: observation.route
      )

      switch decision.resolution {
      case .reflex(let intent):
        let route = "reflex_native"
        let adapter = "rook_reflex"
        try adapterStarted(requestID, route: route, adapter: adapter)
        let validResult: Bool
        switch intent {
        case .calculation(let calculation):
          validResult = calculation.result != nil
        case .conversion(let conversion):
          validResult = conversion.result != nil
        default:
          throw RookFastPathLiveRunError.unsupportedResolution(scenarioID)
        }
        finish(
          validResult
            ? .success(true)
            : .failure(RookFastPathLiveRunError.unsupportedResolution(scenarioID)),
          requestID: requestID,
          scenarioID: scenarioID,
          route: route,
          adapter: adapter,
          started: started,
          completion: completion
        )

      case .computerControl(let intent):
        let route = "computer_native"
        let adapter = "native_mac_controller"
        try adapterStarted(requestID, route: route, adapter: adapter)
        computerController.execute(intent) { [weak self] result in
          self?.finish(
            result.map(\.verified),
            requestID: requestID,
            scenarioID: scenarioID,
            route: route,
            adapter: adapter,
            started: started,
            completion: completion
          )
        }

      case .spotify(let intent):
        runSpotify(
          intent,
          requestID: requestID,
          scenarioID: scenarioID,
          started: started,
          connected: spotifyConnected,
          completion: completion
        )

      default:
        throw RookFastPathLiveRunError.unsupportedResolution(scenarioID)
      }
    } catch {
      try? recorder.finish(
        id: requestID,
        outcome: .failed,
        verified: false,
        failureCategory: .executionFailed,
        detail: error.localizedDescription
      )
      completion(.failure(error))
    }
  }

  private func runSpotify(
    _ intent: RookSpotifyIntent,
    requestID: UUID,
    scenarioID: String,
    started: UInt64,
    connected: Bool,
    completion: @escaping Completion
  ) {
    if connected {
      let route = "spotify_native"
      let adapter = "spotify_web_api"
      do {
        try adapterStarted(requestID, route: route, adapter: adapter)
      } catch {
        completion(.failure(error))
        return
      }
      let oauthCoordinator = self.oauthCoordinator
      let client = RookSpotifyClient {
        try await oauthCoordinator.validAccessToken(for: .spotify)
      }
      Task { [weak self] in
        do {
          let output = try await client.executeForTask(intent)
          self?.finish(
            .success(output.verified),
            requestID: requestID,
            scenarioID: scenarioID,
            route: route,
            adapter: adapter,
            started: started,
            completion: completion
          )
        } catch {
          self?.finish(
            .failure(error),
            requestID: requestID,
            scenarioID: scenarioID,
            route: route,
            adapter: adapter,
            started: started,
            completion: completion
          )
        }
      }
      return
    }

    guard case .resume = intent else {
      completion(.failure(RookFastPathLiveRunError.unsupportedResolution(scenarioID)))
      return
    }
    let route = "computer_native"
    let adapter = "native_mac_controller"
    do {
      try adapterStarted(requestID, route: route, adapter: adapter)
    } catch {
      completion(.failure(error))
      return
    }
    computerController.execute(.spotify(.play)) { [weak self] result in
      self?.finish(
        result.map(\.verified),
        requestID: requestID,
        scenarioID: scenarioID,
        route: route,
        adapter: adapter,
        started: started,
        completion: completion
      )
    }
  }

  private func adapterStarted(_ id: UUID, route: String, adapter: String) throws {
    try record(
      id,
      stage: .adapterStarted,
      component: adapter,
      detail: "Live native adapter started.",
      route: route,
      adapter: adapter
    )
  }

  private func finish(
    _ result: Result<Bool, Error>,
    requestID: UUID,
    scenarioID: String,
    route: String,
    adapter: String,
    started: UInt64,
    completion: @escaping Completion
  ) {
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    switch result {
    case .success(let verified):
      try? record(
        requestID,
        stage: .externalOutcome,
        component: adapter,
        detail: verified ? "Live native outcome verified." : "Live native outcome accepted but unverified.",
        metadata: ["verified": String(verified)],
        route: route,
        adapter: adapter
      )
      try? recorder.finish(id: requestID, outcome: .succeeded, verified: verified)
      completion(
        .success(
          RookFastPathLiveRunReport(
            requestID: requestID,
            scenarioID: scenarioID,
            route: route,
            adapter: adapter,
            succeeded: true,
            verified: verified,
            outcomeMilliseconds: elapsed
          )
        )
      )
    case .failure(let error):
      let category = RookFailureClassifier.classify(error.localizedDescription)
      try? record(
        requestID,
        stage: .externalOutcome,
        status: .failed,
        component: adapter,
        detail: error.localizedDescription,
        metadata: ["verified": "false"],
        route: route,
        adapter: adapter
      )
      try? recorder.finish(
        id: requestID,
        outcome: .failed,
        verified: false,
        failureCategory: category,
        detail: error.localizedDescription
      )
      completion(.failure(error))
    }
  }

  private func record(
    _ id: UUID,
    stage: RookTaskTraceStage,
    status: RookTaskTraceEventStatus = .succeeded,
    component: String,
    detail: String,
    metadata: [String: String] = [:],
    effectiveCommand: String? = nil,
    route: String? = nil,
    adapter: String? = nil
  ) throws {
    try recorder.record(
      id: id,
      stage: stage,
      status: status,
      component: component,
      detail: detail,
      metadata: metadata,
      effectiveCommand: effectiveCommand,
      route: route,
      adapter: adapter
    )
  }
}
