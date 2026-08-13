import SwiftUI

private enum RookMobileTab: String, CaseIterable {
  case home
  case activity
  case library
  case moves

  var title: String {
    switch self {
    case .home: return "Home"
    case .activity: return "Activity"
    case .library: return "Library"
    case .moves: return "Moves"
    }
  }

  var symbol: String {
    switch self {
    case .home: return "house"
    case .activity: return "bolt.horizontal.circle"
    case .library: return "books.vertical"
    case .moves: return "checkmark.shield"
    }
  }
}

struct RookMobileRootView: View {
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var model: RookMobileViewModel
  @ObservedObject private var voice: RookMobileVoiceController
  @State private var selectedTab: RookMobileTab
  @State private var isSettingsPresented = false

  init(model: RookMobileViewModel) {
    self.model = model
    voice = model.voice
    let requested = CommandLine.arguments.first { $0.hasPrefix("--ui-preview-tab=") }
      .map { String($0.dropFirst("--ui-preview-tab=".count)) }
    _selectedTab = State(initialValue: RookMobileTab(rawValue: requested ?? "") ?? .home)
    _isSettingsPresented = State(
      initialValue: CommandLine.arguments.contains("--ui-preview-settings")
    )
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack {
        RookMobileHomeView(
          model: model,
          voice: voice,
          selectedTab: $selectedTab,
          isSettingsPresented: $isSettingsPresented
        )
      }
      .tag(RookMobileTab.home)
      .tabItem { Label(RookMobileTab.home.title, systemImage: RookMobileTab.home.symbol) }

      NavigationStack {
        RookMobileActivityView(model: model)
      }
      .tag(RookMobileTab.activity)
      .tabItem { Label(RookMobileTab.activity.title, systemImage: RookMobileTab.activity.symbol) }

      NavigationStack {
        RookMobileLibraryView(model: model)
      }
      .tag(RookMobileTab.library)
      .tabItem { Label(RookMobileTab.library.title, systemImage: RookMobileTab.library.symbol) }

      NavigationStack {
        RookMobileMovesView(model: model)
      }
      .tag(RookMobileTab.moves)
      .tabItem { Label(RookMobileTab.moves.title, systemImage: RookMobileTab.moves.symbol) }
    }
    .tint(RookMobilePalette.accent)
    .background(RookMobilePalette.paper.ignoresSafeArea())
    .sheet(isPresented: $isSettingsPresented) {
      RookMobileSettingsView(model: model)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $model.isPairingPresented) {
      RookMobilePairingView(model: model)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    .alert(
      "Rook needs attention",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "Try again.")
    }
    .task { model.start() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { model.start() }
    }
  }
}

private struct RookMobileHomeView: View {
  @ObservedObject var model: RookMobileViewModel
  @ObservedObject var voice: RookMobileVoiceController
  @Binding var selectedTab: RookMobileTab
  @Binding var isSettingsPresented: Bool

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        masthead
        statusRail.padding(.top, 20)

        if model.isWorking || !model.activeActivity.isEmpty {
          liveWork.padding(.top, 30)
        }

        if let response = model.latestResponse {
          latestResponse(response).padding(.top, 34)
          ForEach(response.canvas) { block in
            RookMobileCanvasView(block: block)
              .padding(.top, 16)
          }
        } else {
          emptyState.padding(.top, 36)
        }

        if !model.pendingMoves.isEmpty {
          movePrompt.padding(.top, 18)
        }

