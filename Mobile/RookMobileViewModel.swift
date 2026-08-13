import Combine
import Foundation
import LocalAuthentication
import UIKit

enum RookMobileConnectionState: Equatable {
  case unpaired
  case connecting
  case connected(String)
  case disconnected(String)
  case failed(String)

  var label: String {
    switch self {
    case .unpaired: return "Not paired"
    case .connecting: return "Connecting"
    case .connected: return "Connected"
    case .disconnected: return "Mac unavailable"
    case .failed: return "Needs attention"
    }
  }

  var detail: String {
    switch self {
    case .unpaired: return "Pair with Rook on your Mac"
    case .connecting: return "Securing the private link"
    case .connected(let host): return host
    case .disconnected(let reason), .failed(let reason): return reason
    }
  }

  var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}

@MainActor
final class RookMobileViewModel: ObservableObject {
  @Published var commandText = ""
  @Published var isPairingPresented = false
  @Published var isScannerPresented = false
  @Published private(set) var connectionState: RookMobileConnectionState = .unpaired
  @Published private(set) var latestResponse: RookResponse?
  @Published private(set) var pawns: [PawnReport] = []
  @Published private(set) var activity: [RookMobileActivityItem] = []
  @Published private(set) var library: [RookMobileLibraryItem] = []
  @Published private(set) var moves: [RookMobileMove] = []
  @Published private(set) var allies: [RookMobileAlly] = []
  @Published private(set) var hostStatus = "Waiting for your Mac"
  @Published private(set) var statusText = "Rook goes where you do."
  @Published private(set) var isWorking = false
  @Published var errorMessage: String?

  let voice = RookMobileVoiceController()

  var pendingMoves: [RookMobileMove] { moves.filter { $0.status == .pending } }
  var approvedMoves: [RookMobileMove] { moves.filter { $0.status == .approved } }
  var activeActivity: [RookMobileActivityItem] {
    activity.filter { $0.status == .queued || $0.status == .working }
  }
  var recentActivity: [RookMobileActivityItem] {
    activity.filter { $0.status != .queued && $0.status != .working }
  }

  private let socket = RookMobileClient()
  private let defaults: UserDefaults
  private let deviceID: UUID
  private var connectionTask: Task<Void, Never>?
  private var connectionGeneration = 0
  private var receiveTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var reconnectAttempt = 0
  private var reconnectEnabled = false
  private var currentRequestID: UUID?
  private var pendingPairingPayload: RookMobilePairingPayload?
  private var replayGuard = RookMobileReplayGuard()
  private var cancellables: Set<AnyCancellable> = []

  private static let serviceIDKey = "rook.mobile.service-id"
  private static let hostNameKey = "rook.mobile.host-name"
  private static let deviceIDKey = "rook.mobile.device-id"
  private static let relayURLKey = "rook.mobile.relay-url"

  init(preview: Bool = false, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let value = defaults.string(forKey: Self.deviceIDKey), let stored = UUID(uuidString: value) {
      deviceID = stored
    } else {
      let created = UUID()
      deviceID = created
      defaults.set(created.uuidString, forKey: Self.deviceIDKey)
    }

    voice.$transcript
      .receive(on: DispatchQueue.main)
      .sink { [weak self] transcript in
        guard !transcript.isEmpty else { return }
        self?.commandText = transcript
      }
      .store(in: &cancellables)

    if preview {
      seedPreview()
    } else if defaults.string(forKey: Self.serviceIDKey) != nil,
      RookMobileKeychain.loadSessionToken() != nil
    {
      let host = defaults.string(forKey: Self.hostNameKey) ?? "Paired Mac"
      connectionState = .disconnected("Reconnect to \(host)")
    }
  }

  func start() {
    guard !connectionState.isConnected else { return }
    if case .connecting = connectionState { return }
    guard let token = RookMobileKeychain.loadSessionToken(),
      let serviceValue = defaults.string(forKey: Self.serviceIDKey),
      let serviceID = UUID(uuidString: serviceValue)
    else { return }

    reconnectEnabled = true
    reconnectTask?.cancel()
    reconnectTask = nil
    connectionTask?.cancel()
    connectionGeneration += 1
    let generation = connectionGeneration
    connectionState = .connecting
    statusText = "Securing the link to your Mac"
    errorMessage = nil
    traceConnection("attempt_started", generation: generation)
    connectionTask = Task {
      await connect(
        serviceID: serviceID,
        keyID: RookMobileSecureChannel.deviceKeyID(deviceID: deviceID),
        secret: token,
        relayURL: defaults.string(forKey: Self.relayURLKey).flatMap(RookMobileRelay.endpoint(from:)),
        relayAccessToken: RookMobileKeychain.loadRelayAccessToken(),
        initialPayload: .authenticate(
          RookMobileAuthentication(deviceID: deviceID, sessionToken: token)
        ),
        reconnectOnFailure: true,
        generation: generation
      )
    }
  }

