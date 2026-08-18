import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
import Foundation
import RookKit
import Speech

@MainActor
final class RookAppDelegate: NSObject, NSApplicationDelegate {
  private struct DeliberationRequest: Sendable {
    let id: UUID
    let displayCommand: String
    let effectiveCommand: String
    let quick: QuickRookResponse
    let workspacePath: String?
    let screenCapture: RookScreenCaptureResult?
    let hybridPlan: RookHybridCapabilityPlan?
    let taskExecution: RookTaskExecutionResult?
  }

  private struct CodingTaskRequest: Sendable {
    let id: UUID
    let displayCommand: String
    let effectiveCommand: String
    let workspacePath: String
  }

  private struct PendingPromptPolish {
    let original: String
    let local: String
    let processingRequestID: UUID
    let source: RookTaskInputSource
    let deadline: DispatchWorkItem
  }

  private struct PrewarmedReflexResult {
    let intent: RookReflexIntent
    let result: Result<RookReflexExecution, Error>
  }

  private let previewMode: Bool
  private var statusItem: NSStatusItem!
  private var statusMenuItem: NSMenuItem!
  private var listeningMenuItem: NSMenuItem!
  private var fluidTranscriptionMenuItem: NSMenuItem!
  private var lastResponseMenuItem: NSMenuItem!
  private var config: RookConfig!
  private var bridge: CodexBridge!
  private var computerController: RookComputerController!
  private var screenCaptureController: RookScreenCaptureController!
  private var reflexController: RookReflexController!
  private var weatherService: RookWeatherService!
  private var oauthCoordinator: RookOAuthCoordinator!
  private var spotifyClient: RookSpotifyClient!
  private var mobileBridge: RookMobileBridgeServer?
  private var library: RookLibrary!
  private var streamingClient: RookStreamingClient!
  private var centralDelegationClient: RookStreamingClient!
  private var promptPolishClient: RookStreamingClient!
  private var pendingConversationStore: RookPendingConversationStore!
  private var traceRecorder: RookTaskTraceRecorder!
  private var taskExecutor: RookTaskExecutor!
  private var codingTaskStore: RookCodingTaskStore!
  private var voice: VoiceController!
  private var lastResponse: RookResponse?
  private var dashboardModel: RookDashboardModel!
  private var rookWindowController: RookWindowController!
  private var activeStreamingRequests: [UUID: String] = [:]
  private var activeCentralDelegations: [UUID: String] = [:]
  private var pendingPromptPolishes: [UUID: PendingPromptPolish] = [:]
  private var prewarmedReflexResults: [UUID: PrewarmedReflexResult] = [:]
  private var activeDeliberations: [UUID: DeliberationRequest] = [:]
  private var activeCodingTasks: [UUID: CodingTaskRequest] = [:]
  private var speechQueue: [String] = []
  private var isSpeakingResponse = false
  private var librarianTimer: Timer?
  private var isLibrarianRefreshing = false
  private var lastLibrarianAttempt: Date?
  private let deliberationQueue = DispatchQueue(
    label: "com.noah.rook.deliberation",
    qos: .userInitiated,
    attributes: .concurrent
  )
  private let librarianQueue = DispatchQueue(label: "com.noah.rook.librarian", qos: .utility)

  init(previewMode: Bool = false) {
    self.previewMode = previewMode
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      config = try RookConfig.loadOrCreate()
      library = try RookLibrary(config: config)
      try library.recoverInterrupted()
      pendingConversationStore = RookPendingConversationStore(documentURL: config.pendingConversationURL)
      traceRecorder = try RookTaskTraceRecorder(directoryURL: config.tracesURL)
      codingTaskStore = try RookCodingTaskStore(directoryURL: config.codingTasksURL)
      try codingTaskStore.recoverInterrupted()
      if let data = try? Data(contentsOf: config.lastResponseJSONURL) {
        lastResponse = try? JSONDecoder().decode(RookResponse.self, from: data)
      }
    } catch {
      showFatal("Rook could not create its private state folder: \(error.localizedDescription)")
      return
    }
    bridge = CodexBridge(config: config)
    computerController = RookComputerController()
    screenCaptureController = RookScreenCaptureController(mediaURL: config.mediaURL)
    reflexController = RookReflexController(config: config)
    weatherService = RookWeatherService(config: config)
    oauthCoordinator = RookOAuthCoordinator(config: config)
    let directOAuth = oauthCoordinator!
    spotifyClient = RookSpotifyClient { [weak directOAuth] in
      guard let directOAuth else { throw RookSpotifyError.notConnected }
      return try await directOAuth.validAccessToken(for: .spotify)
    }
    let nativeSpotifyClient = spotifyClient!
    taskExecutor = RookTaskExecutor { intent in
      try await nativeSpotifyClient.executeForTask(intent)
    }
    if !previewMode {
      streamingClient = RookStreamingClient(config: config)
      centralDelegationClient = RookStreamingClient(config: config, purpose: .centralDelegation)
      centralDelegationClient.start()
      if config.promptPolishEnabled {
        promptPolishClient = RookStreamingClient(config: config, purpose: .promptPolish)
        promptPolishClient.start()
      }
    }
    dashboardModel = RookDashboardModel(config: config, previewMode: previewMode)
    if !previewMode {
      dashboardModel.configureOAuth(
        configuration: oauthCoordinator.configuration(),
        statuses: oauthCoordinator.initialStatuses()
      )
    }
    oauthCoordinator.onStatus = { [weak self] status in
      self?.dashboardModel.updateOAuthStatus(status)
    }
    rookWindowController = RookWindowController(model: dashboardModel)
    buildMenu()

