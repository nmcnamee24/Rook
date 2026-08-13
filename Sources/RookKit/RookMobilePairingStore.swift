import CryptoKit
import Foundation
import Security

public struct RookMobilePairingOffer: Equatable, Sendable {
  public let serviceID: UUID
  public let oneTimeCode: String
  public let secret: String
  public let expiresAt: Date
  public let relayURL: URL?
  public let relayAccessToken: String?

  public init(
    serviceID: UUID,
    oneTimeCode: String,
    secret: String,
    expiresAt: Date,
    relayURL: URL? = nil,
    relayAccessToken: String? = nil
  ) {
    self.serviceID = serviceID
    self.oneTimeCode = oneTimeCode
    self.secret = secret
    self.expiresAt = expiresAt
    self.relayURL = relayURL
    self.relayAccessToken = relayAccessToken
  }

  public var payload: RookMobilePairingPayload {
    RookMobilePairingPayload(
      serviceID: serviceID,
      oneTimeCode: oneTimeCode,
      secret: secret,
      expiresAt: expiresAt,
      relayURL: relayURL,
      relayAccessToken: relayAccessToken
    )
  }
}

public struct RookMobilePairedDeviceSummary: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let name: String
  public let pairedAt: Date
  public var lastSeenAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case pairedAt = "paired_at"
    case lastSeenAt = "last_seen_at"
  }
}

public enum RookMobilePairingError: LocalizedError, Equatable {
  case noActiveOffer
  case offerExpired
  case codeMismatch
  case secureRandomFailed
  case deviceNotPaired

  public var errorDescription: String? {
    switch self {
    case .noActiveOffer: return "Start a new iPhone pairing session on this Mac."
    case .offerExpired: return "That pairing code expired. Start a new pairing session."
    case .codeMismatch: return "The pairing code does not match."
    case .secureRandomFailed: return "Rook could not create secure pairing material."
    case .deviceNotPaired: return "This iPhone is not paired with Rook."
    }
  }
}

public final class RookMobilePairingStore: @unchecked Sendable {
  private struct StoredDevice: Codable, Equatable {
    let id: UUID
    var name: String
    let tokenDigest: String
    let pairedAt: Date
    var lastSeenAt: Date

    enum CodingKeys: String, CodingKey {
      case id
      case name
      case tokenDigest = "token_digest"
      case pairedAt = "paired_at"
      case lastSeenAt = "last_seen_at"
    }

    var summary: RookMobilePairedDeviceSummary {
      RookMobilePairedDeviceSummary(
        id: id,
        name: name,
        pairedAt: pairedAt,
        lastSeenAt: lastSeenAt
      )
    }
  }

  private struct Document: Codable {
    var version: Int
    var devices: [StoredDevice]
  }

  private let stateDirectory: URL
  private let documentURL: URL
  private let lock = NSLock()
  private var activeOffer: RookMobilePairingOffer?

  public init(stateDirectory: URL) throws {
    self.stateDirectory = stateDirectory
    documentURL = stateDirectory.appendingPathComponent("mobile_pairing.json")
    try ensureStateDirectory()
    if !FileManager.default.fileExists(atPath: documentURL.path) {
      try save(Document(version: 1, devices: []))
    }
  }

  public func beginPairing(
    serviceID: UUID,
    relayURL: URL? = nil,
    relayAccessToken: String? = nil,
    now: Date = Date(),
    lifetime: TimeInterval = 5 * 60
  ) throws -> RookMobilePairingOffer {
    let code = try Self.secureDigits(count: 6)
    let offer = RookMobilePairingOffer(
      serviceID: serviceID,
      oneTimeCode: code,
      secret: try Self.secureToken(),
      expiresAt: now.addingTimeInterval(lifetime),
      relayURL: relayURL,
      relayAccessToken: relayAccessToken
    )
    lock.withLock { activeOffer = offer }
    return offer
  }

  public func accept(
    _ request: RookMobilePairRequest,
    hostName: String,
    now: Date = Date()
  ) throws -> RookMobilePairAccepted {
    let envelope = RookMobileEnvelope(sentAt: now, payload: .pairRequest(request))
    try RookMobileSessionPolicy.validateHostInbound(
      envelope,
      authenticated: false,
      now: now
    )

    return try lock.withLock {
      guard let offer = activeOffer else { throw RookMobilePairingError.noActiveOffer }
      guard now <= offer.expiresAt else {
        activeOffer = nil
        throw RookMobilePairingError.offerExpired
      }
      guard Self.constantTimeEqual(request.oneTimeCode, offer.oneTimeCode) else {
        throw RookMobilePairingError.codeMismatch
      }

      let token = try Self.secureToken()
      var document = try load()
      let name = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
      let stored = StoredDevice(
        id: request.deviceID,
        name: name,
        tokenDigest: Self.digest(token),
        pairedAt: now,
        lastSeenAt: now
      )
      document.devices.removeAll { $0.id == request.deviceID }
      document.devices.append(stored)
      try save(document)
      activeOffer = nil

      return RookMobilePairAccepted(
        hostName: hostName,
        sessionToken: token,
        capabilities: RookMobileCapability.allCases
      )
    }
  }

  public func authenticate(
    _ authentication: RookMobileAuthentication,
    now: Date = Date()
  ) throws -> RookMobilePairedDeviceSummary {
    try lock.withLock {
      var document = try load()
      guard let index = document.devices.firstIndex(where: { $0.id == authentication.deviceID }),
        Self.constantTimeEqual(
          document.devices[index].tokenDigest,
          Self.digest(authentication.sessionToken)
        )
      else {
        throw RookMobilePairingError.deviceNotPaired
      }
      document.devices[index].lastSeenAt = now
      try save(document)
      return document.devices[index].summary
    }
  }

  public func pairedDevices() throws -> [RookMobilePairedDeviceSummary] {
    try lock.withLock {
      try load().devices
        .map(\.summary)
        .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }
  }

  public func revoke(deviceID: UUID) throws {
    try lock.withLock {
      var document = try load()
      document.devices.removeAll { $0.id == deviceID }
      try save(document)
    }
  }

  public func cancelPairing() {
    lock.withLock { activeOffer = nil }
  }

  public func pairingSecret(serviceID: UUID, now: Date = Date()) -> String? {
    lock.withLock {
      guard let offer = activeOffer, offer.serviceID == serviceID, offer.expiresAt >= now else {
        return nil
      }
      return offer.secret
    }
  }

  private func ensureStateDirectory() throws {
    try FileManager.default.createDirectory(
      at: stateDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: stateDirectory.path
    )
  }

  private func load() throws -> Document {
    let data = try Data(contentsOf: documentURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Document.self, from: data)
  }

  private func save(_ document: Document) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(document)
    let temporary = documentURL.appendingPathExtension("tmp")
    try data.write(to: temporary, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: temporary.path
    )
    if FileManager.default.fileExists(atPath: documentURL.path) {
      _ = try FileManager.default.replaceItemAt(documentURL, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: documentURL)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: documentURL.path
    )
  }

  private static func secureDigits(count: Int) throws -> String {
    let bytes = try secureBytes(count: count)
    return bytes.map { String(Int($0) % 10) }.joined()
  }

  private static func secureToken() throws -> String {
    Data(try secureBytes(count: 32)).base64EncodedString()
  }

  private static func secureBytes(count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
      throw RookMobilePairingError.secureRandomFailed
    }
    return bytes
  }

  private static func digest(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { difference, pair in
      difference | (pair.0 ^ pair.1)
    } == 0
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
