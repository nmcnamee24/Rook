import Foundation
import LiveKitWakeWord
import RookKit

private enum WakeToolError: LocalizedError {
  case usage
  case invalidThreshold(String)
  case modelUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .usage:
      return "usage: RookWakeTool [stream|probe] <rook.onnx> [threshold-percent]"
    case .invalidThreshold(let value):
      return "wake threshold must be between 1 and 99 percent (received \(value))"
    case .modelUnavailable(let path):
      return "wake classifier is missing at \(path)"
    }
  }
}

private struct WakeToolOptions {
  enum Mode {
    case stream
    case probe
  }

  let mode: Mode
  let modelURL: URL
  let threshold: Float

  static func parse(_ arguments: [String]) throws -> WakeToolOptions {
    var values = arguments
    let mode: Mode
    if values.first == "probe" {
      mode = .probe
      values.removeFirst()
    } else if values.first == "stream" {
      mode = .stream
      values.removeFirst()
    } else {
      mode = .stream
    }

    guard let modelPath = values.first, values.count <= 2 else {
      throw WakeToolError.usage
    }
    let expandedPath = NSString(string: modelPath).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: expandedPath) else {
      throw WakeToolError.modelUnavailable(expandedPath)
    }

    let suppliedThreshold = values.count == 2 ? values[1] : "68"
    guard let thresholdPercent = Float(suppliedThreshold), (1...99).contains(thresholdPercent) else {
      throw WakeToolError.invalidThreshold(suppliedThreshold)
    }
    return WakeToolOptions(
      mode: mode,
      modelURL: URL(fileURLWithPath: expandedPath),
      threshold: thresholdPercent / 100
    )
  }
}

private final class WakeStream {
  private static let sampleRate = 16_000
  private static let windowSamples = sampleRate * 2
  private static let inferenceStrideSamples = 1_280

  private let model: WakeWordModel
  private let modelName: String
  private let threshold: Float
  private let releaseThreshold: Float
  private let audio = RookPCM16RingBuffer(
    sampleRate: sampleRate,
    durationMilliseconds: 2_000
  )

  private var totalSamples: Int64 = 0
  private var samplesSinceInference = 0
  private var armed = true
  private var belowReleaseCount = 0

  init(modelURL: URL, threshold: Float) throws {
    model = try WakeWordModel(
      models: [modelURL],
      sampleRate: UInt32(Self.sampleRate),
      executionProvider: .coreML
    )
    modelName = modelURL.deletingPathExtension().lastPathComponent
    self.threshold = threshold
    releaseThreshold = max(0.05, threshold * 0.55)
  }

  func append(_ samples: [Int16], forceInference: Bool = false) throws {
    guard !samples.isEmpty else { return }
    audio.append(samples)
    totalSamples += Int64(samples.count)
    samplesSinceInference += samples.count

    guard audio.snapshot().count == Self.windowSamples else { return }
    guard forceInference || samplesSinceInference >= Self.inferenceStrideSamples else { return }
    samplesSinceInference %= Self.inferenceStrideSamples
    try infer()
  }

  private func infer() throws {
    let window = audio.snapshot()
    let scores = try model.predict(window)
    let score = scores[modelName] ?? scores.values.max() ?? 0

    if armed, score >= threshold {
      armed = false
      belowReleaseCount = 0
      let begin = max(0, totalSamples - Int64(Self.windowSamples))
      emit("WAKE\tRook\t\(begin)\t\(totalSamples)\t\(String(format: "%.5f", score))")
      return
    }

    guard !armed else { return }
    if score < releaseThreshold {
      belowReleaseCount += 1
      if belowReleaseCount >= 5 {
        armed = true
        belowReleaseCount = 0
      }
    } else {
      belowReleaseCount = 0
    }
  }
}

private func emit(_ line: String, to handle: FileHandle = .standardOutput) {
  handle.write(Data((line + "\n").utf8))
}

private func pcm16(from data: Data, pendingByte: inout UInt8?) -> [Int16] {
  var bytes = [UInt8]()
  bytes.reserveCapacity(data.count + (pendingByte == nil ? 0 : 1))
  if let pendingByte {
    bytes.append(pendingByte)
  }
  bytes.append(contentsOf: data)

  let evenCount = bytes.count - (bytes.count % 2)
  pendingByte = evenCount < bytes.count ? bytes.last : nil
  guard evenCount > 0 else { return [] }

  var samples = [Int16]()
  samples.reserveCapacity(evenCount / 2)
  var index = 0
  while index < evenCount {
    let value = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    samples.append(Int16(bitPattern: value))
    index += 2
  }
  return samples
}

do {
  let options = try WakeToolOptions.parse(Array(CommandLine.arguments.dropFirst()))
  let stream = try WakeStream(modelURL: options.modelURL, threshold: options.threshold)

  if options.mode == .probe {
    emit("READY")
    exit(0)
  }

  emit("READY")
  var pendingByte: UInt8?
  while true {
    let data = FileHandle.standardInput.readData(ofLength: 8_192)
    if data.isEmpty { break }
    let samples = pcm16(from: data, pendingByte: &pendingByte)
    try stream.append(samples)
  }
} catch {
  emit(error.localizedDescription, to: .standardError)
  exit(1)
}
