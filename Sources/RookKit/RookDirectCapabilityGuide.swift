import Foundation

/// The ordered, inspectable list of work Rook should attempt without a task
/// pawn. Keeping this in one place prevents a new direct adapter from being
/// added to the app while the general router still treats its keywords as
/// research.
public enum RookDirectCapabilityID: String, CaseIterable, Equatable, Sendable {
  case reflex
  case weather
  case spotify
  case screenCapture = "screen_capture"
  case computerControl = "computer_control"
  case librarianCheckpoint = "librarian_checkpoint"
}

public struct RookDirectCapabilityDescriptor: Equatable, Sendable {
  public let id: RookDirectCapabilityID
  public let title: String
  public let adapter: String
  public let handles: String
  public let fallback: String

  public init(
    id: RookDirectCapabilityID,
    title: String,
    adapter: String,
    handles: String,
    fallback: String
  ) {
    self.id = id
    self.title = title
    self.adapter = adapter
    self.handles = handles
    self.fallback = fallback
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

/// Rook's behind-the-scenes capability cheat sheet and its direct-first router.
/// Exact parsers run first. Weather and Spotify then get a bounded semantic
/// attempt. Only an adapter decline falls through to the normal model/pawn
/// router; ambiguous or unsupported operations may instead ask locally.
public enum RookDirectCapabilityGuide {
  public static let cheatSheet: [RookDirectCapabilityDescriptor] = [
    RookDirectCapabilityDescriptor(
      id: .reflex,
      title: "Rook Reflex",
      adapter: "On-device controller",
      handles: "Calculations, conversions, local alerts, Mac status, and volume",
      fallback: "Use normal routing when the bounded parser declines"
    ),
    RookDirectCapabilityDescriptor(
      id: .weather,
      title: "Weather",
      adapter: "Open-Meteo",
      handles: "Current, tomorrow, and one-to-seven-day forecasts",
      fallback: "Try the semantic forecast resolver, then use deliberate routing"
    ),
    RookDirectCapabilityDescriptor(
      id: .spotify,
      title: "Spotify",
      adapter: "Spotify Web API or narrow Mac playback control",
      handles: "Playback, playlists, catalog, history, top items, and devices",
      fallback: "Try the semantic Spotify resolver, then clarify or use deliberate routing"
    ),
    RookDirectCapabilityDescriptor(
      id: .screenCapture,
      title: "Private screen capture",
      adapter: "ScreenCaptureKit",
      handles: "Explicit display, front-window, and named-window inspection",
      fallback: "Use deliberate routing when the bounded parser declines"
    ),
    RookDirectCapabilityDescriptor(
      id: .computerControl,
      title: "Mac controls",
      adapter: "Native app, browser, and playback controller",
      handles: "Open apps or pages, web search, and basic media controls",
      fallback: "Use deliberate Computer Operator routing when the parser declines"
    ),
    RookDirectCapabilityDescriptor(
      id: .librarianCheckpoint,
      title: "Fresh Librarian context",
      adapter: "Private local Library",
      handles: "Stable operational answers backed by a fresh checkpoint",
      fallback: "Use live deliberate routing when the checkpoint is missing or stale"
    ),
  ]

  public static func resolve(
    _ rawCommand: String,
    cachedDecision: LocalRookDecision? = nil
  ) -> RookDirectCapabilityResolution {
    var declinedCapability: RookDirectCapabilityID?

    if let intent = RookReflexCommandParser.parse(rawCommand) {
      return .reflex(intent)
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
    if let hybrid = RookHybridCapabilityPlanner.plan(rawCommand) {
      return .hybrid(hybrid)
    }
    if let request = RookWeatherCommandParser.parse(rawCommand) {
      return .weather(request)
    }

    switch RookWeatherSemanticResolver.resolve(rawCommand) {
    case .request(let request):
      return .weather(request)
    case .requiresDeliberation:
      declinedCapability = .weather
    case .notWeather:
      break
    }

    switch RookSpotifySemanticResolver.resolve(rawCommand) {
    case .intent(let intent):
      return .spotify(intent)
    case .clarification(let message):
      return .clarification(capability: .spotify, message: message)
    case .notSpotify:
      if explicitlyNamesSpotify(rawCommand) { declinedCapability = .spotify }
    }

    if let cachedDecision {
      return .librarianCheckpoint(cachedDecision)
    }
    if let declinedCapability {
      return .fallThrough(declinedCapability)
    }
    return .unclaimed
  }

  private static func explicitlyNamesSpotify(_ value: String) -> Bool {
    value.range(of: #"\bspotify\b"#, options: [.regularExpression, .caseInsensitive]) != nil
  }
}
