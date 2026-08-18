import Foundation

public enum RookSpotifyMediaKind: String, Codable, CaseIterable, Equatable, Sendable {
  case track
  case album
  case artist
  case playlist

  public var label: String { rawValue.capitalized }
}

public enum RookSpotifyTopKind: String, Codable, Equatable, Sendable {
  case tracks
  case artists
}

public enum RookSpotifyPlaylistPurpose: String, CaseIterable, Codable, Equatable, Sendable {
  case study
  case work
  case focus

  public var label: String { rawValue.capitalized }
}

/// Exact Spotify requests that are safe and fast enough to run directly against
/// Spotify's Web API without a model or pawn crew.
public enum RookSpotifyIntent: Equatable, Sendable {
  case resume
  case pause
  case next
  case previous
  case play(query: String, preferredKind: RookSpotifyMediaKind?, libraryOnly: Bool)
  case playTopTracks
  case playAnyPlaylist
  case playForPurpose(purposes: [RookSpotifyPlaylistPurpose])
  case choosePlaylist
  case playlists
  case recommendPlaylists(purposes: [RookSpotifyPlaylistPurpose])
  case recentlyPlayed
  case top(RookSpotifyTopKind)
  case devices
  case nowPlaying
  case transferPlayback(deviceName: String)

  public var progressText: String {
    switch self {
    case .resume: return "Resuming **Spotify**…"
    case .pause: return "Pausing **Spotify**…"
    case .next: return "Skipping to the next Spotify track…"
    case .previous: return "Going back one Spotify track…"
    case .play(let query, _, _): return "Finding **\(query)** on Spotify…"
    case .playTopTracks: return "Loading and playing your top Spotify tracks…"
    case .playAnyPlaylist: return "Choosing one of your Spotify playlists…"
    case .playForPurpose: return "Choosing the best-fit playlist from your Spotify library…"
    case .choosePlaylist: return "Loading your Spotify playlists…"
    case .playlists: return "Loading your Spotify playlists…"
    case .recommendPlaylists: return "Finding the best-fit playlists in your Spotify library…"
    case .recentlyPlayed: return "Loading your recent Spotify listening…"
    case .top(let kind): return "Loading your top Spotify \(kind.rawValue)…"
    case .devices: return "Checking your Spotify devices…"
    case .nowPlaying: return "Checking what Spotify is playing…"
    case .transferPlayback(let deviceName): return "Moving Spotify to **\(deviceName)**…"
    }
  }
}

public enum RookSpotifyCommandParser {
  public static func parse(_ rawCommand: String) -> RookSpotifyIntent? {
    let command = cleaned(rawCommand)
    guard !command.isEmpty else { return nil }

    if matches(
      #"^(?:please\s+)?(?:pause|stop)(?:\s+(?:(?:the|my)\s+)?(?:music|song|track|playback))?(?:\s+(?:on|in))?\s+(?:my\s+)?spotify(?:\s+please)?$"#,
      in: command)
    {
      return .pause
    }

    if matches(
      #"^(?:please\s+)?(?:resume|continue|play)(?:\s+(?:(?:the|my)\s+)?(?:music|song|track|playback))?(?:\s+(?:on|in))?\s+(?:my\s+)?spotify(?:\s+please)?$"#,
      in: command)
      || matches(
        #"^(?:please\s+)?(?:resume|continue|play)\s+(?:my\s+)?spotify(?:\s+please)?$"#,
        in: command)
      || matches(
        #"^(?:please\s+)?(?:open|launch|start)\s+spotify\s+and\s+(?:resume|continue|play)(?:\s+(?:(?:the|my)\s+)?(?:music|playback))?(?:\s+please)?$"#,
        in: command)
    {
      return .resume
    }

    if matches(
      #"^(?:please\s+)?(?:skip|next)(?:\s+(?:song|track))?(?:\s+(?:on|in))?\s+spotify(?:\s+please)?$"#,
      in: command)
    {
      return .next
    }

    if matches(
      #"^(?:please\s+)?(?:previous|last|go\s+back)(?:\s+(?:song|track))?(?:\s+(?:on|in))?\s+spotify(?:\s+please)?$"#,
      in: command)
    {
      return .previous
    }

    if matches(
      #"^(?:please\s+)?(?:show|list|display|open)(?:\s+me)?\s+(?:all\s+)?(?:of\s+)?my\s+spotify\s+playlists?(?:\s+please)?$"#,
      in: command)
      || matches(
        #"^(?:please\s+)?what\s+playlists\s+do\s+i\s+have\s+(?:on|in)\s+spotify(?:\s+please)?$"#,
        in: command)
      || matches(
        #"^(?:please\s+)?what\s+are\s+my\s+(?:spotify\s+)?playlists?(?:\s+(?:on|in)\s+spotify)?(?:\s+please)?$"#,
        in: command)
    {
      return .playlists
    }

    if matches(
      #"^(?:please\s+)?(?:show|list|display)(?:\s+me)?\s+my\s+(?:recent|recently\s+played)(?:\s+(?:songs|tracks|music))?\s+(?:on|in)\s+spotify(?:\s+please)?$"#,
      in: command)
      || matches(
        #"^(?:please\s+)?what\s+(?:have\s+i|did\s+i)\s+(?:recently\s+)?listen(?:ed)?\s+to\s+(?:on|in)\s+spotify(?:\s+please)?$"#,
        in: command)
    {
      return .recentlyPlayed
    }

    if let captures = captures(
      #"^(?:please\s+)?(?:show|list|what\s+are)(?:\s+me)?\s+my\s+(?:top|most\s+played)\s+(tracks|songs|artists)(?:\s+(?:on|in)\s+spotify)?(?:\s+please)?$"#,
      in: command)
    {
      return .top(captures[0].lowercased() == "artists" ? .artists : .tracks)
    }

    if matches(
      #"^(?:please\s+)?(?:show|list|what\s+are)(?:\s+me)?\s+(?:my\s+)?(?:available\s+)?spotify\s+(?:connect\s+)?devices(?:\s+please)?$"#,
      in: command)
      || matches(
        #"^(?:please\s+)?what\s+(?:spotify\s+)?devices\s+(?:can\s+i\s+use|are\s+available)(?:\s+on\s+spotify)?(?:\s+please)?$"#,
        in: command)
    {
      return .devices
    }

    if matches(
      #"^(?:please\s+)?(?:what(?:'s|\s+is)|show\s+me)\s+(?:currently\s+)?playing\s+(?:on|in)\s+spotify(?:\s+please)?$"#,
      in: command)
      || matches(
        #"^(?:please\s+)?(?:what(?:'s|\s+is)\s+my\s+current\s+(?:spotify\s+)?(?:song|track)|now\s+playing\s+(?:on|in)\s+spotify)(?:\s+please)?$"#,
        in: command)
    {
      return .nowPlaying
    }

    if let captures = captures(
      #"^(?:please\s+)?(?:move|switch|transfer)\s+(?:my\s+)?spotify(?:\s+playback)?\s+to\s+(.+?)(?:\s+please)?$"#,
      in: command), let deviceName = safeName(captures[0])
    {
      return .transferPlayback(deviceName: deviceName)
    }

    if matches(
      #"^(?:please\s+)?(?:play|start)(?:\s+me)?\s+(?:any|a|some|one\s+of\s+my)\s+spotify\s+playlists?(?:\s+on\s+(?:my\s+)?computer)?(?:\s+please)?$"#,
      in: command)
    {
      return .playAnyPlaylist
    }

    if matches(
      #"^(?:please\s+)?(?:play|start)(?:\s+me)?\s+(?:my\s+)?spotify\s+playlists?(?:\s+on\s+(?:my\s+)?computer)?(?:\s+please)?$"#,
      in: command)
    {
      return .choosePlaylist
    }

    if matches(
      #"^(?:please\s+)?(?:play|start)(?:\s+me)?\s+(?:my\s+)?(?:top|most\s+played)\s+(?:tracks|songs)(?:\s+playlist)?(?:\s+(?:on|in)\s+spotify)?(?:\s+please)?$"#,
      in: command)
    {
      return .playTopTracks
    }

    if let captures = captures(
      #"^(?:please\s+)?(?:play|start)\s+(my\s+|the\s+)?(.+?)\s+playlist\s+(?:on|in)\s+spotify(?:\s+please)?$"#,
      in: command), let query = safeName(captures[1])
    {
      return .play(query: query, preferredKind: .playlist, libraryOnly: !captures[0].isEmpty)
    }

    if let captures = captures(
      #"^(?:please\s+)?(?:play|start)\s+(?:the\s+)?(song|track|album|artist)\s+(.+?)\s+(?:on|in)\s+spotify(?:\s+please)?$"#,
      in: command), let kind = mediaKind(captures[0]), let query = safeName(captures[1])
    {
      return .play(query: query, preferredKind: kind, libraryOnly: false)
    }

    if let captures = captures(
      #"^(?:please\s+)?(?:play|start)\s+(.+?)\s+(song|track|album|artist)\s+(?:on|in)\s+spotify(?:\s+please)?$"#,
      in: command), let query = safeName(captures[0]), let kind = mediaKind(captures[1])
    {
      return .play(query: query, preferredKind: kind, libraryOnly: false)
    }

    if let captures = captures(
      #"^(?:please\s+)?(?:play|start)\s+(.+?)\s+(?:on|in)\s+spotify(?:\s+please)?$"#,
      in: command), let query = safeName(captures[0]),
      !["my", "music", "my music", "spotify"].contains(query.lowercased())
    {
      return .play(query: query, preferredKind: nil, libraryOnly: false)
    }

    if let captures = captures(
      #"^(?:please\s+)?(?:play|start)(?:\s+me)?\s+(?:my\s+|the\s+)?(.+?)\s+playlist(?:\s+please)?$"#,
      in: command), let query = safeName(captures[0]),
      !["spotify", "any", "a", "some"].contains(query.lowercased())
    {
      return .play(query: query, preferredKind: .playlist, libraryOnly: true)
    }

    if let correction = voiceCorrection(in: command) {
      return parse(correction)
    }
    return nil
  }

