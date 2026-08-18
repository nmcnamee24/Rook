import RookKit
import SwiftUI

enum RookPalette {
  // Adaptive foregrounds and translucent washes keep native glass readable in either appearance.
  static let paper = Color.primary.opacity(0.055)
  static let paperBright = Color.white
  static let ink = Color.primary.opacity(0.94)
  static let muted = Color.secondary
  static let faint = muted.opacity(0.72)
  static let line = Color.primary.opacity(0.20)
  static let accent = Color(red: 70 / 255, green: 130 / 255, blue: 180 / 255)
  static let green = Color(red: 46 / 255, green: 139 / 255, blue: 87 / 255)
}

private enum LibraryScope: String, CaseIterable, Identifiable {
  case all = "All"
  case tasks = "Tasks"
  case attention = "Attention"

  var id: String { rawValue }
}

private struct LibraryPawnInspection: Identifiable {
  let id = UUID()
  let pawn: PawnReport
  let entry: RookLibraryEntry?
  let sourceTitle: String
  let isContextWorker: Bool
}

private enum RookConnectionState: Equatable {
  case direct
  case codex
  case local
  case connecting
  case failed
  case planned

  var label: String {
    switch self {
    case .direct: return "Connected directly"
    case .codex: return "Connected via Codex"
    case .local: return "Local controls ready"
    case .connecting: return "Connecting directly"
    case .failed: return "Connection needs attention"
    case .planned: return "Planned"
    }
  }

  var color: Color {
    switch self {
    case .direct, .codex, .local: return RookPalette.green
    case .connecting: return RookPalette.accent
    case .failed: return RookPalette.ink
    case .planned: return RookPalette.faint
    }
  }
}

private struct RookConnection: Identifiable {
  let id: String
  let priority: Int?
  let name: String
  let summary: String
  let icon: String
  let state: RookConnectionState
  let connectionNote: String
  let oauthProvider: RookOAuthProvider?

  init(
    id: String,
    priority: Int?,
    name: String,
    summary: String,
    icon: String,
    state: RookConnectionState,
    connectionNote: String,
    oauthProvider: RookOAuthProvider? = nil
  ) {
    self.id = id
    self.priority = priority
    self.name = name
    self.summary = summary
    self.icon = icon
    self.state = state
    self.connectionNote = connectionNote
    self.oauthProvider = oauthProvider
  }
}

struct RookDashboardView: View {
  @ObservedObject var model: RookDashboardModel
  @State private var typedCommand = ""
  @State private var librarySearch = ""
  @State private var libraryScope: LibraryScope = .all
  @State private var librarianPulse = false
  @State private var selectedLibraryPawn: LibraryPawnInspection?
  @State private var oauthClientIDDraft = ""
  @State private var oauthSetupError: String?
  @State private var confirmOAuthDisconnect = false
  @FocusState private var commandFocused: Bool

  var body: some View {
    GlassEffectContainer(spacing: 18) {
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
    }
    .frame(minWidth: 1_060, minHeight: 720)
    .background(Color.clear.ignoresSafeArea())
    .sheet(item: $model.selectedReviewItem) { item in
      reviewSheet(item)
    }
    .sheet(item: $model.selectedOAuthProvider) { provider in
      oauthSetupSheet(provider)
    }
    .sheet(item: $selectedLibraryPawn) { inspection in
      pawnInspectionSheet(inspection)
    }
  }

