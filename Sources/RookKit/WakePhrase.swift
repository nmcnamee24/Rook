import Foundation

public enum WakePhrase {
    public static func contains(_ transcript: String, phrase: String) -> Bool {
        range(in: transcript, phrase: phrase) != nil
    }

    public static func commandTail(in transcript: String, phrase: String) -> String? {
        guard let match = range(in: transcript, phrase: phrase) else { return nil }
        let tail = String(transcript[match.upperBound...])
        return clean(tail)
    }

    private static func range(in transcript: String, phrase: String) -> Range<String.Index>? {
        let configuredWords = phrase
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        if configuredWords == ["rook"] {
            // A single-word wake phrase should be at the start of the utterance
            // (optionally after “Hey”) so ordinary chess talk cannot wake Rook.
            // Brooke/Brook are the common Apple Speech substitutions observed
            // for the uncommon name.
            for candidate in ["rook", "brooke", "brook"] {
                if let match = leadingNameRange(in: transcript, name: candidate) {
                    return match
                }
            }
            return nil
        }

        for candidate in recognitionCandidates(for: phrase) {
            if let match = exactRange(in: transcript, phrase: candidate) {
                return match
            }
        }
        return nil
    }

    private static func leadingNameRange(in transcript: String, name: String) -> Range<String.Index>? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "(?i)^\\s*(?:hey[\\s,.;:!?\\-]+)?\\b" + escaped + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard let result = regex.firstMatch(in: transcript, range: full),
              let swiftRange = Range(result.range, in: transcript) else { return nil }
        return swiftRange
    }

    private static func exactRange(in transcript: String, phrase: String) -> Range<String.Index>? {
        let words = phrase
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        let pattern = "(?i)\\b" + words.joined(separator: "[\\s,.;:!?\\-]+") + "\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
        guard let result = regex.firstMatch(in: transcript, range: full),
              let swiftRange = Range(result.range, in: transcript) else { return nil }
        return swiftRange
    }

    private static func recognitionCandidates(for phrase: String) -> [String] {
        let words = phrase
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        guard words == ["rook", "wake", "up"] else { return [phrase] }

        // Apple Speech occasionally turns the uncommon name "Rook" into a
        // nearby word. Prefer the full configured phrase, then a small set of
        // observed-safe alternatives. Bare "Rook" also supports the natural
        // one-shot form: "Rook, what's next?"
        return [
            phrase,
            "rook wakeup",
            "brook wake up",
            "brooke wake up",
            "book wake up",
            "rook",
        ]
    }

    public static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }
}
