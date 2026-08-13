import Foundation
import XCTest

@testable import RookKit

final class RookOAuthTests: XCTestCase {
  func testPKCEChallengeMatchesRFC7636Vector() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    XCTAssertEqual(RookPKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  func testProviderClientIDsAreValidatedBeforeAuthorization() {
    var configuration = RookOAuthClientConfiguration()
    XCTAssertNotNil(configuration.validationError(for: .google))
    XCTAssertNotNil(configuration.validationError(for: .spotify))

    configuration.setClientID("rook.apps.googleusercontent.com", for: .google)
    configuration.setClientID(String(repeating: "a", count: 32), for: .spotify)
    XCTAssertNil(configuration.validationError(for: .google))
    XCTAssertNil(configuration.validationError(for: .spotify))
  }

  func testConfigurationStorePersistsOnlyPublicClientIDs() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-oauth-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("connections.json")
    let store = RookOAuthConfigurationStore(url: url)

    try store.saveClientID("rook.apps.googleusercontent.com", for: .google)
    try store.saveClientID(String(repeating: "b", count: 32), for: .spotify)

    let loaded = store.load()
    XCTAssertEqual(loaded.googleClientID, "rook.apps.googleusercontent.com")
    XCTAssertEqual(loaded.spotifyClientID, String(repeating: "b", count: 32))
    let persisted = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(persisted.localizedCaseInsensitiveContains("secret"))
  }

  func testGoogleScopeSetAvoidsFullMailboxAndFullCalendarScopes() {
    let scopes = RookOAuthProviderDefinition.definition(for: .google).scopes
    XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/gmail.readonly"))
    XCTAssertTrue(scopes.contains("https://www.googleapis.com/auth/calendar.events"))
    XCTAssertFalse(scopes.contains("https://mail.google.com/"))
    XCTAssertFalse(scopes.contains("https://www.googleapis.com/auth/gmail.send"))
    XCTAssertFalse(scopes.contains("https://www.googleapis.com/auth/calendar"))
  }

  func testExpiredCredentialRequiresRefresh() {
    let now = Date(timeIntervalSince1970: 1_786_492_800)
    let expired = RookOAuthCredential(
      provider: .spotify,
      accessToken: "access",
      refreshToken: "refresh",
      tokenType: "Bearer",
      scope: "user-read-private",
      expiresAt: now.addingTimeInterval(30)
    )
    XCTAssertFalse(expired.hasUsableAccessToken(now: now, leeway: 60))
    XCTAssertTrue(expired.hasUsableAccessToken(now: now, leeway: 0))
  }

  func testSpotifyUsesTheDashboardAcceptedFixedLoopbackURI() {
    XCTAssertEqual(RookOAuthCallback.spotifyPort, 8_888)
    XCTAssertEqual(RookOAuthCallback.spotifyRedirectURI, "http://127.0.0.1:8888/oauth/callback")
  }

  func testLoopbackServerAcceptsOnlyTheOAuthCallbackPath() {
    let callbackReceived = expectation(description: "OAuth callback received")
    let server = RookOAuthLoopbackServer()
    server.start(
      onReady: { result in
        switch result {
        case .success(let redirectURL):
          var components = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false)!
          components.queryItems = [
            URLQueryItem(name: "code", value: "test-code"),
            URLQueryItem(name: "state", value: "test-state"),
          ]
          URLSession.shared.dataTask(with: components.url!).resume()
        case .failure(let error):
          XCTFail("Loopback listener did not start: \(error)")
          callbackReceived.fulfill()
        }
      },
      onCallback: { result in
        switch result {
        case .success(let url):
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
          XCTAssertEqual(items.first(where: { $0.name == "code" })?.value, "test-code")
          XCTAssertEqual(items.first(where: { $0.name == "state" })?.value, "test-state")
        case .failure(let error):
          XCTFail("Loopback callback failed: \(error)")
        }
        callbackReceived.fulfill()
      }
    )

    wait(for: [callbackReceived], timeout: 5)
  }
}
