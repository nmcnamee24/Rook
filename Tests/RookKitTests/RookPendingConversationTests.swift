import Foundation
import XCTest

@testable import RookKit

final class RookPendingConversationTests: XCTestCase {
  func testSpotifyQuestionPersistsAndTopTracksAnswerStaysOnTheDirectRoute() throws {
    let now = Date(timeIntervalSince1970: 1_786_500_000)
    let response = RookResponse(
      displayText: "Which playlist should I play? I found 3.",
      spokenText: "Which playlist should I play? Say the exact name.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [playlistCanvas(["Deep Focus", "Running", "Discover Weekly"])]
    )
    let pending = try XCTUnwrap(
      RookPendingConversationDetector.detect(
        response: response,
        sourceCommand: "Play my Spotify playlist",
        route: "spotify_native",
        now: now
      )
    )
    XCTAssertEqual(pending.domain, .spotifyPlaylist)
    XCTAssertEqual(pending.options, ["Deep Focus", "Running", "Discover Weekly"])

    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("pending.json")
    var store = RookPendingConversationStore(documentURL: url)
    store.set(pending)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    var restored = RookPendingConversationStore(documentURL: url)
    let resolution = restored.resolve("My top tracks playlist", now: now.addingTimeInterval(20))
    guard case .continuation(let continuation) = resolution else {
      return XCTFail("Expected the short answer to continue the open Spotify request")
    }
    XCTAssertEqual(continuation.pending.sourceCommand, "Play my Spotify playlist")
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(
        answer: continuation.answer,
        options: continuation.pending.options
      ),
      .playTopTracks
    )
    XCTAssertNil(restored.pending)
  }

  func testNamedAndOrdinalPlaylistAnswersResolveWithoutPawns() {
    let options = ["Deep Focus", "Running", "Discover Weekly"]
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(answer: "Deep Focus", options: options),
      .play(query: "Deep Focus", preferredKind: .playlist, libraryOnly: true)
    )
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(answer: "the second one", options: options),
      .play(query: "Running", preferredKind: .playlist, libraryOnly: true)
    )
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(answer: "Play option one.", options: options),
      .play(query: "Deep Focus", preferredKind: .playlist, libraryOnly: true)
    )
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(answer: "choice number two", options: options),
      .play(query: "Running", preferredKind: .playlist, libraryOnly: true)
    )
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(answer: "playlist 3", options: options),
      .play(query: "Discover Weekly", preferredKind: .playlist, libraryOnly: true)
    )
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(answer: "play that", options: options),
      .play(query: "Deep Focus", preferredKind: .playlist, libraryOnly: true)
    )
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(
        answer: "Which one seems best for studying?",
        options: options
      ),
      .recommendPlaylists(purposes: [.study])
    )
  }

  func testHybridSpotifyQuestionPreservesTheWholeTaskForTheFollowUp() throws {
    let source =
      "Play my Focus playlist, tell me what is playing, and research the artist."
    let response = RookResponse(
      displayText: "Which playlist should I play? Deep Focus or Focus Mix?",
      spokenText: "Which playlist should I play?",
      intent: "clarification",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [playlistCanvas(["Deep Focus", "Focus Mix"])]
    )

    let pending = try XCTUnwrap(
      RookPendingConversationDetector.detect(
        response: response,
        sourceCommand: source,
        route: "spotify_hybrid"
      )
    )

    XCTAssertEqual(pending.domain, .spotifyHybrid)
    XCTAssertEqual(pending.sourceCommand, source)
    XCTAssertEqual(pending.options, ["Deep Focus", "Focus Mix"])
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(answer: "the second one", options: pending.options),
      .play(query: "Focus Mix", preferredKind: .playlist, libraryOnly: true)
    )
  }

  func testScreenshotOptionOneResolvesAgainstPersistedSemanticChoices() throws {
    let now = Date(timeIntervalSince1970: 1_786_568_283)
    let options = [
      "Jazz Study Vibes",
      "lock-in study music",
      "Lofi Girl - beats to relax/study to",
    ]
    let response = RookResponse(
      displayText: "I found a few study matches. Which playlist should I play?",
      spokenText: "I found a few study matches. Which playlist should I play?",
      intent: "clarification",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [playlistCanvas(options)]
    )
    let pending = try XCTUnwrap(
      RookPendingConversationDetector.detect(
        response: response,
        sourceCommand: "Play the playlist that you think is the most study-esque.",
        route: "spotify_native",
        now: now
      )
    )

    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = RookPendingConversationStore(documentURL: folder.appendingPathComponent("pending.json"))
    store.set(pending)
    guard
      case .continuation(let continuation) = store.resolve(
        "Play option one.",
        now: now.addingTimeInterval(17)
      )
    else {
      return XCTFail("Expected option one to continue the open Spotify choice")
    }

    XCTAssertEqual(continuation.pending.options, options)
    XCTAssertEqual(
      RookSpotifyPlaylistFollowUpResolver.resolve(
        answer: continuation.answer,
        options: continuation.pending.options
      ),
      .play(query: "Jazz Study Vibes", preferredKind: .playlist, libraryOnly: true)
    )
  }

  func testGenericAnswerCarriesTheOriginalRequestAndQuestionForward() throws {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = RookPendingConversationStore(documentURL: folder.appendingPathComponent("pending.json"))
    store.set(
      RookPendingConversation(
        sourceCommand: "Schedule a study block tomorrow",
        question: "What time should I schedule it?",
        expiresAt: Date().addingTimeInterval(1_800)
      )
    )

    guard case .continuation(let continuation) = store.resolve("3 PM for two hours") else {
      return XCTFail("Expected the answer to continue the scheduling request")
    }
    XCTAssertTrue(continuation.effectiveCommand.contains("Schedule a study block tomorrow"))
    XCTAssertTrue(continuation.effectiveCommand.contains("What time should I schedule it?"))
    XCTAssertTrue(continuation.effectiveCommand.contains("3 PM for two hours"))
  }

  func testDetectorKeepsMissingDetailsButNotRhetoricalConversation() throws {
    let clarification = RookResponse(
      displayText: "I can schedule that. What time should I use?",
      spokenText: "What time should I use?",
      intent: "answer",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    let pending = try XCTUnwrap(
      RookPendingConversationDetector.detect(
        response: clarification,
        sourceCommand: "Schedule a study block tomorrow",
        route: "deliberate"
      )
    )
    XCTAssertEqual(pending.domain, .general)
    XCTAssertEqual(pending.question, "What time should I use?")

    let greeting = RookResponse(
      displayText: "Hey—what's up?",
      spokenText: "Hey, what's up?",
      intent: "answer",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    XCTAssertNil(
      RookPendingConversationDetector.detect(
        response: greeting,
        sourceCommand: "Hey Rook",
        route: "instant"
      )
    )
  }

  func testAContextSwitchClearsTheOpenLoopAndRoutesAsANewRequest() {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = RookPendingConversationStore(documentURL: folder.appendingPathComponent("pending.json"))
    store.set(spotifyPending())

    XCTAssertEqual(store.resolve("What's the weather tomorrow?"), .none)
    XCTAssertNil(store.pending)

    store.set(spotifyPending())
    XCTAssertEqual(store.resolve("I need help with my resume"), .none)
    XCTAssertNil(store.pending)
  }

  func testCancellationDropsTheOpenLoop() {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = RookPendingConversationStore(documentURL: folder.appendingPathComponent("pending.json"))
    let pending = spotifyPending()
    store.set(pending)

    XCTAssertEqual(store.resolve("Never mind"), .cancelled(pending))
    XCTAssertNil(store.pending)
  }

  func testRetryTargetsTheOpenRequestInsteadOfTreatingRetryAsAnAnswer() {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var store = RookPendingConversationStore(documentURL: folder.appendingPathComponent("pending.json"))
    let pending = spotifyPending()
    store.set(pending)

    XCTAssertEqual(store.resolve("Try that again"), .retry(pending))
    XCTAssertNil(store.pending)
  }

  func testExpiredQuestionIsNotUsedAsContext() {
    let folder = temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("pending.json")
    var store = RookPendingConversationStore(documentURL: url)
    store.set(
      RookPendingConversation(
        sourceCommand: "Old request",
        question: "Which one?",
        createdAt: Date(timeIntervalSince1970: 10),
        expiresAt: Date(timeIntervalSince1970: 20)
      )
    )

    XCTAssertEqual(store.resolve("the first one", now: Date(timeIntervalSince1970: 30)), .none)
    XCTAssertNil(store.pending)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  private func spotifyPending() -> RookPendingConversation {
    RookPendingConversation(
      sourceCommand: "Play my Spotify playlist",
      question: "Which playlist should I play?",
      domain: .spotifyPlaylist,
      options: ["Deep Focus", "Running"],
      expiresAt: Date().addingTimeInterval(1_800)
    )
  }

  private func playlistCanvas(_ names: [String]) -> RookCanvasBlock {
    RookCanvasBlock(
      id: "spotify_playlists",
      kind: .spotify,
      title: "Your playlists",
      items: names.enumerated().map { index, name in
        RookCanvasItem(id: "playlist_\(index)", label: name, symbol: .music)
      }
    )
  }

  private func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-pending-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
