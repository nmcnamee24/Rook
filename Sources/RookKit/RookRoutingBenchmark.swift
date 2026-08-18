import Dispatch
import Foundation

public struct RookRoutingBenchmarkScenario: Codable, Equatable, Sendable {
  public let id: String
  public let command: String
  public let expectedRoute: String
  public let requiredCapabilities: [RookDirectCapabilityID]
  public let forbiddenCapabilities: [RookDirectCapabilityID]
  public let forbidsComputerOperator: Bool
  public let minimumDependentSteps: Int
  public let isFastPath: Bool
  public let maximumRoutingMilliseconds: Double?

  public init(
    id: String,
    command: String,
    expectedRoute: String,
    requiredCapabilities: [RookDirectCapabilityID] = [],
    forbiddenCapabilities: [RookDirectCapabilityID] = [],
    forbidsComputerOperator: Bool = false,
    minimumDependentSteps: Int = 0,
    isFastPath: Bool = false,
    maximumRoutingMilliseconds: Double? = nil
  ) {
    self.id = id
    self.command = command
    self.expectedRoute = expectedRoute
    self.requiredCapabilities = requiredCapabilities
    self.forbiddenCapabilities = forbiddenCapabilities
    self.forbidsComputerOperator = forbidsComputerOperator
    self.minimumDependentSteps = minimumDependentSteps
    self.isFastPath = isFastPath
    self.maximumRoutingMilliseconds = maximumRoutingMilliseconds
  }
}

public struct RookRoutingObservation: Codable, Equatable, Sendable {
  public let route: String
  public let capabilities: [RookDirectCapabilityID]
  public let usesComputerOperator: Bool
  public let dependentStepCount: Int
  public let stepSummary: [String]

  public init(
    route: String,
    capabilities: [RookDirectCapabilityID],
    usesComputerOperator: Bool,
    dependentStepCount: Int,
    stepSummary: [String]
  ) {
    self.route = route
    self.capabilities = capabilities
    self.usesComputerOperator = usesComputerOperator
    self.dependentStepCount = dependentStepCount
    self.stepSummary = stepSummary
  }
}

public struct RookRoutingBenchmarkResult: Codable, Equatable, Sendable {
  public let scenario: RookRoutingBenchmarkScenario
  public let observation: RookRoutingObservation
  public let passed: Bool
  public let failures: [String]
  public let routingMilliseconds: Double
  public let manualBaselineMilliseconds: Double?
}

public struct RookRoutingBenchmarkReport: Codable, Equatable, Sendable {
  public let generatedAt: Date
  public let results: [RookRoutingBenchmarkResult]

  public var allPassed: Bool { results.allSatisfy(\.passed) }
  public var passedCount: Int { results.filter(\.passed).count }

  public init(generatedAt: Date = Date(), results: [RookRoutingBenchmarkResult]) {
    self.generatedAt = generatedAt
    self.results = results
  }
}

public enum RookRoutingBenchmarkSuite {
  public static let defaults: [RookRoutingBenchmarkScenario] = [
    RookRoutingBenchmarkScenario(
      id: "spotify_resume",
      command: "Play my Spotify",
      expectedRoute: RookDirectCapabilityID.spotify.rawValue,
      requiredCapabilities: [.spotify],
      forbiddenCapabilities: [.computerControl],
      forbidsComputerOperator: true,
      isFastPath: true,
      maximumRoutingMilliseconds: 250
    ),
    RookRoutingBenchmarkScenario(
      id: "safari_destination",
      command: "Open Safari and go to https://example.com",
      expectedRoute: RookDirectCapabilityID.computerControl.rawValue,
      requiredCapabilities: [.computerControl],
      forbidsComputerOperator: true,
      isFastPath: true,
      maximumRoutingMilliseconds: 250
    ),
    RookRoutingBenchmarkScenario(
      id: "app_launch",
      command: "Open Notes",
      expectedRoute: RookDirectCapabilityID.computerControl.rawValue,
      requiredCapabilities: [.computerControl],
      forbidsComputerOperator: true,
      isFastPath: true,
      maximumRoutingMilliseconds: 250
    ),
    RookRoutingBenchmarkScenario(
      id: "spotify_dependent_artist_research",
      command: "Open Spotify, play a playlist, and tell me about the song that's playing and research the artist.",
      expectedRoute: "central_delegation",
      forbiddenCapabilities: [.computerControl],
      forbidsComputerOperator: true
    ),
    RookRoutingBenchmarkScenario(
      id: "coding_handoff",
      command: "Fix the failing tests in this project and verify the result.",
      expectedRoute: "central_delegation"
    ),
    RookRoutingBenchmarkScenario(
      id: "reflex_calculation",
      command: "What is 15 percent of 240?",
      expectedRoute: RookDirectCapabilityID.reflex.rawValue,
      requiredCapabilities: [.reflex],
      forbidsComputerOperator: true,
      isFastPath: true,
      maximumRoutingMilliseconds: 250
    ),
  ]

