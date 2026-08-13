import Foundation

public enum RookMobileProtocol {
  public static let currentVersion = 2
  public static let maximumMessageBytes = 1_048_576
  public static let maximumCommandCharacters = 4_000
  public static let maximumClockSkew: TimeInterval = 5 * 60
}

public enum RookMobileCapability: String, Codable, CaseIterable, Sendable {
  case command
  case canvas
  case activity
  case library
  case moves
  case allies
  case voice
}

public enum RookMobileCommandSource: String, Codable, Sendable {
  case typed
  case voice
  case shortcut
}

public enum RookMobileMoveStatus: String, Codable, Sendable {
  case pending
  case approved
}

public enum RookMobileMoveDecisionAction: String, Codable, Sendable {
  case approve
  case reject
}

public struct RookMobilePairRequest: Codable, Equatable, Sendable {
  public let deviceID: UUID
  public let deviceName: String
  public let oneTimeCode: String

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case deviceName = "device_name"
    case oneTimeCode = "one_time_code"
  }

  public init(deviceID: UUID, deviceName: String, oneTimeCode: String) {
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.oneTimeCode = oneTimeCode
  }
}

public struct RookMobilePairAccepted: Codable, Equatable, Sendable {
  public let hostName: String
  public let sessionToken: String
  public let capabilities: [RookMobileCapability]

  enum CodingKeys: String, CodingKey {
    case hostName = "host_name"
    case sessionToken = "session_token"
    case capabilities
  }

  public init(
    hostName: String,
    sessionToken: String,
    capabilities: [RookMobileCapability]
  ) {
    self.hostName = hostName
    self.sessionToken = sessionToken
    self.capabilities = capabilities
  }
}

public struct RookMobileAuthentication: Codable, Equatable, Sendable {
  public let deviceID: UUID
  public let sessionToken: String

  enum CodingKeys: String, CodingKey {
    case deviceID = "device_id"
    case sessionToken = "session_token"
  }

  public init(deviceID: UUID, sessionToken: String) {
    self.deviceID = deviceID
    self.sessionToken = sessionToken
  }
}

public struct RookMobileCommand: Codable, Equatable, Sendable {
  public let text: String
  public let source: RookMobileCommandSource

  public init(text: String, source: RookMobileCommandSource) {
    self.text = text
    self.source = source
  }

  public var normalizedText: String {
    text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct RookMobileProgress: Codable, Equatable, Sendable {
  public let phase: String
  public let displayText: String
  public let pawns: [PawnReport]

  enum CodingKeys: String, CodingKey {
    case phase
    case displayText = "display_text"
    case pawns
  }

  public init(phase: String, displayText: String, pawns: [PawnReport] = []) {
    self.phase = phase
    self.displayText = displayText
    self.pawns = pawns
  }
}

public enum RookMobilePendingRequestUpdate: Equatable, Sendable {
  case waiting
  case progress(RookMobileProgress)
  case response(RookResponse)
}

public struct RookMobilePendingRequest: Equatable, Sendable {
  public private(set) var requestID: UUID?

  public init() {}

  public var isPending: Bool { requestID != nil }

  public mutating func begin(id: UUID) {
    requestID = id
  }

  public mutating func cancel() {
    requestID = nil
  }

  public mutating func update(
    hostRequestID: UUID?,
    isWorking: Bool,
    progress: RookMobileProgress,
    response: RookResponse?
  ) -> RookMobilePendingRequestUpdate {
    guard let requestID, hostRequestID == requestID else { return .waiting }
    if isWorking {
      return .progress(progress)
    }
    guard let response else { return .waiting }
    self.requestID = nil
    return .response(response)
  }
}

public struct RookMobileLibraryItem: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let label: String
  public let summary: String
  public let status: String
  public let updatedAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case label
    case summary
    case status
    case updatedAt = "updated_at"
  }

  public init(id: UUID, label: String, summary: String, status: String, updatedAt: Date) {
    self.id = id
    self.label = label
    self.summary = summary
    self.status = status
    self.updatedAt = updatedAt
  }
}

public enum RookMobileActivityStatus: String, Codable, Sendable {
  case queued
  case working
  case completed
  case blocked
  case interrupted
}

