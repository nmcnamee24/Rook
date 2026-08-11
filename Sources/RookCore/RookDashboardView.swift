import RookKit
import SwiftUI

enum RookPalette {
    static let paper = Color(red: 0.984, green: 0.971, blue: 0.949)
    static let paperBright = Color(red: 0.996, green: 0.991, blue: 0.980)
    static let ink = Color(red: 0.075, green: 0.070, blue: 0.066)
    static let muted = Color(red: 0.38, green: 0.37, blue: 0.35)
    static let faint = Color(red: 0.60, green: 0.57, blue: 0.53)
    static let line = Color(red: 0.84, green: 0.81, blue: 0.76)
    static let accent = Color(red: 0.63, green: 0.18, blue: 0.10)
    static let green = Color(red: 0.22, green: 0.60, blue: 0.28)
}

private enum LibraryScope: String, CaseIterable, Identifiable {
    case all = "All"
    case tasks = "Tasks"
    case attention = "Attention"

    var id: String { rawValue }
}

struct RookDashboardView: View {
    @ObservedObject var model: RookDashboardModel
    @State private var typedCommand = ""
    @State private var librarySearch = ""
    @State private var libraryScope: LibraryScope = .all
    @State private var librarianPulse = false
    @FocusState private var commandFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle()
                .fill(RookPalette.line.opacity(0.72))
                .frame(height: 1)
            ZStack(alignment: .bottom) {
                sectionContent
                voiceDock
                    .padding(.horizontal, 72)
                    .padding(.bottom, 30)
            }
        }
        .frame(minWidth: 1_060, minHeight: 720)
        .background(RookPalette.paper.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)
        .sheet(item: $model.selectedReviewItem) { item in
            reviewSheet(item)
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            Text("ROOK")
                .font(.system(size: 25, weight: .medium, design: .serif))
                .tracking(3.5)
                .foregroundStyle(RookPalette.ink)
                .frame(width: 250, alignment: .leading)

            Spacer(minLength: 12)

            HStack(spacing: 30) {
                ForEach(RookDashboardModel.Section.allCases) { section in
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            model.selectedSection = section
                        }
                    } label: {
                        VStack(spacing: 11) {
                            Text(section.rawValue)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(RookPalette.ink)
                            Rectangle()
                                .fill(model.selectedSection == section ? RookPalette.accent : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(section.rawValue)")
                }
            }

            Spacer(minLength: 12)

            Button(action: model.toggleListening) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.isListening ? RookPalette.green : RookPalette.accent)
                        .frame(width: 8, height: 8)
                    Text("Local · \(model.shortStatus)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(model.isListening ? RookPalette.green : RookPalette.accent)
                }
                .frame(width: 250, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help(model.isListening ? "Pause Rook listening" : "Resume Rook listening")
        }
        .padding(.leading, 108)
        .padding(.trailing, 30)
        .padding(.top, 10)
        .frame(height: 54)
        .background(RookPalette.paperBright.opacity(0.78))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.selectedSection {
        case .today:
            todayView
        case .pawns:
            pawnsView
        case .library:
            libraryView
        case .queue:
            queueView
        }
    }

    private var todayView: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                responseCanvas
                    .frame(width: proxy.size.width * 0.69)

                Rectangle()
                    .fill(RookPalette.line.opacity(0.70))
                    .frame(width: 1)

                operationsRail
            }
        }
    }

    private var responseCanvas: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.dateHeading)
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(RookPalette.accent)

                if model.latestCommand.isEmpty {
                    Text("JUST SAY “ROOK”")
                        .font(.system(size: 13, weight: .medium))
                        .tracking(0.7)
                        .foregroundStyle(RookPalette.muted)
                        .padding(.top, 32)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("YOU ASKED")
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(RookPalette.muted)
                        Text("·")
                            .foregroundStyle(RookPalette.faint)
                        Text(model.latestCommand)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(RookPalette.ink)
                            .lineLimit(2)
                    }
                    .padding(.top, 32)
                }

                if model.isStreaming {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(RookPalette.green)
                            .frame(width: 7, height: 7)
                        Text("ROOK IS ANSWERING LIVE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(RookPalette.green)
                    }
                    .padding(.top, 24)
                } else if model.isDeliberating {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(RookPalette.accent)
                            .frame(width: 7, height: 7)
                        Text("ROOK ANSWERED · DEEP PASS CONTINUES")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(RookPalette.accent)
                    }
                    .padding(.top, 24)
                }

                if !model.responseCanvas.isEmpty {
                    RookCanvasView(blocks: model.responseCanvas)
                        .frame(maxWidth: 700, alignment: .leading)
                        .padding(.top, model.isDeliberating || model.isStreaming ? 12 : 24)
                }

                RookMarkdownView(markdown: model.responseText)
                    .frame(maxWidth: 650, alignment: .leading)
                    .padding(.top, model.responseCanvas.isEmpty
                        ? (model.isDeliberating || model.isStreaming ? 12 : 24)
                        : 22)

                if !model.timelineItems.isEmpty {
                    timeline
                        .padding(.top, 36)
                }

                Color.clear.frame(height: 150)
            }
            .padding(.top, 45)
            .padding(.leading, 76)
            .padding(.trailing, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var timeline: some View {
        ZStack(alignment: .topLeading) {
            if model.timelineItems.count > 1 {
                Rectangle()
                    .fill(RookPalette.accent.opacity(0.45))
                    .frame(width: 1, height: CGFloat(model.timelineItems.count - 1) * 54)
                    .offset(x: 10.5, y: 10)
            }

            VStack(alignment: .leading, spacing: 29) {
                ForEach(model.timelineItems) { item in
                    HStack(spacing: 18) {
                        Image(systemName: "circle.inset.filled")
                            .font(.system(size: 15))
                            .foregroundStyle(RookPalette.accent)
                            .frame(width: 22)
                        Text(item.time)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(RookPalette.accent)
                            .frame(width: 58, alignment: .leading)
                        Text(item.title)
                            .font(.system(size: 18, design: .serif))
                            .foregroundStyle(RookPalette.ink)
                    }
                }
            }
        }
    }

    private var operationsRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("PAWNS")
                        .font(.system(size: 12, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(RookPalette.muted)
                    Spacer(minLength: 8)
                    if model.isDeliberating {
                        ProgressView()
                            .controlSize(.small)
                            .tint(RookPalette.accent)
                    }
                }

                if let label = model.deliberationLabel {
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.55)
                        .foregroundStyle(model.isDeliberating ? RookPalette.accent : RookPalette.green)
                        .padding(.top, 11)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.isDeliberating {
                    Text("Silent background work. Only Rook presents the synthesis.")
                        .font(.system(size: 12))
                        .foregroundStyle(RookPalette.muted)
                        .lineSpacing(2)
                        .padding(.top, 7)
                }

                if model.pawns.isEmpty {
                    emptyPawnState
                        .padding(.top, 28)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.pawns.prefix(3).enumerated()), id: \.offset) { index, pawn in
                            pawnRow(pawn)
                            if index < min(model.pawns.count, 3) - 1 {
                                Rectangle()
                                    .fill(RookPalette.line.opacity(0.78))
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(.top, 10)
                    if model.pawns.count > 3 {
                        Button {
                            model.selectedSection = .pawns
                        } label: {
                            Text("View \(model.pawns.count - 3) more in Pawns")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(RookPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                    }
                }

                Rectangle()
                    .fill(RookPalette.line.opacity(0.85))
                    .frame(height: 1)
                    .padding(.vertical, 30)

                if let item = model.primaryQueueItem {
                    approvalSummary(item)
                } else {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("NEXT MOVE")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(RookPalette.muted)
                        Text("Nothing waiting for review")
                            .font(.system(size: 19, design: .serif))
                            .foregroundStyle(RookPalette.ink)
                        Text("Rook handles safe calendar changes and drafts; consequential actions wait for review.")
                            .font(.system(size: 13))
                            .foregroundStyle(RookPalette.muted)
                            .lineSpacing(3)
                    }
                }

                Color.clear.frame(height: 150)
            }
            .padding(.top, 52)
            .padding(.horizontal, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RookPalette.paperBright.opacity(0.28))
    }

    private var emptyPawnState: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "person.2")
                .font(.system(size: 17))
                .foregroundStyle(RookPalette.accent)
                .frame(width: 40, height: 40)
                .background(RookPalette.accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Central Rook is handling this")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(RookPalette.ink)
                Text("Pawns appear only when specialist work helps.")
                    .font(.system(size: 12))
                    .foregroundStyle(RookPalette.muted)
            }
        }
    }

    private func pawnRow(_ pawn: PawnReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: pawnIcon(pawn.pawn))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(RookPalette.ink)
                .frame(width: 38, height: 38)
                .background(Color(red: 0.92, green: 0.89, blue: 0.84), in: Circle())

            Text("**\(pawn.instanceLabel)** — \(pawn.task)")
                .font(.system(size: 9.8))
                .foregroundStyle(RookPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .layoutPriority(1)

            Spacer(minLength: 8)

            Text(pawnStatus(pawn.status))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(pawnStatusColor(pawn.status))
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .padding(.vertical, 17)
    }

    private func approvalSummary(_ item: RookQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("NEXT MOVE")
                .font(.system(size: 12, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(RookPalette.muted)
            Text(item.displayLabel)
                .font(.system(size: 22, design: .serif))
                .foregroundStyle(RookPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.proposedAction)
                .font(.system(size: 12.5))
                .foregroundStyle(RookPalette.muted)
                .lineSpacing(3)
            Button {
                model.selectedReviewItem = item
            } label: {
                HStack(spacing: 7) {
                    Text("Review move")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RookPalette.accent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(RookPalette.accent, lineWidth: 1.2)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private var pawnsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PAWN ACTIVITY")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(RookPalette.accent)
                        Text("Crews by request")
                            .font(.system(size: 38, design: .serif))
                            .foregroundStyle(RookPalette.ink)
                    }
                }

                Text("Every deliberate prompt gets its own crew. The separate Librarian indexes the result and keeps its own context workers in the Library.")
                    .font(.system(size: 15))
                    .foregroundStyle(RookPalette.muted)
                    .lineSpacing(3)
                    .padding(.top, 18)

                workforceSummary
                    .padding(.top, 32)

                Rectangle()
                    .fill(RookPalette.line)
                    .frame(height: 1)
                    .padding(.top, 26)

                if model.pawnRuns.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("No crews yet")
                            .font(.system(size: 23, design: .serif))
                            .foregroundStyle(RookPalette.ink)
                        Text("Complex requests will appear here with each pawn instance, assignment, and live status.")
                            .font(.system(size: 14))
                            .foregroundStyle(RookPalette.muted)
                    }
                    .padding(.top, 40)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.pawnRuns.enumerated()), id: \.element.id) { index, run in
                            pawnRunSection(run)
                            if index < model.pawnRuns.count - 1 {
                                Rectangle()
                                    .fill(RookPalette.line)
                                    .frame(height: 1)
                            }
                        }
                    }
                }

                Color.clear.frame(height: 150)
            }
            .padding(.top, 52)
            .padding(.horizontal, 76)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var workforceSummary: some View {
        HStack(spacing: 28) {
            workforceMetric(value: "\(model.activePawnRuns.count)", label: "active crews")
            summaryDivider
            workforceMetric(value: "\(model.activePawnCount)", label: "pawns working")
            summaryDivider
            workforceMetric(value: "\(model.completedPawnCount)", label: "completed")
            summaryDivider
            workforceMetric(value: "10", label: "capacity / prompt")
            Spacer(minLength: 0)
        }
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(RookPalette.line)
            .frame(width: 1, height: 36)
    }

    private func workforceMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, design: .serif))
                .foregroundStyle(RookPalette.ink)
            Text(label.uppercased())
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(RookPalette.muted)
        }
    }

    private func pawnRunSection(_ run: RookPawnRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(runStatusColor(run.status))
                    .frame(width: 7, height: 7)
                Text(run.status.label.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(runStatusColor(run.status))
                Text("·")
                    .foregroundStyle(RookPalette.faint)
                Text(runTime(run.startedAt))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RookPalette.muted)
                Spacer()
                Text(roleSummary(run.pawns))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RookPalette.muted)
            }

            Text(run.command)
                .font(.system(size: 22, design: .serif))
                .foregroundStyle(RookPalette.ink)
                .lineLimit(2)
                .padding(.top, 9)

            if let reason = run.failureReason, !reason.isEmpty {
                Text("Why it stopped: \(reason)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RookPalette.accent)
                    .lineLimit(3)
                    .padding(.top, 8)
            }

            VStack(spacing: 0) {
                ForEach(Array(run.pawns.enumerated()), id: \.offset) { index, pawn in
                    pawnActivityRow(pawn)
                    if index < run.pawns.count - 1 {
                        Rectangle()
                            .fill(RookPalette.line.opacity(0.65))
                            .frame(height: 1)
                            .padding(.leading, 48)
                    }
                }
            }
            .padding(.top, 14)
        }
        .padding(.vertical, 28)
    }

    private func pawnActivityRow(_ pawn: PawnReport) -> some View {
        HStack(spacing: 13) {
            Image(systemName: pawnIcon(pawn.pawn))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(RookPalette.ink)
                .frame(width: 34, height: 34)
                .background(RookPalette.accent.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(pawn.instanceLabel)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(RookPalette.ink)
                Text(pawn.task)
                    .font(.system(size: 12.5))
                    .foregroundStyle(RookPalette.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 16)
            Text(pawnStatus(pawn.status))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(pawnStatusColor(pawn.status))
        }
        .padding(.vertical, 10)
    }

    private func roleSummary(_ pawns: [PawnReport]) -> String {
        let counts = Dictionary(grouping: pawns, by: \.pawn).mapValues(\.count)
        return PawnDefinition.all.compactMap { definition in
            guard let count = counts[definition.name] else { return nil }
            return count == 1 ? definition.name : "\(count)× \(definition.name)"
        }.joined(separator: " · ")
    }

    private func runTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "MMM d · h:mm a"
        return formatter.string(from: date)
    }

    private func runStatusColor(_ status: RookPawnRunStatus) -> Color {
        switch status {
        case .working: return RookPalette.accent
        case .completed: return RookPalette.green
        case .queued: return RookPalette.faint
        case .blocked, .interrupted: return RookPalette.muted
        }
    }

    private var libraryView: some View {
        VStack(spacing: 0) {
            libraryHeader
                .padding(.horizontal, 62)
                .padding(.top, 34)
                .padding(.bottom, 24)

            Rectangle()
                .fill(RookPalette.line)
                .frame(height: 1)

            GeometryReader { proxy in
                HStack(spacing: 0) {
                    libraryArchive
                        .frame(width: max(380, proxy.size.width * 0.39))

                    Rectangle()
                        .fill(RookPalette.line)
                        .frame(width: 1)

                    libraryInspector
                }
            }
        }
        .padding(.bottom, 132)
    }

    private var libraryHeader: some View {
        HStack(alignment: .bottom, spacing: 32) {
            VStack(alignment: .leading, spacing: 9) {
                Text("LIBRARY")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(RookPalette.accent)
                Text("Working memory")
                    .font(.system(size: 38, design: .serif))
                    .foregroundStyle(RookPalette.ink)
            }

            Spacer()

            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(RookPalette.green.opacity(model.isLibrarianRefreshing ? 0.14 : 0))
                        .frame(width: 26, height: 26)
                        .scaleEffect(librarianPulse ? 1.25 : 0.82)
                    Circle()
                        .fill(model.librarianError == nil ? RookPalette.green : RookPalette.accent)
                        .frame(width: 8, height: 8)
                }
                .onAppear { updateLibrarianPulse() }
                .onChange(of: model.isLibrarianRefreshing) { updateLibrarianPulse() }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("LIBRARIAN")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(RookPalette.ink)
                        Text("ALWAYS ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(RookPalette.green)
                    }
                    Text("\(model.librarianMessage) · \(model.librarianFreshness)")
                        .font(.system(size: 12))
                        .foregroundStyle(RookPalette.muted)
                }

                Rectangle()
                    .fill(RookPalette.line)
                    .frame(width: 1, height: 34)
                    .padding(.horizontal, 8)

                Button {
                    model.requestLibrarianRefresh()
                } label: {
                    Label(model.isLibrarianRefreshing ? "Refreshing" : "Refresh now", systemImage: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(RookPalette.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.isLibrarianRefreshing)
            }
        }
    }

    private var libraryArchive: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(RookPalette.faint)
                TextField("Search memory", text: $librarySearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(RookPalette.ink)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .background(RookPalette.paperBright.opacity(0.72))
            .overlay(alignment: .bottom) {
                Rectangle().fill(RookPalette.line).frame(height: 1)
            }

            HStack(spacing: 7) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { model.selectLibraryEntry(nil) }
                } label: {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(model.selectedLibraryEntryID == nil ? RookPalette.paperBright : RookPalette.green)
                        .frame(width: 28, height: 28)
                        .background(model.selectedLibraryEntryID == nil ? RookPalette.ink : RookPalette.green.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Open Librarian context")
                .accessibilityLabel("Open Librarian context")

                Rectangle()
                    .fill(RookPalette.line)
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 3)

                ForEach(LibraryScope.allCases) { scope in
                    Button(scope.rawValue) {
                        withAnimation(.easeOut(duration: 0.16)) { libraryScope = scope }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(libraryScope == scope ? RookPalette.paperBright : RookPalette.muted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(libraryScope == scope ? RookPalette.ink : Color.clear, in: Capsule())
                }
                Spacer()
                Text("\(filteredLibraryEntries.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(RookPalette.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if filteredLibraryEntries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No matching memory")
                        .font(.system(size: 19, design: .serif))
                        .foregroundStyle(RookPalette.ink)
                    Text("Try another phrase or clear the filter.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(RookPalette.muted)
                }
                .padding(24)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredLibraryEntries) { entry in
                            libraryRow(entry)
                        }
                    }
                }
            }
        }
        .background(RookPalette.paperBright.opacity(0.26))
    }

    private func libraryRow(_ entry: RookLibraryEntry) -> some View {
        let selected = model.selectedLibraryEntryID == entry.id
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { model.selectLibraryEntry(entry.id) }
        } label: {
            HStack(alignment: .top, spacing: 13) {
                Rectangle()
                    .fill(selected ? RookPalette.accent : Color.clear)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.label)
                            .font(.system(size: 17, design: .serif))
                            .foregroundStyle(RookPalette.ink)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        Text(libraryTime(entry.updatedAt))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(RookPalette.faint)
                    }
                    Text(entry.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(RookPalette.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        libraryStatus(entry.status)
                        Text(entry.route.uppercased())
                        if !entry.pawns.isEmpty { Text("\(entry.pawns.count) TASK PAWN\(entry.pawns.count == 1 ? "" : "S")") }
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(0.55)
                    .foregroundStyle(RookPalette.faint)
                }
                .padding(.vertical, 16)
                .padding(.trailing, 16)
            }
            .contentShape(Rectangle())
            .background(selected ? RookPalette.accent.opacity(0.055) : Color.clear)
            .overlay(alignment: .bottom) {
                Rectangle().fill(RookPalette.line.opacity(0.72)).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var libraryInspector: some View {
        if let entry = model.selectedLibraryEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("ARCHIVE NOTE")
                            .font(.system(size: 10.5, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(RookPalette.accent)
                        Spacer()
                        Button("Open folder") { model.openSelectedLibraryEntryFolder() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RookPalette.accent)
                    }

                    Text(entry.label)
                        .font(.system(size: 31, design: .serif))
                        .foregroundStyle(RookPalette.ink)
                        .padding(.top, 13)

                    HStack(spacing: 9) {
                        libraryStatus(entry.status)
                        Text("·")
                        Text(libraryDate(entry.createdAt))
                        Text("·")
                        Text(entry.route.capitalized)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RookPalette.muted)
                    .padding(.top, 9)

                    libraryRule
                        .padding(.vertical, 23)

                    inspectorLabel("YOU ASKED")
                    Text(entry.command)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(RookPalette.ink)
                        .lineSpacing(3)
                        .padding(.top, 8)

                    inspectorLabel("WHAT HAPPENED")
                        .padding(.top, 25)
                    RookMarkdownView(markdown: entry.summary, density: .history)
                        .padding(.top, 5)

                    if let reason = entry.failureReason, !reason.isEmpty {
                        inspectorLabel("EXACT STOP REASON")
                            .padding(.top, 24)
                        Text(reason)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(RookPalette.accent)
                            .lineSpacing(3)
                            .padding(.top, 8)
                    }

                    inspectorLabel("LIBRARIAN INDEX")
                        .padding(.top, 25)
                    Text(entry.librarianIndexedAt.map(libraryDate) ?? "Indexing pending")
                        .font(.system(size: 13))
                        .foregroundStyle(entry.librarianIndexedAt == nil ? RookPalette.accent : RookPalette.muted)
                        .padding(.top, 7)

                    inspectorLabel("TASK CREW")
                        .padding(.top, 25)
                    if entry.pawns.isEmpty {
                        Text("Central Rook handled this without task pawns.")
                            .font(.system(size: 13))
                            .foregroundStyle(RookPalette.muted)
                            .padding(.top, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(entry.pawns.enumerated()), id: \.offset) { index, pawn in
                                pawnActivityRow(pawn)
                                if index < entry.pawns.count - 1 {
                                    Rectangle().fill(RookPalette.line.opacity(0.65)).frame(height: 1).padding(.leading, 48)
                                }
                            }
                        }
                        .padding(.top, 5)
                    }

                    Color.clear.frame(height: 36)
                }
                .padding(30)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            librarianContextOverview
        }
    }

    private var librarianContextOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("LIBRARIAN CONTEXT")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(RookPalette.accent)
                Text("What Rook knows now")
                    .font(.system(size: 30, design: .serif))
                    .foregroundStyle(RookPalette.ink)
                    .padding(.top, 12)
                Text("A read-only working set, refreshed in the background and used for fast answers. Central Rook remains the only voice and action authority.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(RookPalette.muted)
                    .lineSpacing(3)
                    .padding(.top, 10)

                libraryRule.padding(.vertical, 23)

                HStack(spacing: 30) {
                    contextMetric("\(model.librarianCheckpoint?.calendarItems.count ?? 0)", "calendar items")
                    contextMetric("\(model.librarianCheckpoint?.emailItems.count ?? 0)", "email signals")
                    contextMetric("\(model.activePreferenceCount)", "active preferences")
                }

                inspectorLabel("CONTEXT PAWNS")
                    .padding(.top, 28)
                if model.librarianPawns.isEmpty {
                    Text("No successful context crew has reported yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(RookPalette.muted)
                        .padding(.top, 9)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.librarianPawns.enumerated()), id: \.offset) { index, pawn in
                            pawnActivityRow(pawn)
                            if index < model.librarianPawns.count - 1 {
                                Rectangle().fill(RookPalette.line.opacity(0.65)).frame(height: 1).padding(.leading, 48)
                            }
                        }
                    }
                    .padding(.top, 5)
                }

                inspectorLabel("LEARNED PREFERENCES")
                    .padding(.top, 28)
                let active = model.librarianPreferences.filter(\.isActive)
                if active.isEmpty {
                    Text("Nothing promoted yet. Repeated or explicit preferences will appear here.")
                        .font(.system(size: 13))
                        .foregroundStyle(RookPalette.muted)
                        .padding(.top, 9)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(active) { preference in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(RookPalette.accent)
                                    .padding(.top, 3)
                                Text(preference.value)
                                    .font(.system(size: 13))
                                    .foregroundStyle(RookPalette.ink)
                            }
                        }
                    }
                    .padding(.top, 11)
                }

                Button("Open full Library folder") { model.openLibraryFolder() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(RookPalette.accent)
                    .padding(.top, 27)
            }
            .padding(30)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filteredLibraryEntries: [RookLibraryEntry] {
        let query = librarySearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.libraryEntries.filter { entry in
            let matchesScope: Bool
            switch libraryScope {
            case .all: matchesScope = true
            case .tasks: matchesScope = !entry.pawns.isEmpty
            case .attention: matchesScope = entry.status == .blocked || entry.status == .interrupted
            }
            guard matchesScope else { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([entry.label, entry.command, entry.summary, entry.route] + entry.tags + entry.pawns.flatMap { [$0.pawn, $0.task] })
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(query)
        }
    }

    private var libraryRule: some View {
        Rectangle().fill(RookPalette.line).frame(height: 1)
    }

    private func inspectorLabel(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(RookPalette.muted)
    }

    private func contextMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 25, design: .serif))
                .foregroundStyle(RookPalette.ink)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(RookPalette.faint)
        }
    }

    private func libraryStatus(_ status: RookLibraryStatus) -> some View {
        Text(status.rawValue.uppercased())
            .foregroundStyle(status == .completed ? RookPalette.green : (status == .working ? RookPalette.accent : RookPalette.muted))
    }

    private func libraryTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "MMM d"
        return formatter.string(from: date)
    }

    private func libraryDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy · h:mm a"
        return formatter.string(from: date)
    }

    private func updateLibrarianPulse() {
        guard model.isLibrarianRefreshing else {
            librarianPulse = false
            return
        }
        librarianPulse = false
        withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
            librarianPulse = true
        }
    }

    private var queueView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("NEXT MOVES")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(RookPalette.accent)
                        Text("Waiting on you")
                            .font(.system(size: 38, design: .serif))
                            .foregroundStyle(RookPalette.ink)
                    }
                    Spacer()
                    Button("Refresh") { model.refreshQueue() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(RookPalette.accent)
                }

                if model.queueItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Nothing is waiting")
                            .font(.system(size: 22, design: .serif))
                            .foregroundStyle(RookPalette.ink)
                        Text("Consequential actions appear here with a clear label and the exact change Rook wants to make.")
                            .font(.system(size: 14))
                            .foregroundStyle(RookPalette.muted)
                    }
                    .padding(.top, 54)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.queueItems) { item in
                            HStack(alignment: .center, spacing: 24) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.displayLabel)
                                        .font(.system(size: 20, design: .serif))
                                        .foregroundStyle(RookPalette.ink)
                                    Text(item.proposedAction)
                                        .font(.system(size: 13))
                                        .foregroundStyle(RookPalette.muted)
                                }
                                Spacer()
                                Text(item.statusLabel)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(RookPalette.muted)
                                Button("Review") { model.selectedReviewItem = item }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(RookPalette.accent)
                            }
                            .padding(.vertical, 22)
                            Rectangle()
                                .fill(RookPalette.line)
                                .frame(height: 1)
                        }
                    }
                    .padding(.top, 34)
                }
                Color.clear.frame(height: 150)
            }
            .padding(.top, 62)
            .padding(.horizontal, 76)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var voiceDock: some View {
        HStack(spacing: 24) {
            Button(action: model.listenNow) {
                HStack(spacing: 18) {
                    RookCaptureMeter(
                        progress: model.captureMeterProgress,
                        phase: model.voicePhase,
                        color: voiceAccent
                    )
                    .frame(width: 52, height: 52)

                    RookWaveform(levels: model.audioLevels, color: voiceAccent)
                        .frame(width: 270, height: 48)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.voicePhase == .waiting ? "Rook is ready for its wake word" : "Voice capture status")

            VStack(alignment: .leading, spacing: 3) {
                Text(model.voiceInstruction)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(voiceAccent)
                Text(model.voiceDetail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(RookPalette.muted)
                    .lineLimit(1)
                TextField("Ask Rook anything…", text: $typedCommand)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(RookPalette.ink)
                    .focused($commandFocused)
                    .onSubmit(submitTypedCommand)
            }

            Spacer(minLength: 14)

            Button {
                if typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    commandFocused = true
                } else {
                    submitTypedCommand()
                }
            } label: {
                Image(systemName: typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "keyboard" : "arrow.up")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(RookPalette.ink)
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(typedCommand.isEmpty ? "Focus command field" : "Ask Rook")
        }
        .padding(.horizontal, 34)
        .frame(height: 104)
        .background(RookPalette.paperBright.opacity(0.97), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(RookPalette.line.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 18, x: 0, y: 8)
    }

    private var voiceAccent: Color {
        switch model.voicePhase {
        case .waiting: return RookPalette.green
        case .paused, .unavailable: return RookPalette.muted
        default: return RookPalette.accent
        }
    }

    private func reviewSheet(_ item: RookQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("NEXT MOVE")
                .font(.system(size: 12, weight: .bold))
                .tracking(1)
                .foregroundStyle(RookPalette.accent)
            Text(item.displayLabel)
                .font(.system(size: 30, design: .serif))
                .foregroundStyle(RookPalette.ink)
            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(RookPalette.muted)
            VStack(alignment: .leading, spacing: 8) {
                Text("PROPOSED ACTION")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.9)
                    .foregroundStyle(RookPalette.muted)
                Text(item.proposedAction)
                    .font(.system(size: 15))
                    .foregroundStyle(RookPalette.ink)
                if !item.details.isEmpty {
                    Text(item.details)
                        .font(.system(size: 14))
                        .foregroundStyle(RookPalette.muted)
                        .lineSpacing(3)
                }
            }
            .padding(18)
            .background(RookPalette.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Label("Reviewing alone does not execute, send, publish, or change anything.", systemImage: "hand.raised.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(RookPalette.muted)

            HStack {
                Text("Status: \(item.statusLabel) · Risk: \(item.risk)")
                    .font(.system(size: 12))
                    .foregroundStyle(RookPalette.faint)
                Spacer()
                Button("Close") { model.selectedReviewItem = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 560)
        .background(RookPalette.paperBright)
    }

    private func submitTypedCommand() {
        let command = typedCommand
        typedCommand = ""
        commandFocused = false
        model.submit(command)
    }

    private func pawnIcon(_ pawn: String) -> String {
        switch pawn {
        case "Steward": return "calendar"
        case "Scout": return "magnifyingglass"
        case "Forge": return "hammer"
        case "Scribe": return "pencil.line"
        case "Auditor": return "checkmark.shield"
        case "Librarian": return "books.vertical"
        default: return "person"
        }
    }

    private func pawnStatus(_ status: String) -> String {
        switch status {
        case "completed": return "Complete"
        case "working": return "Working"
        case "queued": return "Queued"
        case "not_needed": return "Not needed"
        case "blocked": return "Blocked"
        default: return status.capitalized
        }
    }

    private func pawnStatusColor(_ status: String) -> Color {
        switch status {
        case "completed": return RookPalette.green
        case "queued": return RookPalette.faint
        default: return RookPalette.accent
        }
    }
}

private struct RookWaveform: View {
    let levels: [CGFloat]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            let step = size.width / CGFloat(levels.count)
            for (index, level) in levels.enumerated() {
                let height = max(2, level * size.height * 0.92)
                let x = (CGFloat(index) + 0.5) * step
                var path = Path()
                path.move(to: CGPoint(x: x, y: (size.height - height) / 2))
                path.addLine(to: CGPoint(x: x, y: (size.height + height) / 2))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: max(1.2, step * 0.34), lineCap: .round)
                )
            }
        }
        .accessibilityLabel("Live microphone waveform")
    }
}

private struct RookCaptureMeter: View {
    let progress: CGFloat
    let phase: RookVoicePhase
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(RookPalette.line.opacity(0.85), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.025, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.06), value: progress)
            Image(systemName: meterIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var meterIcon: String {
        switch phase {
        case .waiting: return "waveform"
        case .wakeDetected, .capturing: return "mic.fill"
        case .sending, .processing: return "arrow.up"
        case .speaking: return "speaker.wave.2.fill"
        case .paused: return "pause.fill"
        case .unavailable: return "exclamationmark"
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .waiting: return "Rook is ready. Just say Rook."
        case .wakeDetected: return "Wake word heard. Start talking."
        case .capturing: return "Listening. The ring shows time remaining before the command sends."
        case .sending: return "Command captured."
        case .processing: return "Rook is answering."
        case .speaking: return "Rook is speaking."
        case .paused: return "Voice is paused."
        case .unavailable: return "Voice needs attention."
        }
    }
}
