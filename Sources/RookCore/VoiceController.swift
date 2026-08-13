@preconcurrency import AVFoundation
import AppKit
import Foundation
import RookKit
import Speech

enum RookVoicePhase: Equatable {
  case waiting
  case wakeDetected
  case capturing
  case sending
  case processing
  case speaking
  case paused
  case unavailable
}

@MainActor
final class VoiceController {
  private enum State {
    case idle
    case capturingWake
    case awaitingCommand
    case processing
    case speaking
    case paused
  }

  let config: RookConfig
  var onCommand: ((String) -> Void)?
  var onStatus: ((String) -> Void)?
  var onTranscript: ((String) -> Void)?
  var onAudioLevel: ((CGFloat) -> Void)?
  var onCaptureProgress: ((CGFloat) -> Void)?
  var onPhase: ((RookVoicePhase) -> Void)?
  var onPermissionsResolved: ((Bool) -> Void)?

  private let audioEngine = AVAudioEngine()
  private var analyzer: SpeechAnalyzer?
  private var transcriber: SpeechTranscriber?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
  private var analyzerTask: Task<Void, Never>?
  private var resultsTask: Task<Void, Never>?
  private var setupTask: Task<Void, Never>?
  private var followUpTimer: Timer?
  private var endpointTimer: Timer?
  private var restartWorkItem: DispatchWorkItem?
  private var state: State = .idle
  private var commandBuffer = ""
  private var lastTranscript = ""
  private var lastVoiceActivity = Date()
  private var tapInstalled = false
  private var recognitionGeneration = 0
  private(set) var listeningEnabled = true
  private let neuralSpeech: KokoroSpeechSynthesizer

  init(config: RookConfig) {
    self.config = config
    neuralSpeech = KokoroSpeechSynthesizer(config: config)
  }

