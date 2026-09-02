import SwiftUI

/// The vocabulary that primes Whisper's decoder.
///
/// Worth surfacing rather than hiding in UserDefaults: these terms directly
/// change how the next recording is transcribed, so being able to see, add, and
/// remove them is the difference between a feature and a black box.
///
/// Two columns, because a term is two different things at once. The cloud on
/// the left is the vocabulary at a glance — dozens of short words, which a row
/// each would spread over a screen and a half. The pane on the right is one
/// term in depth: where it has been heard, how often, and since when. A chip
/// can hold a word and nothing else; the counts need somewhere to live.
struct GlossaryView: View {
    @EnvironmentObject private var glossary: GlossaryStore
    @EnvironmentObject private var sessions: SessionStore
    /// App-scoped, not view-scoped. The detail pane rebuilds this view every
    /// time you navigate back to it, so a `@StateObject` here meant the counts
    /// were thrown away and recomputed from zero on every visit — chips
    /// reordering under the cursor, figures blinking to "counting…". Held at
    /// app level the numbers are already there on arrival, and `refresh` just
    /// revalidates in the background.
    @EnvironmentObject private var index: GlossaryIndex

    /// Lets the inspector's recording list act as navigation, the way the
    /// library's cards do.
    var onOpenSession: (String) -> Void = { _ in }

    @State private var query = ""
    @State private var selectedKey: String?
    @State private var sort: Sort = .newest
    @State private var showingPrompt = false

    private enum Sort: String, CaseIterable, Identifiable {
        case newest, mentions, alphabetical
        var id: String { rawValue }

        var label: String {
            switch self {
            case .newest: "Newest"
            case .mentions: "Most heard"
            case .alphabetical: "A–Z"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            vocabulary
            Divider().opacity(0.5)
            inspector
                .frame(width: 300)
                // A hair off the page colour, so the split reads as two
                // surfaces without a heavy divider doing the work.
                .background(Color.primary.opacity(0.022))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 760, minHeight: 460)
        .background(Theme.content)
        .ignoresSafeArea(.container, edges: .top)
        .task { reindex() }
        .onChange(of: sessions.sessions) { _, _ in reindex() }
        .onChange(of: glossary.learned) { _, _ in reindex() }
    }

    // MARK: - Left column

    private var vocabulary: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if hasMatches {
                        learnedSection
                        builtinSection
                    } else {
                        noMatches
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 30)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Glossary")
                    .font(Theme.Font.display)
                Text("Primes the transcriber, so these words come out spelled correctly.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }

            // One field, two jobs. A separate search box and add box would sit
            // side by side asking the same question — "which word?" — and the
            // answer is a term you either already have or are about to.
            GlossaryField(text: $query, canAdd: canAdd, onSubmit: addTerm)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Sections

    private var learnedSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(title: "LEARNED", count: filteredLearned.count, tint: Theme.system) {
                if glossary.learned.count > 1 {
                    sortMenu
                }
                if !glossary.learned.isEmpty, query.isEmpty {
                    Button("Remove All", role: .destructive) {
                        glossary.removeAllLearned()
                        selectedKey = nil
                    }
                    .controlSize(.small)
                }
            }

            if filteredLearned.isEmpty {
                Text("Nothing learned yet. Run **Extract Glossary Terms** on a recording and the names it finds appear here.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 9) {
                    ForEach(filteredLearned) { term in
                        TermChip(
                            text: term.term,
                            mentions: index.stats(for: term.term).mentions,
                            isSelected: selectedKey == term.id,
                            select: { select(term.id) },
                            onRemove: { remove(term) }
                        )
                    }
                }
            }
        }
    }