  public static func run(
    scenarios: [RookRoutingBenchmarkScenario] = defaults,
    manualBaselines: [String: Double] = [:]
  ) -> RookRoutingBenchmarkReport {
    let results = scenarios.map { scenario in
      let started = DispatchTime.now().uptimeNanoseconds
      let interpretation = RookInferenceLayer.interpret(scenario.command)
      let decision = RookInferenceLayer.decide(interpretation)
      let observation = observe(decision.resolution, command: interpretation.effectiveCommand)
      let finished = DispatchTime.now().uptimeNanoseconds
      let routingMilliseconds = Double(finished - started) / 1_000_000
      var failures: [String] = []
      if observation.route != scenario.expectedRoute {
        failures.append("Expected route \(scenario.expectedRoute), observed \(observation.route).")
      }
      for capability in scenario.requiredCapabilities where !observation.capabilities.contains(capability) {
        failures.append("Missing required capability \(capability.rawValue).")
      }
      for capability in scenario.forbiddenCapabilities where observation.capabilities.contains(capability) {
        failures.append("Used forbidden capability \(capability.rawValue).")
      }
      if scenario.forbidsComputerOperator, observation.usesComputerOperator {
        failures.append("Selected Computer Operator for a benchmark that forbids it.")
      }
      if observation.dependentStepCount < scenario.minimumDependentSteps {
        failures.append(
          "Expected at least \(scenario.minimumDependentSteps) dependent steps, observed \(observation.dependentStepCount)."
        )
      }
      if let maximum = scenario.maximumRoutingMilliseconds,
        routingMilliseconds > maximum
      {
        let measured = String(format: "%.3f", routingMilliseconds)
        let target = String(format: "%.0f", maximum)
        failures.append(
          "Routing took \(measured) ms; maximum is \(target) ms."
        )
      }
      return RookRoutingBenchmarkResult(
        scenario: scenario,
        observation: observation,
        passed: failures.isEmpty,
        failures: failures,
        routingMilliseconds: routingMilliseconds,
        manualBaselineMilliseconds: manualBaselines[scenario.id]
      )
    }
    return RookRoutingBenchmarkReport(results: results)
  }

  public static func observe(
    _ resolution: RookDirectCapabilityResolution,
    command: String
  ) -> RookRoutingObservation {
    switch resolution {
    case .reflex:
      return direct(.reflex)
    case .weather:
      return direct(.weather)
    case .spotify:
      return direct(.spotify)
    case .screenCapture:
      return direct(.screenCapture)
    case .computerControl:
      return direct(.computerControl)
    case .librarianCheckpoint:
      return direct(.librarianCheckpoint)
    case .hybrid(let plan):
      return RookRoutingObservation(
        route: "hybrid",
        capabilities: plan.centralCapabilities,
        usesComputerOperator: plan.requiresComputerOperator,
        dependentStepCount: plan.steps.filter { !$0.dependsOn.isEmpty }.count,
        stepSummary: plan.steps.map { step in
          let dependency =
            step.dependsOn.isEmpty
            ? "independent"
            : "after \(step.dependsOn.map(String.init).joined(separator: ","))"
          return "\(step.order):\(step.owner.rawValue):\(dependency):\(step.clause)"
        }
      )
    case .clarification(let capability, _):
      return RookRoutingObservation(
        route: "clarification",
        capabilities: [capability],
        usesComputerOperator: false,
        dependentStepCount: 0,
        stepSummary: []
      )
    case .fallThrough(let capability):
      return RookRoutingObservation(
        route: "central_delegation",
        capabilities: [capability],
        usesComputerOperator: false,
        dependentStepCount: 0,
        stepSummary: []
      )
    case .unclaimed:
      return RookRoutingObservation(
        route: "central_delegation",
        capabilities: [],
        usesComputerOperator: false,
        dependentStepCount: 0,
        stepSummary: []
      )
    }
  }

