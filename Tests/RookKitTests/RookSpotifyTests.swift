import Foundation
import XCTest

@testable import RookKit

final class RookSpotifyTests: XCTestCase {
  func testParserRecognizesDirectAccountCommands() {
    XCTAssertEqual(
      RookSpotifyCommandParser.parse("Play my Focus playlist on Spotify"),
      .play(query: "Focus", preferredKind: .playlist, libraryOnly: true)
    )
    XCTAssertEqual(
      RookSpotifyCommandParser.parse("Play the album Abbey Road on Spotify"),
      .play(query: "Abbey Road", preferredKind: .album, libraryOnly: false)
    )
    XCTAssertEqual(RookSpotifyCommandParser.parse("Show my Spotify playlists"), .playlists)
    XCTAssertEqual(RookSpotifyCommandParser.parse("Show me my Spotify playlist"), .playlists)
    XCTAssertEqual(RookSpotifyCommandParser.parse("What are my playlists on Spotify?"), .playlists)
    XCTAssertEqual(
      RookSpotifyCommandParser.parse("Play my top tracks playlist."),
      .playTopTracks
    )
    XCTAssertEqual(RookSpotifyCommandParser.parse("Play my Spotify playlist."), .choosePlaylist)
    XCTAssertEqual(RookSpotifyCommandParser.parse("Play me any Spotify playlist on my computer."), .playAnyPlaylist)
    XCTAssertEqual(
      RookSpotifyCommandParser.parse("Open my Spotify playlist or show me my Spotify playlist"),
      .playlists
    )
    XCTAssertEqual(RookSpotifyCommandParser.parse("Pause Spotify"), .pause)
    XCTAssertEqual(RookSpotifyCommandParser.parse("Next track on Spotify"), .next)
    XCTAssertEqual(RookSpotifyCommandParser.parse("What did I recently listen to on Spotify"), .recentlyPlayed)
    XCTAssertEqual(RookSpotifyCommandParser.parse("Show my top artists on Spotify"), .top(.artists))
    XCTAssertEqual(RookSpotifyCommandParser.parse("What are my most played songs"), .top(.tracks))
    XCTAssertEqual(RookSpotifyCommandParser.parse("What is playing on Spotify"), .nowPlaying)
    XCTAssertEqual(
      RookSpotifyCommandParser.parse("Move Spotify to Kitchen Speaker"),
      .transferPlayback(deviceName: "Kitchen Speaker")
    )
  }

  func testParserLeavesBasicAndCompoundCommandsToExistingSafetyRoutes() {
    XCTAssertEqual(RookSpotifyCommandParser.parse("Play my Spotify"), .resume)
    XCTAssertNil(RookSpotifyCommandParser.parse("Play Focus on Spotify and then send a message"))
    XCTAssertNil(RookSpotifyCommandParser.parse("Delete my Spotify playlist"))
    XCTAssertEqual(
      RookSpotifySemanticResolver.resolve("Delete my Spotify playlist"),
      .clarification(
        "Rook’s Spotify connection can read your account and control playback, but it cannot modify playlists or your saved library."
      )
    )
  }

  func testSemanticResolverMapsNaturalFailuresToReviewedSpotifyIntents() {
    XCTAssertNil(RookSpotifyCommandParser.parse("Could you pull up everything in my Spotify playlist collection"))
    XCTAssertEqual(
      RookSpotifySemanticResolver.resolve("Could you pull up everything in my Spotify playlist collection"),
      .intent(.playlists)
    )
    XCTAssertEqual(
      RookSpotifySemanticResolver.resolve("Put on something from my most played Spotify songs"),
      .intent(.playTopTracks)
    )
    XCTAssertEqual(
      RookSpotifySemanticResolver.resolve("Which tracks have I listened to lately through Spotify"),
      .intent(.recentlyPlayed)
    )
    XCTAssertEqual(
      RookSpotifySemanticResolver.resolve("Could you switch my Spotify device to the Kitchen Speaker"),
      .intent(.transferPlayback(deviceName: "the Kitchen Speaker"))
    )
    XCTAssertEqual(RookSpotifySemanticResolver.resolve("How does Spotify Wrapped work?"), .notSpotify)
    XCTAssertEqual(RookSpotifySemanticResolver.resolve("Play this on Apple Music"), .notSpotify)
    XCTAssertEqual(
      RookSpotifySemanticResolver.resolve(
        "Which of these playlists seems like a study or work or focus playlist?"
      ),
      .intent(.recommendPlaylists(purposes: [.study, .work, .focus]))
    )
  }

