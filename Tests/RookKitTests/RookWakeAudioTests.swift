import CryptoKit
import XCTest

@testable import RookKit

final class RookWakeAudioTests: XCTestCase {
  func testParsesLocalWakeEventWithConfidence() {
    XCTAssertEqual(
      RookWakeEvent(line: "WAKE\tRook\t120\t32120\t0.81234"),
      RookWakeEvent(
        phrase: "Rook",
        beginSample: 120,
        endSample: 32_120,
        confidence: 0.81234
      )
    )
    XCTAssertNil(RookWakeEvent(line: "READY"))
  }

  func testValidationManifestMustMatchCurrentModel() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let modelURL = directory.appendingPathComponent("rook.onnx")
    let validationURL = directory.appendingPathComponent("rook.validation.json")
    let model = Data("owned-rook-model".utf8)
    try model.write(to: modelURL)
    let digest = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()
    try Data(#"{"passed":true,"model_sha256":"\#(digest)"}"#.utf8).write(to: validationURL)

    XCTAssertTrue(RookWakeValidation.isCurrent(modelURL: modelURL, manifestURL: validationURL))
    XCTAssertEqual(
      RookWakeValidation.authorization(modelURL: modelURL, manifestURL: validationURL),
      .validated
    )
    try Data("changed-model".utf8).write(to: modelURL)
    XCTAssertFalse(RookWakeValidation.isCurrent(modelURL: modelURL, manifestURL: validationURL))
    XCTAssertEqual(
      RookWakeValidation.authorization(modelURL: modelURL, manifestURL: validationURL),
      .unavailable
    )
  }

  func testTrialManifestMustExplicitlyOptInAndMatchCurrentModel() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let modelURL = directory.appendingPathComponent("rook.onnx")
    let validationURL = directory.appendingPathComponent("rook.validation.json")
    let model = Data("trial-rook-model".utf8)
    try model.write(to: modelURL)
    let digest = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()

    try Data(#"{"passed":false,"model_sha256":"\#(digest)"}"#.utf8).write(to: validationURL)
    XCTAssertEqual(
      RookWakeValidation.authorization(modelURL: modelURL, manifestURL: validationURL),
      .unavailable
    )

    try Data(
      #"{"passed":false,"trial_enabled":true,"model_sha256":"\#(digest)"}"#.utf8
    ).write(to: validationURL)
    XCTAssertFalse(RookWakeValidation.isCurrent(modelURL: modelURL, manifestURL: validationURL))
    XCTAssertEqual(
      RookWakeValidation.authorization(modelURL: modelURL, manifestURL: validationURL),
      .trial
    )

    try Data("changed-model".utf8).write(to: modelURL)
    XCTAssertEqual(
      RookWakeValidation.authorization(modelURL: modelURL, manifestURL: validationURL),
      .unavailable
    )
  }

  func testPreRollRetainsOnlyNewestSamplesInOrder() {
    let buffer = RookPCM16RingBuffer(sampleRate: 1_000, durationMilliseconds: 4)
    buffer.append([1, 2, 3])
    XCTAssertEqual(buffer.snapshot(), [1, 2, 3])

    buffer.append([4, 5, 6])
    XCTAssertEqual(buffer.snapshot(), [3, 4, 5, 6])
  }

  func testAdaptiveVoiceActivityDetectsQuietVoiceAboveLearnedRoomFloor() {
    var detector = RookAdaptiveVoiceActivity()
    for _ in 0..<100 {
      _ = detector.observe(level: 0.03, capturing: false)
    }

    XCTAssertFalse(detector.observe(level: 0.04, capturing: true).isVoice)
    XCTAssertTrue(detector.observe(level: 0.07, capturing: true).isVoice)
  }

  func testAdaptiveVoiceActivityRaisesThresholdInNoisyRoom() {
    var detector = RookAdaptiveVoiceActivity(initialNoiseFloor: 0.15)
    for _ in 0..<150 {
      _ = detector.observe(level: 0.16, capturing: false)
    }

    let roomNoise = detector.observe(level: 0.18, capturing: true)
    let foreground = detector.observe(level: 0.30, capturing: true)
    XCTAssertFalse(roomNoise.isVoice)
    XCTAssertTrue(foreground.isVoice)
    XCTAssertGreaterThan(roomNoise.threshold, 0.18)
  }

  func testDedicatedWakeExtractionDoesNotRequireAppleToValidateRook() {
    XCTAssertEqual(
      RookWakeTranscript.command(
        after: "Brooke",
        current: "Brooke, open Safari",
        wakePhrase: "Rook"
      ),
      "open Safari"
    )
    XCTAssertEqual(
      RookWakeTranscript.command(
        after: "background words",
        current: "background words Brooke open Safari",
        wakePhrase: "Rook"
      ),
      "open Safari"
    )
    XCTAssertEqual(
      RookWakeTranscript.commandFollowingAcousticWake(
        in: "background words Brooke open Safari",
        wakePhrase: "Rook"
      ),
      "open Safari"
    )
    XCTAssertEqual(
      RookWakeTranscript.command(
        after: "Rook",
        current: "open Safari",
        wakePhrase: "Rook"
      ),
      "open Safari"
    )
  }
}
