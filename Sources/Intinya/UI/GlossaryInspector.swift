import SwiftUI

/// The right-hand pane of the glossary: everything known about one term.
///
/// A chip can hold a word and nothing else, which is what made the screen read
/// as thin. The counts live here instead, where there is room to give them a
/// size worth reading.
struct GlossaryInspector: View {
    let term: String
    /// Absent for a built-in, which has no provenance to show.
    let learned: LearnedTerm?
    let origin: String?
    let stats: TermStats
    let isIndexing: Bool
    /// Built-ins only: nil hides the enable switch.
    let isEnabled: Bool?
    let onToggle: () -> Void
    let onRemove: () -> Void
    let onOpenSession: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                identity
                figures
                facts
                if !stats.appearances.isEmpty { appearances }
                Spacer(minLength: 0)
                actions
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(term)
                .font(.system(size: 18, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Text(learned == nil ? "Built-in term" : (origin.map { "From \($0)" } ?? "Learned term"))
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Figures

    @ViewBuilder
    private var figures: some View {
        if isIndexing && stats.mentions == 0 {
            Figure(value: "—", label: "counting…", tint: .secondary)
        } else if stats.isUnseen {
            VStack(alignment: .leading, spacing: 8) {
                Figure(value: "0", label: "mentions", tint: .secondary)
                // Said plainly, because the obvious reading — "this term is
                // dead weight" — is usually wrong. A term is often added
                // precisely because the transcriber kept mishearing it.
                Text("Not seen in a transcript yet. It still primes the next recording.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .top, spacing: 22) {
                Figure(value: "\(stats.mentions)", label: "mentions", tint: Theme.system)
                Figure(value: "\(stats.meetings)", label: stats.meetings == 1 ? "meeting" : "meetings", tint: .primary)
            }
        }
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(spacing: 0) {
            if let first = stats.first {
                Fact(label: "First heard", value: Self.day.string(from: first.recordedAt))
            }
            if let last = stats.last, stats.meetings > 1 {
                Fact(label: "Last heard", value: Self.day.string(from: last.recordedAt))
            }
            if let learned {
                Fact(label: "Added", value: learned.addedAt == .distantPast
                     ? "—"
                     : Self.day.string(from: learned.addedAt))
            }
        }
    }

    // MARK: - Appearances

    private var appearances: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPEARS IN")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)

            VStack(spacing: 2) {
                ForEach(stats.appearances) { appearance in
                    AppearanceRow(appearance: appearance) {
                        onOpenSession(appearance.sessionID)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.5)

            if let isEnabled {
                Toggle(isOn: Binding(get: { isEnabled }, set: { _ in onToggle() })) {
                    Text("Use when transcribing")
                        .font(Theme.Font.body)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            } else {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove term", systemImage: "trash")
                        .font(Theme.Font.caption)
                }
                .controlSize(.small)
            }
        }
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}

// MARK: - Pieces

/// One number, at a size that makes it the thing you look at first.
private struct Figure: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(Theme.Font.body)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }
}

private struct AppearanceRow: View {
    let appearance: TermAppearance
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(appearance.title)
                    .font(Theme.Font.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(appearance.count)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.06 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open “\(appearance.title)”")
    }
}

/// What the pane shows with nothing selected: the shape of the glossary as a
/// whole, rather than an empty column.
struct GlossarySummary: View {
    let activeTerms: Int
    let learnedTerms: Int
    let indexedMeetings: Int
    let isIndexing: Bool
    let top: [(term: String, mentions: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Vocabulary")
                    .font(.system(size: 18, weight: .semibold))
                Text(isIndexing
                     ? "Counting mentions…"
                     : "Across \(indexedMeetings) transcribed \(indexedMeetings == 1 ? "recording" : "recordings").")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 22) {
                Figure(value: "\(activeTerms)", label: "active", tint: Theme.system)
                Figure(value: "\(learnedTerms)", label: "learned", tint: .primary)
            }

            if !top.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MOST HEARD")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 0) {
                        ForEach(top, id: \.term) { entry in
                            Fact(label: entry.term, value: "\(entry.mentions)")
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text("Select a term to see where it has been heard.")
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
