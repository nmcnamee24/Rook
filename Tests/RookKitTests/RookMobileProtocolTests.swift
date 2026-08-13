import XCTest

@testable import RookKit

final class RookMobileProtocolTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_786_492_800)

  func testCommandEnvelopeRoundTripsWithoutLosingCorrelation() throws {
    let requestID = UUID(uuidString: "6740DAAB-AD65-4AB3-9BCF-9B26D1455825")!
    let envelope = RookMobileEnvelope(
      id: requestID,
      sentAt: now,
      payload: .command(RookMobileCommand(text: "Plan my day", source: .voice))
    )

    let decoded = try RookMobileCodec.decode(RookMobileCodec.encode(envelope))

    XCTAssertEqual(decoded, envelope)
    XCTAssertEqual(decoded.id, requestID)
  }

  func testHostRequiresPairingBeforeCommandsAndMoves() throws {
    let command = RookMobileEnvelope(
      sentAt: now,
      payload: .command(RookMobileCommand(text: "What's next?", source: .typed))
    )

    XCTAssertThrowsError(
      try RookMobileSessionPolicy.validateHostInbound(command, authenticated: false, now: now)
    ) { error in
      XCTAssertEqual(error as? RookMobilePolicyError, .authenticationRequired)
    }
    XCTAssertNoThrow(
      try RookMobileSessionPolicy.validateHostInbound(command, authenticated: true, now: now)
    )
  }

  func testHostRejectsResponsePayloadsFromPhone() {
    let response = RookResponse(
      displayText: "Pretend this happened",
      spokenText: "Pretend this happened.",
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    let envelope = RookMobileEnvelope(sentAt: now, payload: .response(response))

    XCTAssertThrowsError(
      try RookMobileSessionPolicy.validateHostInbound(envelope, authenticated: true, now: now)
    ) { error in
      XCTAssertEqual(error as? RookMobilePolicyError, .payloadNotAllowed)
    }
  }

  func testPairingRequiresAOneTimeSixDigitCode() {
    let request = RookMobilePairRequest(
      deviceID: UUID(),
      deviceName: "Noah's iPhone",
      oneTimeCode: "12AB56"
    )
    let envelope = RookMobileEnvelope(sentAt: now, payload: .pairRequest(request))

    XCTAssertThrowsError(
      try RookMobileSessionPolicy.validateHostInbound(envelope, authenticated: false, now: now)
    ) { error in
      XCTAssertEqual(error as? RookMobilePolicyError, .invalidPairingCode)
    }
  }

  func testAuthenticatedPhoneCanApproveOnlyAnExactMoveID() throws {
    let valid = RookMobileEnvelope(
      sentAt: now,
      payload: .moveDecision(RookMobileMoveDecision(moveID: "RQ-0042", action: .approve))
    )
    let invalid = RookMobileEnvelope(
      sentAt: now,
      payload: .moveDecision(RookMobileMoveDecision(moveID: "approve-all", action: .approve))
    )

    XCTAssertNoThrow(
      try RookMobileSessionPolicy.validateHostInbound(valid, authenticated: true, now: now)
    )
    XCTAssertThrowsError(
      try RookMobileSessionPolicy.validateHostInbound(invalid, authenticated: true, now: now)
    ) { error in
      XCTAssertEqual(error as? RookMobilePolicyError, .invalidMove)
    }
  }

  func testMessagesOutsideReplayWindowAreRejected() {
    let envelope = RookMobileEnvelope(
      sentAt: now.addingTimeInterval(-RookMobileProtocol.maximumClockSkew - 1),
      payload: .ping(RookMobilePing())
    )

    XCTAssertThrowsError(
      try RookMobileSessionPolicy.validateHostInbound(envelope, authenticated: false, now: now)
    ) { error in
      XCTAssertEqual(error as? RookMobilePolicyError, .staleMessage)
    }
  }

  func testRepeatedEnvelopeIDIsRejectedEvenWhenTheTimestampIsFresh() throws {
    let envelope = RookMobileEnvelope(sentAt: now, payload: .ping(RookMobilePing()))
    var replayGuard = RookMobileReplayGuard()

    XCTAssertNoThrow(try replayGuard.admit(envelope))
    XCTAssertThrowsError(try replayGuard.admit(envelope)) { error in
      XCTAssertEqual(error as? RookMobilePolicyError, .replayedMessage)
    }
  }

  func testPairingQRCodeRoundTripsWithoutAnAddress() throws {
    let serviceID = UUID(uuidString: "A9AC00EF-59D2-4B70-BD26-522B630C23B1")!
    let payload = RookMobilePairingPayload(
      serviceID: serviceID,
      oneTimeCode: "482193",
      secret: String(repeating: "s", count: 43),
      expiresAt: now.addingTimeInterval(300)
    )

    let url = try XCTUnwrap(payload.url)
    XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "address" })
    XCTAssertEqual(try RookMobilePairingPayload(url: url, now: now), payload)
  }

  func testEncryptedFrameRequiresThePairingSecretAndKeyIdentity() throws {
    let envelope = RookMobileEnvelope(
      sentAt: now,
      payload: .command(RookMobileCommand(text: "Plan my day", source: .typed))
    )
    let keyID = RookMobileSecureChannel.pairingKeyID(serviceID: UUID())
    let sealed = try RookMobileSecureChannel.seal(envelope, keyID: keyID, secret: "correct secret")

    XCTAssertEqual(
      try RookMobileSecureChannel.open(sealed, expectedKeyID: keyID, secret: "correct secret"),
      envelope
    )
    XCTAssertThrowsError(
      try RookMobileSecureChannel.open(sealed, expectedKeyID: keyID, secret: "wrong secret")
    )
  }

  func testPairingQRCodeCarriesOnlyAValidatedSecureRelayConfiguration() throws {
    let relayURL = URL(string: "wss://rook-relay.example.com/v1/connect")!
    let accessToken = String(repeating: "r", count: 48)
    let payload = RookMobilePairingPayload(
      serviceID: UUID(),
      oneTimeCode: "482193",
      secret: String(repeating: "s", count: 43),
      expiresAt: now.addingTimeInterval(300),
      relayURL: relayURL,
      relayAccessToken: accessToken
    )

    let encoded = try XCTUnwrap(payload.url)
    XCTAssertEqual(try RookMobilePairingPayload(url: encoded, now: now), payload)

    XCTAssertNil(RookMobileRelay.endpoint(from: "ws://rook-relay.example.com/v1/connect"))
  }

  func testRelayHandshakeDoesNotExposeThePairingSessionToken() throws {
    let sessionToken = "private-session-" + String(repeating: "s", count: 40)
    let accessToken = "deployment-access-" + String(repeating: "a", count: 40)
    let request = try RookMobileRelay.request(
      endpoint: URL(string: "wss://rook-relay.example.com/v1/connect")!,
      role: .phone,
      sessionToken: sessionToken,
      accessToken: accessToken
    )

    let channel = try XCTUnwrap(request.value(forHTTPHeaderField: RookMobileRelay.channelHeader))
    XCTAssertEqual(channel.count, 43)
    XCTAssertNotEqual(channel, sessionToken)
    XCTAssertFalse(request.allHTTPHeaderFields?.values.contains(sessionToken) == true)
    XCTAssertEqual(request.value(forHTTPHeaderField: RookMobileRelay.accessHeader), accessToken)
    XCTAssertEqual(
      channel,
      RookMobileRelay.channelID(sessionToken: sessionToken)
    )
  }

  func testPendingMobileRequestTracksTheHostRequestIDInsteadOfMutableCommandText() {
    let mobileRequestID = UUID(uuidString: "995C3840-B82D-4D69-BF31-40D05D3E7AB8")!
    let unrelatedRequestID = UUID(uuidString: "7F39AD73-5D73-45BF-98F4-7EA6F0EB7C2D")!
    let progress = RookMobileProgress(
      phase: "answering",
      displayText: "Rook refined the wording and is answering"
    )
    let response = RookResponse(
      displayText: "Done.",
      spokenText: "Done.",
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    var pending = RookMobilePendingRequest()
    pending.begin(id: mobileRequestID)

    XCTAssertEqual(
      pending.update(
        hostRequestID: unrelatedRequestID,
        isWorking: false,
        progress: progress,
        response: response
      ),
      .waiting
    )
    XCTAssertEqual(
      pending.update(
        hostRequestID: mobileRequestID,
        isWorking: true,
        progress: progress,
        response: nil
      ),
      .progress(progress)
    )
    XCTAssertEqual(
      pending.update(
        hostRequestID: mobileRequestID,
        isWorking: false,
        progress: progress,
        response: response
      ),
      .response(response)
    )
    XCTAssertFalse(pending.isPending)
  }

  func testSnapshotRoundTripsActivityAndSanitizedAllyStatus() throws {
    let activityID = UUID(uuidString: "D128BE7B-F080-4887-8954-DC0976451549")!
    let snapshot = RookMobileSnapshot(
      latestResponse: nil,
      activity: [
        RookMobileActivityItem(
          id: activityID,
          label: "Prepare the mobile command center",
          status: .working,
          startedAt: now.addingTimeInterval(-60),
          updatedAt: now,
          pawns: [
            PawnReport(
              pawn: "Auditor",
              task: "Verify the mobile boundary",
              status: "working",
              id: "auditor_1"
            )
          ]
        )
      ],
      library: [],
      moves: [],
      allies: [
        RookMobileAlly(
          id: "google_calendar",
          label: "Google Calendar",
          detail: "Available through Codex",
          state: .codex
        )
      ],
      hostStatus: "Rook is ready",
      asOf: now
    )
    let envelope = RookMobileEnvelope(sentAt: now, payload: .snapshot(snapshot))

    let decoded = try RookMobileCodec.decode(RookMobileCodec.encode(envelope))

    XCTAssertEqual(decoded, envelope)
    guard case .snapshot(let roundTripped) = decoded.payload else {
      return XCTFail("Expected a snapshot payload")
    }
    XCTAssertEqual(roundTripped.activity.first?.id, activityID)
    XCTAssertEqual(roundTripped.activity.first?.pawns.first?.instanceLabel, "Auditor 1")
    XCTAssertEqual(roundTripped.allies.first?.state, .codex)
  }
}