  func requestPermissionsAndStart() {
    onStatus?("Requesting microphone access")
    SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
      AVCaptureDevice.requestAccess(for: .audio) { microphoneGranted in
        DispatchQueue.main.async {
          guard let self else { return }
          guard speechStatus == .authorized else {
            self.onStatus?("Speech Recognition permission required")
            self.onPhase?(.unavailable)
            self.onPermissionsResolved?(false)
            return
          }
          guard microphoneGranted else {
            self.onStatus?("Microphone permission required")
            self.onPhase?(.unavailable)
            self.onPermissionsResolved?(false)
            return
          }
          self.onPermissionsResolved?(true)
          self.startListening(state: .idle)
        }
      }
    }
  }

  func setListening(enabled: Bool) {
    listeningEnabled = enabled
    if enabled {
      startListening(state: .idle)
    } else {
      state = .paused
      stopRecognition()
      onPhase?(.paused)
      onStatus?("Paused")
    }
  }

  func beginProcessing() {
    state = .processing
    followUpTimer?.invalidate()
    followUpTimer = nil
    endpointTimer?.invalidate()
    endpointTimer = nil
    stopRecognition()
    onCaptureProgress?(1)
    onPhase?(.processing)
    onStatus?("Rook is answering")
  }

  func promptForCommand() {
    guard listeningEnabled else {
      onStatus?("Paused — resume listening first")
      return
    }
    listenForCommand()
  }

  func speak(_ text: String, completion: (() -> Void)? = nil) {
    let safeText = String(text.prefix(420)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !safeText.isEmpty else {
      completion?()
      resumeIdle()
      return
    }
    state = .speaking
    stopRecognition()
    onPhase?(.speaking)
    onStatus?("Rook is speaking")

    if config.speechEngine == "kokoro" {
      neuralSpeech.speak(
        safeText,
        voice: config.neuralVoice,
        speed: config.neuralVoiceSpeed
      ) { @MainActor [weak self] succeeded in
        Task { @MainActor in
          guard let self else { return }
          if succeeded {
            completion?()
            self.resumeIdle()
          } else {
            self.onStatus?("Neural voice unavailable — using \(self.config.voice)")
            self.speakWithSystemVoice(safeText, completion: completion)
          }
        }
      }
      return
    }

    speakWithSystemVoice(safeText, completion: completion)
  }

  private func speakWithSystemVoice(_ text: String, completion: (() -> Void)?) {
    DispatchQueue.global(qos: .userInitiated).async { [config] in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
      process.arguments = ["-v", config.voice, "-r", String(config.voiceRate), text]
      try? process.run()
      process.waitUntilExit()
      DispatchQueue.main.async { [weak self] in
        completion?()
        self?.resumeIdle()
      }
    }
  }

  func listenForCommand() {
    guard listeningEnabled else { return }
    commandBuffer = ""
    lastTranscript = ""
    state = .awaitingCommand
    onCaptureProgress?(0)
    onPhase?(.wakeDetected)
    onStatus?("Listening for command")

    if !audioEngine.isRunning {
      startListening(state: .awaitingCommand)
    }
    armFollowUpWindow()
  }

  func submitTextCommand(_ command: String) {
    let cleaned = WakePhrase.clean(command)
    guard !cleaned.isEmpty else { return }
    onPhase?(.sending)
    beginProcessing()
    onCommand?(cleaned)
  }

  private func startListening(state newState: State) {
    guard listeningEnabled else { return }
    stopRecognition()
    state = newState
    commandBuffer = ""
    lastTranscript = ""
    onCaptureProgress?(0)
    if newState != .awaitingCommand {
      followUpTimer?.invalidate()
      followUpTimer = nil
    }

    switch newState {
    case .idle:
      onPhase?(.waiting)
      onStatus?("Just say “\(config.wakePhrase)”")
    case .awaitingCommand:
      onPhase?(.wakeDetected)
      onStatus?("Listening for command")
    default:
      break
    }

    recognitionGeneration += 1
    let generation = recognitionGeneration
    setupTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.startModernRecognition(generation: generation)
      } catch {
        guard generation == self.recognitionGeneration, self.listeningEnabled else { return }
        self.onPhase?(.unavailable)
        self.onStatus?("Local speech model unavailable")
        self.scheduleRestart(preserving: newState)
      }
    }
  }

  private func startModernRecognition(generation: Int) async throws {
    guard SpeechTranscriber.isAvailable else {
      throw VoiceRecognitionError.transcriberUnavailable
    }
    let requestedLocale = Locale(identifier: config.language)
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
      throw VoiceRecognitionError.localeUnavailable(config.language)
    }
    _ = try await AssetInventory.reserve(locale: locale)
    guard generation == recognitionGeneration, listeningEnabled else { return }

    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let naturalFormat = audioEngine.inputNode.outputFormat(forBus: 0)
    guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
      throw VoiceRecognitionError.audioFormatUnavailable
    }
    let analyzerFormat =
      await SpeechAnalyzer.bestAvailableAudioFormat(
        compatibleWith: [transcriber],
        considering: naturalFormat
      ) ?? naturalFormat
    try await analyzer.prepareToAnalyze(in: analyzerFormat)
    guard generation == recognitionGeneration, listeningEnabled else {
      await analyzer.cancelAndFinishNow()
      return
    }

    guard let converter = AVAudioConverter(from: naturalFormat, to: analyzerFormat) else {
      throw VoiceRecognitionError.audioConversionUnavailable
    }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    self.transcriber = transcriber
    self.analyzer = analyzer
    self.inputContinuation = continuation

    resultsTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.consumeResults(from: transcriber, generation: generation)
    }
    analyzerTask = Task { [weak self] in
      do {
        try await analyzer.start(inputSequence: stream)
      } catch {
        await MainActor.run {
          guard let self,
            generation == self.recognitionGeneration,
            self.listeningEnabled,
            self.state != .processing,
            self.state != .speaking
          else { return }
          self.scheduleRestart(preserving: self.state)
        }
      }
    }

    let inputNode = audioEngine.inputNode
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: naturalFormat) { [weak self] buffer, _ in
      guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
      continuation.yield(AnalyzerInput(buffer: converted))
      let level = Self.normalizedLevel(in: buffer)
      DispatchQueue.main.async {
        guard let self, generation == self.recognitionGeneration else { return }
        self.handleAudioLevel(level)
      }
    }
    tapInstalled = true
    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      stopRecognition()
      throw error
    }
  }

  private func consumeResults(from transcriber: SpeechTranscriber, generation: Int) async {
    var finalizedTranscript = ""
    var volatileTranscript = ""

    do {
      for try await result in transcriber.results {
        guard !Task.isCancelled, generation == recognitionGeneration else { return }
        let fragment = WakePhrase.clean(String(result.text.characters))
        guard !fragment.isEmpty else { continue }

        if result.isFinal {
          let combined = Self.joinTranscript(finalizedTranscript, fragment)
          let retain = handleTranscript(combined)
          finalizedTranscript = retain ? combined : ""
          volatileTranscript = ""
        } else {
          volatileTranscript = fragment
          _ = handleTranscript(Self.joinTranscript(finalizedTranscript, volatileTranscript))
        }
      }
    } catch {
      guard generation == recognitionGeneration,
        listeningEnabled,
        state != .processing,
        state != .speaking
      else { return }
      scheduleRestart(preserving: state)
    }
  }

  @discardableResult
  private func handleTranscript(_ transcript: String) -> Bool {
    let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned != lastTranscript else {
      return state == .capturingWake || state == .awaitingCommand
    }
    lastTranscript = cleaned

    switch state {
    case .idle:
      guard let tail = WakePhrase.commandTail(in: cleaned, phrase: config.wakePhrase) else {
        return false
      }
      state = .capturingWake
      commandBuffer = tail
      onCaptureProgress?(0)
      if tail.isEmpty {
        onPhase?(.wakeDetected)
        onStatus?("Rook heard you — keep talking")
        armFollowUpWindow()
      } else {
        onTranscript?(tail)
        onPhase?(.capturing)
        onStatus?("Listening — send when the ring completes")
        followUpTimer?.invalidate()
        followUpTimer = nil
        armEndpointing()
      }
    case .capturingWake:
      if let tail = WakePhrase.commandTail(in: cleaned, phrase: config.wakePhrase) {
        commandBuffer = tail
        if !tail.isEmpty {
          onTranscript?(tail)
          onPhase?(.capturing)
          onStatus?("Listening — send when the ring completes")
          followUpTimer?.invalidate()
          followUpTimer = nil
          armEndpointing()
        }
      }
    case .awaitingCommand:
      commandBuffer = WakePhrase.clean(cleaned)
      if !commandBuffer.isEmpty {
        onTranscript?(commandBuffer)
        onPhase?(.capturing)
        onStatus?("Listening — send when the ring completes")
        followUpTimer?.invalidate()
        followUpTimer = nil
        armEndpointing()
      }
    case .processing, .speaking, .paused:
      break
    }

    return state == .capturingWake || state == .awaitingCommand
  }

  private func handleAudioLevel(_ level: CGFloat) {
    onAudioLevel?(level)
    guard (state == .capturingWake || state == .awaitingCommand),
      !WakePhrase.clean(commandBuffer).isEmpty,
      level > 0.12
    else { return }
    lastVoiceActivity = Date()
    onCaptureProgress?(0)
  }

  private func armEndpointing() {
    lastVoiceActivity = Date()
    onCaptureProgress?(0)
    guard endpointTimer == nil else { return }
    endpointTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
      Task { @MainActor [weak self] in
        guard let self else {
          timer.invalidate()
          return
        }
        let elapsed = Date().timeIntervalSince(self.lastVoiceActivity)
        let progress = min(max(elapsed / self.config.silenceSeconds, 0), 1)
        self.onCaptureProgress?(CGFloat(progress))
        if progress >= 1 {
          timer.invalidate()
          self.endpointTimer = nil
          self.finishCapture()
        }
      }
    }
  }

  private func armFollowUpWindow() {
    followUpTimer?.invalidate()
    followUpTimer = Timer.scheduledTimer(withTimeInterval: config.followUpWindowSeconds, repeats: false) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if WakePhrase.clean(self.commandBuffer).isEmpty {
          self.startListening(state: .idle)
        }
      }
    }
  }

  private func finishCapture() {
    endpointTimer?.invalidate()
    endpointTimer = nil
    followUpTimer?.invalidate()
    followUpTimer = nil
    let command = WakePhrase.clean(commandBuffer)
    guard !command.isEmpty else {
      startListening(state: .idle)
      return
    }
    onCaptureProgress?(1)
    onPhase?(.sending)
    onStatus?("Got it — sending to Rook")
    beginProcessing()
    onCommand?(command)
  }

  private func resumeIdle() {
    guard listeningEnabled else {
      state = .paused
      onPhase?(.paused)
      onStatus?("Paused")
      return
    }
    startListening(state: .idle)
  }

  private func stopRecognition() {
    recognitionGeneration += 1
    setupTask?.cancel()
    setupTask = nil
    restartWorkItem?.cancel()
    restartWorkItem = nil
    endpointTimer?.invalidate()
    endpointTimer = nil
    resultsTask?.cancel()
    resultsTask = nil
    analyzerTask?.cancel()
    analyzerTask = nil
    inputContinuation?.finish()
    inputContinuation = nil
    if audioEngine.isRunning { audioEngine.stop() }
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    let analyzer = self.analyzer
    self.analyzer = nil
    self.transcriber = nil
    if let analyzer {
      Task { await analyzer.cancelAndFinishNow() }
    }
  }

  private func scheduleRestart(preserving stateToRestore: State = .idle) {
    guard listeningEnabled else { return }
    restartWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.startListening(state: stateToRestore)
    }
    restartWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
  }

  private static func convert(
    _ buffer: AVAudioPCMBuffer,
    using converter: AVAudioConverter,
    to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * ratio) + 16))
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
      if supplied {
        outStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
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
    guard samples > 0 else { return 0.03 }
    let rms = sqrt(sum / Float(samples))
    let decibels = 20 * log10(max(rms, 0.000_001))
    return CGFloat(max(0.03, min(1, (decibels + 58) / 58)))
  }

  private static func joinTranscript(_ leading: String, _ trailing: String) -> String {
    let first = WakePhrase.clean(leading)
    let second = WakePhrase.clean(trailing)
    if first.isEmpty { return second }
    if second.isEmpty { return first }
    return "\(first) \(second)"
  }
}

private enum VoiceRecognitionError: LocalizedError {
  case transcriberUnavailable
  case localeUnavailable(String)
  case audioFormatUnavailable
  case audioConversionUnavailable

  var errorDescription: String? {
    switch self {
    case .transcriberUnavailable:
      return "The macOS 26 speech transcriber is unavailable"
    case .localeUnavailable(let locale):
      return "The local speech model does not support \(locale)"
    case .audioFormatUnavailable:
      return "The microphone returned an invalid audio format"
    case .audioConversionUnavailable:
      return "Rook could not convert microphone audio for transcription"
    }
  }
}