  func testComputerParserDoesNotClaimSpotifyAccountLanguageAsAnApplicationName() {
    XCTAssertNil(RookComputerCommandParser.parse("Open my Spotify playlist or show me my Spotify playlist"))
    XCTAssertNil(RookComputerCommandParser.parse("Open my Spotify playlists"))
    XCTAssertEqual(RookComputerCommandParser.parse("Open Spotify"), .openApplication(name: "Spotify"))
  }

  func testMatcherPrefersAnExactHumanPlaylistName() throws {
    let candidates = [
      RookSpotifyCandidate(id: "1", name: "Deep Focus", uri: "spotify:playlist:1", kind: .playlist),
      RookSpotifyCandidate(id: "2", name: "Focus", uri: "spotify:playlist:2", kind: .playlist),
      RookSpotifyCandidate(id: "3", name: "Focus Mix", uri: "spotify:playlist:3", kind: .playlist),
    ]
    let ranked = RookSpotifyMatcher.ranked(query: "my Focus playlist", candidates: candidates)
    XCTAssertEqual(try XCTUnwrap(ranked.first).candidate.id, "2")
    XCTAssertEqual(try XCTUnwrap(ranked.first).score, 100)
  }

  func testPurposeMatcherRanksPersonalPlaylistMeaningInsteadOfLiteralQuery() throws {
    let candidates = [
      RookSpotifyCandidate(
        id: "1",
        name: "Homework Instrumentals",
        uri: "spotify:playlist:1",
        kind: .playlist,
        semanticText: "Quiet background music for studying"
      ),
      RookSpotifyCandidate(id: "2", name: "Running", uri: "spotify:playlist:2", kind: .playlist),
      RookSpotifyCandidate(
        id: "3",
        name: "The Zone",
        uri: "spotify:playlist:3",
        kind: .playlist,
        semanticText: "Deep focus for coding and productive work"
      ),
    ]

    let ranked = RookSpotifyPurposeMatcher.ranked(
      purposes: [.study, .work, .focus],
      candidates: candidates
    )
    XCTAssertEqual(ranked.map(\.candidate.id), ["1", "3"])
    XCTAssertTrue(try XCTUnwrap(ranked.first).matchedPurposes.contains(.study))

    let focusFallback = RookSpotifyPurposeMatcher.ranked(
      purposes: [.focus],
      candidates: [
        RookSpotifyCandidate(
          id: "study",
          name: "Study Session",
          uri: "spotify:playlist:study",
          kind: .playlist
        ),
        RookSpotifyCandidate(id: "party", name: "Party", uri: "spotify:playlist:party", kind: .playlist),
      ]
    )
    XCTAssertEqual(focusFallback.first?.candidate.id, "study")
  }

  @MainActor
  func testTiedFocusInferencesReturnAUsablePlaylistQuestion() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpotifyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    SpotifyURLProtocol.reset()
    SpotifyURLProtocol.handler = { request in
      guard request.httpMethod == "GET", request.url?.path == "/v1/me/playlists" else {
        return (404, Data())
      }
      let json =
        #"{"total":2,"items":[{"id":"study","name":"Study Session","uri":"spotify:playlist:study","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/study"}},{"id":"homework","name":"Homework Session","uri":"spotify:playlist:homework","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/homework"}}]}"#
      return (200, Data(json.utf8))
    }

    let client = RookSpotifyClient(session: session) { "test-access-token" }
    let response = try await client.execute(
      .play(query: "Focus", preferredKind: .playlist, libraryOnly: true)
    )

