import Foundation

public struct RookConfig: Codable, Equatable, Sendable {
  public static let pawnCapacityPerPrompt = 10

  public var wakePhrase: String
  public var language: String
  public var onDeviceOnly: Bool
  public var silenceSeconds: Double
  public var followUpWindowSeconds: Double
  public var speechEngine: String
  public var neuralVoice: String
  public var neuralVoiceSpeed: Double
  public var voice: String
  public var voiceRate: Int
  public var frontModel: String
  public var model: String
  public var frontReasoningEffort: String
  public var reasoningEffort: String
  public var promptPolishEnabled: Bool
  public var promptPolishWaitMilliseconds: Int
  public var checkpointIntervalMinutes: Int
  public var maxPawns: Int
  public var enabledPawns: [String]
  public var codexPath: String
  public var queueScriptPath: String
  public var stateDirectory: String
  public var mobileRelayURL: String

  enum CodingKeys: String, CodingKey {
    case wakePhrase = "wake_phrase"
    case language
    case onDeviceOnly = "on_device_only"
    case silenceSeconds = "silence_seconds"
    case followUpWindowSeconds = "follow_up_window_seconds"
    case speechEngine = "speech_engine"
    case neuralVoice = "neural_voice"
    case neuralVoiceSpeed = "neural_voice_speed"
    case voice
    case voiceRate = "voice_rate"
    case frontModel = "front_model"
    case model
    case frontReasoningEffort = "front_reasoning_effort"
    case reasoningEffort = "reasoning_effort"
    case promptPolishEnabled = "prompt_polish_enabled"
    case promptPolishWaitMilliseconds = "prompt_polish_wait_milliseconds"
    case checkpointIntervalMinutes = "checkpoint_interval_minutes"
    case maxPawns = "max_pawns"
    case enabledPawns = "enabled_pawns"
    case codexPath = "codex_path"
    case queueScriptPath = "queue_script_path"
    case stateDirectory = "state_directory"
    case mobileRelayURL = "mobile_relay_url"
  }

  public init(
    wakePhrase: String,
    language: String,
    onDeviceOnly: Bool,
    silenceSeconds: Double,
    followUpWindowSeconds: Double,
    speechEngine: String,
    neuralVoice: String,
    neuralVoiceSpeed: Double,
    voice: String,
    voiceRate: Int,
    frontModel: String,
    model: String,
    frontReasoningEffort: String,
    reasoningEffort: String,
    promptPolishEnabled: Bool,
    promptPolishWaitMilliseconds: Int,
    checkpointIntervalMinutes: Int,
    maxPawns: Int,
    enabledPawns: [String] = PawnDefinition.defaultNames,
    codexPath: String,
    queueScriptPath: String,
    stateDirectory: String,
    mobileRelayURL: String = ""
  ) {
    self.wakePhrase = wakePhrase
    self.language = language
    self.onDeviceOnly = onDeviceOnly
    self.silenceSeconds = silenceSeconds
    self.followUpWindowSeconds = followUpWindowSeconds
    self.speechEngine = speechEngine
    self.neuralVoice = neuralVoice
    self.neuralVoiceSpeed = neuralVoiceSpeed
    self.voice = voice
    self.voiceRate = voiceRate
    self.frontModel = frontModel
    self.model = model
    self.frontReasoningEffort = frontReasoningEffort
    self.reasoningEffort = reasoningEffort
    self.promptPolishEnabled = promptPolishEnabled
    self.promptPolishWaitMilliseconds = promptPolishWaitMilliseconds
    self.checkpointIntervalMinutes = checkpointIntervalMinutes
    self.maxPawns = maxPawns
    self.enabledPawns = enabledPawns
    self.codexPath = codexPath
    self.queueScriptPath = queueScriptPath
    self.stateDirectory = stateDirectory
    self.mobileRelayURL = mobileRelayURL
  }

