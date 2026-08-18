import Foundation

/// The ordered, inspectable list of work Rook should attempt without a task
/// pawn. Keeping this in one place prevents a new direct adapter from being
/// added to the app while the general router still treats its keywords as
/// research.
public enum RookDirectCapabilityID: String, CaseIterable, Codable, Equatable, Sendable {
  case reflex
  case weather
  case spotify
  case screenCapture = "screen_capture"
  case computerControl = "computer_control"
  case librarianCheckpoint = "librarian_checkpoint"
}

public enum RookCapabilityEffect: String, Codable, Equatable, Sendable {
  case readOnly = "read_only"
  case localMutation = "local_mutation"
  case externalMutation = "external_mutation"
  case mixed
}

public enum RookCapabilityRetryRule: String, Codable, Equatable, Sendable {
  case readOnce = "read_once"
  case retryReadOnce = "retry_read_once"
  case neverRepeatMutation = "never_repeat_mutation"
  case intentSpecific = "intent_specific"
}

/// The minimum adapter, retry, and verification boundary Central Rook must
/// preserve when a native capability participates in dependent work. A
/// contract describes ownership; it does not let the exact gate interpret a
/// new semantic or compound request.
public struct RookCapabilityExecutionContract: Codable, Equatable, Sendable {
  public let capability: RookDirectCapabilityID
  public let adapter: String
  public let effect: RookCapabilityEffect
  public let retryRule: RookCapabilityRetryRule
  public let verification: String
  public let mayFeedDependentWork: Bool

  public init(
    capability: RookDirectCapabilityID,
    adapter: String,
    effect: RookCapabilityEffect,
    retryRule: RookCapabilityRetryRule,
    verification: String,
    mayFeedDependentWork: Bool
  ) {
    self.capability = capability
    self.adapter = adapter
    self.effect = effect
    self.retryRule = retryRule
    self.verification = verification
    self.mayFeedDependentWork = mayFeedDependentWork
  }
}

public struct RookDirectCapabilityDescriptor: Equatable, Sendable {
  public let id: RookDirectCapabilityID
  public let title: String
  public let adapter: String
  public let handles: String
  public let fallback: String
  public let executionContract: RookCapabilityExecutionContract

  public init(
    id: RookDirectCapabilityID,
    title: String,
    adapter: String,
    handles: String,
    fallback: String,
    executionContract: RookCapabilityExecutionContract
  ) {
    self.id = id
    self.title = title
    self.adapter = adapter
    self.handles = handles
    self.fallback = fallback
    self.executionContract = executionContract
  }
}

public enum RookDirectCapabilityResolution: Equatable, Sendable {
  case reflex(RookReflexIntent)
  case weather(RookWeatherRequest)
  case spotify(RookSpotifyIntent)
  case screenCapture(RookScreenCaptureRequest)
  case computerControl(RookComputerIntent)
  case librarianCheckpoint(LocalRookDecision)
  case hybrid(RookHybridCapabilityPlan)
  case clarification(capability: RookDirectCapabilityID, message: String)
  case fallThrough(RookDirectCapabilityID)
  case unclaimed
}

