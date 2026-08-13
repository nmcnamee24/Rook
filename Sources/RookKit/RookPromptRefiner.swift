import Foundation

/// Converts conversational speech recognition output into a clean Rook command.
///
/// The deterministic pass is intentionally conservative and runs before any
/// network or model work. It removes unambiguous dictation noise while keeping
/// names, numbers, paths, URLs, negations, and the user's requested action intact.
public enum RookPromptRefiner {
  public static func refine(_ transcript: String) -> String {
    var text =
      transcript
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "" }

    // Spoken layout cues are useful in longer dictated prompts.
    text = replacing(
      #"(?i)[ \t]*\bnew[ -]paragraph\b[,.]?[ \t]*"#,
      in: text,
      with: "\n\n"
    )
    text = replacing(
      #"(?i)[ \t]*\b(?:new[ -]line|line[ -]break)\b[,.]?[ \t]*"#,
      in: text,
      with: "\n"
    )
    text = replacing(
      #"(?i)[ \t]*\b(?:bullet[ -]point|next[ -]bullet)\b[:,]?[ \t]*"#,
      in: text,
      with: "\n- "
    )

    // Common opening discourse markers do not change the requested work.
    text = replacing(
      #"(?i)^\s*(?:(?:okay|ok|well|so|basically|you know)\b[,;:]?\s*)+"#,
      in: text,
      with: ""
    )

    // Remove fillers only when their grammar is unambiguous. In particular,
    // semantic uses such as "I like Swift" must remain untouched.
    text = replacing(
      #"(?i)[ \t]*,[ \t]*(?:um+|uh+|erm+|er+|hmm+|mm+|like|you know)[ \t]*,[ \t]*"#,
      in: text,
      with: " "
    )
    text = replacing(
      #"(?i)(^|[\s(\[{:;—–-])(?:um+|uh+|erm+|er+|hmm+|mm+)(?=$|[\s,.!?;:)\]}—–-])(?:[ \t]*[,;:—–-][ \t]*|[ \t]+)"#,
      in: text,
      with: "$1"
    )
    text = replacing(
      #"(?i),\s*(?:basically|you know)\b\s*,?\s*"#,
      in: text,
      with: ", "
    )
    text = replacing(
      #"(?i)\b(leav(?:e|ing)|left)\s+it\s+like\s+"#,
      in: text,
      with: "$1 it as "
    )
    text = removingFillerLikes(from: text)

    // Collapse the most common speech-recognition restart: an immediately
    // repeated word or short phrase ("I want to I want to...").
    for _ in 0..<3 {
      let previous = text
      text = replacing(
        #"(?i)\b((?:[\p{L}\p{N}][\p{L}\p{N}'’_-]*[ \t]+){2,5})\1"#,
        in: text,
        with: "$1"
      )
      text = replacing(
        #"(?i)\b([\p{L}\p{N}][\p{L}\p{N}'’_-]*)[ \t]+\1\b"#,
        in: text,
        with: "$1"
      )
      text = replacing(
        #"(?i)\b([\p{L}\p{N}][\p{L}\p{N}'’_-]*)\s*[,;:—–-]\s*\1\b"#,
        in: text,
        with: "$1"
      )
      if text == previous { break }
    }