    XCTAssertEqual(response.intent, "clarification")
    XCTAssertTrue(response.displayText.contains("Which playlist should I play?"))
    XCTAssertEqual(response.canvas.first?.items.map(\.label), ["Study Session", "Homework Session"])
    XCTAssertTrue(response.pawns.isEmpty)
  }

  @MainActor
  func testPlaylistRecommendationReturnsOnlyLikelyMatchesAndKeepsNamesInCanvas() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpotifyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    SpotifyURLProtocol.reset()
    SpotifyURLProtocol.handler = { request in
      guard request.httpMethod == "GET", request.url?.path == "/v1/me/playlists" else {
        return (404, Data())
      }
      let json =
        #"{"total":4,"items":[{"id":"focus","name":"Deep Focus","description":"Concentration and flow","uri":"spotify:playlist:focus","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/focus"},"items":{"total":42}},{"id":"study","name":"Homework Piano","description":"Instrumental study music","uri":"spotify:playlist:study","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/study"},"items":{"total":30}},{"id":"run","name":"Running","description":"Fast workout songs","uri":"spotify:playlist:run","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/run"},"items":{"total":20}},{"id":"party","name":"Party","description":"Dance floor","uri":"spotify:playlist:party","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/party"},"items":{"total":50}}]}"#
      return (200, Data(json.utf8))
    }

    let client = RookSpotifyClient(session: session) { "test-access-token" }
    let response = try await client.execute(
      .recommendPlaylists(purposes: [.study, .work, .focus])
    )

    XCTAssertTrue(response.displayText.contains("Deep Focus"))
    XCTAssertTrue(response.displayText.contains("ranked playlist titles and descriptions"))
    XCTAssertEqual(response.canvas.first?.items.map(\.label), ["Deep Focus", "Homework Piano"])
    XCTAssertFalse(response.displayText.contains("4 Spotify playlists"))
    XCTAssertTrue(response.pawns.isEmpty)
  }

  @MainActor
  func testMissingLiteralFocusPlaylistFallsBackToSemanticLibraryMatch() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpotifyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    SpotifyURLProtocol.reset()
    SpotifyURLProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/me/playlists"):
        let json =
          #"{"total":2,"items":[{"id":"zone","name":"The Zone","description":"Deep focus and concentration for coding","uri":"spotify:playlist:zone","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/zone"},"items":{"total":42}},{"id":"party","name":"Party","description":"Dance floor","uri":"spotify:playlist:party","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/party"},"items":{"total":50}}]}"#
        return (200, Data(json.utf8))
      case ("GET", "/v1/me/player/devices"):
        let json =
          #"{"devices":[{"id":"mac","is_active":true,"is_restricted":false,"name":"Noah's MacBook","type":"computer"}]}"#
        return (200, Data(json.utf8))
      case ("PUT", "/v1/me/player/play"):
        return (204, Data())
      default:
        return (404, Data())
      }
    }

    let client = RookSpotifyClient(session: session) { "test-access-token" }
    let response = try await client.execute(
      .play(query: "Focus", preferredKind: .playlist, libraryOnly: true)
    )

    XCTAssertTrue(response.displayText.contains("The Zone"))
    XCTAssertEqual(
      SpotifyURLProtocol.recordedRequests.map(\.url?.path),
      ["/v1/me/playlists", "/v1/me/player/devices", "/v1/me/player/play"]
    )
  }

  @MainActor
  func testPlayForPurposeUsesThePersonalLibraryWithoutAPawn() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpotifyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    SpotifyURLProtocol.reset()
    SpotifyURLProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/me/playlists"):
        let json =
          #"{"total":2,"items":[{"id":"study","name":"lock-in study music","description":"Music for studying and deep concentration","uri":"spotify:playlist:study","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/study"}},{"id":"party","name":"Party","description":"Dance floor","uri":"spotify:playlist:party","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/party"}}]}"#
        return (200, Data(json.utf8))
      case ("GET", "/v1/me/player/devices"):
        let json =
          #"{"devices":[{"id":"mac","is_active":true,"is_restricted":false,"name":"Noah's MacBook","type":"computer"}]}"#
        return (200, Data(json.utf8))
      case ("PUT", "/v1/me/player/play"):
        return (204, Data())
      default:
        return (404, Data())
      }
    }

    let client = RookSpotifyClient(session: session) { "test-access-token" }
    let response = try await client.execute(.playForPurpose(purposes: [.study]))

    XCTAssertTrue(response.displayText.contains("lock-in study music"))
    XCTAssertTrue(response.pawns.isEmpty)
    XCTAssertEqual(
      SpotifyURLProtocol.recordedRequests.map(\.url?.path),
      ["/v1/me/playlists", "/v1/me/player/devices", "/v1/me/player/play"]
    )
  }

  @MainActor
  func testNamedPlaylistPlaybackUsesUserLibraryDeviceAndBearerToken() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpotifyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    SpotifyURLProtocol.reset()
    SpotifyURLProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/me/playlists"):
        let json =
          #"{"total":1,"items":[{"id":"focus","name":"Focus","uri":"spotify:playlist:focus","type":"playlist","owner":{"display_name":"Noah"},"images":[],"external_urls":{"spotify":"https://open.spotify.com/playlist/focus"},"items":{"total":42}}]}"#
        return (200, Data(json.utf8))
      case ("GET", "/v1/me/player/devices"):
        let json =
          #"{"devices":[{"id":"mac","is_active":true,"is_restricted":false,"name":"Noah's MacBook","type":"computer"}]}"#
        return (200, Data(json.utf8))
      case ("PUT", "/v1/me/player/play"):
        return (204, Data())
      default:
        return (404, Data())
      }
    }

    let client = RookSpotifyClient(session: session) { "test-access-token" }
    let response = try await client.execute(
      .play(query: "Focus", preferredKind: .playlist, libraryOnly: true)
    )

    XCTAssertTrue(response.displayText.contains("Focus"))
    XCTAssertEqual(response.canvas.first?.kind, .spotify)
    let requests = SpotifyURLProtocol.recordedRequests
    XCTAssertEqual(requests.count, 3)
    XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token" })
    let playback = try XCTUnwrap(requests.first { $0.url?.path == "/v1/me/player/play" })
    XCTAssertEqual(
      URLComponents(url: try XCTUnwrap(playback.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "mac")
  }

  @MainActor
  func testConnectedPauseUsesSpotifyWebAPIInsteadOfComputerControl() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpotifyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    SpotifyURLProtocol.reset()
    SpotifyURLProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/me/player/devices"):
        let json =
          #"{"devices":[{"id":"mac","is_active":true,"is_restricted":false,"name":"Noah's MacBook","type":"computer"}]}"#
        return (200, Data(json.utf8))
      case ("PUT", "/v1/me/player/pause"):
        return (204, Data())
      default:
        return (404, Data())
      }
    }

    let client = RookSpotifyClient(session: session) { "test-access-token" }
    let response = try await client.execute(.pause)

    XCTAssertTrue(response.displayText.contains("Paused"))
    XCTAssertEqual(response.canvas.first?.kind, .spotify)
    XCTAssertEqual(
      SpotifyURLProtocol.recordedRequests.map(\.url?.path),
      [
        "/v1/me/player/devices", "/v1/me/player/pause",
      ])
  }

  @MainActor
  func testPlayTopTracksCallsTopItemsThenPlaybackEndpoints() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpotifyURLProtocol.self]
    let session = URLSession(configuration: configuration)
    SpotifyURLProtocol.reset()
    SpotifyURLProtocol.handler = { request in
      switch (request.httpMethod, request.url?.path) {
      case ("GET", "/v1/me/top/tracks"):
        let json =
          #"{"items":[{"id":"track-1","name":"First Song","uri":"spotify:track:1","type":"track","artists":[{"name":"First Artist"}],"images":[],"external_urls":{"spotify":"https://open.spotify.com/track/1"}},{"id":"track-2","name":"Second Song","uri":"spotify:track:2","type":"track","artists":[{"name":"Second Artist"}],"images":[],"external_urls":{"spotify":"https://open.spotify.com/track/2"}}]}"#
        return (200, Data(json.utf8))
      case ("GET", "/v1/me/player/devices"):
        let json =
          #"{"devices":[{"id":"mac","is_active":true,"is_restricted":false,"name":"Noah's MacBook","type":"computer"}]}"#
        return (200, Data(json.utf8))
      case ("PUT", "/v1/me/player/play"):
        return (204, Data())
      default:
        return (404, Data())
      }
    }

    let client = RookSpotifyClient(session: session) { "test-access-token" }
    let response = try await client.execute(.playTopTracks)

    XCTAssertTrue(response.displayText.contains("top Spotify tracks"))
    XCTAssertEqual(response.canvas.first?.kind, .spotify)
    XCTAssertEqual(
      SpotifyURLProtocol.recordedRequests.map(\.url?.path),
      ["/v1/me/top/tracks", "/v1/me/player/devices", "/v1/me/player/play"]
    )
  }
}

private final class SpotifyURLProtocol: URLProtocol, @unchecked Sendable {
  static var handler: ((URLRequest) -> (Int, Data))?
  private static var requests: [URLRequest] = []
  private static let lock = NSLock()

  static var recordedRequests: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  static func reset() {
    lock.lock()
    requests = []
    lock.unlock()
    handler = nil
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.lock.lock()
    Self.requests.append(request)
    Self.lock.unlock()
    let result = Self.handler?(request) ?? (500, Data())
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: result.0,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !result.1.isEmpty { client?.urlProtocol(self, didLoad: result.1) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
