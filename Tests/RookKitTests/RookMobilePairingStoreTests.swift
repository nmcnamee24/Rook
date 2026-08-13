import XCTest

@testable import RookKit

final class RookMobilePairingStoreTests: XCTestCase {
  private var temporaryDirectory: URL!
  private var store: RookMobilePairingStore!
  private let now = Date(timeIntervalSince1970: 1_786_492_800)

  override func setUpWithError() throws {
    temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-mobile-pairing-\(UUID().uuidString)", isDirectory: true)
    store = try RookMobilePairingStore(stateDirectory: temporaryDirectory)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporaryDirectory)
  }

  func testPairingIsSingleUseAndStoresOnlyATokenDigest() throws {
    let offer = try store.beginPairing(
      serviceID: UUID(),
      now: now
    )
    let deviceID = UUID()
    let accepted = try store.accept(
      RookMobilePairRequest(
        deviceID: deviceID,
        deviceName: "Noah's iPhone",
        oneTimeCode: offer.oneTimeCode
      ),
      hostName: "Noah's MacBook Pro",
      now: now
    )

    XCTAssertGreaterThanOrEqual(accepted.sessionToken.count, 32)
    let persisted = try String(
      contentsOf: temporaryDirectory.appendingPathComponent("mobile_pairing.json"),
      encoding: .utf8
    )
    XCTAssertFalse(persisted.contains(accepted.sessionToken))
    XCTAssertTrue(persisted.contains("token_digest"))

    XCTAssertThrowsError(
      try store.accept(
        RookMobilePairRequest(
          deviceID: UUID(),
          deviceName: "Another phone",
          oneTimeCode: offer.oneTimeCode
        ),
        hostName: "Noah's MacBook Pro",
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? RookMobilePairingError, .noActiveOffer)
    }
  }

  func testAuthenticationRequiresExactDeviceAndToken() throws {
    let offer = try store.beginPairing(
      serviceID: UUID(),
      now: now
    )
    let deviceID = UUID()
    let accepted = try store.accept(
      RookMobilePairRequest(
        deviceID: deviceID,
        deviceName: "Noah's iPhone",
        oneTimeCode: offer.oneTimeCode
      ),
      hostName: "Noah's MacBook Pro",
      now: now
    )

    let summary = try store.authenticate(
      RookMobileAuthentication(deviceID: deviceID, sessionToken: accepted.sessionToken),
      now: now.addingTimeInterval(30)
    )
    XCTAssertEqual(summary.id, deviceID)
    XCTAssertEqual(summary.lastSeenAt, now.addingTimeInterval(30))

    XCTAssertThrowsError(
      try store.authenticate(
        RookMobileAuthentication(
          deviceID: deviceID,
          sessionToken: String(repeating: "x", count: 44)
        ),
        now: now
      )
    ) { error in
      XCTAssertEqual(error as? RookMobilePairingError, .deviceNotPaired)
    }
  }

  func testExpiredCodeCannotPair() throws {
    let offer = try store.beginPairing(
      serviceID: UUID(),
      now: now,
      lifetime: 60
    )

    XCTAssertThrowsError(
      try store.accept(
        RookMobilePairRequest(
          deviceID: UUID(),
          deviceName: "Noah's iPhone",
          oneTimeCode: offer.oneTimeCode
        ),
        hostName: "Noah's MacBook Pro",
        now: now.addingTimeInterval(61)
      )
    ) { error in
      XCTAssertEqual(error as? RookMobilePairingError, .offerExpired)
    }
  }

  func testRevokedDeviceCannotAuthenticate() throws {
    let offer = try store.beginPairing(
      serviceID: UUID(),
      now: now
    )
    let deviceID = UUID()
    let accepted = try store.accept(
      RookMobilePairRequest(
        deviceID: deviceID,
        deviceName: "Noah's iPhone",
        oneTimeCode: offer.oneTimeCode
      ),
      hostName: "Noah's MacBook Pro",
      now: now
    )
    try store.revoke(deviceID: deviceID)

    XCTAssertThrowsError(
      try store.authenticate(
        RookMobileAuthentication(deviceID: deviceID, sessionToken: accepted.sessionToken),
        now: now
      )
    )
  }
}