  func handleScannedPairingCode(_ value: String) {
    guard let url = URL(string: value) else {
      errorMessage = "That QR code is not a Rook pairing code."
      return
    }
    do {
      let payload = try RookMobilePairingPayload(url: url)
      pendingPairingPayload = payload
      reconnectEnabled = false
      reconnectTask?.cancel()
      reconnectTask = nil
      connectionTask?.cancel()
      connectionGeneration += 1
      let generation = connectionGeneration
      connectionState = .connecting
      statusText = "Securing the link to your Mac"
      isScannerPresented = false
      errorMessage = nil
      connectionTask = Task {
        await connect(
          serviceID: payload.serviceID,
          keyID: RookMobileSecureChannel.pairingKeyID(serviceID: payload.serviceID),
          secret: payload.secret,
          relayURL: nil,
          relayAccessToken: nil,
          initialPayload: .pairRequest(
            RookMobilePairRequest(
              deviceID: deviceID,
              deviceName: UIDevice.current.name,
              oneTimeCode: payload.oneTimeCode
            )
          ),
          reconnectOnFailure: false,
          generation: generation
        )
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func submitCommand(source: RookMobileCommandSource = .typed) {
    let command = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty,
      command.count <= RookMobileProtocol.maximumCommandCharacters
    else { return }
    guard connectionState.isConnected else {
      isPairingPresented = true
      return
    }

    voice.stop()
    commandText = ""
    let requestID = UUID()
    currentRequestID = requestID
    isWorking = true
    statusText = "Rook is answering"
    let envelope = RookMobileEnvelope(
      id: requestID,
      payload: .command(RookMobileCommand(text: command, source: source))
    )
    Task { await send(envelope) }
  }

  func submitPreset(_ command: String) {
    commandText = command
    submitCommand(source: .shortcut)
  }

  func decide(_ action: RookMobileMoveDecisionAction, move: RookMobileMove) {
    guard connectionState.isConnected else {
      isPairingPresented = true
      return
    }
    Task {
      if action == .approve, !(await authorizeApproval(for: move)) { return }
      let envelope = RookMobileEnvelope(
        payload: .moveDecision(RookMobileMoveDecision(moveID: move.id, action: action))
      )
      await send(envelope)
      statusText = action == .approve ? "Approval sent to your Mac" : "Move rejected"
    }
  }

  func reconnect() {
    start()
  }

  func disconnect() {
    reconnectEnabled = false
    connectionGeneration += 1
    connectionTask?.cancel()
    connectionTask = nil
    reconnectTask?.cancel()
    reconnectTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    Task { await socket.disconnect() }
    let host = defaults.string(forKey: Self.hostNameKey) ?? "your Mac"
    connectionState = .disconnected("Reconnect to \(host)")
    isWorking = false
  }

  func forgetPairing() {
    disconnect()
    RookMobileKeychain.clear()
    defaults.removeObject(forKey: Self.serviceIDKey)
    defaults.removeObject(forKey: Self.hostNameKey)
    defaults.removeObject(forKey: Self.relayURLKey)
    pendingPairingPayload = nil
    connectionState = .unpaired
    statusText = "Pair with Rook on your Mac to begin."
  }

  private func connect(
    serviceID: UUID,
    keyID: String,
    secret: String,
    relayURL: URL?,
    relayAccessToken: String?,
    initialPayload: RookMobilePayload,
    reconnectOnFailure: Bool,
    generation: Int
  ) async {
    guard generation == connectionGeneration else { return }
    receiveTask?.cancel()
    do {
      try await socket.connect(
        serviceID: serviceID,
        keyID: keyID,
        secret: secret,
        relayURL: relayURL,
        relayAccessToken: relayAccessToken,
        initialEnvelope: RookMobileEnvelope(payload: initialPayload)
      )
      guard generation == connectionGeneration else { return }
      traceConnection("transport_ready", generation: generation)
      reconnectEnabled = reconnectOnFailure
      reconnectAttempt = 0
      beginReceiving(generation: generation)
    } catch {
      guard generation == connectionGeneration else { return }
      if reconnectOnFailure {
        await handleConnectionInterruption(error, generation: generation)
      } else {
        connectionState = .failed(error.localizedDescription)
        errorMessage = error.localizedDescription
      }
    }
  }

  private func beginReceiving(generation: Int) {
    receiveTask = Task { [weak self] in
      guard let self else { return }
      do {
        while !Task.isCancelled {
          let envelope = try await socket.receive()
          guard generation == connectionGeneration else { return }
          traceConnection("envelope_received", generation: generation)
          try replayGuard.admit(envelope)
          try RookMobileSessionPolicy.validatePhoneInbound(envelope)
          handle(envelope)
        }
      } catch {
        guard !Task.isCancelled, generation == connectionGeneration else { return }
        await handleConnectionInterruption(error, generation: generation)
      }
    }
  }

  private func send(_ envelope: RookMobileEnvelope) async {
    let generation = connectionGeneration
    do {
      try await socket.send(envelope)
    } catch {
      await handleConnectionInterruption(error, generation: generation)
    }
  }

  private func handle(_ envelope: RookMobileEnvelope) {
    switch envelope.payload {
    case .pairAccepted(let accepted):
      do {
        try RookMobileKeychain.save(sessionToken: accepted.sessionToken)
        if let payload = pendingPairingPayload {
          defaults.set(payload.serviceID.uuidString, forKey: Self.serviceIDKey)
          if let relayURL = payload.relayURL {
            defaults.set(relayURL.absoluteString, forKey: Self.relayURLKey)
          } else {
            defaults.removeObject(forKey: Self.relayURLKey)
          }
          if let relayAccessToken = payload.relayAccessToken {
            try RookMobileKeychain.saveRelayAccessToken(relayAccessToken)
          }
        }
        defaults.set(accepted.hostName, forKey: Self.hostNameKey)
        reconnectEnabled = true
        reconnectAttempt = 0
        pendingPairingPayload = nil
        connectionState = .connected(accepted.hostName)
        statusText = "Paired privately with \(accepted.hostName)"
        isPairingPresented = false
      } catch {
        connectionState = .failed("Could not store the private session")
        errorMessage = error.localizedDescription
      }
    case .progress(let progress):
      markConnectedIfNeeded()
      isWorking = true
      statusText = progress.displayText
      pawns = progress.pawns
    case .response(let response):
      markConnectedIfNeeded()
      latestResponse = response
      pawns = response.pawns
      statusText = response.requiresApproval ? "A move needs your review" : "Rook answered"
      isWorking = false
      currentRequestID = nil
    case .snapshot(let snapshot):
      markConnectedIfNeeded()
      latestResponse = snapshot.latestResponse ?? latestResponse
      if let response = snapshot.latestResponse { pawns = response.pawns }
      activity = snapshot.activity.sorted { $0.updatedAt > $1.updatedAt }
      library = snapshot.library.sorted { $0.updatedAt > $1.updatedAt }
      moves = snapshot.moves.filter { move in
        guard let expiresAt = move.expiresAt else { return true }
        return expiresAt > Date()
      }
      allies = snapshot.allies
      hostStatus = snapshot.hostStatus
      statusText = "Synced with your Mac"
      isWorking = false
    case .error(let error):
      errorMessage = error.message
      statusText = error.recoverable ? "Rook needs one adjustment" : "Request stopped safely"
      isWorking = false
    case .ping:
      markConnectedIfNeeded()
    case .pairRequest, .authenticate, .command, .moveDecision:
      break
    }
  }

  private func markConnectedIfNeeded() {
    guard !connectionState.isConnected else { return }
    let host = defaults.string(forKey: Self.hostNameKey) ?? "Paired Mac"
    connectionState = .connected(host)
    traceConnection("connected", generation: connectionGeneration)
  }

  private func handleConnectionInterruption(_ error: Error, generation: Int) async {
    guard generation == connectionGeneration else { return }
    traceConnection("interrupted", generation: generation, error: error)
    await socket.disconnect()
    guard generation == connectionGeneration else { return }
    isWorking = false
    guard reconnectEnabled else {
      connectionState = .failed(error.localizedDescription)
      errorMessage = error.localizedDescription
      return
    }
    errorMessage = nil
    connectionState = .disconnected("Reconnecting through Rook's private relay")
    statusText = "Switching to the cellular connection"
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    guard reconnectEnabled, reconnectTask == nil else { return }
    let exponent = min(reconnectAttempt, 4)
    let delay = UInt64(min(15, 1 << exponent))
    reconnectAttempt += 1
    traceConnection("retry_scheduled", generation: connectionGeneration)
    reconnectTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay * 1_000_000_000)
      } catch {
        return
      }
      guard let self, self.reconnectEnabled else { return }
      self.reconnectTask = nil
      self.start()
    }
  }

