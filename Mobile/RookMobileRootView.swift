import SwiftUI

private enum RookMobileTab: String, CaseIterable {
  case home
  case activity
  case library
  case moves

  var title: String {
    switch self {
    case .home: return "Rook"
    case .activity: return "Activity"
    case .library: return "Library"
    case .moves: return "Moves"
    }
  }

  var symbol: String {
    switch self {
    case .home: return "bubble.left.and.bubble.right"
    case .activity: return "waveform.path.ecg"
    case .library: return "books.vertical"
    case .moves: return "checkmark.circle"
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
      .badge(model.pendingMoves.count)
    }
    .tint(RookMobilePalette.accent)
    .sheet(isPresented: $isSettingsPresented) {
      RookMobileSettingsView(model: model)
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
      LazyVStack(alignment: .leading, spacing: 18) {
        if !model.connectionState.isConnected {
          connectionPrompt
        }

        if model.isWorking || !model.activeActivity.isEmpty {
          workingRow
        }

        if let response = model.latestResponse {
          responseView(response)
          ForEach(response.canvas) { block in
            RookMobileCanvasView(block: block)
          }
        } else if model.connectionState.isConnected {
          ContentUnavailableView(
            "Ask Rook anything",
            systemImage: "sparkles",
            description: Text("Type a request or tap the microphone.")
          )
          .frame(maxWidth: .infinity)
          .padding(.top, 72)
        }

        if !model.pendingMoves.isEmpty {
          pendingMoveLink
        }
      }
      .padding(.horizontal, 18)
      .padding(.top, 10)
      .padding(.bottom, 112)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(RookMobilePalette.groupedBackground.ignoresSafeArea())
    .navigationTitle("Rook")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          isSettingsPresented = true
        } label: {
          Image(systemName: "gearshape")
        }
        .accessibilityLabel("Settings")
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      commandComposer
    }
  }

  private var connectionPrompt: some View {
    Button {
      model.isPairingPresented = true
    } label: {
      HStack(spacing: 12) {
        Image(systemName: connectionSymbol)
          .font(.title3)
          .foregroundStyle(RookMobilePalette.accent)
          .frame(width: 34, height: 34)
          .background(RookMobilePalette.accent.opacity(0.12), in: Circle())
        VStack(alignment: .leading, spacing: 2) {
          Text(model.connectionState.label)
            .font(.headline)
            .foregroundStyle(.primary)
          Text(model.connectionState.detail)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(16)
      .background(RookMobilePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private var workingRow: some View {
    HStack(spacing: 12) {
      ProgressView()
        .controlSize(.small)
      Text(model.isWorking ? model.statusText : model.activeActivity.first?.label ?? model.statusText)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .contentTransition(.opacity)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 2)
    .animation(.easeInOut(duration: 0.2), value: model.statusText)
  }

  private func responseView(_ response: RookResponse) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(model.isWorking ? "Answering" : "Latest")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if response.requiresApproval {
          Button {
            selectedTab = .moves
          } label: {
            Label("Review", systemImage: "checkmark.circle")
              .font(.caption.weight(.semibold))
          }
        }
      }

      Text.rookMarkdown(response.displayText)
        .font(.title3)
        .foregroundStyle(.primary)
        .lineSpacing(5)
        .textSelection(.enabled)
    }
    .padding(.vertical, 4)
  }

  private var pendingMoveLink: some View {
    Button {
      selectedTab = .moves
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "checkmark.circle.fill")
          .font(.title3)
          .foregroundStyle(RookMobilePalette.accent)
        Text("\(model.pendingMoves.count) move\(model.pendingMoves.count == 1 ? "" : "s") to review")
          .font(.headline)
          .foregroundStyle(.primary)
        Spacer()
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(16)
      .background(RookMobilePalette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private var commandComposer: some View {
    VStack(spacing: 7) {
      if voice.isListening {
        HStack(spacing: 7) {
          Circle()
            .fill(RookMobilePalette.accent)
            .frame(width: 7, height: 7)
          Text("Listening…")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(.horizontal, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }

      HStack(alignment: .bottom, spacing: 8) {
        TextField("Ask Rook", text: $model.commandText, axis: .vertical)
          .font(.body)
          .lineLimit(1...4)
          .padding(.leading, 16)
          .padding(.vertical, 12)
          .submitLabel(.send)
          .onSubmit { submitText() }

        Button(action: composerAction) {
          Image(systemName: composerSymbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(composerHasText || voice.isListening ? .white : RookMobilePalette.accent)
            .frame(width: 38, height: 38)
            .background(
              composerHasText || voice.isListening
                ? RookMobilePalette.accent
                : RookMobilePalette.accent.opacity(0.12),
              in: Circle()
            )
        }
        .padding(.trailing, 6)
        .padding(.bottom, 5)
        .accessibilityLabel(composerAccessibilityLabel)
      }
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(RookMobilePalette.separator.opacity(0.35))
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 6)
    .background(.ultraThinMaterial)
    .animation(.snappy(duration: 0.22), value: voice.isListening)
  }

  private var composerHasText: Bool {
    !model.commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var composerSymbol: String {
    if voice.isListening { return "stop.fill" }
    return composerHasText ? "arrow.up" : "mic.fill"
  }

  private var composerAccessibilityLabel: String {
    if voice.isListening { return "Stop listening" }
    return composerHasText ? "Send command" : "Start push to talk"
  }

  private func composerAction() {
    if voice.isListening {
      voice.toggle()
    } else if composerHasText {
      submitText()
    } else {
      voice.toggle()
    }
  }

  private func submitText() {
    guard composerHasText else { return }
    model.submitCommand(source: voice.transcript.isEmpty ? .typed : .voice)
  }

  private var connectionSymbol: String {
    switch model.connectionState {
    case .connecting: return "arrow.triangle.2.circlepath"
    case .unpaired: return "macbook.and.iphone"
    case .disconnected, .failed: return "exclamationmark.triangle"
    case .connected: return "checkmark.circle.fill"
    }
  }
}

private struct RookMobileActivityView: View {
  @ObservedObject var model: RookMobileViewModel

  var body: some View {
    Group {
      if model.activity.isEmpty {
        ContentUnavailableView(
          "No activity yet",
          systemImage: "waveform.path.ecg",
          description: Text("Work started on your Mac will appear here.")
        )
      } else {
        List {
          if !model.activeActivity.isEmpty {
            Section("Active") {
              ForEach(model.activeActivity) { item in
                NavigationLink {
                  RookMobileActivityDetail(item: item)
                } label: {
                  RookMobileActivityRow(item: item, active: true)
                }
              }
            }
          }

          if !model.recentActivity.isEmpty {
            Section("Recent") {
              ForEach(model.recentActivity) { item in
                NavigationLink {
                  RookMobileActivityDetail(item: item)
                } label: {
                  RookMobileActivityRow(item: item, active: false)
                }
              }
            }
          }
        }
        .listStyle(.insetGrouped)
      }
    }
    .background(RookMobilePalette.groupedBackground)
    .navigationTitle("Activity")
  }
}

private struct RookMobileActivityRow: View {
  let item: RookMobileActivityItem
  let active: Bool

  var body: some View {
    HStack(spacing: 12) {
      RookMobileStatusDot(color: RookMobileStyle.activityColor(item.status), pulses: active)
      VStack(alignment: .leading, spacing: 4) {
        Text(item.label)
          .font(.body.weight(.medium))
          .lineLimit(2)
        Text(activityDetail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var activityDetail: String {
    let relative = item.updatedAt.formatted(.relative(presentation: .named))
    return
      "\(RookMobileStyle.activityLabel(item.status)) · \(item.pawns.count) pawn\(item.pawns.count == 1 ? "" : "s") · \(relative)"
  }
}

private struct RookMobileActivityDetail: View {
  let item: RookMobileActivityItem

  var body: some View {
    List {
      Section {
        LabeledContent("Status", value: RookMobileStyle.activityLabel(item.status))
        LabeledContent("Updated", value: item.updatedAt.formatted(date: .abbreviated, time: .shortened))
      }

      Section {
        ForEach(Array(item.pawns.enumerated()), id: \.offset) { _, pawn in
          HStack(alignment: .top, spacing: 12) {
            RookMobileStatusDot(color: RookMobileStyle.statusColor(pawn.status), pulses: pawn.status == "working")
              .padding(.top, 5)
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(pawn.instanceLabel)
                  .font(.body.weight(.medium))
                Spacer()
                Text(pawn.status.capitalized)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Text(pawn.task)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }
      } header: {
        Text("Pawns")
      } footer: {
        Text("Rook shows attributable status, never hidden reasoning or raw pawn messages.")
      }
    }
    .navigationTitle(item.label)
    .navigationBarTitleDisplayMode(.inline)
  }
}

private enum RookMobileLibraryScope: String, CaseIterable, Identifiable {
  case all = "All"
  case completed = "Completed"
  case attention = "Needs Attention"

  var id: String { rawValue }
}

private struct RookMobileLibraryView: View {
  @ObservedObject var model: RookMobileViewModel
  @State private var query = ""
  @State private var scope: RookMobileLibraryScope = .all

  var body: some View {
    Group {
      if filteredLibrary.isEmpty {
        ContentUnavailableView(
          query.isEmpty ? "Library is empty" : "No results",
          systemImage: query.isEmpty ? "books.vertical" : "magnifyingglass",
          description: Text(emptyDescription)
        )
      } else {
        List(filteredLibrary) { item in
          NavigationLink {
            RookMobileLibraryDetail(item: item)
          } label: {
            RookMobileLibraryRow(item: item)
          }
        }
        .listStyle(.insetGrouped)
      }
    }
    .background(RookMobilePalette.groupedBackground)
    .navigationTitle("Library")
    .searchable(text: $query, prompt: "Search Library")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Status", selection: $scope) {
            ForEach(RookMobileLibraryScope.allCases) { value in
              Text(value.rawValue).tag(value)
            }
          }
        } label: {
          Image(
            systemName: scope == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter Library")
      }
    }
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

  private var emptyDescription: String {
    if !query.isEmpty { return "Try another project name or outcome." }
    return scope == .all ? "Completed work will appear here after it syncs." : "Nothing matches this filter."
  }
}

private struct RookMobileLibraryRow: View {
  let item: RookMobileLibraryItem

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: RookMobileStyle.librarySymbol(item.status))
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(RookMobileStyle.statusColor(item.status))
        .frame(width: 30, height: 30)
        .background(RookMobileStyle.statusColor(item.status).opacity(0.1), in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(item.label)
          .font(.body.weight(.medium))
        Text(item.summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Text(item.updatedAt.formatted(.relative(presentation: .named)))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 4)
  }
}

private struct RookMobileLibraryDetail: View {
  let item: RookMobileLibraryItem

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Label(item.status.capitalized, systemImage: RookMobileStyle.librarySymbol(item.status))
          .font(.subheadline.weight(.medium))
          .foregroundStyle(RookMobileStyle.statusColor(item.status))
        Text.rookMarkdown(item.summary)
          .font(.title3)
          .lineSpacing(5)
          .textSelection(.enabled)
        Text(item.updatedAt.formatted(date: .long, time: .shortened))
          .font(.footnote)
          .foregroundStyle(.secondary)
        Divider()
        Text("Open Rook on your Mac to inspect the full archive, project graph, source evidence, and pawn reports.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(20)
    }
    .background(RookMobilePalette.groupedBackground.ignoresSafeArea())
    .navigationTitle(item.label)
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct RookMobileMovesView: View {
  @ObservedObject var model: RookMobileViewModel

  var body: some View {
    Group {
      if model.moves.isEmpty {
        ContentUnavailableView(
          "Nothing to review",
          systemImage: "checkmark.circle",
          description: Text("Consequential actions wait here for your decision.")
        )
      } else {
        List {
          if !model.pendingMoves.isEmpty {
            Section("Needs Your Review") {
              ForEach(model.pendingMoves) { move in
                RookMobileMoveRow(model: model, move: move)
              }
            }
          }

          if !model.approvedMoves.isEmpty {
            Section("Recorded") {
              ForEach(model.approvedMoves) { move in
                RookMobileMoveRow(model: model, move: move)
              }
            }
          }
        }
        .listStyle(.insetGrouped)
      }
    }
    .background(RookMobilePalette.groupedBackground)
    .navigationTitle("Moves")
  }
}

private struct RookMobileMoveRow: View {
  @ObservedObject var model: RookMobileViewModel
  let move: RookMobileMove

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(move.label)
          .font(.headline)
        Spacer()
        Text(move.risk)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(move.details)
        .font(.subheadline)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 3) {
        Text("Exact action")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(move.proposedAction)
          .font(.subheadline)
      }

      if move.status == .pending {
        HStack(spacing: 10) {
          Button("Reject", role: .destructive) {
            model.decide(.reject, move: move)
          }
          .buttonStyle(.bordered)
          .frame(maxWidth: .infinity)

          Button {
            model.decide(.approve, move: move)
          } label: {
            Label("Approve", systemImage: "faceid")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .tint(RookMobilePalette.accent)
        }
        .controlSize(.large)
      } else {
        Label("Approval recorded on your Mac", systemImage: "checkmark.circle.fill")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(RookMobilePalette.green)
      }
    }
    .padding(.vertical, 6)
  }
}

private struct RookMobileSettingsView: View {
  @ObservedObject var model: RookMobileViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 12) {
            RookMobileStatusDot(color: connectionColor, pulses: model.isWorking)
            VStack(alignment: .leading, spacing: 2) {
              Text(model.connectionState.label)
              Text(model.connectionState.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          if !model.connectionState.isConnected {
            Button("Reconnect") { model.reconnect() }
            Button("Pair with QR") {
              dismiss()
              DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                model.isPairingPresented = true
              }
            }
          }
        } header: {
          Text("Connection")
        } footer: {
          Text("Your Mac keeps Codex, files, connections, and execution authority.")
        }

        Section {
          if model.allies.isEmpty {
            Text("Connection status will appear after Rook syncs.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(model.allies) { ally in
              HStack(spacing: 12) {
                Image(systemName: RookMobileStyle.allySymbol(ally.id))
                  .foregroundStyle(RookMobilePalette.accent)
                  .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                  Text(ally.label)
                  Text(ally.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(RookMobileStyle.allyLabel(ally.state))
                  .font(.caption)
                  .foregroundStyle(RookMobileStyle.allyColor(ally.state))
              }
            }
          }
        } header: {
          Text("Allies on Your Mac")
        } footer: {
          Text("Manage sign-in from Rook on your Mac.")
        }

        Section("Privacy") {
          Label("Codex authentication stays on your Mac", systemImage: "macbook.and.iphone")
          Label("Approvals use device authentication", systemImage: "faceid")
          Label("Ambient audio is never stored", systemImage: "waveform.badge.mic")
        }

        if RookMobileKeychain.loadSessionToken() != nil {
          Section {
            Button("Forget This Mac", role: .destructive) {
              model.forgetPairing()
              dismiss()
            }
          }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }

  private var connectionColor: Color {
    switch model.connectionState {
    case .connected: return RookMobilePalette.green
    case .connecting: return RookMobilePalette.accent
    case .unpaired, .disconnected, .failed: return .secondary
    }
  }
}

private struct RookMobilePairingView: View {
  @ObservedObject var model: RookMobileViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(spacing: 20) {
        Spacer(minLength: 6)
        Image(systemName: "qrcode.viewfinder")
          .font(.system(size: 48, weight: .light))
          .foregroundStyle(RookMobilePalette.accent)
        VStack(spacing: 8) {
          Text("Pair with your Mac")
            .font(.title2.weight(.semibold))
          Text("On your Mac, choose Rook → Pair iPhone, then scan the five-minute code.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        Button {
          model.isScannerPresented = true
        } label: {
          Label("Scan QR Code", systemImage: "camera.fill")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(RookMobilePalette.accent)

        if case .connecting = model.connectionState {
          HStack(spacing: 10) {
            ProgressView()
            Text("Securing the private link…")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
        Text("The code contains a one-time pairing secret, never your account credentials.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(24)
      .background(RookMobilePalette.groupedBackground.ignoresSafeArea())
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
          .stroke(color.opacity(0.24), lineWidth: 4)
          .scaleEffect(pulses && pulse ? 1.65 : 0.9)
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

private enum RookMobileStyle {
  static func statusColor(_ status: String) -> Color {
    switch status {
    case "completed": return RookMobilePalette.green
    case "working", "queued": return RookMobilePalette.accent
    case "blocked", "interrupted": return .orange
    default: return .secondary
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
    case .blocked, .interrupted: return .orange
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
    case .attention: return .orange
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
