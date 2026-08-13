import Foundation
import RookKit

@MainActor
final class RookMobileRelayHostConnection: RookMobileHostClient {
  let id = UUID()
  private(set) var isAuthenticated = false
  var onStateChange: ((String) -> Void)?

  private let deviceID: UUID
  private let sessionToken: String
  private let relayAccessToken: String
  private let endpoint: URL
  private weak var server: RookMobileBridgeServer?
  private let urlSession: URLSession

  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var reconnectAttempt = 0
  private var peerConnected = false
  private var pendingRequest = RookMobilePendingRequest()
  private var lastSnapshotSentAt = Date.distantPast
  private var sendQueue: [Data] = []
  private var isSending = false
  private var isStopped = false

  init(
    deviceID: UUID,
    sessionToken: String,
    relayAccessToken: String,
    endpoint: URL,
    server: RookMobileBridgeServer
  ) {
    self.deviceID = deviceID
    self.sessionToken = sessionToken
    self.relayAccessToken = relayAccessToken
    self.endpoint = endpoint
    self.server = server
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 20
    urlSession = URLSession(configuration: configuration)
  }

  deinit {
    receiveTask?.cancel()
    heartbeatTask?.cancel()
    reconnectTask?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    urlSession.invalidateAndCancel()
  }

  func start() {
    guard !isStopped, socket == nil else { return }
    onStateChange?("opening")
    openSocket()
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    receiveTask?.cancel()
    heartbeatTask?.cancel()
    reconnectTask?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    urlSession.invalidateAndCancel()
    resetPeer()
    onStateChange?("stopped")
  }

  func markAuthenticated(deviceID: UUID, deviceName: String) {
    isAuthenticated = deviceID == self.deviceID
  }

  func beginRequest(id: UUID) {
    pendingRequest.begin(id: id)
  }

  func synchronize(with state: RookMobileBridgeState) {
    guard peerConnected else { return }
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
    guard !isStopped, peerConnected else { return }
    do {
      let encrypted = try RookMobileSecureChannel.seal(
        envelope,
        keyID: RookMobileSecureChannel.deviceKeyID(deviceID: deviceID),
        secret: sessionToken
      )
      sendQueue.append(encrypted)
      drainSendQueue()
    } catch {
      reconnect()
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

  private func openSocket() {
    do {
      let request = try RookMobileRelay.request(
        endpoint: endpoint,
        role: .host,
        sessionToken: sessionToken,
        accessToken: relayAccessToken
      )
      let nextSocket = urlSession.webSocketTask(with: request)
      nextSocket.maximumMessageSize = RookMobileProtocol.maximumMessageBytes
      socket = nextSocket
      nextSocket.resume()

      receiveTask = Task { [weak self, weak nextSocket] in
        guard let self, let nextSocket else { return }
        await self.receiveLoop(from: nextSocket)
      }
      heartbeatTask = Task { [weak self, weak nextSocket] in
        guard let self, let nextSocket else { return }
        await self.heartbeatLoop(on: nextSocket)
      }
    } catch {
      scheduleReconnect()
    }
  }

  private func receiveLoop(from activeSocket: URLSessionWebSocketTask) async {
    do {
      while !Task.isCancelled, socket === activeSocket {
        let message = try await activeSocket.receive()
        switch message {
        case .data(let data):
          try receiveEncryptedFrame(data)
        case .string(let text):
          try receiveControl(text)
        @unknown default:
          throw RookMobileRelayError.invalidControlMessage
        }
      }
    } catch {
      guard !Task.isCancelled else { return }
      connectionEnded(activeSocket)
    }
  }

  private func heartbeatLoop(on activeSocket: URLSessionWebSocketTask) async {
    do {
      while !Task.isCancelled, socket === activeSocket {
        try await Task.sleep(nanoseconds: 25_000_000_000)
        guard socket === activeSocket else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          activeSocket.sendPing { error in
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume(returning: ())
            }
          }
        }
      }
    } catch {
      guard !Task.isCancelled else { return }
      connectionEnded(activeSocket)
    }
  }

  private func receiveControl(_ text: String) throws {
    let control = try RookMobileRelay.decodeControl(text)
    switch control.type {
    case .ready:
      reconnectAttempt = 0
      onStateChange?("relay_ready")
    case .peer where control.connected == true:
      resetPeer()
      peerConnected = true
      onStateChange?("peer_connected")
    case .peer:
      resetPeer()
      onStateChange?("waiting_for_phone")
    case .error:
      throw RookMobileRelayError.unavailable
    }
  }

  private func receiveEncryptedFrame(_ data: Data) throws {
    guard peerConnected, !data.isEmpty, data.count <= RookMobileProtocol.maximumMessageBytes else {
      throw RookMobileBridgeError.invalidFrame
    }
    let envelope = try RookMobileSecureChannel.open(
      data,
      expectedKeyID: RookMobileSecureChannel.deviceKeyID(deviceID: deviceID),
      secret: sessionToken
    )
    server?.handle(envelope, from: self)
  }

  private func drainSendQueue() {
    guard !isSending, let activeSocket = socket, peerConnected else { return }
    isSending = true
    Task { [weak self, weak activeSocket] in
      guard let self, let activeSocket else { return }
      while !Task.isCancelled, self.socket === activeSocket, !self.sendQueue.isEmpty {
        let data = self.sendQueue.removeFirst()
        do {
          try await activeSocket.send(.data(data))
        } catch {
          self.isSending = false
          self.connectionEnded(activeSocket)
          return
        }
      }
      self.isSending = false
    }
  }

  private func connectionEnded(_ activeSocket: URLSessionWebSocketTask) {
    guard socket === activeSocket else { return }
    socket = nil
    receiveTask?.cancel()
    receiveTask = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
    activeSocket.cancel(with: .goingAway, reason: nil)
    resetPeer()
    onStateChange?("reconnecting")
    scheduleReconnect()
  }

  private func reconnect() {
    guard let activeSocket = socket else {
      scheduleReconnect()
      return
    }
    connectionEnded(activeSocket)
  }

  private func scheduleReconnect() {
    guard !isStopped, reconnectTask == nil else { return }
    let exponent = min(reconnectAttempt, 5)
    let delay = UInt64(min(30, 1 << exponent))
    reconnectAttempt += 1
    onStateChange?("retry_scheduled")
    reconnectTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay * 1_000_000_000)
      } catch {
        return
      }
      guard let self, !self.isStopped else { return }
      self.reconnectTask = nil
      self.openSocket()
    }
  }

  private func resetPeer() {
    isAuthenticated = false
    peerConnected = false
    pendingRequest.cancel()
    lastSnapshotSentAt = .distantPast
    sendQueue.removeAll(keepingCapacity: true)
    isSending = false
  }
}