public struct RookMobileActivityItem: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let label: String
  public let status: RookMobileActivityStatus
  public let startedAt: Date
  public let updatedAt: Date
  public let pawns: [PawnReport]

  enum CodingKeys: String, CodingKey {
    case id
    case label
    case status
    case startedAt = "started_at"
    case updatedAt = "updated_at"
    case pawns
  }

  public init(
    id: UUID,
    label: String,
    status: RookMobileActivityStatus,
    startedAt: Date,
    updatedAt: Date,
    pawns: [PawnReport]
  ) {
    self.id = id
    self.label = label
    self.status = status
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.pawns = pawns
  }
}

public enum RookMobileAllyState: String, Codable, Sendable {
  case direct
  case codex
  case local
  case connecting
  case attention
}

public struct RookMobileAlly: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let detail: String
  public let state: RookMobileAllyState

  public init(id: String, label: String, detail: String, state: RookMobileAllyState) {
    self.id = id
    self.label = label
    self.detail = detail
    self.state = state
  }
}

public struct RookMobileMove: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let details: String
  public let proposedAction: String
  public let risk: String
  public let status: RookMobileMoveStatus
  public let expiresAt: Date?

  enum CodingKeys: String, CodingKey {
    case id
    case label
    case details
    case proposedAction = "proposed_action"
    case risk
    case status
    case expiresAt = "expires_at"
  }

  public init(
    id: String,
    label: String,
    details: String,
    proposedAction: String,
    risk: String,
    status: RookMobileMoveStatus,
    expiresAt: Date?
  ) {
    self.id = id
    self.label = label
    self.details = details
    self.proposedAction = proposedAction
    self.risk = risk
    self.status = status
    self.expiresAt = expiresAt
  }
}

public struct RookMobileSnapshot: Codable, Equatable, Sendable {
  public let latestResponse: RookResponse?
  public let activity: [RookMobileActivityItem]
  public let library: [RookMobileLibraryItem]
  public let moves: [RookMobileMove]
  public let allies: [RookMobileAlly]
  public let hostStatus: String
  public let asOf: Date

  enum CodingKeys: String, CodingKey {
    case latestResponse = "latest_response"
    case activity
    case library
    case moves
    case allies
    case hostStatus = "host_status"
    case asOf = "as_of"
  }

  public init(
    latestResponse: RookResponse?,
    activity: [RookMobileActivityItem] = [],
    library: [RookMobileLibraryItem],
    moves: [RookMobileMove],
    allies: [RookMobileAlly] = [],
    hostStatus: String,
    asOf: Date
  ) {
    self.latestResponse = latestResponse
    self.activity = activity
    self.library = library
    self.moves = moves
    self.allies = allies
    self.hostStatus = hostStatus
    self.asOf = asOf
  }
}

public struct RookMobileMoveDecision: Codable, Equatable, Sendable {
  public let moveID: String
  public let action: RookMobileMoveDecisionAction

  enum CodingKeys: String, CodingKey {
    case moveID = "move_id"
    case action
  }

  public init(moveID: String, action: RookMobileMoveDecisionAction) {
    self.moveID = moveID
    self.action = action
  }
}

public struct RookMobileErrorMessage: Codable, Equatable, Sendable {
  public let code: String
  public let message: String
  public let recoverable: Bool

  public init(code: String, message: String, recoverable: Bool) {
    self.code = code
    self.message = message
    self.recoverable = recoverable
  }
}

public struct RookMobilePing: Codable, Equatable, Sendable {
  public let nonce: UUID

  public init(nonce: UUID = UUID()) {
    self.nonce = nonce
  }
}

public enum RookMobilePayload: Equatable, Sendable {
  case pairRequest(RookMobilePairRequest)
  case pairAccepted(RookMobilePairAccepted)
  case authenticate(RookMobileAuthentication)
  case command(RookMobileCommand)
  case progress(RookMobileProgress)
  case response(RookResponse)
  case snapshot(RookMobileSnapshot)
  case moveDecision(RookMobileMoveDecision)
  case error(RookMobileErrorMessage)
  case ping(RookMobilePing)
}

extension RookMobilePayload: Codable {
  private enum CodingKeys: String, CodingKey {
    case type
    case body
  }

