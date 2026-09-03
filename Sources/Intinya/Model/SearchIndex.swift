import Foundation

/// Which part of a recording a hit came from.
enum SearchScope: String, Sendable, Hashable, CaseIterable {
    case title
    case transcript
    case notes
    case sections

    var systemImage: String {
        switch self {
        case .title: return "textformat"
        case .transcript: return "text.alignleft"
        case .notes: return "note.text"
        case .sections: return "text.insert"
        }
    }

    var label: String {
        switch self {
        case .title: return "Title"
        case .transcript: return "Transcript"
        case .notes: return "Notes"
        case .sections: return "Section"
        }
    }
}

/// Where to land when a recording is opened from somewhere else.
///
/// Carries the scope rather than a pane, because the panes are the detail
/// view's own business — this says "a note matched", and that view decides
/// which of its tabs shows notes.
struct SessionFocus: Hashable {
    let scope: SearchScope
    let segmentID: UUID?
    let time: TimeInterval?
}

/// One matching line.
struct SearchHit: Identifiable, Hashable, Sendable {
    let id: String
    let scope: SearchScope
    let segmentID: UUID?
    let start: TimeInterval?
    let source: AudioSource?
    let text: String

    var focus: SessionFocus {
        SessionFocus(scope: scope, segmentID: segmentID, time: start)
    }
}

/// The hits from one recording.
struct SearchGroup: Identifiable, Hashable, Sendable {
    let sessionID: String
    let title: String
    let recordedAt: Date
    let hits: [SearchHit]
    /// Matches beyond the per-recording cap, so the row can say so.
    let more: Int

    var id: String { sessionID }
    var total: Int { hits.count + more }
}

/// Full-text search across every recording on disk.
///
/// Deliberately not SQLite FTS or a persisted inverted index. A
/// `transcript.json` is a few kilobytes, so the entire library is a couple of
/// megabytes of text — matching it end to end takes milliseconds, which is
/// less time than the debounce that precedes it. `GlossaryIndex` already reads
/// every transcript on the same terms.
///
/// What it *does* do carefully is avoid repeating that work: documents are
/// built once, reused across queries, and rebuilt per recording only when that
/// recording's files change on disk. Nothing is parsed on a keystroke.
@MainActor
final class SearchIndex: ObservableObject {

    /// Matches for the current query, grouped by recording, newest first.
    @Published private(set) var results: [SearchGroup] = []
    @Published private(set) var isSearching = false
    @Published private(set) var isIndexing = false
    /// Total matches found, including any past the display caps.
    @Published private(set) var totalHits = 0
    /// Whether the caps cut the result list short.
    @Published private(set) var isTruncated = false

    /// Shortest query worth running. One letter matches most of the library and
    /// tells you nothing.
    static let minimumQueryLength = 2

    /// Caps, so a query for "the" cannot build a fifty-thousand-row list.
    // `nonisolated`, because the matching pass that reads them runs off the
    // main actor.
    nonisolated private static let hitLimit = 400
    nonisolated private static let perSessionLimit = 12

    private var documents: [SearchDocument] = []
    /// What `documents` was built from.
    private var signature: String?
    private var indexJob: Task<Void, Never>?
    private var searchJob: Task<Void, Never>?
    private var query = ""

    // MARK: - Indexing