        quickAsks.padding(.top, 34)
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 132)
    }
    .scrollIndicators(.hidden)
    .background(RookMobilePalette.paper.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      commandComposer
    }
  }

  private var masthead: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 3) {
        Text("ROOK")
          .font(.system(size: 34, weight: .medium, design: .serif))
          .tracking(-0.5)
          .foregroundStyle(RookMobilePalette.accent)
        Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(RookMobilePalette.faint)
      }
      Spacer()
      Button {
        isSettingsPresented = true
      } label: {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(RookMobilePalette.ink)
          .frame(width: 42, height: 42)
          .background(RookMobilePalette.paperBright, in: Circle())
          .overlay { Circle().stroke(RookMobilePalette.line.opacity(0.78)) }
      }
      .accessibilityLabel("Rook settings")
    }
  }

  private var statusRail: some View {
    Button {
      if model.connectionState.isConnected {
        isSettingsPresented = true
      } else {
        model.isPairingPresented = true
      }
    } label: {
      HStack(spacing: 12) {
        RookMobileStatusDot(color: connectionColor, pulses: model.isWorking)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.connectionState.label.uppercased())
            .font(.system(size: 9, weight: .black))
            .tracking(0.9)
            .foregroundStyle(RookMobilePalette.faint)
          Text(model.connectionState.detail)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(RookMobilePalette.ink)
            .lineLimit(1)
        }
        Spacer(minLength: 8)
        if !model.activeActivity.isEmpty {
          statusMetric("\(model.activeActivity.count)", "active")
        }
        if !model.pendingMoves.isEmpty {
          RookMobileRule(vertical: true).frame(height: 28)
          statusMetric("\(model.pendingMoves.count)", "moves")
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(RookMobilePalette.faint)
      }
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottom) { RookMobileRule() }
  }

  private func statusMetric(_ value: String, _ label: String) -> some View {
    VStack(alignment: .trailing, spacing: 0) {
      Text(value)
        .font(.system(size: 15, weight: .bold, design: .rounded))
        .foregroundStyle(RookMobilePalette.ink)
      Text(label.uppercased())
        .font(.system(size: 7.5, weight: .black))
        .tracking(0.6)
        .foregroundStyle(RookMobilePalette.faint)
    }
  }

  private var liveWork: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack {
        RookMobileSectionLabel("IN PROGRESS", color: RookMobilePalette.accent)
        Spacer()
        ProgressView().controlSize(.small).tint(RookMobilePalette.accent)
      }
      Text(model.isWorking ? model.statusText : model.activeActivity.first?.label ?? model.statusText)
        .font(.system(size: 20, weight: .medium, design: .serif))
        .foregroundStyle(RookMobilePalette.ink)
        .contentTransition(.opacity)
      if !model.pawns.isEmpty {
        pawnStrip(model.pawns)
      } else if let run = model.activeActivity.first {
        pawnStrip(run.pawns)
      }
    }
    .padding(18)
    .background(RookMobilePalette.paperBright, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(RookMobilePalette.accent.opacity(0.34))
    }
    .animation(.easeInOut(duration: 0.2), value: model.statusText)
  }

  private func latestResponse(_ response: RookResponse) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        RookMobileSectionLabel(model.isWorking ? "LIVE ANSWER" : "LATEST ANSWER")
        Spacer()
        if response.requiresApproval {
          Label("Review", systemImage: "checkmark.shield")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(RookMobilePalette.accent)
        }
      }
      HStack(alignment: .top, spacing: 14) {
        RoundedRectangle(cornerRadius: 2)
          .fill(RookMobilePalette.accent)
          .frame(width: 3)
        Text.rookMarkdown(response.displayText)
          .font(.system(size: 21, design: .serif))
          .foregroundStyle(RookMobilePalette.ink)
          .lineSpacing(5)
          .textSelection(.enabled)
      }
      if !model.isWorking {
        Text(model.statusText)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(RookMobilePalette.faint)
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 15) {
      Image(systemName: "iphone.and.arrow.forward.inward")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(RookMobilePalette.accent)
      Text("Your Mac stays the brain.")
        .font(.system(size: 27, design: .serif))
        .foregroundStyle(RookMobilePalette.ink)
      Text("Ask, follow live work, read Canvas results, inspect the Library, and decide exact Moves from here.")
        .font(.system(size: 15))
        .foregroundStyle(RookMobilePalette.muted)
        .lineSpacing(4)
      Button("Pair with Mac") { model.isPairingPresented = true }
        .buttonStyle(.borderedProminent)
        .tint(RookMobilePalette.accent)
        .controlSize(.large)
    }
  }

  private var movePrompt: some View {
    Button {
      selectedTab = .moves
    } label: {
      HStack(spacing: 13) {
        Image(systemName: "checkmark.shield.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(RookMobilePalette.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("\(model.pendingMoves.count) move\(model.pendingMoves.count == 1 ? "" : "s") waiting")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(RookMobilePalette.ink)
          Text("Review the exact change before Rook records a decision.")
            .font(.system(size: 11))
            .foregroundStyle(RookMobilePalette.muted)
        }
        Spacer()
        Image(systemName: "arrow.right")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(RookMobilePalette.accent)
      }
      .padding(16)
      .background(RookMobilePalette.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
  }

  private var quickAsks: some View {
    VStack(alignment: .leading, spacing: 12) {
      RookMobileSectionLabel("QUICK ASKS")
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 9) {
          quickAsk("Brief me", symbol: "sun.max", command: "Give me a concise brief for today")
          quickAsk("What’s next?", symbol: "clock", command: "What's next?")
          quickAsk("Weather", symbol: "cloud.sun", command: "What's the weather today?")
          quickAsk("Plan my day", symbol: "calendar.badge.clock", command: "Help me plan the rest of my day")
        }
      }
      .contentMargins(.horizontal, 0)
    }
  }

  private func quickAsk(_ label: String, symbol: String, command: String) -> some View {
    Button {
      model.submitPreset(command)
    } label: {
      Label(label, systemImage: symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(RookMobilePalette.ink)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(RookMobilePalette.paperBright, in: Capsule())
        .overlay { Capsule().stroke(RookMobilePalette.line.opacity(0.8)) }
    }
    .buttonStyle(.plain)
  }

  private func pawnStrip(_ pawns: [PawnReport]) -> some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Array(pawns.enumerated()), id: \.offset) { _, pawn in
          HStack(spacing: 7) {
            Circle()
              .fill(RookMobileStyle.statusColor(pawn.status))
              .frame(width: 7, height: 7)
            Text(pawn.instanceLabel)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(RookMobilePalette.ink)
          }
          .padding(.horizontal, 11)
          .padding(.vertical, 8)
          .background(RookMobilePalette.paperBright.opacity(0.86), in: Capsule())
        }
      }
    }
  }

  private var commandComposer: some View {
    VStack(spacing: 8) {
      if voice.isListening {
        HStack(spacing: 8) {
          RookMobileStatusDot(color: RookMobilePalette.accent, pulses: true)
          Text("Listening on this iPhone")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(RookMobilePalette.accent)
          Spacer()
          Text("Tap stop when finished")
            .font(.system(size: 10))
            .foregroundStyle(RookMobilePalette.faint)
        }
        .padding(.horizontal, 7)
      }

      HStack(alignment: .bottom, spacing: 10) {
        TextField("Ask Rook…", text: $model.commandText, axis: .vertical)
          .font(.system(size: 16))
          .lineLimit(1...4)
          .padding(.horizontal, 16)
          .padding(.vertical, 13)
          .background(RookMobilePalette.paperBright, in: RoundedRectangle(cornerRadius: 18))
          .overlay { RoundedRectangle(cornerRadius: 18).stroke(RookMobilePalette.line.opacity(0.85)) }
          .submitLabel(.send)
          .onSubmit { model.submitCommand() }

        Button(action: voice.toggle) {
          Image(systemName: voice.isListening ? "stop.fill" : "mic.fill")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(RookMobilePalette.accent, in: Circle())
            .scaleEffect(voice.isListening ? 1 + min(voice.level, 0.35) : 1)
            .animation(.easeOut(duration: 0.1), value: voice.level)
        }
        .accessibilityLabel(voice.isListening ? "Stop listening" : "Start push to talk")

        if !model.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Button {
            model.submitCommand(source: voice.transcript.isEmpty ? .typed : .voice)
          } label: {
            Image(systemName: "arrow.up")
              .font(.system(size: 17, weight: .black))
              .foregroundStyle(.white)
              .frame(width: 48, height: 48)
              .background(RookMobilePalette.ink, in: Circle())
          }
          .transition(.scale.combined(with: .opacity))
          .accessibilityLabel("Send command")
        }
      }
      .animation(.spring(response: 0.25, dampingFraction: 0.82), value: model.commandText.isEmpty)
    }
    .padding(.horizontal, 14)
    .padding(.top, 9)
    .padding(.bottom, 7)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) { RookMobileRule() }
  }

  private var connectionColor: Color {
    switch model.connectionState {
    case .connected: return RookMobilePalette.green
    case .connecting: return RookMobilePalette.accent
    case .unpaired, .disconnected, .failed: return RookMobilePalette.ink
    }
  }
}

