import AppKit
import Foundation
import RookKit

@MainActor
final class RookOAuthCoordinator {
  typealias StatusHandler = (RookOAuthConnectionStatus) -> Void

  var onStatus: StatusHandler?

  private let configurationStore: RookOAuthConfigurationStore
  private let keychain = RookOAuthKeychain()
  private var servers: [RookOAuthProvider: RookOAuthLoopbackServer] = [:]
  private var redirectURLs: [RookOAuthProvider: URL] = [:]

  init(config: RookConfig) {
    configurationStore = RookOAuthConfigurationStore(url: config.connectionsConfigURL)
  }

  func configuration() -> RookOAuthClientConfiguration {
    configurationStore.load()
  }

  func initialStatuses() -> [RookOAuthProvider: RookOAuthConnectionStatus] {
    let configuration = configurationStore.load()
    return Dictionary(
      uniqueKeysWithValues: RookOAuthProvider.allCases.map { provider in
        let status: RookOAuthConnectionStatus
        if configuration.validationError(for: provider) != nil {
          status = RookOAuthConnectionStatus(
            provider: provider,
            phase: .notConfigured,
            detail: "Add a developer client ID to begin."
          )
        } else if let credential = keychain.load(provider),
          credential.hasUsableAccessToken()
            || !(credential.refreshToken?.isEmpty ?? true)
        {
          status = RookOAuthConnectionStatus(
            provider: provider,
            phase: .connected,
            accountLabel: credential.accountLabel,
            detail: "Direct OAuth stored securely in Keychain."
          )
        } else {
          status = RookOAuthConnectionStatus(
            provider: provider,
            phase: .disconnected,
            detail: "Connect in your browser to authorize Rook."
          )
        }
        return (provider, status)
      })
  }

  func saveClientID(_ clientID: String, for provider: RookOAuthProvider) throws {
    let oldID = configurationStore.load().clientID(for: provider)
    try configurationStore.saveClientID(clientID, for: provider)
    if !oldID.isEmpty, oldID != clientID.trimmingCharacters(in: .whitespacesAndNewlines) {
      try keychain.delete(provider)
    }
    emit(RookOAuthConnectionStatus(provider: provider, phase: .disconnected))
  }

  func connect(_ provider: RookOAuthProvider) {
    guard servers[provider] == nil else { return }
    let configuration = configurationStore.load()
    if let validationError = configuration.validationError(for: provider) {
      emit(
        RookOAuthConnectionStatus(
          provider: provider,
          phase: .notConfigured,
          detail: validationError
        ))
      return
    }

    let clientID = configuration.clientID(for: provider)
    let definition = RookOAuthProviderDefinition.definition(for: provider)
    let server = RookOAuthLoopbackServer(
      port: provider == .spotify ? RookOAuthCallback.spotifyPort : nil
    )
    servers[provider] = server
    emit(
      RookOAuthConnectionStatus(
        provider: provider,
        phase: .connecting,
        detail: "Waiting for browser authorization."
      ))

    do {
      let verifier = try RookPKCE.randomURLSafeString(byteCount: 64)
      let state = try RookPKCE.randomURLSafeString(byteCount: 32)
      server.start(
        onReady: { [weak self] result in
          guard let self else { return }
          switch result {
          case .success(let redirectURL):
            self.redirectURLs[provider] = redirectURL
            guard
              let authorizationURL = self.authorizationURL(
                definition: definition,
                clientID: clientID,
                redirectURL: redirectURL,
                verifier: verifier,
                state: state
              )
            else {
              self.fail(provider, "Rook could not construct the authorization URL.")
              return
            }
            guard NSWorkspace.shared.open(authorizationURL) else {
              self.fail(provider, "Rook could not open the authorization page in your browser.")
              return
            }
          case .failure(let error):
            self.fail(provider, error.localizedDescription)
          }
        },
        onCallback: { [weak self] result in
          guard let self else { return }
          self.servers[provider] = nil
          switch result {
          case .success(let callbackURL):
            guard let redirectURL = self.redirectURLs.removeValue(forKey: provider) else {
              self.fail(provider, "Rook lost the local callback address before sign-in completed.")
              return
            }
            Task {
              await self.finishAuthorization(
                provider: provider,
                definition: definition,
                clientID: clientID,
                redirectURL: redirectURL,
                callbackURL: callbackURL,
                verifier: verifier,
                expectedState: state
              )
            }
          case .failure(let error):
            self.fail(provider, error.localizedDescription)
          }
        }
      )
    } catch {
      servers[provider] = nil
      fail(provider, error.localizedDescription)
    }
  }

  func disconnect(_ provider: RookOAuthProvider) {
    servers[provider]?.cancel()
    servers[provider] = nil
    redirectURLs[provider] = nil
    do {
      try keychain.delete(provider)
      emit(
        RookOAuthConnectionStatus(
          provider: provider,
          phase: .disconnected,
          detail: "The token was removed from this Mac."
        ))
    } catch {
      fail(provider, error.localizedDescription)
    }
  }

  func validAccessToken(for provider: RookOAuthProvider) async throws -> String {
    guard var credential = keychain.load(provider) else {
      throw RookOAuthError.authorization("\(provider.displayName) is not connected directly to Rook.")
    }
    if credential.hasUsableAccessToken() { return credential.accessToken }
    guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
      throw RookOAuthError.authorization("\(provider.displayName) needs to be connected again.")
    }