  private static func voiceCorrection(in command: String) -> String? {
    guard let separator = command.range(of: #"\s+or\s+"#, options: [.regularExpression, .caseInsensitive]) else {
      return nil
    }
    let original = String(command[..<separator.lowerBound])
    let correction = String(command[separator.upperBound...])
    guard original.localizedCaseInsensitiveContains("spotify"),
      correction.localizedCaseInsensitiveContains("spotify")
    else { return nil }
    return correction
  }

  private static func mediaKind(_ value: String) -> RookSpotifyMediaKind? {
    switch value.lowercased() {
    case "song", "track": return .track
    case "album": return .album
    case "artist": return .artist
    default: return nil
    }
  }

  private static func safeName(_ value: String) -> String? {
    let cleaned =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned.count <= 160 else { return nil }
    let chainedAction =
      #"\b(?:and\s+then|then|and)\s+(?:send|delete|buy|purchase|install|post|publish|book|apply|upload|share|open|click|type)\b"#
    guard cleaned.range(of: chainedAction, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
    return cleaned
  }

  private static func cleaned(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func matches(_ pattern: String, in value: String) -> Bool {
    captures(pattern, in: value) != nil
  }

  private static func captures(_ pattern: String, in value: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      match.range == NSRange(value.startIndex..., in: value)
    else { return nil }
    return (1..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return "" }
      return String(value[swiftRange])
    }
  }
}

public struct RookSpotifyCandidate: Equatable, Sendable {
  public let id: String
  public let name: String
  public let uri: String
  public let kind: RookSpotifyMediaKind
  public let detail: String
  public let imageURL: String
  public let externalURL: String
  public let itemCount: Int?
  public let semanticText: String

  public init(
    id: String,
    name: String,
    uri: String,
    kind: RookSpotifyMediaKind,
    detail: String = "",
    imageURL: String = "",
    externalURL: String = "",
    itemCount: Int? = nil,
    semanticText: String = ""
  ) {
    self.id = id
    self.name = name
    self.uri = uri
    self.kind = kind
    self.detail = detail
    self.imageURL = imageURL
    self.externalURL = externalURL
    self.itemCount = itemCount
    self.semanticText = semanticText
  }
}

public struct RookSpotifyRankedCandidate: Equatable, Sendable {
  public let candidate: RookSpotifyCandidate
  public let score: Int
}

public enum RookSpotifyMatcher {
  public static func ranked(query: String, candidates: [RookSpotifyCandidate]) -> [RookSpotifyRankedCandidate] {
    let normalizedQuery = normalized(query)
    guard !normalizedQuery.isEmpty else { return [] }
    return
      candidates
      .map { RookSpotifyRankedCandidate(candidate: $0, score: score(normalizedQuery, normalized($0.name))) }
      .filter { $0.score > 0 }
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.candidate.name.localizedCaseInsensitiveCompare($1.candidate.name) == .orderedAscending
      }
  }

  public static func normalized(_ value: String) -> String {
    let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let words =
      folded
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
    let ignored: Set<String> = ["the", "my", "playlist", "spotify"]
    return words.filter { !ignored.contains($0) }.joined(separator: " ")
  }

  private static func score(_ query: String, _ name: String) -> Int {
    guard !query.isEmpty, !name.isEmpty else { return 0 }
    if query == name { return 100 }
    if name.hasPrefix(query) || query.hasPrefix(name) { return 88 }
    if name.contains(query) || query.contains(name) { return 80 }
    let queryTokens = Set(query.split(separator: " ").map(String.init))
    let nameTokens = Set(name.split(separator: " ").map(String.init))
    let intersection = queryTokens.intersection(nameTokens).count
    let union = queryTokens.union(nameTokens).count
    guard intersection > 0, union > 0 else { return 0 }
    return 35 + Int((Double(intersection) / Double(union)) * 50)
  }
}

public struct RookSpotifyPurposeRankedCandidate: Equatable, Sendable {
  public let candidate: RookSpotifyCandidate
  public let score: Int
  public let matchedPurposes: [RookSpotifyPlaylistPurpose]
}