    text = replacing(#"(?<=[\p{Ll}\p{N}])\s+But\s+"#, in: text, with: ", but ")
    text = replacing(
      #"(?i)\b(the question)\s*,\s*(can|could|do|does|is|are|should|will|would)\b"#,
      in: text,
      with: "$1: $2"
    )
    text = replacing(#"[ \t]+([,.;:!?])"#, in: text, with: "$1")
    text = replacing(#",(?:[ \t]*,)+"#, in: text, with: ",")
    text = replacing(#"[ \t]{2,}"#, in: text, with: " ")
    text = replacing(#"[ \t]*\n[ \t]*"#, in: text, with: "\n")
    text = replacing(#"\n{3,}"#, in: text, with: "\n\n")
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    text = capitalizeSentenceStarts(in: text)
    return addingTerminalPunctuationIfSafe(to: text)
  }

  /// Model polishing is reserved for prompts where semantic restructuring can
  /// materially improve the result. Short clean commands never pay model latency.
  public static func needsModelPolish(original: String, locallyRefined: String) -> Bool {
    let words = wordTokens(in: original)
    guard words.count >= 8 else { return false }
    if normalizedForComparison(original) != normalizedForComparison(locallyRefined) { return true }
    if words.count >= 18 { return true }
    return original.range(
      of: #"(?i)\b(?:and then|first(?:ly)?|second(?:ly)?|finally|I mean|no,? actually|scratch that)\b"#,
      options: .regularExpression
    ) != nil
  }

  /// Accepts a model rewrite only when it is prompt-shaped and retains tokens
  /// whose accidental mutation would be especially costly.
  public static func validatedModelPolish(_ candidate: String, preserving original: String) -> String? {
    var polished = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if polished.hasPrefix("```") && polished.hasSuffix("```") {
      let lines = polished.components(separatedBy: .newlines)
      if lines.count >= 3 {
        polished = lines.dropFirst().dropLast().joined(separator: "\n")
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    polished = replacing(
      #"(?i)^\s*(?:polished|cleaned|rewritten) prompt\s*:\s*"#,
      in: polished,
      with: ""
    )
    guard !polished.isEmpty, polished.count <= 4_000 else { return nil }
    guard polished.count <= max(original.count * 2 + 240, 400) else { return nil }

    let originalWords = wordTokens(in: original)
    let polishedWords = wordTokens(in: polished)
    guard polishedWords.count >= max(1, originalWords.count / 3) else { return nil }

    for token in protectedTokens(in: original) {
      guard polished.range(of: token, options: [.caseInsensitive, .literal]) != nil else { return nil }
    }
    for negation in ["not", "never", "without", "don't", "doesn't", "didn't", "can't", "won't"] {
      if containsWord(negation, in: original), !containsWord(negation, in: polished) { return nil }
    }
    return refine(polished)
  }

  private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
  }

  private static func removingFillerLikes(from text: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: #"(?i)\blike\b"#) else { return text }
    let source = text as NSString
    let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
    guard !matches.isEmpty else { return text }

    let fillerPredecessors: Set<String> = [
      "a", "about", "and", "at", "but", "for", "from", "in", "it", "its", "my", "of", "on", "or",
      "our", "so", "that", "the", "then", "there", "there's", "this", "to", "was", "well", "with",
      "your",
    ]
    var removalRanges: [NSRange] = []
    for match in matches {
      let before = source.substring(to: match.range.location)
      let afterLocation = match.range.location + match.range.length
      let after = source.substring(from: afterLocation)
      let previous = wordTokens(in: before).last?.lowercased()
      let next = wordTokens(in: after).first?.lowercased()
      let precedingCharacter = before.trimmingCharacters(in: .whitespaces).last
      let isFiller =
        previous == nil
        || precedingCharacter == ","
        || previous == next
        || previous.map(fillerPredecessors.contains) == true
      if isFiller { removalRanges.append(match.range) }
    }

    let result = NSMutableString(string: text)
    for range in removalRanges.reversed() { result.replaceCharacters(in: range, with: "") }
    return result as String
  }

  private static func wordTokens(in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{N}'’_-]*"#) else {
      return []
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      return String(text[range])
    }
  }

  private static func protectedTokens(in text: String) -> [String] {
    let pattern = #"https?://\S+|(?:~|/)[^\s,;]+|--?[A-Za-z0-9][A-Za-z0-9_-]*|\b\d+(?:[.:/-]\d+)*\b"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard let range = Range(match.range, in: text) else { return nil }
      return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?"))
    }
  }

  private static func containsWord(_ word: String, in text: String) -> Bool {
    text.range(
      of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
      options: [.caseInsensitive, .regularExpression]
    ) != nil
  }

  private static func normalizedForComparison(_ text: String) -> String {
    replacing(#"\s+"#, in: text, with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func capitalizeSentenceStarts(in text: String) -> String {
    var result = ""
    var shouldCapitalize = true
    let characters = Array(text)
    for (index, character) in characters.enumerated() {
      if shouldCapitalize, character.isLetter {
        let wordTail = characters.dropFirst(index + 1).prefix { $0.isLetter }
        let looksLikeBrand = wordTail.contains(where: \Character.isUppercase)
        let word = String([character] + wordTail).lowercased()
        let naturalStarts: Set<String> = [
          "a", "add", "am", "an", "analyze", "are", "build", "can", "check", "clean", "compare", "could",
          "create", "debug", "did", "do", "does", "draft", "explain", "find", "fix", "format", "give", "has",
          "have", "help", "how", "i", "implement", "inspect", "is", "list", "make", "may", "open", "please",
          "preserve", "refactor", "remove", "review", "run", "should", "summarize", "test", "update", "was",
          "were", "what", "when", "where", "which", "who", "why", "will", "would", "write",
        ]
        let shouldChangeCase = !looksLikeBrand && naturalStarts.contains(word)
        result.append(shouldChangeCase ? Character(String(character).uppercased()) : character)
        shouldCapitalize = false
      } else {
        result.append(character)
        if !character.isWhitespace && !["\"", "'", "“", "‘", "(", "[", "{", "-"].contains(character) {
          shouldCapitalize = false
        }
      }
      if character == "\n" {
        shouldCapitalize = true
      } else if [".", "?", "!"].contains(character) {
        let nextIsBoundary = index + 1 == characters.count || characters[index + 1].isWhitespace
        if nextIsBoundary { shouldCapitalize = true }
      }
    }
    return result
  }

  private static func addingTerminalPunctuationIfSafe(to text: String) -> String {
    guard let last = text.last, !text.contains("\n- ") else { return text }
    if ".!?:;…)]}`\"'”’".contains(last) { return text }
    let finalToken = text.split(whereSeparator: \Character.isWhitespace).last.map(String.init) ?? ""
    if finalToken.contains("/") || finalToken.contains("\\") || finalToken.hasPrefix("-")
      || finalToken.contains("@") || finalToken.contains(".")
    {
      return text
    }
    let first = wordTokens(in: text).first?.lowercased() ?? ""
    let commandStarts: Set<String> = [
      "bun", "cargo", "cd", "curl", "docker", "git", "go", "grep", "kubectl", "ls", "npm", "pip", "pip3",
      "pnpm", "python", "python3", "rg", "swift", "yarn",
    ]
    if commandStarts.contains(first) { return text }
    let questionStarts: Set<String> = [
      "am", "are", "can", "could", "did", "do", "does", "has", "have", "how", "is", "may", "should",
      "was", "were", "what", "when", "where", "which", "who", "why", "will", "would",
    ]
    return text + (questionStarts.contains(first) ? "?" : ".")
  }
}
