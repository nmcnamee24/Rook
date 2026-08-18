import CryptoKit
import Foundation

public struct RookWakeEvent: Equatable, Sendable {
  public let phrase: String
  public let beginSample: Int64?
  public let endSample: Int64?
  public let confidence: Double?

  public init(phrase: String, beginSample: Int64?, endSample: Int64?, confidence: Double?) {
    self.phrase = phrase
    self.beginSample = beginSample
    self.endSample = endSample
    self.confidence = confidence
  }

  public init?(line: String) {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.first == "WAKE" else { return nil }
    phrase = fields.count > 1 && !fields[1].isEmpty ? String(fields[1]) : "Rook"
    beginSample = fields.count > 2 ? Int64(fields[2]) : nil
    endSample = fields.count > 3 ? Int64(fields[3]) : nil
    confidence = fields.count > 4 ? Double(fields[4]) : nil
  }
}

public enum RookWakeModelAuthorization: String, Equatable, Sendable {
  case unavailable
  case trial
  case validated
}

public enum RookWakeValidation {
  private struct Manifest: Decodable {
    let passed: Bool
    let trialEnabled: Bool?
    let modelSHA256: String

    enum CodingKeys: String, CodingKey {
      case passed
      case trialEnabled = "trial_enabled"
      case modelSHA256 = "model_sha256"
    }
  }

  public static func isCurrent(modelURL: URL, manifestURL: URL) -> Bool {
    authorization(modelURL: modelURL, manifestURL: manifestURL) == .validated
  }

  public static func authorization(modelURL: URL, manifestURL: URL) -> RookWakeModelAuthorization {
    guard
      let manifestData = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
      let modelData = try? Data(contentsOf: modelURL)
    else { return .unavailable }

    let digest = SHA256.hash(data: modelData).map { String(format: "%02x", $0) }.joined()
    guard digest == manifest.modelSHA256.lowercased() else { return .unavailable }
    if manifest.passed { return .validated }
    if manifest.trialEnabled == true { return .trial }
    return .unavailable
  }
}

public struct RookVoiceActivitySample: Equatable, Sendable {
  public let isVoice: Bool
  public let noiseFloor: Double
  public let threshold: Double

  public init(isVoice: Bool, noiseFloor: Double, threshold: Double) {
    self.isVoice = isVoice
    self.noiseFloor = noiseFloor
    self.threshold = threshold
  }
}

/// Tracks the actual room floor instead of imposing one fixed amplitude gate.
/// The input is Rook's normalized 0...1 meter value, not raw PCM energy.
public struct RookAdaptiveVoiceActivity: Sendable {
  public private(set) var noiseFloor: Double
  private var hasBaseline: Bool

  public init(initialNoiseFloor: Double = 0.03) {
    noiseFloor = min(max(initialNoiseFloor, 0.01), 0.5)
    hasBaseline = false
  }

  public mutating func observe(level suppliedLevel: Double, capturing: Bool) -> RookVoiceActivitySample {
    let level = min(max(suppliedLevel, 0), 1)

    if !capturing {
      if !hasBaseline {
        noiseFloor = level
        hasBaseline = true
      } else {
        // Follow ordinary room drift quickly, but let short foreground sounds
        // influence the baseline only very slowly.
        let foregroundLimit = noiseFloor + max(0.04, noiseFloor * 0.75)
        let alpha = level <= foregroundLimit ? 0.035 : 0.002
        noiseFloor += (level - noiseFloor) * alpha
      }
    }

    let margin = max(0.025, noiseFloor * 0.38)
    let threshold = min(max(noiseFloor + margin, 0.045), 0.6)
    return RookVoiceActivitySample(
      isVoice: capturing && level >= threshold,
      noiseFloor: noiseFloor,
      threshold: threshold
    )
  }
}

/// A bounded, in-memory pre-roll. It never writes ambient audio to disk.
public final class RookPCM16RingBuffer: @unchecked Sendable {
  public let capacitySamples: Int

  private let lock = NSLock()
  private var samples: [Int16]
  private var writeIndex = 0
  private var sampleCount = 0

  public init(sampleRate: Int = 16_000, durationMilliseconds: Int) {
    capacitySamples = max(1, sampleRate * max(1, durationMilliseconds) / 1_000)
    samples = Array(repeating: 0, count: capacitySamples)
  }

  public func append(_ newSamples: [Int16]) {
    guard !newSamples.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }

    for sample in newSamples.suffix(capacitySamples) {
      samples[writeIndex] = sample
      writeIndex = (writeIndex + 1) % capacitySamples
      sampleCount = min(sampleCount + 1, capacitySamples)
    }
  }

  public func snapshot() -> [Int16] {
    lock.lock()
    defer { lock.unlock() }
    guard sampleCount > 0 else { return [] }

    let start = (writeIndex - sampleCount + capacitySamples) % capacitySamples
    if start + sampleCount <= capacitySamples {
      return Array(samples[start..<(start + sampleCount)])
    }
    let first = samples[start..<capacitySamples]
    let secondCount = sampleCount - first.count
    return Array(first) + Array(samples[0..<secondCount])
  }

  public func removeAll() {
    lock.lock()
    writeIndex = 0
    sampleCount = 0
    lock.unlock()
  }
}

public enum RookWakeTranscript {
  /// Extracts command text from an Apple transcript after a dedicated acoustic
  /// detector has already made the wake decision.
  public static func command(
    after anchor: String,
    current transcript: String,
    wakePhrase: String
  ) -> String {
    let current = WakePhrase.clean(transcript)
    guard !current.isEmpty else { return "" }

    if let tail = commandFollowingAcousticWake(in: current, wakePhrase: wakePhrase) {
      return tail
    }

    let baseline = WakePhrase.clean(anchor)
    guard !baseline.isEmpty else { return current }
    if current == baseline { return "" }

    if current.hasPrefix(baseline) {
      let boundary = current.index(current.startIndex, offsetBy: baseline.count)
      let delta = WakePhrase.clean(String(current[boundary...]))
      return WakePhrase.commandTail(in: delta, phrase: wakePhrase) ?? delta
    }

    // Finalized and volatile transcriptions can disagree on punctuation or one
    // word. Preserve only the words that appeared after their common prefix.
    let baselineWords = words(in: baseline)
    let currentWords = words(in: current)
    var common = 0
    while common < min(baselineWords.count, currentWords.count),
      baselineWords[common] == currentWords[common]
    {
      common += 1
    }
    guard common > 0, common < currentWords.count else { return current }
    return currentWords[common...].joined(separator: " ")
  }

  /// Finds the transcript tail after the last wake spelling. This is safe only
  /// after the acoustic detector has already validated the event; unlike
  /// `WakePhrase`, it deliberately accepts a wake word after background text.
  public static func commandFollowingAcousticWake(
    in transcript: String,
    wakePhrase: String
  ) -> String? {
    let configuredWords = words(in: wakePhrase)
    let pattern: String
    if configuredWords == ["rook"] {
      pattern = "(?i)\\b(?:rook|brooke|brook)\\b"
    } else {
      guard !configuredWords.isEmpty else { return nil }
      pattern =
        "(?i)\\b"
        + configuredWords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[\\s,.;:!?\\-]+")
        + "\\b"
    }
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let fullRange = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
    guard let match = regex.matches(in: transcript, range: fullRange).last,
      let range = Range(match.range, in: transcript)
    else { return nil }
    return WakePhrase.clean(String(transcript[range.upperBound...]))
  }

  private static func words(in value: String) -> [String] {
    value.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map(String.init)
  }
}
