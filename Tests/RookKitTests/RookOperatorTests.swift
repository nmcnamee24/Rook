import Foundation
import XCTest

@testable import RookKit

final class RookOperatorTests: XCTestCase {
  func testComputerUseElicitationIsSilentlyApprovedAndPersisted() throws {
    let message: [String: Any] = [
      "id": 42,
      "method": "mcpServer/elicitation/request",
      "params": [
        "mode": "form",
        "serverName": "node_repl",
        "message": "Allow Computer Use to use \"Spotify\"?",
        "requestedSchema": ["type": "object", "properties": [:]],
        "_meta": [
          "codex_approval_kind": "mcp_tool_call",
          "connector_id": "computer-use",
          "persist": ["session", "always"],
          "tool_params": ["app": "com.spotify.client"],
        ],
      ],
    ]

    let decision = try XCTUnwrap(RookComputerUseAutoApproval.decision(for: message))
    XCTAssertEqual(decision.scopeLabel, "com.spotify.client")
    XCTAssertTrue(decision.persistAlways)

    let response = RookComputerUseAutoApproval.response(for: decision)
    XCTAssertEqual(response["action"] as? String, "accept")
    XCTAssertNotNil(response["content"] as? [String: Any])
    XCTAssertEqual((response["_meta"] as? [String: String])?["persist"], "always")
  }

  func testOnlyComputerUseAppAccessIsAutoApproved() {
    let genericConnector: [String: Any] = [
      "method": "mcpServer/elicitation/request",
      "params": [
        "mode": "form",
        "_meta": [
          "codex_approval_kind": "mcp_tool_call",
          "connector_id": "gmail",
          "persist": ["always"],
          "tool_params": ["app": "com.apple.Mail"],
        ],
      ],
    ]
    let commandApproval: [String: Any] = [
      "method": "item/commandExecution/requestApproval",
      "params": ["command": "example"],
    ]
    let allApps: [String: Any] = [
      "method": "mcpServer/elicitation/request",
      "params": [
        "mode": "form",
        "_meta": [
          "codex_approval_kind": "mcp_tool_call",
          "connector_id": "computer-use",
          "persist": ["always"],
          "tool_params": [:],
        ],
      ],
    ]

    XCTAssertNil(RookComputerUseAutoApproval.decision(for: genericConnector))
    XCTAssertNil(RookComputerUseAutoApproval.decision(for: commandApproval))
    let decision = RookComputerUseAutoApproval.decision(for: allApps)
    XCTAssertEqual(decision?.scopeLabel, "Computer Use")
  }

  func testComputerOperatorRoutingCoversRequestsAndApprovalFollowUps() {
    XCTAssertTrue(RookComputerOperatorRouting.requiresComputerUse("Use my computer to text my girlfriend"))
    XCTAssertTrue(RookComputerOperatorRouting.requiresComputerUse("Inspect the Spotify app"))
    XCTAssertTrue(RookComputerOperatorRouting.requiresComputerUse("Click the download button"))
    XCTAssertTrue(RookComputerOperatorRouting.requiresComputerUse("I approve"))
    XCTAssertTrue(RookComputerOperatorRouting.requiresComputerUse("send it."))
    XCTAssertTrue(RookComputerOperatorRouting.requiresComputerUse("yes, send"))
    XCTAssertTrue(RookComputerOperatorRouting.isApprovalFollowUp("Yes—send it!"))

    XCTAssertFalse(RookComputerOperatorRouting.requiresComputerUse("Inspect the Rook app source code"))
    XCTAssertFalse(RookComputerOperatorRouting.requiresComputerUse("Review the repository architecture"))
    XCTAssertFalse(RookComputerOperatorRouting.requiresComputerUse("Research current browser market share"))
  }

  func testApprovalFollowUpsEscalateBeforeTheOrdinaryAnswerStream() {
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("send it."),
      .fallThrough(.computerControl)
    )
    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("yes, send"),
      .fallThrough(.computerControl)
    )
  }
}
