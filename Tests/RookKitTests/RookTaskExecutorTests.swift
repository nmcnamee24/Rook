import XCTest

@testable import RookKit

@MainActor
final class RookTaskExecutorTests: XCTestCase {
  func testSpotifyHybridExecutesNativeStepsBeforeDependentResearch() async throws {
    let command =
      "Open Spotify, play a playlist, and tell me about the song that's playing and research the artist."
    guard let plan = RookHybridCapabilityPlanner.plan(command) else {
      return XCTFail("Expected the Spotify request to produce a hybrid plan")
    }

    var calls: [RookSpotifyIntent] = []
    var events: [RookTaskStepEvent] = []
    let executor = RookTaskExecutor { intent in
      calls.append(intent)
      switch intent {
      case .playAnyPlaylist:
        return taskOutput(
          display: "Playing Deep Focus.",
          verified: true,
          track: "First Light",
          artist: "Northstar"
        )
      case .nowPlaying:
        return taskOutput(
          display: "First Light by Northstar is playing.",
          verified: true,
          track: "First Light",
          artist: "Northstar"
        )
      default:
        throw RookSpotifyError.invalidResponse
      }
    }

    let result = await executor.execute(plan) { events.append($0) }

    XCTAssertEqual(calls, [.playAnyPlaylist, .nowPlaying])
    XCTAssertEqual(result.steps.map(\.state), [.succeeded, .succeeded, .pending])
    XCTAssertTrue(result.steps[0].verified)
    XCTAssertTrue(result.steps[1].verified)
    XCTAssertTrue(result.canStartDependentWork)
    XCTAssertTrue(result.promptContext.contains("track: First Light"))
    XCTAssertTrue(result.promptContext.contains("artist: Northstar"))
    XCTAssertEqual(
      events.map(\.kind),
      [.started, .succeeded, .started, .succeeded, .ready]
    )
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex { $0.kind == .succeeded && $0.step.order == 1 }),
      try XCTUnwrap(events.firstIndex { $0.kind == .started && $0.step.order == 2 })
    )
    XCTAssertLessThan(
      try XCTUnwrap(events.firstIndex { $0.kind == .succeeded && $0.step.order == 2 }),
      try XCTUnwrap(events.firstIndex { $0.kind == .ready && $0.step.order == 3 })
    )
  }

  func testPlaybackFailureIsNotRetriedAndStopsEveryDependency() async throws {
    let plan = try spotifyResearchPlan()
    var calls = 0
    let executor = RookTaskExecutor { _ in
      calls += 1
      throw RookSpotifyError.network
    }

    let result = await executor.execute(plan)

    XCTAssertEqual(calls, 1)
    XCTAssertEqual(result.steps.map(\.state), [.failed, .skipped, .skipped])
    XCTAssertEqual(result.steps[0].failureCategory, .providerUnavailable)
    XCTAssertEqual(result.steps[0].recovery?.action, .stop)
    XCTAssertEqual(result.steps[1].failureCategory, .dependencyFailed)
    XCTAssertEqual(result.steps[2].failureCategory, .dependencyFailed)
    XCTAssertFalse(result.canStartDependentWork)
  }

  func testReadOnlyNowPlayingStepRetriesOnceBeforeResearch() async {
    let plan = RookHybridCapabilityPlan(steps: [
      RookHybridPlanStep(
        order: 1,
        clause: "What is playing on Spotify",
        capabilities: [.spotify],
        owner: .central
      ),
      RookHybridPlanStep(
        order: 2,
        clause: "research the artist",
        capabilities: [],
        owner: .pawnEligible,
        dependsOn: [1]
      ),
    ])
    var calls = 0
    var events: [RookTaskStepEventKind] = []
    let executor = RookTaskExecutor { intent in
      XCTAssertEqual(intent, .nowPlaying)
      calls += 1
      if calls == 1 { throw RookSpotifyError.network }
      return taskOutput(
        display: "First Light by Northstar is playing.",
        verified: true,
        track: "First Light",
        artist: "Northstar"
      )
    }

    let result = await executor.execute(plan) { events.append($0.kind) }

    XCTAssertEqual(calls, 2)
    XCTAssertEqual(result.steps.map(\.state), [.succeeded, .pending])
    XCTAssertEqual(result.steps[0].attemptCount, 2)
    XCTAssertTrue(events.contains(.retrying))
    XCTAssertTrue(result.canStartDependentWork)
  }

  func testClarificationBlocksResearchAndPreservesTheSpotifyQuestion() async {
    let plan = RookHybridCapabilityPlan(steps: [
      RookHybridPlanStep(
        order: 1,
        clause: "Play my Focus playlist on Spotify",
        capabilities: [.spotify],
        owner: .central
      ),
      RookHybridPlanStep(
        order: 2,
        clause: "research the artist",
        capabilities: [],
        owner: .pawnEligible,
        dependsOn: [1]
      ),
    ])
    let clarification = RookResponse(
      displayText: "Which playlist should I play? Deep Focus or Focus Mix?",
      spokenText: "Which playlist should I play?",
      intent: "clarification",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    let executor = RookTaskExecutor { _ in
      RookTaskAdapterOutput(response: clarification, verified: false)
    }

    let result = await executor.execute(plan)

    XCTAssertEqual(result.steps.map(\.state), [.blocked, .skipped])
    XCTAssertEqual(result.blockingStep?.failureCategory, .ambiguity)
    XCTAssertEqual(result.blockingStep?.response, clarification)
    XCTAssertEqual(result.blockingStep?.recovery?.action, .clarify)
    XCTAssertFalse(result.canStartDependentWork)
  }

  private func spotifyResearchPlan() throws -> RookHybridCapabilityPlan {
    let command =
      "Open Spotify, play a playlist, and tell me about the song that's playing and research the artist."
    guard let plan = RookHybridCapabilityPlanner.plan(command) else {
      throw TestFailure.expectedHybridPlan
    }
    return plan
  }

  private enum TestFailure: Error {
    case expectedHybridPlan
  }
}

@MainActor
private func taskOutput(
  display: String,
  verified: Bool,
  track: String,
  artist: String
) -> RookTaskAdapterOutput {
  RookTaskAdapterOutput(
    response: RookResponse(
      displayText: display,
      spokenText: display,
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    ),
    verified: verified,
    evidence: RookTaskStepEvidence(
      summary: "Spotify verified \(track) by \(artist).",
      values: ["artist": artist, "track": track]
    )
  )
}