  private enum Kind: String, Codable {
    case pairRequest = "pair_request"
    case pairAccepted = "pair_accepted"
    case authenticate
    case command
    case progress
    case response
    case snapshot
    case moveDecision = "move_decision"
    case error
    case ping
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .pairRequest:
      self = .pairRequest(try container.decode(RookMobilePairRequest.self, forKey: .body))
    case .pairAccepted:
      self = .pairAccepted(try container.decode(RookMobilePairAccepted.self, forKey: .body))
    case .authenticate:
      self = .authenticate(try container.decode(RookMobileAuthentication.self, forKey: .body))
    case .command:
      self = .command(try container.decode(RookMobileCommand.self, forKey: .body))
    case .progress:
      self = .progress(try container.decode(RookMobileProgress.self, forKey: .body))
    case .response:
      self = .response(try container.decode(RookResponse.self, forKey: .body))
    case .snapshot:
      self = .snapshot(try container.decode(RookMobileSnapshot.self, forKey: .body))
    case .moveDecision:
      self = .moveDecision(try container.decode(RookMobileMoveDecision.self, forKey: .body))
    case .error:
      self = .error(try container.decode(RookMobileErrorMessage.self, forKey: .body))
    case .ping:
      self = .ping(try container.decode(RookMobilePing.self, forKey: .body))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pairRequest(let value):
      try container.encode(Kind.pairRequest, forKey: .type)
      try container.encode(value, forKey: .body)
    case .pairAccepted(let value):
      try container.encode(Kind.pairAccepted, forKey: .type)
      try container.encode(value, forKey: .body)
    case .authenticate(let value):
      try container.encode(Kind.authenticate, forKey: .type)
      try container.encode(value, forKey: .body)
    case .command(let value):
      try container.encode(Kind.command, forKey: .type)
      try container.encode(value, forKey: .body)
    case .progress(let value):
      try container.encode(Kind.progress, forKey: .type)
      try container.encode(value, forKey: .body)
    case .response(let value):
      try container.encode(Kind.response, forKey: .type)
      try container.encode(value, forKey: .body)
    case .snapshot(let value):
      try container.encode(Kind.snapshot, forKey: .type)
      try container.encode(value, forKey: .body)
    case .moveDecision(let value):
      try container.encode(Kind.moveDecision, forKey: .type)
      try container.encode(value, forKey: .body)
    case .error(let value):
      try container.encode(Kind.error, forKey: .type)
      try container.encode(value, forKey: .body)
    case .ping(let value):
      try container.encode(Kind.ping, forKey: .type)
      try container.encode(value, forKey: .body)
    }
  }
}

public struct RookMobileEnvelope: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let id: UUID
  public let correlationID: UUID?
  public let sentAt: Date
  public let payload: RookMobilePayload

  enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol_version"
    case id
    case correlationID = "correlation_id"
    case sentAt = "sent_at"
    case payload
  }

  public init(
    protocolVersion: Int = RookMobileProtocol.currentVersion,
    id: UUID = UUID(),
    correlationID: UUID? = nil,
    sentAt: Date = Date(),
    payload: RookMobilePayload
  ) {
    self.protocolVersion = protocolVersion
    self.id = id
    self.correlationID = correlationID
    self.sentAt = sentAt
    self.payload = payload
  }
}

public enum RookMobileCodec {
  public static func encode(_ envelope: RookMobileEnvelope) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(envelope)
    guard data.count <= RookMobileProtocol.maximumMessageBytes else {
      throw RookMobilePolicyError.messageTooLarge
    }
    return data
  }

  public static func decode(_ data: Data) throws -> RookMobileEnvelope {
    guard data.count <= RookMobileProtocol.maximumMessageBytes else {
      throw RookMobilePolicyError.messageTooLarge
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(RookMobileEnvelope.self, from: data)
  }
}

public enum RookMobilePolicyError: LocalizedError, Equatable {
  case unsupportedVersion
  case staleMessage
  case replayedMessage
  case messageTooLarge
  case payloadNotAllowed
  case authenticationRequired
  case invalidPairingCode
  case invalidDeviceName
  case invalidSessionToken
  case invalidCommand
  case invalidMove

  public var errorDescription: String? {
    switch self {
    case .unsupportedVersion: return "This Rook mobile protocol version is not supported."
    case .staleMessage: return "The Rook mobile message is outside the allowed time window."
    case .replayedMessage: return "Rook rejected a repeated private message."
    case .messageTooLarge: return "The Rook mobile message is too large."
    case .payloadNotAllowed: return "This message is not allowed in that direction."
    case .authenticationRequired: return "Pair this device before sending that request."
    case .invalidPairingCode: return "The pairing code must contain exactly six digits."
    case .invalidDeviceName: return "The device name is missing or too long."
    case .invalidSessionToken: return "The pairing session token is invalid."
    case .invalidCommand: return "The command is empty or too long."
    case .invalidMove: return "The requested move is invalid."
    }
  }
}

