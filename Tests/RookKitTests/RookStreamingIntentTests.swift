import Foundation
import XCTest

@testable import RookKit

final class RookStreamingIntentTests: XCTestCase {
  func testOnlySideEffectFreeReflexWorkMayPrewarm() {
    XCTAssertEqual(
      RookStreamingIntentPolicy.candidate(for: "What is 15 percent of 240?")?.capability,
      .reflex
    )
    XCTAssertEqual(
      RookStreamingIntentPolicy.candidate(for: "Convert 10 miles to kilometers")?.adapter,
      "rook_reflex_prewarm"
    )

    for command in [
      "Set a timer for 10 minutes",
      "Turn the volume up",
      "What is my battery",
      "Weather in Boston today",
      "Play my Spotify",
      "Open Safari",
    ] {
      XCTAssertNil(RookStreamingIntentPolicy.candidate(for: command), command)
    }
  }

  func testTrackerRequiresStabilityAndEmitsOnce() throws {
    let started = Date(timeIntervalSince1970: 1_786_577_031)
    var tracker = RookStreamingIntentTracker(stabilityMilliseconds: 350)
    tracker.observe("What is 15 percent of 240?", at: started)

    XCTAssertNil(tracker.ready(at: started.addingTimeInterval(0.349)))
    XCTAssertNotNil(tracker.ready(at: started.addingTimeInterval(0.350)))
    XCTAssertNil(tracker.ready(at: started.addingTimeInterval(1)))
  }

  func testACompoundTailCancelsThePrewarmCandidate() {
    let started = Date(timeIntervalSince1970: 1_786_577_031)
    var tracker = RookStreamingIntentTracker(stabilityMilliseconds: 350)
    tracker.observe("What is 15 percent of 240?", at: started)
    tracker.observe(
      "What is 15 percent of 240 and email the result",
      at: started.addingTimeInterval(0.1)
    )

    XCTAssertNil(tracker.candidate)
    XCTAssertNil(tracker.ready(at: started.addingTimeInterval(1)))
  }
}