/// A transparent, deterministic inference layer for human requests such as
/// “my focus playlist” when no playlist has that literal name. It intentionally
/// uses only the user's Spotify playlist titles and descriptions.
public enum RookSpotifyPurposeMatcher {
  private struct Signal {
    let phrase: String
    let weight: Int
  }

  private static let signals: [RookSpotifyPlaylistPurpose: [Signal]] = [
    .study: [
      Signal(phrase: "study", weight: 110),
      Signal(phrase: "studying", weight: 110),
      Signal(phrase: "homework", weight: 105),
      Signal(phrase: "revision", weight: 100),
      Signal(phrase: "exam", weight: 95),
      Signal(phrase: "finals", weight: 95),
      Signal(phrase: "reading", weight: 80),
      Signal(phrase: "learn", weight: 70),
      Signal(phrase: "school", weight: 65),
      Signal(phrase: "focus", weight: 90),
      Signal(phrase: "concentration", weight: 85),
      Signal(phrase: "lofi", weight: 70),
      Signal(phrase: "lo fi", weight: 70),
    ],
    .work: [
      Signal(phrase: "deep work", weight: 115),
      Signal(phrase: "work", weight: 110),
      Signal(phrase: "working", weight: 110),
      Signal(phrase: "productivity", weight: 105),
      Signal(phrase: "productive", weight: 100),
      Signal(phrase: "workflow", weight: 95),
      Signal(phrase: "coding", weight: 90),
      Signal(phrase: "programming", weight: 90),
      Signal(phrase: "office", weight: 80),
      Signal(phrase: "desk", weight: 65),
      Signal(phrase: "focus", weight: 90),
      Signal(phrase: "concentration", weight: 85),
      Signal(phrase: "study", weight: 75),
    ],
    .focus: [
      Signal(phrase: "deep focus", weight: 120),
      Signal(phrase: "focus", weight: 115),
      Signal(phrase: "focused", weight: 115),
      Signal(phrase: "concentration", weight: 110),
      Signal(phrase: "concentrate", weight: 110),
      Signal(phrase: "flow state", weight: 100),
      Signal(phrase: "flow", weight: 85),
      Signal(phrase: "lofi", weight: 75),
      Signal(phrase: "lo fi", weight: 75),
      Signal(phrase: "instrumental", weight: 70),
      Signal(phrase: "ambient", weight: 60),
      Signal(phrase: "study", weight: 90),
      Signal(phrase: "studying", weight: 90),
      Signal(phrase: "homework", weight: 85),
      Signal(phrase: "work", weight: 85),
      Signal(phrase: "productivity", weight: 80),
      Signal(phrase: "coding", weight: 75),
    ],
  ]

  public static func purposes(in rawValue: String) -> [RookSpotifyPlaylistPurpose] {
    let value = normalized(rawValue)
    var found: [RookSpotifyPlaylistPurpose] = []
    let requestedSignals: [(RookSpotifyPlaylistPurpose, [String])] = [
      (.study, ["study", "studying", "homework", "revision", "exam", "finals"]),
      (.work, ["work", "working", "productivity", "productive", "coding", "programming"]),
      (.focus, ["focus", "focused", "concentration", "concentrate", "flow state"]),
    ]
    for (purpose, phrases) in requestedSignals where phrases.contains(where: { containsPhrase($0, in: value) }) {
      found.append(purpose)
    }
    return found
  }

  public static func ranked(
    purposes: [RookSpotifyPlaylistPurpose],
    candidates: [RookSpotifyCandidate]
  ) -> [RookSpotifyPurposeRankedCandidate] {
    let uniquePurposes = purposes.reduce(into: [RookSpotifyPlaylistPurpose]()) { result, purpose in
      if !result.contains(purpose) { result.append(purpose) }
    }
    guard !uniquePurposes.isEmpty else { return [] }

    return candidates.compactMap { candidate in
      let name = normalized(candidate.name)
      let context = normalized(candidate.semanticText)
      var purposeScores: [(RookSpotifyPlaylistPurpose, Int)] = []
      for purpose in uniquePurposes {
        let purposeSignals = signals[purpose] ?? []
        let titleScore =
          purposeSignals
          .filter { containsPhrase($0.phrase, in: name) }
          .map { $0.weight + (name == normalized($0.phrase) ? 15 : 0) }
          .max() ?? 0
        let descriptionScore =
          purposeSignals
          .filter { containsPhrase($0.phrase, in: context) }
          .map { Int(Double($0.weight) * 0.55) }
          .max() ?? 0
        let score = max(titleScore, descriptionScore)
        if score > 0 { purposeScores.append((purpose, score)) }
      }
      guard let best = purposeScores.map(\.1).max(), best > 0 else { return nil }
      let matched =
        purposeScores
        .filter { $0.1 >= max(55, best - 12) }
        .map(\.0)
      return RookSpotifyPurposeRankedCandidate(
        candidate: candidate,
        score: best + max(0, matched.count - 1) * 4,
        matchedPurposes: matched
      )
    }
    .sorted {
      if $0.score != $1.score { return $0.score > $1.score }
      return $0.candidate.name.localizedCaseInsensitiveCompare($1.candidate.name) == .orderedAscending
    }
  }

  private static func normalized(_ value: String) -> String {
    value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func containsPhrase(_ phrase: String, in value: String) -> Bool {
    guard !value.isEmpty else { return false }
    let escaped = NSRegularExpression.escapedPattern(for: normalized(phrase))
    return value.range(of: "\\b\(escaped)\\b", options: .regularExpression) != nil
  }
}

public enum RookSpotifyError: LocalizedError, Equatable {
  case notConnected
  case noActiveDevice
  case noMatch(String)
  case ambiguous(String, [String])
  case restrictedDevice(String)
  case rateLimited
  case unavailable
  case network
  case invalidResponse
  case verificationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .notConnected:
      return "Connect Spotify in Rook → Allies, then try again."
    case .noActiveDevice:
      return "Open Spotify on your Mac, phone, or speaker so Rook has a playback device to use."
    case .noMatch(let query):
      return "I couldn’t find “\(query)” in the Spotify results available to this account."
    case .ambiguous(let query, let options):
      return "“\(query)” matches more than one item: \(options.prefix(3).joined(separator: ", ")). Say the exact name."
    case .restrictedDevice(let name):
      return "Spotify reports that \(name) cannot accept remote playback controls."
    case .rateLimited:
      return "Spotify is temporarily rate-limiting this developer connection. Try again shortly."
    case .unavailable:
      return "Spotify rejected that request. Confirm the connected account is Premium and allowed in the developer app."
    case .network:
      return "Rook couldn’t reach Spotify. Check your connection and try again."
    case .invalidResponse:
      return "Spotify returned a response Rook couldn’t safely read."
    case .verificationFailed(let detail):
      return "Spotify verification failed: \(detail)"
    }
  }
}

@MainActor
public final class RookSpotifyClient {
  public typealias AccessTokenProvider = @MainActor () async throws -> String

  private struct PlaylistCache {
    let fetchedAt: Date
    let playlists: [RookSpotifyCandidate]
  }

  private enum PlaybackExpectation {
    case playing(expectedURI: String?)
    case paused
    case device(String)
  }

