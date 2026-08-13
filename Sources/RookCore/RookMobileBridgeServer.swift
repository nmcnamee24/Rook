import Foundation
@preconcurrency import Network
import RookKit

enum RookMobileBridgeError: LocalizedError {
  case pairingUnavailable
  case deviceKeyUnavailable
  case invalidKeyIdentity
  case invalidFrame

  var errorDescription: String? {
    switch self {
    case .pairingUnavailable: return "That pairing session is no longer active."
    case .deviceKeyUnavailable: return "This iPhone needs to pair with Rook again."
    case .invalidKeyIdentity: return "Rook could not identify this private connection."
    case .invalidFrame: return "Rook received an invalid private message."
    }
  }
}

@MainActor
protocol RookMobileHostClient: AnyObject {
  var id: UUID { get }
  var isAuthenticated: Bool { get }
  func start()
  func stop()
  func markAuthenticated(deviceID: UUID, deviceName: String)
  func beginRequest(id: UUID)
  func synchronize(with state: RookMobileBridgeState)
  func send(_ envelope: RookMobileEnvelope)
  func sendError(_ error: Error, correlationID: UUID?)
}

@MainActor
final class RookMobileBridgeServer {
  typealias MoveDecisionHandler = (
    RookMobileMoveDecision,
    @escaping @Sendable (Result<Void, Error>) -> Void
  ) -> Void

  let serviceID: UUID
  private(set) var currentOffer: RookMobilePairingOffer?
  var onStatus: ((String) -> Void)?
  var onPairingCompleted: ((String) -> Void)?

  private let model: RookDashboardModel
  private let pairingStore: RookMobilePairingStore
  private let onCommand: (UUID, String) -> Void
  private let onMoveDecision: MoveDecisionHandler
  private let relayEndpoint: URL?
  private let relayAccessToken: String?
  private let diagnosticsURL: URL
  private let networkQueue = DispatchQueue(label: "com.noah.rook.mobile-host", qos: .userInitiated)
  private var listener: NWListener?
  private var connections: [UUID: any RookMobileHostClient] = [:]
  private var relayConnections: [UUID: RookMobileRelayHostConnection] = [:]
  private var replayGuard = RookMobileReplayGuard()
  private var syncTimer: Timer?
  private var relayRefreshTimer: Timer?
  private var relayStates: [UUID: String] = [:]