  private static func direct(_ capability: RookDirectCapabilityID) -> RookRoutingObservation {
    RookRoutingObservation(
      route: capability.rawValue,
      capabilities: [capability],
      usesComputerOperator: false,
      dependentStepCount: 0,
      stepSummary: []
    )
  }
}

public struct RookManualBaseline: Codable, Equatable, Sendable {
  public let scenarioID: String
  public var samplesMilliseconds: [Double]
  public var attentionAdvantage: Bool?
  public var attentionNote: String?

  public init(
    scenarioID: String,
    samplesMilliseconds: [Double],
    attentionAdvantage: Bool? = nil,
    attentionNote: String? = nil
  ) {
    self.scenarioID = scenarioID
    self.samplesMilliseconds = samplesMilliseconds
    self.attentionAdvantage = attentionAdvantage
    self.attentionNote = attentionNote
  }

  public var medianMilliseconds: Double? {
    let values = samplesMilliseconds.sorted()
    guard !values.isEmpty else { return nil }
    if values.count.isMultiple(of: 2) {
      return (values[values.count / 2 - 1] + values[values.count / 2]) / 2
    }
    return values[values.count / 2]
  }
}

public final class RookManualBaselineStore {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func record(scenarioID: String, milliseconds: Double) throws -> RookManualBaseline {
    guard milliseconds > 0, milliseconds.isFinite else {
      throw RookManualBaselineError.invalidDuration
    }
    var records = try load()
    if let index = records.firstIndex(where: { $0.scenarioID == scenarioID }) {
      records[index].samplesMilliseconds.append(milliseconds)
    } else {
      records.append(RookManualBaseline(scenarioID: scenarioID, samplesMilliseconds: [milliseconds]))
    }
    records.sort { $0.scenarioID < $1.scenarioID }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try RookConfig.writePrivate(try encoder.encode(records), to: url)
    return records.first(where: { $0.scenarioID == scenarioID })!
  }

  public func recordAttentionAdvantage(
    scenarioID: String,
    note: String
  ) throws -> RookManualBaseline {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 240 else {
      throw RookManualBaselineError.invalidAttentionNote
    }
    var records = try load()
    if let index = records.firstIndex(where: { $0.scenarioID == scenarioID }) {
      records[index].attentionAdvantage = true
      records[index].attentionNote = trimmed
    } else {
      records.append(
        RookManualBaseline(
          scenarioID: scenarioID,
          samplesMilliseconds: [],
          attentionAdvantage: true,
          attentionNote: trimmed
        )
      )
    }
    records.sort { $0.scenarioID < $1.scenarioID }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try RookConfig.writePrivate(try encoder.encode(records), to: url)
    return records.first(where: { $0.scenarioID == scenarioID })!
  }

  public func load() throws -> [RookManualBaseline] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try JSONDecoder().decode([RookManualBaseline].self, from: Data(contentsOf: url))
  }

  public func medians() throws -> [String: Double] {
    Dictionary(
      uniqueKeysWithValues: try load().compactMap { baseline in
        baseline.medianMilliseconds.map { (baseline.scenarioID, $0) }
      })
  }
}

public enum RookManualBaselineError: LocalizedError {
  case invalidDuration
  case invalidAttentionNote

  public var errorDescription: String? {
    switch self {
    case .invalidDuration:
      "Manual baseline duration must be a positive finite number of milliseconds."
    case .invalidAttentionNote:
      "Attention advantage requires a concise note between 1 and 240 characters."
    }
  }
}