  private struct PlaybackMutationOutcome {
    let response: RookResponse
    let expectedURI: String?
  }

  private struct PlaybackEvidence {
    let trackName: String
    let artists: String
    let deviceName: String
    let isPlaying: Bool
    let imageURL: String
    let externalURL: String
    let itemURI: String
    let contextURI: String?

    var taskEvidence: RookTaskStepEvidence {
      RookTaskStepEvidence(
        summary: "Spotify verified \(trackName) by \(artists) on \(deviceName).",
        values: [
          "artist": artists,
          "device": deviceName,
          "playback_state": isPlaying ? "playing" : "paused",
          "source": "Spotify Web API",
          "track": trackName,
        ]
      )
    }
  }

  private let session: URLSession
  private let accessTokenProvider: AccessTokenProvider
  private var playlistCache: PlaylistCache?

  public init(
    session: URLSession = .shared,
    accessTokenProvider: @escaping AccessTokenProvider
  ) {
    self.session = session
    self.accessTokenProvider = accessTokenProvider
  }

  public func execute(_ intent: RookSpotifyIntent) async throws -> RookResponse {
    switch intent {
    case .resume, .pause, .next, .previous:
      return try await controlPlayback(intent)
    case .play(let query, let preferredKind, let libraryOnly):
      return try await play(query: query, preferredKind: preferredKind, libraryOnly: libraryOnly)
    case .playTopTracks:
      return try await playTopTracks()
    case .playAnyPlaylist:
      guard let playlist = try await currentPlaylists().first else {
        throw RookSpotifyError.noMatch("a playlist")
      }
      return try await play(query: playlist.name, preferredKind: .playlist, libraryOnly: true)
    case .playForPurpose(let purposes):
      return try await playForPurpose(purposes)
    case .choosePlaylist:
      return try await playlistResponse(promptToChoose: true)
    case .playlists:
      return try await playlistResponse(promptToChoose: false)
    case .recommendPlaylists(let purposes):
      return try await recommendedPlaylistResponse(purposes: purposes)
    case .recentlyPlayed:
      return try await recentlyPlayedResponse()
    case .top(let kind):
      return try await topResponse(kind)
    case .devices:
      return try await devicesResponse()
    case .nowPlaying:
      return try await nowPlayingResponse()
    case .transferPlayback(let deviceName):
      return try await transferPlayback(to: deviceName)
    }
  }

  /// Executes a Spotify step for Rook's dependency-aware task engine and
  /// returns only the bounded evidence needed by downstream work. Playback
  /// mutations are never repeated here. Their state is verified with up to two
  /// read-only player checks so an uncertain mutation cannot be compounded.
  public func executeForTask(_ intent: RookSpotifyIntent) async throws -> RookTaskAdapterOutput {
    switch intent {
    case .nowPlaying:
      let playback = try await playbackEvidence()
      return RookTaskAdapterOutput(
        response: nowPlayingResponse(from: playback),
        verified: true,
        evidence: playback.taskEvidence
      )
    case .play(let query, let preferredKind, let libraryOnly):
      return try await verifiedMutationOutput(
        try await playOutcome(
          query: query,
          preferredKind: preferredKind,
          libraryOnly: libraryOnly
        )
      )
    case .playTopTracks:
      return try await verifiedMutationOutput(try await playTopTracksOutcome())
    case .playAnyPlaylist:
      guard let playlist = try await currentPlaylists().first else {
        throw RookSpotifyError.noMatch("a playlist")
      }
      return try await verifiedMutationOutput(
        try await playOutcome(
          query: playlist.name,
          preferredKind: .playlist,
          libraryOnly: true
        )
      )
    case .playForPurpose(let purposes):
      return try await verifiedMutationOutput(try await playForPurposeOutcome(purposes))
    default:
      break
    }

    let response = try await execute(intent)
    guard response.intent != "clarification" else {
      return RookTaskAdapterOutput(response: response, verified: false)
    }

    switch intent {
    case .resume:
      let playback = try await verifiedPlaybackEvidence(expectation: .playing(expectedURI: nil))
      return RookTaskAdapterOutput(
        response: response,
        verified: true,
        evidence: playback.taskEvidence
      )
    case .pause:
      let playback = try await verifiedPlaybackEvidence(expectation: .paused)
      return RookTaskAdapterOutput(
        response: response,
        verified: true,
        evidence: playback.taskEvidence
      )
    case .transferPlayback(let deviceName):
      let playback = try await verifiedPlaybackEvidence(expectation: .device(deviceName))
      return RookTaskAdapterOutput(
        response: response,
        verified: true,
        evidence: playback.taskEvidence
      )
    case .choosePlaylist, .playlists, .recommendPlaylists, .recentlyPlayed, .top, .devices:
      return RookTaskAdapterOutput(
        response: response,
        verified: true,
        evidence: RookTaskStepEvidence(summary: "Spotify returned the requested account data.")
      )
    case .next, .previous:
      return RookTaskAdapterOutput(response: response, verified: false)
    case .play, .playTopTracks, .playAnyPlaylist, .playForPurpose, .nowPlaying:
      preconditionFailure("Handled before the ordinary execute path.")
    }
  }

  private func verifiedMutationOutput(
    _ mutation: PlaybackMutationOutcome
  ) async throws -> RookTaskAdapterOutput {
    guard mutation.response.intent != "clarification" else {
      return RookTaskAdapterOutput(response: mutation.response, verified: false)
    }
    let playback = try await verifiedPlaybackEvidence(
      expectation: .playing(expectedURI: mutation.expectedURI)
    )
    return RookTaskAdapterOutput(
      response: mutation.response,
      verified: true,
      evidence: playback.taskEvidence
    )
  }