private struct RookMobileActivityView: View {
  @ObservedObject var model: RookMobileViewModel

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        RookMobileScreenHeader(
          eyebrow: "ACTIVITY",
          title: "Rook at work",
          detail: "Live crews and their attributable task status. Central Rook still owns every answer."
        )

        activitySummary.padding(.top, 24)

        if model.activity.isEmpty {
          RookMobileEmptyState(
            symbol: "bolt.horizontal.circle",
            title: "No task activity yet",
            detail: "Multi-step requests and pawn crews will appear here after they start on your Mac."
          )
          .padding(.top, 42)
        } else {
          if !model.activeActivity.isEmpty {
            activitySection("ACTIVE", items: model.activeActivity, active: true)
              .padding(.top, 34)
          }
          if !model.recentActivity.isEmpty {
            activitySection("RECENT", items: model.recentActivity, active: false)
              .padding(.top, 34)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 120)
    }
    .scrollIndicators(.hidden)
    .background(RookMobilePalette.paper.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
  }

  private var activitySummary: some View {
    HStack(spacing: 0) {
      activityMetric("\(model.activeActivity.count)", "Active crews")
      RookMobileRule(vertical: true).padding(.horizontal, 22)
      activityMetric("\(model.activity.flatMap(\.pawns).filter { $0.status == "working" }.count)", "Pawns working")
      RookMobileRule(vertical: true).padding(.horizontal, 22)
      activityMetric("\(model.recentActivity.count)", "Recent runs")
      Spacer(minLength: 0)
    }
    .frame(height: 54)
    .overlay(alignment: .bottom) { RookMobileRule() }
  }

