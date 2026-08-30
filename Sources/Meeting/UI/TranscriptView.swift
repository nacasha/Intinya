import SwiftUI

/// The transcript feed. Mic and system are visually distinct so speaker
/// attribution reads at a glance.
struct TranscriptView: View, Equatable {
    let segments: [TranscriptSegment]
    let isRecording: Bool
    /// The line currently being spoken, resolved by the caller.
    ///
    /// Deliberately not the raw playback time: that changes 20x a second, and
    /// taking it here made the whole transcript re-render at that rate. An id
    /// changes only when the spoken line does.
    var activeID: TranscriptSegment.ID? = nil
    /// Whether playback is driving the view, which decides scroll behaviour.
    var isPlaying: Bool = false
    /// Plays from a line. Nil when there is nothing to play.
    var onSeek: ((TranscriptSegment) -> Void)? = nil
    /// Saves an edited line.
    var onEdit: ((TranscriptSegment, String) -> Void)? = nil

    var sections: [MeetingSection] = []
    var onAddSection: ((TimeInterval) -> Void)? = nil
    var onRenameSection: ((MeetingSection, String) -> Void)? = nil
    var onDeleteSection: ((MeetingSection) -> Void)? = nil

    /// Chunks still decoding, per track. Each becomes a placeholder chip.
    var pending: [AudioSource: Int] = [:]

    static func == (lhs: TranscriptView, rhs: TranscriptView) -> Bool {
        lhs.activeID == rhs.activeID
            && lhs.isRecording == rhs.isRecording
            && lhs.isPlaying == rhs.isPlaying
            && lhs.pending == rhs.pending
            && lhs.sections == rhs.sections
            && lhs.segments == rhs.segments
    }

    /// Width of the scrolling content, used to cap bubble width.
    @State private var contentWidth: CGFloat = 640
    /// Sections keyed by the line they precede, built once per change instead of
    /// searched per row. The previous per-row lookup was O(n) inside an O(n)
    /// loop, so a long transcript cost O(n^2) on every single render.
    @State private var sectionMap: [TranscriptSegment.ID: [MeetingSection]] = [:]
    /// Whether the newest line is on screen. Auto-scroll only happens when it is.
    @State private var isAtBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if segments.isEmpty {
                        EmptyTranscriptView(isRecording: isRecording)
                            .padding(.top, 60)
                    } else {
                        ForEach(segments) { segment in
                            row(for: segment)
                        }
                    }

                    ForEach(AudioSource.allCases, id: \.self) { source in
                        ForEach(0..<(pending[source] ?? 0), id: \.self) { index in
                            GhostLine(source: source, seed: index)
                                .transition(.opacity)
                        }
                    }

                    // Sentinel: visible only when the transcript is scrolled to
                    // the end, which is what "should we follow along?" means.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { contentWidth = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, width in contentWidth = width }
                    }
                }
            }
            // Keyed on count, not the array: animating on `segments` re-diffs
            // every row whenever any row changes, which gets expensive on a long
            // transcript while live text is still arriving.
            .animation(.smooth(duration: 0.28), value: segments.count)
            .animation(.smooth(duration: 0.2), value: pending)
            .onAppear { rebuildSectionMap() }
            .onChange(of: segments.count) { _, _ in
                rebuildSectionMap()
                // Follow new text only when already at the end. Yanking the view
                // back down while reading something earlier is the whole
                // complaint this guards against.
                guard !isPlaying, isAtBottom else { return }
                withAnimation(.smooth(duration: 0.35)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: sections) { _, _ in rebuildSectionMap() }
            .onChange(of: activeID) { _, id in
                guard isPlaying, let id else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom, !isPlaying, !segments.isEmpty {
                    Button {
                        withAnimation(.smooth(duration: 0.3)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(Theme.Font.caption)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(.regularMaterial))
                            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .animation(.smooth(duration: 0.15), value: isAtBottom)
        }
    }

    @ViewBuilder
    private func row(for segment: TranscriptSegment) -> some View {
        ForEach(sectionMap[segment.id] ?? []) { section in
            SectionHeader(
                section: section,
                onRename: onRenameSection.map { rename in { rename(section, $0) } },
                onDelete: onDeleteSection.map { delete in { delete(section) } }
            )
            .id(section.id)
        }

        SegmentRow(
            segment: segment,
            isActive: segment.id == activeID,
            onPlay: onSeek.map { seek in { seek(segment) } },
            onAddSection: onAddSection.map { add in { add(segment.start) } },
            onEdit: onEdit.map { edit in { edit(segment, $0) } }
        )
        .equatable()
        .id(segment.id)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)),
            removal: .opacity
        ))
    }

    private static let bottomAnchor = "transcript-bottom"

    /// One pass over both lists, assigning each section to the line it precedes.
    private func rebuildSectionMap() {
        guard !sections.isEmpty else {
            if !sectionMap.isEmpty { sectionMap = [:] }
            return
        }

        var map: [TranscriptSegment.ID: [MeetingSection]] = [:]
        let ordered = sections.chronological
        var cursor = 0

        for (index, segment) in segments.enumerated() {
            let lowerBound = index == 0 ? -Double.greatestFiniteMagnitude : segments[index - 1].start
            var attached: [MeetingSection] = []
            while cursor < ordered.count, ordered[cursor].start <= segment.start {
                if ordered[cursor].start > lowerBound { attached.append(ordered[cursor]) }
                cursor += 1
            }
            if !attached.isEmpty { map[segment.id] = attached }
        }
        sectionMap = map
    }

}

