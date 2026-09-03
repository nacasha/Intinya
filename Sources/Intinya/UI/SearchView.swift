import SwiftUI

/// Search across every recording: transcripts, notes, sections, and titles.
///
/// Results are per *line*, not per recording. The sidebar filter already
/// narrows the library to matching recordings; what it cannot do is tell you
/// where in a fifty-minute meeting the word was said, which is the thing you
/// actually came looking for.
struct SearchView: View {
    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var index: SearchIndex

    /// Opens a recording at the line that matched.
    var onOpen: (String, SessionFocus) -> Void

    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private var tokens: [String] { SearchIndex.tokens(from: query) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Every branch of the detail switch has to declare one of these.
        // `navigationSplitViewColumnWidth` is applied to the switch as a whole,
        // so a branch with no floor of its own leaves the column sized by
        // whatever it last held — and the wrong width persists onto the next
        // screen you visit, which is why this broke the session view and not
        // only this one.
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.content)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            isFieldFocused = true
            index.refresh(sessions.sessions)
        }
        // Enhancing or annotating a recording changes what it contains, and the
        // results on screen should follow rather than go stale.
        .onChange(of: sessions.sessions) { _, list in index.refresh(list) }
        .onChange(of: query) { _, text in index.search(text) }
    }

    // MARK: - Header

    /// The field *is* the screen's title. A heading over a search box says the
    /// same word twice and costs a row of the results.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            TextField("Search all recordings", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Font.title)
                .focused($isFieldFocused)

            if index.isSearching || index.isIndexing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .frame(width: 12, height: 12)
            }

            if !query.isEmpty {
                Text(countLabel.uppercased())
                    .font(Theme.Font.label)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Button {
                    query = ""
                    index.clear()
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.headerHeight)
    }

    private var countLabel: String {
        guard query.count >= SearchIndex.minimumQueryLength else { return "" }
        if index.isSearching { return "" }
        let hits = index.totalHits
        guard hits > 0 else { return "no matches" }
        let meetings = index.results.count
        return "\(hits) in \(meetings) recording\(meetings == 1 ? "" : "s")"
    }

    // MARK: - Results

    @ViewBuilder
    private var content: some View {
        if query.count < SearchIndex.minimumQueryLength {
            EmptyState(
                systemImage: "magnifyingglass",
                title: "Search every recording",
                detail: "Finds words in transcripts, notes, sections, and titles. Click a line to open it at that moment."
            )
        } else if index.results.isEmpty {
            if index.isSearching || index.isIndexing {
                EmptyState(systemImage: "magnifyingglass", title: "Searching…")
            } else {
                EmptyState(
                    systemImage: "magnifyingglass",
                    title: "No matches",
                    detail: "Nothing in the library contains \u{201C}\(query)\u{201D}."
                )
            }
        } else {
            results
        }
    }

    private var results: some View {
        SlimScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(index.results) { group in
                    SearchGroupView(group: group, tokens: tokens, onOpen: onOpen)
                }

                if index.isTruncated {
                    Text("Showing the first matches. Add another word to narrow the search.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Pinned to the width it is offered. Without it the stack takes
            // its width from its widest child, and a long undivided note
            // paragraph makes the whole document wider than the pane.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
    }
}

/// One recording's matches, under its name.
private struct SearchGroupView: View {
    let group: SearchGroup
    let tokens: [String]
    let onOpen: (String, SessionFocus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                onOpen(group.sessionID, SessionFocus(scope: .title, segmentID: nil, time: nil))
            } label: {
                HStack(spacing: 8) {
                    Text(group.title)
                        .font(Theme.Font.title)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(metaLine.uppercased())
                        .font(Theme.Font.label)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            ForEach(group.hits) { hit in
                SearchHitRow(hit: hit, tokens: tokens) {
                    onOpen(group.sessionID, hit.focus)
                }
            }

            if group.more > 0 {
                Text("\(group.more) more in this recording")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 62)
                    .padding(.top, 2)
            }
        }
    }

    private var metaLine: String {
        "\(Session.dayLabel(for: Calendar.current.startOfDay(for: group.recordedAt)))  ·  \(group.total) match\(group.total == 1 ? "" : "es")"
    }
}

/// One matching line: where it is on the left, what it says on the right.
private struct SearchHitRow: View {
    let hit: SearchHit
    let tokens: [String]
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                marker
                    // Fixed, so every snippet in the list starts at the same x
                    // whether its line has a timestamp or an icon.
                    .frame(width: 52, alignment: .trailing)

                Text(SearchHitRow.highlighted(snippet, tokens: tokens))
                    .font(Theme.Font.body)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    /// A timestamp when the line has one, the scope's icon when it does not —
    /// a note has no moment in the recording to point at.
    @ViewBuilder
    private var marker: some View {
        if let start = hit.start {
            Text(start.clockString)
                .font(Theme.Font.caption)
                .foregroundStyle(hit.source.map { AnyShapeStyle(Theme.accent(for: $0)) }
                    ?? AnyShapeStyle(.secondary))
        } else {
            Image(systemName: hit.scope.systemImage)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var helpText: String {
        guard let start = hit.start else { return "Open in \(hit.scope.label)" }
        return "Open at \(start.clockString)"
    }

    // MARK: - Text

    private static let options: String.CompareOptions =
        [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// A window around the first match, rather than the head of the line.
    ///
    /// A note paragraph can run for hundreds of characters, and truncating it
    /// from the start is how a result list ends up showing three lines that do
    /// not contain the word you searched for.
    private var snippet: String {
        SearchHitRow.snippet(hit.text, tokens: tokens)
    }

    static func snippet(_ text: String, tokens: [String], limit: Int = 220) -> String {
        guard text.count > limit else { return text }

        let firstMatch = tokens
            .compactMap { text.range(of: $0, options: options)?.lowerBound }
            .min()

        guard let firstMatch else { return String(text.prefix(limit)) + "\u{2026}" }

        // A little run-up, so the match is not flush against the ellipsis.
        let lead = 48
        let startOffset = max(0, text.distance(from: text.startIndex, to: firstMatch) - lead)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex

        var out = String(text[start..<end])
        if startOffset > 0 { out = "\u{2026}" + out }
        if end < text.endIndex { out += "\u{2026}" }
        return out
    }

    /// Bolds and tints what matched.
    ///
    /// Matched on the *displayed* string rather than carried through from the
    /// index: ranges cannot survive folding intact, and this runs only for the
    /// handful of rows actually on screen.
    static func highlighted(_ text: String, tokens: [String]) -> AttributedString {
        var attributed = AttributedString(text)

        for token in tokens where !token.isEmpty {
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(of: token, options: options, range: cursor..<text.endIndex) {
                if let lower = AttributedString.Index(range.lowerBound, within: attributed),
                   let upper = AttributedString.Index(range.upperBound, within: attributed) {
                    attributed[lower..<upper].font = .system(size: 14, weight: .semibold)
                    attributed[lower..<upper].backgroundColor = Theme.system.opacity(0.22)
                }
                cursor = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            }
        }

        return attributed
    }
}
