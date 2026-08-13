import XCTest

@testable import RookKit

final class RookDirectCapabilityGuideTests: XCTestCase {
  func testCheatSheetListsEveryDirectCapabilityInAttemptOrder() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.cheatSheet.map(\.id),
      [
        .reflex,
        .weather,
        .spotify,
        .screenCapture,
        .computerControl,
        .librarianCheckpoint,
      ]
    )
    XCTAssertTrue(RookDirectCapabilityGuide.cheatSheet.allSatisfy { !$0.adapter.isEmpty })
    XCTAssertTrue(RookDirectCapabilityGuide.cheatSheet.allSatisfy { !$0.fallback.isEmpty })
  }

  func testCasualWeatherLanguageGetsANativeSecondChance() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Will it rain tomorrow in Boston?"),
      .weather(RookWeatherRequest(locationQuery: "Boston", dayOffset: 1, dayCount: 1))
    )
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("How cold is it in Oakland today?"),
      .weather(RookWeatherRequest(locationQuery: "Oakland", dayOffset: 0, dayCount: 1))
    )
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Could you check the next three day forecast?"),
      .weather(RookWeatherRequest(locationQuery: nil, dayOffset: 0, dayCount: 3))
    )
  }

  func testNaturalSpotifyLanguageStaysDirectWithoutDependingOnConnectionState() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve(
        "Could you pull up everything in my Spotify playlist collection"
      ),
      .spotify(.playlists)
    )
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Put on something from my most played Spotify songs"),
      .spotify(.playTopTracks)
    )
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve(
        "Which of these playlists seems like a study or work or focus playlist?"
      ),
      .spotify(.recommendPlaylists(purposes: [.study, .work, .focus]))
    )
  }

  func testOtherNativeCommandsStillWinOverKeywordMentions() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Search for weather tomorrow using Chrome"),
      .computerControl(.webSearch(browser: .chrome, query: "weather tomorrow"))
    )
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Open Spotify"),
      .computerControl(.openApplication(name: "Spotify"))
    )
  }

  func testUnsupportedKnownDomainsFallThroughInsteadOfExecutingAPartialMatch() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Are there weather alerts near the beach?"),
      .fallThrough(.weather)
    )
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("How does Spotify Wrapped work?"),
      .fallThrough(.spotify)
    )

    let weatherFallback = LocalRookRouter.routeAfterDirectCapabilityMiss(
      "Are there weather alerts near the beach?",
      capability: .weather
    )
    let spotifyFallback = LocalRookRouter.routeAfterDirectCapabilityMiss(
      "How does Spotify Wrapped work?",
      capability: .spotify
    )
    XCTAssertEqual(weatherFallback.destination, .deliberate)
    XCTAssertFalse(weatherFallback.response.pawns.isEmpty)
    XCTAssertEqual(spotifyFallback.destination, .deliberate)
    XCTAssertFalse(spotifyFallback.response.pawns.isEmpty)
  }

  func testFreshLibrarianDecisionIsPartOfTheSameGuide() {
    let cached = LocalRookDecision(
      destination: .instant,
      response: QuickRookResponse(
        displayText: "Your next event starts at 3:00 PM.",
        spokenText: "Your next event starts at three.",
        route: "answer_now",
        intent: "brief",
        pawns: []
      )
    )

    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("What's next?", cachedDecision: cached),
      .librarianCheckpoint(cached)
    )
  }

  func testComputerControlAndPawnWorkBecomeOneOrderedHybridPlan() throws {
    let resolution = RookDirectCapabilityGuide.resolve(
      "Open Spotify and research the artist playing right now"
    )
    guard case .hybrid(let plan) = resolution else {
      return XCTFail("Expected a hybrid capability plan")
    }

    XCTAssertEqual(plan.steps.map(\.clause), ["Open Spotify", "research the artist playing right now"])
    XCTAssertEqual(plan.steps.map(\.owner), [.central, .pawnEligible])
    XCTAssertEqual(plan.centralCapabilities, [.computerControl])
    XCTAssertTrue(plan.requiresComputerOperator)

    let decision = LocalRookRouter.routeHybrid(
      "Open Spotify and research the artist playing right now",
      plan: plan
    )
    XCTAssertEqual(decision.destination, .deliberate)
    XCTAssertTrue(decision.response.pawns.contains { $0.pawn == "Scout" })
    XCTAssertFalse(decision.response.pawns.contains { $0.task.localizedCaseInsensitiveContains("open spotify") })
  }

  func testHybridPlanPreservesCentralStepAfterPawnEligibleResearch() throws {
    let resolution = RookDirectCapabilityGuide.resolve(
      "Research the best focus playlist then open Spotify"
    )
    guard case .hybrid(let plan) = resolution else {
      return XCTFail("Expected a hybrid capability plan")
    }

    XCTAssertEqual(plan.steps.map(\.owner), [.pawnEligible, .central])
    XCTAssertEqual(plan.steps.last?.capabilities, [.computerControl])
  }

  func testSupportedNativeCompoundCommandDoesNotBecomeHybrid() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Open Spotify and play my music"),
      .spotify(.resume)
    )
  }
}
