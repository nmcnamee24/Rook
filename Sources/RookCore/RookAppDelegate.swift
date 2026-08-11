import AppKit
import AVFoundation
import Foundation
import RookKit
import Speech

@MainActor
final class RookAppDelegate: NSObject, NSApplicationDelegate {
    private struct DeliberationRequest: Sendable {
        let id: UUID
        let command: String
        let quick: QuickRookResponse
    }

    private let previewMode: Bool
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var listeningMenuItem: NSMenuItem!
    private var lastResponseMenuItem: NSMenuItem!
    private var config: RookConfig!
    private var bridge: CodexBridge!
    private var computerController: RookComputerController!
    private var reflexController: RookReflexController!
    private var weatherService: RookWeatherService!
    private var library: RookLibrary!
    private var streamingClient: RookStreamingClient!
    private var voice: VoiceController!
    private var lastResponse: RookResponse?
    private var dashboardModel: RookDashboardModel!
    private var rookWindowController: RookWindowController!
    private var activeStreamingRequests: [UUID: String] = [:]
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
        } catch {
            showFatal("Rook could not create its private state folder: \(error.localizedDescription)")
            return
        }
        bridge = CodexBridge(config: config)
        computerController = RookComputerController()
        reflexController = RookReflexController(config: config)
        weatherService = RookWeatherService(config: config)
        if !previewMode {
            streamingClient = RookStreamingClient(config: config)
            streamingClient.start()
        }
        dashboardModel = RookDashboardModel(config: config, previewMode: previewMode)
        rookWindowController = RookWindowController(model: dashboardModel)
        buildMenu()

        voice = VoiceController(config: config)
        voice.onStatus = { [weak self] status in self?.setStatus(status) }
        voice.onCommand = { [weak self] command in self?.process(command: command) }
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
            dashboardModel.onRefreshLibrarian = { [weak self] in self?.setStatus("Preview context refresh") }
        } else {
            dashboardModel.onListenNow = { [weak self] in self?.voice.promptForCommand() }
            dashboardModel.onSubmitCommand = { [weak self] command in self?.voice.submitTextCommand(command) }
            dashboardModel.onSpeak = { [weak self] text in self?.voice.speak(text) }
            dashboardModel.onToggleListening = { [weak self] in self?.toggleListening() }
            dashboardModel.onOpenLibraryFolder = { [weak self] in self?.openRookFolder() }
            dashboardModel.onOpenLibraryEntryFolder = { entry in
                NSWorkspace.shared.open(URL(fileURLWithPath: entry.conversationFolder, isDirectory: true))
            }
            dashboardModel.onRefreshLibrarian = { [weak self] in self?.refreshLibrarianContext(force: true) }
        }

        NSApp.setActivationPolicy(previewMode ? .regular : .accessory)
        rookWindowController.showRook()

        if previewMode {
            setStatus("Listening for “\(config.wakePhrase)”")
            return
        }

        reflexController.start()
        installLibrarianTimer()

        let needsOnboarding = SFSpeechRecognizer.authorizationStatus() == .notDetermined ||
            AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
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

        let permissionsItem = NSMenuItem(title: "Voice Permissions…", action: #selector(requestVoicePermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let computerPermissionsItem = NSMenuItem(title: "Computer Control Setup…", action: #selector(openComputerControlSetup), keyEquivalent: "")
        computerPermissionsItem.target = self
        menu.addItem(computerPermissionsItem)

        let weatherPermissionsItem = NSMenuItem(title: "Instant Weather Setup…", action: #selector(openWeatherSetup), keyEquivalent: "")
        weatherPermissionsItem.target = self
        menu.addItem(weatherPermissionsItem)

        let listenNowItem = NSMenuItem(title: "Listen Now / Test Voice", action: #selector(listenNow), keyEquivalent: "l")
        listenNowItem.target = self
        menu.addItem(listenNowItem)

        let typeItem = NSMenuItem(title: "Type a Command…", action: #selector(typeCommand), keyEquivalent: "t")
        typeItem.target = self
        menu.addItem(typeItem)

        lastResponseMenuItem = NSMenuItem(title: "Open Last Response", action: #selector(openLastResponse), keyEquivalent: "o")
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
        let resetItem = NSMenuItem(title: "Start a Fresh Conversation", action: #selector(resetConversation), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let quitItem = NSMenuItem(title: "Quit Rook", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func process(command: String) {
        if let intent = RookReflexCommandParser.parse(command) {
            processReflexCommand(command, intent: intent)
            return
        }

        if let request = RookWeatherCommandParser.parse(command) {
            processWeatherCommand(command, request: request)
            return
        }

        if let intent = RookComputerCommandParser.parse(command) {
            processNativeComputerCommand(command, intent: intent)
            return
        }

        let requestID = UUID()
        let decision = library.cachedOperationalDecision(for: command) ?? LocalRookRouter.route(command)
        let immediate = decision.response.immediateResponse
        _ = try? library.beginTurn(
            id: requestID,
            command: command,
            route: decision.destination.rawValue,
            pawns: decision.response.pawns
        )
        dashboardModel.refreshLibrary()
        dashboardModel.beginRequest(id: requestID, command: command)
        dashboardModel.presentLocal(decision, requestID: requestID, command: command)
        lastResponse = immediate
        lastResponseMenuItem.isEnabled = true

        switch decision.destination {
        case .instant:
            persistLastResponse(immediate)
            _ = try? library.finishTurn(
                id: requestID,
                command: command,
                route: decision.destination.rawValue,
                displayText: immediate.displayText,
                pawns: []
            )
            dashboardModel.refreshLibrary()
            setStatus(backgroundStatus())
        case .stream:
            launchStreamingAnswer(id: requestID, command: command)
            setStatus(backgroundStatus())
        case .deliberate:
            launchDeliberation(id: requestID, command: command, quick: decision.response)
            setStatus(backgroundStatus())
        }

        speakResponse(decision.response.spokenText)
    }

    private func processReflexCommand(_ command: String, intent: RookReflexIntent) {
        let requestID = UUID()
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
                    self.persistLastResponse(response)
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
                    canvas: [RookCanvasBlock(
                        id: "reflex_error",
                        kind: .list,
                        title: "Rook Reflex",
                        subtitle: "Not completed",
                        items: [RookCanvasItem(
                            id: "reflex_issue",
                            label: "Needs clarification",
                            detail: message,
                            value: "Not completed",
                            symbol: .warning
                        )]
                    )]
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
                    self.persistLastResponse(response)
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
            canvas: [RookCanvasBlock(
                id: "alert_due",
                kind: .list,
                title: title,
                subtitle: "Local Rook alert",
                items: [RookCanvasItem(
                    id: "due_item",
                    label: alert.message,
                    detail: alert.kind.rawValue.capitalized,
                    value: "Now",
                    symbol: .clock
                )]
            )]
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

    private func processWeatherCommand(_ command: String, request: RookWeatherRequest) {
        let requestID = UUID()
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
                    self.persistLastResponse(response)
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
                    canvas: [RookCanvasBlock(
                        id: "weather_error",
                        kind: .weather,
                        title: "Instant weather",
                        subtitle: "Not completed",
                        items: [RookCanvasItem(
                            id: "weather_setup",
                            label: "Location needed",
                            detail: message,
                            value: "Setup",
                            symbol: .warning
                        )]
                    )]
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
                    self.persistLastResponse(response)
                }
                self.lastResponseMenuItem.isEnabled = true
                self.dashboardModel.refreshLibrary()
                self.setStatus(self.backgroundStatus(fallback: "Instant weather needs setup"))
                self.speakResponse(response.spokenText)
            }
        }
    }

    private func processNativeComputerCommand(_ command: String, intent: RookComputerIntent) {
        let requestID = UUID()
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
                    self.persistLastResponse(response)
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
                    canvas: [RookCanvasBlock(
                        id: "computer_error",
                        kind: .computer,
                        title: "Computer control",
                        subtitle: "Not completed",
                        items: [RookCanvasItem(
                            id: "control_error",
                            label: intent.targetLabel,
                            detail: message,
                            value: "Needs attention",
                            symbol: .warning
                        )]
                    )]
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
                    self.persistLastResponse(response)
                }
                self.lastResponseMenuItem.isEnabled = true
                self.dashboardModel.refreshLibrary()
                self.setStatus(self.backgroundStatus(fallback: "Computer control needs attention"))
                self.speakResponse(response.spokenText)
            }
        }
    }

    private func computerCanvas(for execution: RookComputerExecution) -> RookCanvasBlock {
        RookCanvasBlock(
            id: "computer_control",
            kind: .computer,
            title: "Computer control",
            subtitle: "Completed on this Mac",
            items: [RookCanvasItem(
                id: "computer_target",
                label: execution.target,
                detail: execution.detail,
                value: "Done",
                symbol: .computer
            )]
        )
    }

    private func launchStreamingAnswer(id: UUID, command: String) {
        activeStreamingRequests[id] = command
        streamingClient.answer(
            id: id,
            command: command,
            contextSnapshot: library.contextSnapshot(for: command),
            onDelta: { [weak self] delta in
                DispatchQueue.main.async {
                    self?.dashboardModel.appendStreamingText(delta, requestID: id)
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleStreamingResult(result, id: id, command: command)
                }
            }
        )
    }

    private func handleStreamingResult(_ result: Result<String, Error>, id: UUID, command: String) {
        switch result {
        case .success(let text):
            finishStreamingAnswer(text, id: id, command: command)
        case .failure(let error):
            runFallbackAnswer(id: id, command: command, originalError: error)
        }
    }

    private func runFallbackAnswer(id: UUID, command: String, originalError: Error) {
        let bridge = self.bridge!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let fallback = try bridge.runQuick(command: command)
                DispatchQueue.main.async {
                    self?.finishStreamingAnswer(fallback.displayText, id: id, command: command)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.activeStreamingRequests.removeValue(forKey: id)
                    let reason = "Live answer failed: \(originalError.localizedDescription). Fallback failed: \(error.localizedDescription)"
                    _ = try? self.library.failTurn(
                        id: id,
                        command: command,
                        route: LocalRookDestination.stream.rawValue,
                        displayText: "Rook could not finish the answer.",
                        reason: reason,
                        pawns: []
                    )
                    let isLatest = self.dashboardModel.failStreaming(
                        command: command,
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
            persistLastResponse(response)
        }
        lastResponseMenuItem.isEnabled = true
        setStatus(backgroundStatus())
        speakResponse(spoken)
    }

    private func launchDeliberation(id: UUID, command: String, quick: QuickRookResponse) {
        let request = DeliberationRequest(id: id, command: command, quick: quick)
        activeDeliberations[id] = request
        dashboardModel.markDeliberationActive(requestID: id)
        let bridge = self.bridge!
        let contextSnapshot = library.contextSnapshot(for: command)

        deliberationQueue.async { [weak self] in
            guard let self else { return }
            do {
                let response = try bridge.runDeep(
                    command: request.command,
                    initial: request.quick,
                    requestID: request.id,
                    contextSnapshot: contextSnapshot
                )
                DispatchQueue.main.async {
                    self.activeDeliberations.removeValue(forKey: request.id)
                    let archived = try? self.library.finishTurn(
                        id: request.id,
                        command: request.command,
                        route: LocalRookDestination.deliberate.rawValue,
                        displayText: response.displayText,
                        pawns: response.pawns
                    )
                    let completedResponse = RookResponse(
                        displayText: response.displayText,
                        spokenText: response.spokenText,
                        intent: response.intent,
                        requiresApproval: response.requiresApproval,
                        queueItemIDs: response.queueItemIDs,
                        pawns: archived?.pawns ?? response.pawns,
                        canvas: response.canvas
                    )
                    self.dashboardModel.refreshLibrary()
                    let isLatest = self.dashboardModel.completeDeliberation(
                        completedResponse,
                        command: request.command,
                        requestID: request.id
                    )
                    if isLatest {
                        self.lastResponse = completedResponse
                        self.persistLastResponse(completedResponse)
                    }
                    self.lastResponseMenuItem.isEnabled = true
                    self.setStatus(completedResponse.requiresApproval ? "Move waiting for review" : self.backgroundStatus(fallback: "Synthesis ready"))
                    self.speakResponse(completedResponse.spokenText)
                }
            } catch {
                DispatchQueue.main.async {
                    self.activeDeliberations.removeValue(forKey: request.id)
                    let reason = error.localizedDescription
                    let archived = try? self.library.failTurn(
                        id: request.id,
                        command: request.command,
                        route: LocalRookDestination.deliberate.rawValue,
                        displayText: request.quick.displayText,
                        reason: reason,
                        pawns: request.quick.immediateResponse.pawns
                    )
                    self.dashboardModel.failDeliberation(
                        command: request.command,
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
              dashboardModel.voicePhase == .waiting || dashboardModel.voicePhase == .paused else { return }

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
                    self.setStatus(self.backgroundStatus(fallback: "Ready · context checked \(self.checkpointTime(checkpoint.checkedAt))"))
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
        let cleaned = markdown
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

    private func persistLastResponse(_ response: RookResponse) {
        try? RookConfig.writePrivate(Data(response.displayText.utf8), to: config.lastResponseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(response) {
            try? RookConfig.writePrivate(data, to: config.lastResponseJSONURL)
        }
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
        alert.messageText = "Enable Rook Computer Control"
        alert.informativeText = "Opening apps, browser searches, and basic Spotify playback work directly. Screen-aware Operator requests need Accessibility access when macOS prompts. Spotify may also ask whether Rook can automate Spotify."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Done")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openWeatherSetup() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enable Instant Weather"
        alert.informativeText = "Rook uses an approximate location to warm a private ten-minute weather cache. Location stays in Rook’s private local state; coordinates are sent only to Open-Meteo for the forecast."
        alert.addButton(withTitle: "Open Location Settings")
        alert.addButton(withTitle: "Refresh Weather")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
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
        streamingClient?.stop()
        streamingClient?.start()
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
        alert.informativeText = "Rook needs Microphone and Speech Recognition access to hear “\(config.wakePhrase).” For instant local weather, it will also request approximate Location access after voice setup. Audio stays on this Mac when on-device recognition is available."
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
    }
}
