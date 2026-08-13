@preconcurrency import AVFoundation
import Foundation
import Speech

@MainActor
final class RookMobileVoiceController: ObservableObject {
  @Published private(set) var isListening = false
  @Published private(set) var level: CGFloat = 0.03
  @Published var transcript = ""
  @Published private(set) var errorMessage: String?

  private let audioEngine = AVAudioEngine()
  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
  private var analyzerTask: Task<Void, Never>?
  private var resultsTask: Task<Void, Never>?
  private var tapInstalled = false

  func toggle() {
    if isListening {
      stop()
    } else {
      Task { await start() }
    }
  }

  func start() async {
    guard !isListening else { return }
    errorMessage = nil

    guard await requestPermissions() else {
      errorMessage = "Microphone and Speech Recognition access are required."
      return
    }

    do {
      try configureAudioSession()
      try await startRecognition()
      isListening = true
    } catch {
      stop()
      errorMessage = error.localizedDescription
    }
  }

  func stop() {
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioEngine.stop()
    inputContinuation?.finish()
    inputContinuation = nil
    analyzerTask?.cancel()
    analyzerTask = nil
    resultsTask?.cancel()
    resultsTask = nil
    let analyzer = self.analyzer
    self.analyzer = nil
    transcriber = nil
    isListening = false
    level = 0.03

    Task {
      await analyzer?.cancelAndFinishNow()
      try? AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
    }
  }

  private func requestPermissions() async -> Bool {
    let speech = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { status in
        continuation.resume(returning: status == .authorized)
      }
    }
    guard speech else { return false }

    return await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
    try session.setActive(true)
  }

  private func startRecognition() async throws {
    guard SpeechTranscriber.isAvailable else {
      throw RookMobileVoiceError.transcriberUnavailable
    }
    let requestedLocale = Locale(identifier: "en-US")
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      throw RookMobileVoiceError.localeUnavailable
    }
    _ = try await AssetInventory.reserve(locale: locale)

    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let naturalFormat = audioEngine.inputNode.outputFormat(forBus: 0)
    guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
      throw RookMobileVoiceError.audioUnavailable
    }
    let analyzerFormat =
      await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber],
        considering: naturalFormat
      ) ?? naturalFormat
    try await analyzer.prepareToAnalyze(in: analyzerFormat)
    guard let converter = AVAudioConverter(from: naturalFormat, to: analyzerFormat) else {
      throw RookMobileVoiceError.audioUnavailable
    }

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    self.transcriber = transcriber
    self.analyzer = analyzer
    inputContinuation = continuation
    transcript = ""

    resultsTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.consumeResults(from: transcriber)
    }
    analyzerTask = Task {
      try? await analyzer.start(inputSequence: stream)
    }

    audioEngine.inputNode.installTap(
      onBus: 0,
      bufferSize: 1_024,
      format: naturalFormat
    ) { [weak self] buffer, _ in
      guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else {
        return
      }
      continuation.yield(AnalyzerInput(buffer: converted))
      let level = Self.normalizedLevel(in: buffer)
      Task { @MainActor [weak self] in self?.level = level }
    }
    tapInstalled = true
    audioEngine.prepare()
    try audioEngine.start()
  }

  private func consumeResults(from transcriber: SpeechTranscriber) async {
    var finalized = ""
    do {
      for try await result in transcriber.results {
        guard !Task.isCancelled else { return }
        let fragment = String(result.text.characters)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fragment.isEmpty else { continue }
        if result.isFinal {
          finalized = Self.join(finalized, fragment)
          transcript = finalized
        } else {
          transcript = Self.join(finalized, fragment)
        }
      }
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  private static func convert(
    _ buffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 16))
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return nil
    }
    let supply = RookMobileBufferSupply()
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      if supply.supplied {
        outStatus.pointee = .noDataNow
        return nil
      }
      supply.supplied = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
    return output
  }

  private static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> CGFloat {
    guard let channel = buffer.floatChannelData?[0] else { return 0.03 }
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0 else { return 0.03 }
    var sum: Float = 0
    var samples = 0
    for index in stride(from: 0, to: frameCount, by: 4) {
      let value = channel[index]
      sum += value * value
      samples += 1
    }
    let rms = sqrt(sum / Float(max(samples, 1)))
    let decibels = 20 * log10(max(rms, 0.000_001))
    return CGFloat(max(0.03, min(1, (decibels + 58) / 58)))
  }

  private static func join(_ leading: String, _ trailing: String) -> String {
    if leading.isEmpty { return trailing }
    if trailing.isEmpty { return leading }
    return "\(leading) \(trailing)"
  }
}

private final class RookMobileBufferSupply: @unchecked Sendable {
  var supplied = false
}

private enum RookMobileVoiceError: LocalizedError {
  case transcriberUnavailable
  case localeUnavailable
  case audioUnavailable

  var errorDescription: String? {
    switch self {
    case .transcriberUnavailable:
      return "On-device transcription is unavailable on this iPhone."
    case .localeUnavailable:
      return "The on-device English speech model is unavailable."
    case .audioUnavailable:
      return "Rook could not read audio from the microphone."
    }
  }
}