// MARK: - Row

/// One transcript line: timestamp, then text.
///
/// Both speakers share a single left-aligned column. Chat-style bubbles pushed
/// half the conversation to the right edge, which made a long meeting hard to
/// scan and wasted most of the width on an ultrawide display. Reading down one
/// column is what a transcript is for.
private struct SegmentRow: View, Equatable {
    let segment: TranscriptSegment
    var isActive: Bool = false
    var onPlay: (() -> Void)?
    var onAddSection: (() -> Void)?
    var onEdit: ((String) -> Void)?

    /// Closures cannot be compared, so they are matched on availability only.
    /// Each one captures nothing but `segment` and a parent callback that is
    /// fixed for the lifetime of the transcript, so equal inputs here really do
    /// mean an identical row. Without this, one new line while recording
    /// re-renders every line already on screen.
    static func == (lhs: SegmentRow, rhs: SegmentRow) -> Bool {
        lhs.segment == rhs.segment
            && lhs.isActive == rhs.isActive
            && (lhs.onPlay == nil) == (rhs.onPlay == nil)
            && (lhs.onAddSection == nil) == (rhs.onAddSection == nil)
            && (lhs.onEdit == nil) == (rhs.onEdit == nil)
    }

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""

    /// Fixed so every line's text starts at the same x, which is what makes a
    /// wrapped line hang under the text instead of under the timestamp.
    private static let timeColumn: CGFloat = 46
    private static let gutter: CGFloat = 92
    /// A readable measure. Full-window lines on a wide display are hard to
    /// track back to the start of the next one.
    private static let measure: CGFloat = 780

    private var isMic: Bool { segment.source == .mic }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(segment.start.clockString)
                .font(Theme.Font.caption)
                .monospacedDigit()
                .foregroundStyle(isActive ? AnyShapeStyle(Theme.system) : AnyShapeStyle(.tertiary))
                .frame(width: Self.timeColumn, alignment: .leading)

            if isEditing { editor } else { line }

            Spacer(minLength: 0)

