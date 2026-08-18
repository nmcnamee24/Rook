@preconcurrency import AVFoundation
import AppKit
import FluidAudio
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

enum RookWakeEngineState: Equatable {
  case apple
  case personalizedStarting
  case personalizedTrial
  case personalizedReady
  case appleFallback(String)
  case unavailable(String)
}

@MainActor
final class VoiceController {
  static let fluidTranscriptionTrialPreferenceKey =
    "com.noah.rook.fluid-transcription-trial-enabled"

  private enum State {
    case idle
    case capturingWake
    case awaitingCommand
    case processing
    case speaking
    case paused
  }

  let config: RookConfig
  var onCommand: ((String, UUID, RookTaskInputSource) -> Void)?
  var onStableStreamingIntent: ((RookStreamingIntentCandidate, UUID) -> Void)?
  var onTraceSignal: ((RookTaskTraceSignal) -> Void)?
  var onStatus: ((String) -> Void)?
  var onTranscript: ((String) -> Void)?
  var onAudioLevel: ((CGFloat) -> Void)?
  var onCaptureProgress: ((CGFloat) -> Void)?
  var onPhase: ((RookVoicePhase) -> Void)?
  var onWakeEngineState: ((RookWakeEngineState) -> Void)?
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
  private var streamingIntentTimer: Timer?
  private var restartWorkItem: DispatchWorkItem?
  private var wakeRestartWorkItem: DispatchWorkItem?
  private var state: State = .idle
  private var commandBuffer = ""
  private var lastTranscript = ""
  private var wakeTranscriptAnchor = ""
  private var lastVoiceActivity = Date()
  private var tapInstalled = false
  private var recognitionGeneration = 0
  private var activeRequestID: UUID?
  private var didTraceFirstTranscript = false
  private var dedicatedWakeActive = false
  private var wakeDetectorStartAttempted = false
  private var wakeDetectorReady = false
  private var voiceActivity = RookAdaptiveVoiceActivity()
  private var streamingIntentTracker = RookStreamingIntentTracker()
  private(set) var listeningEnabled = true
  private let neuralSpeech: KokoroSpeechSynthesizer
  private let wakeDetector: LocalWakeWordDetector?
  private let wakePreRoll: RookPCM16RingBuffer
  private let commandAudioCapture = RookCommandAudioCapture()
  private let fluidTranscriptionTrial = RookFluidTranscriptionTrial()
  private var fluidPreparationTask: Task<Void, Never>?
  private(set) var fluidTranscriptionTrialEnabled: Bool