/// Rook's behind-the-scenes capability cheat sheet and exact fast-path gate.
/// Only typed, deterministic parsers may bypass Central Rook. Semantic,
/// compound, unsupported, and uncertain requests remain unclaimed so Central
/// Rook can understand the complete outcome and choose the right workers.
public enum RookDirectCapabilityGuide {
  public static let cheatSheet: [RookDirectCapabilityDescriptor] = [
    RookDirectCapabilityDescriptor(
      id: .reflex,
      title: "Rook Reflex",
      adapter: "On-device controller",
      handles: "Calculations, conversions, local alerts, Mac status, and volume",
      fallback: "Let Central Rook interpret anything beyond the exact Reflex grammar",
      executionContract: RookCapabilityExecutionContract(
        capability: .reflex,
        adapter: "rook_reflex",
        effect: .mixed,
        retryRule: .intentSpecific,
        verification:
          "Verify the exact computed value, device reading, or local mutation state "
          + "for the parsed Reflex intent.",
        mayFeedDependentWork: true
      )
    ),
    RookDirectCapabilityDescriptor(
      id: .weather,
      title: "Weather",
      adapter: "Open-Meteo",
      handles: "Current, tomorrow, and one-to-seven-day forecasts",
      fallback: "Let Central Rook interpret anything beyond the exact forecast grammar",
      executionContract: RookCapabilityExecutionContract(
        capability: .weather,
        adapter: "open_meteo",
        effect: .readOnly,
        retryRule: .retryReadOnce,
        verification:
          "Require the requested location and days, an as-of time, source attribution, "
          + "and one forecast item per requested day.",
        mayFeedDependentWork: true
      )
    ),
    RookDirectCapabilityDescriptor(
      id: .spotify,
      title: "Spotify",
      adapter: "Spotify Web API or narrow Mac playback control",
      handles: "Playback, playlists, catalog, history, top items, and devices",
      fallback: "Let Central Rook interpret anything beyond the exact Spotify grammar",
      executionContract: RookCapabilityExecutionContract(
        capability: .spotify,
        adapter: "spotify_web_api",
        effect: .mixed,
        retryRule: .neverRepeatMutation,
        verification:
          "Verify playback mutations with a bounded player read; accept read receipts "
          + "only for the requested Spotify state.",
        mayFeedDependentWork: true
      )
    ),
    RookDirectCapabilityDescriptor(
      id: .screenCapture,
      title: "Private screen capture",
      adapter: "ScreenCaptureKit",
      handles: "Explicit display, front-window, and named-window inspection",
      fallback: "Let Central Rook interpret anything beyond explicit capture grammar",
      executionContract: RookCapabilityExecutionContract(
        capability: .screenCapture,
        adapter: "screen_capture_kit",
        effect: .readOnly,
        retryRule: .readOnce,
        verification:
          "Bind the private captured asset to the exact requested display or uniquely "
          + "visible window and current request ID.",
        mayFeedDependentWork: true
      )
    ),
    RookDirectCapabilityDescriptor(
      id: .computerControl,
      title: "Mac controls",
      adapter: "Native app, browser, and playback controller",
      handles: "Open apps or pages, web search, and basic media controls",
      fallback: "Let Central Rook decide whether deliberate Computer Use is needed",
      executionContract: RookCapabilityExecutionContract(
        capability: .computerControl,
        adapter: "native_mac_controller",
        effect: .mixed,
        retryRule: .neverRepeatMutation,
        verification:
          "Verify the exact application, browser destination, search, or media outcome "
          + "without switching to Computer Use.",
        mayFeedDependentWork: true
      )
    ),
    RookDirectCapabilityDescriptor(
      id: .librarianCheckpoint,
      title: "Fresh Librarian context",
      adapter: "Private local Library",
      handles: "Stable operational answers backed by a fresh checkpoint",
      fallback: "Let Central Rook decide whether a live read is needed",
      executionContract: RookCapabilityExecutionContract(
        capability: .librarianCheckpoint,
        adapter: "private_library",
        effect: .readOnly,
        retryRule: .readOnce,
        verification: "Require a checkpoint inside its freshness window and preserve its explicit source as-of time.",
        mayFeedDependentWork: true
      )
    ),
  ]

  public static func resolve(
    _ rawCommand: String,
    cachedDecision: LocalRookDecision? = nil
  ) -> RookDirectCapabilityResolution {
    if let intent = RookReflexCommandParser.parse(rawCommand) {
      return .reflex(intent)
    }
    if let request = RookWeatherCommandParser.parse(rawCommand) {
      return .weather(request)
    }
    if let intent = RookSpotifyCommandParser.parse(rawCommand) {
      return .spotify(intent)
    }
    if let request = RookScreenCaptureCommandParser.parse(rawCommand) {
      return .screenCapture(request)
    }
    if let intent = RookComputerCommandParser.parse(rawCommand) {
      return .computerControl(intent)
    }
    // Approval follow-ups must never fall into the ordinary no-tools answer
    // stream. Central Rook still has to bind the phrase to one exact reviewed
    // action before Computer Use may cross the final boundary.
    if RookComputerOperatorRouting.isApprovalFollowUp(rawCommand) {
      return .fallThrough(.computerControl)
    }

    if let cachedDecision {
      return .librarianCheckpoint(cachedDecision)
    }
    return .unclaimed
  }

  public static func executionContract(
    for capability: RookDirectCapabilityID
  ) -> RookCapabilityExecutionContract {
    // Every capability is declared exactly once in the ordered cheat sheet.
    cheatSheet.first(where: { $0.id == capability })!.executionContract
  }
}
