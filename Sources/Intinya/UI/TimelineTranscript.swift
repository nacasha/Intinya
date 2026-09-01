import SwiftUI

/// The playback transcript, read as a document rather than a feed.
///
/// Separate from `TranscriptView` because the two jobs stopped being the same
/// one. Recording is a live feed: newest-last, auto-scrolling, placeholders for
/// what has not arrived. Playback is a finished document you read and annotate,
/// centred on a measure, with a timeline down the side and the screen shown
/// where it was captured. Sharing one view meant every change had to be checked
/// against a context it was not designed for.
///
/// Owns no scroll view of its own — it sits inside the document's, so the title
/// and notes scroll with the transcript instead of above a separate pane.
struct TimelineTranscript: View, Equatable {
    let segments: [TranscriptSegment]
    let sections: [MeetingSection]
    let keyframes: [ScreenCapture.Keyframe]
    let directory: URL
    /// The line being spoken, resolved by the caller so this does not re-render
    /// on every playback tick.
    let activeID: TranscriptSegment.ID?

    var onSeek: ((TimeInterval) -> Void)?
    var onEdit: ((TranscriptSegment, String) -> Void)?
    var onNote: ((TranscriptSegment, String?) -> Void)?

    static func == (lhs: TimelineTranscript, rhs: TimelineTranscript) -> Bool {
        lhs.activeID == rhs.activeID
            && lhs.segments == rhs.segments
            && lhs.sections == rhs.sections
            && lhs.keyframes == rhs.keyframes
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                ForEach(sectionsBefore(index)) { section in
                    TimelineSectionHeader(section: section)
                }

                TimelineRow(
                    segment: segment,
                    isActive: segment.id == activeID,
                    // The rail is drawn per row; the last one stops at its own
                    // text so the line does not dangle past the transcript.
                    isLast: index == segments.count - 1,
                    frames: frames(for: index),
                    directory: directory,
                    onSeek: onSeek,
                    onEdit: onEdit.map { edit in { edit(segment, $0) } },
                    onNote: onNote.map { note in { note(segment, $0) } }
                )
                .equatable()
                .id(segment.id)
            }
        }
    }

    /// Sections that fall between the previous line and this one.
    private func sectionsBefore(_ index: Int) -> [MeetingSection] {
        let lower = index == 0 ? -Double.greatestFiniteMagnitude : segments[index - 1].start
        let upper = segments[index].start
        return sections.chronological.filter { $0.start > lower && $0.start <= upper }
    }

    /// Frames captured while this line was being spoken.
    ///
    /// Grouped onto the line rather than placed by their own timestamps, so a
    /// slide lands beside the sentence said over it instead of splitting a
    /// paragraph at an arbitrary point.
    private func frames(for index: Int) -> [ScreenCapture.Keyframe] {
        guard !keyframes.isEmpty else { return [] }
        let start = segments[index].start
        let end = index == segments.count - 1
            ? Double.greatestFiniteMagnitude
            : segments[index + 1].start
        return keyframes.filter { $0.time >= start && $0.time < end }
    }
}

// MARK: - Row

private struct TimelineRow: View, Equatable {
    let segment: TranscriptSegment
    let isActive: Bool
    let isLast: Bool
    let frames: [ScreenCapture.Keyframe]
    let directory: URL
    var onSeek: ((TimeInterval) -> Void)?
    var onEdit: ((String) -> Void)?
    var onNote: ((String?) -> Void)?

    static func == (lhs: TimelineRow, rhs: TimelineRow) -> Bool {
        lhs.segment == rhs.segment
            && lhs.isActive == rhs.isActive
            && lhs.isLast == rhs.isLast
            && lhs.frames == rhs.frames
    }

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var isNoting = false
    @State private var draft = ""