  init(config: RookConfig) {
    self.config = config
    fluidTranscriptionTrialEnabled =
      UserDefaults.standard.object(
        forKey: Self.fluidTranscriptionTrialPreferenceKey
      ) as? Bool ?? true
    neuralSpeech = KokoroSpeechSynthesizer(config: config)
    wakePreRoll = RookPCM16RingBuffer(durationMilliseconds: config.wakePreRollMilliseconds)
    if config.wakeEngine == "livekit" {
      wakeDetector = LocalWakeWordDetector(
        helperURL: config.wakeHelperURL,
        modelURL: config.wakeModelURL,
        validationURL: config.wakeValidationURL,
        thresholdPercent: config.wakeOperatingPoint
      )
    } else {
      wakeDetector = nil
    }
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
          self.prepareFluidTranscriptionTrialIfNeeded()
          self.startWakeDetectorIfNeeded()
          self.startListening(state: .idle)
        }
      }
    }
  }

  func setListening(enabled: Bool) {
    listeningEnabled = enabled
    if enabled {
      startWakeDetectorIfNeeded()
      startListening(state: .idle)
    } else {
      state = .paused
      stopRecognition()
      wakeRestartWorkItem?.cancel()
      wakeRestartWorkItem = nil
      wakeDetector?.stop()
      wakeDetectorStartAttempted = false
      wakeDetectorReady = false
      onPhase?(.paused)
      onStatus?("Paused")
    }
  }

  func setFluidTranscriptionTrial(enabled: Bool) {
    fluidTranscriptionTrialEnabled = enabled
    UserDefaults.standard.set(
      enabled,
      forKey: Self.fluidTranscriptionTrialPreferenceKey
    )
    if enabled {
      prepareFluidTranscriptionTrialIfNeeded()
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
    let requestID = beginRequestTrace()
    trace(
      requestID: requestID,
      stage: .wakeDetected,
      status: .succeeded,
      detail: "Listening started from an explicit control.",
      metadata: ["trigger": "manual"]
    )
    commandBuffer = ""
    lastTranscript = ""
    streamingIntentTracker.reset()
    state = .awaitingCommand
    onCaptureProgress?(0)
    onPhase?(.wakeDetected)
    onStatus?("Listening for command")

    if !audioEngine.isRunning {
      startListening(state: .awaitingCommand)
    } else {
      commandAudioCapture.begin()
    }
    armFollowUpWindow()
  }

  func submitTextCommand(_ command: String) {
    let cleaned = WakePhrase.clean(command)
    guard !cleaned.isEmpty else { return }
    let requestID = UUID()
    trace(
      requestID: requestID,
      source: .typed,
      stage: .requestReceived,
      status: .succeeded,
      detail: "Typed command received."
    )
    trace(
      requestID: requestID,
      source: .typed,
      stage: .finalTranscript,
      status: .succeeded,
      detail: "Typed command finalized."
    )
    onPhase?(.sending)
    beginProcessing()
    onCommand?(cleaned, requestID, .typed)
  }

  private func startListening(state newState: State) {
    guard listeningEnabled else { return }
    startWakeDetectorIfNeeded()
    stopRecognition()
    state = newState
    commandBuffer = ""
    lastTranscript = ""
    wakeTranscriptAnchor = ""
    dedicatedWakeActive = false
    if newState == .awaitingCommand {
      commandAudioCapture.begin()
    } else {
      commandAudioCapture.reset()
    }
    onCaptureProgress?(0)
    if newState != .awaitingCommand {
      followUpTimer?.invalidate()
      followUpTimer = nil
    }

    switch newState {
    case .idle:
      activeRequestID = nil
      didTraceFirstTranscript = false
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
    guard
      let wakeFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
      ),
      let wakeConverter = AVAudioConverter(from: naturalFormat, to: wakeFormat)
    else {
      throw VoiceRecognitionError.wakeAudioConversionUnavailable
    }
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
    let wakePreRoll = self.wakePreRoll
    let wakeDetector = self.wakeDetector
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: naturalFormat) { [weak self] buffer, _ in
      guard let converted = Self.convert(buffer, using: converter, to: analyzerFormat) else { return }
      continuation.yield(AnalyzerInput(buffer: converted))
      if let wakeBuffer = Self.convert(buffer, using: wakeConverter, to: wakeFormat),
        let wakeSamples = Self.pcm16Samples(in: wakeBuffer)
      {
        wakePreRoll.append(wakeSamples)
        wakeDetector?.write(samples: wakeSamples)
        self?.commandAudioCapture.append(wakeSamples)
      }
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
      if wakeDetectorReady { return false }
      guard config.wakeFallbackToApple else { return false }
      guard let tail = WakePhrase.commandTail(in: cleaned, phrase: config.wakePhrase) else {
        return false
      }
      let requestID = beginRequestTrace()
      commandAudioCapture.begin(seed: wakePreRoll.snapshot())
      trace(
        requestID: requestID,
        stage: .wakeDetected,
        status: .succeeded,
        detail: "Leading wake phrase recognized.",
        metadata: ["trigger": "wake_phrase"]
      )
      state = .capturingWake
      commandBuffer = tail
      onCaptureProgress?(0)
      if tail.isEmpty {
        onPhase?(.wakeDetected)
        onStatus?("Rook heard you — keep talking")
        armFollowUpWindow()
      } else {
        traceFirstTranscriptIfNeeded(requestID: requestID)
        onTranscript?(tail)
        onPhase?(.capturing)
        onStatus?("Listening — send when the ring completes")
        followUpTimer?.invalidate()
        followUpTimer = nil
        armEndpointing()
      }
    case .capturingWake:
      if dedicatedWakeActive {
        let tail = RookWakeTranscript.command(
          after: wakeTranscriptAnchor,
          current: cleaned,
          wakePhrase: config.wakePhrase
        )
        commandBuffer = tail
        if !tail.isEmpty {
          traceFirstTranscriptIfNeeded(requestID: activeRequestID ?? beginRequestTrace())
          onTranscript?(tail)
          onPhase?(.capturing)
          onStatus?("Listening — send when the ring completes")
          followUpTimer?.invalidate()
          followUpTimer = nil
          armEndpointing()
        }
      } else if let tail = WakePhrase.commandTail(in: cleaned, phrase: config.wakePhrase) {
        commandBuffer = tail
        if !tail.isEmpty {
          traceFirstTranscriptIfNeeded(requestID: activeRequestID ?? beginRequestTrace())
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
        traceFirstTranscriptIfNeeded(requestID: activeRequestID ?? beginRequestTrace())
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

    if state == .capturingWake || state == .awaitingCommand {
      observeStreamingIntent(commandBuffer)
    }

    return state == .capturingWake || state == .awaitingCommand
  }

  private func observeStreamingIntent(_ command: String) {
    let previous = streamingIntentTracker.candidate
    streamingIntentTracker.observe(command)
    guard streamingIntentTracker.candidate != previous else { return }
    streamingIntentTimer?.invalidate()
    streamingIntentTimer = nil
    guard streamingIntentTracker.candidate != nil else { return }
    scheduleStreamingIntentCheck(
      after: streamingIntentTracker.stabilityMilliseconds / 1_000
    )
  }

  private func scheduleStreamingIntentCheck(after delay: TimeInterval) {
    streamingIntentTimer?.invalidate()
    streamingIntentTimer = Timer.scheduledTimer(
      withTimeInterval: max(0.05, delay),
      repeats: false
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.prepareStableStreamingIntentIfSafe() }
    }
  }

  private func prepareStableStreamingIntentIfSafe() {
    guard state == .capturingWake || state == .awaitingCommand else { return }
    let minimumQuietSeconds = 0.25
    let quietSeconds = Date().timeIntervalSince(lastVoiceActivity)
    guard quietSeconds >= minimumQuietSeconds else {
      scheduleStreamingIntentCheck(after: minimumQuietSeconds - quietSeconds)
      return
    }
    guard let candidate = streamingIntentTracker.ready() else { return }
    let requestID = activeRequestID ?? beginRequestTrace()
    trace(
      requestID: requestID,
      stage: .stableIntent,
      status: .succeeded,
      detail: "A side-effect-free streaming intent remained stable and may be prepared.",
      metadata: [
        "adapter": candidate.adapter,
        "capability": candidate.capability.rawValue,
        "execution": "private_prewarm",
      ]
    )
    onStableStreamingIntent?(candidate, requestID)
  }

  private func handleAudioLevel(_ level: CGFloat) {
    onAudioLevel?(level)
    let isCapturing = state == .capturingWake || state == .awaitingCommand
    let activity = voiceActivity.observe(level: Double(level), capturing: isCapturing)
    guard (state == .capturingWake || state == .awaitingCommand),
      !WakePhrase.clean(commandBuffer).isEmpty,
      activity.isVoice
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
    streamingIntentTimer?.invalidate()
    streamingIntentTimer = nil
    streamingIntentTracker.reset()
    followUpTimer?.invalidate()
    followUpTimer = nil
    let command = WakePhrase.clean(commandBuffer)
    let capturedAudio = commandAudioCapture.finish()
    guard !command.isEmpty else {
      startListening(state: .idle)
      return
    }
    onCaptureProgress?(1)
    onPhase?(.sending)
    let requestID = activeRequestID ?? beginRequestTrace()
    beginProcessing()
    activeRequestID = nil
    didTraceFirstTranscript = false
    dedicatedWakeActive = false
    wakeTranscriptAnchor = ""
    if fluidTranscriptionTrialEnabled {
      onStatus?("Improving transcript locally…")
      Task { [weak self] in
        guard let self else { return }
        do {
          let candidate = try await self.fluidTranscriptionTrial.transcribeIfReady(
            pcm16Samples: capturedAudio
          )
          self.deliverCapturedCommand(
            appleCommand: command,
            fluidCandidate: candidate,
            requestID: requestID,
            fallbackReason: candidate == nil ? "model_preparing" : nil
          )
        } catch {
          self.deliverCapturedCommand(
            appleCommand: command,
            fluidCandidate: nil,
            requestID: requestID,
            fallbackReason: "trial_failed"
          )
        }
      }
    } else {
      deliverCapturedCommand(
        appleCommand: command,
        fluidCandidate: nil,
        requestID: requestID,
        fallbackReason: "trial_disabled"
      )
    }
  }

  private func prepareFluidTranscriptionTrialIfNeeded() {
    guard fluidTranscriptionTrialEnabled, fluidPreparationTask == nil else { return }
    fluidPreparationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await self.fluidTranscriptionTrial.prepare()
        guard !Task.isCancelled else { return }
        self.fluidPreparationTask = nil
        if self.state == .idle {
          self.onStatus?("FluidAudio trial ready — just say “\(self.config.wakePhrase)”")
        }
      } catch {
        guard !Task.isCancelled else { return }
        self.fluidPreparationTask = nil
        if self.state == .idle {
          self.onStatus?("Apple transcription active — FluidAudio trial unavailable")
        }
      }
    }
  }

  private func deliverCapturedCommand(
    appleCommand: String,
    fluidCandidate: String?,
    requestID: UUID,
    fallbackReason: String?
  ) {
    let fluidCommand = fluidCandidate.flatMap { candidate -> String? in
      let cleaned = WakePhrase.clean(candidate)
      guard !cleaned.isEmpty else { return nil }
      if let tail = WakePhrase.commandTail(in: cleaned, phrase: config.wakePhrase),
        !tail.isEmpty
      {
        return tail
      }
      return cleaned
    }
    let command = fluidCommand ?? appleCommand
    var metadata = [
      "engine": fluidCommand == nil ? "apple_speech" : "fluidaudio_v2_trial",
      "on_device": "true",
    ]
    if let fallbackReason, fluidCommand == nil {
      metadata["fallback"] = fallbackReason
    }
    trace(
      requestID: requestID,
      stage: .finalTranscript,
      status: .succeeded,
      detail: fluidCommand == nil
        ? "Command transcript finalized with Apple fallback."
        : "Command transcript finalized with the on-device FluidAudio trial.",
      metadata: metadata
    )
    if fluidCommand != nil {
      onTranscript?(command)
    }
    onStatus?("Got it — sending to Rook")
    onCommand?(command, requestID, .voice)
  }

  private func startWakeDetectorIfNeeded() {
    guard listeningEnabled else { return }
    guard let wakeDetector else {
      onWakeEngineState?(.apple)
      return
    }
    guard !wakeDetectorStartAttempted else { return }
    wakeDetectorStartAttempted = true
    onWakeEngineState?(.personalizedStarting)
    wakeDetector.start(
      onReady: { [weak self] in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.wakeDetectorReady = true
          let authorization = RookWakeValidation.authorization(
            modelURL: self.config.wakeModelURL,
            manifestURL: self.config.wakeValidationURL
          )
          self.onWakeEngineState?(
            authorization == .trial ? .personalizedTrial : .personalizedReady
          )
        }
      },
      onWake: { [weak self] phrase, beginSample, endSample, confidence in
        Task { @MainActor [weak self] in
          self?.handleDedicatedWake(
            phrase: phrase,
            beginSample: beginSample,
            endSample: endSample,
            confidence: confidence
          )
        }
      },
      onFailure: { [weak self] reason in
        Task { @MainActor [weak self] in
          self?.handleWakeDetectorFailure(reason)
        }
      }
    )
  }

  private func handleDedicatedWake(
    phrase: String,
    beginSample: Int64?,
    endSample: Int64?,
    confidence: Double?
  ) {
    guard listeningEnabled, wakeDetectorReady, state == .idle else { return }
    let requestID = beginRequestTrace()
    let preRoll = wakePreRoll.snapshot()
    commandAudioCapture.begin(seed: preRoll)
    dedicatedWakeActive = true
    wakeTranscriptAnchor = lastTranscript
    commandBuffer =
      RookWakeTranscript.commandFollowingAcousticWake(
        in: lastTranscript,
        wakePhrase: config.wakePhrase
      ) ?? ""
    state = .capturingWake
    onCaptureProgress?(0)

    var metadata = [
      "trigger": "livekit_rook_model",
      "phrase": phrase,
      "pre_roll_samples": String(preRoll.count),
    ]
    if let beginSample { metadata["begin_sample"] = String(beginSample) }
    if let endSample { metadata["end_sample"] = String(endSample) }
    if let confidence { metadata["confidence"] = String(format: "%.5f", confidence) }
    trace(
      requestID: requestID,
      stage: .wakeDetected,
      status: .succeeded,
      detail: "Personalized on-device wake detector recognized the leading phrase.",
      metadata: metadata
    )

    if commandBuffer.isEmpty {
      onPhase?(.wakeDetected)
      onStatus?("Rook heard you — keep talking")
      armFollowUpWindow()
    } else {
      traceFirstTranscriptIfNeeded(requestID: requestID)
      onTranscript?(commandBuffer)
      onPhase?(.capturing)
      onStatus?("Listening — send when the ring completes")
      armEndpointing()
    }
  }

  private func handleWakeDetectorFailure(_ reason: String) {
    let wasReady = wakeDetectorReady
    wakeDetectorReady = false
    if !config.wakeFallbackToApple {
      onWakeEngineState?(.unavailable(reason))
      onPhase?(.unavailable)
      onStatus?(reason)
      return
    }
    onWakeEngineState?(.appleFallback(reason))
    guard wasReady, listeningEnabled else { return }
    onStatus?("Personal wake detector restarting — Apple fallback active")
    wakeRestartWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.wakeDetectorStartAttempted = false
      self.startWakeDetectorIfNeeded()
    }
    wakeRestartWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
  }

  private func beginRequestTrace() -> UUID {
    if let activeRequestID { return activeRequestID }
    let requestID = UUID()
    activeRequestID = requestID
    didTraceFirstTranscript = false
    return requestID
  }

  private func traceFirstTranscriptIfNeeded(requestID: UUID) {
    guard !didTraceFirstTranscript else { return }
    didTraceFirstTranscript = true
    trace(
      requestID: requestID,
      stage: .firstTranscript,
      status: .succeeded,
      detail: "First non-empty command transcript received."
    )
  }

  private func trace(
    requestID: UUID,
    source: RookTaskInputSource = .voice,
    stage: RookTaskTraceStage,
    status: RookTaskTraceEventStatus,
    detail: String,
    metadata: [String: String] = [:]
  ) {
    onTraceSignal?(
      RookTaskTraceSignal(
        requestID: requestID,
        source: source,
        stage: stage,
        status: status,
        detail: detail,
        metadata: metadata
      ))
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
    streamingIntentTimer?.invalidate()
    streamingIntentTimer = nil
    streamingIntentTracker.reset()
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

  private static func pcm16Samples(in buffer: AVAudioPCMBuffer) -> [Int16]? {
    guard buffer.format.commonFormat == .pcmFormatInt16,
      let channel = buffer.int16ChannelData?[0]
    else { return nil }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
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
  case wakeAudioConversionUnavailable

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
    case .wakeAudioConversionUnavailable:
      return "Rook could not convert microphone audio for local wake detection"
    }
  }
}