  private func activityMetric(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value)
        .font(.system(size: 23, weight: .medium, design: .serif))
        .foregroundStyle(RookMobilePalette.ink)
      Text(label.uppercased())
        .font(.system(size: 7.5, weight: .black))
        .tracking(0.55)
        .foregroundStyle(RookMobilePalette.faint)
        .lineLimit(1)
    }
  }

  private func activitySection(
    _ label: String,
    items: [RookMobileActivityItem],
    active: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      RookMobileSectionLabel(label, color: active ? RookMobilePalette.accent : RookMobilePalette.faint)
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        NavigationLink {
          RookMobileActivityDetail(item: item)
        } label: {
          RookMobileActivityRow(item: item, active: active)
        }
        .buttonStyle(.plain)
        if index < items.count - 1 { RookMobileRule().padding(.leading, 20) }
      }
    }
  }
}

private struct RookMobileActivityRow: View {
  let item: RookMobileActivityItem
  let active: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      RookMobileStatusDot(color: RookMobileStyle.activityColor(item.status), pulses: active)
        .padding(.top, 5)
      VStack(alignment: .leading, spacing: 7) {
        Text(item.label)
          .font(.system(size: 17, weight: .medium, design: .serif))
          .foregroundStyle(RookMobilePalette.ink)
          .lineLimit(2)
        HStack(spacing: 8) {
          Text(RookMobileStyle.activityLabel(item.status).uppercased())
            .font(.system(size: 8.5, weight: .black))
            .tracking(0.65)
            .foregroundStyle(RookMobileStyle.activityColor(item.status))
          Text("·")
          Text("\(item.pawns.count) pawn\(item.pawns.count == 1 ? "" : "s")")
          Text("·")
          Text(item.updatedAt.formatted(.relative(presentation: .named)))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(RookMobilePalette.faint)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(RookMobilePalette.faint)
        .padding(.top, 6)
    }
    .padding(.vertical, 9)
    .contentShape(Rectangle())
  }
}

private struct RookMobileActivityDetail: View {
  let item: RookMobileActivityItem

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        RookMobileSectionLabel("TASK ACTIVITY", color: RookMobileStyle.activityColor(item.status))
        Text(item.label)
          .font(.system(size: 30, design: .serif))
          .foregroundStyle(RookMobilePalette.ink)
          .padding(.top, 12)
        Label(
          RookMobileStyle.activityLabel(item.status),
          systemImage: item.status == .working ? "bolt.fill" : "checkmark.circle.fill"
        )
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(RookMobileStyle.activityColor(item.status))
        .padding(.top, 14)

        RookMobileRule().padding(.vertical, 24)
        RookMobileSectionLabel("PAWN REPORTS")

        VStack(spacing: 0) {
          ForEach(Array(item.pawns.enumerated()), id: \.offset) { index, pawn in
            HStack(alignment: .top, spacing: 13) {
              Circle()
                .fill(RookMobileStyle.statusColor(pawn.status))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(pawn.instanceLabel)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(RookMobilePalette.ink)
                  Spacer()
                  Text(pawn.status.uppercased())
                    .font(.system(size: 8, weight: .black))
                    .tracking(0.6)
                    .foregroundStyle(RookMobileStyle.statusColor(pawn.status))
                }
                Text(pawn.task)
                  .font(.system(size: 13))
                  .foregroundStyle(RookMobilePalette.muted)
                  .lineSpacing(3)
              }
            }
            .padding(.vertical, 15)
            if index < item.pawns.count - 1 { RookMobileRule().padding(.leading, 21) }
          }
        }
        .padding(.top, 8)

        Text("Rook shows assignments and attributable status here, never hidden reasoning or raw pawn messages.")
          .font(.system(size: 11))
          .foregroundStyle(RookMobilePalette.faint)
          .lineSpacing(3)
          .padding(.top, 28)
      }
      .padding(20)
    }
    .background(RookMobilePalette.paper.ignoresSafeArea())
    .navigationTitle("Activity")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private enum RookMobileLibraryScope: String, CaseIterable, Identifiable {
  case all = "All"
  case completed = "Completed"
  case attention = "Attention"

  var id: String { rawValue }
}

