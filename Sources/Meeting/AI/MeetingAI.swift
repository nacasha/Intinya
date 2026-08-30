import Foundation

/// Tier 3: a language-model pass over a finished transcript.
///
/// Tiers 1 and 2 both ask "what sounds were in this audio", and are bounded by
/// acoustics. This asks a different question — "given what this text says, what
/// was meant" — which is the only way to fix errors the audio does not contain.
/// Whisper hears an Indonesian speaker say "bahk-kend" and faithfully writes
/// `batchkent`; no ASR model recovers `backend` from that, but a model reading
/// `deployment batchkent dulu` does.
enum MeetingAI {

    struct Result {
        var corrections: [Int: String] = [:]   // line number -> corrected text
        var summary: String = ""               // markdown, for notes
        var terms: [String] = []               // glossary candidates
        var answer: String = ""                // markdown, for the result panel
        var title: String = ""                 // short label for the library

        var isEmpty: Bool {
            corrections.isEmpty && summary.isEmpty && terms.isEmpty
                && answer.isEmpty && title.isEmpty
        }
    }

    // MARK: - Prompt

    /// Numbered, speaker-tagged lines. Numbers are the contract for mapping the
    /// response back onto segments.
    static func transcriptInput(_ segments: [TranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1) [\(segment.source.label) \(segment.start.clockString)] \(segment.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Run

    static func run(
        action: AIAction,
        userInput: String = "",
        segments: [TranscriptSegment],
        glossary: Glossary,
        meetingType: MeetingType? = nil,
        provider: AIProvider,
        binaryOverride: String?
    ) async throws -> Result {
        guard !segments.isEmpty else {
            throw AIError.badResponse("This recording has no transcript to work from.")
        }

        let text = try await AIRunner.run(
            provider: provider,
            instruction: action.instruction(
                glossary: glossary,
                userInput: userInput,
                meetingType: meetingType
            ),
            input: transcriptInput(segments),
            binaryOverride: binaryOverride
        )
        return try parse(text, lineCount: segments.count)
    }

    // MARK: - Parsing

    static func parse(_ text: String, lineCount: Int) throws -> Result {
        guard let data = extractJSON(from: text) else {
            throw AIError.badResponse(String(text.prefix(300)))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse("Response was not valid JSON.")
        }

        var corrections: [Int: String] = [:]
        for entry in object["corrections"] as? [[String: Any]] ?? [] {
            guard let number = entry["n"] as? Int,
                  let raw = entry["text"] as? String,
                  // Ignore any line number the model invented; a bad index would
                  // otherwise silently overwrite the wrong utterance.
                  number >= 1, number <= lineCount,
                  case let corrected = stripSpeakerPrefix(raw),
                  !corrected.trimmingCharacters(in: .whitespaces).isEmpty
            else { continue }
            corrections[number] = corrected
        }

        return Result(
            corrections: corrections,
            summary: (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            terms: (object["terms"] as? [String] ?? []).filter { !$0.isEmpty },
            answer: (object["answer"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            // Models like to wrap a title in quotes despite being told not to.
            title: (object["title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        )
    }

    /// Removes an echoed `[Them 00:14] ` tag from a corrected line.
    ///
    /// The input format carries the speaker and timestamp so the model has that
    /// context, and models routinely hand it back as part of the "corrected"
    /// text. Those fields belong to the segment, not the words, so a returned
    /// prefix has to be stripped or it ends up rendered inside the bubble.
    static func stripSpeakerPrefix(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return trimmed }

        let tag = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        // Only strip what actually looks like our own tag: a speaker label and a
        // clock time. Real transcript text can legitimately start with a bracket.
        let parts = tag.split(separator: " ")
        guard parts.count == 2,
              AudioSource.allCases.contains(where: { $0.label == parts[0] }),
              parts[1].contains(":")
        else { return trimmed }

        return String(trimmed[trimmed.index(after: close)...])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Pulls the JSON object out of a reply, tolerating code fences or a
    /// sentence of preamble even though the prompt asks for neither.
    private static func extractJSON(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"), start < end
        else { return nil }
        return String(trimmed[start...end]).data(using: .utf8)
    }
}
