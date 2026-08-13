import AppKit
import Foundation
import RookKit

func printJSON<T: Encodable>(_ value: T) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(value))
  FileHandle.standardOutput.write(Data("\n".utf8))
}

final class CLIStreamState: @unchecked Sendable {
  private let lock = NSLock()
  private var failureMessage: String?

  func fail(_ error: Error) {
    lock.lock()
    failureMessage = error.localizedDescription
    lock.unlock()
  }

  var failure: String? {
    lock.lock()
    defer { lock.unlock() }
    return failureMessage
  }
}

enum RookCLIError: LocalizedError {
  case invalidRelayEndpoint
  case invalidRelayAccessToken

  var errorDescription: String? {
    switch self {
    case .invalidRelayEndpoint:
      return "The mobile relay address must be a secure wss:// WebSocket URL."
    case .invalidRelayAccessToken:
      return "The mobile relay access token was missing or invalid."
    }
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
  var config = try RookConfig.loadOrCreate()

  if let relayIndex = arguments.firstIndex(of: "--configure-mobile-relay"),
    arguments.indices.contains(relayIndex + 1)
  {
    guard let relayEndpoint = RookMobileRelay.endpoint(from: arguments[relayIndex + 1]) else {
      throw RookCLIError.invalidRelayEndpoint
    }
    let tokenData = FileHandle.standardInput.readDataToEndOfFile()
    guard let tokenValue = String(data: tokenData, encoding: .utf8) else {
      throw RookCLIError.invalidRelayAccessToken
    }
    let token = tokenValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard RookMobileRelay.isValidAccessToken(token) else {
      throw RookCLIError.invalidRelayAccessToken
    }
    try RookMobileHostKeychain.saveRelayAccessToken(token)
    config.mobileRelayURL = relayEndpoint.absoluteString
    try config.save()
    print("Rook mobile relay configured at \(relayEndpoint.absoluteString). Restart Rook and pair the iPhone again.")
    exit(0)
  }

  if let relayIndex = arguments.firstIndex(of: "--configure-mobile-relay-endpoint"),
    arguments.indices.contains(relayIndex + 1)
  {
    guard let relayEndpoint = RookMobileRelay.endpoint(from: arguments[relayIndex + 1]) else {
      throw RookCLIError.invalidRelayEndpoint
    }
    config.mobileRelayURL = relayEndpoint.absoluteString
    try config.save()
    print("Rook mobile relay endpoint configured at \(relayEndpoint.absoluteString).")
    exit(0)
  }

  if arguments.contains("--mobile-relay-token-status") {
    let tokenIsReady =
      RookMobileHostKeychain.loadRelayAccessToken()
      .map(RookMobileRelay.isValidAccessToken) == true
    print(tokenIsReady ? "Rook mobile relay token is ready." : "Rook mobile relay token is missing.")
    exit(tokenIsReady ? 0 : 1)
  }

  if arguments.contains("--disable-mobile-relay") {
    RookMobileHostKeychain.removeRelayAccessToken()
    config.mobileRelayURL = ""
    try config.save()
    print("Rook mobile relay disabled. Nearby Bonjour connections remain available.")
    exit(0)
  }

  let bridge = CodexBridge(config: config)

  if arguments.contains("--doctor") {
    let result = bridge.doctor()
    try printJSON(result)
    exit(result.ok ? 0 : 1)
  }

  if arguments.contains("--reset-session") {
    bridge.resetConversation()
    print("Rook conversation reset.")
    exit(0)
  }

  if arguments.contains("--checkpoint") {
    let library = try RookLibrary(config: config)
    let checkpoint = try bridge.runCheckpoint(
      previousCheck: library.latestCheckpoint(),
      activePreferences: library.activePreferences()
    )
    try library.storeCheckpoint(checkpoint)
    try printJSON(checkpoint)
    exit(0)
  }

  if let contextIndex = arguments.firstIndex(of: "--library-context"),
    arguments.indices.contains(contextIndex + 1)
  {
    let library = try RookLibrary(config: config)
    print(library.contextSnapshot(for: arguments[contextIndex + 1]))
    exit(0)
  }

  if let weatherIndex = arguments.firstIndex(of: "--weather-fast"),
    arguments.indices.contains(weatherIndex + 1)
  {
    guard case .weather(let request) = RookDirectCapabilityGuide.resolve(arguments[weatherIndex + 1]) else {
      FileHandle.standardError.write(Data("Command is not a supported direct-weather request.\n".utf8))
      exit(2)
    }
    var weatherResult: Result<RookResponse, Error>?
    let service = MainActor.assumeIsolated { RookWeatherService(config: config) }
    MainActor.assumeIsolated {
      service.fetch(request) { result in weatherResult = result }
    }
    let deadline = Date().addingTimeInterval(5)
    while weatherResult == nil, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    MainActor.assumeIsolated { service.stop() }
    guard let weatherResult else {
      FileHandle.standardError.write(Data("Instant weather exceeded five seconds.\n".utf8))
      exit(1)
    }
    switch weatherResult {
    case .success(let response):
      try printJSON(response)
      exit(0)
    case .failure(let error):
      throw error
    }
  }

  if let reflexIndex = arguments.firstIndex(of: "--reflex-fast"),
    arguments.indices.contains(reflexIndex + 1)
  {
    guard let intent = RookReflexCommandParser.parse(arguments[reflexIndex + 1]) else {
      FileHandle.standardError.write(Data("Command is not an exact local Reflex request.\n".utf8))
      exit(2)
    }
    var reflexResult: Result<RookReflexExecution, Error>?
    let controller = MainActor.assumeIsolated { RookReflexController(config: config) }
    MainActor.assumeIsolated {
      controller.execute(intent) { result in reflexResult = result }
    }
    guard let reflexResult else {
      FileHandle.standardError.write(Data("Rook Reflex did not return immediately.\n".utf8))
      exit(1)
    }
    switch reflexResult {
    case .success(let execution):
      try printJSON(
        RookResponse(
          displayText: execution.displayText,
          spokenText: execution.spokenText,
          intent: "status",
          requiresApproval: false,
          queueItemIDs: [],
          pawns: [],
          canvas: [execution.canvas]
        ))
      exit(0)
    case .failure(let error):
      throw error
    }
  }

  if let speechIndex = arguments.firstIndex(of: "--speak-test"), arguments.indices.contains(speechIndex + 1) {
    var finished = false
    let voice = MainActor.assumeIsolated { VoiceController(config: config) }
    MainActor.assumeIsolated {
      voice.setListening(enabled: false)
      voice.speak(arguments[speechIndex + 1]) {
        finished = true
      }
    }
    while !finished {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    exit(0)
  }

  if let askIndex = arguments.firstIndex(of: "--ask-fast"), arguments.indices.contains(askIndex + 1) {
    let decision = LocalRookRouter.route(arguments[askIndex + 1])
    try printJSON(decision.response)
    exit(0)
  }

  if let polishIndex = arguments.firstIndex(of: "--polish-local"),
    arguments.indices.contains(polishIndex + 1)
  {
    print(RookPromptRefiner.refine(arguments[polishIndex + 1]))
    exit(0)
  }

  if let askIndex = arguments.firstIndex(of: "--ask-live"), arguments.indices.contains(askIndex + 1) {
    let client = RookStreamingClient(config: config)
    let finished = DispatchSemaphore(value: 0)
    let state = CLIStreamState()
    client.start()
    client.answer(
      id: UUID(),
      command: arguments[askIndex + 1],
      onDelta: { delta in
        FileHandle.standardOutput.write(Data(delta.utf8))
      },
      completion: { result in
        if case .failure(let error) = result { state.fail(error) }
        FileHandle.standardOutput.write(Data("\n".utf8))
        finished.signal()
      }
    )
    let waitResult = finished.wait(timeout: .now() + 45)
    client.stop()
    if waitResult == .timedOut {
      FileHandle.standardError.write(Data("Rook live answer timed out.\n".utf8))
      exit(1)
    }
    if let failure = state.failure {
      FileHandle.standardError.write(Data("Rook live answer failed: \(failure)\n".utf8))
      exit(1)
    }
    exit(0)
  }

  if let askIndex = arguments.firstIndex(of: "--ask"), arguments.indices.contains(askIndex + 1) {
    let response = try bridge.run(command: arguments[askIndex + 1])
    try printJSON(response)
    exit(0)
  }

  let retainedDelegate: RookAppDelegate? = MainActor.assumeIsolated {
    RookAppDelegate(previewMode: arguments.contains("--ui-preview"))
  }
  let application = NSApplication.shared
  application.delegate = retainedDelegate
  application.run()
  withExtendedLifetime(retainedDelegate) {}
} catch {
  FileHandle.standardError.write(Data("Rook error: \(error.localizedDescription)\n".utf8))
  exit(1)
}