    /// Rebuilds any document whose recording has changed on disk.
    func refresh(_ sessions: [Session]) {
        let sources = sessions.map(SearchSource.init)
        let next = Self.signature(of: sources)
        guard next != signature else { return }

        indexJob?.cancel()
        signature = next
        isIndexing = true

        // Reused verbatim for recordings whose files have not moved, so
        // enhancing one session re-reads one session.
        let cache = Dictionary(documents.map { ($0.sessionID, $0) }) { first, _ in first }

        indexJob = Task { [weak self] in
            let built = await Task.detached(priority: .utility) {
                Self.build(sources: sources, reusing: cache)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.documents = built
            self.isIndexing = false
            // The library changed underneath whatever is on screen.
            if !self.query.isEmpty { self.run(self.query, debounced: false) }
        }
    }

    // MARK: - Querying

    /// Runs a query, debounced. Safe to call on every keystroke.
    func search(_ raw: String) {
        run(raw.trimmingCharacters(in: .whitespacesAndNewlines), debounced: true)
    }

    func clear() {
        searchJob?.cancel()
        query = ""
        results = []
        totalHits = 0
        isTruncated = false
        isSearching = false
    }

    private func run(_ trimmed: String, debounced: Bool) {
        searchJob?.cancel()
        query = trimmed

        let tokens = Self.tokens(from: trimmed)
        guard trimmed.count >= Self.minimumQueryLength, !tokens.isEmpty else {
            results = []
            totalHits = 0
            isTruncated = false
            isSearching = false
            return
        }

        isSearching = true
        let corpus = documents

        searchJob = Task { [weak self] in
            if debounced {
                // Long enough to swallow a burst of typing, short enough that a
                // pause feels like an answer rather than a wait. Same interval
                // `SessionStore` coalesces its rescans on.
                try? await Task.sleep(for: .milliseconds(120))
            }
            guard !Task.isCancelled else { return }

            let outcome = await Task.detached(priority: .userInitiated) {
                Self.match(tokens: tokens, in: corpus)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.results = outcome.groups
            self.totalHits = outcome.total
            self.isTruncated = outcome.truncated
            self.isSearching = false
        }
    }

    // MARK: - Text

    /// Case-, diacritic- and width-insensitive, so "resume" finds "résumé" and
    /// a full-width character typed on a Japanese keyboard still matches.
    ///
    /// Applied once per line at index time and once per query, never per
    /// comparison — folding a megabyte of transcript on every keystroke is
    /// exactly the cost this class exists to avoid.
    nonisolated static func fold(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil)
    }

    /// Query words. Every one must appear in a line for it to match, which is
    /// what makes a second word narrow the results rather than widen them.
    nonisolated static func tokens(from query: String) -> [String] {
        fold(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // MARK: - Work

    nonisolated private static func signature(of sources: [SearchSource]) -> String {
        sources
            .map { "\($0.id)@\($0.stamp.timeIntervalSince1970)" }
            .sorted()
            .joined(separator: "\u{1}")
    }

    nonisolated private static func build(
        sources: [SearchSource],
        reusing cache: [String: SearchDocument]
    ) -> [SearchDocument] {
        var out: [SearchDocument] = []
        out.reserveCapacity(sources.count)

        for source in sources {
            if Task.isCancelled { return out }
            // Same recording, same files: nothing to re-read.
            if let cached = cache[source.id], cached.stamp == source.stamp {
                out.append(cached)
                continue
            }
            out.append(document(for: source))
        }
        return out
    }

    nonisolated private static func document(for source: SearchSource) -> SearchDocument {
        var lines: [SearchLine] = []

        lines.append(SearchLine(
            scope: .title,
            segmentID: nil,
            start: nil,
            source: nil,
            text: source.title))

        let transcript = SessionStore.loadTranscript(in: source.directory)

        for segment in transcript?.segments ?? [] {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(SearchLine(
                scope: .transcript,
                segmentID: segment.id,
                start: segment.start,
                source: segment.source,
                text: text))
        }

        for section in transcript?.sections ?? [] {
            let text = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(SearchLine(
                scope: .sections,
                segmentID: nil,
                start: section.start,
                source: nil,
                text: text))
        }

        // A paragraph at a time. Markdown's blank-line separation is already
        // the unit a reader thinks in, and a whole notes file as one "line"
        // would put a hit's context nowhere near the words that matched.
        for paragraph in Notes.load(in: source.directory).components(separatedBy: "\n") {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(SearchLine(
                scope: .notes,
                segmentID: nil,
                start: nil,
                source: nil,
                text: text))
        }

        return SearchDocument(
            sessionID: source.id,
            title: source.title,
            recordedAt: source.recordedAt,
            stamp: source.stamp,
            lines: lines)
    }

    nonisolated private static func match(
        tokens: [String],
        in documents: [SearchDocument]
    ) -> (groups: [SearchGroup], total: Int, truncated: Bool) {
        var groups: [SearchGroup] = []
        var total = 0
        var emitted = 0
        var truncated = false

        for document in documents {
            if Task.isCancelled { return (groups, total, truncated) }

            var hits: [SearchHit] = []
            var matches = 0

            for (offset, line) in document.lines.enumerated() {
                guard tokens.allSatisfy({ line.key.contains($0) }) else { continue }
                matches += 1
                guard hits.count < perSessionLimit else { continue }
                hits.append(SearchHit(
                    id: "\(document.sessionID)#\(offset)",
                    scope: line.scope,
                    segmentID: line.segmentID,
                    start: line.start,
                    source: line.source,
                    text: line.text))
            }

            guard !hits.isEmpty else { continue }
            total += matches
            emitted += hits.count
            groups.append(SearchGroup(
                sessionID: document.sessionID,
                title: document.title,
                recordedAt: document.recordedAt,
                hits: hits,
                more: matches - hits.count))

            // Stop building rows, but keep the flag honest about there being
            // more of the library past this point.
            if emitted >= hitLimit {
                truncated = true
                break
            }
        }

        return (groups, total, truncated)
    }
}

/// One searchable line: a transcript segment, a note paragraph, a section
/// heading, or the recording's title.
private struct SearchLine: Sendable {
    let scope: SearchScope
    let segmentID: UUID?
    let start: TimeInterval?
    let source: AudioSource?
    let text: String
    /// Folded copy of `text`, which is what queries are actually compared
    /// against. Roughly doubles the index's footprint — a few megabytes for a
    /// large library — and buys not folding the corpus on every keystroke.
    let key: String

    init(
        scope: SearchScope,
        segmentID: UUID?,
        start: TimeInterval?,
        source: AudioSource?,
        text: String
    ) {
        self.scope = scope
        self.segmentID = segmentID
        self.start = start
        self.source = source
        self.text = text
        self.key = SearchIndex.fold(text)
    }
}

/// One recording, reduced to the text in it.
private struct SearchDocument: Sendable {
    let sessionID: String
    let title: String
    let recordedAt: Date
    let stamp: Date
    let lines: [SearchLine]
}

/// The bits of a `Session` the indexing pass needs, so the work can cross to a
/// detached task without dragging the model along.
private struct SearchSource: Sendable {
    let id: String
    let title: String
    let recordedAt: Date
    let directory: URL
    /// Newest write across the files that hold text. Enhancement rewrites the
    /// transcript in place and notes are edited constantly, so identity alone
    /// would pin the index to whatever it read first.
    let stamp: Date

    init(_ session: Session) {
        id = session.id
        title = session.displayTitle
        recordedAt = session.recordedAt
        directory = session.directory

        let written = [
            SessionStore.transcriptURL(in: session.directory),
            Notes.url(in: session.directory),
        ].compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        stamp = written.max() ?? session.recordedAt
    }
}
