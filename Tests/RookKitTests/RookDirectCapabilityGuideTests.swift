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
    XCTAssertTrue(
      RookDirectCapabilityGuide.cheatSheet.allSatisfy {
        $0.executionContract.capability == $0.id
          && !$0.executionContract.adapter.isEmpty
          && !$0.executionContract.verification.isEmpty
      }
    )
  }

  func testNonSpotifyCapabilitiesDeclareDependentWorkContracts() {
    let weather = RookDirectCapabilityGuide.executionContract(for: .weather)
    XCTAssertEqual(weather.adapter, "open_meteo")
    XCTAssertEqual(weather.effect, .readOnly)
    XCTAssertEqual(weather.retryRule, .retryReadOnce)
    XCTAssertTrue(weather.mayFeedDependentWork)

    let computer = RookDirectCapabilityGuide.executionContract(for: .computerControl)
    XCTAssertEqual(computer.adapter, "native_mac_controller")
    XCTAssertEqual(computer.retryRule, .neverRepeatMutation)

    let plan = RookHybridCapabilityPlan(steps: [
      RookHybridPlanStep(
        order: 1,
        clause: "Weather in Boston today",
        capabilities: [.weather],
        owner: .central
      ),
      RookHybridPlanStep(
        order: 2,
        clause: "explain whether I should bring a coat",
        capabilities: [],
        owner: .pawnEligible,
        dependsOn: [1]
      ),
    ])
    XCTAssertEqual(plan.executionContracts, [weather])
  }

  func testSemanticWeatherLanguageGoesToCentralRook() {
    for command in [
      "Will it rain tomorrow in Boston?",
      "How cold is it in Oakland today?",
      "Could you check the next three day forecast?",
    ] {
      XCTAssertEqual(RookDirectCapabilityGuide.resolve(command), .unclaimed)
    }
  }

  func testSemanticSpotifyLanguageGoesToCentralRook() {
    for command in [
      "Could you pull up everything in my Spotify playlist collection",
      "Put on something from my most played Spotify songs",
      "Which of these playlists seems like a study or work or focus playlist?",
    ] {
      XCTAssertEqual(RookDirectCapabilityGuide.resolve(command), .unclaimed)
    }
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

  func testUnsupportedKnownDomainsStayUnclaimedInsteadOfExecutingAPartialMatch() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Are there weather alerts near the beach?"),
      .unclaimed
    )
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("How does Spotify Wrapped work?"),
      .unclaimed
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
    XCTAssertTrue(weatherFallback.response.pawns.isEmpty)
    XCTAssertEqual(spotifyFallback.destination, .deliberate)
    XCTAssertTrue(spotifyFallback.response.pawns.isEmpty)
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

  func testLegacyHybridPlannerCanRestoreOneOrderedPlan() throws {
    guard
      let plan = RookHybridCapabilityPlanner.plan(
        "Open Spotify and research the artist playing right now"
      )
    else {
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
    XCTAssertTrue(decision.response.pawns.isEmpty)
  }

  func testLegacyHybridPlannerPreservesCentralStepAfterPawnEligibleResearch() throws {
    guard
      let plan = RookHybridCapabilityPlanner.plan(
        "Research the best focus playlist then open Spotify"
      )
    else {
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

  func testLegacySpotifyPlanRemainsDependencyOrderedForInFlightWork() throws {
    let command =
      "Open Spotify, play a playlist, and tell me about the song that's playing and research the artist."
    guard let plan = RookHybridCapabilityPlanner.plan(command) else {
      return XCTFail("Expected a dependent Spotify and research plan")
    }

    XCTAssertEqual(plan.steps.map(\.owner), [.central, .central, .pawnEligible])
    XCTAssertEqual(plan.steps[0].capabilities, [.spotify])
    XCTAssertEqual(plan.steps[1].capabilities, [.spotify])
    XCTAssertEqual(plan.steps[1].dependsOn, [1])
    XCTAssertEqual(plan.steps[2].dependsOn, [2])
    XCTAssertFalse(plan.requiresComputerOperator)
  }

  func testOpeningBrowserAtAddressStaysOnNarrowNativeController() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Open Safari and go to https://example.com"),
      .computerControl(.openWebAddress(browser: .safari, address: "https://example.com"))
    )
  }
}