  public init(from decoder: Decoder) throws {
    let defaults = Self.recommended
    let container = try decoder.container(keyedBy: CodingKeys.self)
    wakePhrase = try container.decodeIfPresent(String.self, forKey: .wakePhrase) ?? defaults.wakePhrase
    language = try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language
    onDeviceOnly = try container.decodeIfPresent(Bool.self, forKey: .onDeviceOnly) ?? defaults.onDeviceOnly
    silenceSeconds = try container.decodeIfPresent(Double.self, forKey: .silenceSeconds) ?? defaults.silenceSeconds
    followUpWindowSeconds =
      try container.decodeIfPresent(Double.self, forKey: .followUpWindowSeconds) ?? defaults.followUpWindowSeconds
    speechEngine = try container.decodeIfPresent(String.self, forKey: .speechEngine) ?? defaults.speechEngine
    neuralVoice = try container.decodeIfPresent(String.self, forKey: .neuralVoice) ?? defaults.neuralVoice
    neuralVoiceSpeed =
      try container.decodeIfPresent(Double.self, forKey: .neuralVoiceSpeed) ?? defaults.neuralVoiceSpeed
    voice = try container.decodeIfPresent(String.self, forKey: .voice) ?? defaults.voice
    voiceRate = try container.decodeIfPresent(Int.self, forKey: .voiceRate) ?? defaults.voiceRate
    frontModel = try container.decodeIfPresent(String.self, forKey: .frontModel) ?? defaults.frontModel
    model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
    frontReasoningEffort =
      try container.decodeIfPresent(String.self, forKey: .frontReasoningEffort) ?? defaults.frontReasoningEffort
    reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) ?? defaults.reasoningEffort
    promptPolishEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .promptPolishEnabled) ?? defaults.promptPolishEnabled
    promptPolishWaitMilliseconds =
      try container.decodeIfPresent(Int.self, forKey: .promptPolishWaitMilliseconds)
      ?? defaults.promptPolishWaitMilliseconds
    checkpointIntervalMinutes =
      try container.decodeIfPresent(Int.self, forKey: .checkpointIntervalMinutes) ?? defaults.checkpointIntervalMinutes
    maxPawns = try container.decodeIfPresent(Int.self, forKey: .maxPawns) ?? defaults.maxPawns
    enabledPawns = try container.decodeIfPresent([String].self, forKey: .enabledPawns) ?? defaults.enabledPawns
    codexPath = try container.decodeIfPresent(String.self, forKey: .codexPath) ?? defaults.codexPath
    queueScriptPath = try container.decodeIfPresent(String.self, forKey: .queueScriptPath) ?? defaults.queueScriptPath
    stateDirectory = try container.decodeIfPresent(String.self, forKey: .stateDirectory) ?? defaults.stateDirectory
    mobileRelayURL = try container.decodeIfPresent(String.self, forKey: .mobileRelayURL) ?? defaults.mobileRelayURL
  }

  public static var recommended: RookConfig {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return RookConfig(
      wakePhrase: "rook wake up",
      language: "en-US",
      onDeviceOnly: true,
      silenceSeconds: 1.4,
      followUpWindowSeconds: 8.0,
      speechEngine: "kokoro",
      neuralVoice: "bm_daniel",
      neuralVoiceSpeed: 0.96,
      voice: "Daniel",
      voiceRate: 195,
      frontModel: "gpt-5.6-luna",
      model: "gpt-5.6-terra",
      frontReasoningEffort: "low",
      reasoningEffort: "high",
      promptPolishEnabled: false,
      promptPolishWaitMilliseconds: 900,
      checkpointIntervalMinutes: 30,
      maxPawns: Self.pawnCapacityPerPrompt,
      enabledPawns: PawnDefinition.defaultNames,
      codexPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
      queueScriptPath: "\(home)/.codex/skills/rook/scripts/rook_queue.py",
      stateDirectory: "\(home)/.codex/rook/core",
      mobileRelayURL: ""
    )
  }

  public var stateURL: URL {
    URL(fileURLWithPath: NSString(string: stateDirectory).expandingTildeInPath, isDirectory: true)
  }

  public var rookWorkspaceURL: URL { stateURL.deletingLastPathComponent() }
  public var actionQueueURL: URL { rookWorkspaceURL.appendingPathComponent("action_queue.json") }
  public var configURL: URL { stateURL.appendingPathComponent("config.json") }
  public var schemaURL: URL { stateURL.appendingPathComponent("response_schema.json") }
  public var frontSchemaURL: URL { stateURL.appendingPathComponent("front_response_schema.json") }
  public var sessionURL: URL { stateURL.appendingPathComponent("session.json") }
  public var frontSessionURL: URL { stateURL.appendingPathComponent("front_session.json") }
  public var lastResponseURL: URL { stateURL.appendingPathComponent("last_response.txt") }
  public var lastResponseJSONURL: URL { stateURL.appendingPathComponent("last_response.json") }
  public var pendingConversationURL: URL { stateURL.appendingPathComponent("pending_conversation.json") }
  public var codexLogURL: URL { stateURL.appendingPathComponent("codex.log") }
  public var frontCodexLogURL: URL { stateURL.appendingPathComponent("front_codex.log") }
  public var appServerLogURL: URL { stateURL.appendingPathComponent("app_server.log") }
  public var promptPolishLogURL: URL { stateURL.appendingPathComponent("prompt_polish.log") }
  public var statusURL: URL { stateURL.appendingPathComponent("status.json") }
  public var weatherCacheURL: URL { stateURL.appendingPathComponent("weather_cache.json") }
  public var mediaURL: URL { rookWorkspaceURL.appendingPathComponent("media", isDirectory: true) }
  public var codexSessionsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/sessions", isDirectory: true)
  }
  public var reflexAlertsURL: URL { stateURL.appendingPathComponent("reflex_alerts.json") }
  public var pawnRunsURL: URL { stateURL.appendingPathComponent("pawn_runs.json") }
  public var connectionsConfigURL: URL { stateURL.appendingPathComponent("connections.json") }
  public var checkpointSchemaURL: URL { stateURL.appendingPathComponent("checkpoint_schema.json") }
  public var checkpointLogURL: URL { stateURL.appendingPathComponent("checkpoint.log") }
  public var libraryURL: URL { rookWorkspaceURL.appendingPathComponent("library", isDirectory: true) }
  public var libraryIndexURL: URL { libraryURL.appendingPathComponent("index.json") }
  public var libraryGraphURL: URL { libraryURL.appendingPathComponent("graph.json") }
  public var libraryNodesURL: URL { libraryURL.appendingPathComponent("nodes", isDirectory: true) }
  public var libraryConversationsURL: URL { libraryURL.appendingPathComponent("conversations", isDirectory: true) }
  public var libraryTasksURL: URL { libraryURL.appendingPathComponent("tasks", isDirectory: true) }
  public var checkpointsURL: URL { libraryURL.appendingPathComponent("checkpoints", isDirectory: true) }
  public var checkpointHistoryURL: URL { checkpointsURL.appendingPathComponent("history", isDirectory: true) }
  public var latestCheckpointURL: URL { checkpointsURL.appendingPathComponent("latest.json") }
  public var preferencesURL: URL { libraryURL.appendingPathComponent("preferences", isDirectory: true) }
  public var preferencesProfileURL: URL { preferencesURL.appendingPathComponent("profile.json") }
  public var libraryPreparationsURL: URL { libraryURL.appendingPathComponent("preparations", isDirectory: true) }
  public func taskLogURL(requestID: UUID) -> URL {
    stateURL.appendingPathComponent("task_\(requestID.uuidString.lowercased()).log")
  }

  public var normalizedEnabledPawns: [String] {
    PawnDefinition.defaultNames
  }

  public var effectiveMaxPawns: Int {
    Self.pawnCapacityPerPrompt
  }

  public mutating func normalizePawnSettings() {
    enabledPawns = PawnDefinition.defaultNames
    maxPawns = Self.pawnCapacityPerPrompt
    checkpointIntervalMinutes = max(5, checkpointIntervalMinutes)
    promptPolishWaitMilliseconds = min(max(200, promptPolishWaitMilliseconds), 3_000)
  }

  public static func loadOrCreate() throws -> RookConfig {
    let defaults = RookConfig.recommended
    try defaults.ensureStateDirectory()
    if FileManager.default.fileExists(atPath: defaults.configURL.path) {
      let data = try Data(contentsOf: defaults.configURL)
      var loaded = try JSONDecoder().decode(RookConfig.self, from: data)
      loaded.normalizePawnSettings()
      try loaded.ensureStateDirectory()
      try loaded.ensureSchema()
      try loaded.save()
      return loaded
    }
    try defaults.save()
    try defaults.ensureSchema()
    return defaults
  }

  public func save() throws {
    try ensureStateDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try Self.writePrivate(try encoder.encode(self), to: configURL)
  }

  public func ensureStateDirectory() throws {
    try FileManager.default.createDirectory(
      at: rookWorkspaceURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rookWorkspaceURL.path)
    try FileManager.default.createDirectory(
      at: stateURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateURL.path)
    try FileManager.default.createDirectory(
      at: mediaURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mediaURL.path)
  }

  public func ensureSchema() throws {
    try Self.writePrivate(Data(RookResponse.outputSchema.utf8), to: schemaURL)
    try Self.writePrivate(Data(QuickRookResponse.outputSchema.utf8), to: frontSchemaURL)
    try Self.writePrivate(Data(RookCheckpoint.outputSchema.utf8), to: checkpointSchemaURL)
  }

  public static func writePrivate(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temporary, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: url)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
