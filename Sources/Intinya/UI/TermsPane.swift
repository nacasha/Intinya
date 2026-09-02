import SwiftUI

/// Glossary terms as they actually appear in one recording.
///
/// The glossary is otherwise write-only from a session's point of view: terms
/// are learned from a meeting and fed back into the next transcription, but
/// there is nowhere to see which of them this recording is the source of, or
/// where in it they were said. This is that read side.
struct TermsPane: View {
    /// Matched once by the caller and held, not recomputed here.
    ///
    /// `body` runs on every playback tick. Scanning the glossary against the
    /// transcript from inside it meant thousands of regex matches twenty times
    /// a second, for an answer that only changes when the transcript or the
    /// glossary does.
    let occurrences: [Occurrence]
    var onSeek: ((TimeInterval) -> Void)?

    /// A term and every line that says it.
    struct Occurrence: Identifiable {
        let term: String
        let hits: [TranscriptSegment]
        var id: String { term.lowercased() }
        var count: Int { hits.count }
    }

    /// Terms present in this transcript, most-said first.
    ///
    /// Matched case-insensitively on word boundaries, so "AI" does not also
    /// match "said" and "Rust" does not match "trusted". Scanning the whole
    /// glossary against the whole transcript is O(terms × lines), which is
    /// nothing at these sizes and happens once per visit.
    static func occurrences(in segments: [TranscriptSegment], terms: [String]) -> [Occurrence] {
        terms.compactMap { term in
            let pattern = "(?i)\\b\(NSRegularExpression.escapedPattern(for: term))\\b"
            let hits = segments.filter { $0.text.range(of: pattern, options: .regularExpression) != nil }
            guard !hits.isEmpty else { return nil }
            return Occurrence(term: term, hits: hits)
        }
        .sorted { $0.count == $1.count ? $0.term < $1.term : $0.count > $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(occurrences) { occurrence in
                row(occurrence)
            }
        }
    }

    private func row(_ occurrence: Occurrence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(occurrence.term)
                    .font(.system(size: 15, weight: .semibold))

                Text("\(occurrence.count)")
                    .font(Theme.Font.label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))

                Spacer(minLength: 0)
            }

            // Every mention, not just the first: a term's meaning in a meeting
            // is usually the sentence around it, and which sentence matters.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(occurrence.hits) { hit in
                    Button { onSeek?(hit.start) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Text(hit.start.clockString)
                                .font(Theme.Font.caption)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .frame(width: 46, alignment: .leading)

                            Text(hit.text)
                                .font(Theme.Font.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.5)
        }
    }
}