  private var topBar: some View {
    HStack(spacing: 0) {
      Text("ROOK")
        .font(.system(size: 25, weight: .medium, design: .serif))
        .tracking(3.5)
        .foregroundStyle(RookPalette.accent)
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
                .foregroundStyle(
                  model.selectedSection == section ? RookPalette.accent : RookPalette.muted)
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
    .rookGlassPlane(tintOpacity: 0.035)
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
    case .allies:
      alliesView
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
          RookCanvasView(blocks: model.responseCanvas, mediaRootURL: model.mediaRootURL)
            .frame(maxWidth: 700, alignment: .leading)
            .padding(.top, model.isDeliberating || model.isStreaming ? 12 : 24)
        }

        RookMarkdownView(markdown: model.responseText)
          .frame(maxWidth: 650, alignment: .leading)
          .padding(
            .top,
            model.responseCanvas.isEmpty
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
    .rookGlassPlane(tintOpacity: 0.025)
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
        .background(RookPalette.line.opacity(0.58), in: Circle())

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

        Text(
          "Every deliberate prompt gets its own crew. The separate Librarian indexes the result and keeps its own context workers in the Library."
        )
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
            Text("No activity yet")
              .font(.system(size: 23, design: .serif))
              .foregroundStyle(RookPalette.ink)
            Text("Codex tasks and complex requests will appear here with their owner and live status.")
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
      workforceMetric(value: "\(model.activePawnRuns.count)", label: "active work")
      summaryDivider
      workforceMetric(value: "\(model.activePawnCount)", label: "pawns working")
      summaryDivider
      workforceMetric(value: "\(model.completedWorkCount)", label: "completed work")
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
        Text(run.isCodexTask ? "Full Codex" : roleSummary(run.pawns))
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

      if run.isCodexTask {
        HStack(spacing: 13) {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(RookPalette.ink)
            .frame(width: 34, height: 34)
            .background(RookPalette.accent.opacity(0.07), in: Circle())
          VStack(alignment: .leading, spacing: 3) {
            Text("Full Codex task")
              .font(.system(size: 13.5, weight: .semibold))
              .foregroundStyle(RookPalette.ink)
            Text(codexTaskDetail(run))
              .font(.system(size: 12.5))
              .foregroundStyle(RookPalette.muted)
              .lineLimit(2)
          }
          Spacer(minLength: 16)
          Text(run.status.label)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(runStatusColor(run.status))
        }
        .padding(.top, 14)
        .padding(.vertical, 10)
      } else {
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

  private func libraryPawnActivityRow(
    _ pawn: PawnReport,
    entry: RookLibraryEntry? = nil,
    sourceTitle: String? = nil,
    isContextWorker: Bool = false
  ) -> some View {
    Button {
      selectedLibraryPawn = LibraryPawnInspection(
        pawn: pawn,
        entry: entry,
        sourceTitle: sourceTitle ?? entry?.label ?? "Pawn report",
        isContextWorker: isContextWorker
      )
    } label: {
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
          Text(pawn.reportedResult == nil ? "Open assignment and archive evidence" : "Open result and evidence")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(RookPalette.accent)
            .padding(.top, 2)
        }
        Spacer(minLength: 16)
        Text(pawnStatus(pawn.status))
          .font(.system(size: 11.5, weight: .semibold))
          .foregroundStyle(pawnStatusColor(pawn.status))
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(RookPalette.faint)
      }
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Inspect \(pawn.instanceLabel)")
  }

  private func roleSummary(_ pawns: [PawnReport]) -> String {
    let counts = Dictionary(grouping: pawns, by: \.pawn).mapValues(\.count)
    return PawnDefinition.all.compactMap { definition in
      guard let count = counts[definition.name] else { return nil }
      return count == 1 ? definition.name : "\(count)× \(definition.name)"
    }.joined(separator: " · ")
  }

  private func codexTaskDetail(_ run: RookPawnRun) -> String {
    let workspace = run.workspaceName.map { "Checkout: \($0)" } ?? "Verified project checkout"
    guard let taskID = run.taskID else { return workspace }
    return "\(workspace) · Task \(taskID)"
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
      .rookGlassInset(cornerRadius: 0, tintOpacity: 0.025)
      .overlay(alignment: .bottom) {
        Rectangle().fill(RookPalette.line).frame(height: 1)
      }

      HStack(spacing: 7) {
        Button {
          withAnimation(.easeOut(duration: 0.16)) { model.clearLibrarySelection() }
        } label: {
          Image(systemName: "books.vertical.fill")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(
              model.selectedLibraryEntryID == nil && model.selectedLibraryNodeID == nil
                ? RookPalette.paperBright : RookPalette.green
            )
            .frame(width: 28, height: 28)
            .background(
              model.selectedLibraryEntryID == nil && model.selectedLibraryNodeID == nil
                ? RookPalette.ink : RookPalette.green.opacity(0.10),
              in: Circle())
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
    .rookGlassPlane(tintOpacity: 0.025)
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
            if let project = model.libraryProject(for: entry) { Text(project.title.uppercased()) }
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
    if let node = model.selectedLibraryNode {
      libraryNodeInspector(node)
    } else if let entry = model.selectedLibraryEntry {
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

          let nodePath = model.libraryNodePath(for: entry)
          if !nodePath.isEmpty {
            inspectorLabel("GRAPH PATH")
              .padding(.top, 25)
            HStack(spacing: 7) {
              ForEach(Array(nodePath.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                  Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(RookPalette.faint)
                }
                Button(node.title) {
                  withAnimation(.easeOut(duration: 0.16)) { model.selectLibraryNode(node.id) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RookPalette.accent)
              }
            }
            .padding(.top, 8)
          }

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
                libraryPawnActivityRow(pawn, entry: entry)
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

  private func libraryNodeInspector(_ node: RookLibraryNode) -> some View {
    let path = model.libraryPath(to: node.id)
    let parents = model.libraryParents(of: node.id)
    let children = model.libraryChildren(of: node.id)
    let entries = model.libraryEntries(for: node.id)
    return ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack {
          Button {
            withAnimation(.easeOut(duration: 0.16)) { model.clearLibrarySelection() }
          } label: {
            Label("Project graph", systemImage: "chevron.left")
          }
          .buttonStyle(.plain)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(RookPalette.accent)
          Spacer()
          Button("Open note") { model.openSelectedLibraryNodeNote() }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(RookPalette.accent)
        }

        Text(node.kind.rawValue.uppercased())
          .font(.system(size: 10.5, weight: .bold))
          .tracking(1)
          .foregroundStyle(RookPalette.accent)
          .padding(.top, 25)
        Text(node.title)
          .font(.system(size: 34, design: .serif))
          .foregroundStyle(RookPalette.ink)
          .padding(.top, 9)
        Text("Every stored connection, source context, and attached archive note for this node.")
          .font(.system(size: 13.5))
          .foregroundStyle(RookPalette.muted)
          .lineSpacing(3)
          .padding(.top, 8)

        libraryRule.padding(.vertical, 23)

        HStack(spacing: 30) {
          contextMetric("\(node.mentionCount)", "activity signals")
          contextMetric("\(children.count)", "child folders")
          contextMetric("\(entries.count)", "archive notes")
          contextMetric("\(node.referencedSourceContexts.count)", "source records")
        }

        inspectorLabel("GRAPH PATH")
          .padding(.top, 28)
        HStack(spacing: 7) {
          ForEach(Array(path.enumerated()), id: \.element.id) { index, pathNode in
            if index > 0 {
              Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(RookPalette.faint)
            }
            Button(pathNode.title) {
              withAnimation(.easeOut(duration: 0.16)) { model.selectLibraryNode(pathNode.id) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: pathNode.id == node.id ? .bold : .semibold))
            .foregroundStyle(pathNode.id == node.id ? RookPalette.ink : RookPalette.accent)
          }
        }
        .padding(.top, 9)

        if !parents.isEmpty || !children.isEmpty {
          inspectorLabel("CONNECTED FOLDERS")
            .padding(.top, 28)
          VStack(spacing: 0) {
            ForEach(parents) { parent in
              libraryNodeConnection(parent, relationship: "Parent")
            }
            ForEach(children) { child in
              libraryNodeConnection(child, relationship: "Contains")
            }
          }
          .padding(.top, 6)
        }

        if !node.referencedWorkspacePaths.isEmpty {
          inspectorLabel("RECORDED WORKSPACES")
            .padding(.top, 28)
          VStack(alignment: .leading, spacing: 7) {
            ForEach(node.referencedWorkspacePaths, id: \.self) { path in
              Text(path)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(RookPalette.ink)
                .textSelection(.enabled)
            }
          }
          .padding(.top, 9)
        }

        inspectorLabel("STORED SOURCE CONTEXT · \(node.referencedSourceContexts.count)")
          .padding(.top, 28)
        if node.referencedSourceContexts.isEmpty {
          Text("No external source record is attached. Rook-turn context appears below when available.")
            .font(.system(size: 13))
            .foregroundStyle(RookPalette.muted)
            .padding(.top, 9)
        } else {
          VStack(spacing: 0) {
            ForEach(node.referencedSourceContexts) { context in
              DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                  Text("\(context.source) · \(libraryDate(context.updatedAt))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(RookPalette.faint)
                  RookMarkdownView(markdown: context.body, density: .history)
                }
                .padding(.top, 12)
                .padding(.bottom, 14)
              } label: {
                Text(context.title)
                  .font(.system(size: 13.5, weight: .semibold))
                  .foregroundStyle(RookPalette.ink)
                  .multilineTextAlignment(.leading)
              }
              .tint(RookPalette.accent)
              .padding(.vertical, 12)
              Rectangle().fill(RookPalette.line.opacity(0.65)).frame(height: 1)
            }
          }
          .padding(.top, 5)
        }

        inspectorLabel("ATTACHED ARCHIVE NOTES · \(entries.count)")
          .padding(.top, 28)
        if entries.isEmpty {
          Text("No native Rook conversations are attached yet. Imported source context remains visible above.")
            .font(.system(size: 13))
            .foregroundStyle(RookPalette.muted)
            .padding(.top, 9)
        } else {
          VStack(spacing: 0) {
            ForEach(entries) { entry in
              Button {
                withAnimation(.easeOut(duration: 0.16)) { model.selectLibraryEntry(entry.id) }
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  HStack {
                    Text(entry.label)
                      .font(.system(size: 14, weight: .semibold))
                      .foregroundStyle(RookPalette.ink)
                    Spacer()
                    Text(libraryTime(entry.updatedAt))
                      .font(.system(size: 10.5, weight: .medium))
                      .foregroundStyle(RookPalette.faint)
                    Image(systemName: "chevron.right")
                      .font(.system(size: 9, weight: .bold))
                      .foregroundStyle(RookPalette.faint)
                  }
                  Text(entry.command)
                    .font(.system(size: 12.5))
                    .foregroundStyle(RookPalette.muted)
                    .lineLimit(2)
                  Text(entry.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(RookPalette.faint)
                    .lineLimit(3)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              Rectangle().fill(RookPalette.line.opacity(0.65)).frame(height: 1)
            }
          }
          .padding(.top, 4)
        }

        if !node.aliases.isEmpty {
          inspectorLabel("ALIASES · \(node.aliases.count)")
            .padding(.top, 28)
          Text(node.aliases.joined(separator: "  ·  "))
            .font(.system(size: 12.5))
            .foregroundStyle(RookPalette.ink)
            .lineSpacing(4)
            .padding(.top, 8)
            .textSelection(.enabled)
        }

        if !node.keywords.isEmpty {
          inspectorLabel("MATCHING TERMS · \(node.keywords.count)")
            .padding(.top, 28)
          Text(node.keywords.joined(separator: ", "))
            .font(.system(size: 12.5))
            .foregroundStyle(RookPalette.muted)
            .lineSpacing(4)
            .padding(.top, 8)
            .textSelection(.enabled)
        }

        inspectorLabel("STORAGE")
          .padding(.top, 28)
        VStack(alignment: .leading, spacing: 6) {
          Text("Node ID: \(node.id)")
          Text("Note: \(node.notePath)")
          Text("Created: \(libraryDate(node.createdAt))")
          Text("Updated: \(libraryDate(node.updatedAt))")
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(RookPalette.faint)
        .padding(.top, 8)
        .textSelection(.enabled)

        Color.clear.frame(height: 36)
      }
      .padding(30)
      .frame(maxWidth: 760, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func libraryNodeConnection(_ node: RookLibraryNode, relationship: String) -> some View {
    Button {
      withAnimation(.easeOut(duration: 0.16)) { model.selectLibraryNode(node.id) }
    } label: {
      HStack(spacing: 11) {
        Circle()
          .fill(RookPalette.accent.opacity(0.12))
          .frame(width: 28, height: 28)
          .overlay(Circle().fill(RookPalette.accent).frame(width: 7, height: 7))
        VStack(alignment: .leading, spacing: 2) {
          Text(node.title)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(RookPalette.ink)
          Text("\(relationship.uppercased()) · \(node.kind.rawValue.uppercased())")
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(RookPalette.faint)
        }
        Spacer()
        Text("\(node.mentionCount) signals")
          .font(.system(size: 10.5, weight: .medium))
          .foregroundStyle(RookPalette.muted)
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(RookPalette.faint)
      }
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func pawnInspectionSheet(_ inspection: LibraryPawnInspection) -> some View {
    let pawn = inspection.pawn
    let evidence = pawn.reportedEvidence.isEmpty ? legacyContextEvidence(for: inspection) : pawn.reportedEvidence
    return VStack(spacing: 0) {
      HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 3) {
          Text("PAWN EVIDENCE")
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1)
            .foregroundStyle(RookPalette.accent)
          Text(inspection.sourceTitle)
            .font(.system(size: 12))
            .foregroundStyle(RookPalette.muted)
            .lineLimit(1)
        }
        Spacer()
        Button {
          selectedLibraryPawn = nil
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(RookPalette.muted)
            .frame(width: 30, height: 30)
            .background(RookPalette.line.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close pawn evidence")
      }
      .padding(.horizontal, 30)
      .padding(.vertical, 20)

      libraryRule

      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(alignment: .top, spacing: 15) {
            Image(systemName: pawnIcon(pawn.pawn))
              .font(.system(size: 20, weight: .medium))
              .foregroundStyle(RookPalette.ink)
              .frame(width: 46, height: 46)
              .background(RookPalette.accent.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
              Text(pawn.instanceLabel)
                .font(.system(size: 30, design: .serif))
                .foregroundStyle(RookPalette.ink)
              Text(pawnStatus(pawn.status))
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(pawnStatusColor(pawn.status))
            }
          }

          inspectorLabel("ASSIGNMENT")
            .padding(.top, 28)
          Text(pawn.task)
            .font(.system(size: 14.5, weight: .medium))
            .foregroundStyle(RookPalette.ink)
            .lineSpacing(3)
            .padding(.top, 8)

          inspectorLabel("WHAT THIS PAWN DID")
            .padding(.top, 28)
          RookMarkdownView(markdown: pawn.reportedResult ?? legacyPawnResult(for: inspection), density: .history)
            .padding(.top, 6)

          inspectorLabel("EVIDENCE · \(evidence.count)")
            .padding(.top, 28)
          if evidence.isEmpty {
            Text("No separately attributable evidence was preserved for this older pawn report.")
              .font(.system(size: 13))
              .foregroundStyle(RookPalette.muted)
              .padding(.top, 8)
          } else {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(Array(evidence.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                  Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(RookPalette.accent)
                    .frame(width: 18, alignment: .leading)
                  Text(item)
                    .font(.system(size: 13))
                    .foregroundStyle(RookPalette.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                }
              }
            }
            .padding(.top, 10)
          }

          if let entry = inspection.entry {
            inspectorLabel("CENTRAL ROOK SYNTHESIS")
              .padding(.top, 28)
            RookMarkdownView(markdown: entry.summary, density: .history)
              .padding(.top, 6)

            HStack(spacing: 18) {
              Button("Open archive folder") { model.openLibraryEntryFolder(entry) }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(RookPalette.accent)
              if let path = entry.taskFolder {
                Text(path)
                  .font(.system(size: 10.5, design: .monospaced))
                  .foregroundStyle(RookPalette.faint)
                  .lineLimit(1)
                  .textSelection(.enabled)
              }
            }
            .padding(.top, 20)
          }

          Text("Rook stores the pawn’s attributable result and evidence, never hidden reasoning or raw pawn messages.")
            .font(.system(size: 11.5))
            .foregroundStyle(RookPalette.faint)
            .padding(.top, 28)

          Color.clear.frame(height: 28)
        }
        .padding(30)
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 680, minHeight: 620)
    .padding(1)
    .rookGlassSheet()
  }

  private func legacyPawnResult(for inspection: LibraryPawnInspection) -> String {
    guard inspection.isContextWorker, let checkpoint = model.librarianCheckpoint else {
      return
        "This archive predates detailed pawn reports. Rook preserved the assignment, status, and central synthesis, but it cannot honestly attribute a more specific result to this pawn."
    }
    let identifier = inspection.pawn.id?.lowercased() ?? ""
    if identifier.contains("calendar") {
      return
        "Read the bounded primary Calendar checkpoint and contributed \(checkpoint.calendarItems.count) upcoming item\(checkpoint.calendarItems.count == 1 ? "" : "s") as of \(checkpoint.calendarAsOf)."
    }
    if identifier.contains("gmail") || identifier.contains("mail") {
      return
        "Read the bounded Gmail checkpoint and contributed \(checkpoint.emailItems.count) high-confidence signal\(checkpoint.emailItems.count == 1 ? "" : "s") as of \(checkpoint.gmailAsOf)."
    }
    if inspection.pawn.pawn == "Auditor" {
      return "Verified the checkpoint’s freshness and bounded Calendar and Gmail claims at \(checkpoint.checkedAt)."
    }
    if inspection.pawn.pawn == "Scout" {
      return
        "Retrieved context for the checkpoint, including \(checkpoint.preparations.count) stored meeting preparation\(checkpoint.preparations.count == 1 ? "" : "s")."
    }
    return
      "Completed its read-only checkpoint assignment. This older checkpoint did not preserve a separate result narrative."
  }

  private func legacyContextEvidence(for inspection: LibraryPawnInspection) -> [String] {
    guard inspection.isContextWorker, let checkpoint = model.librarianCheckpoint else { return [] }
    let identifier = inspection.pawn.id?.lowercased() ?? ""
    if identifier.contains("calendar") {
      return [
        "Primary Calendar checkpoint as of \(checkpoint.calendarAsOf)",
        "\(checkpoint.calendarItems.count) bounded upcoming item\(checkpoint.calendarItems.count == 1 ? "" : "s") retained",
      ]
    }
    if identifier.contains("gmail") || identifier.contains("mail") {
      return [
        "Gmail checkpoint as of \(checkpoint.gmailAsOf)",
        "\(checkpoint.emailItems.count) high-confidence signal\(checkpoint.emailItems.count == 1 ? "" : "s") retained",
      ]
    }
    return ["Checkpoint verified at \(checkpoint.checkedAt)", "Timezone: \(checkpoint.timezone)"]
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
        Text(
          "A read-only working set, refreshed in the background and used for fast answers. Central Rook remains the only voice and action authority."
        )
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

        inspectorLabel("PROJECT GRAPH")
          .padding(.top, 28)
        Text(
          "Open any project, category, or topic to inspect every connection, source record, matching term, and attached archive note."
        )
        .font(.system(size: 12.5))
        .foregroundStyle(RookPalette.muted)
        .lineSpacing(3)
        .padding(.top, 8)
        if model.libraryProjects.isEmpty {
          Text(
            "Project nodes appear as the Librarian recognizes named work. Categories and topics branch beneath them."
          )
          .font(.system(size: 13))
          .foregroundStyle(RookPalette.muted)
          .padding(.top, 9)
        } else {
          VStack(spacing: 0) {
            ForEach(model.libraryProjects) { project in
              libraryProjectBranch(project)
              Rectangle().fill(RookPalette.line.opacity(0.65)).frame(height: 1)
            }
          }
          .padding(.top, 7)
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
              libraryPawnActivityRow(pawn, sourceTitle: "Librarian context", isContextWorker: true)
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
      let haystack =
        ([entry.label, entry.command, entry.summary, entry.route] + entry.tags
        + entry.pawns.flatMap { [$0.pawn, $0.task, $0.reportedResult ?? ""] + $0.reportedEvidence })
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

  private func libraryProjectBranch(_ project: RookLibraryNode) -> some View {
    let categories = model.libraryChildren(of: project.id)
    return VStack(alignment: .leading, spacing: 0) {
      libraryGraphNodeRow(project, depth: 0)
      ForEach(categories) { category in
        libraryGraphNodeRow(category, depth: 1)
        ForEach(model.libraryChildren(of: category.id)) { topic in
          libraryGraphNodeRow(topic, depth: 2)
        }
      }
    }
  }

  private func libraryGraphNodeRow(_ node: RookLibraryNode, depth: Int) -> some View {
    let selected = model.selectedLibraryNodeID == node.id
    return Button {
      withAnimation(.easeOut(duration: 0.16)) { model.selectLibraryNode(node.id) }
    } label: {
      HStack(spacing: 10) {
        HStack(spacing: 0) {
          if depth > 0 {
            Rectangle()
              .fill(RookPalette.line)
              .frame(width: CGFloat(depth * 18), height: 1)
          }
          Circle()
            .fill(depth == 0 ? RookPalette.accent : RookPalette.faint.opacity(0.72))
            .frame(width: depth == 0 ? 8 : 6, height: depth == 0 ? 8 : 6)
        }
        .frame(width: 12 + CGFloat(depth * 18), alignment: .trailing)

        VStack(alignment: .leading, spacing: 2) {
          Text(node.title)
            .font(.system(size: depth == 0 ? 15 : 13, weight: depth == 0 ? .semibold : .medium))
            .foregroundStyle(selected ? RookPalette.accent : RookPalette.ink)
          Text(node.kind.rawValue.uppercased())
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(RookPalette.faint)
        }
        Spacer()
        Text("\(node.mentionCount)")
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .foregroundStyle(RookPalette.faint)
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(selected ? RookPalette.accent : RookPalette.faint)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, depth == 0 ? 10 : 7)
      .background(selected ? RookPalette.accent.opacity(0.06) : Color.clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open \(node.kind.rawValue) \(node.title)")
  }

  private func libraryStatus(_ status: RookLibraryStatus) -> some View {
    Text(status.rawValue.uppercased())
      .foregroundStyle(
        status == .completed ? RookPalette.green : (status == .working ? RookPalette.accent : RookPalette.muted))
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

  private var alliesView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .bottom, spacing: 32) {
          VStack(alignment: .leading, spacing: 10) {
            Text("ALLIES")
              .font(.system(size: 12, weight: .bold))
              .tracking(1.2)
              .foregroundStyle(RookPalette.accent)
            Text("Rook’s connections")
              .font(.system(size: 38, design: .serif))
              .foregroundStyle(RookPalette.ink)
            Text("The services, local bridges, and future integrations Rook can bring onto the board.")
              .font(.system(size: 15))
              .foregroundStyle(RookPalette.muted)
              .lineSpacing(3)
          }

          Spacer(minLength: 28)

          HStack(spacing: 18) {
            connectionMetric("\(directConnectionCount)", "direct")
            summaryDivider
            connectionMetric("\(codexConnectionCount)", "via Codex")
            summaryDivider
            connectionMetric("\(localConnectionCount)", "local bridge")
            summaryDivider
            connectionMetric("\(plannedConnections.count)", "in line")
          }
        }

        Text("ON THE BOARD")
          .font(.system(size: 11, weight: .bold))
          .tracking(1.05)
          .foregroundStyle(RookPalette.muted)
          .padding(.top, 42)

        HStack(alignment: .top, spacing: 14) {
          ForEach(activeConnections) { connection in
            activeConnectionCard(connection)
          }
        }
        .padding(.top, 13)

        HStack(alignment: .firstTextBaseline) {
          Text("NEXT IN LINE")
            .font(.system(size: 11, weight: .bold))
            .tracking(1.05)
            .foregroundStyle(RookPalette.muted)
          Spacer()
          Text("RANKED BY USEFULNESS TO ROOK")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.75)
            .foregroundStyle(RookPalette.faint)
        }
        .padding(.top, 40)

        VStack(spacing: 0) {
          ForEach(plannedConnections) { connection in
            plannedConnectionRow(connection)
            if connection.id != plannedConnections.last?.id {
              Rectangle()
                .fill(RookPalette.line.opacity(0.72))
                .frame(height: 1)
                .padding(.leading, 66)
            }
          }
        }
        .padding(.top, 11)

        connectionLegend
          .padding(.top, 38)

        Color.clear.frame(height: 160)
      }
      .padding(.top, 48)
      .padding(.horizontal, 76)
      .frame(maxWidth: 1_080, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var activeConnections: [RookConnection] {
    Self.connections
      .filter { $0.state != .planned }
      .map(resolveConnection)
  }

  private var plannedConnections: [RookConnection] {
    Self.connections
      .filter { $0.state == .planned }
      .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
  }

  private var directConnectionCount: Int { activeConnections.filter { $0.state == .direct }.count }
  private var codexConnectionCount: Int { activeConnections.filter { $0.state == .codex }.count }
  private var localConnectionCount: Int { activeConnections.filter { $0.state == .local }.count }

  private func resolveConnection(_ connection: RookConnection) -> RookConnection {
    guard let provider = connection.oauthProvider else { return connection }
    let status = model.oauthStatus(for: provider)
    let state: RookConnectionState
    let note: String

    switch status.phase {
    case .connected:
      state = .direct
      note = status.accountLabel.map { "Direct OAuth · \($0)" } ?? "Direct OAuth · Keychain secured"
    case .connecting:
      state = .connecting
      note = status.detail ?? "Finish authorization in your browser"
    case .failed:
      state = .failed
      note = status.detail ?? "Open setup to try again"
    case .notConfigured, .disconnected:
      state = connection.state
      if connection.id == "spotify" {
        note = "Basic playback works · add OAuth for account data"
      } else {
        note = "Codex works · direct OAuth is available"
      }
    }

    return RookConnection(
      id: connection.id,
      priority: connection.priority,
      name: connection.name,
      summary: connection.summary,
      icon: connection.icon,
      state: state,
      connectionNote: note,
      oauthProvider: provider
    )
  }

  private func activeConnectionCard(_ connection: RookConnection) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center) {
        Image(systemName: connection.icon)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(RookPalette.ink)
          .frame(width: 38, height: 38)
          .background(RookPalette.accent.opacity(0.075), in: Circle())
        Spacer()
        if let priority = connection.priority {
          Text("#\(priority)")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(RookPalette.accent)
        }
      }

      Text(connection.name)
        .font(.system(size: 21, design: .serif))
        .foregroundStyle(RookPalette.ink)
        .padding(.top, 18)

      Text(connection.summary)
        .font(.system(size: 12.5))
        .foregroundStyle(RookPalette.muted)
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 7)

      Spacer(minLength: 20)

      Rectangle()
        .fill(RookPalette.line.opacity(0.78))
        .frame(height: 1)

      HStack(alignment: .center, spacing: 8) {
        Circle()
          .fill(connection.state.color)
          .frame(width: 7, height: 7)
        VStack(alignment: .leading, spacing: 2) {
          Text(connection.state.label.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.65)
            .foregroundStyle(connection.state.color)
          Text(connection.connectionNote)
            .font(.system(size: 10.5))
            .foregroundStyle(RookPalette.faint)
            .lineLimit(1)
        }
        Spacer(minLength: 6)
        if let provider = connection.oauthProvider {
          Button(oauthActionLabel(provider)) {
            handleOAuthAction(provider)
          }
          .buttonStyle(.plain)
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(RookPalette.accent)
          .disabled(model.oauthStatus(for: provider).phase == .connecting)
        }
      }
      .padding(.top, 13)
    }
    .padding(20)
    .frame(maxWidth: .infinity, minHeight: 224, alignment: .topLeading)
    .rookGlassCard(cornerRadius: 12, tintOpacity: 0.045, castsShadow: false)
  }

  private func plannedConnectionRow(_ connection: RookConnection) -> some View {
    HStack(spacing: 18) {
      Text(connection.priority.map(String.init) ?? "—")
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .foregroundStyle(RookPalette.paperBright)
        .frame(width: 34, height: 34)
        .background(RookPalette.ink, in: Circle())

      Image(systemName: connection.icon)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(RookPalette.accent)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 4) {
        Text(connection.name)
          .font(.system(size: 17, design: .serif))
          .foregroundStyle(RookPalette.ink)
        Text(connection.summary)
          .font(.system(size: 12.5))
          .foregroundStyle(RookPalette.muted)
          .lineLimit(2)
      }

      Spacer(minLength: 24)

      Text(connection.state.label.uppercased())
        .font(.system(size: 9.5, weight: .bold))
        .tracking(0.7)
        .foregroundStyle(RookPalette.faint)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RookPalette.line.opacity(0.36), in: Capsule())
    }
    .padding(.vertical, 16)
  }

  private func connectionMetric(_ value: String, _ label: String) -> some View {
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

  private func oauthActionLabel(_ provider: RookOAuthProvider) -> String {
    switch model.oauthStatus(for: provider).phase {
    case .notConfigured: return "Set up"
    case .disconnected, .failed: return provider == .spotify ? "Connect Spotify" : "Connect"
    case .connecting: return "Waiting…"
    case .connected: return "Manage"
    }
  }

  private func handleOAuthAction(_ provider: RookOAuthProvider) {
    let phase = model.oauthStatus(for: provider).phase
    if provider == .spotify, phase == .disconnected || phase == .failed {
      model.connectOAuth(provider)
      return
    }
    openOAuthManager(provider)
  }

  private func openOAuthManager(_ provider: RookOAuthProvider) {
    oauthClientIDDraft = model.oauthConfiguration.clientID(for: provider)
    oauthSetupError = nil
    confirmOAuthDisconnect = false
    model.selectedOAuthProvider = provider
  }

  private func oauthSetupSheet(_ provider: RookOAuthProvider) -> some View {
    let status = model.oauthStatus(for: provider)
    let requiresDeveloperSetup = provider == .google || status.phase == .notConfigured
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 9) {
          Text("DIRECT ALLY")
            .font(.system(size: 11, weight: .bold))
            .tracking(1)
            .foregroundStyle(RookPalette.accent)
          Text(provider == .google ? "Google connection" : "Spotify connection")
            .font(.system(size: 30, design: .serif))
            .foregroundStyle(RookPalette.ink)
        }
        Spacer()
        Button("Close") { model.selectedOAuthProvider = nil }
          .buttonStyle(.plain)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(RookPalette.muted)
      }

      oauthStatusBanner(status)
        .padding(.top, 22)

      Text(provider == .google ? googleOAuthExplanation : spotifyOAuthExplanation)
        .font(.system(size: 13.5))
        .foregroundStyle(RookPalette.muted)
        .lineSpacing(4)
        .padding(.top, 20)

      if requiresDeveloperSetup {
        VStack(alignment: .leading, spacing: 8) {
          Text("DEVELOPER CLIENT ID")
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.85)
            .foregroundStyle(RookPalette.muted)
          TextField(
            provider == .google ? "…apps.googleusercontent.com" : "Spotify Client ID",
            text: $oauthClientIDDraft
          )
          .textFieldStyle(.plain)
          .font(.system(size: 13, design: .monospaced))
          .foregroundStyle(RookPalette.ink)
          .padding(.horizontal, 13)
          .frame(height: 42)
          .rookGlassInset(cornerRadius: 7, tintOpacity: 0.025)
          Text(
            provider == .google
              ? "Create a Desktop app OAuth client. No client secret is stored."
              : "This development build has no Rook Spotify app identity. Register \(RookOAuthCallback.spotifyRedirectURI) as the redirect URI; no client secret is stored."
          )
          .font(.system(size: 11.5))
          .foregroundStyle(RookPalette.faint)
        }
        .padding(.top, 22)
      } else if provider == .spotify {
        Label("Sign-in opens securely in your browser. OAuth tokens stay in macOS Keychain.", systemImage: "lock.fill")
          .font(.system(size: 11.5, weight: .medium))
          .foregroundStyle(RookPalette.faint)
          .padding(.top, 18)
      }

      if let oauthSetupError {
        Label(oauthSetupError, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(RookPalette.accent)
          .padding(.top, 14)
      }

      HStack(spacing: 12) {
        if requiresDeveloperSetup {
          Button("Open developer setup") { model.openOAuthSetup(provider) }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RookPalette.accent)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .overlay {
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(RookPalette.accent.opacity(0.65), lineWidth: 1)
            }
        }

        Spacer()

        if status.phase == .connected {
          Button("Disconnect") { confirmOAuthDisconnect = true }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RookPalette.accent)
        } else {
          Button(
            status.phase == .connecting
              ? "Waiting for browser…" : (provider == .spotify ? "Connect Spotify" : "Save and connect")
          ) {
            if requiresDeveloperSetup {
              saveAndConnectOAuth(provider)
            } else {
              model.connectOAuth(provider)
            }
          }
          .buttonStyle(.plain)
          .font(.system(size: 13.5, weight: .semibold))
          .foregroundStyle(RookPalette.paperBright)
          .padding(.horizontal, 18)
          .padding(.vertical, 11)
          .background(RookPalette.ink, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
          .disabled(status.phase == .connecting)
        }
      }
      .padding(.top, 24)
    }
    .padding(30)
    .frame(width: 610)
    .rookGlassSheet()
    .confirmationDialog(
      "Disconnect \(provider.displayName) from Rook?",
      isPresented: $confirmOAuthDisconnect,
      titleVisibility: .visible
    ) {
      Button("Disconnect from this Mac", role: .destructive) {
        model.disconnectOAuth(provider)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Rook will remove its OAuth token from Keychain. Your provider account is not deleted.")
    }
  }

  private func oauthStatusBanner(_ status: RookOAuthConnectionStatus) -> some View {
    let color: Color = status.phase == .connected ? RookPalette.green : RookPalette.accent
    return HStack(alignment: .top, spacing: 11) {
      Circle()
        .fill(color)
        .frame(width: 8, height: 8)
        .padding(.top, 4)
      VStack(alignment: .leading, spacing: 3) {
        Text(oauthStatusTitle(status).uppercased())
          .font(.system(size: 10.5, weight: .bold))
          .tracking(0.75)
          .foregroundStyle(color)
        if let detail = status.accountLabel ?? status.detail, !detail.isEmpty {
          Text(detail)
            .font(.system(size: 12.5))
            .foregroundStyle(RookPalette.muted)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .rookGlassInset(cornerRadius: 8, tint: color, tintOpacity: 0.05)
  }

  private func oauthStatusTitle(_ status: RookOAuthConnectionStatus) -> String {
    switch status.phase {
    case .notConfigured: return "Developer setup required"
    case .disconnected: return "Ready to connect"
    case .connecting: return "Browser authorization in progress"
    case .connected: return "Connected directly"
    case .failed: return "Connection needs attention"
    }
  }

  private var googleOAuthExplanation: String {
    "One Google sign-in powers both Gmail and Google Calendar. This first direct layer requests Gmail read access and Calendar event access. Gmail sending, Calendar deletion, attendee changes, recurrence changes, and other consequential actions remain blocked by Rook’s policy."
  }

  private var spotifyOAuthExplanation: String {
    "Connect Spotify once to give Rook direct playlist and catalog playback, recent listening, top items, now-playing state, devices, and playback transfer without Codex or pawns. Basic Mac playback continues to work without a Spotify connection."
  }

  private func saveAndConnectOAuth(_ provider: RookOAuthProvider) {
    if let error = model.saveOAuthClientID(oauthClientIDDraft, for: provider) {
      oauthSetupError = error
      return
    }
    oauthSetupError = nil
    model.connectOAuth(provider)
  }

  private var connectionLegend: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("HOW ALLIES JOIN ROOK")
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.9)
        .foregroundStyle(RookPalette.accent)

      HStack(alignment: .top, spacing: 28) {
        connectionPath(
          "Direct",
          "Rook owns the sign-in and can keep a fast local snapshot.",
          icon: "bolt.fill"
        )
        connectionPath(
          "Via Codex",
          "Codex manages the account connection and performs live reads.",
          icon: "link"
        )
        connectionPath(
          "Local bridge",
          "Mac-native controls work without a separate account connection.",
          icon: "desktopcomputer"
        )
      }
    }
    .padding(22)
    .background(RookPalette.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(RookPalette.accent.opacity(0.17), lineWidth: 1)
    }
  }

  private func connectionPath(_ title: String, _ detail: String, icon: String) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: icon)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(RookPalette.accent)
        .frame(width: 24, height: 24)
        .background(RookPalette.accent.opacity(0.09), in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 12.5, weight: .semibold))
          .foregroundStyle(RookPalette.ink)
        Text(detail)
          .font(.system(size: 11.5))
          .foregroundStyle(RookPalette.muted)
          .lineSpacing(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private static let connections: [RookConnection] = [
    RookConnection(
      id: "gmail",
      priority: nil,
      name: "Gmail",
      summary: "Read and triage mail, understand threads, and prepare drafts. Sending remains approval-gated.",
      icon: "envelope",
      state: .codex,
      connectionNote: "Sign-in is managed by Codex",
      oauthProvider: .google
    ),
    RookConnection(
      id: "google_calendar",
      priority: nil,
      name: "Google Calendar",
      summary: "Read the primary calendar, detect conflicts, and safely create or update personal events.",
      icon: "calendar",
      state: .codex,
      connectionNote: "Sign-in is managed by Codex",
      oauthProvider: .google
    ),
    RookConnection(
      id: "spotify",
      priority: 1,
      name: "Spotify",
      summary: "Playlists, recently played, devices, search, and personalized playback.",
      icon: "music.note",
      state: .local,
      connectionNote: "Basic playback works · OAuth adds account commands",
      oauthProvider: .spotify
    ),
    RookConnection(
      id: "google_drive",
      priority: 2,
      name: "Google Drive + Docs",
      summary: "Find documents, create meeting notes, summarize files, and maintain project folders.",
      icon: "folder",
      state: .planned,
      connectionNote: ""
    ),
    RookConnection(
      id: "apple_reminders",
      priority: 3,
      name: "Apple Reminders",
      summary: "Tasks that synchronize automatically across your Mac and iPhone.",
      icon: "checklist",
      state: .planned,
      connectionNote: ""
    ),
    RookConnection(
      id: "apple_contacts",
      priority: 4,
      name: "Apple Contacts",
      summary: "Resolve people naturally when you say things like “text Jack” or “email Professor Smith.”",
      icon: "person.crop.circle",
      state: .planned,
      connectionNote: ""
    ),
    RookConnection(
      id: "github",
      priority: 5,
      name: "GitHub",
      summary: "Repository status, issues, pull requests, CI failures, and coding-task context.",
      icon: "chevron.left.forwardslash.chevron.right",
      state: .planned,
      connectionNote: ""
    ),
    RookConnection(
      id: "notion",
      priority: 6,
      name: "Notion",
      summary: "Project knowledge, task databases, notes, and long-term reference material.",
      icon: "square.grid.2x2",
      state: .planned,
      connectionNote: ""
    ),
    RookConnection(
      id: "slack",
      priority: 7,
      name: "Slack",
      summary: "Message triage, summaries, and drafted replies. Sending still requires approval.",
      icon: "number.square",
      state: .planned,
      connectionNote: ""
    ),
    RookConnection(
      id: "apple_shortcuts",
      priority: 8,
      name: "Apple Shortcuts",
      summary: "A universal local bridge into Mac apps that do not expose their own APIs.",
      icon: "switch.2",
      state: .planned,
      connectionNote: ""
    ),
    RookConnection(
      id: "home_assistant",
      priority: 9,
      name: "Home Assistant",
      summary: "Lights, thermostats, speakers, scenes, and household sensors.",
      icon: "house",
      state: .planned,
      connectionNote: ""
    ),
    RookConnection(
      id: "canvas_au",
      priority: 10,
      name: "Canvas + AU systems",
      summary: "Assignments, deadlines, announcements, and course schedules.",
      icon: "graduationcap",
      state: .planned,
      connectionNote: ""
    ),
  ]

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
        Image(
          systemName: typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "keyboard" : "arrow.up"
        )
        .font(.system(size: 21, weight: .medium))
        .foregroundStyle(RookPalette.ink)
        .frame(width: 44, height: 40)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(typedCommand.isEmpty ? "Focus command field" : "Ask Rook")
    }
    .padding(.horizontal, 34)
    .frame(height: 104)
    .rookGlassCard(cornerRadius: 18, tintOpacity: 0, interactive: true)
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(commandFocused ? RookPalette.accent : .clear, lineWidth: commandFocused ? 1.5 : 1)
    }
    .animation(.easeOut(duration: 0.16), value: commandFocused)
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
      .rookGlassInset(cornerRadius: 10, tintOpacity: 0.03)

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
    .rookGlassSheet()
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
