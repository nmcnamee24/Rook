import Combine
import Foundation
import RookKit

struct RookQueueDocument: Decodable {
    let items: [RookQueueItem]
}

struct RookQueueItem: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let label: String?
    let title: String
    let details: String
    let proposedAction: String
    let risk: String
    let status: String
    let createdAt: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case label
        case title
        case details
        case proposedAction = "proposed_action"
        case risk
        case status
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    init(
        id: String,
        kind: String,
        title: String,
        details: String,
        proposedAction: String,
        risk: String,
        status: String,
        createdAt: String,
        expiresAt: String?,
        label: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.title = title
        self.details = details
        self.proposedAction = proposedAction
        self.risk = risk
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    var isVisible: Bool {
        guard status == "pending" || status == "approved" else { return false }
        guard let expiresAt,
              let expiry = ISO8601DateFormatter().date(from: expiresAt) else { return true }
        return expiry > Date()
    }

    var statusLabel: String {
        status.prefix(1).uppercased() + status.dropFirst().replacingOccurrences(of: "_", with: " ")
    }

    var displayLabel: String {
        RookQueueLabel.make(kind: kind, title: title, explicitLabel: label)
    }
}

struct RookTimelineItem: Identifiable, Equatable {
    let id = UUID()
    let time: String
    let title: String
}

enum RookPawnRunStatus: String, Codable {
    case queued
    case working
    case completed
    case blocked
    case interrupted

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .working: return "Working"
        case .completed: return "Complete"
        case .blocked: return "Blocked"
        case .interrupted: return "Interrupted"
        }
    }

    var isActive: Bool { self == .queued || self == .working }
}

struct RookPawnRun: Identifiable, Codable, Equatable {
    let id: UUID
    let command: String
    var status: RookPawnRunStatus
    var pawns: [PawnReport]
    let startedAt: Date
    var updatedAt: Date
    var failureReason: String? = nil
}

private struct RookPawnRunDocument: Codable {
    let runs: [RookPawnRun]
}