    private static let gutter: CGFloat = 52
    private static let rail: CGFloat = 9
    /// Drops the dot onto the first line of text rather than the row's top edge.
    private static let dotOffset: CGFloat = 6

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { onSeek?(segment.start) } label: {
                Text(segment.start.clockString)
                    .font(Theme.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(isActive ? AnyShapeStyle(Theme.system) : AnyShapeStyle(.tertiary))
                    // Leading, so the timestamps begin on the same line as the
                    // title and the meta row above them. Trailing-aligned they
                    // ended at the gutter's right edge and started wherever
                    // their width happened to put them — never at the column's
                    // left edge, which is what left the transcript looking
                    // indented against the heading.
                    //
                    // Costs nothing: the digits are monospaced and every
                    // timestamp under an hour is the same width anyway.
                    .frame(width: Self.gutter, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            timeline
                .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 10) {
                if isEditing { editor } else { line }
                if let note = segment.note, !note.isEmpty, !isNoting { noteCard(note) }
                if isNoting { noteEditor }
                if !frames.isEmpty { KeyframeStrip(frames: frames, directory: directory, onSeek: onSeek) }
            }
            .padding(.bottom, 22)

            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) { if isHovering, !isEditing, !isNoting { actions } }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    /// The rail: a continuous line down the page with a dot on each line.
    private var timeline: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                // The last row's rail stops at its dot, so the line ends with
                // the transcript instead of trailing into the page.
                .frame(maxHeight: isLast ? Self.dotOffset + Self.rail / 2 : .infinity, alignment: .top)

            Circle()
                .fill(isActive ? AnyShapeStyle(Theme.system) : AnyShapeStyle(Color.primary.opacity(0.16)))
                .frame(width: isActive ? Self.rail : 6, height: isActive ? Self.rail : 6)
                .overlay {
                    if isActive {
                        Circle().stroke(Theme.content, lineWidth: 2).padding(-2)
                    }
                }
                .offset(y: Self.dotOffset)
                .animation(.smooth(duration: 0.2), value: isActive)
        }
        .frame(width: Self.rail)
    }

    private var line: some View {
        Text(segment.text)
            .font(Theme.Font.body)
            // One colour, whatever pass produced the line.
            //
            // Tier used to dim the rough ones. In a finished recording that is
            // noise: which lines the enhanced pass happened to reach is a fact
            // about the transcription run, not about the conversation, and it
            // left a page of text mottled for a reason no reader can act on.
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(3)
    }

    /// The annotation. Warm, because it is the one thing on the page that came
    /// from you rather than from the recording.
    private func noteCard(_ note: String) -> some View {
        Text(note)
            .font(Theme.Font.caption)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.mic.opacity(0.14))
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.mic.opacity(0.55)).frame(width: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onTapGesture {
                draft = note
                isNoting = true
            }
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(Theme.Font.caption)
                .scrollContentBackground(.hidden)
                .frame(height: 58)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.mic.opacity(0.10))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.mic.opacity(0.45), lineWidth: 1)
                }

            HStack(spacing: 6) {
                Button("Cancel") { isNoting = false }.controlSize(.small)
                if segment.note?.isEmpty == false {
                    Button("Remove") {
                        onNote?(nil)
                        isNoting = false
                    }
                    .controlSize(.small)
                }
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    onNote?(trimmed.isEmpty ? nil : trimmed)
                    isNoting = false
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(Theme.Font.body)
                .scrollContentBackground(.hidden)
                .frame(height: 80)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.system.opacity(0.4), lineWidth: 1)
                }

            HStack(spacing: 6) {
                Button("Cancel") { isEditing = false }.controlSize(.small)
                Button("Save") {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, trimmed != segment.text { onEdit?(trimmed) }
                    isEditing = false
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if onSeek != nil {
                RowAction(icon: "play.fill", help: "Play from \(segment.start.clockString)") {
                    onSeek?(segment.start)
                }
            }
            if onNote != nil {
                RowAction(icon: "note.text", help: segment.note == nil ? "Add a note" : "Edit the note") {
                    draft = segment.note ?? ""
                    isNoting = true
                }
            }
            if onEdit != nil {
                RowAction(icon: "pencil", help: "Edit this line") {
                    draft = segment.text
                    isEditing = true
                }
            }
            RowAction(icon: "doc.on.doc", help: "Copy this line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }
        }
        .padding(4)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct RowAction: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(Theme.system) : AnyShapeStyle(.secondary))
                .frame(width: 22, height: 22)
                .background {
                    Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0))
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tooltip(help, isHovering: hovering)
    }
}

// MARK: - Screen

/// Frames captured over one line, shown where they happened.
private struct KeyframeStrip: View {
    let frames: [ScreenCapture.Keyframe]
    let directory: URL
    var onSeek: ((TimeInterval) -> Void)?

    @State private var index = 0

    private var frame: ScreenCapture.Keyframe? {
        frames.indices.contains(index) ? frames[index] : frames.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let frame, let image = KeyframeCache.image(directory: directory, file: frame.file) {
                Button { onSeek?(frame.time) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 420, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }

            // Only when there is more than one: a lone frame needs no paging.
            if frames.count > 1 {
                HStack(spacing: 8) {
                    Button { index = max(0, index - 1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0)

                    Text("\(index + 1) of \(frames.count)")
                        .font(Theme.Font.label)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    Button { index = min(frames.count - 1, index + 1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .disabled(index == frames.count - 1)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sections

private struct TimelineSectionHeader: View {
    let section: MeetingSection

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(section.start.clockString)
                .font(Theme.Font.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.system.opacity(0.8))
                .frame(width: 52, alignment: .leading)

            Color.clear.frame(width: 9).padding(.horizontal, 14)

            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.system)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 14)
    }
}
