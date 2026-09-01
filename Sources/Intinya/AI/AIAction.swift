import SwiftUI

/// Where an action's output belongs.
///
/// Making this explicit is what lets several actions share one runner: the
/// destination decides how a response is applied, so adding an action is data,
/// not new plumbing.
enum AIOutput {
    /// Rewrites transcript lines in place.
    case transcript
    /// Appended to `notes.md`, never overwriting hand-written notes.
    case notes
    /// Adds vocabulary that primes the next transcription.
    case glossary
    /// Names the recording in the library.
    case title
    /// Shown once in a result panel; the user decides whether to keep it.
    case panel
}

/// One thing the AI can do to a recording.
struct AIAction: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let detail: String
    let output: AIOutput
    /// Free-text the user supplies, e.g. a question. Nil for fixed actions.
    var needsInput: String?

    static func == (lhs: AIAction, rhs: AIAction) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Catalog

    static let repairTranscript = AIAction(
        id: "repair",
        title: "Repair Transcript",
        systemImage: "text.badge.checkmark",
        detail: "Fix mis-heard words, English terms rendered phonetically, affixes, and punctuation. Rewrites the transcript.",
        output: .transcript
    )

    static let generateTitle = AIAction(
        id: "title",
        title: "Generate Title",
        systemImage: "textformat",
        detail: "Name this recording from what was actually discussed, so the library is browsable.",
        output: .title
    )

    static let summarize = AIAction(
        id: "summary",
        title: "Summary & Action Items",
        systemImage: "list.bullet.rectangle",
        detail: "Ringkasan, action items with owners, and decisions. Appended to notes.",
        output: .notes
    )

    static let extractTerms = AIAction(
        id: "terms",
        title: "Extract Glossary Terms",
        systemImage: "character.book.closed",
        detail: "Find names, products, and jargon, and add them to the glossary so the next recording transcribes them correctly.",
        output: .glossary
    )

    static let translate = AIAction(
        id: "translate",
        title: "Translate to English",
        systemImage: "globe",
        detail: "An English rendering of the conversation, appended to notes. Useful for sharing with people who do not read Indonesian.",
        output: .notes
    )

    static let ask = AIAction(
        id: "ask",
        title: "Ask a Question",
        systemImage: "questionmark.bubble",
        detail: "Ask anything about this meeting. The answer is shown, not saved.",
        output: .panel,
        needsInput: "What did we decide about…?"
    )

    static let custom = AIAction(
        id: "custom",
        title: "Custom Instruction",
        systemImage: "wand.and.rays",
        detail: "Run your own instruction against the transcript.",
        output: .panel,
        needsInput: "e.g. list every deadline mentioned, with who committed to it"
    )

    static let all: [AIAction] = [
        repairTranscript, generateTitle, summarize, extractTerms, translate, ask, custom,
    ]

    /// Actions safe to run unattended. Repair first, so everything downstream
    /// reads corrected text.
    static let runAll: [AIAction] = [repairTranscript, generateTitle, summarize, extractTerms]

    /// What is worth running mid-meeting.
    ///
    /// Titling is premature while the meeting is still going, and translation is
    /// a review task. The rest earn their place — extracting terms mid-meeting
    /// improves how the *remainder* is transcribed, since the glossary primes
    /// Whisper's decoder.
    static let live: [AIAction] = [ask, summarize, extractTerms, repairTranscript, custom]

    // MARK: - Prompts

    private static let sharedContext = """
    This is an automatic transcript of a meeting spoken mainly in Bahasa \
    Indonesia, with English technical terms mixed in mid-sentence. It comes from \
    Whisper, so English words are often rendered phonetically as Indonesian \
    ("batchkent" for "backend", "eskuel" for "SQL"), affixes (me-, di-, -kan, \
    -nya) go missing, and informal spellings are inconsistent (gak / nggak / ga).

    The input is numbered. "You" is the person recording, "Them" is everyone else.
    """

    func instruction(
        glossary: Glossary,
        userInput: String,
        meetingType: MeetingType? = nil
    ) -> String {
        let vocabulary = "Known vocabulary for this team: \(glossary.terms.prefix(80).joined(separator: ", "))."
        let people = (meetingType?.participants ?? []).isEmpty
            ? ""
            : "\n\nUsual participants: \(meetingType!.participants.joined(separator: ", ")). "
            + "Attribute lines to these names where the transcript makes it clear who is speaking."

        switch id {
        case AIAction.repairTranscript.id:
            return """
            \(Self.sharedContext)

            \(vocabulary)

            Fix only what is clearly a transcription error. Do not rewrite style, \
            do not translate, do not summarise, do not invent content. Keep the \
            speaker's register — informal stays informal, just spelled \
            consistently. English technical terms get correct English spelling. \
            Omit any line that is already correct. Never merge or split lines.

            Reply with ONLY this JSON, no prose, no code fences. Do not include \
            the "[Them 00:00]" prefix in the corrected text:
            {"corrections":[{"n":<line number>,"text":"<corrected line>"}]}
            """

        case AIAction.generateTitle.id:
            return """
            \(Self.sharedContext)\(people)

            Give this recording a short title, as a person would name it in a \
            list of meetings. At most six words. Name the actual subject, not the \
            format — "Backend fix and Thursday release", not "Team discussion". \
            Use the language the meeting was held in. No quotes, no date, no \
            trailing punctuation.

            Reply with ONLY this JSON, no prose, no code fences:
            {"title":"<the title>"}
            """

        case AIAction.summarize.id:
            // The meeting type supplies what the summary should contain; the
            // context and the JSON contract are fixed so an edited prompt can
            // never break parsing.
            let spec = meetingType?.summaryPrompt ?? """
            ## Ringkasan
            Three to six bullets covering what was discussed.

            ## Action Items
            With an owner where one was stated.

            ## Keputusan
            Decisions that were actually made.

            Omit any section that has nothing in it.
            """

            return """
            \(Self.sharedContext)\(people)

            Write the summary in the language the meeting was held in. Follow \
            this specification exactly:

            \(spec)

            Do not invent action items, decisions, or attendees that were not in \
            the transcript.

            Reply with ONLY this JSON, no prose, no code fences:
            {"summary":"<the markdown summary>"}
            """

        case AIAction.extractTerms.id:
            return """
            \(Self.sharedContext)

            \(vocabulary)

            List proper nouns, people's names, product names, company names, and \
            domain jargon that recur in this meeting and should be spelled \
            correctly in future transcripts. Correct any that Whisper clearly \
            mangled. Skip terms already in the known vocabulary. Skip ordinary \
            Indonesian and English words.

            Reply with ONLY this JSON, no prose, no code fences:
            {"terms":["..."]}
            """

        case AIAction.translate.id:
            return """
            \(Self.sharedContext)

            Translate this conversation into natural English. Keep the speaker \
            labels and rough timing so it can be followed against the recording. \
            Preserve technical terms as-is rather than translating them.

            Reply with ONLY this JSON, no prose, no code fences:
            {"summary":"<markdown: begin with '## English Translation', then the \
            conversation with speaker labels>"}
            """

        case AIAction.ask.id:
            return """
            \(Self.sharedContext)\(people)

            Answer this question about the meeting: \(userInput)

            Answer from the transcript only. If it does not say, say so plainly \
            rather than guessing. Be brief.

            Reply with ONLY this JSON, no prose, no code fences:
            {"answer":"<markdown>"}
            """

        default:
            return """
            \(Self.sharedContext)

            Follow this instruction about the meeting: \(userInput)

            Reply with ONLY this JSON, no prose, no code fences:
            {"answer":"<markdown>"}
            """
        }
    }
}