  init(
    config: RookConfig,
    model: RookDashboardModel,
    onCommand: @escaping (UUID, String) -> Void,
    onMoveDecision: @escaping MoveDecisionHandler
  ) throws {
    self.model = model
    self.onCommand = onCommand
    self.onMoveDecision = onMoveDecision
    diagnosticsURL = config.stateURL.appendingPathComponent("mobile_bridge_status.json")
    let configuredRelayEndpoint = RookMobileRelay.endpoint(from: config.mobileRelayURL)
    let configuredRelayToken = RookMobileHostKeychain.loadRelayAccessToken()
    if configuredRelayEndpoint != nil,
      configuredRelayToken.map(RookMobileRelay.isValidAccessToken) == true
    {
      relayEndpoint = configuredRelayEndpoint
      relayAccessToken = configuredRelayToken
    } else {
      relayEndpoint = nil
      relayAccessToken = nil
    }
    pairingStore = try RookMobilePairingStore(stateDirectory: config.stateURL)
    serviceID = try Self.loadOrCreateServiceID(in: config.stateURL)
    try start()
    syncTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.synchronizeConnections() }
    }
    if relayEndpoint != nil {
      refreshRelayConnections()
      relayRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
        Task { @MainActor in self?.refreshRelayConnections() }
      }
    }
    writeDiagnostics()
  }

  deinit {
    listener?.cancel()
    syncTimer?.invalidate()
    relayRefreshTimer?.invalidate()
  }

  func beginPairing() throws -> RookMobilePairingOffer {
    let offer = try pairingStore.beginPairing(
      serviceID: serviceID,
      relayURL: relayEndpoint,
      relayAccessToken: relayAccessToken
    )
    currentOffer = offer
    return offer
  }

  func cancelPairing() {
    currentOffer = nil
    pairingStore.cancelPairing()
  }

  func resolveSecret(for keyID: String) throws -> String {
    let pairingKey = RookMobileSecureChannel.pairingKeyID(serviceID: serviceID)
    if keyID == pairingKey {
      guard let secret = pairingStore.pairingSecret(serviceID: serviceID) else {
        throw RookMobileBridgeError.pairingUnavailable
      }
      return secret
    }
    let prefix = "device:"
    guard keyID.hasPrefix(prefix),
      let deviceID = UUID(uuidString: String(keyID.dropFirst(prefix.count)))
    else { throw RookMobileBridgeError.invalidKeyIdentity }
    guard let token = RookMobileHostKeychain.load(deviceID: deviceID) else {
      throw RookMobileBridgeError.deviceKeyUnavailable
    }
    return token
  }

  func handle(_ envelope: RookMobileEnvelope, from client: any RookMobileHostClient) {
    do {
      try replayGuard.admit(envelope)
      try RookMobileSessionPolicy.validateHostInbound(
        envelope,
        authenticated: client.isAuthenticated
      )
      switch envelope.payload {
      case .pairRequest(let request):
        let accepted = try pairingStore.accept(
          request,
          hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        )
        try RookMobileHostKeychain.save(sessionToken: accepted.sessionToken, deviceID: request.deviceID)
        replaceRelayConnection(for: request.deviceID)
        client.markAuthenticated(deviceID: request.deviceID, deviceName: request.deviceName)
        currentOffer = nil
        client.send(
          RookMobileEnvelope(correlationID: envelope.id, payload: .pairAccepted(accepted))
        )
        client.send(RookMobileEnvelope(payload: .snapshot(model.mobileBridgeState.snapshot)))
        refreshRelayConnections()
        onPairingCompleted?(request.deviceName)

      case .authenticate(let authentication):
        let device = try pairingStore.authenticate(authentication)
        client.markAuthenticated(deviceID: device.id, deviceName: device.name)
        client.send(
          RookMobileEnvelope(correlationID: envelope.id, payload: .snapshot(model.mobileBridgeState.snapshot)))

      case .command(let command):
        client.beginRequest(id: envelope.id)
        client.send(
          RookMobileEnvelope(
            correlationID: envelope.id,
            payload: .progress(
              RookMobileProgress(phase: "routing", displayText: "Rook is routing your request")
            )
          )
        )
        onCommand(envelope.id, command.normalizedText)

      case .moveDecision(let decision):
        guard let currentMove = model.queueItems.first(where: { $0.id == decision.moveID }),
          decision.action == .reject || currentMove.status == "pending"
        else {
          throw RookMobilePolicyError.invalidMove
        }
        client.send(
          RookMobileEnvelope(
            correlationID: envelope.id,
            payload: .progress(
              RookMobileProgress(phase: "approval", displayText: "Recording the exact move decision")
            )
          )
        )
        let clientID = client.id
        onMoveDecision(decision) { [weak self] result in
          Task { @MainActor in
            guard let self, let client = self.connections[clientID] else { return }
            switch result {
            case .success:
              self.model.refreshQueue()
              client.send(
                RookMobileEnvelope(
                  correlationID: envelope.id,
                  payload: .snapshot(self.model.mobileBridgeState.snapshot)
                )
              )
            case .failure(let error):
              client.sendError(error, correlationID: envelope.id)
            }
          }
        }

      case .ping(let ping):
        client.send(RookMobileEnvelope(correlationID: envelope.id, payload: .ping(ping)))

      case .pairAccepted, .progress, .response, .snapshot, .error:
        throw RookMobilePolicyError.payloadNotAllowed
      }
    } catch {
      client.sendError(error, correlationID: envelope.id)
    }
  }

  func removeConnection(_ id: UUID) {
    connections.removeValue(forKey: id)
  }

  private func start() throws {
    let listener = try NWListener(using: .tcp)
    listener.service = NWListener.Service(
      name: RookMobileBonjour.serviceName(for: serviceID),
      type: RookMobileBonjour.serviceType
    )
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in
        guard let self else {
          connection.cancel()
          return
        }
        let client = RookMobileHostConnection(
          connection: connection,
          server: self,
          networkQueue: self.networkQueue
        )
        self.connections[client.id] = client
        client.start()
      }
    }
    listener.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .ready:
          self?.onStatus?(
            self?.relayEndpoint == nil ? "iPhone bridge ready nearby" : "iPhone bridge ready anywhere"
          )
        case .failed(let error):
          self?.onStatus?("iPhone bridge unavailable: \(error.localizedDescription)")
        default:
          break
        }
      }
    }
    listener.start(queue: networkQueue)
    self.listener = listener
  }

  private func synchronizeConnections() {
    let state = model.mobileBridgeState
    for client in connections.values where client.isAuthenticated {
      client.synchronize(with: state)
    }
  }

  private func refreshRelayConnections() {
    guard let relayEndpoint, let relayAccessToken else { return }
    let pairedDevices: [RookMobilePairedDeviceSummary]
    do {
      pairedDevices = try pairingStore.pairedDevices()
    } catch {
      return
    }

    let pairedIDs = Set(pairedDevices.map(\.id))
    let staleDeviceIDs = relayConnections.keys.filter { !pairedIDs.contains($0) }
    for deviceID in staleDeviceIDs {
      guard let client = relayConnections.removeValue(forKey: deviceID) else { continue }
      client.stop()
      connections.removeValue(forKey: client.id)
    }

    for device in pairedDevices where relayConnections[device.id] == nil {
      guard let token = RookMobileHostKeychain.load(deviceID: device.id) else { continue }
      let client = RookMobileRelayHostConnection(
        deviceID: device.id,
        sessionToken: token,
        relayAccessToken: relayAccessToken,
        endpoint: relayEndpoint,
        server: self
      )
      client.onStateChange = { [weak self] state in
        guard let self else { return }
        self.relayStates[device.id] = state
        self.writeDiagnostics()
      }
      relayConnections[device.id] = client
      connections[client.id] = client
      client.start()
    }
    writeDiagnostics(pairedDevices: pairedDevices)
  }

  private func replaceRelayConnection(for deviceID: UUID) {
    guard let client = relayConnections.removeValue(forKey: deviceID) else { return }
    client.stop()
    connections.removeValue(forKey: client.id)
    relayStates.removeValue(forKey: deviceID)
  }

  private func writeDiagnostics(pairedDevices: [RookMobilePairedDeviceSummary]? = nil) {
    let devices = pairedDevices ?? (try? pairingStore.pairedDevices()) ?? []
    let keyedDeviceCount = devices.lazy.filter { RookMobileHostKeychain.load(deviceID: $0.id) != nil }.count
    let document = RookMobileBridgeDiagnostics(
      checkedAt: Date(),
      relayEndpointConfigured: relayEndpoint != nil,
      relayAccessTokenAvailable: relayAccessToken != nil,
      pairedDeviceCount: devices.count,
      pairedSessionKeyCount: keyedDeviceCount,
      relayClientCount: relayConnections.count,
      relayStates: relayStates.values.sorted()
    )
    guard let data = try? JSONEncoder.rookDiagnostics.encode(document) else { return }
    try? RookConfig.writePrivate(data, to: diagnosticsURL)
  }

  private static func loadOrCreateServiceID(in stateDirectory: URL) throws -> UUID {
    let url = stateDirectory.appendingPathComponent("mobile_bridge_id")
    if let value = try? String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let id = UUID(uuidString: value)
    {
      return id
    }
    let id = UUID()
    try RookConfig.writePrivate(Data(id.uuidString.lowercased().utf8), to: url)
    return id
  }
}

