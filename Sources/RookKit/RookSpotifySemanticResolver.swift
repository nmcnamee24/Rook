import Foundation

public enum RookSpotifySemanticResolution: Equatable, Sendable {
  case intent(RookSpotifyIntent)
  case clarification(String)
  case notSpotify
}

/// A bounded semantic fallback for natural Spotify language. It runs only
/// after the exact fast parser misses and maps to the same reviewed API intents.
public enum RookSpotifySemanticResolver {
  public static func resolve(_ rawCommand: String) -> RookSpotifySemanticResolution {
    if let exact = RookSpotifyCommandParser.parse(rawCommand) { return .intent(exact) }

    let command = cleaned(rawCommand)
    let lower = command.lowercased()
    let explicitSpotify = lower.contains("spotify")
    let otherService = ["apple music", "youtube music", "soundcloud", "tidal"].contains(where: lower.contains)
    if otherService { return .notSpotify }

    let musicNouns = ["playlist", "track", "song", "album", "artist", "music", "playback", "device"]
    let actionWords = [
      "play", "start", "pause", "stop", "resume", "continue", "skip", "next", "previous", "show", "list",
      "open", "find", "what", "which", "move", "switch", "transfer",
    ]
    let actionPhrases = ["put on", "go back", "pull up"]
    let operational =
      musicNouns.contains(where: lower.contains)
      && (actionWords.contains(where: { containsWord($0, in: lower) }) || containsAny(lower, actionPhrases))
    guard explicitSpotify || operational else { return .notSpotify }

    let mutationTerms = ["delete", "remove", "create", "make", "add", "save", "follow", "unfollow"]
    if mutationTerms.contains(where: lower.contains) {
      return .clarification(
        "Rook’s Spotify connection can read your account and control playback, but it cannot modify playlists or your saved library."
      )
    }
    if lower.contains(" and then ") || lower.contains(" then ") {
      return .clarification(
        "That Spotify request contains more than one action. Say the Spotify action separately so I don’t execute only part of it."
      )
    }

    if containsAny(lower, ["pause", "stop playback", "stop the music", "stop spotify"]) { return .intent(.pause) }
    if containsAny(lower, ["skip", "next track", "next song"]) { return .intent(.next) }
    if containsAny(lower, ["previous", "go back", "last track", "last song"]) { return .intent(.previous) }
    if containsAny(lower, ["resume", "continue"]) { return .intent(.resume) }

    if lower.contains("device") {
      if let destination = phrase(after: " to ", in: command),
        containsAny(lower, ["move", "switch", "transfer"])
      {
        return .intent(.transferPlayback(deviceName: destination))
      }
      return .intent(.devices)
    }
    if containsAny(lower, ["what is playing", "what's playing", "now playing", "current track", "current song"]) {
      return .intent(.nowPlaying)
    }
    if containsAny(lower, ["recent", "lately", "listening history", "listened to"]) {
      return .intent(.recentlyPlayed)
    }

    let topLanguage =
      containsWord("top", in: lower)
      || containsAny(lower, ["most played", "favorite", "favourite"])
    let wantsPlayback =
      containsWord("play", in: lower) || containsWord("start", in: lower)
      || containsAny(lower, ["put on", "listen to"])
    if topLanguage, lower.contains("artist") { return .intent(.top(.artists)) }
    if topLanguage, containsAny(lower, ["track", "song", "music"]) {
      return .intent(wantsPlayback ? .playTopTracks : .top(.tracks))
    }

    if lower.contains("playlist") {
      let purposes = RookSpotifyPurposeMatcher.purposes(in: command)
      let wantsRecommendation = containsAny(
        lower,
        [
          "which", "what would", "what should", "best", "good for", "seems like", "looks like", "sounds like",
        ])
      if !wantsPlayback, wantsRecommendation, !purposes.isEmpty {
        return .intent(.recommendPlaylists(purposes: purposes))
      }
      if wantsPlayback {
        if containsAny(lower, [" any ", " some ", " one of "]) { return .intent(.playAnyPlaylist) }
        if let name = playlistName(in: command) {
          return .intent(.play(query: name, preferredKind: .playlist, libraryOnly: true))
        }
        return .intent(.choosePlaylist)
      }
      return .intent(.playlists)
    }

    if wantsPlayback {
      for kind in RookSpotifyMediaKind.allCases where kind != .playlist {
        if let name = mediaName(kind: kind, in: command) {
          return .intent(.play(query: name, preferredKind: kind, libraryOnly: false))
        }
      }
      if explicitSpotify, containsAny(lower, ["music", "playback"]) { return .intent(.resume) }
    }

    if explicitSpotify, lower.contains("popular") {
      return .clarification("Do you mean your top Spotify tracks, or a playlist with a specific name?")
    }
    if explicitSpotify, operational {
      return .clarification(
        "I can handle Spotify directly. Say the playlist, track, album, artist, or device you want—or ask me to show your playlists."
      )
    }
    return .notSpotify
  }

  private static func playlistName(in command: String) -> String? {
    let patterns = [
      #"(?i)(?:play|start|put\s+on)(?:\s+me)?\s+(?:my\s+|the\s+)?(.+?)\s+playlist"#,
      #"(?i)playlist\s+(?:called|named)\s+(.+)$"#,
    ]
    for pattern in patterns {
      if let value = firstCapture(pattern, in: command) {
        let name = scrub(value)
        if !name.isEmpty, !["spotify", "a", "any", "some", "one of my"].contains(name.lowercased()) {
          return name
        }
      }
    }
    return nil
  }

  private static func mediaName(kind: RookSpotifyMediaKind, in command: String) -> String? {
    let noun = kind == .track ? "(?:track|song)" : kind.rawValue
    let patterns = [
      "(?i)(?:play|start|put\\s+on)(?:\\s+me)?\\s+(?:the\\s+)?\(noun)\\s+(.+?)(?:\\s+(?:on|in)\\s+spotify)?$",
      "(?i)(?:play|start|put\\s+on)(?:\\s+me)?\\s+(.+?)\\s+\(noun)(?:\\s+(?:on|in)\\s+spotify)?$",
    ]
    for pattern in patterns {
      if let value = firstCapture(pattern, in: command) {
        let name = scrub(value)
        if !name.isEmpty { return name }
      }
    }
    return nil
  }

  private static func phrase(after marker: String, in command: String) -> String? {
    guard let range = command.range(of: marker, options: [.caseInsensitive]) else { return nil }
    let value = scrub(String(command[range.upperBound...]))
    return value.isEmpty ? nil : value
  }

  private static func firstCapture(_ pattern: String, in value: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range])
  }

  private static func scrub(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: #"(?i)\s+(?:on|in)\s+spotify$"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?'\"“”‘’"))
  }

  private static func cleaned(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func containsAny(_ value: String, _ phrases: [String]) -> Bool {
    phrases.contains(where: value.contains)
  }

  private static func containsWord(_ word: String, in value: String) -> Bool {
    value.range(
      of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
      options: [.regularExpression, .caseInsensitive]
    ) != nil
  }
}
