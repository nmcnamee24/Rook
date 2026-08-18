import Foundation
import XCTest

@testable import RookKit

final class RookCodingTaskTests: XCTestCase {
  func testCodingTaskStorePersistsThreadAndCompletion() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-coding-task-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RookCodingTaskStore(directoryURL: directory)
    let requestID = UUID()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let queued = try store.begin(
      requestID: requestID,
      command: "Fix the failing tests.",
      workspacePath: "/Users/example/project",
      now: startedAt
    )
    XCTAssertEqual(queued.status, .queued)
    XCTAssertNil(queued.threadID)

    let working = try store.markStarted(
      requestID: requestID,
      threadID: "thread-123",
      now: startedAt.addingTimeInterval(2)
    )
    XCTAssertEqual(working.status, .working)
    XCTAssertEqual(working.threadID, "thread-123")

    let completed = try store.complete(
      requestID: requestID,
      summary: "Updated the parser and ran the focused tests.",
      now: startedAt.addingTimeInterval(8)
    )
    XCTAssertEqual(completed.status, .completed)
    XCTAssertEqual(completed.finalSummary, "Updated the parser and ran the focused tests.")
    XCTAssertEqual(try store.load(requestID: requestID), completed)
  }

  func testCodingTaskStoreMarksOrphanedWorkInterrupted() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-coding-task-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RookCodingTaskStore(directoryURL: directory)
    let requestID = UUID()
    _ = try store.begin(
      requestID: requestID,
      command: "Implement the feature.",
      workspacePath: "/Users/example/project"
    )
    _ = try store.markStarted(requestID: requestID, threadID: "thread-456")

    try store.recoverInterrupted(reason: "Rook restarted.")

    let recovered = try XCTUnwrap(store.load(requestID: requestID))
    XCTAssertEqual(recovered.status, .interrupted)
    XCTAssertEqual(recovered.threadID, "thread-456")
    XCTAssertEqual(recovered.failureReason, "Rook restarted.")
  }

  func testCodingProgressNeverExposesCommandContents() {
    XCTAssertEqual(
      RookCodingTaskEventMapper.progress(
        method: "item/started",
        itemType: "fileChange"
      ),
      RookCodingTaskProgress(
        stage: .editing,
        detail: "Codex is applying a scoped code change."
      )
    )
    XCTAssertEqual(
      RookCodingTaskEventMapper.progress(
        method: "item/completed",
        itemType: "commandExecution"
      )?.stage,
      .verifying
    )
    XCTAssertNil(
      RookCodingTaskEventMapper.progress(
        method: "item/agentMessage/delta",
        itemType: "agentMessage"
      )
    )
  }

  func testCodingIntentIsAcceptedByBothResponseSchemas() throws {
    let quick = try JSONDecoder().decode(
      QuickRookResponse.self,
      from: Data(
        #"{"display_text":"Starting Codex.","spoken_text":"Starting Codex.","route":"deliberate","intent":"coding","pawns":[],"canvas":[]}"#
          .utf8
      )
    )
    XCTAssertEqual(quick.intent, "coding")
    XCTAssertTrue(QuickRookResponse.outputSchema.contains(#""coding""#))
    XCTAssertTrue(RookResponse.outputSchema.contains(#""coding""#))
  }
}
