import Foundation
@preconcurrency import Network

enum RookMobileTransportError: LocalizedError {
  case discoveryTimedOut
  case macUnavailable
  case notConnected
  case connectionClosed
  case invalidFrame

  var errorDescription: String? {
    switch self {
    case .discoveryTimedOut:
      return "Rook could not find your Mac nearby or through its private relay."
    case .macUnavailable:
      return "Your Mac is offline or Rook is not running."
    case .notConnected:
      return "Rook is not connected to your Mac."
    case .connectionClosed:
      return "The private connection to your Mac closed."
    case .invalidFrame:
      return "Rook received an invalid private message."
    }
  }
}

private final class RookMobileContinuationGate<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?

  init(_ continuation: CheckedContinuation<Value, Error>) {
    self.continuation = continuation
  }

  @discardableResult
  func succeed(_ value: Value) -> Bool {
    resolve(.success(value))
  }

  @discardableResult
  func fail(_ error: Error) -> Bool {
    resolve(.failure(error))
  }

  private func resolve(_ result: Result<Value, Error>) -> Bool {
    let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
      defer { self.continuation = nil }
      return self.continuation
    }
    guard let continuation else { return false }
    switch result {
    case .success(let value): continuation.resume(returning: value)
    case .failure(let error): continuation.resume(throwing: error)
    }
    return true
  }
}