    let configuration = configurationStore.load()
    let clientID = configuration.clientID(for: provider)
    guard configuration.validationError(for: provider) == nil else {
      throw RookOAuthError.configuration("The \(provider.displayName) client ID is missing or invalid.")
    }
    let definition = RookOAuthProviderDefinition.definition(for: provider)
    let response = try await tokenRequest(
      endpoint: definition.tokenEndpoint,
      values: [
        "client_id": clientID,
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
      ]
    )
    credential.accessToken = response.accessToken
    credential.refreshToken = response.refreshToken ?? credential.refreshToken
    credential.tokenType = response.tokenType ?? credential.tokenType
    credential.scope = response.scope ?? credential.scope
    credential.expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3_600))
    try keychain.save(credential)
    return credential.accessToken
  }

  private func finishAuthorization(
    provider: RookOAuthProvider,
    definition: RookOAuthProviderDefinition,
    clientID: String,
    redirectURL: URL,
    callbackURL: URL,
    verifier: String,
    expectedState: String
  ) async {
    do {
      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
      let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
      guard values["state"] == expectedState else {
        throw RookOAuthError.callback("The sign-in callback did not match Rook’s authorization request.")
      }
      if let error = values["error"], !error.isEmpty {
        throw RookOAuthError.authorization(
          error == "access_denied" ? "Sign-in was cancelled." : "Authorization failed: \(error)"
        )
      }
      guard let code = values["code"], !code.isEmpty else {
        throw RookOAuthError.callback("The provider did not return an authorization code.")
      }

      let response = try await tokenRequest(
        endpoint: definition.tokenEndpoint,
        values: [
          "client_id": clientID,
          "code": code,
          "code_verifier": verifier,
          "grant_type": "authorization_code",
          "redirect_uri": redirectURL.absoluteString,
        ]
      )

      let oldCredential = keychain.load(provider)
      var credential = RookOAuthCredential(
        provider: provider,
        accessToken: response.accessToken,
        refreshToken: response.refreshToken ?? oldCredential?.refreshToken,
        tokenType: response.tokenType ?? "Bearer",
        scope: response.scope ?? definition.scopes.joined(separator: " "),
        expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3_600)),
        accountLabel: nil
      )
      credential.accountLabel = try? await accountLabel(definition: definition, accessToken: response.accessToken)
      try keychain.save(credential)
      emit(
        RookOAuthConnectionStatus(
          provider: provider,
          phase: .connected,
          accountLabel: credential.accountLabel,
          detail: "Direct OAuth stored securely in Keychain."
        ))
    } catch {
      fail(provider, error.localizedDescription)
    }
  }

  private func authorizationURL(
    definition: RookOAuthProviderDefinition,
    clientID: String,
    redirectURL: URL,
    verifier: String,
    state: String
  ) -> URL? {
    var components = URLComponents(url: definition.authorizationEndpoint, resolvingAgainstBaseURL: false)
    var items = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
      URLQueryItem(name: "scope", value: definition.scopes.joined(separator: " ")),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: RookPKCE.challenge(for: verifier)),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]
    if definition.provider == .google {
      items.append(URLQueryItem(name: "access_type", value: "offline"))
      items.append(URLQueryItem(name: "prompt", value: "consent"))
    }
    components?.queryItems = items
    return components?.url
  }

  private func tokenRequest(endpoint: URL, values: [String: String]) async throws -> TokenResponse {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    var form = URLComponents()
    form.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw RookOAuthError.network("The token request failed: \(error.localizedDescription)")
    }
    guard let http = response as? HTTPURLResponse else {
      throw RookOAuthError.network("The provider returned an invalid token response.")
    }
    guard (200..<300).contains(http.statusCode) else {
      let providerError = (try? JSONDecoder().decode(TokenErrorResponse.self, from: data))
      throw RookOAuthError.tokenExchange(
        providerError?.errorDescription ?? providerError?.error ?? "Token exchange failed with HTTP \(http.statusCode)."
      )
    }
    do {
      return try JSONDecoder().decode(TokenResponse.self, from: data)
    } catch {
      throw RookOAuthError.tokenExchange("The provider returned an unreadable token response.")
    }
  }

  private func accountLabel(definition: RookOAuthProviderDefinition, accessToken: String) async throws -> String {
    var request = URLRequest(url: definition.profileEndpoint)
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw RookOAuthError.network("The provider profile could not be verified.")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RookOAuthError.network("The provider profile was unreadable.")
    }
    if definition.provider == .google, let email = object["email"] as? String, !email.isEmpty { return email }
    if let displayName = object["display_name"] as? String, !displayName.isEmpty { return displayName }
    if let id = object["id"] as? String, !id.isEmpty { return id }
    return definition.provider.displayName
  }

  private func fail(_ provider: RookOAuthProvider, _ detail: String) {
    servers[provider]?.cancel()
    servers[provider] = nil
    redirectURLs[provider] = nil
    emit(RookOAuthConnectionStatus(provider: provider, phase: .failed, detail: detail))
  }

  private func emit(_ status: RookOAuthConnectionStatus) {
    onStatus?(status)
  }
}

private struct TokenResponse: Decodable {
  let accessToken: String
  let tokenType: String?
  let expiresIn: Int?
  let refreshToken: String?
  let scope: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case tokenType = "token_type"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case scope
  }
}

private struct TokenErrorResponse: Decodable {
  let error: String?
  let errorDescription: String?

  enum CodingKeys: String, CodingKey {
    case error
    case errorDescription = "error_description"
  }
}