            // Reserved width, so revealing the controls never reflows the text.
            //
            // Built only while hovering. Keeping them permanently mounted at
            // zero opacity meant every line on screen carried four live buttons
            // and their help strings — the cost of a control nobody is looking at.
            Group {
                if isHovering && !isEditing { actions }
            }
            .frame(width: Self.gutter, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        }
        .overlay(alignment: .leading) {
            // A slim bar rather than a border: it marks the active line without
            // boxing it in, which would reintroduce the chip look.
            if isActive {
                Capsule()
                    .fill(Theme.system)
                    .frame(width: 2)
                    .padding(.vertical, 2)
            }
        }
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.12), value: isHovering)
        .animation(.smooth(duration: 0.2), value: isActive)
    }

    private var rowFill: Color {
        if isActive { return Theme.system.opacity(0.12) }
        if isHovering { return Color.primary.opacity(0.04) }
        return .clear
    }

    private var line: some View {
        (speaker + Text(segment.text))
            .font(Theme.Font.body)
            .foregroundStyle(segment.tier == .live ? .secondary : .primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.measure, alignment: .leading)
    }

    /// Only the microphone track is labelled. Everything else is the meeting, and
    /// prefixing every other line would be noise.
    private var speaker: Text {
        isMic
            ? Text("You: ").foregroundColor(Theme.mic).fontWeight(.semibold)
            : Text("")
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(Theme.Font.body)
                .scrollContentBackground(.hidden)
                .frame(height: 80)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
        .frame(maxWidth: Self.measure, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            if let onPlay {
                ActionButton(icon: "play.fill", help: "Play from \(segment.start.clockString)", action: onPlay)
            }
            if let onAddSection {
                ActionButton(icon: "text.insert", help: "Start a section here", action: onAddSection)
            }
            if onEdit != nil {
                ActionButton(icon: "pencil", help: "Edit this line") {
                    draft = segment.text
                    isEditing = true
                }
            }
            ActionButton(icon: "doc.on.doc", help: "Copy this line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(segment.text, forType: .string)
            }
        }
    }
}

private struct ActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(Theme.system) : AnyShapeStyle(.secondary))
                .frame(width: 21, height: 21)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.10 : 0.04))
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Sections

private struct SectionHeader: View {
    let section: MeetingSection
    let onRename: ((String) -> Void)?
    let onDelete: (() -> Void)?

    @State private var isEditing = false
    @State private var draft = ""
    @State private var hovering = false

    /// Matches `SegmentRow`, so a section's own time sits in the same column as
    /// every transcript timestamp and its title starts where the text does.
    private static let timeColumn: CGFloat = 46

    var body: some View {
        Group {
            if isEditing { editingRow } else { displayRow }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .onHover { hovering = $0 }
    }

    private var displayRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(section.start.clockString)
                .font(Theme.Font.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.system.opacity(0.8))
                .frame(width: Self.timeColumn, alignment: .leading)

            Text(section.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.system)
                .lineLimit(1)

            if hovering {
                if onRename != nil {
                    ActionButton(icon: "pencil", help: "Rename section") {
                        draft = section.title
                        isEditing = true
                    }
                }
                if let onDelete {
                    ActionButton(icon: "trash", help: "Delete section", action: onDelete)
                }
            }

            // Fills whatever is left, so the rule always reaches the edge.
            Rectangle()
                .fill(Theme.system.opacity(0.22))
                .frame(height: 1)
        }
        // Fixed, so revealing the controls cannot shift the lines below.
        .frame(height: 22)
    }

    private var editingRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(section.start.clockString)
                .font(Theme.Font.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: Self.timeColumn, alignment: .leading)

            TextField("Section name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(commit)

            Button("Save", action: commit).controlSize(.small)
            Button("Cancel") { isEditing = false }.controlSize(.small)

            Spacer(minLength: 0)
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onRename?(trimmed) }
        isEditing = false
    }
}

private struct EmptyTranscriptView: View {
    let isRecording: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isRecording ? "waveform" : "text.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(isRecording ? "Listening…" : "Start recording to transcribe")
                .font(Theme.Font.title)
                .foregroundStyle(.secondary)
            Text(isRecording
                 ? "Text appears once the first sentence finishes."
                 : "Bahasa Indonesia, with English terms preserved.")
                .font(Theme.Font.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}


/// A placeholder for a line still being transcribed.
///
/// Occupies the same two columns as a real line, so text lands exactly where the
/// eye is already resting rather than shifting when it arrives.
private struct GhostLine: View {
    let source: AudioSource
    /// Varies the bar widths so consecutive placeholders don't look identical.
    let seed: Int

    @State private var pulsing = false

    /// Deliberately uneven — equal bars read as a progress bar, not as text.
    private var widths: [CGFloat] {
        [[320.0, 190], [240.0], [400.0, 260], [180.0]][abs(seed) % 4]
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(width: 30, height: 7)
                .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                    Capsule()
                        .fill(source == .mic
                              ? Theme.mic.opacity(0.16)
                              : Color.primary.opacity(0.11))
                        .frame(width: width, height: 9)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .opacity(pulsing ? 0.45 : 0.9)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityLabel("Transcribing")
    }
}
