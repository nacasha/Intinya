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
    /// Room to leave at the foot for a bar floating over the feed.
    ///
    /// Not in `==`: it is fixed by the caller and never changes, so comparing
    /// it would only cost a field.
    var bottomClearance: CGFloat = 0

    static func == (lhs: TranscriptView, rhs: TranscriptView) -> Bool {
        lhs.activeID == rhs.activeID
            && lhs.isRecording == rhs.isRecording
            && lhs.isPlaying == rhs.isPlaying
            && lhs.pending == rhs.pending
            && lhs.sections == rhs.sections
            && lhs.segments == rhs.segments
    }

    /// Sections keyed by the line they precede, built once per change instead of
    /// searched per row. The previous per-row lookup was O(n) inside an O(n)
    /// loop, so a long transcript cost O(n^2) on every single render.
    @State private var sectionMap: [TranscriptSegment.ID: [MeetingSection]] = [:]

    /// Whether to jump to the newest line as it arrives.
    ///
    /// A switch you set, rather than something inferred from where the transcript
    /// is scrolled. Inferring it meant guessing whether you had scrolled away on
    /// purpose or the text had simply grown underneath you, and those two look
    /// identical from the outside — so it would let go while you were following
    /// and hang on while you were trying to read.
    @AppStorage("transcript.autoScroll") private var autoScroll = true

    /// Whether any chunk is still decoding.
    private var hasPending: Bool {
        pending.values.contains { $0 > 0 }
    }

    var body: some View {
        if segments.isEmpty, !hasPending {
            EmptyState(
                systemImage: isRecording ? "waveform" : "text.bubble",
                title: isRecording ? "Listening…" : "Start recording to transcribe",
                detail: isRecording
                    ? "Text appears once the first sentence finishes."
                    : "Bahasa Indonesia, with English terms preserved."
            )
        } else {
            feed
        }
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(segments) { segment in
                        row(for: segment)
                    }

                    ForEach(AudioSource.allCases, id: \.self) { source in
                        ForEach(0..<(pending[source] ?? 0), id: \.self) { index in
                            GhostLine(source: source, seed: index)
                                .transition(.opacity)
                        }
                    }

                    // Where auto-scroll scrolls to.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .padding(.bottom, bottomClearance)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Keyed on count, not the array: animating on `segments` re-diffs
            // every row whenever any row changes, which gets expensive on a long
            // transcript while live text is still arriving.
            .animation(.smooth(duration: 0.28), value: segments.count)
            .animation(.smooth(duration: 0.2), value: pending)
            .onAppear { rebuildSectionMap() }
            .onChange(of: segments.count) { _, _ in
                rebuildSectionMap()
                follow(proxy)
            }
            // The decoding placeholders occupy space too, so they push the end of
            // the transcript down exactly as a finished line does.
            .onChange(of: pending) { _, _ in follow(proxy) }
            .onChange(of: sections) { _, _ in rebuildSectionMap() }
            .onChange(of: activeID) { _, id in
                guard isPlaying, let id else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Playback has its own scrolling, driven by the line being spoken, so
            // the toggle would have nothing to control there.
            .overlay(alignment: .bottomTrailing) {
                // Placeholders count as content: the first thing you see in a
                // new recording is a placeholder, and that is exactly when you
                // might want to turn following off.
                if !isPlaying, !segments.isEmpty || hasPending {
                    autoScrollToggle(proxy)
                }
            }
            .animation(.smooth(duration: 0.15), value: autoScroll)
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

    /// The floating switch. Tinted while following, plain while not, so its
    /// state reads without having to watch whether the transcript moves.
    private func autoScrollToggle(_ proxy: ScrollViewProxy) -> some View {
        Button {
            autoScroll.toggle()
            // Turning it on catches up immediately, rather than sitting still
            // until the next line happens to arrive.
            if autoScroll { scrollToBottom(proxy) }
        } label: {
            Label(
                autoScroll ? "Following" : "Follow",
                systemImage: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle"
            )
            .font(Theme.Font.caption)
            .foregroundStyle(autoScroll ? AnyShapeStyle(Theme.system) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
            .overlay(
                Capsule().stroke(
                    autoScroll ? Theme.system.opacity(0.35) : Color.primary.opacity(0.12),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .help(autoScroll
              ? "Following new lines — click to stop"
              : "Not following — click to jump to the newest line and keep up")
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard autoScroll, !isPlaying else { return }
        scrollToBottom(proxy)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // Next runloop pass. The line that triggered this has not been laid out
        // yet, so scrolling now targets the previous bottom and lands short —
        // the transcript creeps behind while text is still arriving.
        DispatchQueue.main.async {
            withAnimation(.smooth(duration: 0.3)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

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

            // Holds the gutter open so the text never runs under the controls.
            // Width only — the controls themselves are an overlay, see below.
            Color.clear
                .frame(width: Self.gutter, height: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        // An overlay rather than a column, so the row is sized by the timestamp
        // and the text alone and hovering cannot change its height.
        //
        // As a column this shifted every line below it. Reserving the same
        // height for both states was not enough: the stack is
        // `.firstTextBaseline`-aligned, an empty placeholder is aligned by its
        // bottom edge, and the controls are SF Symbols, which carry a real text
        // baseline. Two different baselines put the row's top edge in two
        // different places even at identical heights.
        // Top-aligned, not centred: a line that wraps to three rows would
        // otherwise float its controls down beside the middle of the paragraph,
        // where the baseline alignment used to keep them beside the first line.
        .overlay(alignment: .topTrailing) {
            // Still built only on hover: permanently mounting them at zero
            // opacity meant every line on screen carried four live buttons and
            // their help strings, for a control nobody is looking at.
            if isHovering && !isEditing {
                actions.padding(.trailing, 8)
            }
        }
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

/// A placeholder for a line still being transcribed.
///
/// Occupies the same two columns as a real line, so text lands exactly where the
/// eye is already resting rather than shifting when it arrives.
private struct GhostLine: View {
    let source: AudioSource
    /// Varies the bar widths so consecutive placeholders don't look identical.
    let seed: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.4

    /// Fractions of the text measure, deliberately uneven: equal bars read as a
    /// progress bar rather than as sentences waiting to appear.
    ///
    /// Relative rather than the fixed pixel widths this used to carry, which
    /// overhung a narrow window and looked stranded on a wide one.
    private var widths: [CGFloat] {
        [[0.92, 0.54], [0.71], [0.96, 0.78, 0.38], [0.61]][abs(seed) % 4]
    }

    /// Matches `SegmentRow`, so text lands exactly where the placeholder sat
    /// rather than shifting when it arrives.
    private static let timeColumn: CGFloat = 46
    private static let measure: CGFloat = 780

    var body: some View {
        bars
            .overlay { sweep }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
            .accessibilityLabel(source == .mic ? "Transcribing your side" : "Transcribing the meeting")
    }

    private var bars: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 26, height: 8)
                .frame(width: Self.timeColumn, alignment: .leading)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(widths.enumerated()), id: \.offset) { _, fraction in
                    Capsule()
                        .fill(.tertiary)
                        .frame(height: 9)
                        .frame(maxWidth: Self.measure * fraction, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// A band travelling left to right, masked to the bars.
    ///
    /// Built from `primary` rather than white so it reads the same in both
    /// appearances — a white sweep is invisible on a light background. It
    /// replaces a pulse of the whole row's opacity, which dimmed the timestamp
    /// column in step with the text and made the whole line look like it was
    /// fading out rather than loading.
    @ViewBuilder
    private var sweep: some View {
        if reduceMotion {
            EmptyView()
        } else {
            GeometryReader { geometry in
                LinearGradient(
                    colors: [.clear, Color.primary.opacity(0.13), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geometry.size.width * 0.4)
                .offset(x: phase * geometry.size.width)
            }
            .mask(bars)
            .allowsHitTesting(false)
        }
    }
}