private struct RookMobileLibraryView: View {
  @ObservedObject var model: RookMobileViewModel
  @State private var query = ""
  @State private var scope: RookMobileLibraryScope = .all

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        RookMobileScreenHeader(
          eyebrow: "LIBRARY",
          title: "What Rook remembers",
          detail: "Durable outcomes from your Mac, newest first. Live project files remain authoritative."
        )

        Picker("Library scope", selection: $scope) {
          ForEach(RookMobileLibraryScope.allCases) { value in
            Text(value.rawValue).tag(value)
          }
        }
        .pickerStyle(.segmented)
        .padding(.top, 22)

        if filteredLibrary.isEmpty {
          RookMobileEmptyState(
            symbol: "books.vertical",
            title: query.isEmpty ? "Library is quiet" : "No matching work",
            detail: query.isEmpty
              ? "Completed and blocked Rook work will appear here after syncing from your Mac."
              : "Try a project name, outcome, or a different status."
          )
          .padding(.top, 42)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(filteredLibrary.enumerated()), id: \.element.id) { index, item in
              NavigationLink {
                RookMobileLibraryDetail(item: item)
              } label: {
                RookMobileLibraryRow(item: item)
              }
              .buttonStyle(.plain)
              if index < filteredLibrary.count - 1 { RookMobileRule().padding(.leading, 18) }
            }
          }
          .padding(.top, 22)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 120)
    }
    .scrollIndicators(.hidden)
    .background(RookMobilePalette.paper.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
    .searchable(text: $query, prompt: "Search Rook Library")
  }

  private var filteredLibrary: [RookMobileLibraryItem] {
    let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return model.library.filter { item in
      let matchesScope: Bool
      switch scope {
      case .all: matchesScope = true
      case .completed: matchesScope = item.status == "completed"
      case .attention: matchesScope = item.status == "blocked" || item.status == "interrupted"
      }
      guard matchesScope else { return false }
      guard !cleaned.isEmpty else { return true }
      return "\(item.label) \(item.summary)".lowercased().contains(cleaned)
    }
  }
}

private struct RookMobileLibraryRow: View {
  let item: RookMobileLibraryItem

  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      Image(systemName: RookMobileStyle.librarySymbol(item.status))
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(RookMobileStyle.statusColor(item.status))
        .frame(width: 30, height: 30)
        .background(RookMobileStyle.statusColor(item.status).opacity(0.08), in: Circle())
      VStack(alignment: .leading, spacing: 6) {
        Text(item.label)
          .font(.system(size: 17, weight: .medium, design: .serif))
          .foregroundStyle(RookMobilePalette.ink)
        Text(item.summary)
          .font(.system(size: 12.5))
          .foregroundStyle(RookMobilePalette.muted)
          .lineLimit(2)
          .lineSpacing(2)
        Text(item.updatedAt.formatted(.relative(presentation: .named)))
          .font(.system(size: 9.5, weight: .semibold))
          .foregroundStyle(RookMobilePalette.faint)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(RookMobilePalette.faint)
        .padding(.top, 7)
    }
    .padding(.vertical, 14)
    .contentShape(Rectangle())
  }
}

private struct RookMobileLibraryDetail: View {
  let item: RookMobileLibraryItem

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        RookMobileSectionLabel(item.status.uppercased(), color: RookMobileStyle.statusColor(item.status))
        Text(item.label)
          .font(.system(size: 31, design: .serif))
          .foregroundStyle(RookMobilePalette.ink)
          .padding(.top, 12)
        Text(item.updatedAt.formatted(date: .abbreviated, time: .shortened))
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(RookMobilePalette.faint)
          .padding(.top, 8)
        RookMobileRule().padding(.vertical, 24)
        Text.rookMarkdown(item.summary)
          .font(.system(size: 18, design: .serif))
          .foregroundStyle(RookMobilePalette.ink)
          .lineSpacing(5)
          .textSelection(.enabled)
        Text("Open Rook on your Mac to inspect the complete archive, project graph, source evidence, and pawn reports.")
          .font(.system(size: 11.5))
          .foregroundStyle(RookMobilePalette.faint)
          .lineSpacing(3)
          .padding(.top, 28)
      }
      .padding(20)
    }
    .background(RookMobilePalette.paper.ignoresSafeArea())
    .navigationTitle("Library")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct RookMobileMovesView: View {
  @ObservedObject var model: RookMobileViewModel

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        RookMobileScreenHeader(
          eyebrow: "MOVES",
          title: "Your decision queue",
          detail:
            "Each approval applies only to the exact move shown. Execution stays behind Rook’s normal Mac boundary."
        )

        if model.moves.isEmpty {
          RookMobileEmptyState(
            symbol: "checkmark.shield",
            title: "Nothing needs a decision",
            detail: "Consequential actions stay here until you approve or reject the exact proposal."
          )
          .padding(.top, 42)
        } else {
          if !model.pendingMoves.isEmpty {
            movesSection("WAITING FOR YOU", items: model.pendingMoves, pending: true)
              .padding(.top, 30)
          }
          if !model.approvedMoves.isEmpty {
            movesSection("RECORDED", items: model.approvedMoves, pending: false)
              .padding(.top, 34)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 12)
      .padding(.bottom, 120)
    }
    .scrollIndicators(.hidden)
    .background(RookMobilePalette.paper.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
  }

  private func movesSection(_ label: String, items: [RookMobileMove], pending: Bool) -> some View {
    VStack(alignment: .leading, spacing: 13) {
      RookMobileSectionLabel(label, color: pending ? RookMobilePalette.accent : RookMobilePalette.faint)
      ForEach(items) { move in
        RookMobileMoveCard(model: model, move: move)
      }
    }
  }
}