    private var builtinSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            SectionHeader(title: "BUILT-IN", count: filteredBuiltins.count, tint: .secondary) {
                Text(enabledBuiltins == glossary.builtins.count
                     ? "All on"
                     : "\(enabledBuiltins) of \(glossary.builtins.count) on")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            FlowLayout(spacing: 9) {
                ForEach(filteredBuiltins, id: \.self) { term in
                    BuiltinChip(
                        text: term,
                        isOn: !glossary.disabledBuiltins.contains(term.lowercased()),
                        isSelected: selectedKey == term.lowercased(),
                        select: { select(term.lowercased()) },
                        toggle: { glossary.toggleBuiltin(term) }
                    )
                }
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(Sort.allCases) { option in
                Button {
                    sort = option
                } label: {
                    if sort == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Label(sort.label, systemImage: "arrow.up.arrow.down")
                .font(Theme.Font.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

    /// Shown instead of the sections, so a search that finds nothing does not
    /// leave two empty headings behind as the only thing on the page.
    private var noMatches: some View {
        EmptyState(
            systemImage: "magnifyingglass",
            title: "No terms match “\(trimmed)”",
            detail: canAdd ? "Press Return to add it to the glossary." : nil
        )
        .padding(.top, 50)
    }

    // MARK: - Right column

    @ViewBuilder
    private var inspector: some View {
        if let term = selectedLearned {
            GlossaryInspector(
                term: term.term,
                learned: term,
                origin: origin(of: term),
                stats: index.stats(for: term.term),
                isIndexing: index.isIndexing,
                isEnabled: nil,
                onToggle: {},
                onRemove: { remove(term) },
                onOpenSession: onOpenSession
            )
            .id(term.id)
        } else if let term = selectedBuiltin {
            GlossaryInspector(
                term: term,
                learned: nil,
                origin: nil,
                stats: index.stats(for: term),
                isIndexing: index.isIndexing,
                isEnabled: !glossary.disabledBuiltins.contains(term.lowercased()),
                onToggle: { glossary.toggleBuiltin(term) },
                onRemove: {},
                onOpenSession: onOpenSession
            )
            .id(term)
        } else {
            GlossarySummary(
                activeTerms: glossary.activeTerms.count,
                learnedTerms: glossary.learned.count,
                indexedMeetings: index.indexedMeetings,
                isIndexing: index.isIndexing,
                top: mostHeard
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Label("\(glossary.activeTerms.count) active", systemImage: "character.book.closed")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)

            if index.isIndexing {
                Text("· counting mentions…")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
            Button {
                showingPrompt.toggle()
            } label: {
                Label(showingPrompt ? "Hide prompt" : "Show prompt", systemImage: "text.quote")
                    .font(Theme.Font.caption)
            }
            .controlSize(.small)
            .popover(isPresented: $showingPrompt, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sent to Whisper before each chunk")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                    Text(glossary.promptPreview)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(width: 420)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        // Solid rather than a material: the house bars are opaque surfaces
        // (see FloatingChrome), and a translucent strip here picks up whatever
        // chip happens to scroll under it.
        .background(Theme.content)
    }

    // MARK: - Selection

    private var selectedLearned: LearnedTerm? {
        glossary.learned.first { $0.id == selectedKey }
    }

    private var selectedBuiltin: String? {
        glossary.builtins.first { $0.lowercased() == selectedKey }
    }

    private func select(_ key: String) {
        // Clicking the selected chip again clears it, which is the only way
        // back to the summary without a close button in the pane.
        selectedKey = selectedKey == key ? nil : key
    }

    private func remove(_ term: LearnedTerm) {
        if selectedKey == term.id { selectedKey = nil }
        glossary.remove(term)
    }

    // MARK: - Filtering

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredLearned: [LearnedTerm] {
        let ordered: [LearnedTerm]
        switch sort {
        case .newest:
            ordered = glossary.learned.sorted { $0.addedAt > $1.addedAt }
        case .mentions:
            ordered = glossary.learned.sorted {
                let left = index.stats(for: $0.term).mentions
                let right = index.stats(for: $1.term).mentions
                return left == right ? $0.term < $1.term : left > right
            }
        case .alphabetical:
            ordered = glossary.learned.sorted {
                $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending
            }
        }
        guard !trimmed.isEmpty else { return ordered }
        return ordered.filter { $0.term.localizedCaseInsensitiveContains(trimmed) }
    }

    private var filteredBuiltins: [String] {
        guard !trimmed.isEmpty else { return glossary.builtins }
        return glossary.builtins.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private var hasMatches: Bool {
        trimmed.isEmpty || !filteredLearned.isEmpty || !filteredBuiltins.isEmpty
    }

    private var enabledBuiltins: Int {
        glossary.builtins.count { !glossary.disabledBuiltins.contains($0.lowercased()) }
    }

    private var mostHeard: [(term: String, mentions: Int)] {
        glossary.activeTerms
            .map { (term: $0, mentions: index.stats(for: $0).mentions) }
            .filter { $0.mentions > 0 }
            .sorted { $0.mentions > $1.mentions }
            .prefix(4)
            .map { $0 }
    }

    /// Adding is only offered for a term that is not already somewhere in the
    /// glossary — otherwise Return silently no-ops on the store's duplicate
    /// check and the field looks broken.
    private var canAdd: Bool {
        guard trimmed.count >= 2 else { return false }
        let exists = glossary.learned.contains { $0.term.caseInsensitiveCompare(trimmed) == .orderedSame }
            || glossary.builtins.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        return !exists
    }

    // MARK: - Helpers

    private func reindex() {
        index.refresh(
            terms: glossary.learned.map(\.term) + glossary.builtins,
            sessions: sessions.sessions)
    }

    private func addTerm() {
        guard canAdd, glossary.add(trimmed) else { return }
        selectedKey = trimmed.lowercased()
        query = ""
    }

    private func origin(of term: LearnedTerm) -> String? {
        guard let sessionID = term.sessionID else { return "added by hand" }
        return sessions.sessions.first { $0.id == sessionID }?.displayTitle ?? "a recording"
    }
}

// MARK: - Field

/// The search-and-add field.
///
/// Built by hand rather than with `.roundedBorder`, which is the bezel AppKit
/// gives a form row: heavy, grey, and the one control on the page that looks
/// like it came from a different decade.
private struct GlossaryField: View {
    @Binding var text: String
    let canAdd: Bool
    let onSubmit: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)

                TextField("Filter, or add a name, product, or bit of jargon…", text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body)
                    .focused($focused)
                    .onSubmit(onSubmit)

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(Color.primary.opacity(0.05))
            }
            .overlay {
                // The focus ring the app disables globally, drawn back on the
                // one control that genuinely needs to show where typing goes.
                Capsule().stroke(
                    focused ? Theme.system.opacity(0.55) : Color.primary.opacity(0.08),
                    lineWidth: 1)
            }
            .animation(.smooth(duration: 0.12), value: focused)

            Button("Add", action: onSubmit)
                .disabled(!canAdd)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

// MARK: - Section header

private struct SectionHeader<Accessory: View>: View {
    let title: String
    let count: Int
    let tint: Color
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(Theme.Font.label)
                .foregroundStyle(tint)
            Text("\(count)")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background { Capsule().fill(Color.primary.opacity(0.06)) }
            Spacer()
            accessory
        }
    }
}

// MARK: - Chips

/// A learned term: filled, countable, removable.
///
/// Filled where a built-in is outlined, because that is the difference that
/// matters here — one is yours and removable, the other ships with the app. The
/// dot carries no track meaning; `Theme.mic` used to tint these chips, which
/// reads as "the mic said this" everywhere else in the app.
private struct TermChip: View {
    let text: String
    let mentions: Int
    let isSelected: Bool
    let select: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.system.opacity(mentions > 0 ? 0.75 : 0.25))
                    .frame(width: 5, height: 5)

                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                if mentions > 0 {
                    Text("\(mentions)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                // Always present, only visible on hover. Revealing it by
                // inserting it grows the chip under the pointer and reflows
                // every chip after it — the cloud rearranges itself as the
                // mouse crosses it.
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .padding(.vertical, 6)
            .background {
                Capsule().fill(isSelected
                               ? Theme.system.opacity(0.16)
                               : Color.primary.opacity(hovering ? 0.09 : 0.06))
            }
            .overlay {
                Capsule().stroke(
                    isSelected ? Theme.system.opacity(0.55) : Color.primary.opacity(0.08),
                    lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.12), value: hovering)
        .animation(.smooth(duration: 0.12), value: isSelected)
        .contextMenu {
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

/// A built-in term: outlined, toggled from the inspector or its context menu.
private struct BuiltinChip: View {
    let text: String
    let isOn: Bool
    let isSelected: Bool
    let select: () -> Void
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            Text(text)
                .font(.system(size: 12, weight: .regular))
                .strikethrough(!isOn, color: .secondary)
                .foregroundStyle(isOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    Capsule().fill(isSelected
                                   ? Theme.system.opacity(0.12)
                                   : Color.primary.opacity(hovering ? 0.05 : 0))
                }
                .overlay {
                    Capsule().stroke(
                        isSelected ? Theme.system.opacity(0.5) : Color.primary.opacity(isOn ? 0.14 : 0.07),
                        style: StrokeStyle(lineWidth: 1, dash: isOn ? [] : [3, 3]))
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.12), value: hovering)
        .animation(.smooth(duration: 0.12), value: isSelected)
        .contextMenu {
            Button(isOn ? "Disable" : "Enable", action: toggle)
        }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
