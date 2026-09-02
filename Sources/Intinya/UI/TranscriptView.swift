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
    /// Provisional text for the utterance still being spoken, per track.
    /// Shown dimmed in place of that track's placeholder until the real
    /// segment replaces it.
    var partials: [AudioSource: TranscriptSegment] = [:]
    /// Room to leave for the bar and the bands floating over the feed.
    ///
    /// Not in `==`: set by the caller from measured chrome, and a change there
    /// already re-renders this view through its other inputs.
    var bottomClearance: CGFloat = 0
    var topClearance: CGFloat = 0

    /// Room the follow toggle needs above the bar, and that the feed leaves
    /// below its last line so the two never overlap.
    private static let followReserve: CGFloat = 44

    static func == (lhs: TranscriptView, rhs: TranscriptView) -> Bool {
        lhs.activeID == rhs.activeID
            && lhs.isRecording == rhs.isRecording
            && lhs.isPlaying == rhs.isPlaying
            && lhs.pending == rhs.pending
            && lhs.partials == rhs.partials
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

    /// Whether any chunk is still decoding or previewing.
    private var hasPending: Bool {
        pending.values.contains { $0 > 0 } || !partials.isEmpty
    }

    var body: some View {
        if segments.isEmpty, !hasPending {
            EmptyState(
                systemImage: isRecording ? "waveform" : "text.bubble",
                title: isRecording ? "Listening…" : "Start recording to transcribe",
                detail: isRecording
                    ? "Words appear as you speak."
                    : "Bahasa Indonesia, with English terms preserved."
            )
        } else {
            feed
        }
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            // The same scroll view playback uses, so both screens get the
            // floating thumb instead of one system scroller and one custom one.
            SlimScrollView {
                // A plain stack, not a lazy one. `TimelineTranscript` is itself
                // a `LazyVStack`, and nesting two of them leaves the outer one
                // estimating the height of an inner one that has not built its
                // rows yet — which is what threw the scroll to the top and the
                // bottom as the feed grew. Laziness still comes from the inner
                // stack, where the rows actually are.
                VStack(alignment: .leading, spacing: 0) {
                    // The same rows playback draws: timeline rail, timestamp
                    // gutter, hover controls. The two screens showed the same
                    // transcript in two different shapes, which made moving
                    // between them feel like moving between two apps.
                    //
                    // What stays local to recording is everything about a feed
                    // in motion — following the newest line, the placeholders
                    // for what has not arrived, and the switch that governs it.
                    TimelineTranscript(
                        segments: segments,
                        sections: sections,
                        keyframes: [],
                        directory: URL(fileURLWithPath: "/"),
                        activeID: nil,
                        onSeek: onSeek.map { seek in { time in
                            if let match = segments.last(where: { $0.start <= time }) { seek(match) }
                        } },
                        onEdit: onEdit,
                        onAddSection: onAddSection,
                        onRenameSection: onRenameSection,
                        onDeleteSection: onDeleteSection
                    )
                    .equatable()

                    ForEach(AudioSource.allCases, id: \.self) { source in
                        // The preview *is* that track's placeholder, with the
                        // words so far in it; bars only show when there is
                        // decoding but no preview text yet.
                        if let partial = partials[source] {
                            PartialLine(segment: partial)
                                .transition(.opacity)
                        } else {
                            ForEach(0..<(pending[source] ?? 0), id: \.self) { index in
                                GhostLine(source: source, seed: index)
                                    .transition(.opacity)
                            }
                        }
                    }
                    // Placeholders fade where they stand.
                    //
                    // The fade was always there; what made one look like it
                    // slid away was the line arriving above it, whose insertion
                    // animated every placeholder downward at the same moment.
                    // Opting them out of that animation leaves the new line to
                    // animate in while the placeholder it replaces simply goes.
                    .animation(nil, value: segments.count)

                    // The clearance *is* the anchor, rather than a 1pt marker
                    // after it. Two reasons, both of which had this landing
                    // short of the bottom:
                    //
                    // Anything placed after the anchor — padding on the stack,
                    // or a spacer — is content the scroll never reaches, so the
                    // feed settles that far above the end.
                    //
                    // And a 1pt view is a poor target inside a `LazyVStack`,
                    // which only builds what is near the viewport: scrolling to
                    // something that thin, and not yet built, lands on an
                    // estimate. A block this tall is always resolved.
                    Color.clear
                        .frame(height: bottomClearance + Self.followReserve)
                        .id(Self.bottomAnchor)
                }
                // The same reading column playback uses, rather than the full
                // width of the pane — otherwise the two screens set the same
                // transcript to two different measures.
                .measure()
                .padding(.top, topClearance)
            }
            // Keyed on count, not the array: animating on `segments` re-diffs
            // every row whenever any row changes, which gets expensive on a long
            // transcript while live text is still arriving.
            .animation(.smooth(duration: 0.28), value: segments.count)
            .animation(.smooth(duration: 0.2), value: pending)
            .animation(.smooth(duration: 0.2), value: partials)
            .onAppear { rebuildSectionMap() }
            .onChange(of: segments.count) { _, _ in
                rebuildSectionMap()
                follow(proxy)
            }
            // The decoding placeholders occupy space too, so they push the end of
            // the transcript down exactly as a finished line does.
            .onChange(of: pending) { _, _ in follow(proxy) }
            .onChange(of: partials) { _, _ in follow(proxy) }
            .onChange(of: sections) { _, _ in rebuildSectionMap() }
            .onChange(of: activeID) { _, id in
                guard isPlaying, let id else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            // Playback has its own scrolling, driven by the line being spoken, so
            // the toggle would have nothing to control there.
            //
            // Centred above the bar rather than tucked into the corner: it is
            // about the feed as a whole, and the corner is where the scrollbar
            // and the last line's controls already are.
            .overlay(alignment: .bottom) {
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
        .padding(.bottom, bottomClearance)
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

/// The utterance still being spoken, decoded provisionally.
///
/// Same columns as `GhostLine` and `TimelineRow`, so when the real segment
/// replaces this the words stay where they were. Dimmed and cursor-tailed
/// because the tail is allowed to be wrong: it re-decodes every refresh and
/// firms up when the utterance closes.
private struct PartialLine: View {
    let segment: TranscriptSegment

    private static let gutter: CGFloat = 52
    private static let rail: CGFloat = 9

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(segment.start.clockString)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: Self.gutter, alignment: .leading)
                .padding(.top, 3)

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .frame(width: Self.rail)
                .padding(.horizontal, 14)

            (Text(segment.text).foregroundStyle(.secondary)
                + Text(" ▍").foregroundStyle(Theme.accent(for: segment.source).opacity(0.7)))
                .font(Theme.Font.body)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.bottom, 22)
        .accessibilityLabel(segment.source == .mic
            ? "Transcribing your side: \(segment.text)"
            : "Transcribing the meeting: \(segment.text)")
    }
}

/// A placeholder for a line still being transcribed.
///
/// Laid out on `TimelineRow`'s columns — same gutter, same rail, same text
/// origin — so the words land exactly where the eye is already resting instead
/// of shifting when they arrive.
private struct GhostLine: View {
    let source: AudioSource
    /// Varies the bar widths so consecutive placeholders don't look identical.
    let seed: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.4

    /// Fractions of the text measure, deliberately uneven: equal bars read as a
    /// progress bar rather than as sentences waiting to appear.
    private var widths: [CGFloat] {
        [[0.92, 0.54], [0.71], [0.96, 0.78, 0.38], [0.61]][abs(seed) % 4]
    }

    private static let gutter: CGFloat = 52
    private static let rail: CGFloat = 9
    private static let measure: CGFloat = 620

    var body: some View {
        bars
            .overlay { sweep }
            .padding(.bottom, 22)
            .accessibilityLabel(source == .mic ? "Transcribing your side" : "Transcribing the meeting")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.4
                }
            }
    }

    private var bars: some View {
        HStack(alignment: .top, spacing: 0) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 26, height: 8)
                .frame(width: Self.gutter, alignment: .leading)
                .padding(.top, 3)

            // The rail runs through the placeholder too, so the line does not
            // break where the transcript has not caught up yet.
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
                .frame(width: Self.rail)
                .padding(.horizontal, 14)

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
