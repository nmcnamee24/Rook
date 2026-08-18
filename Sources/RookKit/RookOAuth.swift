import CryptoKit
import Foundation
import Security

public enum RookOAuthProvider: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
  case google
  case spotify

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .google: return "Google"
    case .spotify: return "Spotify"
    }
  }
}

public enum RookOAuthCallback {
  public static let spotifyPort: UInt16 = 8_888
  public static let spotifyRedirectURI = "http://127.0.0.1:\(spotifyPort)/oauth/callback"
}

public enum RookOAuthConnectionPhase: String, Codable, Equatable, Sendable {
  case notConfigured = "not_configured"
  case disconnected
  case connecting
  case connected
  case failed
}

public struct RookOAuthConnectionStatus: Codable, Equatable, Sendable {
  public let provider: RookOAuthProvider
  public let phase: RookOAuthConnectionPhase
  public let accountLabel: String?
  public let detail: String?

  public init(
    provider: RookOAuthProvider,
    phase: RookOAuthConnectionPhase,
    accountLabel: String? = nil,
    detail: String? = nil
  ) {
    self.provider = provider
    self.phase = phase
    self.accountLabel = accountLabel
    self.detail = detail
  }
}

public struct RookOAuthClientConfiguration: Codable, Equatable, Sendable {
  public var googleClientID: String
  public var spotifyClientID: String

  enum CodingKeys: String, CodingKey {
    case googleClientID = "google_client_id"
    case spotifyClientID = "spotify_client_id"
  }

  public init(googleClientID: String = "", spotifyClientID: String = "") {
    self.googleClientID = googleClientID
    self.spotifyClientID = spotifyClientID
  }

  public func clientID(for provider: RookOAuthProvider) -> String {
    switch provider {
    case .google: return googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    case .spotify: return spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  public mutating func setClientID(_ value: String, for provider: RookOAuthProvider) {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch provider {
    case .google: googleClientID = cleaned
    case .spotify: spotifyClientID = cleaned
    }
  }

  /// Keeps an explicitly saved developer override while allowing a release
  /// build to supply Rook-owned public client IDs from its app bundle.
  public func resolvingFallback(_ fallback: RookOAuthClientConfiguration) -> RookOAuthClientConfiguration {
    RookOAuthClientConfiguration(
      googleClientID: clientID(for: .google).isEmpty
        ? fallback.clientID(for: .google) : clientID(for: .google),
      spotifyClientID: clientID(for: .spotify).isEmpty
        ? fallback.clientID(for: .spotify) : clientID(for: .spotify)
    )
  }

  public func validationError(for provider: RookOAuthProvider) -> String? {
    let clientID = clientID(for: provider)
    guard !clientID.isEmpty else { return "A client ID is required." }
    switch provider {
    case .google:
      guard clientID.hasSuffix(".apps.googleusercontent.com") else {
        return "Use a Google OAuth client ID for a Desktop app."
      }
    case .spotify:
      let allowed = CharacterSet.alphanumerics
      guard clientID.count >= 20,
        clientID.unicodeScalars.allSatisfy({ allowed.contains($0) })
      else {
        return "Use the Client ID from your Spotify developer app."
      }
    }
    return nil
  }
}

public final class RookOAuthConfigurationStore: @unchecked Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  public func load() -> RookOAuthClientConfiguration {
    guard let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(RookOAuthClientConfiguration.self, from: data)
    else { return RookOAuthClientConfiguration() }
    return decoded
  }

  public func save(_ configuration: RookOAuthClientConfiguration) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try RookConfig.writePrivate(try encoder.encode(configuration), to: url)
  }

  public func saveClientID(_ clientID: String, for provider: RookOAuthProvider) throws {
    var configuration = load()
    configuration.setClientID(clientID, for: provider)
    if let error = configuration.validationError(for: provider) {
      throw RookOAuthError.configuration(error)
    }
    try save(configuration)
  }
}

public struct RookOAuthCredential: Codable, Equatable, Sendable {
  public let provider: RookOAuthProvider
  public var accessToken: String
  public var refreshToken: String?
  public var tokenType: String
  public var scope: String
  public var expiresAt: Date
  public var accountLabel: String?

  public init(
    provider: RookOAuthProvider,
    accessToken: String,
    refreshToken: String?,
    tokenType: String,
    scope: String,
    expiresAt: Date,
    accountLabel: String? = nil
  ) {
    self.provider = provider
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.tokenType = tokenType
    self.scope = scope
    self.expiresAt = expiresAt
    self.accountLabel = accountLabel
  }

  public func hasUsableAccessToken(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
    expiresAt.timeIntervalSince(now) > leeway
  }
}

public struct RookOAuthProviderDefinition: Equatable, Sendable {
  public let provider: RookOAuthProvider
  public let authorizationEndpoint: URL
  public let tokenEndpoint: URL
  public let profileEndpoint: URL
  public let scopes: [String]

  public static func definition(for provider: RookOAuthProvider) -> RookOAuthProviderDefinition {
    switch provider {
    case .google:
      return RookOAuthProviderDefinition(
        provider: .google,
        authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
        profileEndpoint: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!,
        scopes: [
          "openid",
          "email",
          "https://www.googleapis.com/auth/gmail.readonly",
          "https://www.googleapis.com/auth/calendar.events",
        ]
      )
    case .spotify:
      return RookOAuthProviderDefinition(
        provider: .spotify,
        authorizationEndpoint: URL(string: "https://accounts.spotify.com/authorize")!,
        tokenEndpoint: URL(string: "https://accounts.spotify.com/api/token")!,
        profileEndpoint: URL(string: "https://api.spotify.com/v1/me")!,
        scopes: [
          "user-read-private",
          "playlist-read-private",
          "user-read-recently-played",
          "user-read-playback-state",
          "user-modify-playback-state",
          "user-top-read",
        ]
      )
    }
  }
}

public enum RookPKCE {
  public static func randomURLSafeString(byteCount: Int = 32) throws -> String {
    var bytes = [UInt8](repeating: 0, count: byteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw RookOAuthError.security("Secure random generation failed with status \(status).")
    }
    return Data(bytes).base64URLEncodedString()
  }

  public static func challenge(for verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64URLEncodedString()
  }
}

public enum RookOAuthError: LocalizedError, Equatable {
  case configuration(String)
  case security(String)
  case authorization(String)
  case callback(String)
  case tokenExchange(String)
  case network(String)

  public var errorDescription: String? {
    switch self {
    case .configuration(let detail): return detail
    case .security(let detail): return detail
    case .authorization(let detail): return detail
    case .callback(let detail): return detail
    case .tokenExchange(let detail): return detail
    case .network(let detail): return detail
    }
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