  private func controlPlayback(_ intent: RookSpotifyIntent) async throws -> RookResponse {
    let device: DeviceDTO
    let path: String
    let method: String
    let title: String
    let displayVerb: String

    switch intent {
    case .resume:
      device = try await playbackDevice()
      path = "/me/player/play"
      method = "PUT"
      title = "Playback resumed"
      displayVerb = "Resumed"
    case .pause:
      device = try await activePlaybackDevice()
      path = "/me/player/pause"
      method = "PUT"
      title = "Playback paused"
      displayVerb = "Paused"
    case .next:
      device = try await activePlaybackDevice()
      path = "/me/player/next"
      method = "POST"
      title = "Skipped forward"
      displayVerb = "Skipped to the next track"
    case .previous:
      device = try await activePlaybackDevice()
      path = "/me/player/previous"
      method = "POST"
      title = "Went back"
      displayVerb = "Went back one track"
    default:
      throw RookSpotifyError.invalidResponse
    }

    _ = try await requestData(
      path: path,
      method: method,
      queryItems: [URLQueryItem(name: "device_id", value: device.id)]
    )
    return RookResponse(
      displayText: "\(displayVerb) on **\(device.name)**.",
      spokenText: "\(displayVerb) on \(device.name).",
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: title,
          subtitle: device.name,
          sourceURL: "https://open.spotify.com",
          items: [
            RookCanvasItem(
              id: "spotify_transport",
              label: device.name,
              detail: device.type.capitalized,
              value: title,
              symbol: .music
            )
          ]
        )
      ]
    )
  }

  private func playTopTracks() async throws -> RookResponse {
    try await playTopTracksOutcome().response
  }

  private func playTopTracksOutcome() async throws -> PlaybackMutationOutcome {
    let data = try await requestData(
      path: "/me/top/tracks",
      queryItems: [
        URLQueryItem(name: "time_range", value: "medium_term"),
        URLQueryItem(name: "limit", value: "10"),
      ]
    )
    let tracks = try decode(NamedPage.self, from: data).items.map(\.candidate)
    guard !tracks.isEmpty else { throw RookSpotifyError.noMatch("your top tracks") }
    let device = try await playbackDevice()
    _ = try await requestData(
      path: "/me/player/play",
      method: "PUT",
      queryItems: [URLQueryItem(name: "device_id", value: device.id)],
      jsonBody: ["uris": tracks.map(\.uri)]
    )
    return PlaybackMutationOutcome(
      response: RookResponse(
        displayText: "Playing your top Spotify tracks on **\(device.name)**, starting with **\(tracks[0].name)**.",
        spokenText: "Playing your top Spotify tracks on \(device.name).",
        intent: "status",
        requiresApproval: false,
        queueItemIDs: [],
        pawns: [],
        canvas: [
          spotifyCanvas(
            title: "Your top tracks",
            subtitle: "Playing on \(device.name)",
            body: tracks[0].name,
            caption: tracks[0].detail,
            imageURL: tracks[0].imageURL,
            sourceURL: tracks[0].externalURL,
            items: tracks.prefix(5).enumerated().map { index, track in
              RookCanvasItem(
                id: "spotify_top_queue_\(index + 1)",
                label: track.name,
                detail: track.detail,
                value: index == 0 ? "Playing" : "Up next",
                symbol: .music
              )
            }
          )
        ]
      ),
      expectedURI: tracks[0].uri
    )
  }

  private func playForPurpose(_ purposes: [RookSpotifyPlaylistPurpose]) async throws -> RookResponse {
    try await playForPurposeOutcome(purposes).response
  }

  private func playForPurposeOutcome(
    _ purposes: [RookSpotifyPlaylistPurpose]
  ) async throws -> PlaybackMutationOutcome {
    let playlists = try await currentPlaylists()
    let matches = RookSpotifyPurposeMatcher.ranked(purposes: purposes, candidates: playlists)
      .filter { $0.score >= 55 }
    let label = naturalPurposeLabel(purposes)
    guard let best = matches.first else { throw RookSpotifyError.noMatch("a \(label) playlist") }
    if matches.count > 1, matches[1].score >= best.score - 7 {
      return PlaybackMutationOutcome(
        response: playlistChoiceResponse(
          query: "a \(label) playlist",
          options: Array(matches.prefix(3).map(\.candidate.name))
        ),
        expectedURI: nil
      )
    }
    return try await playOutcome(
      query: best.candidate.name,
      preferredKind: .playlist,
      libraryOnly: true
    )
  }

  private func play(
    query: String,
    preferredKind: RookSpotifyMediaKind?,
    libraryOnly: Bool
  ) async throws -> RookResponse {
    try await playOutcome(
      query: query,
      preferredKind: preferredKind,
      libraryOnly: libraryOnly
    ).response
  }

  private func playOutcome(
    query: String,
    preferredKind: RookSpotifyMediaKind?,
    libraryOnly: Bool
  ) async throws -> PlaybackMutationOutcome {
    let target: RookSpotifyCandidate
    do {
      target = try await resolve(query: query, preferredKind: preferredKind, libraryOnly: libraryOnly)
    } catch RookSpotifyError.ambiguous(let ambiguousQuery, let options)
      where preferredKind == .playlist || libraryOnly
    {
      return PlaybackMutationOutcome(
        response: playlistChoiceResponse(query: ambiguousQuery, options: options),
        expectedURI: nil
      )
    }
    let device = try await playbackDevice()
    let body: [String: Any]
    if target.kind == .track {
      body = ["uris": [target.uri]]
    } else {
      body = ["context_uri": target.uri]
    }
    _ = try await requestData(
      path: "/me/player/play",
      method: "PUT",
      queryItems: [URLQueryItem(name: "device_id", value: device.id)],
      jsonBody: body
    )

    let detail = [target.kind.label, target.detail].filter { !$0.isEmpty }.joined(separator: " · ")
    let display = "Playing **\(target.name)** on **\(device.name)**."
    return PlaybackMutationOutcome(
      response: RookResponse(
        displayText: display,
        spokenText: "Playing \(target.name) on \(device.name).",
        intent: "status",
        requiresApproval: false,
        queueItemIDs: [],
        pawns: [],
        canvas: [
          spotifyCanvas(
            title: "Now playing",
            subtitle: device.name,
            body: target.name,
            caption: detail,
            imageURL: target.imageURL,
            sourceURL: target.externalURL,
            items: [
              RookCanvasItem(
                id: "spotify_playback",
                label: target.kind.label,
                detail: target.detail,
                value: "Playing",
                symbol: .music
              )
            ]
          )
        ]
      ),
      expectedURI: target.uri
    )
  }

  private func playlistChoiceResponse(query: String, options: [String]) -> RookResponse {
    let visible = Array(options.prefix(3))
    return RookResponse(
      displayText:
        "I found a few playlists that could mean **\(query)**: \(visible.map { "**\($0)**" }.joined(separator: ", ")). Which playlist should I play?",
      spokenText: "I found a few likely matches. Which playlist should I play?",
      intent: "clarification",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: "Choose a playlist",
          subtitle: "Likely matches for \(query)",
          sourceURL: "https://open.spotify.com/collection/playlists",
          items: visible.enumerated().map { index, name in
            RookCanvasItem(
              id: "spotify_playlist_choice_\(index + 1)",
              label: name,
              detail: "Your Spotify library",
              value: "Option \(index + 1)",
              symbol: .music
            )
          }
        )
      ]
    )
  }

  private func playlistResponse(promptToChoose: Bool) async throws -> RookResponse {
    let playlists = try await currentPlaylists()
    let visible = Array(playlists.prefix(10))
    let display =
      playlists.isEmpty
      ? "Your connected Spotify account returned no playlists."
      : promptToChoose
        ? "Which playlist should I play? I found **\(playlists.count)**. Say the exact name."
        : "I found **\(playlists.count)** Spotify playlist\(playlists.count == 1 ? "" : "s") available to Rook."
    return RookResponse(
      displayText: display,
      spokenText: playlists.isEmpty
        ? "I didn’t find any playlists."
        : promptToChoose
          ? "Which playlist should I play? Say the exact name."
          : "I found \(playlists.count) Spotify playlists.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: "Your playlists",
          subtitle: playlists.count > visible.count
            ? "Showing \(visible.count) of \(playlists.count)" : "Spotify library",
          sourceURL: "https://open.spotify.com/collection/playlists",
          items: visible.enumerated().map { index, playlist in
            RookCanvasItem(
              id: "spotify_playlist_\(index + 1)",
              label: playlist.name,
              detail: playlist.detail,
              value: playlist.itemCount.map { "\($0) items" } ?? "Playlist",
              symbol: .music
            )
          }
        )
      ]
    )
  }

  private func recommendedPlaylistResponse(
    purposes: [RookSpotifyPlaylistPurpose]
  ) async throws -> RookResponse {
    let playlists = try await currentPlaylists()
    let matches = RookSpotifyPurposeMatcher.ranked(purposes: purposes, candidates: playlists)
      .filter { $0.score >= 55 }
    let visible = Array(matches.prefix(5))
    let purposeLabel = naturalPurposeLabel(purposes)

    guard let best = visible.first else {
      return RookResponse(
        displayText:
          "I couldn’t confidently infer a **\(purposeLabel)** playlist from the titles and descriptions in your Spotify library. I won’t dump all **\(playlists.count)** playlists again—tell me a name or a more specific vibe.",
        spokenText:
          "I couldn’t confidently infer a \(purposeLabel) playlist from your playlist titles and descriptions. Give me a name or a more specific vibe.",
        intent: "clarification",
        requiresApproval: false,
        queueItemIDs: [],
        pawns: [],
        canvas: []
      )
    }

    let alternatives = visible.dropFirst().prefix(3).map { "**\($0.candidate.name)**" }
    let alternativesText =
      alternatives.isEmpty
      ? ""
      : " Other likely fits: \(alternatives.joined(separator: ", "))."
    return RookResponse(
      displayText:
        "**\(best.candidate.name)** looks like the best \(purposeLabel) fit in your Spotify library.\(alternativesText) I ranked playlist titles and descriptions, not just exact names. Which playlist should I play?",
      spokenText:
        "\(best.candidate.name) looks like the best \(purposeLabel) fit. Say play that, or choose another result on screen.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: "Best \(purposeLabel) fits",
          subtitle: "\(visible.count) likely match\(visible.count == 1 ? "" : "es") from \(playlists.count) playlists",
          sourceURL: "https://open.spotify.com/collection/playlists",
          items: visible.enumerated().map { index, match in
            RookCanvasItem(
              id: "spotify_purpose_\(index + 1)",
              label: match.candidate.name,
              detail: purposeMatchLabel(match),
              value: index == 0 ? "Best fit" : "Alternative",
              symbol: .music
            )
          }
        )
      ]
    )
  }

  private func naturalPurposeLabel(_ purposes: [RookSpotifyPlaylistPurpose]) -> String {
    let labels = purposes.reduce(into: [String]()) { result, purpose in
      if !result.contains(purpose.rawValue) { result.append(purpose.rawValue) }
    }
    switch labels.count {
    case 0: return "requested"
    case 1: return labels[0]
    case 2: return labels.joined(separator: " or ")
    default: return labels.dropLast().joined(separator: ", ") + ", or " + labels.last!
    }
  }

  private func purposeMatchLabel(_ match: RookSpotifyPurposeRankedCandidate) -> String {
    let purpose = match.matchedPurposes.map(\.label).joined(separator: " · ")
    return [purpose, match.candidate.detail].filter { !$0.isEmpty }.joined(separator: " · ")
  }

  private func recentlyPlayedResponse() async throws -> RookResponse {
    let data = try await requestData(
      path: "/me/player/recently-played",
      queryItems: [URLQueryItem(name: "limit", value: "10")]
    )
    let response = try decode(RecentResponse.self, from: data)
    let items = response.items.prefix(10).map { ($0.track.candidate, $0.playedAt) }
    return RookResponse(
      displayText: items.isEmpty ? "Spotify returned no recent tracks." : "Here’s your recent Spotify listening.",
      spokenText: items.isEmpty ? "Spotify returned no recent tracks." : "I pulled up your recent Spotify listening.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: "Recently played",
          subtitle: "Newest first",
          sourceURL: "https://open.spotify.com",
          items: items.enumerated().map { index, entry in
            RookCanvasItem(
              id: "spotify_recent_\(index + 1)",
              label: entry.0.name,
              detail: entry.0.detail,
              value: shortTime(entry.1),
              symbol: .music
            )
          }
        )
      ]
    )
  }

  private func topResponse(_ kind: RookSpotifyTopKind) async throws -> RookResponse {
    let type = kind == .artists ? "artists" : "tracks"
    let data = try await requestData(
      path: "/me/top/\(type)",
      queryItems: [
        URLQueryItem(name: "time_range", value: "medium_term"),
        URLQueryItem(name: "limit", value: "10"),
      ]
    )
    let response = try decode(NamedPage.self, from: data)
    let candidates = response.items.map(\.candidate)
    return RookResponse(
      displayText: candidates.isEmpty
        ? "Spotify returned no top \(type)." : "Here are your top Spotify \(type) from roughly the last six months.",
      spokenText: candidates.isEmpty ? "Spotify returned no top \(type)." : "I pulled up your top Spotify \(type).",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: "Top \(type)",
          subtitle: "Approximately six months",
          sourceURL: "https://open.spotify.com",
          items: candidates.prefix(10).enumerated().map { index, candidate in
            RookCanvasItem(
              id: "spotify_top_\(index + 1)",
              label: candidate.name,
              detail: candidate.detail,
              value: "#\(index + 1)",
              symbol: .music
            )
          }
        )
      ]
    )
  }

  private func devicesResponse() async throws -> RookResponse {
    let devices = try await availableDevices()
    return RookResponse(
      displayText: devices.isEmpty
        ? "Spotify returned no available devices."
        : "I found **\(devices.count)** Spotify device\(devices.count == 1 ? "" : "s").",
      spokenText: devices.isEmpty
        ? "Spotify returned no available devices." : "I found \(devices.count) Spotify devices.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: "Spotify devices",
          subtitle: "Spotify Connect",
          sourceURL: "https://open.spotify.com",
          items: devices.enumerated().map { index, device in
            RookCanvasItem(
              id: "spotify_device_\(index + 1)",
              label: device.name,
              detail: [device.type.capitalized, device.isRestricted ? "Remote control restricted" : "Available"]
                .joined(separator: " · "),
              value: device.isActive ? "Active" : "Ready",
              symbol: device.isRestricted ? .warning : .music
            )
          }
        )
      ]
    )
  }

  private func nowPlayingResponse() async throws -> RookResponse {
    nowPlayingResponse(from: try await playbackEvidence())
  }

  private func playbackEvidence() async throws -> PlaybackEvidence {
    let data = try await requestData(path: "/me/player")
    guard !data.isEmpty else {
      throw RookSpotifyError.noActiveDevice
    }
    let playback = try decode(PlaybackResponse.self, from: data)
    guard let item = playback.item?.candidate else {
      throw RookSpotifyError.noActiveDevice
    }
    return PlaybackEvidence(
      trackName: item.name,
      artists: item.detail,
      deviceName: playback.device?.name ?? "Spotify",
      isPlaying: playback.isPlaying,
      imageURL: item.imageURL,
      externalURL: item.externalURL,
      itemURI: item.uri,
      contextURI: playback.context?.uri
    )
  }

  private func verifiedPlaybackEvidence(expectation: PlaybackExpectation) async throws -> PlaybackEvidence {
    var lastObserved: PlaybackEvidence?
    var lastError: Error?
    for attempt in 0...1 {
      if attempt > 0 {
        try? await Task.sleep(nanoseconds: 180_000_000)
      }
      do {
        let playback = try await playbackEvidence()
        lastObserved = playback
        if Self.playback(playback, satisfies: expectation) { return playback }
      } catch {
        lastError = error
      }
    }

    if let lastObserved {
      let state = lastObserved.isPlaying ? "playing" : "paused"
      throw RookSpotifyError.verificationFailed(
        "the player remained \(state) on \(lastObserved.deviceName) after Spotify accepted the command."
      )
    }
    throw RookSpotifyError.verificationFailed(
      lastError?.localizedDescription ?? "Spotify accepted the command but returned no readable player state."
    )
  }

  private static func playback(
    _ playback: PlaybackEvidence,
    satisfies expectation: PlaybackExpectation
  ) -> Bool {
    switch expectation {
    case .playing(let expectedURI):
      guard playback.isPlaying else { return false }
      guard let expectedURI, !expectedURI.isEmpty else { return true }
      return playback.itemURI == expectedURI || playback.contextURI == expectedURI
    case .paused:
      return !playback.isPlaying
    case .device(let requestedName):
      let requested = normalizedDeviceName(requestedName)
      let actual = normalizedDeviceName(playback.deviceName)
      return !requested.isEmpty && (requested == actual || actual.contains(requested) || requested.contains(actual))
    }
  }

  private static func normalizedDeviceName(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func nowPlayingResponse(from playback: PlaybackEvidence) -> RookResponse {
    let state = playback.isPlaying ? "Playing" : "Paused"
    return RookResponse(
      displayText:
        "**\(playback.trackName)** by \(playback.artists) is \(state.lowercased()) on **\(playback.deviceName)**.",
      spokenText: "\(playback.trackName) is \(state.lowercased()) on \(playback.deviceName).",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: "Now playing",
          subtitle: "\(playback.deviceName) · \(state)",
          body: playback.trackName,
          caption: playback.artists,
          imageURL: playback.imageURL,
          sourceURL: playback.externalURL,
          items: [
            RookCanvasItem(
              id: "spotify_now_playing",
              label: "Track",
              detail: playback.artists,
              value: state,
              symbol: .music
            )
          ]
        )
      ]
    )
  }

  private func transferPlayback(to requestedName: String) async throws -> RookResponse {
    let devices = try await availableDevices()
    let controllableDevices = devices.filter { !$0.id.isEmpty }
    let matches = RookSpotifyMatcher.ranked(
      query: requestedName,
      candidates: controllableDevices.map {
        RookSpotifyCandidate(id: $0.id, name: $0.name, uri: $0.id, kind: .playlist, detail: $0.type)
      }
    )
    guard let best = matches.first, best.score >= 70,
      let device = controllableDevices.first(where: { $0.id == best.candidate.id })
    else {
      throw RookSpotifyError.noMatch(requestedName)
    }
    if device.isRestricted { throw RookSpotifyError.restrictedDevice(device.name) }
    if matches.count > 1, matches[1].score >= best.score - 2, matches[1].candidate.id != best.candidate.id {
      throw RookSpotifyError.ambiguous(requestedName, Array(matches.prefix(3).map(\.candidate.name)))
    }
    _ = try await requestData(
      path: "/me/player",
      method: "PUT",
      jsonBody: ["device_ids": [device.id], "play": true]
    )
    return RookResponse(
      displayText: "Spotify is now playing on **\(device.name)**.",
      spokenText: "Spotify is now playing on \(device.name).",
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        spotifyCanvas(
          title: "Playback moved",
          subtitle: "Spotify Connect",
          sourceURL: "https://open.spotify.com",
          items: [
            RookCanvasItem(
              id: "spotify_transfer",
              label: device.name,
              detail: device.type.capitalized,
              value: "Active",
              symbol: .music
            )
          ]
        )
      ]
    )
  }

  private func resolve(
    query: String,
    preferredKind: RookSpotifyMediaKind?,
    libraryOnly: Bool
  ) async throws -> RookSpotifyCandidate {
    if preferredKind == nil || preferredKind == .playlist {
      let playlistMatches = RookSpotifyMatcher.ranked(query: query, candidates: try await currentPlaylists())
      if let resolved = try resolvedCandidate(query: query, matches: playlistMatches, threshold: 76) {
        return resolved
      }
      if libraryOnly {
        let purposes = RookSpotifyPurposeMatcher.purposes(in: query)
        let purposeMatches = RookSpotifyPurposeMatcher.ranked(
          purposes: purposes,
          candidates: try await currentPlaylists()
        )
        if let resolved = try resolvedPurposeCandidate(query: query, matches: purposeMatches) {
          return resolved
        }
        throw RookSpotifyError.noMatch(query)
      }
    }

    let searchKinds = preferredKind.map { [$0] } ?? [.track, .album, .artist, .playlist]
    let data = try await requestData(
      path: "/search",
      queryItems: [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "type", value: searchKinds.map(\.rawValue).joined(separator: ",")),
        URLQueryItem(name: "limit", value: "10"),
      ]
    )
    let search = try decode(SearchResponse.self, from: data)
    var candidates: [RookSpotifyCandidate] = []
    candidates += search.tracks?.items.map(\.candidate) ?? []
    candidates += search.albums?.items.map(\.candidate) ?? []
    candidates += search.artists?.items.map(\.candidate) ?? []
    candidates += search.playlists?.items.map(\.candidate) ?? []
    if let preferredKind { candidates = candidates.filter { $0.kind == preferredKind } }
    let matches = RookSpotifyMatcher.ranked(query: query, candidates: candidates)
    if let resolved = try resolvedCandidate(query: query, matches: matches, threshold: 55) {
      return resolved
    }
    throw RookSpotifyError.noMatch(query)
  }

  private func resolvedCandidate(
    query: String,
    matches: [RookSpotifyRankedCandidate],
    threshold: Int
  ) throws -> RookSpotifyCandidate? {
    guard let best = matches.first, best.score >= threshold else { return nil }
    if matches.count > 1 {
      let second = matches[1]
      if second.score >= best.score - 2,
        second.candidate.id != best.candidate.id,
        RookSpotifyMatcher.normalized(second.candidate.name) != RookSpotifyMatcher.normalized(best.candidate.name)
      {
        throw RookSpotifyError.ambiguous(query, Array(matches.prefix(3).map(\.candidate.name)))
      }
    }
    return best.candidate
  }

  private func resolvedPurposeCandidate(
    query: String,
    matches: [RookSpotifyPurposeRankedCandidate]
  ) throws -> RookSpotifyCandidate? {
    guard let best = matches.first, best.score >= 55 else { return nil }
    if matches.count > 1 {
      let second = matches[1]
      if second.score >= best.score - 7, second.candidate.id != best.candidate.id {
        throw RookSpotifyError.ambiguous(query, Array(matches.prefix(3).map(\.candidate.name)))
      }
    }
    return best.candidate
  }

  private func currentPlaylists() async throws -> [RookSpotifyCandidate] {
    if let playlistCache, Date().timeIntervalSince(playlistCache.fetchedAt) < 300 {
      return playlistCache.playlists
    }
    var playlists: [RookSpotifyCandidate] = []
    var offset = 0
    while offset < 200 {
      let data = try await requestData(
        path: "/me/playlists",
        queryItems: [
          URLQueryItem(name: "limit", value: "50"),
          URLQueryItem(name: "offset", value: "\(offset)"),
        ]
      )
      let page = try decode(PlaylistPage.self, from: data)
      playlists += page.items.map(\.candidate)
      offset += page.items.count
      if page.items.isEmpty || offset >= page.total { break }
    }
    playlistCache = PlaylistCache(fetchedAt: Date(), playlists: playlists)
    return playlists
  }

  private func playbackDevice() async throws -> DeviceDTO {
    let devices = try await availableDevices()
    if let active = devices.first(where: { !$0.id.isEmpty && $0.isActive && !$0.isRestricted }) { return active }
    if let available = devices.first(where: { !$0.id.isEmpty && !$0.isRestricted }) { return available }
    if let restricted = devices.first { throw RookSpotifyError.restrictedDevice(restricted.name) }
    throw RookSpotifyError.noActiveDevice
  }

  private func activePlaybackDevice() async throws -> DeviceDTO {
    let devices = try await availableDevices()
    if let active = devices.first(where: { !$0.id.isEmpty && $0.isActive && !$0.isRestricted }) { return active }
    if let restricted = devices.first(where: { $0.isActive }) {
      throw RookSpotifyError.restrictedDevice(restricted.name)
    }
    throw RookSpotifyError.noActiveDevice
  }

  private func availableDevices() async throws -> [DeviceDTO] {
    let data = try await requestData(path: "/me/player/devices")
    return try decode(DeviceResponse.self, from: data).devices
  }

  private func requestData(
    path: String,
    method: String = "GET",
    queryItems: [URLQueryItem] = [],
    jsonBody: [String: Any]? = nil
  ) async throws -> Data {
    let token: String
    do {
      token = try await accessTokenProvider()
    } catch {
      throw RookSpotifyError.notConnected
    }

    var components = URLComponents(string: "https://api.spotify.com/v1\(path)")!
    if !queryItems.isEmpty { components.queryItems = queryItems }
    guard let url = components.url else { throw RookSpotifyError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let jsonBody {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody)
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw RookSpotifyError.network
    }
    guard let http = response as? HTTPURLResponse else { throw RookSpotifyError.invalidResponse }
    switch http.statusCode {
    case 200..<300: return data
    case 401: throw RookSpotifyError.notConnected
    case 403: throw RookSpotifyError.unavailable
    case 404: throw RookSpotifyError.noActiveDevice
    case 429: throw RookSpotifyError.rateLimited
    default: throw RookSpotifyError.invalidResponse
    }
  }

  private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw RookSpotifyError.invalidResponse
    }
  }

  private func spotifyCanvas(
    title: String,
    subtitle: String,
    body: String = "",
    caption: String = "",
    imageURL: String = "",
    sourceURL: String,
    items: [RookCanvasItem]
  ) -> RookCanvasBlock {
    RookCanvasBlock(
      id: "spotify_panel",
      kind: .spotify,
      title: title,
      subtitle: subtitle,
      asOf: ISO8601DateFormatter().string(from: Date()),
      items: items,
      imageURL: imageURL,
      caption: caption,
      body: body,
      sourceLabel: "Spotify",
      sourceURL: sourceURL.isEmpty ? "https://open.spotify.com" : sourceURL
    )
  }

  private func shortTime(_ value: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: value) else { return "Recent" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "MMM d"
    return formatter.string(from: date)
  }
}

