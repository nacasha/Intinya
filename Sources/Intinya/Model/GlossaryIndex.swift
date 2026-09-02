import Foundation

/// One recording a term turned up in.
struct TermAppearance: Identifiable, Hashable, Sendable {
    let sessionID: String
    let title: String
    let recordedAt: Date
    let count: Int

    var id: String { sessionID }
}

/// What the transcripts say about a glossary term.
struct TermStats: Hashable, Sendable {
    var mentions = 0
    /// Recordings it appears in, newest first.
    var appearances: [TermAppearance] = []

    var meetings: Int { appearances.count }
    /// A term can be in the glossary precisely *because* the transcriber kept
    /// getting it wrong, so this is "not yet seen", never "unused".
    var isUnseen: Bool { mentions == 0 }

    var first: TermAppearance? { appearances.last }
    var last: TermAppearance? { appearances.first }
}

/// Counts glossary terms across every transcript on disk.
///
/// Feasible only because the corpus is small and already parsed: a session's
/// `transcript.json` runs a few kilobytes, and `SessionStore` decodes all of
/// them on every scan anyway. Counting is one more pass over text that has
/// already been read off disk once.
///
/// Kept out of `GlossaryStore` because the two answer to different owners — the
/// store is the user's vocabulary and must save instantly, while this is a
/// derived view of the library that can lag a moment behind without anyone
/// noticing.
@MainActor
final class GlossaryIndex: ObservableObject {

    @Published private(set) var stats: [String: TermStats] = [:]
    @Published private(set) var isIndexing = false

    /// Sessions whose transcripts were actually read, for the summary panel.
    @Published private(set) var indexedMeetings = 0

    /// What the current numbers were computed from. Recomputing on every view
    /// update would re-read the library each time a chip is hovered.
    private var signature: String?
    private var job: Task<Void, Never>?

    func stats(for term: String) -> TermStats {
        stats[term.lowercased()] ?? TermStats()
    }

    /// Rebuilds the counts if the vocabulary or the library has changed.
    func refresh(terms: [String], sessions: [Session]) {
        let sources = sessions.compactMap(Source.init)
        let next = Self.signature(terms: terms, sources: sources)
        guard next != signature else { return }

        job?.cancel()
        signature = next
        isIndexing = true

        job = Task { [weak self] in
            let counted = await Task.detached(priority: .utility) {
                Self.index(terms: terms, sources: sources)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.stats = counted
            self.indexedMeetings = sources.count
            self.isIndexing = false
        }
    }

    // MARK: - Work

    nonisolated private static func signature(terms: [String], sources: [Source]) -> String {
        let vocabulary = terms.map { $0.lowercased() }.sorted().joined(separator: "\u{1}")
        let library = sources
            .map { "\($0.id)@\($0.stamp.timeIntervalSince1970)" }
            .sorted()
            .joined(separator: "\u{1}")
        return vocabulary + "\u{2}" + library
    }

    nonisolated private static func index(terms: [String], sources: [Source]) -> [String: TermStats] {
        let matchers = terms.compactMap(Matcher.init)
        guard !matchers.isEmpty else { return [:] }

        var out: [String: TermStats] = [:]
        // Oldest first, so appending appearances leaves them in date order and
        // `first`/`last` are just the ends of the array.
        for source in sources.sorted(by: { $0.recordedAt < $1.recordedAt }) {
            guard let transcript = SessionStore.loadTranscript(in: source.directory) else { continue }
            let text = transcript.segments.map(\.text).joined(separator: "\n")
            guard !text.isEmpty else { continue }

            for matcher in matchers {
                let count = matcher.count(in: text)
                guard count > 0 else { continue }
                out[matcher.key, default: TermStats()].mentions += count
                out[matcher.key, default: TermStats()].appearances.append(
                    TermAppearance(
                        sessionID: source.id,
                        title: source.title,
                        recordedAt: source.recordedAt,
                        count: count))
            }
        }

        // Newest first for display; `first`/`last` read from the ends.
        for key in out.keys {
            out[key]?.appearances.reverse()
        }
        return out
    }

}

/// The bits of a `Session` the counting pass needs, and nothing else — so
/// the work can cross to a detached task without dragging the model along.
private struct Source: Sendable {
    let id: String
    let title: String
    let recordedAt: Date
    let directory: URL
    let stamp: Date

    init?(_ session: Session) {
        guard session.hasTranscript else { return nil }
        id = session.id
        title = session.displayTitle
        recordedAt = session.recordedAt
        directory = session.directory
        // Enhancement rewrites the transcript in place, so counts must
        // follow the file's mtime rather than the session's identity.
        stamp = (try? SessionStore.transcriptURL(in: session.directory)
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? session.recordedAt
    }
}

/// Whole-word matching for one term.
///
/// Substring matching is what makes this feature lie: "API" would score a
/// hit on "rapid" and "AI" on "said". `\b` is dropped at an end that is not
/// a word character, since there is no word boundary beside the "+" in
/// "C++" and requiring one there matches nothing at all.
private struct Matcher {
    let key: String
    private let regex: NSRegularExpression

    init?(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        key = trimmed.lowercased()
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
        let opensOnWord = trimmed.first?.isLetter == true || trimmed.first?.isNumber == true
        let closesOnWord = trimmed.last?.isLetter == true || trimmed.last?.isNumber == true
        let pattern = (opensOnWord ? "\\b" : "") + escaped + (closesOnWord ? "\\b" : "")

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        self.regex = regex
    }

    func count(in text: String) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
