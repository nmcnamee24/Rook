import CryptoKit
import Foundation

public enum RookMobileBonjour {
  public static let serviceType = "_rook._tcp"

  public static func serviceName(for serviceID: UUID) -> String {
    "Rook-\(serviceID.uuidString.lowercased())"
  }
}

public struct RookMobilePairingPayload: Equatable, Sendable {
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

  public var url: URL? {
    var components = URLComponents()
    components.scheme = "rook"
    components.host = "pair"
    var queryItems = [
      URLQueryItem(name: "v", value: String(RookMobileProtocol.currentVersion)),
      URLQueryItem(name: "service", value: serviceID.uuidString.lowercased()),
      URLQueryItem(name: "code", value: oneTimeCode),
      URLQueryItem(name: "secret", value: secret),
      URLQueryItem(name: "expires", value: String(Int(expiresAt.timeIntervalSince1970))),
    ]
    if let relayURL {
      queryItems.append(URLQueryItem(name: "relay", value: relayURL.absoluteString))
    }
    if let relayAccessToken {
      queryItems.append(URLQueryItem(name: "relay_key", value: relayAccessToken))
    }
    components.queryItems = queryItems
    return components.url
  }

  public init(url: URL, now: Date = Date()) throws {
    guard url.scheme?.lowercased() == "rook", url.host?.lowercased() == "pair",
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw RookMobilePairingPayloadError.invalidCode }

    let values = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
      if result[item.name] == nil, let value = item.value { result[item.name] = value }
    }
    guard values["v"] == String(RookMobileProtocol.currentVersion),
      let service = values["service"], let serviceID = UUID(uuidString: service),
      let oneTimeCode = values["code"], oneTimeCode.count == 6,
      oneTimeCode.allSatisfy(\.isNumber),
      let secret = values["secret"], secret.count >= 32,
      let expiryValue = values["expires"], let expirySeconds = TimeInterval(expiryValue)
    else { throw RookMobilePairingPayloadError.invalidCode }

    let expiresAt = Date(timeIntervalSince1970: expirySeconds)
    guard expiresAt >= now else { throw RookMobilePairingPayloadError.expired }
    let relayURL: URL?
    if let relayValue = values["relay"] {
      guard let parsed = URL(string: relayValue), RookMobileRelay.isValidEndpoint(parsed) else {
        throw RookMobilePairingPayloadError.invalidCode
      }
      relayURL = parsed
    } else {
      relayURL = nil
    }
    let relayAccessToken = values["relay_key"]
    guard
      (relayURL == nil && relayAccessToken == nil)
        || (relayURL != nil && relayAccessToken.map(RookMobileRelay.isValidAccessToken) == true)
    else { throw RookMobilePairingPayloadError.invalidCode }
    self.init(
      serviceID: serviceID,
      oneTimeCode: oneTimeCode,
      secret: secret,
      expiresAt: expiresAt,
      relayURL: relayURL,
      relayAccessToken: relayAccessToken
    )
  }
}

public enum RookMobilePairingPayloadError: LocalizedError, Equatable {
  case invalidCode
  case expired

  public var errorDescription: String? {
    switch self {
    case .invalidCode: return "That is not a valid Rook pairing QR code."
    case .expired: return "That Rook pairing QR code expired. Open a new one on your Mac."
    }
  }
}

public enum RookMobileSecureChannelError: LocalizedError {
  case invalidFrame
  case keyMismatch

  public var errorDescription: String? {
    switch self {
    case .invalidFrame: return "Rook received an invalid encrypted message."
    case .keyMismatch: return "This message belongs to a different Rook pairing."
    }
  }
}

public enum RookMobileSecureChannel {
  private struct Frame: Codable {
    let keyID: String
    let sealed: Data

    enum CodingKeys: String, CodingKey {
      case keyID = "key_id"
      case sealed
    }
  }

  public static func pairingKeyID(serviceID: UUID) -> String {
    "pair:\(serviceID.uuidString.lowercased())"
  }

  public static func deviceKeyID(deviceID: UUID) -> String {
    "device:\(deviceID.uuidString.lowercased())"
  }

  public static func keyID(in data: Data) throws -> String {
    try JSONDecoder().decode(Frame.self, from: data).keyID
  }