    voice = VoiceController(config: config)
    voice.onStatus = { [weak self] status in self?.setStatus(status) }
    voice.onCommand = { [weak self] command, requestID, source in
      self?.polishAndProcess(command: command, requestID: requestID, source: source)
    }
    voice.onStableStreamingIntent = { [weak self] candidate, requestID in
      self?.prewarmStableStreamingIntent(candidate, requestID: requestID)
    }
    voice.onTraceSignal = { [weak self] signal in try? self?.traceRecorder.ingest(signal) }
    voice.onTranscript = { [weak self] transcript in self?.dashboardModel.noteCommand(transcript) }
    voice.onAudioLevel = { [weak self] level in self?.dashboardModel.updateAudioLevel(level) }
    voice.onCaptureProgress = { [weak self] progress in self?.dashboardModel.updateCaptureProgress(progress) }
    voice.onPhase = { [weak self] phase in self?.dashboardModel.updateVoicePhase(phase) }
    voice.onWakeEngineState = { [weak self] state in self?.dashboardModel.updateWakeEngineState(state) }
    voice.onPermissionsResolved = { [weak self] granted in
      if !granted { self?.setStatus("Voice permissions required") }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        self?.weatherService.start()
      }
    }
    reflexController.onAlert = { [weak self] alert in self?.presentLocalAlert(alert) }
    if previewMode {
      dashboardModel.onListenNow = { [weak self] in self?.setStatus("Ready for command") }
      dashboardModel.onSubmitCommand = { [weak self] command in
        self?.dashboardModel.noteCommand(command)
        self?.setStatus("Preview command ready")
      }
      dashboardModel.onToggleListening = { [weak self] in self?.setStatus("Preview listening control") }
      dashboardModel.onOpenLibraryFolder = { [weak self] in self?.setStatus("Preview Library folder") }
      dashboardModel.onOpenLibraryEntryFolder = { [weak self] _ in self?.setStatus("Preview archive folder") }
      dashboardModel.onOpenLibraryNodeNote = { [weak self] _ in self?.setStatus("Preview graph note") }
      dashboardModel.onRefreshLibrarian = { [weak self] in self?.setStatus("Preview context refresh") }
      dashboardModel.onSaveOAuthClientID = { [weak self] _, _ in
        self?.setStatus("Preview connection saved")
        return nil
      }
      dashboardModel.onConnectOAuth = { [weak self] _ in self?.setStatus("Preview OAuth started") }
      dashboardModel.onDisconnectOAuth = { [weak self] _ in self?.setStatus("Preview OAuth disconnected") }
      dashboardModel.onOpenOAuthSetup = { [weak self] _ in self?.setStatus("Preview developer setup") }
    } else {
      dashboardModel.onListenNow = { [weak self] in self?.voice.promptForCommand() }
      dashboardModel.onSubmitCommand = { [weak self] command in self?.voice.submitTextCommand(command) }
      dashboardModel.onSpeak = { [weak self] text in self?.voice.speak(text) }
      dashboardModel.onToggleListening = { [weak self] in self?.toggleListening() }
      dashboardModel.onOpenLibraryFolder = { [weak self] in self?.openRookFolder() }
      dashboardModel.onOpenLibraryEntryFolder = { entry in
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.conversationFolder, isDirectory: true))
      }
      dashboardModel.onOpenLibraryNodeNote = { [weak self] node in
        guard let self else { return }
        NSWorkspace.shared.open(self.config.libraryURL.appendingPathComponent(node.notePath))
      }
      dashboardModel.onRefreshLibrarian = { [weak self] in self?.refreshLibrarianContext(force: true) }
      dashboardModel.onSaveOAuthClientID = { [weak self] provider, clientID in
        guard let self else { return "Rook is not ready." }
        do {
          try self.oauthCoordinator.saveClientID(clientID, for: provider)
          self.dashboardModel.configureOAuth(
            configuration: self.oauthCoordinator.configuration(),
            statuses: self.oauthCoordinator.initialStatuses()
          )
          return nil
        } catch {
          return error.localizedDescription
        }
      }
      dashboardModel.onConnectOAuth = { [weak self] provider in
        self?.oauthCoordinator.connect(provider)
      }
      dashboardModel.onDisconnectOAuth = { [weak self] provider in
        self?.oauthCoordinator.disconnect(provider)
      }
      dashboardModel.onOpenOAuthSetup = { [weak self] provider in
        self?.openOAuthDeveloperSetup(provider)
      }

      do {
        mobileBridge = try RookMobileBridgeServer(
          config: config,
          model: dashboardModel,
          onCommand: { [weak self] requestID, command in
            self?.polishAndProcess(command: command, requestID: requestID, source: .mobile)
          },
          onMoveDecision: { [weak self] decision, completion in
            self?.recordMobileMoveDecision(decision, completion: completion)
          }
        )
      } catch {
        mobileBridge = nil
      }
    }

    NSApp.setActivationPolicy(previewMode ? .regular : .accessory)
    rookWindowController.showRook()

    if previewMode {
      setStatus("Listening for “\(config.wakePhrase)”")
      return
    }

    reflexController.start()
    installLibrarianTimer()

    let needsOnboarding =
      SFSpeechRecognizer.authorizationStatus() == .notDetermined
      || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    if needsOnboarding {
      showPermissionIntro()
    } else {
      voice.requestPermissionsAndStart()
    }
  }

  private func buildMenu() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = NSImage(
      systemSymbolName: "waveform.circle.fill",
      accessibilityDescription: "Rook"
    )
    statusItem.button?.toolTip = "Rook"

    let menu = NSMenu()
    statusMenuItem = NSMenuItem(title: "Starting Rook…", action: nil, keyEquivalent: "")
    statusMenuItem.isEnabled = false
    menu.addItem(statusMenuItem)

    let phraseItem = NSMenuItem(title: "Wake phrase: “\(config.wakePhrase)”", action: nil, keyEquivalent: "")
    phraseItem.isEnabled = false
    menu.addItem(phraseItem)
    menu.addItem(.separator())

    let openItem = NSMenuItem(title: "Open Rook", action: #selector(openDashboard), keyEquivalent: "r")
    openItem.target = self
    menu.addItem(openItem)

    listeningMenuItem = NSMenuItem(title: "Pause Listening", action: #selector(toggleListening), keyEquivalent: "p")
    listeningMenuItem.target = self
    menu.addItem(listeningMenuItem)

    let permissionsItem = NSMenuItem(
      title: "Voice Permissions…", action: #selector(requestVoicePermissions), keyEquivalent: "")
    permissionsItem.target = self
    menu.addItem(permissionsItem)

    let computerPermissionsItem = NSMenuItem(
      title: "Screen & Computer Setup…", action: #selector(openComputerControlSetup), keyEquivalent: "")
    computerPermissionsItem.target = self
    menu.addItem(computerPermissionsItem)

    let weatherPermissionsItem = NSMenuItem(
      title: "Instant Weather Setup…", action: #selector(openWeatherSetup), keyEquivalent: "")
    weatherPermissionsItem.target = self
    menu.addItem(weatherPermissionsItem)

    let listenNowItem = NSMenuItem(title: "Listen Now / Test Voice", action: #selector(listenNow), keyEquivalent: "l")
    listenNowItem.target = self
    menu.addItem(listenNowItem)

    fluidTranscriptionMenuItem = NSMenuItem(
      title: "FluidAudio Transcription (Trial)",
      action: #selector(toggleFluidTranscriptionTrial),
      keyEquivalent: ""
    )
    fluidTranscriptionMenuItem.target = self
    fluidTranscriptionMenuItem.state =
      (UserDefaults.standard.object(
        forKey: VoiceController.fluidTranscriptionTrialPreferenceKey
      ) as? Bool ?? true) ? .on : .off
    menu.addItem(fluidTranscriptionMenuItem)

    let typeItem = NSMenuItem(title: "Type a Command…", action: #selector(typeCommand), keyEquivalent: "t")
    typeItem.target = self
    menu.addItem(typeItem)

    let pairPhoneItem = NSMenuItem(
      title: "Pair iPhone…", action: #selector(pairIPhone), keyEquivalent: "")
    pairPhoneItem.target = self
    menu.addItem(pairPhoneItem)

    lastResponseMenuItem = NSMenuItem(
      title: "Open Last Response", action: #selector(openLastResponse), keyEquivalent: "o")
    lastResponseMenuItem.target = self
    lastResponseMenuItem.isEnabled = FileManager.default.fileExists(atPath: config.lastResponseURL.path)
    menu.addItem(lastResponseMenuItem)

    let copyItem = NSMenuItem(title: "Copy Last Response", action: #selector(copyLastResponse), keyEquivalent: "c")
    copyItem.target = self
    menu.addItem(copyItem)

    let folderItem = NSMenuItem(title: "Open Rook Library", action: #selector(openRookFolder), keyEquivalent: "")
    folderItem.target = self
    menu.addItem(folderItem)

    menu.addItem(.separator())
    let resetItem = NSMenuItem(
      title: "Start a Fresh Conversation", action: #selector(resetConversation), keyEquivalent: "")
    resetItem.target = self
    menu.addItem(resetItem)

    let quitItem = NSMenuItem(title: "Quit Rook", action: #selector(quit), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
    statusItem.menu = menu
  }

  private func openOAuthDeveloperSetup(_ provider: RookOAuthProvider) {
    let address: String
    switch provider {
    case .google:
      address = "https://console.cloud.google.com/apis/credentials"
    case .spotify:
      address = "https://developer.spotify.com/dashboard"
    }
    guard let url = URL(string: address) else { return }
    NSWorkspace.shared.open(url)
  }

  private func process(
    command: String,
    requestID requestedID: UUID? = nil,
    source: RookTaskInputSource = .unknown
  ) {
    let requestID = requestedID ?? UUID()
    beginTrace(id: requestID, source: source, command: command)
    var routedCommand = command
    var continuationDisplayCommand: String?
    switch pendingConversationStore.resolve(command) {
    case .none:
      break
    case .cancelled(let pending):
      processPendingCancellation(command, pending: pending, requestID: requestID)
      return
    case .retry(let pending):
      routedCommand = pending.sourceCommand
      continuationDisplayCommand = "\(command)  →  \(pending.sourceCommand)"
    case .continuation(let continuation):
      let pending = continuation.pending
      continuationDisplayCommand = "\(command)  →  \(pending.sourceCommand)"
      if pending.domain == .spotifyHybrid,
        let intent = RookSpotifyPlaylistFollowUpResolver.resolve(
          answer: continuation.answer,
          options: pending.options
        ),
        let plan = RookHybridCapabilityPlanner.plan(pending.sourceCommand),
        let playbackStep = RookTaskExecutor.playbackStepOrder(in: plan)
      {
        processSpotifyHybridContinuation(
          displayCommand: continuationDisplayCommand ?? command,
          sourceCommand: pending.sourceCommand,
          plan: plan,
          playbackStep: playbackStep,
          intent: intent,
          requestID: requestID
        )
        return
      }
      if pending.domain == .spotifyPlaylist,
        let intent = RookSpotifyPlaylistFollowUpResolver.resolve(
          answer: continuation.answer,
          options: pending.options
        )
      {
        processSpotifyCommand(
          continuationDisplayCommand ?? command,
          intent: intent,
          requestID: requestID
        )
        return
      }
      routedCommand = continuation.effectiveCommand
    }

    let retryResolution = library.resolveConversationReference(routedCommand)
    let interpretation = RookInferenceLayer.interpret(
      routedCommand,
      retryResolution: retryResolution,
      lastResponse: lastResponse,
      recentEntries: library.entries()
    )
    let effectiveCommand = interpretation.effectiveCommand
    trace(
      id: requestID,
      stage: .intentSelected,
      status: .succeeded,
      component: "inference",
      detail: interpretation.basis.rawValue,
      metadata: ["confidence": String(format: "%.2f", interpretation.confidence)],
      command: command,
      effectiveCommand: effectiveCommand
    )
    let projectResolution = library.resolveProjectReference(effectiveCommand)
    let projectWorkspace = projectResolution?.project.referencedWorkspacePaths.first { candidate in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
    let displayCommand: String
    if let continuationDisplayCommand {
      displayCommand = continuationDisplayCommand
    } else if interpretation.displayCommand != effectiveCommand {
      displayCommand = interpretation.displayCommand
    } else if let projectResolution, projectResolution.reason != "project name or alias matched" {
      displayCommand = "\(command)  →  \(projectResolution.project.title)"
    } else {
      displayCommand = command
    }

    let inference = RookInferenceLayer.decide(
      interpretation,
      cachedDecision: library.cachedOperationalDecision(for: effectiveCommand)
    )
    let directResolution = inference.resolution
    let routingObservation = RookRoutingBenchmarkSuite.observe(
      directResolution,
      command: effectiveCommand
    )
    trace(
      id: requestID,
      stage: .routeSelected,
      status: .succeeded,
      component: "deliberator",
      detail: routingObservation.route,
      metadata: [
        "capabilities": routingObservation.capabilities.map(\.rawValue).joined(separator: ","),
        "computer_operator": String(routingObservation.usesComputerOperator),
        "execution_contracts": routingObservation.capabilities.map {
          RookDirectCapabilityGuide.executionContract(for: $0).adapter
        }.joined(separator: ","),
        "dependent_steps": String(routingObservation.dependentStepCount),
      ],
      route: routingObservation.route
    )
    let decision: LocalRookDecision
    var hybridPlan: RookHybridCapabilityPlan?
    switch directResolution {
    case .reflex(let intent):
      processReflexCommand(displayCommand, intent: intent, requestID: requestID)
      return
    case .weather(let request):
      processWeatherCommand(displayCommand, request: request, requestID: requestID)
      return
    case .spotify(let intent):
      processResolvedSpotifyCommand(displayCommand, intent: intent, requestID: requestID)
      return
    case .screenCapture(let captureRequest):
      processScreenCaptureCommand(
        displayCommand,
        effectiveCommand: effectiveCommand,
        request: captureRequest,
        workspacePath: projectWorkspace,
        requestID: requestID
      )
      return
    case .computerControl(let intent):
      processNativeComputerCommand(displayCommand, intent: intent, requestID: requestID)
      return
    case .librarianCheckpoint(let cachedDecision):
      decision = cachedDecision
    case .hybrid(let plan):
      hybridPlan = plan
      decision = LocalRookRouter.routeHybrid(effectiveCommand, plan: plan)
    case .clarification(let capability, let message):
      switch capability {
      case .spotify:
        processSpotifyClarification(displayCommand, message: message, requestID: requestID)
      default:
        processDirectCapabilityClarification(
          displayCommand,
          capability: capability,
          message: message,
          requestID: requestID
        )
      }
      return
    case .fallThrough(let capability):
      launchCentralDelegation(
        id: requestID,
        displayCommand: displayCommand,
        effectiveCommand: effectiveCommand,
        workspacePath: projectWorkspace,
        declinedCapability: capability
      )
      return
    case .unclaimed:
      launchCentralDelegation(
        id: requestID,
        displayCommand: displayCommand,
        effectiveCommand: effectiveCommand,
        workspacePath: projectWorkspace
      )
      return
    }

    let immediate = decision.response.immediateResponse
    _ = try? library.beginTurn(
      id: requestID,
      command: displayCommand,
      route: decision.destination.rawValue,
      pawns: decision.response.pawns
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: displayCommand)
    dashboardModel.presentLocal(decision, requestID: requestID, command: displayCommand)
    lastResponse = immediate
    lastResponseMenuItem.isEnabled = true

    switch decision.destination {
    case .instant:
      traceExternalOutcome(
        id: requestID,
        route: decision.destination.rawValue,
        adapter: "local_router",
        verified: true
      )
      persistLastResponse(
        immediate,
        command: displayCommand,
        route: decision.destination.rawValue
      )
      _ = try? library.finishTurn(
        id: requestID,
        command: displayCommand,
        route: decision.destination.rawValue,
        displayText: immediate.displayText,
        pawns: []
      )
      dashboardModel.refreshLibrary()
      setStatus(backgroundStatus())
      finishTrace(id: requestID, outcome: .succeeded, verified: true)
    case .stream:
      launchStreamingAnswer(id: requestID, displayCommand: displayCommand, effectiveCommand: effectiveCommand)
      setStatus(backgroundStatus())
    case .deliberate:
      if let hybridPlan, RookTaskExecutor.supports(hybridPlan) {
        launchTaskExecution(
          id: requestID,
          displayCommand: displayCommand,
          effectiveCommand: effectiveCommand,
          quick: decision.response,
          workspacePath: projectWorkspace,
          plan: hybridPlan
        )
        setStatus("Running native steps…")
      } else {
        launchDeliberation(
          id: requestID,
          displayCommand: displayCommand,
          effectiveCommand: effectiveCommand,
          quick: decision.response,
          workspacePath: projectWorkspace,
          hybridPlan: hybridPlan
        )
        setStatus(backgroundStatus())
      }
    }

    speakResponse(decision.response.spokenText)
  }

  private func processSpotifyHybridContinuation(
    displayCommand: String,
    sourceCommand: String,
    plan: RookHybridCapabilityPlan,
    playbackStep: Int,
    intent: RookSpotifyIntent,
    requestID: UUID
  ) {
    trace(
      id: requestID,
      stage: .intentSelected,
      status: .succeeded,
      component: "pending_conversation",
      detail: "spotify_hybrid_continuation",
      command: displayCommand,
      effectiveCommand: sourceCommand
    )
    trace(
      id: requestID,
      stage: .routeSelected,
      status: .succeeded,
      component: "deliberator",
      detail: "hybrid",
      metadata: [
        "capabilities": "spotify",
        "computer_operator": "false",
        "execution_contracts": RookDirectCapabilityGuide.executionContract(for: .spotify).adapter,
        "dependent_steps": String(plan.steps.filter { !$0.dependsOn.isEmpty }.count),
      ],
      route: "hybrid"
    )
    let planned = LocalRookRouter.routeHybrid(sourceCommand, plan: plan).response
    let quick = QuickRookResponse(
      displayText: "Got it—I’ll use that playlist, verify what starts playing, and continue the artist research.",
      spokenText: "Got it. I’ll play that and continue the research.",
      route: planned.route,
      intent: planned.intent,
      pawns: planned.pawns,
      canvas: planned.canvas
    )
    let decision = LocalRookDecision(destination: .deliberate, response: quick)
    _ = try? library.beginTurn(
      id: requestID,
      command: displayCommand,
      route: LocalRookDestination.deliberate.rawValue,
      pawns: quick.pawns
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: displayCommand)
    dashboardModel.presentLocal(decision, requestID: requestID, command: displayCommand)
    lastResponse = quick.immediateResponse
    lastResponseMenuItem.isEnabled = true
    launchTaskExecution(
      id: requestID,
      displayCommand: displayCommand,
      effectiveCommand: sourceCommand,
      quick: quick,
      workspacePath: nil,
      plan: plan,
      intentOverrides: [playbackStep: intent]
    )
    setStatus(backgroundStatus())
    speakResponse(quick.spokenText)
  }

  private func processPendingCancellation(
    _ command: String,
    pending: RookPendingConversation,
    requestID: UUID
  ) {
    traceAdapterStart(id: requestID, route: "context_cancelled", adapter: "pending_conversation")
    let label = pending.sourceCommand
      .split(whereSeparator: \.isWhitespace)
      .prefix(5)
      .joined(separator: " ")
    let response = RookResponse(
      displayText: "Okay—I dropped **\(label)**.",
      spokenText: "Okay, I dropped that request.",
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    let quick = QuickRookResponse(
      displayText: response.displayText,
      spokenText: response.spokenText,
      route: "answer_now",
      intent: "status",
      pawns: []
    )
    _ = try? library.beginTurn(id: requestID, command: command, route: "context_cancelled", pawns: [])
    _ = try? library.finishTurn(
      id: requestID,
      command: command,
      route: "context_cancelled",
      displayText: response.displayText,
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: command)
    dashboardModel.presentLocal(
      LocalRookDecision(destination: .instant, response: quick),
      requestID: requestID,
      command: command
    )
    _ = dashboardModel.completeInstant(response, command: command, requestID: requestID)
    lastResponse = response
    persistLastResponse(response, command: command, route: "context_cancelled")
    lastResponseMenuItem.isEnabled = true
    setStatus(backgroundStatus())
    speakResponse(response.spokenText)
    finishTrace(id: requestID, outcome: .cancelled, verified: true)
  }

  private func polishAndProcess(
    command: String,
    requestID: UUID? = nil,
    source: RookTaskInputSource = .unknown
  ) {
    let processingRequestID = requestID ?? UUID()
    beginTrace(id: processingRequestID, source: source, command: command)
    trace(
      id: processingRequestID,
      stage: .requestReceived,
      status: .succeeded,
      component: "orchestrator",
      detail: "Command entered the Rook request pipeline.",
      command: command
    )
    let local = RookPromptRefiner.refine(command)
    guard !local.isEmpty else { return }
    trace(
      id: processingRequestID,
      stage: .promptRefined,
      status: .succeeded,
      component: "prompt_refiner",
      detail: local == command ? "unchanged" : "locally_refined",
      effectiveCommand: local
    )
    dashboardModel.noteCommand(local)

    // An answer to Rook's own question should never wait on a prompt-polish
    // model. The pending-context resolver is both faster and more accurate.
    if pendingConversationStore.current() != nil {
      process(command: local, requestID: processingRequestID, source: source)
      return
    }

    guard config.promptPolishEnabled,
      promptPolishClient != nil,
      RookPromptRefiner.needsModelPolish(original: command, locallyRefined: local),
      shouldUseModelPromptPolish(local)
    else {
      process(command: local, requestID: processingRequestID, source: source)
      return
    }

    let polishRequestID = UUID()
    setStatus("Polishing your prompt")
    let deadline = DispatchWorkItem { [weak self] in
      self?.finishPromptPolish(id: polishRequestID, modelCandidate: nil)
    }
    pendingPromptPolishes[polishRequestID] = PendingPromptPolish(
      original: command,
      local: local,
      processingRequestID: processingRequestID,
      source: source,
      deadline: deadline
    )
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(config.promptPolishWaitMilliseconds),
      execute: deadline
    )

    promptPolishClient.answer(
      id: polishRequestID,
      command: command,
      onDelta: { _ in },
      completion: { [weak self] result in
        DispatchQueue.main.async {
          switch result {
          case .success(let candidate):
            self?.finishPromptPolish(id: polishRequestID, modelCandidate: candidate)
          case .failure:
            self?.finishPromptPolish(id: polishRequestID, modelCandidate: nil)
          }
        }
      }
    )
  }

  private func shouldUseModelPromptPolish(_ command: String) -> Bool {
    switch RookDirectCapabilityGuide.resolve(
      command,
      cachedDecision: library.cachedOperationalDecision(for: command)
    ) {
    case .fallThrough, .unclaimed:
      break
    default:
      return false
    }
    return LocalRookRouter.route(command).destination != .instant
  }

  private func finishPromptPolish(id: UUID, modelCandidate: String?) {
    guard let pending = pendingPromptPolishes.removeValue(forKey: id) else { return }
    pending.deadline.cancel()
    let polished =
      modelCandidate.flatMap {
        RookPromptRefiner.validatedModelPolish($0, preserving: pending.original)
      } ?? pending.local
    dashboardModel.noteCommand(polished)
    process(command: polished, requestID: pending.processingRequestID, source: pending.source)
  }

  private func prewarmStableStreamingIntent(
    _ candidate: RookStreamingIntentCandidate,
    requestID: UUID
  ) {
    guard case .reflex(let intent) = RookDirectCapabilityGuide.resolve(candidate.command),
      RookStreamingIntentPolicy.isSafeToPrepare(intent)
    else { return }

    trace(
      id: requestID,
      stage: .adapterStarted,
      status: .started,
      component: candidate.adapter,
      detail: "Side-effect-free native preparation started before final transcript.",
      metadata: ["execution": "private_prewarm"],
      route: "reflex_native",
      adapter: candidate.adapter
    )
    reflexController.execute(intent) { [weak self] result in
      guard let self else { return }
      self.prewarmedReflexResults[requestID] = PrewarmedReflexResult(
        intent: intent,
        result: result
      )
      self.trace(
        id: requestID,
        stage: .prewarmReady,
        status: {
          if case .success = result { return .succeeded }
          return .failed
        }(),
        component: candidate.adapter,
        detail: "Private native preparation finished; the result remains conditional on the final transcript.",
        metadata: ["execution": "private_prewarm"]
      )
      DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
        guard self?.prewarmedReflexResults[requestID]?.intent == intent else { return }
        self?.prewarmedReflexResults.removeValue(forKey: requestID)
      }
    }
  }

  private func processReflexCommand(
    _ command: String,
    intent: RookReflexIntent,
    requestID: UUID
  ) {
    let prewarmed = prewarmedReflexResults.removeValue(forKey: requestID)
    if prewarmed?.intent != intent {
      traceAdapterStart(id: requestID, route: "reflex_native", adapter: "rook_reflex")
    }
    let quick = QuickRookResponse(
      displayText: intent.progressText,
      spokenText: "On it.",
      route: "answer_now",
      intent: "status",
      pawns: []
    )
    let decision = LocalRookDecision(destination: .instant, response: quick)
    _ = try? library.beginTurn(
      id: requestID,
      command: command,
      route: "reflex_native",
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: command)
    dashboardModel.presentLocal(decision, requestID: requestID, command: command)
    setStatus(intent.progressText)

    if let prewarmed, prewarmed.intent == intent {
      completeReflexCommand(
        prewarmed.result,
        command: command,
        requestID: requestID
      )
    } else {
      reflexController.execute(intent) { [weak self] result in
        self?.completeReflexCommand(result, command: command, requestID: requestID)
      }
    }
  }

  private func completeReflexCommand(
    _ result: Result<RookReflexExecution, Error>,
    command: String,
    requestID: UUID
  ) {
    switch result {
    case .success(let execution):
      traceExternalOutcome(
        id: requestID,
        route: "reflex_native",
        adapter: "rook_reflex",
        verified: true
      )
      let response = RookResponse(
        displayText: execution.displayText,
        spokenText: execution.spokenText,
        intent: "status",
        requiresApproval: false,
        queueItemIDs: [],
        pawns: [],
        canvas: [execution.canvas]
      )
      _ = try? library.finishTurn(
        id: requestID,
        command: command,
        route: "reflex_native",
        displayText: execution.displayText,
        pawns: []
      )
      if dashboardModel.completeInstant(response, command: command, requestID: requestID) {
        lastResponse = response
        persistLastResponse(response, command: command, route: "reflex_native")
      }
      lastResponseMenuItem.isEnabled = true
      dashboardModel.refreshLibrary()
      setStatus(backgroundStatus())
      speakResponse(execution.spokenText)
      finishTrace(id: requestID, outcome: .succeeded, verified: true)

    case .failure(let error):
      let message = error.localizedDescription
      traceFailure(id: requestID, message: message, capability: .reflex)
      let response = RookResponse(
        displayText: "**Rook Reflex needs clarification.** \(message)",
        spokenText: message,
        intent: "error",
        requiresApproval: false,
        queueItemIDs: [],
        pawns: [],
        canvas: [
          RookCanvasBlock(
            id: "reflex_error",
            kind: .list,
            title: "Rook Reflex",
            subtitle: "Not completed",
            items: [
              RookCanvasItem(
                id: "reflex_issue",
                label: "Needs clarification",
                detail: message,
                value: "Not completed",
                symbol: .warning
              )
            ]
          )
        ]
      )
      _ = try? library.failTurn(
        id: requestID,
        command: command,
        route: "reflex_native",
        displayText: response.displayText,
        reason: message,
        pawns: []
      )
      if dashboardModel.completeInstant(response, command: command, requestID: requestID) {
        lastResponse = response
        persistLastResponse(response, command: command, route: "reflex_native")
      }
      lastResponseMenuItem.isEnabled = true
      dashboardModel.refreshLibrary()
      setStatus(backgroundStatus(fallback: "Reflex needs clarification"))
      speakResponse(response.spokenText)
    }
  }

  private func presentLocalAlert(_ alert: RookLocalAlert) {
    let requestID = UUID()
    let command = alert.kind == .timer ? "Timer finished" : "Reminder due"
    let title = alert.kind == .timer ? "Timer finished" : "Reminder due"
    let spoken = alert.kind == .timer ? "Your Rook timer is finished." : "Your Rook reminder is due."
    let response = RookResponse(
      displayText: "**\(title)**\n\n\(alert.message)",
      spokenText: spoken,
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "alert_due",
          kind: .list,
          title: title,
          subtitle: "Local Rook alert",
          items: [
            RookCanvasItem(
              id: "due_item",
              label: alert.message,
              detail: alert.kind.rawValue.capitalized,
              value: "Now",
              symbol: .clock
            )
          ]
        )
      ]
    )
    _ = try? library.beginTurn(id: requestID, command: command, route: "reflex_alert", pawns: [])
    _ = try? library.finishTurn(
      id: requestID,
      command: command,
      route: "reflex_alert",
      displayText: response.displayText,
      pawns: []
    )
    dashboardModel.beginRequest(id: requestID, command: command)
    _ = dashboardModel.completeInstant(response, command: command, requestID: requestID)
    dashboardModel.refreshLibrary()
    lastResponse = response
    persistLastResponse(response)
    lastResponseMenuItem.isEnabled = true
    setStatus(title)
    speakResponse(spoken)
  }

  private func processWeatherCommand(
    _ command: String,
    request: RookWeatherRequest,
    requestID: UUID
  ) {
    traceAdapterStart(id: requestID, route: "weather_native", adapter: "open_meteo")
    let quick = QuickRookResponse(
      displayText: "Pulling the live forecast…",
      spokenText: "Checking the weather.",
      route: "answer_now",
      intent: "brief",
      pawns: []
    )
    let decision = LocalRookDecision(destination: .instant, response: quick)
    _ = try? library.beginTurn(
      id: requestID,
      command: command,
      route: "weather_native",
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: command)
    dashboardModel.presentLocal(decision, requestID: requestID, command: command)
    setStatus("Fetching live weather…")

    weatherService.fetch(request) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let response):
        self.traceExternalOutcome(
          id: requestID,
          route: "weather_native",
          adapter: "open_meteo",
          verified: true
        )
        _ = try? self.library.finishTurn(
          id: requestID,
          command: command,
          route: "weather_native",
          displayText: response.displayText,
          pawns: []
        )
        if self.dashboardModel.completeInstant(response, command: command, requestID: requestID) {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "weather_native")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus())
        self.speakResponse(response.spokenText)
        self.finishTrace(id: requestID, outcome: .succeeded, verified: true)

      case .failure(let error):
        let message = error.localizedDescription
        self.traceFailure(id: requestID, message: message, capability: .weather)
        let response = RookResponse(
          displayText: "**Instant weather needs attention.** \(message)",
          spokenText: "I need your location once before instant weather will work.",
          intent: "error",
          requiresApproval: false,
          queueItemIDs: [],
          pawns: [],
          canvas: [
            RookCanvasBlock(
              id: "weather_error",
              kind: .weather,
              title: "Instant weather",
              subtitle: "Not completed",
              items: [
                RookCanvasItem(
                  id: "weather_setup",
                  label: "Location needed",
                  detail: message,
                  value: "Setup",
                  symbol: .warning
                )
              ]
            )
          ]
        )
        _ = try? self.library.failTurn(
          id: requestID,
          command: command,
          route: "weather_native",
          displayText: response.displayText,
          reason: message,
          pawns: []
        )
        if self.dashboardModel.completeInstant(response, command: command, requestID: requestID) {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "weather_native")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus(fallback: "Instant weather needs setup"))
        self.speakResponse(response.spokenText)
      }
    }
  }

  private func processNativeComputerCommand(
    _ command: String,
    intent: RookComputerIntent,
    requestID: UUID
  ) {
    traceAdapterStart(id: requestID, route: "computer_native", adapter: "native_mac_controller")
    let quick = QuickRookResponse(
      displayText: intent.progressText,
      spokenText: "On it.",
      route: "answer_now",
      intent: "status",
      pawns: []
    )
    let decision = LocalRookDecision(destination: .instant, response: quick)
    _ = try? library.beginTurn(
      id: requestID,
      command: command,
      route: "computer_native",
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: command)
    dashboardModel.presentLocal(decision, requestID: requestID, command: command)
    setStatus("Controlling \(intent.targetLabel)…")

    computerController.execute(intent) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let execution):
        self.traceExternalOutcome(
          id: requestID,
          route: "computer_native",
          adapter: "native_mac_controller",
          verified: execution.verified
        )
        let response = RookResponse(
          displayText: execution.displayText,
          spokenText: execution.spokenText,
          intent: "status",
          requiresApproval: false,
          queueItemIDs: [],
          pawns: [],
          canvas: [self.computerCanvas(for: execution)]
        )
        _ = try? self.library.finishTurn(
          id: requestID,
          command: command,
          route: "computer_native",
          displayText: execution.displayText,
          pawns: []
        )
        if self.dashboardModel.completeInstant(response, command: command, requestID: requestID) {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "computer_native")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus())
        self.speakResponse(execution.spokenText)
        self.finishTrace(id: requestID, outcome: .succeeded, verified: execution.verified)

      case .failure(let error):
        let message = error.localizedDescription
        self.traceFailure(id: requestID, message: message, capability: .computerControl)
        let response = RookResponse(
          displayText: "**Computer control needs attention.** \(message)",
          spokenText: "I couldn't finish that computer control. Check Rook on screen.",
          intent: "error",
          requiresApproval: false,
          queueItemIDs: [],
          pawns: [],
          canvas: [
            RookCanvasBlock(
              id: "computer_error",
              kind: .computer,
              title: "Computer control",
              subtitle: "Not completed",
              items: [
                RookCanvasItem(
                  id: "control_error",
                  label: intent.targetLabel,
                  detail: message,
                  value: "Needs attention",
                  symbol: .warning
                )
              ]
            )
          ]
        )
        _ = try? self.library.failTurn(
          id: requestID,
          command: command,
          route: "computer_native",
          displayText: response.displayText,
          reason: message,
          pawns: []
        )
        if self.dashboardModel.completeInstant(response, command: command, requestID: requestID) {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "computer_native")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus(fallback: "Computer control needs attention"))
        self.speakResponse(response.spokenText)
      }
    }
  }

  private func processScreenCaptureCommand(
    _ command: String,
    effectiveCommand: String,
    request: RookScreenCaptureRequest,
    workspacePath: String?,
    requestID: UUID
  ) {
    traceAdapterStart(id: requestID, route: "screen_capture", adapter: "screen_capture_kit")
    let quick = QuickRookResponse(
      displayText: request.progressText,
      spokenText: "I’m taking a private look now.",
      route: "deliberate",
      intent: "plan",
      pawns: []
    )
    let decision = LocalRookDecision(destination: .deliberate, response: quick)
    _ = try? library.beginTurn(
      id: requestID,
      command: command,
      route: LocalRookDestination.deliberate.rawValue,
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: command)
    dashboardModel.presentLocal(decision, requestID: requestID, command: command)
    setStatus("Capturing \(request.target.label)…")

    Task { [weak self] in
      guard let self else { return }
      do {
        let capture = try await self.screenCaptureController.capture(request)
        self.traceExternalOutcome(
          id: requestID,
          route: "screen_capture",
          adapter: "screen_capture_kit",
          verified: true
        )
        self.launchDeliberation(
          id: requestID,
          displayCommand: command,
          effectiveCommand: effectiveCommand,
          quick: quick,
          workspacePath: workspacePath,
          screenCapture: capture
        )
      } catch {
        let message = error.localizedDescription
        self.traceFailure(id: requestID, message: message, capability: .screenCapture)
        let response = RookResponse(
          displayText: "**Screen capture needs attention.** \(message)",
          spokenText: "I couldn’t capture that view. The details are on screen.",
          intent: "error",
          requiresApproval: false,
          queueItemIDs: [],
          pawns: [],
          canvas: [
            RookCanvasBlock(
              id: "screen_capture_error",
              kind: .computer,
              title: "Screen capture",
              subtitle: "Not completed",
              items: [
                RookCanvasItem(
                  id: "capture_permission",
                  label: request.target.label.capitalized,
                  detail: message,
                  value: "Needs attention",
                  symbol: .warning
                )
              ]
            )
          ]
        )
        _ = try? self.library.failTurn(
          id: requestID,
          command: command,
          route: LocalRookDestination.deliberate.rawValue,
          displayText: response.displayText,
          reason: message,
          pawns: []
        )
        let isLatest = self.dashboardModel.completeDeliberation(
          response,
          command: command,
          requestID: requestID
        )
        if isLatest {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "screen_capture")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus(fallback: "Screen capture needs attention"))
        self.speakResponse(response.spokenText)
      }
    }
  }

  private func processSpotifyCommand(
    _ command: String,
    intent: RookSpotifyIntent,
    requestID: UUID
  ) {
    traceAdapterStart(id: requestID, route: "spotify_native", adapter: "spotify_web_api")
    let quick = QuickRookResponse(
      displayText: intent.progressText,
      spokenText: "Checking Spotify.",
      route: "answer_now",
      intent: "status",
      pawns: []
    )
    let decision = LocalRookDecision(destination: .instant, response: quick)
    _ = try? library.beginTurn(
      id: requestID,
      command: command,
      route: "spotify_native",
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: command)
    dashboardModel.presentLocal(decision, requestID: requestID, command: command)
    setStatus("Checking Spotify…")

    Task { [weak self] in
      guard let self else { return }
      do {
        let output = try await self.spotifyClient.executeForTask(intent)
        let response = output.response
        let verified = output.verified
        self.traceExternalOutcome(
          id: requestID,
          route: "spotify_native",
          adapter: "spotify_web_api",
          verified: verified
        )
        _ = try? self.library.finishTurn(
          id: requestID,
          command: command,
          route: "spotify_native",
          displayText: response.displayText,
          pawns: []
        )
        if self.dashboardModel.completeInstant(response, command: command, requestID: requestID) {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "spotify_native")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus())
        self.speakResponse(response.spokenText)
        self.finishTrace(id: requestID, outcome: .succeeded, verified: verified)
      } catch {
        let message = error.localizedDescription
        self.traceFailure(id: requestID, message: message, capability: .spotify)
        let response = RookResponse(
          displayText: "**Spotify needs attention.** \(message)",
          spokenText: "I couldn’t finish that Spotify request. Check Rook on screen.",
          intent: "error",
          requiresApproval: false,
          queueItemIDs: [],
          pawns: [],
          canvas: [
            RookCanvasBlock(
              id: "spotify_error",
              kind: .spotify,
              title: "Spotify",
              subtitle: "Not completed",
              asOf: ISO8601DateFormatter().string(from: Date()),
              items: [
                RookCanvasItem(
                  id: "spotify_issue",
                  label: "Needs attention",
                  detail: message,
                  value: "Not completed",
                  symbol: .warning
                )
              ],
              sourceLabel: "Spotify",
              sourceURL: "https://open.spotify.com"
            )
          ]
        )
        _ = try? self.library.failTurn(
          id: requestID,
          command: command,
          route: "spotify_native",
          displayText: response.displayText,
          reason: message,
          pawns: []
        )
        if self.dashboardModel.completeInstant(response, command: command, requestID: requestID) {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "spotify_native")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus(fallback: "Spotify needs attention"))
        self.speakResponse(response.spokenText)
      }
    }
  }

  private func processResolvedSpotifyCommand(
    _ command: String,
    intent: RookSpotifyIntent,
    requestID: UUID
  ) {
    if dashboardModel.oauthStatus(for: .spotify).phase == .connected {
      processSpotifyCommand(command, intent: intent, requestID: requestID)
    } else if let fallback = computerFallback(for: intent) {
      processNativeComputerCommand(
        command,
        intent: .spotify(fallback),
        requestID: requestID
      )
    } else {
      processSpotifyCommand(command, intent: intent, requestID: requestID)
    }
  }

  private func processSpotifyClarification(
    _ command: String,
    message: String,
    requestID: UUID
  ) {
    traceAdapterStart(id: requestID, route: "spotify_native", adapter: "spotify_clarification")
    let response = RookResponse(
      displayText: message,
      spokenText: message,
      intent: "clarification",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "spotify_clarification",
          kind: .spotify,
          title: "Spotify",
          subtitle: "One detail needed",
          items: [
            RookCanvasItem(
              id: "spotify_next_detail",
              label: "What to say",
              detail: "Name the playlist, track, album, artist, or device.",
              value: "Direct · No Computer Control",
              symbol: .music
            )
          ],
          sourceLabel: "Spotify",
          sourceURL: "https://open.spotify.com"
        )
      ]
    )
    _ = try? library.beginTurn(id: requestID, command: command, route: "spotify_native", pawns: [])
    _ = try? library.finishTurn(
      id: requestID,
      command: command,
      route: "spotify_native",
      displayText: response.displayText,
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: command)
    let quick = QuickRookResponse(
      displayText: response.displayText,
      spokenText: response.spokenText,
      route: "answer_now",
      intent: "clarification",
      pawns: []
    )
    dashboardModel.presentLocal(
      LocalRookDecision(destination: .instant, response: quick),
      requestID: requestID,
      command: command
    )
    _ = dashboardModel.completeInstant(response, command: command, requestID: requestID)
    lastResponse = response
    persistLastResponse(response, command: command, route: "spotify_native")
    lastResponseMenuItem.isEnabled = true
    setStatus(backgroundStatus())
    speakResponse(response.spokenText)
    traceExternalOutcome(
      id: requestID,
      route: "spotify_native",
      adapter: "spotify_clarification",
      verified: true,
      status: .clarified
    )
    finishTrace(id: requestID, outcome: .clarified, verified: true)
  }

  private func processDirectCapabilityClarification(
    _ command: String,
    capability: RookDirectCapabilityID,
    message: String,
    requestID: UUID
  ) {
    traceAdapterStart(
      id: requestID,
      route: "\(capability.rawValue)_native",
      adapter: "direct_clarification"
    )
    let descriptor = RookDirectCapabilityGuide.cheatSheet.first { $0.id == capability }
    let title = descriptor?.title ?? "Direct capability"
    let route = "\(capability.rawValue)_native"
    let response = RookResponse(
      displayText: message,
      spokenText: "I need one detail before I can do that directly.",
      intent: "clarification",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "direct_capability_clarification",
          kind: .list,
          title: title,
          subtitle: "One detail needed",
          items: [
            RookCanvasItem(
              id: "direct_capability_next_detail",
              label: "Direct route",
              detail: message,
              value: "No pawns",
              symbol: .info
            )
          ]
        )
      ]
    )
    _ = try? library.beginTurn(id: requestID, command: command, route: route, pawns: [])
    _ = try? library.finishTurn(
      id: requestID,
      command: command,
      route: route,
      displayText: response.displayText,
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: requestID, command: command)
    _ = dashboardModel.completeInstant(response, command: command, requestID: requestID)
    lastResponse = response
    persistLastResponse(response, command: command, route: route)
    lastResponseMenuItem.isEnabled = true
    setStatus(backgroundStatus())
    speakResponse(response.spokenText)
    traceExternalOutcome(
      id: requestID,
      route: route,
      adapter: "direct_clarification",
      verified: true,
      status: .clarified
    )
    finishTrace(id: requestID, outcome: .clarified, verified: true)
  }

  private func computerFallback(for intent: RookSpotifyIntent) -> RookSpotifyAction? {
    switch intent {
    case .resume: return .play
    case .pause: return .pause
    case .next: return .next
    case .previous: return .previous
    default: return nil
    }
  }

  private func computerCanvas(for execution: RookComputerExecution) -> RookCanvasBlock {
    RookCanvasBlock(
      id: "computer_control",
      kind: .computer,
      title: "Computer control",
      subtitle: "Completed on this Mac",
      items: [
        RookCanvasItem(
          id: "computer_target",
          label: execution.target,
          detail: execution.detail,
          value: "Done",
          symbol: .computer
        )
      ]
    )
  }

  /// Gives every request that was not claimed by an exact native fast path to
  /// Central Rook before any deep work begins. This pass understands the whole
  /// request, but cannot use tools or take action; it may answer, clarify, or
  /// hand the intact request to the deep Central Rook with a small pawn plan.
  private func launchCentralDelegation(
    id: UUID,
    displayCommand: String,
    effectiveCommand: String,
    workspacePath: String?,
    declinedCapability: RookDirectCapabilityID? = nil
  ) {
    let holding = LocalRookDecision(
      destination: .stream,
      response: QuickRookResponse(
        displayText: "Central Rook is deciding the best way to handle that.",
        spokenText: "Let me work out the right way to handle that.",
        route: "answer_now",
        intent: "status",
        pawns: []
      )
    )
    _ = try? library.beginTurn(
      id: id,
      command: displayCommand,
      route: "central_delegation",
      pawns: []
    )
    dashboardModel.refreshLibrary()
    dashboardModel.beginRequest(id: id, command: displayCommand)
    dashboardModel.presentLocal(holding, requestID: id, command: displayCommand)
    activeCentralDelegations[id] = displayCommand
    traceAdapterStart(id: id, route: "central_delegation", adapter: "central_rook_front")
    setStatus(backgroundStatus())

    var contextSnapshot = library.contextSnapshot(for: effectiveCommand)
    if let declinedCapability {
      contextSnapshot +=
        "\n\nTrusted native routing note: the exact \(declinedCapability.rawValue) fast path did not safely claim this request. Interpret the full request and choose the next owner."
    }
    centralDelegationClient.answer(
      id: id,
      command: effectiveCommand,
      contextSnapshot: contextSnapshot,
      onDelta: { _ in },
      completion: { [weak self] result in
        DispatchQueue.main.async {
          self?.handleCentralDelegationResult(
            result,
            id: id,
            displayCommand: displayCommand,
            effectiveCommand: effectiveCommand,
            workspacePath: workspacePath
          )
        }
      }
    )
  }

  private func handleCentralDelegationResult(
    _ result: Result<String, Error>,
    id: UUID,
    displayCommand: String,
    effectiveCommand: String,
    workspacePath: String?
  ) {
    guard activeCentralDelegations.removeValue(forKey: id) != nil else { return }
    do {
      let text = try result.get()
      let decoded = try JSONDecoder().decode(QuickRookResponse.self, from: Data(text.utf8))
      guard decoded.route == "answer_now" || decoded.route == "deliberate" else {
        throw RookStreamingError.invalidResponse("Central Rook selected an unsupported route.")
      }
      let sanitized = bridge.sanitized(decoded)
      let quick = QuickRookResponse(
        displayText: sanitized.displayText,
        spokenText: sanitized.spokenText,
        route: sanitized.route,
        intent: sanitized.intent,
        pawns: sanitized.route == "answer_now" ? [] : sanitized.pawns,
        canvas: []
      )
      trace(
        id: id,
        stage: .routeSelected,
        status: .succeeded,
        component: "central_rook_front",
        detail: quick.route,
        metadata: ["pawn_count": String(quick.pawns.count)],
        route: quick.route
      )

      if quick.route == "answer_now" {
        let response = quick.immediateResponse
        _ = try? library.finishTurn(
          id: id,
          command: displayCommand,
          route: "central_answer",
          displayText: response.displayText,
          pawns: []
        )
        let isLatest = dashboardModel.completeInstant(response, command: displayCommand, requestID: id)
        dashboardModel.refreshLibrary()
        if isLatest {
          lastResponse = response
          lastResponseMenuItem.isEnabled = true
          persistLastResponse(response, command: displayCommand, route: "central_answer")
          speakResponse(response.spokenText)
        }
        traceExternalOutcome(id: id, route: "central_answer", adapter: "central_rook_front", verified: false)
        finishTrace(id: id, outcome: quick.intent == "clarification" ? .clarified : .succeeded, verified: false)
        setStatus(backgroundStatus())
        return
      }

      dashboardModel.presentQuick(quick, requestID: id, command: displayCommand)
      lastResponse = quick.immediateResponse
      lastResponseMenuItem.isEnabled = true
      launchDeliberation(
        id: id,
        displayCommand: displayCommand,
        effectiveCommand: effectiveCommand,
        quick: quick,
        workspacePath: workspacePath
      )
      setStatus(backgroundStatus())
      speakResponse(quick.spokenText)
    } catch {
      trace(
        id: id,
        stage: .recoverySelected,
        status: .started,
        component: "recovery_policy",
        detail: error.localizedDescription,
        metadata: ["action": RookRecoveryAction.escalateDeliberation.rawValue]
      )
      let quick = LocalRookRouter.centralHandoff(
        displayText: "Central Rook is taking a deeper look."
      ).response
      dashboardModel.presentQuick(quick, requestID: id, command: displayCommand)
      lastResponse = quick.immediateResponse
      lastResponseMenuItem.isEnabled = true
      launchDeliberation(
        id: id,
        displayCommand: displayCommand,
        effectiveCommand: effectiveCommand,
        quick: quick,
        workspacePath: workspacePath
      )
      setStatus(backgroundStatus())
      speakResponse(quick.spokenText)
    }
  }

  private func launchStreamingAnswer(id: UUID, displayCommand: String, effectiveCommand: String) {
    traceAdapterStart(id: id, route: "stream", adapter: "codex_stream")
    activeStreamingRequests[id] = displayCommand
    streamingClient.answer(
      id: id,
      command: effectiveCommand,
      contextSnapshot: library.contextSnapshot(for: effectiveCommand),
      onDelta: { [weak self] delta in
        DispatchQueue.main.async {
          self?.dashboardModel.appendStreamingText(delta, requestID: id)
        }
      },
      completion: { [weak self] result in
        DispatchQueue.main.async {
          self?.handleStreamingResult(
            result,
            id: id,
            displayCommand: displayCommand,
            effectiveCommand: effectiveCommand
          )
        }
      }
    )
  }

  private func handleStreamingResult(
    _ result: Result<String, Error>,
    id: UUID,
    displayCommand: String,
    effectiveCommand: String
  ) {
    switch result {
    case .success(let text):
      finishStreamingAnswer(text, id: id, command: displayCommand)
    case .failure(let error):
      trace(
        id: id,
        stage: .recoverySelected,
        status: .started,
        component: "recovery_policy",
        detail: RookFailureCategory.executionFailed.rawValue,
        metadata: ["action": RookRecoveryAction.retrySameAdapter.rawValue]
      )
      runFallbackAnswer(
        id: id,
        displayCommand: displayCommand,
        effectiveCommand: effectiveCommand,
        originalError: error
      )
    }
  }

  private func runFallbackAnswer(
    id: UUID,
    displayCommand: String,
    effectiveCommand: String,
    originalError: Error
  ) {
    let bridge = self.bridge!
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      do {
        let fallback = try bridge.runQuick(command: effectiveCommand)
        DispatchQueue.main.async {
          self?.finishStreamingAnswer(fallback.displayText, id: id, command: displayCommand)
        }
      } catch {
        DispatchQueue.main.async {
          guard let self else { return }
          self.activeStreamingRequests.removeValue(forKey: id)
          let reason =
            "Live answer failed: \(originalError.localizedDescription). Fallback failed: \(error.localizedDescription)"
          self.traceFailure(id: id, message: reason, capability: nil)
          _ = try? self.library.failTurn(
            id: id,
            command: displayCommand,
            route: LocalRookDestination.stream.rawValue,
            displayText: "Rook could not finish the answer.",
            reason: reason,
            pawns: []
          )
          let isLatest = self.dashboardModel.failStreaming(
            command: displayCommand,
            requestID: id,
            reason: reason
          )
          self.dashboardModel.refreshLibrary()
          self.setStatus(self.backgroundStatus(fallback: "Rook error — see log"))
          if isLatest { self.speakResponse("I couldn't finish that answer. Try it once more.") }
        }
      }
    }
  }

  private func finishStreamingAnswer(_ text: String, id: UUID, command: String) {
    traceExternalOutcome(id: id, route: "stream", adapter: "codex_stream", verified: false)
    activeStreamingRequests.removeValue(forKey: id)
    let spoken = spokenSummary(from: text)
    let response = RookResponse(
      displayText: text,
      spokenText: spoken,
      intent: "answer",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    _ = try? library.finishTurn(
      id: id,
      command: command,
      route: LocalRookDestination.stream.rawValue,
      displayText: text,
      pawns: []
    )
    let isLatest = dashboardModel.completeStreaming(text, command: command, requestID: id)
    dashboardModel.refreshLibrary()
    if isLatest {
      lastResponse = response
      persistLastResponse(response, command: command, route: LocalRookDestination.stream.rawValue)
    }
    lastResponseMenuItem.isEnabled = true
    setStatus(backgroundStatus())
    speakResponse(spoken)
    finishTrace(id: id, outcome: .succeeded, verified: false)
  }

  private func launchTaskExecution(
    id: UUID,
    displayCommand: String,
    effectiveCommand: String,
    quick: QuickRookResponse,
    workspacePath: String?,
    plan: RookHybridCapabilityPlan,
    intentOverrides: [Int: RookSpotifyIntent] = [:]
  ) {
    traceAdapterStart(id: id, route: "hybrid", adapter: "rook_task_executor")
    Task { [weak self] in
      guard let self else { return }
      let execution = await self.taskExecutor.execute(
        plan,
        intentOverrides: intentOverrides
      ) { [weak self] event in
        self?.traceTaskStepEvent(id: id, event: event)
      }

      if execution.canStartDependentWork {
        self.launchDeliberation(
          id: id,
          displayCommand: displayCommand,
          effectiveCommand: effectiveCommand,
          quick: quick,
          workspacePath: workspacePath,
          hybridPlan: plan,
          taskExecution: execution
        )
        self.setStatus(self.backgroundStatus(fallback: "Native steps verified · research running"))
      } else {
        self.finishBlockedTaskExecution(
          execution,
          id: id,
          displayCommand: displayCommand,
          sourceCommand: effectiveCommand,
          quick: quick
        )
      }
    }
  }

  private func finishBlockedTaskExecution(
    _ execution: RookTaskExecutionResult,
    id: UUID,
    displayCommand: String,
    sourceCommand: String,
    quick: QuickRookResponse
  ) {
    let blocking =
      execution.blockingStep
      ?? execution.steps.first(where: { $0.state == .skipped })
    let category = blocking?.failureCategory ?? .dependencyFailed
    let detail =
      blocking?.detail.isEmpty == false
      ? blocking?.detail ?? "A native prerequisite did not complete."
      : "A native prerequisite did not complete."
    let recovery =
      blocking?.recovery
      ?? RookRecoveryPolicy.decide(failure: category, capability: .spotify)
    let base = blocking?.response
    let pawnReports = quick.pawns.map {
      PawnReport(
        pawn: $0.pawn,
        task: $0.task,
        status: "blocked",
        id: $0.id,
        result: "Not started because its verified Spotify prerequisite was unavailable.",
        evidence: ["Native task executor stopped at step \(blocking?.order ?? 0)."]
      )
    }
    let response = RookResponse(
      displayText: base?.displayText
        ?? "**Spotify couldn’t finish the prerequisite.** \(detail)\n\nNext step: \(recovery.rationale)",
      spokenText: base?.spokenText
        ?? "I couldn’t verify the Spotify step. Check Rook for the exact next step.",
      intent: base?.intent ?? "error",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: pawnReports,
      canvas: base?.canvas ?? [spotifyTaskErrorCanvas(detail: detail)]
    )
    let archived = try? library.failTurn(
      id: id,
      command: displayCommand,
      route: "spotify_hybrid",
      displayText: response.displayText,
      reason: detail,
      pawns: pawnReports
    )
    let completed = RookResponse(
      displayText: response.displayText,
      spokenText: response.spokenText,
      intent: response.intent,
      requiresApproval: response.requiresApproval,
      queueItemIDs: response.queueItemIDs,
      pawns: archived?.pawns ?? response.pawns,
      canvas: response.canvas
    )
    _ = dashboardModel.completeDeliberation(
      completed,
      command: displayCommand,
      requestID: id
    )
    dashboardModel.refreshLibrary()
    lastResponse = completed
    persistLastResponse(completed, command: sourceCommand, route: "spotify_hybrid")
    lastResponseMenuItem.isEnabled = true
    setStatus(
      completed.intent == "clarification"
        ? "Waiting for one Spotify detail" : backgroundStatus(fallback: "Spotify needs attention")
    )
    speakResponse(completed.spokenText)
    traceFailure(id: id, message: detail, capability: .spotify)
  }

  private func spotifyTaskErrorCanvas(detail: String) -> RookCanvasBlock {
    RookCanvasBlock(
      id: "spotify_task_error",
      kind: .spotify,
      title: "Spotify task",
      subtitle: "Dependent work stopped",
      asOf: ISO8601DateFormatter().string(from: Date()),
      items: [
        RookCanvasItem(
          id: "spotify_task_issue",
          label: "Native prerequisite",
          detail: detail,
          value: "Not verified",
          symbol: .warning
        )
      ],
      sourceLabel: "Spotify",
      sourceURL: "https://open.spotify.com"
    )
  }

  private func launchDeliberation(
    id: UUID,
    displayCommand: String,
    effectiveCommand: String,
    quick: QuickRookResponse,
    workspacePath: String?,
    screenCapture: RookScreenCaptureResult? = nil,
    hybridPlan: RookHybridCapabilityPlan? = nil,
    taskExecution: RookTaskExecutionResult? = nil
  ) {
    if quick.intent == "coding", hybridPlan == nil, taskExecution == nil {
      launchCodingTask(
        id: id,
        displayCommand: displayCommand,
        effectiveCommand: effectiveCommand,
        workspacePath: workspacePath
      )
      return
    }
    traceAdapterStart(
      id: id,
      route: hybridPlan == nil ? "deliberate" : "hybrid",
      adapter: hybridPlan?.requiresComputerOperator == true ? "central_rook_operator" : "central_rook_codex"
    )
    let request = DeliberationRequest(
      id: id,
      displayCommand: displayCommand,
      effectiveCommand: effectiveCommand,
      quick: quick,
      workspacePath: workspacePath,
      screenCapture: screenCapture,
      hybridPlan: hybridPlan,
      taskExecution: taskExecution
    )
    activeDeliberations[id] = request
    dashboardModel.markDeliberationActive(requestID: id)
    let bridge = self.bridge!
    let contextSnapshot = library.contextSnapshot(for: effectiveCommand)

    deliberationQueue.async { [weak self] in
      guard let self else { return }
      do {
        let response = try bridge.runDeep(
          command: request.effectiveCommand,
          initial: request.quick,
          requestID: request.id,
          contextSnapshot: contextSnapshot,
          workspacePath: request.workspacePath,
          inputImageAssetIDs: request.screenCapture.map { [$0.assetID] } ?? [],
          inputImageDescriptions: request.screenCapture.map {
            ["A fresh private local capture of \($0.targetLabel), attached as live visual evidence for this request."]
          } ?? [],
          hybridPlan: request.hybridPlan,
          taskExecution: request.taskExecution
        )
        DispatchQueue.main.async {
          self.activeDeliberations.removeValue(forKey: request.id)
          let nativeResponse = request.taskExecution?.latestNativeResponse
          let verifiedTrack = request.taskExecution?.verifiedEvidence
            .compactMap { $0.evidence?.values["track"] }
            .last
          let shouldPrependNative =
            nativeResponse != nil
            && !(verifiedTrack.map { response.displayText.localizedCaseInsensitiveContains($0) } ?? false)
          let completedDisplayText =
            shouldPrependNative
            ? "\(nativeResponse?.displayText ?? "")\n\n\(response.displayText)"
            : response.displayText
          let archived: RookLibraryEntry?
          if response.intent == "error" {
            archived = try? self.library.failTurn(
              id: request.id,
              command: request.displayCommand,
              route: LocalRookDestination.deliberate.rawValue,
              displayText: completedDisplayText,
              reason: response.spokenText.isEmpty
                ? "Rook reported that the request did not complete." : response.spokenText,
              pawns: response.pawns
            )
          } else {
            archived = try? self.library.finishTurn(
              id: request.id,
              command: request.displayCommand,
              route: LocalRookDestination.deliberate.rawValue,
              displayText: completedDisplayText,
              pawns: response.pawns
            )
          }
          var completedCanvas = response.canvas
          if let nativeCanvas = nativeResponse?.canvas.first {
            completedCanvas.removeAll { $0.id == nativeCanvas.id }
            completedCanvas.insert(nativeCanvas, at: 0)
            completedCanvas = Array(completedCanvas.prefix(3))
          }
          if let capture = request.screenCapture {
            completedCanvas.removeAll { $0.kind == .image && $0.imageAssetID == capture.assetID }
            completedCanvas.insert(self.screenCaptureCanvas(for: capture), at: 0)
            completedCanvas = Array(completedCanvas.prefix(3))
          }
          let completedResponse = RookResponse(
            displayText: completedDisplayText,
            spokenText: response.spokenText,
            intent: response.intent,
            requiresApproval: response.requiresApproval,
            queueItemIDs: response.queueItemIDs,
            pawns: archived?.pawns ?? response.pawns,
            canvas: completedCanvas
          )
          self.dashboardModel.refreshLibrary()
          let isLatest = self.dashboardModel.completeDeliberation(
            completedResponse,
            command: request.displayCommand,
            requestID: request.id
          )
          if isLatest {
            self.lastResponse = completedResponse
            self.persistLastResponse(
              completedResponse,
              command: request.displayCommand,
              route: LocalRookDestination.deliberate.rawValue
            )
          }
          self.completeVerifiedQueueItems(from: completedResponse)
          self.lastResponseMenuItem.isEnabled = true
          self.setStatus(
            completedResponse.requiresApproval
              ? "Move waiting for review"
              : self.backgroundStatus(
                fallback: completedResponse.intent == "error" ? "Request blocked" : "Synthesis ready"
              ))
          self.speakResponse(completedResponse.spokenText)
          if completedResponse.intent == "error" {
            self.traceFailure(
              id: request.id,
              message: "\(completedResponse.displayText) \(completedResponse.spokenText)",
              capability: request.hybridPlan?.centralCapabilities.first
            )
          } else {
            self.traceExternalOutcome(
              id: request.id,
              route: request.hybridPlan == nil ? "deliberate" : "hybrid",
              adapter: request.hybridPlan?.requiresComputerOperator == true
                ? "central_rook_operator" : "central_rook_codex",
              verified: false
            )
            self.finishTrace(id: request.id, outcome: .succeeded, verified: false)
          }
        }
      } catch {
        DispatchQueue.main.async {
          self.activeDeliberations.removeValue(forKey: request.id)
          let reason = error.localizedDescription
          self.traceFailure(
            id: request.id,
            message: reason,
            capability: request.hybridPlan?.centralCapabilities.first
          )
          let archived = try? self.library.failTurn(
            id: request.id,
            command: request.displayCommand,
            route: LocalRookDestination.deliberate.rawValue,
            displayText: request.quick.displayText,
            reason: reason,
            pawns: request.quick.immediateResponse.pawns
          )
          self.dashboardModel.failDeliberation(
            command: request.displayCommand,
            requestID: request.id,
            reason: reason,
            archivedReports: archived?.pawns
          )
          self.dashboardModel.refreshLibrary()
          self.setStatus(self.backgroundStatus(fallback: "Pawn deliberation blocked — see log"))
          self.speakResponse("I answered quickly, but the deeper pass hit a local error.")
        }
      }
    }
  }

  private func launchCodingTask(
    id: UUID,
    displayCommand: String,
    effectiveCommand: String,
    workspacePath: String?
  ) {
    guard let workspacePath else {
      finishCodingWorkspaceClarification(id: id, displayCommand: displayCommand)
      return
    }

    let request = CodingTaskRequest(
      id: id,
      displayCommand: displayCommand,
      effectiveCommand: effectiveCommand,
      workspacePath: workspacePath
    )
    do {
      _ = try codingTaskStore.begin(
        requestID: id,
        command: effectiveCommand,
        workspacePath: workspacePath
      )
    } catch {
      finishCodingTaskFailure(request: request, error: error)
      return
    }

    activeCodingTasks[id] = request
    dashboardModel.markCodingTaskActive(
      requestID: id,
      workspaceName: URL(fileURLWithPath: workspacePath).lastPathComponent
    )
    traceAdapterStart(id: id, route: "codex_task", adapter: "full_codex_task")
    setStatus(backgroundStatus())

    let config = self.config!
    let store = self.codingTaskStore!
    let contextSnapshot = library.contextSnapshot(for: effectiveCommand)
    deliberationQueue.async { [weak self] in
      guard let self else { return }
      do {
        let result = try RookCodingTaskClient(config: config, store: store).run(
          requestID: request.id,
          command: request.effectiveCommand,
          contextSnapshot: contextSnapshot,
          workspacePath: request.workspacePath
        ) { [weak self] progress in
          DispatchQueue.main.async {
            self?.handleCodingTaskProgress(progress, requestID: request.id)
          }
        }
        DispatchQueue.main.async {
          self.finishCodingTask(result, request: request)
        }
      } catch {
        DispatchQueue.main.async {
          self.finishCodingTaskFailure(request: request, error: error)
        }
      }
    }
  }

  private func handleCodingTaskProgress(_ progress: RookCodingTaskProgress, requestID: UUID) {
    guard activeCodingTasks[requestID] != nil else { return }
    dashboardModel.updateCodingTaskProgress(
      requestID: requestID,
      label: progress.detail,
      taskID: progress.threadID.map { String($0.prefix(8)) }
    )
    setStatus(backgroundStatus())
  }

  private func finishCodingTask(_ result: RookCodingTaskResult, request: CodingTaskRequest) {
    guard activeCodingTasks.removeValue(forKey: request.id) != nil else { return }
    let taskLabel = String(result.threadID.prefix(8))
    let workspaceName = URL(fileURLWithPath: result.workspacePath).lastPathComponent
    let displayText = """
      \(result.finalText)

      ---
      Codex task `\(taskLabel)` is saved in the Codex task list · checkout: `\(workspaceName)`
      """
    let response = RookResponse(
      displayText: displayText,
      spokenText: "The Codex task finished. Its complete result is on screen.",
      intent: "coding",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "codex_task",
          kind: .code,
          title: "Codex task",
          subtitle: "Full coding task in the verified checkout",
          items: [
            RookCanvasItem(
              id: "codex_thread",
              label: "Task",
              detail: "Saved for inspection and continuation in Codex",
              value: taskLabel,
              symbol: .code
            ),
            RookCanvasItem(
              id: "codex_workspace",
              label: "Checkout",
              detail: "Live project workspace",
              value: workspaceName,
              symbol: .code
            ),
          ]
        )
      ]
    )
    let archived = try? library.finishTurn(
      id: request.id,
      command: request.displayCommand,
      route: "codex_task",
      displayText: displayText,
      pawns: []
    )
    let completed = RookResponse(
      displayText: response.displayText,
      spokenText: response.spokenText,
      intent: response.intent,
      requiresApproval: response.requiresApproval,
      queueItemIDs: response.queueItemIDs,
      pawns: archived?.pawns ?? [],
      canvas: response.canvas
    )
    let isLatest = dashboardModel.completeDeliberation(
      completed,
      command: request.displayCommand,
      requestID: request.id
    )
    dashboardModel.refreshLibrary()
    if isLatest {
      lastResponse = completed
      persistLastResponse(completed, command: request.effectiveCommand, route: "codex_task")
      lastResponseMenuItem.isEnabled = true
      speakResponse(completed.spokenText)
    }
    traceExternalOutcome(
      id: request.id,
      route: "codex_task",
      adapter: "full_codex_task",
      verified: false
    )
    finishTrace(id: request.id, outcome: .succeeded, verified: false)
    setStatus(backgroundStatus())
  }

  private func finishCodingTaskFailure(request: CodingTaskRequest, error: Error) {
    activeCodingTasks.removeValue(forKey: request.id)
    _ = try? codingTaskStore.fail(requestID: request.id, reason: error.localizedDescription)
    let response = RookResponse(
      displayText: "The Codex coding task could not finish. \(error.localizedDescription)",
      spokenText: "The Codex task was blocked. The exact reason is on screen.",
      intent: "error",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    let archived = try? library.failTurn(
      id: request.id,
      command: request.displayCommand,
      route: "codex_task",
      displayText: response.displayText,
      reason: error.localizedDescription,
      pawns: []
    )
    _ = dashboardModel.completeDeliberation(
      response,
      command: request.displayCommand,
      requestID: request.id
    )
    dashboardModel.refreshLibrary()
    lastResponse = response
    persistLastResponse(response, command: request.effectiveCommand, route: "codex_task")
    lastResponseMenuItem.isEnabled = true
    setStatus(backgroundStatus(fallback: "Codex task blocked"))
    speakResponse(response.spokenText)
    traceFailure(id: request.id, message: error.localizedDescription, capability: nil)
    _ = archived
  }

  private func finishCodingWorkspaceClarification(id: UUID, displayCommand: String) {
    let response = RookResponse(
      displayText: "Which project or checkout should Codex use? I won't start coding work in a guessed workspace.",
      spokenText: "Which project should Codex use?",
      intent: "clarification",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: []
    )
    _ = try? library.failTurn(
      id: id,
      command: displayCommand,
      route: "codex_task",
      displayText: response.displayText,
      reason: "No unique verified coding workspace was resolved.",
      pawns: []
    )
    _ = dashboardModel.completeDeliberation(response, command: displayCommand, requestID: id)
    dashboardModel.refreshLibrary()
    lastResponse = response
    persistLastResponse(response, command: displayCommand, route: "codex_task")
    lastResponseMenuItem.isEnabled = true
    setStatus(backgroundStatus(fallback: "Waiting for project"))
    speakResponse(response.spokenText)
    traceFailure(id: id, message: "No unique verified coding workspace was resolved.", capability: nil)
  }

  private func beginTrace(
    id: UUID,
    source: RookTaskInputSource,
    command: String = ""
  ) {
    _ = try? traceRecorder.begin(id: id, source: source, command: command)
  }

  private func trace(
    id: UUID,
    stage: RookTaskTraceStage,
    status: RookTaskTraceEventStatus = .informational,
    component: String,
    detail: String = "",
    metadata: [String: String] = [:],
    command: String? = nil,
    effectiveCommand: String? = nil,
    route: String? = nil,
    adapter: String? = nil
  ) {
    try? traceRecorder.record(
      id: id,
      stage: stage,
      status: status,
      component: component,
      detail: detail,
      metadata: metadata,
      command: command,
      effectiveCommand: effectiveCommand,
      route: route,
      adapter: adapter
    )
  }

  private func traceAdapterStart(id: UUID, route: String, adapter: String) {
    trace(
      id: id,
      stage: .adapterStarted,
      status: .started,
      component: adapter,
      detail: "Execution adapter started.",
      route: route,
      adapter: adapter
    )
  }

  private func traceTaskStepEvent(id: UUID, event: RookTaskStepEvent) {
    let step = event.step
    let metadata = [
      "attempt": String(step.attemptCount),
      "state": step.state.rawValue,
      "step": String(step.order),
      "verified": String(step.verified),
    ]
    switch event.kind {
    case .started:
      trace(
        id: id,
        stage: .adapterStarted,
        status: .started,
        component: "spotify_web_api",
        detail: step.clause,
        metadata: metadata,
        route: "hybrid",
        adapter: "rook_task_executor"
      )
    case .retrying:
      trace(
        id: id,
        stage: .recoverySelected,
        status: .started,
        component: "recovery_policy",
        detail: step.recovery?.rationale ?? step.detail,
        metadata: metadata.merging([
          "action": step.recovery?.action.rawValue ?? RookRecoveryAction.retrySameAdapter.rawValue,
          "failure": step.failureCategory?.rawValue ?? RookFailureCategory.unknown.rawValue,
        ]) { _, new in new }
      )
    case .succeeded:
      trace(
        id: id,
        stage: .externalOutcome,
        status: .succeeded,
        component: "spotify_web_api",
        detail: step.detail,
        metadata: metadata,
        route: "hybrid",
        adapter: "rook_task_executor"
      )
      if step.verified {
        trace(
          id: id,
          stage: .confirmation,
          status: .succeeded,
          component: "rook_task_executor",
          detail: "Verified native result accepted for dependent step \(step.order).",
          metadata: metadata
        )
      }
    case .blocked, .failed, .skipped:
      trace(
        id: id,
        stage: .externalOutcome,
        status: event.kind == .blocked ? .blocked : .failed,
        component: step.owner == .central ? "spotify_web_api" : "dependency_gate",
        detail: step.detail,
        metadata: metadata.merging([
          "failure": step.failureCategory?.rawValue ?? RookFailureCategory.unknown.rawValue
        ]) { _, new in new },
        route: "hybrid",
        adapter: "rook_task_executor"
      )
    case .ready:
      trace(
        id: id,
        stage: .confirmation,
        status: .succeeded,
        component: "dependency_gate",
        detail: "Dependent step \(step.order) may start from verified prerequisites.",
        metadata: metadata
      )
    }
  }

  private func traceExternalOutcome(
    id: UUID,
    route: String,
    adapter: String,
    verified: Bool,
    status: RookTaskTraceEventStatus = .succeeded
  ) {
    trace(
      id: id,
      stage: .externalOutcome,
      status: status,
      component: adapter,
      detail: verified ? "Verified outcome received." : "Outcome received without verification.",
      metadata: ["verified": String(verified)],
      route: route,
      adapter: adapter
    )
    if verified {
      trace(
        id: id,
        stage: .confirmation,
        status: .succeeded,
        component: "orchestrator",
        detail: "Verified result accepted for user confirmation."
      )
    }
  }

  private func traceFailure(
    id: UUID,
    message: String,
    capability: RookDirectCapabilityID?
  ) {
    let category = RookFailureClassifier.classify(message)
    let recovery = RookRecoveryPolicy.decide(
      failure: category,
      capability: capability
    )
    trace(
      id: id,
      stage: .externalOutcome,
      status: category == .policyBlocked ? .blocked : .failed,
      component: capability?.rawValue ?? "orchestrator",
      detail: category.rawValue,
      metadata: ["verified": "false"]
    )
    trace(
      id: id,
      stage: .recoverySelected,
      status: .informational,
      component: "recovery_policy",
      detail: recovery.rationale,
      metadata: [
        "action": recovery.action.rawValue,
        "failure": category.rawValue,
        "retry_limit": String(recovery.retryLimit),
      ]
    )
    let outcome: RookTaskOutcomeStatus
    switch category {
    case .ambiguity:
      outcome = .clarified
    case .authentication, .permission, .policyBlocked, .dependencyFailed:
      outcome = .blocked
    default:
      outcome = .failed
    }
    try? traceRecorder.finish(
      id: id,
      outcome: outcome,
      verified: false,
      failureCategory: category,
      detail: recovery.action.rawValue
    )
  }

  private func finishTrace(id: UUID, outcome: RookTaskOutcomeStatus, verified: Bool) {
    try? traceRecorder.finish(id: id, outcome: outcome, verified: verified)
  }

  private func backgroundStatus(fallback: String = "Ready") -> String {
    var work: [String] = []
    let answerCount = activeStreamingRequests.count
    let centralCount = activeCentralDelegations.count
    let crewCount = activeDeliberations.count
    let codingCount = activeCodingTasks.count
    if answerCount > 0 { work.append("\(answerCount) live answer\(answerCount == 1 ? "" : "s")") }
    if centralCount > 0 { work.append("\(centralCount) Central decision\(centralCount == 1 ? "" : "s")") }
    if crewCount > 0 { work.append("\(crewCount) crew\(crewCount == 1 ? "" : "s") working") }
    if codingCount > 0 { work.append("\(codingCount) Codex task\(codingCount == 1 ? "" : "s")") }
    return work.isEmpty ? fallback : "Ready · " + work.joined(separator: " · ")
  }

  private func installLibrarianTimer() {
    librarianTimer?.invalidate()
    librarianTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshLibrarianContext() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      self?.refreshLibrarianContext()
    }
  }

  private func refreshLibrarianContext(force: Bool = false) {
    guard !previewMode,
      !isLibrarianRefreshing,
      force || !library.isCheckpointFresh(),
      force || (lastLibrarianAttempt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true),
      activeStreamingRequests.isEmpty,
      activeCentralDelegations.isEmpty,
      activeDeliberations.isEmpty,
      activeCodingTasks.isEmpty,
      !isSpeakingResponse,
      dashboardModel.voicePhase == .waiting || dashboardModel.voicePhase == .paused
    else { return }

    isLibrarianRefreshing = true
    lastLibrarianAttempt = Date()
    dashboardModel.beginLibrarianRefresh()
    let bridge = self.bridge!
    let library = self.library!
    let previous = library.latestCheckpoint()
    let preferences = library.activePreferences()
    librarianQueue.async { [weak self] in
      do {
        let checkpoint = try bridge.runCheckpoint(
          previousCheck: previous,
          activePreferences: preferences
        )
        try library.storeCheckpoint(checkpoint)
        DispatchQueue.main.async {
          guard let self else { return }
          self.isLibrarianRefreshing = false
          self.dashboardModel.completeLibrarianRefresh(checkpoint)
          self.setStatus(
            self.backgroundStatus(fallback: "Ready · context checked \(self.checkpointTime(checkpoint.checkedAt))"))
        }
      } catch {
        DispatchQueue.main.async {
          guard let self else { return }
          self.isLibrarianRefreshing = false
          self.dashboardModel.failLibrarianRefresh(reason: error.localizedDescription)
          self.setStatus(self.backgroundStatus(fallback: "Ready · context refresh will retry"))
        }
      }
    }
  }

  private func checkpointTime(_ value: String) -> String {
    let iso = ISO8601DateFormatter()
    guard let date = iso.date(from: value) else { return value }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "America/New_York")
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
  }

  private func spokenSummary(from markdown: String) -> String {
    let cleaned =
      markdown
      .replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
      .replacingOccurrences(of: "[#*_`>|\\[\\]()]", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count > 320 else { return cleaned }
    let prefix = String(cleaned.prefix(317))
    if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
      return String(prefix[...sentenceEnd])
    }
    return prefix + "…"
  }

  private func persistLastResponse(
    _ response: RookResponse,
    command: String? = nil,
    route: String? = nil
  ) {
    try? RookConfig.writePrivate(Data(response.displayText.utf8), to: config.lastResponseURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(response) {
      try? RookConfig.writePrivate(data, to: config.lastResponseJSONURL)
    }
    guard let command, let route else { return }
    if let pending = RookPendingConversationDetector.detect(
      response: response,
      sourceCommand: command,
      route: route
    ) {
      pendingConversationStore.set(pending)
    } else {
      pendingConversationStore.clear()
    }
  }

  private func screenCaptureCanvas(for capture: RookScreenCaptureResult) -> RookCanvasBlock {
    RookCanvasBlock(
      id: "screen_capture",
      kind: .image,
      title: capture.targetLabel,
      subtitle: "Private local capture",
      imageAssetID: capture.assetID,
      caption: capture.caption,
      sourceLabel: "This Mac"
    )
  }

  private func speakResponse(_ text: String) {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }
    speechQueue.append(cleaned)
    drainSpeechQueue()
  }

  private func drainSpeechQueue() {
    guard !isSpeakingResponse, !speechQueue.isEmpty else { return }
    isSpeakingResponse = true
    let text = speechQueue.removeFirst()
    voice.speak(text) { [weak self] in
      guard let self else { return }
      self.isSpeakingResponse = false
      // VoiceController resumes listening after invoking this callback.
      // Drain on the next main-loop turn so a queued synthesis starts cleanly.
      DispatchQueue.main.async { [weak self] in self?.drainSpeechQueue() }
    }
  }

  private func setStatus(_ value: String) {
    statusMenuItem?.title = value
    statusItem?.button?.toolTip = "Rook — \(value)"
    dashboardModel?.updateStatus(value)
    guard config != nil, !previewMode else { return }
    if let data = try? JSONSerialization.data(
      withJSONObject: [
        "status": value,
        "updated_at": ISO8601DateFormatter().string(from: Date()),
        "pid": ProcessInfo.processInfo.processIdentifier,
      ],
      options: [.prettyPrinted, .sortedKeys]
    ) {
      try? RookConfig.writePrivate(data, to: config.statusURL)
    }
  }

  @objc private func toggleListening() {
    let enable = !voice.listeningEnabled
    voice.setListening(enabled: enable)
    listeningMenuItem.title = enable ? "Pause Listening" : "Resume Listening"
  }

  @objc private func toggleFluidTranscriptionTrial() {
    let enable = !voice.fluidTranscriptionTrialEnabled
    voice.setFluidTranscriptionTrial(enabled: enable)
    fluidTranscriptionMenuItem.state = enable ? .on : .off
    setStatus(
      enable
        ? "FluidAudio transcription trial on — preparing locally"
        : "FluidAudio trial off — Apple transcription active"
    )
  }

  @objc private func requestVoicePermissions() {
    showPermissionIntro()
  }

  @objc private func openComputerControlSetup() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Enable Rook Screen & Computer Access"
    alert.informativeText =
      "Screenshots and visual window inspection need Screen & System Audio Recording access. Clicking and typing in apps need Accessibility access. Rook captures only when you explicitly ask, stores the image privately on this Mac, and attaches it only to your authenticated central Rook request."
    alert.addButton(withTitle: CGPreflightScreenCaptureAccess() ? "Screen Capture Enabled" : "Allow Screen Capture")
    alert.addButton(withTitle: "Open Accessibility")
    alert.addButton(withTitle: "Done")
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
      guard !CGPreflightScreenCaptureAccess() else { return }
      if !CGRequestScreenCaptureAccess(),
        let url = URL(
          string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
      {
        NSWorkspace.shared.open(url)
      }
    } else if response == .alertSecondButtonReturn,
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func openWeatherSetup() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Enable Instant Weather"
    alert.informativeText =
      "Rook uses an approximate location to warm a private ten-minute weather cache. Location stays in Rook’s private local state; coordinates are sent only to Open-Meteo for the forecast."
    alert.addButton(withTitle: "Open Location Settings")
    alert.addButton(withTitle: "Refresh Weather")
    let response = alert.runModal()
    if response == .alertFirstButtonReturn,
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")
    {
      NSWorkspace.shared.open(url)
    } else if response == .alertSecondButtonReturn {
      weatherService.start()
    }
  }

  @objc private func openDashboard() {
    dashboardModel.refreshFromDisk()
    rookWindowController.showRook()
  }

  @objc private func listenNow() {
    rookWindowController.showRook()
    voice.promptForCommand()
  }

  @objc private func typeCommand() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Ask Rook"
    alert.informativeText = "This uses the same central Rook and approval rules as voice input."
    alert.addButton(withTitle: "Ask")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
    field.placeholderString = "What should Rook handle?"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    voice.submitTextCommand(field.stringValue)
    rookWindowController.showRook()
  }

  @objc private func pairIPhone() {
    NSApp.activate(ignoringOtherApps: true)
    guard let mobileBridge else {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "iPhone pairing is unavailable"
      alert.informativeText = "Restart Rook, then try Pair iPhone again."
      alert.runModal()
      return
    }

    do {
      let offer = try mobileBridge.beginPairing()
      guard let url = offer.payload.url, let qrImage = pairingQRCode(for: url.absoluteString) else {
        throw RookMobilePairingPayloadError.invalidCode
      }

      let imageView = NSImageView(frame: NSRect(x: 0, y: 44, width: 260, height: 260))
      imageView.image = qrImage
      imageView.imageScaling = .scaleProportionallyUpOrDown

      let codeLabel = NSTextField(labelWithString: offer.oneTimeCode)
      codeLabel.alignment = .center
      codeLabel.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
      codeLabel.frame = NSRect(x: 0, y: 4, width: 260, height: 32)

      let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 304))
      accessory.addSubview(imageView)
      accessory.addSubview(codeLabel)

      let alert = NSAlert()
      alert.messageText = "Pair Rook with your iPhone"
      alert.informativeText =
        "Open Rook on your iPhone and scan this code while both devices are on the same Wi-Fi network. The code expires in five minutes. After pairing, Rook reconnects nearby or through its private internet relay when available."
      alert.accessoryView = accessory
      alert.addButton(withTitle: "Done")
      alert.runModal()
      mobileBridge.cancelPairing()
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Rook could not start pairing"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }

  private func pairingQRCode(for value: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(value.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let representation = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: representation.size)
    image.addRepresentation(representation)
    return image
  }

  private func recordMobileMoveDecision(
    _ decision: RookMobileMoveDecision,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void
  ) {
    let script = config.queueScriptPath
    DispatchQueue.global(qos: .userInitiated).async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = [
        script,
        decision.action == .approve ? "approve" : "reject",
        decision.moveID,
        "--note",
        decision.action == .approve
          ? "Approved from the paired Rook iPhone after device authentication."
          : "Rejected from the paired Rook iPhone.",
      ]
      let errorPipe = Pipe()
      process.standardOutput = Pipe()
      process.standardError = errorPipe
      do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
          let message = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          throw NSError(
            domain: "RookMobileMove",
            code: Int(process.terminationStatus),
            userInfo: [
              NSLocalizedDescriptionKey: message?.isEmpty == false ? message! : "The move decision was not recorded."
            ]
          )
        }
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  /// A deep response may identify the exact approved queue item it just
  /// executed. Reconcile that item from trusted native code so the model never
  /// needs shell permission merely to maintain Rook's private queue.
  private func completeVerifiedQueueItems(from response: RookResponse) {
    guard response.intent != "error", !response.requiresApproval, !response.queueItemIDs.isEmpty else { return }
    let itemIDs = response.queueItemIDs.filter {
      $0.range(of: #"^RQ-[0-9]{4}$"#, options: .regularExpression) != nil
    }
    guard !itemIDs.isEmpty else { return }
    let script = config.queueScriptPath
    let result = response.spokenText
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .prefix(240)

    DispatchQueue.global(qos: .utility).async { [weak self] in
      for itemID in itemIDs {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
          script,
          "complete",
          itemID,
          "--result",
          result.isEmpty ? "Executed and verified by central Rook." : String(result),
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
      }
      DispatchQueue.main.async {
        self?.dashboardModel.refreshQueue()
      }
    }
  }

  @objc private func openLastResponse() {
    dashboardModel.selectedSection = .library
    rookWindowController.showRook()
  }

  @objc private func copyLastResponse() {
    let text = lastResponse?.displayText ?? (try? String(contentsOf: config.lastResponseURL, encoding: .utf8))
    guard let text, !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    setStatus("Last response copied")
  }

  @objc private func openRookFolder() {
    NSWorkspace.shared.open(config.libraryURL)
  }

  @objc private func resetConversation() {
    bridge.resetConversation()
    pendingConversationStore.clear()
    streamingClient?.stop()
    for (id, command) in activeCentralDelegations {
      _ = try? library.failTurn(
        id: id,
        command: command,
        route: "central_delegation",
        displayText: "Rook started a fresh conversation before this decision finished.",
        reason: "The Central Rook delegation was cancelled by a conversation reset.",
        pawns: [],
        interrupted: true
      )
    }
    activeCentralDelegations.removeAll()
    dashboardModel.refreshLibrary()
    centralDelegationClient?.stop()
    centralDelegationClient?.start()
    promptPolishClient?.stop()
    promptPolishClient?.start()
    setStatus("Fresh conversation ready")
  }

  @objc private func quit() {
    NSApp.terminate(nil)
  }

  private func showFatal(_ message: String) {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = "Rook could not start"
    alert.informativeText = message
    alert.runModal()
    NSApp.terminate(nil)
  }

  private func showPermissionIntro() {
    setStatus("Waiting for voice setup")
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Enable Rook Voice"
    alert.informativeText =
      "Rook needs Microphone and Speech Recognition access to hear “\(config.wakePhrase).” For instant local weather, it will also request approximate Location access after voice setup. Audio stays on this Mac when on-device recognition is available."
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Not Now")

    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      if response == .alertFirstButtonReturn {
        self.voice.requestPermissionsAndStart()
      } else {
        self.setStatus("Voice permissions required")
        self.weatherService.start()
      }
    }

    if let window = rookWindowController.window {
      alert.beginSheetModal(for: window, completionHandler: completion)
    } else {
      completion(alert.runModal())
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    rookWindowController.showRook()
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    librarianTimer?.invalidate()
    weatherService?.stop()
    try? library?.recoverInterrupted(reason: "Rook quit before this request finished.")
    streamingClient?.stop()
    centralDelegationClient?.stop()
    promptPolishClient?.stop()
  }
}