private struct RookMobileMoveCard: View {
  @ObservedObject var model: RookMobileViewModel
  let move: RookMobileMove

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(move.label)
            .font(.system(size: 23, weight: .medium, design: .serif))
            .foregroundStyle(RookMobilePalette.ink)
          Text(move.risk.uppercased())
            .font(.system(size: 8.5, weight: .black))
            .tracking(0.7)
            .foregroundStyle(move.status == .pending ? RookMobilePalette.accent : RookMobilePalette.faint)
        }
        Spacer()
        Image(systemName: move.status == .pending ? "hourglass" : "checkmark.circle.fill")
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(move.status == .pending ? RookMobilePalette.accent : RookMobilePalette.green)
      }

      Text(move.details)
        .font(.system(size: 14))
        .foregroundStyle(RookMobilePalette.muted)
        .lineSpacing(4)

      VStack(alignment: .leading, spacing: 5) {
        Text("EXACT ACTION")
          .font(.system(size: 8, weight: .black))
          .tracking(0.75)
          .foregroundStyle(RookMobilePalette.faint)
        Text(move.proposedAction)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(RookMobilePalette.ink)
          .lineSpacing(3)
      }
      .padding(13)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RookMobilePalette.paper, in: RoundedRectangle(cornerRadius: 12))

      if move.status == .pending {
        HStack(spacing: 10) {
          Button("Reject", role: .destructive) { model.decide(.reject, move: move) }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
          Button {
            model.decide(.approve, move: move)
          } label: {
            Label("Approve", systemImage: "faceid")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(RookMobilePalette.accent)
        }
      } else {
        Label("Approval recorded on your Mac", systemImage: "checkmark.circle.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(RookMobilePalette.green)
      }
    }
    .padding(18)
    .background(RookMobilePalette.paperBright, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(
          move.status == .pending ? RookMobilePalette.accent.opacity(0.24) : RookMobilePalette.line.opacity(0.75)
        )
    }
  }
}

private struct RookMobileSettingsView: View {
  @ObservedObject var model: RookMobileViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          connectionSection

          RookMobileSectionLabel("ALLIES ON YOUR MAC")
            .padding(.top, 34)
          alliesSection.padding(.top, 8)

          RookMobileSectionLabel("PRIVACY")
            .padding(.top, 34)
          privacySection.padding(.top, 8)