  public static func seal(
    _ envelope: RookMobileEnvelope,
    keyID: String,
    secret: String
  ) throws -> Data {
    let plaintext = try RookMobileCodec.encode(envelope)
    let box = try ChaChaPoly.seal(
      plaintext,
      using: key(for: secret),
      authenticating: Data(keyID.utf8)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Frame(keyID: keyID, sealed: box.combined))
    guard data.count <= RookMobileProtocol.maximumMessageBytes else {
      throw RookMobilePolicyError.messageTooLarge
    }
    return data
  }

  public static func open(
    _ data: Data,
    expectedKeyID: String? = nil,
    secret: String
  ) throws -> RookMobileEnvelope {
    guard data.count <= RookMobileProtocol.maximumMessageBytes else {
      throw RookMobilePolicyError.messageTooLarge
    }
    let frame = try JSONDecoder().decode(Frame.self, from: data)
    if let expectedKeyID, frame.keyID != expectedKeyID {
      throw RookMobileSecureChannelError.keyMismatch
    }
    let box = try ChaChaPoly.SealedBox(combined: frame.sealed)
    let plaintext = try ChaChaPoly.open(
      box,
      using: key(for: secret),
      authenticating: Data(frame.keyID.utf8)
    )
    return try RookMobileCodec.decode(plaintext)
  }

  private static func key(for secret: String) -> SymmetricKey {
    SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
  }
}

public enum RookMobileRelayRole: String, Codable, Sendable {
  case host
  case phone
}

public struct RookMobileRelayControlMessage: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case ready
    case peer
    case error
  }

  public let type: Kind
  public let connected: Bool?

  public init(type: Kind, connected: Bool? = nil) {
    self.type = type
    self.connected = connected
  }
}

public enum RookMobileRelayError: LocalizedError, Equatable {
  case invalidEndpoint
  case unavailable
  case peerUnavailable
  case invalidControlMessage

  public var errorDescription: String? {
    switch self {
    case .invalidEndpoint:
      return "Rook's private relay address is invalid. Pair with the Mac again."
    case .unavailable:
      return "Rook's private relay is temporarily unavailable."
    case .peerUnavailable:
      return "Your Mac is offline or Rook is not running."
    case .invalidControlMessage:
      return "Rook received an invalid relay response."
    }
  }
}

public enum RookMobileRelay {
  public static let currentVersion = 1
  public static let channelHeader = "X-Rook-Relay-Channel"
  public static let roleHeader = "X-Rook-Relay-Role"
  public static let versionHeader = "X-Rook-Relay-Version"
  public static let accessHeader = "X-Rook-Relay-Access"

  public static func isValidEndpoint(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "wss",
      let host = url.host,
      !host.isEmpty,
      url.user == nil,
      url.password == nil,
      url.fragment == nil
    else { return false }
    return true
  }

  public static func endpoint(from value: String) -> URL? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed), isValidEndpoint(url) else {
      return nil
    }
    return url
  }

  public static func channelID(sessionToken: String) -> String {
    let material = Data("rook-mobile-relay-v1:\(sessionToken)".utf8)
    return Data(SHA256.hash(data: material))
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public static func isValidAccessToken(_ token: String) -> Bool {
    (32...512).contains(token.count)
      && token.unicodeScalars.allSatisfy { !$0.properties.isWhitespace }
  }

  public static func request(
    endpoint: URL,
    role: RookMobileRelayRole,
    sessionToken: String,
    accessToken: String
  ) throws -> URLRequest {
    guard isValidEndpoint(endpoint), isValidAccessToken(accessToken) else {
      throw RookMobileRelayError.invalidEndpoint
    }
    var request = URLRequest(url: endpoint)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue(channelID(sessionToken: sessionToken), forHTTPHeaderField: channelHeader)
    request.setValue(role.rawValue, forHTTPHeaderField: roleHeader)
    request.setValue(String(currentVersion), forHTTPHeaderField: versionHeader)
    request.setValue(accessToken, forHTTPHeaderField: accessHeader)
    return request
  }

  public static func decodeControl(_ text: String) throws -> RookMobileRelayControlMessage {
    guard let data = text.data(using: .utf8), data.count <= 1_024 else {
      throw RookMobileRelayError.invalidControlMessage
    }
    do {
      return try JSONDecoder().decode(RookMobileRelayControlMessage.self, from: data)
    } catch {
      throw RookMobileRelayError.invalidControlMessage
    }
  }
}