public struct RookMobileReplayGuard: Sendable {
  private let capacity: Int
  private var order: [UUID] = []
  private var identifiers: Set<UUID> = []

  public init(capacity: Int = 512) {
    self.capacity = max(32, capacity)
  }

  public mutating func admit(_ envelope: RookMobileEnvelope) throws {
    guard identifiers.insert(envelope.id).inserted else {
      throw RookMobilePolicyError.replayedMessage
    }
    order.append(envelope.id)
    while order.count > capacity {
      identifiers.remove(order.removeFirst())
    }
  }
}

public enum RookMobileSessionPolicy {
  public static func validateHostInbound(
    _ envelope: RookMobileEnvelope,
    authenticated: Bool,
    now: Date = Date()
  ) throws {
    try validateEnvelope(envelope, now: now)

    switch envelope.payload {
    case .pairRequest(let request):
      try validatePairRequest(request)
    case .authenticate(let authentication):
      try validateAuthentication(authentication)
    case .command(let command):
      guard authenticated else { throw RookMobilePolicyError.authenticationRequired }
      try validateCommand(command)
    case .moveDecision(let decision):
      guard authenticated else { throw RookMobilePolicyError.authenticationRequired }
      try validateMoveDecision(decision)
    case .ping:
      break
    case .pairAccepted, .progress, .response, .snapshot, .error:
      throw RookMobilePolicyError.payloadNotAllowed
    }
  }

  public static func validatePhoneInbound(
    _ envelope: RookMobileEnvelope,
    now: Date = Date()
  ) throws {
    try validateEnvelope(envelope, now: now)

    switch envelope.payload {
    case .pairAccepted(let accepted):
      try validatePairAccepted(accepted)
    case .progress, .response, .snapshot, .error, .ping:
      break
    case .pairRequest, .authenticate, .command, .moveDecision:
      throw RookMobilePolicyError.payloadNotAllowed
    }
  }

  private static func validateEnvelope(_ envelope: RookMobileEnvelope, now: Date) throws {
    guard envelope.protocolVersion == RookMobileProtocol.currentVersion else {
      throw RookMobilePolicyError.unsupportedVersion
    }
    guard abs(envelope.sentAt.timeIntervalSince(now)) <= RookMobileProtocol.maximumClockSkew else {
      throw RookMobilePolicyError.staleMessage
    }
  }

  private static func validatePairRequest(_ request: RookMobilePairRequest) throws {
    let deviceName = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !deviceName.isEmpty, deviceName.count <= 80 else {
      throw RookMobilePolicyError.invalidDeviceName
    }
    guard request.oneTimeCode.count == 6,
      request.oneTimeCode.allSatisfy(\.isNumber)
    else {
      throw RookMobilePolicyError.invalidPairingCode
    }
  }

  private static func validatePairAccepted(_ accepted: RookMobilePairAccepted) throws {
    let hostName = accepted.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hostName.isEmpty, hostName.count <= 80 else {
      throw RookMobilePolicyError.invalidDeviceName
    }
    try validateToken(accepted.sessionToken)
  }

  private static func validateAuthentication(_ authentication: RookMobileAuthentication) throws {
    try validateToken(authentication.sessionToken)
  }

  private static func validateToken(_ token: String) throws {
    guard (32...512).contains(token.count),
      token.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace })
    else {
      throw RookMobilePolicyError.invalidSessionToken
    }
  }

  private static func validateCommand(_ command: RookMobileCommand) throws {
    guard !command.normalizedText.isEmpty,
      command.normalizedText.count <= RookMobileProtocol.maximumCommandCharacters
    else {
      throw RookMobilePolicyError.invalidCommand
    }
  }

  private static func validateMoveDecision(_ decision: RookMobileMoveDecision) throws {
    guard decision.moveID.range(of: #"^RQ-[0-9]{4,}$"#, options: .regularExpression) != nil else {
      throw RookMobilePolicyError.invalidMove
    }
  }
}