          if RookMobileKeychain.loadSessionToken() != nil {
            Button("Forget this Mac", role: .destructive) {
              model.forgetPairing()
              dismiss()
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.top, 34)
          }
        }
        .padding(20)
        .padding(.bottom, 40)
      }
      .background(RookMobilePalette.paper.ignoresSafeArea())
      .navigationTitle("Rook on this iPhone")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var connectionSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 13) {
        RookMobileStatusDot(color: connectionColor, pulses: model.isWorking)
        VStack(alignment: .leading, spacing: 3) {
          Text(model.connectionState.label.uppercased())
            .font(.system(size: 9, weight: .black))
            .tracking(0.8)
            .foregroundStyle(RookMobilePalette.faint)
          Text(model.connectionState.detail)
            .font(.system(size: 18, weight: .medium, design: .serif))
            .foregroundStyle(RookMobilePalette.ink)
        }
      }

      Text(
        "The Mac keeps Codex, files, connections, and execution authority. This iPhone holds only its private pairing session."
      )
      .font(.system(size: 13))
      .foregroundStyle(RookMobilePalette.muted)
      .lineSpacing(3)

      if !model.connectionState.isConnected {
        HStack(spacing: 10) {
          Button("Reconnect") { model.reconnect() }
            .buttonStyle(.bordered)
            .controlSize(.large)
          Button("Pair with QR") {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
              model.isPairingPresented = true
            }
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .tint(RookMobilePalette.accent)
        }
      }
    }
    .padding(18)
    .background(RookMobilePalette.paperBright, in: RoundedRectangle(cornerRadius: 18))
    .overlay { RoundedRectangle(cornerRadius: 18).stroke(RookMobilePalette.line.opacity(0.78)) }
  }

  private var alliesSection: some View {
    VStack(spacing: 0) {
      if model.allies.isEmpty {
        Text("Connection status will appear after Rook syncs with your Mac.")
          .font(.system(size: 13))
          .foregroundStyle(RookMobilePalette.muted)
          .padding(.vertical, 12)
      } else {
        ForEach(Array(model.allies.enumerated()), id: \.element.id) { index, ally in
          HStack(spacing: 13) {
            Image(systemName: RookMobileStyle.allySymbol(ally.id))
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(RookMobilePalette.ink)
              .frame(width: 34, height: 34)
              .background(RookMobilePalette.accent.opacity(0.07), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
              Text(ally.label)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(RookMobilePalette.ink)
              Text(ally.detail)
                .font(.system(size: 11))
                .foregroundStyle(RookMobilePalette.muted)
            }
            Spacer()
            Text(RookMobileStyle.allyLabel(ally.state).uppercased())
              .font(.system(size: 7.5, weight: .black))
              .tracking(0.55)
              .foregroundStyle(RookMobileStyle.allyColor(ally.state))
          }
          .padding(.vertical, 13)
          if index < model.allies.count - 1 { RookMobileRule().padding(.leading, 47) }
        }
      }
      Text("Manage ally sign-in from Rook on your Mac.")
        .font(.system(size: 10.5))
        .foregroundStyle(RookMobilePalette.faint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }
  }

  private var privacySection: some View {
    VStack(spacing: 0) {
      privacyRow("Codex authentication stays on your Mac", symbol: "macbook.and.iphone")
      RookMobileRule().padding(.leading, 45)
      privacyRow("Approvals require device authentication", symbol: "faceid")
      RookMobileRule().padding(.leading, 45)
      privacyRow("No ambient audio is stored", symbol: "waveform.badge.mic")
    }
  }

  private func privacyRow(_ label: String, symbol: String) -> some View {
    HStack(spacing: 13) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(RookMobilePalette.accent)
        .frame(width: 32)
      Text(label)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(RookMobilePalette.ink)
      Spacer()
    }
    .padding(.vertical, 13)
  }

  private var connectionColor: Color {
    switch model.connectionState {
    case .connected: return RookMobilePalette.green
    case .connecting: return RookMobilePalette.accent
    case .unpaired, .disconnected, .failed: return RookMobilePalette.ink
    }
  }
}

private struct RookMobilePairingView: View {
  @ObservedObject var model: RookMobileViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 0) {
        Image(systemName: "qrcode.viewfinder")
          .font(.system(size: 38, weight: .medium))
          .foregroundStyle(RookMobilePalette.accent)
        Text("Pair without an address")
          .font(.system(size: 29, design: .serif))
          .foregroundStyle(RookMobilePalette.ink)
          .padding(.top, 18)
        Text("On your Mac, choose Rook → Pair iPhone. Then scan the five-minute code below.")
          .font(.system(size: 14))
          .foregroundStyle(RookMobilePalette.muted)
          .lineSpacing(4)
          .padding(.top, 9)

        Button {
          model.isScannerPresented = true
        } label: {
          Label("Scan the QR code", systemImage: "camera.fill")
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(RookMobilePalette.accent)
        .padding(.top, 26)

        if case .connecting = model.connectionState {
          HStack(spacing: 10) {
            ProgressView()
            Text("Finding and securing your Mac…")
              .font(.system(size: 13, weight: .semibold))
          }
          .foregroundStyle(RookMobilePalette.muted)
          .padding(.top, 18)
        }

        Spacer()
        Text("The QR contains a one-time pairing secret—not your Codex, Gmail, Calendar, or Spotify credentials.")
          .font(.system(size: 11))
          .foregroundStyle(RookMobilePalette.faint)
          .lineSpacing(3)
      }
      .padding(24)
      .background(RookMobilePalette.paper.ignoresSafeArea())
      .navigationTitle("Pair Rook")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
      .sheet(isPresented: $model.isScannerPresented) {
        NavigationStack {
          ZStack(alignment: .bottom) {
            RookMobileQRScanner(
              onCode: model.handleScannedPairingCode,
              onError: { message in
                model.errorMessage = message
                model.isScannerPresented = false
              }
            )
            Text("Point your camera at the QR code shown by Rook on your Mac.")
              .font(.footnote.weight(.medium))
              .multilineTextAlignment(.center)
              .padding(14)
              .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
              .padding()
          }
          .ignoresSafeArea(edges: .bottom)
          .navigationTitle("Scan Rook")
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { model.isScannerPresented = false }
            }
          }
        }
      }
    }
  }
}