private struct RookMobileBridgeDiagnostics: Codable {
  let checkedAt: Date
  let relayEndpointConfigured: Bool
  let relayAccessTokenAvailable: Bool
  let pairedDeviceCount: Int
  let pairedSessionKeyCount: Int
  let relayClientCount: Int
  let relayStates: [String]

  enum CodingKeys: String, CodingKey {
    case checkedAt = "checked_at"
    case relayEndpointConfigured = "relay_endpoint_configured"
    case relayAccessTokenAvailable = "relay_access_token_available"
    case pairedDeviceCount = "paired_device_count"
    case pairedSessionKeyCount = "paired_session_key_count"
    case relayClientCount = "relay_client_count"
    case relayStates = "relay_states"
  }
}

private extension JSONEncoder {
  static var rookDiagnostics: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}

@MainActor
private final class RookMobileHostConnection: RookMobileHostClient {
  let id = UUID()
  private(set) var isAuthenticated = false

  private let connection: NWConnection
  private weak var server: RookMobileBridgeServer?
  private let networkQueue: DispatchQueue
  private var keyID: String?
  private var secret: String?
  private var pendingRequest = RookMobilePendingRequest()
  private var lastSnapshotSentAt = Date.distantPast
  private var isClosed = false

  init(connection: NWConnection, server: RookMobileBridgeServer, networkQueue: DispatchQueue) {
    self.connection = connection
    self.server = server
    self.networkQueue = networkQueue
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard case .failed = state else {
        if case .cancelled = state {
          Task { @MainActor in self?.close() }
        }
        return
      }
      Task { @MainActor in self?.close() }
    }
    connection.start(queue: networkQueue)
    receiveNextFrame()
  }

  func stop() {
    close()
  }

  func markAuthenticated(deviceID: UUID, deviceName: String) {
    isAuthenticated = true
  }

  func beginRequest(id: UUID) {
    pendingRequest.begin(id: id)
  }

  func synchronize(with state: RookMobileBridgeState) {
    if let requestID = pendingRequest.requestID {
      switch pendingRequest.update(
        hostRequestID: state.requestID,
        isWorking: state.isWorking,
        progress: state.progress,
        response: state.response
      ) {
      case .waiting:
        break
      case .progress(let progress):
        send(RookMobileEnvelope(correlationID: requestID, payload: .progress(progress)))
      case .response(let response):
        send(RookMobileEnvelope(correlationID: requestID, payload: .response(response)))
        send(RookMobileEnvelope(payload: .snapshot(state.snapshot)))
      }
      return
    }
    guard Date().timeIntervalSince(lastSnapshotSentAt) >= 2 else { return }
    lastSnapshotSentAt = Date()
    send(RookMobileEnvelope(payload: .snapshot(state.snapshot)))
  }

  func send(_ envelope: RookMobileEnvelope) {
    guard !isClosed, let keyID, let secret else { return }
    do {
      let encrypted = try RookMobileSecureChannel.seal(envelope, keyID: keyID, secret: secret)
      var length = UInt32(encrypted.count).bigEndian
      var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
      frame.append(encrypted)
      connection.send(
        content: frame,
        completion: .contentProcessed { [weak self] error in
          guard error != nil else { return }
          Task { @MainActor in self?.close() }
        })
    } catch {
      close()
    }
  }

  func sendError(_ error: Error, correlationID: UUID?) {
    send(
      RookMobileEnvelope(
        correlationID: correlationID,
        payload: .error(
          RookMobileErrorMessage(
            code: String(describing: type(of: error)),
            message: error.localizedDescription,
            recoverable: true
          )
        )
      )
    )
  }

  private func receiveNextFrame() {
    guard !isClosed else { return }
    Self.readExactly(MemoryLayout<UInt32>.size, from: connection) { [weak self] result in
      Task { @MainActor in self?.receivedHeader(result) }
    }
  }

  private func receivedHeader(_ result: Result<Data, Error>) {
    guard case .success(let data) = result else {
      close()
      return
    }
    let length = data.withUnsafeBytes { rawBuffer -> UInt32 in
      rawBuffer.loadUnaligned(as: UInt32.self).bigEndian
    }
    guard length > 0, length <= RookMobileProtocol.maximumMessageBytes else {
      close()
      return
    }
    Self.readExactly(Int(length), from: connection) { [weak self] result in
      Task { @MainActor in self?.receivedFrame(result) }
    }
  }

  private func receivedFrame(_ result: Result<Data, Error>) {
    do {
      let data = try result.get()
      let incomingKeyID = try RookMobileSecureChannel.keyID(in: data)
      if keyID == nil {
        keyID = incomingKeyID
        secret = try server?.resolveSecret(for: incomingKeyID)
      }
      guard let keyID, let secret else { throw RookMobileBridgeError.invalidKeyIdentity }
      let envelope = try RookMobileSecureChannel.open(
        data,
        expectedKeyID: keyID,
        secret: secret
      )
      server?.handle(envelope, from: self)
      receiveNextFrame()
    } catch {
      if keyID != nil { sendError(error, correlationID: nil) }
      close()
    }
  }

  private func close() {
    guard !isClosed else { return }
    isClosed = true
    connection.cancel()
    server?.removeConnection(id)
  }

  private nonisolated static func readExactly(
    _ count: Int,
    from connection: NWConnection,
    completion: @escaping @Sendable (Result<Data, Error>) -> Void
  ) {
    func read(_ accumulated: Data) {
      connection.receive(
        minimumIncompleteLength: 1,
        maximumLength: count - accumulated.count
      ) { content, _, isComplete, error in
        if let error {
          completion(.failure(error))
          return
        }
        var next = accumulated
        if let content { next.append(content) }
        if next.count == count {
          completion(.success(next))
        } else if isComplete || content == nil {
          completion(.failure(RookMobileBridgeError.invalidFrame))
        } else {
          read(next)
        }
      }
    }
    read(Data())
  }
}