private struct SpotifyExternalURLs: Decodable {
  let spotify: String?
}

private struct SpotifyImage: Decodable {
  let url: String
}

private struct SpotifyArtist: Decodable {
  let name: String
}

private struct SpotifyOwner: Decodable {
  let displayName: String?

  enum CodingKeys: String, CodingKey {
    case displayName = "display_name"
  }
}

private struct SpotifyItemCount: Decodable {
  let total: Int?
}

private struct NamedDTO: Decodable {
  let id: String
  let name: String
  let uri: String
  let type: String
  let artists: [SpotifyArtist]?
  let owner: SpotifyOwner?
  let images: [SpotifyImage]?
  let externalURLs: SpotifyExternalURLs?
  let items: SpotifyItemCount?
  let tracks: SpotifyItemCount?
  let album: AlbumDTO?
  let description: String?

  enum CodingKeys: String, CodingKey {
    case id, name, uri, type, artists, owner, images, items, tracks, album, description
    case externalURLs = "external_urls"
  }

  var candidate: RookSpotifyCandidate {
    let kind = RookSpotifyMediaKind(rawValue: type) ?? .track
    let artistNames = artists?.map(\.name).joined(separator: ", ") ?? ""
    let detail: String
    switch kind {
    case .playlist: detail = owner?.displayName.map { "By \($0)" } ?? "Playlist"
    case .artist: detail = "Artist"
    case .album: detail = artistNames
    case .track: detail = artistNames
    }
    return RookSpotifyCandidate(
      id: id,
      name: name,
      uri: uri,
      kind: kind,
      detail: detail,
      imageURL: images?.first?.url ?? album?.images?.first?.url ?? "",
      externalURL: externalURLs?.spotify ?? "",
      itemCount: items?.total ?? tracks?.total,
      semanticText: description ?? ""
    )
  }
}