private struct RookMobileScreenHeader: View {
  let eyebrow: String
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      RookMobileSectionLabel(eyebrow)
      Text(title)
        .font(.system(size: 31, design: .serif))
        .foregroundStyle(RookMobilePalette.ink)
        .padding(.top, 9)
      Text(detail)
        .font(.system(size: 13))
        .foregroundStyle(RookMobilePalette.muted)
        .lineSpacing(3)
        .padding(.top, 7)
    }
  }
}

private struct RookMobileEmptyState: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 25, weight: .medium))
        .foregroundStyle(RookMobilePalette.accent)
      Text(title)
        .font(.system(size: 22, design: .serif))
        .foregroundStyle(RookMobilePalette.ink)
      Text(detail)
        .font(.system(size: 13))
        .foregroundStyle(RookMobilePalette.muted)
        .lineSpacing(3)
    }
  }
}

private struct RookMobileSectionLabel: View {
  let value: String
  let color: Color

  init(_ value: String, color: Color = RookMobilePalette.accent) {
    self.value = value
    self.color = color
  }

  var body: some View {
    Text(value)
      .font(.system(size: 9.5, weight: .black))
      .tracking(1.05)
      .foregroundStyle(color)
  }
}

private struct RookMobileStatusDot: View {
  let color: Color
  let pulses: Bool
  @State private var pulse = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 9, height: 9)
      .background {
        Circle()
          .stroke(color.opacity(0.26), lineWidth: 5)
          .scaleEffect(pulses && pulse ? 1.7 : 0.9)
          .opacity(pulses && pulse ? 0 : 1)
      }
      .onAppear { updatePulse() }
      .onChange(of: pulses) { _, _ in updatePulse() }
  }

  private func updatePulse() {
    pulse = false
    guard pulses else { return }
    withAnimation(.easeOut(duration: 1.15).repeatForever(autoreverses: false)) {
      pulse = true
    }
  }
}

private struct RookMobileRule: View {
  var vertical = false

  var body: some View {
    Rectangle()
      .fill(RookMobilePalette.line.opacity(0.7))
      .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
  }
}

private enum RookMobileStyle {
  static func statusColor(_ status: String) -> Color {
    switch status {
    case "completed": return RookMobilePalette.green
    case "working", "queued": return RookMobilePalette.accent
    case "blocked", "interrupted": return RookMobilePalette.ink
    default: return RookMobilePalette.faint
    }
  }

  static func librarySymbol(_ status: String) -> String {
    switch status {
    case "completed": return "checkmark"
    case "working": return "bolt.fill"
    case "blocked": return "exclamationmark"
    case "interrupted": return "pause.fill"
    default: return "circle"
    }
  }

  static func activityColor(_ status: RookMobileActivityStatus) -> Color {
    switch status {
    case .completed: return RookMobilePalette.green
    case .queued, .working: return RookMobilePalette.accent
    case .blocked, .interrupted: return RookMobilePalette.ink
    }
  }

  static func activityLabel(_ status: RookMobileActivityStatus) -> String {
    switch status {
    case .queued: return "Queued"
    case .working: return "Working"
    case .completed: return "Completed"
    case .blocked: return "Blocked"
    case .interrupted: return "Interrupted"
    }
  }

  static func allyColor(_ state: RookMobileAllyState) -> Color {
    switch state {
    case .direct, .codex, .local: return RookMobilePalette.green
    case .connecting: return RookMobilePalette.accent
    case .attention: return RookMobilePalette.ink
    }
  }

  static func allyLabel(_ state: RookMobileAllyState) -> String {
    switch state {
    case .direct: return "Direct"
    case .codex: return "Codex"
    case .local: return "Local"
    case .connecting: return "Connecting"
    case .attention: return "Attention"
    }
  }

  static func allySymbol(_ id: String) -> String {
    switch id {
    case "gmail": return "envelope"
    case "google_calendar": return "calendar"
    case "spotify": return "music.note"
    default: return "link"
    }
  }
}

#Preview {
  RookMobileRootView(model: RookMobileViewModel(preview: true))
}
