@preconcurrency import AVFoundation
import Foundation

private enum RecorderError: LocalizedError {
  case usage
  case invalidDuration
  case invalidAudioFormat
  case conversionFailed

  var errorDescription: String? {
    switch self {
    case .usage:
      return "usage: RookWakeRecorder <output.wav> [duration-seconds]"
    case .invalidDuration:
      return "recording duration must be between 1 second and 24 hours"
    case .invalidAudioFormat:
      return "the microphone did not provide a usable audio format"
    case .conversionFailed:
      return "microphone audio could not be converted to 16 kHz mono PCM"
    }
  }
}

private final class RecorderState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: Error?

  func fail(_ error: Error) {
    lock.lock()
    if storedError == nil { storedError = error }
    lock.unlock()
  }

  var error: Error? {
    lock.lock()
    defer { lock.unlock() }
    return storedError
  }
}

private func convert(
  _ buffer: AVAudioPCMBuffer,
  using converter: AVAudioConverter,
  to format: AVAudioFormat
) -> AVAudioPCMBuffer? {
  let ratio = format.sampleRate / buffer.format.sampleRate
  let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 8
  guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
  var consumed = false
  var conversionError: NSError?
  let status = converter.convert(to: output, error: &conversionError) { _, outputStatus in
    if consumed {
      outputStatus.pointee = .noDataNow
      return nil
    }
    consumed = true
    outputStatus.pointee = .haveData
    return buffer
  }
  guard status != .error, conversionError == nil else { return nil }
  return output
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard let outputPath = arguments.first, arguments.count <= 2 else { throw RecorderError.usage }
  let duration = arguments.count == 2 ? Double(arguments[1]) : 3.0
  guard let duration, (1...86_400).contains(duration) else { throw RecorderError.invalidDuration }

  let outputURL = URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath)
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )

  let engine = AVAudioEngine()
  let input = engine.inputNode
  let naturalFormat = input.outputFormat(forBus: 0)
  guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0,
    let targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16_000,
      channels: 1,
      interleaved: true
    ),
    let converter = AVAudioConverter(from: naturalFormat, to: targetFormat)
  else { throw RecorderError.invalidAudioFormat }

  let file = try AVAudioFile(
    forWriting: outputURL,
    settings: targetFormat.settings,
    commonFormat: .pcmFormatInt16,
    interleaved: true
  )
  let state = RecorderState()
  input.installTap(onBus: 0, bufferSize: 1_024, format: naturalFormat) { buffer, _ in
    guard let converted = convert(buffer, using: converter, to: targetFormat) else {
      state.fail(RecorderError.conversionFailed)
      return
    }
    do {
      try file.write(from: converted)
    } catch {
      state.fail(error)
    }
  }

  engine.prepare()
  try engine.start()
  FileHandle.standardOutput.write(Data("RECORDING\n".utf8))
  Thread.sleep(forTimeInterval: duration)
  engine.stop()
  input.removeTap(onBus: 0)

  if let error = state.error { throw error }
  FileHandle.standardOutput.write(Data("SAVED\t\(outputURL.path)\n".utf8))
} catch {
  FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
  exit(1)
}