@MainActor
final class RookDashboardModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case today = "Today"
        case pawns = "Pawns"
        case library = "Library"
        case queue = "Moves"

        var id: String { rawValue }
    }

    @Published var selectedSection: Section = .today
    @Published private(set) var systemStatus = "Starting Rook"
    @Published private(set) var latestCommand = ""
    @Published private(set) var responseText = "What should we handle?"
    @Published private(set) var responseCanvas: [RookCanvasBlock] = []
    @Published private(set) var spokenText = ""
    @Published private(set) var pawns: [PawnReport] = []
    @Published private(set) var isDeliberating = false
    @Published private(set) var isStreaming = false
    @Published private(set) var deliberationLabel: String?
    @Published private(set) var queueItems: [RookQueueItem] = []
    @Published private(set) var timelineItems: [RookTimelineItem] = []
    @Published private(set) var audioLevels: [CGFloat] = Array(repeating: 0.04, count: 44)
    @Published private(set) var voicePhase: RookVoicePhase = .waiting
    @Published private(set) var captureProgress: CGFloat = 0
    @Published private(set) var pawnRuns: [RookPawnRun] = []
    @Published private(set) var libraryEntries: [RookLibraryEntry] = []
    @Published var selectedLibraryEntryID: UUID?
    @Published private(set) var librarianCheckpoint: RookCheckpoint?
    @Published private(set) var librarianPreferences: [RookPreferenceRecord] = []
    @Published private(set) var librarianPawns: [PawnReport] = []
    @Published private(set) var isLibrarianRefreshing = false
    @Published private(set) var librarianMessage = "Watching context"
    @Published private(set) var librarianError: String?
    @Published var selectedReviewItem: RookQueueItem?

    var onListenNow: (() -> Void)?
    var onSubmitCommand: ((String) -> Void)?
    var onSpeak: ((String) -> Void)?
    var onToggleListening: (() -> Void)?
    var onOpenLibraryFolder: (() -> Void)?
    var onOpenLibraryEntryFolder: ((RookLibraryEntry) -> Void)?
    var onRefreshLibrarian: (() -> Void)?

    private let config: RookConfig
    private let previewMode: Bool
    private let library: RookLibrary?
    private var latestRequestID: UUID?
    private var streamingText: [UUID: String] = [:]

    init(config: RookConfig, previewMode: Bool) {
        self.config = config
        self.previewMode = previewMode
        self.library = try? RookLibrary(config: config)
        if previewMode {
            seedPreviewState()
        } else {
            loadPawnRuns()
            refreshFromDisk()
        }
    }

    var dateHeading: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date()).uppercased()
    }

    var shortStatus: String {
        switch voicePhase {
        case .waiting: return "Ready"
        case .wakeDetected, .capturing: return "Listening"
        case .sending, .processing: return "Answering"
        case .speaking: return "Speaking"
        case .paused: return "Paused"
        case .unavailable: return "Needs attention"
        }
    }

    var isListening: Bool {
        voicePhase == .waiting || voicePhase == .wakeDetected || voicePhase == .capturing
    }

    var voiceInstruction: String {
        switch voicePhase {
        case .waiting: return "Just say “Rook”"
        case .wakeDetected: return "Rook heard you"
        case .capturing: return "Listening…"
        case .sending: return "Got it"
        case .processing: return "Rook is answering"
        case .speaking: return "Rook is speaking"
        case .paused: return "Voice is paused"
        case .unavailable: return "Voice needs attention"
        }
    }

    var voiceDetail: String {
        switch voicePhase {
        case .waiting:
            return "On-device wake and transcription"
        case .wakeDetected:
            return "Start talking — your voice is being tracked"
        case .capturing:
            return "Sends when the ring completes after you pause"
        case .sending:
            return "Command captured"
        case .processing:
            if isDeliberating { return "Local Rook answered while pawns work" }
            if isStreaming { return "The answer appears as Rook writes it" }
            return "Rook is routing this locally"
        case .speaking:
            return "Only central Rook speaks"
        case .paused:
            return "Click the meter to resume"
        case .unavailable:
            return systemStatus
        }
    }

    var captureMeterProgress: CGFloat {
        switch voicePhase {
        case .waiting: return 1
        case .wakeDetected: return 0.08
        case .capturing: return max(0.03, min(captureProgress, 1))
        case .sending, .processing, .speaking: return 1
        case .paused, .unavailable: return 0
        }
    }

    var primaryQueueItem: RookQueueItem? { queueItems.first }

    var activePawnRuns: [RookPawnRun] { pawnRuns.filter { $0.status.isActive } }

    var activePawnCount: Int {
        activePawnRuns.reduce(0) { $0 + $1.pawns.filter { $0.status == "working" || $0.status == "queued" }.count }
    }

    var completedPawnCount: Int {
        pawnRuns.reduce(0) { $0 + $1.pawns.filter { $0.status == "completed" }.count }
    }

    var hasActivePawnRuns: Bool { !activePawnRuns.isEmpty }

    var selectedLibraryEntry: RookLibraryEntry? {
        guard let selectedLibraryEntryID else { return nil }
        return libraryEntries.first { $0.id == selectedLibraryEntryID }
    }

    var activePreferenceCount: Int { librarianPreferences.filter(\.isActive).count }

    var librarianFreshness: String {
        guard let value = librarianCheckpoint?.checkedAt,
              let date = Self.parseISODate(value) else { return "No context check yet" }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "Checked just now" }
        if seconds < 3_600 { return "Checked \(Int(seconds / 60))m ago" }
        return "Checked \(Int(seconds / 3_600))h ago"
    }

    func isLatestRequest(_ id: UUID) -> Bool { latestRequestID == id }

    func beginRequest(id: UUID, command: String) {
        latestRequestID = id
        noteCommand(command)
    }

    func updateStatus(_ value: String) {
        systemStatus = value
    }

    func noteCommand(_ value: String) {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        latestCommand = cleaned
    }

    func presentQuick(_ response: QuickRookResponse, requestID: UUID, command: String) {
        let destination: LocalRookDestination = response.needsDeliberation ? .deliberate : .instant
        presentLocal(
            LocalRookDecision(destination: destination, response: response),
            requestID: requestID,
            command: command
        )
    }

    func presentLocal(_ decision: LocalRookDecision, requestID: UUID, command: String) {
        let response = decision.response
        latestRequestID = requestID
        latestCommand = command
        responseText = response.displayText
        responseCanvas = response.canvas
        spokenText = response.spokenText
        pawns = response.immediateResponse.pawns
        isDeliberating = decision.destination == .deliberate
        isStreaming = decision.destination == .stream
        deliberationLabel = decision.destination == .deliberate
            ? crewLabel(count: response.pawns.count, active: false)
            : (decision.destination == .stream ? "LIVE ANSWER STARTING" : nil)
        timelineItems = []

        if decision.destination == .stream {
            streamingText[requestID] = ""
        }

        if decision.destination == .deliberate {
            let reports = response.pawns.map {
                PawnReport(pawn: $0.pawn, task: $0.task, status: "queued", id: $0.id)
            }
            pawnRuns.insert(
                RookPawnRun(
                    id: requestID,
                    command: command,
                    status: .queued,
                    pawns: reports,
                    startedAt: Date(),
                    updatedAt: Date()
                ),
                at: 0
            )
            trimPawnRuns()
            persistPawnRuns()
        }
        refreshQueue()
    }

    func appendStreamingText(_ delta: String, requestID: UUID) {
        streamingText[requestID, default: ""] += delta
        guard latestRequestID == requestID else { return }
        responseText = streamingText[requestID] ?? delta
        isStreaming = true
        deliberationLabel = "ANSWERING LIVE"
    }

    @discardableResult
    func completeStreaming(_ text: String, command: String, requestID: UUID) -> Bool {
        streamingText.removeValue(forKey: requestID)
        let isLatest = latestRequestID == requestID
        if isLatest {
            latestCommand = command
            responseText = text
            responseCanvas = []
            pawns = []
            isStreaming = false
            isDeliberating = false
            deliberationLabel = nil
        }
        return isLatest
    }

    @discardableResult
    func completeInstant(_ response: RookResponse, command: String, requestID: UUID) -> Bool {
        let isLatest = latestRequestID == requestID
        if isLatest {
            latestCommand = command
            responseText = response.displayText
            responseCanvas = response.canvas
            spokenText = response.spokenText
            pawns = []
            isStreaming = false
            isDeliberating = false
            deliberationLabel = nil
            timelineItems = []
        }
        refreshQueue()
        return isLatest
    }

    @discardableResult
    func failStreaming(
        command: String,
        requestID: UUID,
        reason: String
    ) -> Bool {
        streamingText.removeValue(forKey: requestID)
        let isLatest = latestRequestID == requestID
        if isLatest {
            latestCommand = command
            responseText = "I couldn’t finish that live answer. Try it once more."
            responseCanvas = []
            pawns = []
            isStreaming = false
            isDeliberating = false
            deliberationLabel = nil
        }
        return isLatest
    }

    func markDeliberationActive(requestID: UUID) {
        updateRun(requestID) { run in
            run.status = .working
            run.pawns = run.pawns.map {
                PawnReport(pawn: $0.pawn, task: $0.task, status: "working", id: $0.id)
            }
        }
        if latestRequestID == requestID, let run = pawnRuns.first(where: { $0.id == requestID }) {
            pawns = run.pawns
            isDeliberating = true
            isStreaming = false
            deliberationLabel = crewLabel(count: run.pawns.count, active: true)
        }
    }

    @discardableResult
    func completeDeliberation(_ response: RookResponse, command: String, requestID: UUID) -> Bool {
        updateRun(requestID) { run in
            run.status = .completed
            run.pawns = response.pawns
        }
        let isLatest = latestRequestID == requestID
        if isLatest {
            latestCommand = command
            responseText = response.displayText
            responseCanvas = response.canvas
            spokenText = response.spokenText
            pawns = response.pawns
            isDeliberating = false
            isStreaming = false
            deliberationLabel = response.pawns.isEmpty
                ? "SYNTHESIS READY"
                : "SYNTHESIS READY · \(response.pawns.count) PAWN\(response.pawns.count == 1 ? "" : "S")"
            timelineItems = []
        }
        refreshQueue()
        return isLatest
    }

    @discardableResult
    func failDeliberation(
        command: String,
        requestID: UUID,
        reason: String,
        archivedReports: [PawnReport]? = nil
    ) -> Bool {
        updateRun(requestID) { run in
            run.status = .blocked
            run.failureReason = reason
            run.pawns = archivedReports ?? run.pawns.map {
                PawnReport(
                    pawn: $0.pawn,
                    task: $0.task,
                    status: "blocked",
                    id: $0.id
                )
            }
        }
        let isLatest = latestRequestID == requestID
        if isLatest {
            latestCommand = command
            if let run = pawnRuns.first(where: { $0.id == requestID }) { pawns = run.pawns }
            responseCanvas = []
            isDeliberating = false
            isStreaming = false
            deliberationLabel = "DEEP PASS BLOCKED"
        }
        return isLatest
    }

    private func crewLabel(count: Int, active: Bool) -> String {
        let count = max(count, 1)
        return active
            ? "DELIBERATING · \(count) PAWN\(count == 1 ? "" : "S") WORKING"
            : "ROUTING · \(count) PAWN\(count == 1 ? "" : "S")"
    }

    func updateAudioLevel(_ level: CGFloat) {
        audioLevels.append(max(0.03, min(level, 1)))
        if audioLevels.count > 44 {
            audioLevels.removeFirst(audioLevels.count - 44)
        }
    }

    func updateCaptureProgress(_ progress: CGFloat) {
        captureProgress = max(0, min(progress, 1))
    }

    func updateVoicePhase(_ phase: RookVoicePhase) {
        voicePhase = phase
        if phase == .waiting || phase == .wakeDetected {
            captureProgress = 0
        }
    }

    func submit(_ command: String) {
        let cleaned = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        noteCommand(cleaned)
        onSubmitCommand?(cleaned)
    }

    func listenNow() {
        onListenNow?()
    }

    func toggleListening() {
        onToggleListening?()
    }

    func hearAnswer() {
        guard !spokenText.isEmpty else { return }
        onSpeak?(spokenText)
    }

    private func updateRun(_ id: UUID, mutate: (inout RookPawnRun) -> Void) {
        guard let index = pawnRuns.firstIndex(where: { $0.id == id }) else { return }
        var run = pawnRuns[index]
        mutate(&run)
        run.updatedAt = Date()
        pawnRuns[index] = run
        trimPawnRuns()
        persistPawnRuns()
    }

    private func trimPawnRuns() {
        let sorted = pawnRuns.sorted {
            if $0.status.isActive != $1.status.isActive { return $0.status.isActive }
            return $0.startedAt > $1.startedAt
        }
        let active = sorted.filter { $0.status.isActive }
        let recent = sorted.filter { !$0.status.isActive }.prefix(20)
        pawnRuns = active + Array(recent)
    }

    private func loadPawnRuns() {
        guard let data = try? Data(contentsOf: config.pawnRunsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(RookPawnRunDocument.self, from: data) else { return }
        pawnRuns = document.runs.compactMap { saved in
            let taskPawns = saved.pawns.filter { $0.pawn != "Librarian" }
            guard !taskPawns.isEmpty else { return nil }
            guard saved.status.isActive else {
                var normalized = saved
                normalized.pawns = taskPawns
                return normalized
            }
            return RookPawnRun(
                id: saved.id,
                command: saved.command,
                status: .interrupted,
                pawns: taskPawns.map {
                    PawnReport(pawn: $0.pawn, task: $0.task, status: "blocked", id: $0.id)
                },
                startedAt: saved.startedAt,
                updatedAt: Date(),
                failureReason: "Rook restarted before this request finished."
            )
        }
        trimPawnRuns()
        persistPawnRuns()
    }

    private func persistPawnRuns() {
        guard !previewMode else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(RookPawnRunDocument(runs: pawnRuns)) else { return }
        try? RookConfig.writePrivate(data, to: config.pawnRunsURL)
    }

    func refreshFromDisk() {
        if let data = try? Data(contentsOf: config.lastResponseJSONURL),
           let response = try? JSONDecoder().decode(RookResponse.self, from: data) {
            responseText = response.displayText
            spokenText = response.spokenText
            responseCanvas = response.canvas
        } else if let text = try? String(contentsOf: config.lastResponseURL, encoding: .utf8) {
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { responseText = cleaned }
        }
        refreshQueue()
        refreshLibrary()
    }

    func refreshLibrary() {
        guard !previewMode, let library else { return }
        libraryEntries = library.entries()
        librarianCheckpoint = library.latestCheckpoint()
        librarianPreferences = library.preferences()
        if !isLibrarianRefreshing {
            librarianPawns = librarianCheckpoint?.reportedContextPawns ?? []
        }
        if let selectedLibraryEntryID,
           !libraryEntries.contains(where: { $0.id == selectedLibraryEntryID }) {
            self.selectedLibraryEntryID = nil
        }
    }

    func selectLibraryEntry(_ id: UUID?) {
        selectedLibraryEntryID = id
    }

    func openLibraryFolder() {
        onOpenLibraryFolder?()
    }

    func openSelectedLibraryEntryFolder() {
        guard let entry = selectedLibraryEntry else { return }
        onOpenLibraryEntryFolder?(entry)
    }

    func requestLibrarianRefresh() {
        onRefreshLibrarian?()
    }

    func beginLibrarianRefresh() {
        isLibrarianRefreshing = true
        librarianError = nil
        librarianMessage = "Refreshing context"
        librarianPawns = [
            PawnReport(pawn: "Steward", task: "checking the primary calendar", status: "working", id: "steward_calendar"),
            PawnReport(pawn: "Steward", task: "triaging recent Gmail", status: "working", id: "steward_mail"),
            PawnReport(pawn: "Scout", task: "retrieving useful context and meeting prep", status: "working", id: "scout_context"),
            PawnReport(pawn: "Auditor", task: "checking freshness and claims", status: "working", id: "auditor_context"),
        ]
    }

    func completeLibrarianRefresh(_ checkpoint: RookCheckpoint) {
        librarianCheckpoint = checkpoint
        librarianPawns = checkpoint.reportedContextPawns
        isLibrarianRefreshing = false
        librarianError = nil
        librarianMessage = "Context ready"
        refreshLibrary()
    }

    func failLibrarianRefresh(reason: String) {
        isLibrarianRefreshing = false
        librarianError = reason
        librarianMessage = "Refresh will retry"
        librarianPawns = librarianPawns.map {
            PawnReport(pawn: $0.pawn, task: $0.task, status: "blocked", id: $0.id)
        }
    }

    func refreshQueue() {
        guard !previewMode else { return }
        let url = config.rookWorkspaceURL.appendingPathComponent("action_queue.json")
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(RookQueueDocument.self, from: data) else {
            queueItems = []
            return
        }
        queueItems = document.items
            .filter(\.isVisible)
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    private func seedPreviewState() {
        systemStatus = "Listening for “rook wake up”"
        let activeRequestID = UUID()
        latestRequestID = activeRequestID
        latestCommand = "Make a work block for X, Y, and Z, check my calendar, and create a document"
        responseText = """
        Your best work window is **9:00–11:30 AM**. I kept the hour before your meeting clear so you can prepare without rushing.

        ## Day plan

        - **9:00–11:30** — protected focus block
        - **1:00–2:00** — meeting prep and transition
        - **2:00 PM** — project meeting

        ## Why this works

        The schedule protects a long morning block and avoids stacking work directly against the meeting.
        """
        responseCanvas = [
            RookCanvasBlock(
                id: "weather_preview",
                kind: .weather,
                title: "Three-day forecast",
                subtitle: "New York, NY",
                asOf: ISO8601DateFormatter().string(from: Date()),
                items: [
                    RookCanvasItem(id: "today", label: "Today", detail: "Mostly sunny", value: "82° / 68°", symbol: .sun),
                    RookCanvasItem(id: "wednesday", label: "Wednesday", detail: "Partly cloudy", value: "79° / 66°", symbol: .partlyCloudy),
                    RookCanvasItem(id: "thursday", label: "Thursday", detail: "Afternoon rain", value: "74° / 63°", symbol: .rain),
                ],
                sourceLabel: "Live forecast"
            ),
        ]
        spokenText = "Your best work window is nine to eleven thirty. I kept the hour before your meeting clear."
        pawns = [
            PawnReport(pawn: "Steward", task: "checking the live calendar", status: "working", id: "steward_1"),
            PawnReport(pawn: "Steward", task: "mapping the work-block constraints", status: "working", id: "steward_2"),
            PawnReport(pawn: "Scribe", task: "building the document outline", status: "working", id: "scribe_1"),
            PawnReport(pawn: "Scribe", task: "organizing X, Y, and Z", status: "working", id: "scribe_2"),
            PawnReport(pawn: "Auditor", task: "checking conflicts and completeness", status: "working", id: "auditor_1"),
        ]
        isDeliberating = true
        deliberationLabel = "DELIBERATING · 5 PAWNS WORKING"
        let now = Date()
        pawnRuns = [
            RookPawnRun(
                id: activeRequestID,
                command: latestCommand,
                status: .working,
                pawns: pawns,
                startedAt: now.addingTimeInterval(-48),
                updatedAt: now
            ),
            RookPawnRun(
                id: UUID(),
                command: "Compare the strongest research options and draft a recommendation",
                status: .completed,
                pawns: [
                    PawnReport(pawn: "Scout", task: "compared primary sources", status: "completed", id: "scout_1"),
                    PawnReport(pawn: "Scout", task: "checked competing approaches", status: "completed", id: "scout_2"),
                    PawnReport(pawn: "Auditor", task: "verified the recommendation", status: "completed", id: "auditor_1"),
                ],
                startedAt: now.addingTimeInterval(-900),
                updatedAt: now.addingTimeInterval(-620)
            ),
        ]
        timelineItems = [
            RookTimelineItem(time: "9:00", title: "Focus block"),
            RookTimelineItem(time: "1:00", title: "Meeting prep"),
            RookTimelineItem(time: "2:00", title: "Project meeting"),
        ]
        audioLevels = [
            0.12, 0.24, 0.48, 0.82, 0.56, 0.31, 0.68, 0.91, 0.60, 0.40, 0.24,
            0.18, 0.14, 0.11, 0.09, 0.07, 0.06, 0.05, 0.05, 0.04, 0.04, 0.04,
            0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
            0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04, 0.04,
        ]
        voicePhase = .capturing
        captureProgress = 0.64
        queueItems = [
            RookQueueItem(
                id: "RQ-0042",
                kind: "gmail_draft",
                title: "Draft reply to Maya",
                details: "Prepared for review. No message has been created or sent.",
                proposedAction: "Create a Gmail draft; do not send",
                risk: "medium",
                status: "pending",
                createdAt: ISO8601DateFormatter().string(from: Date()),
                expiresAt: nil,
                label: "Draft meeting notes"
            ),
        ]

        let archived = RookLibraryEntry(
            id: UUID(),
            label: "Move hike time",
            command: "Move my hike to Saturday morning and check for conflicts",
            route: "deliberate",
            status: .completed,
            summary: "Moved the hike into a clear Saturday morning window after checking the primary calendar. The resulting event was read back and verified.",
            failureReason: nil,
            pawns: [
                PawnReport(pawn: "Steward", task: "checked the calendar and updated the event", status: "completed", id: "steward_1"),
                PawnReport(pawn: "Auditor", task: "verified the new time and conflict window", status: "completed", id: "auditor_1"),
            ],
            createdAt: now.addingTimeInterval(-2_400),
            updatedAt: now.addingTimeInterval(-2_100),
            tags: ["calendar", "hike", "completed"],
            conversationFolder: config.libraryConversationsURL.path,
            taskFolder: config.libraryTasksURL.path,
            librarianIndexedAt: now.addingTimeInterval(-2_095)
        )
        let blocked = RookLibraryEntry(
            id: UUID(),
            label: "Draft meeting notes",
            command: "Draft notes for the project meeting and send them",
            route: "deliberate",
            status: .blocked,
            summary: "Prepared the meeting notes, but sending email remained gated for review.",
            failureReason: "Sending Gmail always requires explicit action-time approval.",
            pawns: [
                PawnReport(pawn: "Scribe", task: "drafted concise meeting notes", status: "completed", id: "scribe_1"),
                PawnReport(pawn: "Steward", task: "prepared the Gmail draft", status: "completed", id: "steward_1"),
            ],
            createdAt: now.addingTimeInterval(-7_800),
            updatedAt: now.addingTimeInterval(-7_200),
            tags: ["gmail", "notes", "blocked"],
            conversationFolder: config.libraryConversationsURL.path,
            taskFolder: config.libraryTasksURL.path,
            librarianIndexedAt: now.addingTimeInterval(-7_190)
        )
        libraryEntries = [archived, blocked]
        selectedLibraryEntryID = nil
        librarianCheckpoint = RookCheckpoint(
            checkedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-540)),
            timezone: "America/New_York",
            calendarAsOf: ISO8601DateFormatter().string(from: now.addingTimeInterval(-540)),
            calendarItems: [RookCheckpointEvent(title: "Project meeting", start: "2026-08-11T14:00:00-04:00", end: "2026-08-11T15:00:00-04:00", location: "")],
            gmailAsOf: ISO8601DateFormatter().string(from: now.addingTimeInterval(-540)),
            emailItems: [],
            suggestions: ["Prepare the project brief before 1 PM"],
            preparations: [],
            contextPawns: [
                PawnReport(pawn: "Steward", task: "checked the primary calendar", status: "completed", id: "steward_calendar"),
                PawnReport(pawn: "Steward", task: "triaged recent Gmail", status: "completed", id: "steward_mail"),
                PawnReport(pawn: "Scout", task: "retrieved meeting context", status: "completed", id: "scout_context"),
                PawnReport(pawn: "Auditor", task: "verified freshness and claims", status: "completed", id: "auditor_context"),
            ]
        )
        librarianPawns = librarianCheckpoint?.reportedContextPawns ?? []
        librarianPreferences = [
            RookPreferenceRecord(
                id: "meeting_preparation",
                value: "Prepare a private local brief before upcoming meetings",
                evidenceCount: 2,
                isActive: true,
                isExplicit: false,
                createdAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-3_600),
                evidenceTurnIDs: [archived.id],
                evidenceLabels: [archived.label]
            ),
        ]
    }

    private static func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
