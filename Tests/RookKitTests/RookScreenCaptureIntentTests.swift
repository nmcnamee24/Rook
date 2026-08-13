import XCTest

@testable import RookKit

final class RookScreenCaptureIntentTests: XCTestCase {
  func testRecognizesMainDisplayCaptureAndInspection() {
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("Take a screenshot of my screen"),
      RookScreenCaptureRequest(target: .mainDisplay)
    )
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("What’s currently on my screen?"),
      RookScreenCaptureRequest(target: .mainDisplay)
    )
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("Look at my desktop and tell me what needs attention"),
      RookScreenCaptureRequest(target: .mainDisplay)
    )
  }

  func testRecognizesFrontmostAndNamedWindows() {
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("Capture the active window"),
      RookScreenCaptureRequest(target: .frontmostWindow)
    )
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("Take a screenshot of my Safari window"),
      RookScreenCaptureRequest(target: .namedWindow("Safari"))
    )
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("Look at the Chrome window and tell me why login failed"),
      RookScreenCaptureRequest(target: .namedWindow("Chrome"))
    )
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("Take a screenshot of Notes"),
      RookScreenCaptureRequest(target: .namedWindow("Notes"))
    )
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("Screenshot my Xcode window"),
      RookScreenCaptureRequest(target: .namedWindow("Xcode"))
    )
    XCTAssertEqual(
      RookScreenCaptureCommandParser.parse("Inspect the window titled Quarterly Review"),
      RookScreenCaptureRequest(target: .namedWindow("Quarterly Review"))
    )
  }

  func testDoesNotHijackUnrelatedScreenLanguage() {
    XCTAssertNil(RookScreenCaptureCommandParser.parse("Search for screenshot tools in Safari"))
    XCTAssertNil(RookScreenCaptureCommandParser.parse("Open Safari"))
    XCTAssertNil(RookScreenCaptureCommandParser.parse("Make the dashboard fit smaller screens"))
  }
}