private struct AlbumDTO: Decodable {
  let images: [SpotifyImage]?
}

private struct NamedPage: Decodable {
  let items: [NamedDTO]
}

private struct PlaylistPage: Decodable {
  let total: Int
  let items: [NamedDTO]
}

private struct SearchResponse: Decodable {
  let tracks: NamedPage?
  let albums: NamedPage?
  let artists: NamedPage?
  let playlists: NamedPage?
}

private struct RecentItem: Decodable {
  let track: NamedDTO
  let playedAt: String

  enum CodingKeys: String, CodingKey {
    case track
    case playedAt = "played_at"
  }
}

private struct RecentResponse: Decodable {
  let items: [RecentItem]
}

private struct DeviceDTO: Decodable {
  let id: String
  let isActive: Bool
  let isRestricted: Bool
  let name: String
  let type: String

  enum CodingKeys: String, CodingKey {
    case id, name, type
    case isActive = "is_active"
    case isRestricted = "is_restricted"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
    isRestricted = try container.decodeIfPresent(Bool.self, forKey: .isRestricted) ?? false
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Unknown device"
    type = try container.decodeIfPresent(String.self, forKey: .type) ?? "device"
  }
}

private struct DeviceResponse: Decodable {
  let devices: [DeviceDTO]
}

private struct PlaybackContextDTO: Decodable {
  let uri: String?
}

private struct PlaybackResponse: Decodable {
  let device: DeviceDTO?
  let isPlaying: Bool
  let item: NamedDTO?
  let context: PlaybackContextDTO?

  enum CodingKeys: String, CodingKey {
    case context, device, item
    case isPlaying = "is_playing"
  }
}
