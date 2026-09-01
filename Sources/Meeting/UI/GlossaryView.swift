import SwiftUI

/// The vocabulary that primes Whisper's decoder.
///
/// Worth surfacing rather than hiding in UserDefaults: these terms directly
/// change how the next recording is transcribed, so being able to see, add, and
/// remove them is the difference between a feature and a black box.
struct GlossaryView: View {
    @EnvironmentObject private var glossary: GlossaryStore
    @EnvironmentObject private var sessions: SessionStore

    @State private var newTerm = ""
    @State private var showingPrompt = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    learnedSection
                    builtinSection
                }
                .padding(20)
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.content)
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Glossary")
                    .font(Theme.Font.display)
                Text("Primes the transcriber, so these words come out spelled correctly.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Add a name, product, or bit of jargon…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    // MARK: - Sections

    private var learnedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LEARNED")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.mic)
                Text("\(glossary.learned.count)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !glossary.learned.isEmpty {
                    Button("Remove All", role: .destructive) { glossary.removeAllLearned() }
                        .controlSize(.small)
                }
            }

            if glossary.learned.isEmpty {
                Text("Nothing learned yet. Run **Extract Glossary Terms** on a recording and the names it finds appear here.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(glossary.learned) { term in
                        TermChip(
                            text: term.term,
                            color: Theme.mic,
                            subtitle: origin(of: term),
                            onRemove: { glossary.remove(term) }
                        )
                    }
                }
            }
        }
    }

    private var builtinSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BUILT-IN")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                Text("\(glossary.builtins.count)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Click to disable")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            FlowLayout(spacing: 7) {
                ForEach(glossary.builtins, id: \.self) { term in
                    let disabled = glossary.disabledBuiltins.contains(term.lowercased())
                    Button {
                        glossary.toggleBuiltin(term)
                    } label: {
                        Text(term)
                            .font(Theme.Font.caption)
                            .strikethrough(disabled)
                            .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background {
                                Capsule().fill(Color.primary.opacity(disabled ? 0.03 : 0.06))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Label("\(glossary.activeTerms.count) active", systemImage: "character.book.closed")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
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
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: - Helpers

    private func addTerm() {
        guard glossary.add(newTerm) else { return }
        newTerm = ""
    }

    private func origin(of term: LearnedTerm) -> String? {
        guard let sessionID = term.sessionID else { return "added by hand" }
        return sessions.sessions.first { $0.id == sessionID }?.title ?? "a recording"
    }
}

private struct TermChip: View {
    let text: String
    let color: Color
    let subtitle: String?
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background { Capsule().fill(color.opacity(0.14)) }
        .overlay { Capsule().stroke(color.opacity(0.25), lineWidth: 1) }
        .onHover { hovering = $0 }
        .help(subtitle.map { "From \($0)" } ?? text)
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