actor RookMobileClient {
  private enum Connection {
    case local(NWConnection)
    case relay(URLSessionWebSocketTask)
  }

  private let networkQueue = DispatchQueue(label: "com.noah.rook.mobile.network", qos: .userInitiated)
  private let relaySession: URLSession
  private var connection: Connection?
  private var keyID: String?
  private var secret: String?
  private var receiveBuffer = Data()

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.allowsCellularAccess = true
    configuration.allowsExpensiveNetworkAccess = true
    configuration.allowsConstrainedNetworkAccess = true
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 20
    relaySession = URLSession(configuration: configuration)
  }

  func connect(
    serviceID: UUID,
    keyID: String,
    secret: String,
    relayURL: URL?,
    relayAccessToken: String?,
    initialEnvelope: RookMobileEnvelope
  ) async throws {
    disconnect()

    if let relayURL, let relayAccessToken {
      #if DEBUG
        if CommandLine.arguments.contains("--rook-force-relay") {
          try await connectThroughRelay(
            endpoint: relayURL,
            keyID: keyID,
            secret: secret,
            relayAccessToken: relayAccessToken,
            initialEnvelope: initialEnvelope
          )
          return
        }
      #endif
      do {
        try await connectLocally(
          serviceID: serviceID,
          keyID: keyID,
          secret: secret,
          initialEnvelope: initialEnvelope,
          discoveryTimeout: 1.2
        )
        return
      } catch {
        disconnect()
      }

      try await connectThroughRelay(
        endpoint: relayURL,
        keyID: keyID,
        secret: secret,
        relayAccessToken: relayAccessToken,
        initialEnvelope: initialEnvelope
      )
      return
    }

    try await connectLocally(
      serviceID: serviceID,
      keyID: keyID,
      secret: secret,
      initialEnvelope: initialEnvelope,
      discoveryTimeout: 12
    )
  }

  func send(_ envelope: RookMobileEnvelope) async throws {
    guard let connection, let keyID, let secret else {
      throw RookMobileTransportError.notConnected
    }
    let encrypted = try RookMobileSecureChannel.seal(envelope, keyID: keyID, secret: secret)
    guard encrypted.count <= RookMobileProtocol.maximumMessageBytes else {
      throw RookMobilePolicyError.messageTooLarge
    }

    switch connection {
    case .local(let local):
      var length = UInt32(encrypted.count).bigEndian
      var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
      frame.append(encrypted)
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        local.send(
          content: frame,
          completion: .contentProcessed { error in
            if let error {
              continuation.resume(throwing: error)
            } else {
              continuation.resume(returning: ())
            }
          })
      }
    case .relay(let relay):
      try await relay.send(.data(encrypted))
    }
  }

  func receive() async throws -> RookMobileEnvelope {
    guard let connection, let keyID, let secret else {
      throw RookMobileTransportError.notConnected
    }

    let encrypted: Data
    switch connection {
    case .local:
      let header = try await readExactly(MemoryLayout<UInt32>.size)
      let length = header.withUnsafeBytes { rawBuffer -> UInt32 in
        rawBuffer.loadUnaligned(as: UInt32.self).bigEndian
      }
      guard length > 0, length <= RookMobileProtocol.maximumMessageBytes else {
        throw RookMobileTransportError.invalidFrame
      }
      encrypted = try await readExactly(Int(length))
    case .relay(let relay):
      encrypted = try await receiveRelayFrame(from: relay)
    }

    return try RookMobileSecureChannel.open(
      encrypted,
      expectedKeyID: keyID,
      secret: secret
    )
  }

  func disconnect() {
    switch connection {
    case .local(let local):
      local.cancel()
    case .relay(let relay):
      relay.cancel(with: .goingAway, reason: nil)
    case nil:
      break
    }
    connection = nil
    keyID = nil
    secret = nil
    receiveBuffer.removeAll(keepingCapacity: false)
  }

  private func connectLocally(
    serviceID: UUID,
    keyID: String,
    secret: String,
    initialEnvelope: RookMobileEnvelope,
    discoveryTimeout: TimeInterval
  ) async throws {
    let endpoint = try await discover(serviceID: serviceID, timeout: discoveryTimeout)
    let local = NWConnection(to: endpoint, using: .tcp)
    try await start(local)
    connection = .local(local)
    self.keyID = keyID
    self.secret = secret
    receiveBuffer.removeAll(keepingCapacity: true)
    try await send(initialEnvelope)
  }

  private func discover(serviceID: UUID, timeout: TimeInterval) async throws -> NWEndpoint {
    let expectedName = RookMobileBonjour.serviceName(for: serviceID)
    return try await withCheckedThrowingContinuation { continuation in
      let gate = RookMobileContinuationGate<NWEndpoint>(continuation)
      let browser = NWBrowser(
        for: .bonjour(type: RookMobileBonjour.serviceType, domain: nil),
        using: .tcp
      )
      browser.browseResultsChangedHandler = { results, _ in
        guard
          let endpoint = results.lazy.map(\.endpoint).first(where: { endpoint in
            guard case .service(let name, _, _, _) = endpoint else { return false }
            return name.caseInsensitiveCompare(expectedName) == .orderedSame
          })
        else { return }
        gate.succeed(endpoint)
        browser.cancel()
      }
      browser.stateUpdateHandler = { state in
        switch state {
        case .failed(let error):
          gate.fail(error)
          browser.cancel()
        case .cancelled:
          break
        default:
          break
        }
      }
      browser.start(queue: networkQueue)
      networkQueue.asyncAfter(deadline: .now() + timeout) {
        if gate.fail(RookMobileTransportError.discoveryTimedOut) { browser.cancel() }
      }
    }
  }

  private func start(_ local: NWConnection) async throws {
    try await withCheckedThrowingContinuation { continuation in
      let gate = RookMobileContinuationGate<Void>(continuation)
      local.stateUpdateHandler = { state in
        switch state {
        case .ready:
          gate.succeed(())
        case .failed(let error):
          gate.fail(error)
        case .cancelled:
          gate.fail(RookMobileTransportError.connectionClosed)
        default:
          break
        }
      }
      local.start(queue: networkQueue)
      networkQueue.asyncAfter(deadline: .now() + 12) {
        if gate.fail(RookMobileTransportError.macUnavailable) { local.cancel() }
      }
    }
  }

  private func startRelay(
    endpoint: URL,
    secret: String,
    relayAccessToken: String
  ) async throws -> URLSessionWebSocketTask {
    let request = try RookMobileRelay.request(
      endpoint: endpoint,
      role: .phone,
      sessionToken: secret,
      accessToken: relayAccessToken
    )
    let socket = relaySession.webSocketTask(with: request)
    socket.maximumMessageSize = RookMobileProtocol.maximumMessageBytes
    socket.resume()

    do {
      while true {
        let message = try await receiveRelayMessage(from: socket, timeout: 15)
        guard case .string(let text) = message else {
          throw RookMobileRelayError.invalidControlMessage
        }
        let control = try RookMobileRelay.decodeControl(text)
        switch control.type {
        case .ready:
          continue
        case .peer where control.connected == true:
          return socket
        case .peer:
          continue
        case .error:
          throw RookMobileRelayError.unavailable
        }
      }
    } catch {
      socket.cancel(with: .goingAway, reason: nil)
      throw error
    }
  }

  private func connectThroughRelay(
    endpoint: URL,
    keyID: String,
    secret: String,
    relayAccessToken: String,
    initialEnvelope: RookMobileEnvelope
  ) async throws {
    let socket = try await startRelay(
      endpoint: endpoint,
      secret: secret,
      relayAccessToken: relayAccessToken
    )
    connection = .relay(socket)
    self.keyID = keyID
    self.secret = secret
    try await send(initialEnvelope)
  }

  private func receiveRelayMessage(
    from relay: URLSessionWebSocketTask,
    timeout: TimeInterval
  ) async throws -> URLSessionWebSocketTask.Message {
    try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
      group.addTask { try await relay.receive() }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw RookMobileRelayError.unavailable
      }
      guard let result = try await group.next() else {
        throw RookMobileRelayError.unavailable
      }
      group.cancelAll()
      return result
    }
  }

  private func receiveRelayFrame(from relay: URLSessionWebSocketTask) async throws -> Data {
    while true {
      switch try await relay.receive() {
      case .data(let data):
        guard !data.isEmpty, data.count <= RookMobileProtocol.maximumMessageBytes else {
          throw RookMobileTransportError.invalidFrame
        }
        return data
      case .string(let text):
        let control = try RookMobileRelay.decodeControl(text)
        switch control.type {
        case .ready:
          continue
        case .peer where control.connected == true:
          continue
        case .peer:
          throw RookMobileRelayError.peerUnavailable
        case .error:
          throw RookMobileRelayError.unavailable
        }
      @unknown default:
        throw RookMobileTransportError.invalidFrame
      }
    }
  }

  private func readExactly(_ count: Int) async throws -> Data {
    while receiveBuffer.count < count {
      let chunk = try await receiveChunk(maximumLength: max(count - receiveBuffer.count, 16_384))
      receiveBuffer.append(chunk)
    }
    let value = receiveBuffer.prefix(count)
    receiveBuffer.removeFirst(count)
    return Data(value)
  }

  private func receiveChunk(maximumLength: Int) async throws -> Data {
    guard case .local(let local) = connection else {
      throw RookMobileTransportError.notConnected
    }
    return try await withCheckedThrowingContinuation { continuation in
      local.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
        content, _, isComplete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let content, !content.isEmpty {
          continuation.resume(returning: content)
        } else if isComplete {
          continuation.resume(throwing: RookMobileTransportError.connectionClosed)
        } else {
          continuation.resume(throwing: RookMobileTransportError.invalidFrame)
        }
      }
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}
