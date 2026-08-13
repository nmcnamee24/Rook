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
  }

  private struct PendingPromptPolish {
    let original: String
    let local: String
    let processingRequestID: UUID
    let deadline: DispatchWorkItem
  }

  private let previewMode: Bool
  private var statusItem: NSStatusItem!
  private var statusMenuItem: NSMenuItem!
  private var listeningMenuItem: NSMenuItem!
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
  private var promptPolishClient: RookStreamingClient!
  private var pendingConversationStore: RookPendingConversationStore!
  private var voice: VoiceController!
  private var lastResponse: RookResponse?
  private var dashboardModel: RookDashboardModel!
  private var rookWindowController: RookWindowController!
  private var activeStreamingRequests: [UUID: String] = [:]
  private var pendingPromptPolishes: [UUID: PendingPromptPolish] = [:]
  private var activeDeliberations: [UUID: DeliberationRequest] = [:]
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
    if !previewMode {
      streamingClient = RookStreamingClient(config: config)
      streamingClient.start()
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
    voice.onCommand = { [weak self] command in self?.polishAndProcess(command: command) }
    voice.onTranscript = { [weak self] transcript in self?.dashboardModel.noteCommand(transcript) }
    voice.onAudioLevel = { [weak self] level in self?.dashboardModel.updateAudioLevel(level) }
    voice.onCaptureProgress = { [weak self] progress in self?.dashboardModel.updateCaptureProgress(progress) }
    voice.onPhase = { [weak self] phase in self?.dashboardModel.updateVoicePhase(phase) }
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
            self?.polishAndProcess(command: command, requestID: requestID)
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

  private func process(command: String, requestID requestedID: UUID? = nil) {
    let requestID = requestedID ?? UUID()
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
      decision = LocalRookRouter.routeAfterDirectCapabilityMiss(
        effectiveCommand,
        capability: capability
      )
    case .unclaimed:
      decision = LocalRookRouter.route(effectiveCommand)
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
    case .stream:
      launchStreamingAnswer(id: requestID, displayCommand: displayCommand, effectiveCommand: effectiveCommand)
      setStatus(backgroundStatus())
    case .deliberate:
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

    speakResponse(decision.response.spokenText)
  }

  private func processPendingCancellation(
    _ command: String,
    pending: RookPendingConversation,
    requestID: UUID
  ) {
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
  }

  private func polishAndProcess(command: String, requestID: UUID? = nil) {
    let local = RookPromptRefiner.refine(command)
    guard !local.isEmpty else { return }
    dashboardModel.noteCommand(local)

    // An answer to Rook's own question should never wait on a prompt-polish
    // model. The pending-context resolver is both faster and more accurate.
    if pendingConversationStore.current() != nil {
      process(command: local, requestID: requestID)
      return
    }

    guard config.promptPolishEnabled,
      promptPolishClient != nil,
      RookPromptRefiner.needsModelPolish(original: command, locallyRefined: local),
      shouldUseModelPromptPolish(local)
    else {
      process(command: local, requestID: requestID)
      return
    }

    let polishRequestID = UUID()
    let processingRequestID = requestID ?? UUID()
    setStatus("Polishing your prompt")
    let deadline = DispatchWorkItem { [weak self] in
      self?.finishPromptPolish(id: polishRequestID, modelCandidate: nil)
    }
    pendingPromptPolishes[polishRequestID] = PendingPromptPolish(
      original: command,
      local: local,
      processingRequestID: processingRequestID,
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
    process(command: polished, requestID: pending.processingRequestID)
  }

  private func processReflexCommand(
    _ command: String,
    intent: RookReflexIntent,
    requestID: UUID
  ) {
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

    reflexController.execute(intent) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let execution):
        let response = RookResponse(
          displayText: execution.displayText,
          spokenText: execution.spokenText,
          intent: "status",
          requiresApproval: false,
          queueItemIDs: [],
          pawns: [],
          canvas: [execution.canvas]
        )
        _ = try? self.library.finishTurn(
          id: requestID,
          command: command,
          route: "reflex_native",
          displayText: execution.displayText,
          pawns: []
        )
        if self.dashboardModel.completeInstant(response, command: command, requestID: requestID) {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "reflex_native")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus())
        self.speakResponse(execution.spokenText)

      case .failure(let error):
        let message = error.localizedDescription
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
        _ = try? self.library.failTurn(
          id: requestID,
          command: command,
          route: "reflex_native",
          displayText: response.displayText,
          reason: message,
          pawns: []
        )
        if self.dashboardModel.completeInstant(response, command: command, requestID: requestID) {
          self.lastResponse = response
          self.persistLastResponse(response, command: command, route: "reflex_native")
        }
        self.lastResponseMenuItem.isEnabled = true
        self.dashboardModel.refreshLibrary()
        self.setStatus(self.backgroundStatus(fallback: "Reflex needs clarification"))
        self.speakResponse(response.spokenText)
      }
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

      case .failure(let error):
        let message = error.localizedDescription
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

      case .failure(let error):
        let message = error.localizedDescription
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
        let response = try await self.spotifyClient.execute(intent)
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
      } catch {
        let message = error.localizedDescription
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
  }

  private func processDirectCapabilityClarification(
    _ command: String,
    capability: RookDirectCapabilityID,
    message: String,
    requestID: UUID
  ) {
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

  private func launchStreamingAnswer(id: UUID, displayCommand: String, effectiveCommand: String) {
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
  }

  private func launchDeliberation(
    id: UUID,
    displayCommand: String,
    effectiveCommand: String,
    quick: QuickRookResponse,
    workspacePath: String?,
    screenCapture: RookScreenCaptureResult? = nil,
    hybridPlan: RookHybridCapabilityPlan? = nil
  ) {
    let request = DeliberationRequest(
      id: id,
      displayCommand: displayCommand,
      effectiveCommand: effectiveCommand,
      quick: quick,
      workspacePath: workspacePath,
      screenCapture: screenCapture,
      hybridPlan: hybridPlan
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
          hybridPlan: request.hybridPlan
        )
        DispatchQueue.main.async {
          self.activeDeliberations.removeValue(forKey: request.id)
          let archived: RookLibraryEntry?
          if response.intent == "error" {
            archived = try? self.library.failTurn(
              id: request.id,
              command: request.displayCommand,
              route: LocalRookDestination.deliberate.rawValue,
              displayText: response.displayText,
              reason: response.spokenText.isEmpty
                ? "Rook reported that the request did not complete." : response.spokenText,
              pawns: response.pawns
            )
          } else {
            archived = try? self.library.finishTurn(
              id: request.id,
              command: request.displayCommand,
              route: LocalRookDestination.deliberate.rawValue,
              displayText: response.displayText,
              pawns: response.pawns
            )
          }
          var completedCanvas = response.canvas
          if let capture = request.screenCapture {
            completedCanvas.removeAll { $0.kind == .image && $0.imageAssetID == capture.assetID }
            completedCanvas.insert(self.screenCaptureCanvas(for: capture), at: 0)
            completedCanvas = Array(completedCanvas.prefix(3))
          }
          let completedResponse = RookResponse(
            displayText: response.displayText,
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
        }
      } catch {
        DispatchQueue.main.async {
          self.activeDeliberations.removeValue(forKey: request.id)
          let reason = error.localizedDescription
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

  private func backgroundStatus(fallback: String = "Ready") -> String {
    var work: [String] = []
    let answerCount = activeStreamingRequests.count
    let crewCount = activeDeliberations.count
    if answerCount > 0 { work.append("\(answerCount) live answer\(answerCount == 1 ? "" : "s")") }
    if crewCount > 0 { work.append("\(crewCount) crew\(crewCount == 1 ? "" : "s") working") }
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
      activeDeliberations.isEmpty,
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
    streamingClient?.start()
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
    promptPolishClient?.stop()
  }
}