  private func traceConnection(_ event: String, generation: Int, error: Error? = nil) {
    #if DEBUG
      let errorFields: String
      if let error {
        let value = error as NSError
        errorFields = " error_domain=\(value.domain) error_code=\(value.code)"
      } else {
        errorFields = ""
      }
      print("ROOK_MOBILE_CONNECTION event=\(event) generation=\(generation)\(errorFields)")
    #endif
  }

  private func authorizeApproval(for move: RookMobileMove) async -> Bool {
    let context = LAContext()
    context.localizedCancelTitle = "Keep pending"
    var evaluationError: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
      errorMessage = evaluationError?.localizedDescription ?? "Device authentication is unavailable."
      return false
    }
    do {
      return try await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: "Approve \(move.label) in Rook"
      )
    } catch {
      errorMessage = "Approval stayed pending. \(error.localizedDescription)"
      return false
    }
  }

  private func seedPreview() {
    connectionState = .connected("Noah's MacBook Pro")
    hostStatus = "Rook is ready"
    statusText = "Your morning is clear after 11:30."
    latestResponse = RookResponse(
      displayText:
        "You have one focused block this morning. The only item that needs a decision is the proposed calendar move below.",
      spokenText: "Your morning is clear after eleven thirty. One move needs your review.",
      intent: "brief",
      requiresApproval: true,
      queueItemIDs: ["RQ-0042"],
      pawns: [
        PawnReport(
          pawn: "Steward",
          task: "Checked the primary Calendar",
          status: "completed",
          id: "steward_1"
        )
      ],
      canvas: [
        RookCanvasBlock(
          id: "today_calendar",
          kind: .calendar,
          title: "Today",
          subtitle: "Primary Calendar",
          asOf: "8:14 AM",
          items: [
            RookCanvasItem(
              id: "deep_work",
              label: "Deep Work",
              detail: "Priority follow-ups",
              symbol: .calendar,
              start: "2026-08-11T09:00:00-04:00",
              end: "2026-08-11T11:30:00-04:00"
            ),
            RookCanvasItem(
              id: "lunch",
              label: "Lunch",
              detail: "Open after this",
              symbol: .clock,
              start: "2026-08-11T12:30:00-04:00",
              end: "2026-08-11T13:15:00-04:00"
            ),
          ]
        )
      ]
    )
    library = [
      RookMobileLibraryItem(
        id: UUID(),
        label: "Morning brief",
        summary: "Calendar checked and priority follow-ups surfaced.",
        status: "completed",
        updatedAt: Date()
      ),
      RookMobileLibraryItem(
        id: UUID(),
        label: "Mobile companion",
        summary: "Address-free QR pairing and encrypted local sync are ready.",
        status: "completed",
        updatedAt: Date().addingTimeInterval(-3_600)
      ),
      RookMobileLibraryItem(
        id: UUID(),
        label: "Spotify direct ally",
        summary: "Named playlists, catalog search, devices, and playback now use the native connection.",
        status: "completed",
        updatedAt: Date().addingTimeInterval(-7_200)
      ),
      RookMobileLibraryItem(
        id: UUID(),
        label: "Project graph refresh",
        summary: "Librarian linked recent work to its projects, categories, and topics.",
        status: "completed",
        updatedAt: Date().addingTimeInterval(-86_400)
      ),
    ]
    activity = [
      RookMobileActivityItem(
        id: UUID(),
        label: "Build the iPhone command center",
        status: .working,
        startedAt: Date().addingTimeInterval(-82),
        updatedAt: Date(),
        pawns: [
          PawnReport(pawn: "Forge", task: "Building the SwiftUI navigation", status: "working", id: "forge_1"),
          PawnReport(pawn: "Auditor", task: "Checking mobile safety boundaries", status: "working", id: "auditor_1"),
        ]
      ),
      RookMobileActivityItem(
        id: UUID(),
        label: "Connect Rook to the iPhone",
        status: .completed,
        startedAt: Date().addingTimeInterval(-7_200),
        updatedAt: Date().addingTimeInterval(-5_400),
        pawns: [
          PawnReport(pawn: "Forge", task: "Implemented encrypted pairing", status: "completed", id: "forge_2"),
          PawnReport(pawn: "Auditor", task: "Verified address-free discovery", status: "completed", id: "auditor_2"),
        ]
      ),
    ]
    allies = [
      RookMobileAlly(id: "gmail", label: "Gmail", detail: "Available through Codex", state: .codex),
      RookMobileAlly(
        id: "google_calendar",
        label: "Google Calendar",
        detail: "Available through Codex",
        state: .codex
      ),
      RookMobileAlly(
        id: "spotify",
        label: "Spotify",
        detail: "Direct account controls on your Mac",
        state: .direct
      ),
    ]
    moves = [
      RookMobileMove(
        id: "RQ-0042",
        label: "Move hike time",
        details: "Move the existing hike from 1:30 PM to 2:00 PM today.",
        proposedAction: "Update one attendee-free event on the primary Calendar.",
        risk: "Calendar change",
        status: .pending,
        expiresAt: Date().addingTimeInterval(10_800)
      ),
      RookMobileMove(
        id: "RQ-0041",
        label: "Send project recap",
        details: "Send the reviewed recap to the project group.",
        proposedAction: "Record approval only; execution remains on your Mac.",
        risk: "Email send",
        status: .approved,
        expiresAt: Date().addingTimeInterval(7_200)
      ),
    ]
  }
}
