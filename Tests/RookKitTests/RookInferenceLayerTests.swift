import Foundation
import XCTest

@testable import RookKit

final class RookInferenceLayerTests: XCTestCase {
  func testExplicitSendApprovalBindsToTheImmediatelyPrecedingGatedRequest() {
    let now = Date(timeIntervalSince1970: 1_786_577_031)
    let prior = libraryEntry(
      label: "Text Sophia",
      command: "Use my computer to text Sophia how much I love her.",
      summary: "Messages is open to Sophia. Nothing was sent because exact approval is required.",
      updatedAt: now.addingTimeInterval(-60)
    )

    for phrase in ["send it.", "yes, send"] {
      let interpretation = RookInferenceLayer.interpret(
        phrase,
        recentEntries: [prior],
        now: now
      )
      XCTAssertEqual(interpretation.basis, .recentContext)
      XCTAssertEqual(interpretation.displayCommand, "\(phrase)  →  Text Sophia")
      XCTAssertTrue(interpretation.effectiveCommand.contains(prior.command))
      XCTAssertTrue(interpretation.effectiveCommand.contains("current action-time approval"))
      XCTAssertEqual(interpretation.inferredResolution, .fallThrough(.computerControl))
    }
  }

  func testSendApprovalDoesNotBindToStaleOrUnrelatedHistory() {
    let now = Date(timeIntervalSince1970: 1_786_577_031)
    let unrelated = libraryEntry(
      command: "Explain how chess openings work.",
      summary: "Explained a stable general concept.",
      updatedAt: now.addingTimeInterval(-60)
    )
    let stale = libraryEntry(
      command: "Send a text to Sophia.",
      summary: "Waiting for exact approval.",
      updatedAt: now.addingTimeInterval(-31 * 60)
    )

    XCTAssertEqual(
      RookInferenceLayer.interpret("send it.", recentEntries: [unrelated, stale], now: now).basis,
      .explicit
    )
  }

  func testSemanticFindAndPlayIsLeftToCentralRook() {
    let interpretation = RookInferenceLayer.interpret("Find and play me a study playlist.")
    let decision = RookInferenceLayer.decide(interpretation)

    XCTAssertEqual(interpretation.basis, .explicit)
    XCTAssertEqual(decision.resolution, .unclaimed)
  }

  func testReferentialSpotifyPlaybackUsesTheSelectedRecentPlaylist() {
    let previous = RookResponse(
      displayText: "I found the strongest match: lock-in study music. Open Spotify, then tell me to play it.",
      spokenText: "I found a study playlist. Open Spotify, then tell me to play it.",
      intent: "error",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [
        PawnReport(
          pawn: "Scout",
          task: "Find a study-playlist candidate",
          status: "completed",
          id: "scout_1",
          result: "Selected “lock-in study music” as the strongest semantic match; two close matches were found.",
          evidence: ["Private Library snapshot: prior study-playlist matches"]
        )
      ]
    )

    let interpretation = RookInferenceLayer.interpret(
      "play that Spotify playlist.",
      lastResponse: previous
    )
    let decision = RookInferenceLayer.decide(interpretation)

    XCTAssertEqual(interpretation.basis, .recentContext)
    XCTAssertEqual(interpretation.displayCommand, "play that Spotify playlist.  →  lock-in study music")
    XCTAssertEqual(
      decision.resolution,
      .spotify(
        .play(query: "lock-in study music", preferredKind: .playlist, libraryOnly: true)
      )
    )
  }

  func testReferentialSpotifyPlaybackCanRecoverFromRecentLibraryEvidence() {
    let now = Date(timeIntervalSince1970: 1_786_568_700)
    let entry = libraryEntry(
      command: "Find and play me a study playlist.",
      summary: "I found the strongest match: lock-in study music. Open Spotify, then tell me to play it.",
      pawns: [
        PawnReport(
          pawn: "Scout",
          task: "Find a study-playlist candidate",
          status: "completed",
          result: "Selected “lock-in study music” as the strongest semantic match.",
          evidence: []
        )
      ],
      updatedAt: now.addingTimeInterval(-30)
    )

    let errorResponse = RookResponse(
      displayText: "Spotify needs attention. I couldn’t find that Spotify.",
      spokenText: "Spotify needs attention.",
      intent: "error",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "spotify_error",
          kind: .spotify,
          title: "Spotify",
          items: [
            RookCanvasItem(
              id: "spotify_issue",
              label: "Needs attention",
              detail: "Not completed",
              value: "Not completed",
              symbol: .warning
            )
          ]
        )
      ]
    )
    let interpretation = RookInferenceLayer.interpret(
      "play it",
      lastResponse: errorResponse,
      recentEntries: [entry],
      now: now
    )

    XCTAssertEqual(interpretation.basis, .recentContext)
    XCTAssertEqual(
      interpretation.inferredResolution,
      .spotify(
        .play(query: "lock-in study music", preferredKind: .playlist, libraryOnly: true)
      )
    )
  }

  func testUnresolvedReferenceClarifiesBeforeLiteralSpotifyParsing() {
    XCTAssertEqual(
      RookSpotifyCommandParser.parse("play that Spotify playlist."),
      .play(query: "that Spotify", preferredKind: .playlist, libraryOnly: true)
    )

    let interpretation = RookInferenceLayer.interpret("play that Spotify playlist.")
    let decision = RookInferenceLayer.decide(interpretation)

    XCTAssertEqual(interpretation.basis, .unresolvedReference)
    guard case .clarification(let capability, let message) = decision.resolution else {
      return XCTFail("The inference layer must stop an unresolved referent before literal parsing")
    }
    XCTAssertEqual(capability, .spotify)
    XCTAssertTrue(message.contains("Which Spotify playlist"))
  }

  func testCrossDomainWorkGoesIntactToCentralRook() {
    let interpretation = RookInferenceLayer.interpret(
      "Open Spotify and research the artist playing right now"
    )
    let decision = RookInferenceLayer.decide(interpretation)

    XCTAssertEqual(decision.resolution, .unclaimed)
    guard let plan = RookHybridCapabilityPlanner.plan(interpretation.effectiveCommand) else {
      return XCTFail("The legacy planner remains available only for restored in-flight work")
    }
    XCTAssertEqual(plan.steps.map(\.owner), [.central, .pawnEligible])
  }

  private func libraryEntry(
    label: String = "Study playlist",
    command: String,
    summary: String,
    pawns: [PawnReport] = [],
    updatedAt: Date
  ) -> RookLibraryEntry {
    RookLibraryEntry(
      id: UUID(),
      label: label,
      command: command,
      route: "deliberate",
      status: .blocked,
      summary: summary,
      failureReason: "Open Spotify first.",
      pawns: pawns,
      createdAt: updatedAt.addingTimeInterval(-10),
      updatedAt: updatedAt,
      tags: ["spotify", "playlist", "study"],
      conversationFolder: "/tmp/rook-inference-test",
      taskFolder: nil
    )
  }
}
