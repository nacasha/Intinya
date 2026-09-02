import SwiftUI

/// Playback view for a past recording: transport, scrubber, and a transcript
/// that highlights the line currently playing and seeks when you click one.
struct SessionDetailView: View {
    /// Which half of the recording the document is showing.
    ///
    /// A switch rather than a disclosure: notes and transcript are two views of
    /// the same session, not a section of one. Stacking them meant the summary
    /// — which is what the AI writes and what you most often want first — sat
    /// behind a click above the thing it summarises.
    private enum Pane: String, Hashable {
        case transcript
        case notes
        case terms
        case screen
    }

    let session: Session

    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var glossary: GlossaryStore
    @StateObject private var player = SessionPlayer()
    /// Supplied by `ActivityCenter`, not created here — work has to outlive this
    /// view so navigating away does not cancel it.
    @ObservedObject var ai: AIActionRunner
    @ObservedObject var enhancer: SessionEnhancer
    /// Asks the sidebar to delete this recording, which owns the confirmation.
    var onDelete: ((Session) -> Void)?
    @StateObject private var notes = NotesDocument()
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    @State private var segments: [TranscriptSegment] = []
    /// Longest line in the transcript, which bounds how far the active-line
    /// lookup has to walk back. Recomputed with the transcript, not per tick.
    @State private var longestSegment: TimeInterval = 0
    @State private var keyframes: [ScreenCapture.Keyframe] = []
    @State private var sections: [MeetingSection] = []
    /// Peak envelope behind the scrubber. Nil until it has been built, which is
    /// the first-visit case for sessions recorded before this existed.
    @State private var waveform: WaveformSummary?
    /// Whether the screen panel is raised out of the bottom bar.
    /// Persisted rather than held in `@State`.
    ///
    /// The detail view carries `.id(session.id)`, so moving between recordings
    /// destroys and rebuilds it and every `@State` goes back to its default.
    /// Which pane you are reading is a preference about how you work, not a
    /// fact about one recording, so it outlives both the view and the launch.
    @AppStorage("session.pane") private var paneRaw = Pane.transcript.rawValue

    private var pane: Pane { Pane(rawValue: paneRaw) ?? .transcript }

    /// The switch writes through to storage.
    private var paneBinding: Binding<Pane> {
        Binding(get: { pane }, set: { paneRaw = $0.rawValue })
    }
    /// Width of the detail pane, for capping the bottom bar.
    @State private var paneWidth: CGFloat = 0
    /// Whether the document's own title is still on screen. Drives the second
    /// header row, which stands in for it once it has scrolled away.
    @State private var isTitleOnScreen = true
    /// Height of the document's heading block, so the notes editor can claim
    /// exactly the rest of the pane.
    @State private var identityHeight: CGFloat = 0
    /// Glossary terms found in this transcript. Matched when either side
    /// changes, never during a render.
    @State private var termOccurrences: [TermsPane.Occurrence] = []
    @State private var scrubbing = false
    @State private var scrubValue: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            // Fixed: it is always there, so giving it its own space costs
            // nothing and keeps the document's first line predictable.
            compactHeader
                // Topmost, so a dropdown hanging out of the header is not
                // painted over by what comes after it in this stack.
                //
                // `zIndex` only orders siblings, and the menu's own reaches no
                // further than the header row it sits in. Both the divider and
                // the document are declared after the header here, so each
                // needs out-ranking: the document and its scrollbar covered the
                // panel, and the divider — at an equal rank, where source order
                // decides — drew its line straight across it.
                .zIndex(2)
            Divider().opacity(0.5)
                .zIndex(1)

            // The bands that come and go float over the document instead. They
            // appear mid-scroll, and a row that pushes the whole page down as
            // it arrives moves the text you are reading out from under you.
            document
                .bottomFade(height: Theme.barClearance)
                .overlay(alignment: .bottom) { transport }
                .overlay(alignment: .top) { floatingBands }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 420)
        .animation(.smooth(duration: 0.22), value: isTitleOnScreen)
        .animation(.smooth(duration: 0.2), value: enhancer.isRunning)
        .animation(.smooth(duration: 0.2), value: ai.isRunning)
        .background(Theme.content)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { paneWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in paneWidth = width }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { load() }
        .onChange(of: session.id) { _, _ in load() }
        .onChange(of: ai.completions) { _, _ in
            load()
            notes.reload()
            sessions.refresh()
        }
        .onChange(of: enhancer.completions) { _, _ in
            load()
            sessions.refresh()
        }
        // The other half of the input: learning a term should surface it here
        // without reloading the session.
        .onChange(of: glossary.activeTerms) { _, terms in
            termOccurrences = TermsPane.occurrences(in: segments, terms: terms)
        }
        .onDisappear { player.stop() }
    }

    /// The bands that appear over the top of the document.
    ///
    /// Opaque, because content passes underneath — the divider marks the edge
    /// and the surface has to actually hide what is behind it.
    private var floatingBands: some View {
        VStack(spacing: 0) {
            // A band of its own, below the actions' divider rather than inside
            // it. Sharing one rule made the header simply grow taller; its own
            // rule makes it read as a second row that arrived.
            //
            // Only once the document's title has gone. Two titles on screen at
            // once is what removing the header title avoided; this brings one
            // back exactly when the page can no longer speak for itself.
            if !isTitleOnScreen {
                stickyTitle
                Divider().opacity(0.5)
            }

            if hasStatus {
                statusStrip
                Divider().opacity(0.5)
            }
        }
        .background(Theme.content)
    }

    /// What is running, if anything, and how to stop it.
    ///
    /// Sits beside the pane switch rather than in a band of its own: a strip
    /// that appears while work runs and vanishes when it finishes is a row of
    /// header arriving and leaving under the one you are reading.
    private var workInProgress: (label: String, cancel: () -> Void)? {
        if enhancer.isRunning {
            let name = enhancer.runningModel?.displayName
            let percent = enhancer.progress.map { " \(Int($0 * 100))%" } ?? ""
            return ("\(name.map { "Transcribing with \($0)" } ?? "Transcribing")\(percent)", enhancer.cancel)
        }
        if let action = ai.running {
            let queued = ai.queued.isEmpty ? "" : " (\(ai.queued.count) more)"
            return ("\(action.title)…\(queued)", ai.cancel)
        }
        return nil
    }

    /// Stands in for the document's title once it has scrolled off.
    ///
    /// Deliberately in the header's own type, not the display face: it is a
    /// label telling you where you are, not the heading of the page — that role
    /// still belongs to the title in the document.
    private var stickyTitle: some View {
        Text(session.displayTitle)
            .font(Theme.Font.title)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            // Fades in place rather than sliding down from above. `.move(edge:
            // .top)` starts the row off-screen *upwards* — which here means it
            // animates in across the header it is supposed to sit under.
            .transition(.opacity)
    }

    /// Pane switch on the left, actions on the right.
    ///
    /// No title: the document carries it, in type that suits a heading, and
    /// repeating it in the bar above meant naming the same recording twice on
    /// one screen. What the header is for is choosing what to look at and what
    /// to do with it. Matches the recording screen, which made the same trade.
    private var compactHeader: some View {
        HStack(spacing: 10) {
            HeaderSwitch(
                options: [
                    .init(value: Pane.transcript, title: "Transcript", systemImage: "text.alignleft"),
                    .init(value: Pane.notes, title: "Notes", systemImage: "note.text"),
                    .init(value: Pane.terms, title: "Terms", systemImage: "character.book.closed"),
                    .init(value: Pane.screen, title: "Screen", systemImage: session.hasVideo ? "video" : "photo.stack"),
                ],
                selection: paneBinding
            )

            if let work = workInProgress {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.62)
                        // Scaling leaves the original footprint behind, so the
                        // spinner would otherwise reserve a control's worth of
                        // width and sit adrift from its label.
                        .frame(width: 12, height: 12)

                    Text(work.label)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button("Cancel", action: work.cancel)
                        .buttonStyle(.plain)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.system)
                }
                .transition(.opacity)
            }

            Spacer(minLength: 12)

            AIActionsMenu(session: session, runner: ai) {}
                .environmentObject(glossary)

            HeaderMenu(
                // Fixed, for the same reason as the AI button: the spinner
                // reports the state, the label reports what the button does.
                title: "Transcribe",
                systemImage: "waveform.badge.magnifyingglass",
                isBusy: enhancer.isRunning,
                isEnabled: !enhancer.isRunning,
                help: "Re-run transcription from the audio with a model you choose",
                items: downloadedModels.isEmpty
                    ? [.info("No models downloaded")]
                    : [.section("Improve rough lines")]
                        + downloadedModels.map { model in
                            .action(model.displayName, systemImage: "wand.and.sparkles") {
                                run(model, replacing: false)
                            }
                        }
                        + [.section("Re-transcribe everything")]
                        + downloadedModels.map { model in
                            .action(model.displayName, systemImage: "arrow.counterclockwise") {
                                run(model, replacing: true)
                            }
                        }
            )

            HeaderMenu(
                title: assignedType?.name ?? "No Template",
                systemImage: assignedType?.systemImage ?? "square.grid.2x2",
                help: "Decides how the AI summary is written",
                items: meetingTypes.types.map { type in
                    .action(type.name, systemImage: type.systemImage) {
                        SessionStore.setType(type.id, in: session.directory)
                        meetingTypes.noteUsed(type)
                        sessions.refresh()
                    }
                } + [
                    .separator,
                    .action("No Type", systemImage: "slash.circle") {
                        SessionStore.setType(nil, in: session.directory)
                        sessions.refresh()
                    },
                ]
            )

            // Copy, Reveal and Delete are one group: things you do *to* the
            // recording as a file, as opposed to things you do to its contents.
            // Three chips for that is more row than they earn.
            //
            // The first menu drawn by the app rather than by AppKit — see
            // `HeaderMenu`. The rest are still `NSMenu`, deliberately, so the
            // two can be compared side by side before the others follow.
            HeaderMenu(
                title: "More",
                systemImage: "ellipsis",
                help: "Copy, reveal, or delete this recording",
                items: [
                    .action("Copy Transcript", systemImage: "doc.on.doc", isEnabled: !segments.isEmpty) {
                        copyTranscript()
                    },
                    .action("Reveal in Finder", systemImage: "folder") {
                        sessions.reveal(session)
                    },
                    .separator,
                    .destructive("Delete Recording", systemImage: "trash") {
                        onDelete?(session)
                    },
                ]
            )
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.headerHeight)
    }

    /// Writes a note against one line.
    ///
    /// Patches the loaded copy rather than calling `load()`: a full reload
    /// rebuilds the waveform and throws away the document's scroll position,
    /// which is a lot to pay for one annotation.
    private func annotate(_ segment: TranscriptSegment, note: String?) {
        guard var transcript = SessionStore.loadTranscript(in: session.directory),
              let index = transcript.segments.firstIndex(where: { $0.id == segment.id })
        else { return }
        transcript.segments[index].note = note
        SessionStore.saveTranscript(transcript, in: session.directory)

        if let local = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[local].note = note
        }
    }

    // MARK: - Document

    /// The document: an identity block, then whichever pane is selected.
    ///
    /// Both panes share the title, so switching changes what you are reading
    /// about the session rather than which session you are looking at.
    private var document: some View {
        Group {
            switch pane {
            case .transcript: transcriptPane
            case .notes: notesPane
            case .terms: termsPane
            case .screen: screenPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var transcriptPane: some View {
        if segments.isEmpty {
            EmptyState(
                systemImage: "waveform.slash",
                title: "No transcript for this recording",
                detail: "Run Transcribe to produce one from the audio."
            )
        } else {
            transcriptDocument
        }
    }

    private var transcriptDocument: some View {
        ScrollViewReader { proxy in
            SlimScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    identity

                    TimelineTranscript(
                            segments: segments,
                            sections: sections,
                            keyframes: keyframes,
                            directory: session.directory,
                            activeID: activeSegmentID,
                            onSeek: { player.play(from: $0) },
                            onEdit: { updateSegment($0, text: $1) },
                            onNote: { annotate($0, note: $1) },
                            onAddSection: { addSection(at: $0) },
                            onRenameSection: { renameSection($0, to: $1) },
                            onDeleteSection: { deleteSection($0) }
                        )
                    .equatable()
                    .padding(.top, 28)
                }
                .measure()
                .padding(.bottom, Theme.barClearance)
            }
            .onChange(of: activeSegmentID) { _, id in
                guard let id else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// Same document as the transcript, with notes in place of the lines: one
    /// scroll view, one thumb, and a heading that travels with what it heads.
    private var notesPane: some View {
        GeometryReader { geometry in
            SlimScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    identity
                        .background {
                            GeometryReader { inner in
                                Color.clear
                                    .onAppear { identityHeight = inner.size.height }
                                    .onChange(of: inner.size.height) { _, height in
                                        identityHeight = height
                                    }
                            }
                        }

                    NotesView(
                        document: notes,
                        hasSession: true,
                        // Whatever the pane has left once the heading and the
                        // paddings have taken theirs, so the editor reaches the
                        // foot of the window and every empty inch of it is
                        // clickable.
                        minimumHeight: max(240, geometry.size.height - identityHeight - 52 - Theme.barClearance)
                    )
                    .padding(.top, 18)
                }
                .measure()
                .padding(.bottom, Theme.barClearance)
            }
        }
    }

    /// True while any part of the title is still below the top of the viewport.
    private func report(_ geometry: GeometryProxy) {
        // The document's own top. The band that replaces the title floats, so
        // it changes no layout and cannot feed its answer back into this.
        let onScreen = geometry.frame(in: .named(ScrollSpace.document)).maxY > 0
        if onScreen != isTitleOnScreen { isTitleOnScreen = onScreen }
    }

    @ViewBuilder
    private var termsPane: some View {
        if segments.isEmpty {
            EmptyState(
                systemImage: "character.book.closed",
                title: "No transcript",
                detail: "Terms are found in what was said."
            )
        } else if termOccurrences.isEmpty {
            EmptyState(
                systemImage: "character.book.closed",
                title: "No glossary terms here",
                detail: "Terms are learned by the AI’s Extract Terms action, and can be added by hand in Glossary."
            )
        } else {
            termsDocument
        }
    }

    private var termsDocument: some View {
        SlimScrollView {
            VStack(alignment: .leading, spacing: 0) {
                identity
                TermsPane(
                    occurrences: termOccurrences,
                    onSeek: { player.play(from: $0) }
                )
                .padding(.top, 20)
            }
            .measure()
            .padding(.bottom, Theme.barClearance)
        }
    }

    /// The screen, at the size it deserves.
    ///
    /// It was a panel raised out of the bottom bar, which meant a recording's
    /// video played in a 300pt slab over its own transcript. As a pane it gets
    /// the window, and the transcript rides along as a subtitle — so watching
    /// and reading are the same activity rather than two panes competing.
    ///
    /// No `.measure()`: a column sized for prose is the wrong shape for a
    /// screen recording, which wants every pixel it can have.
    @ViewBuilder
    private var screenPane: some View {
        if !hasScreen {
            EmptyState(
                systemImage: "rectangle.slash",
                title: "No screen capture",
                detail: "This recording was made without capturing the screen."
            )
        } else {
            screenPlayer
        }
    }

    private var screenPlayer: some View {
        ScreenPlaybackView(
            directory: session.directory,
            keyframes: keyframes,
            hasVideo: session.hasVideo,
            currentFile: currentKeyframeFile,
            videoPlayer: player.videoPlayer,
            subtitle: activeSegment?.text
        )
        .equatable()
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, Theme.barClearance)
    }

    /// What the document is: date, size, title, and the model behind it.
    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(metaLine)
                .font(Theme.Font.label)
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)

            Text(session.displayTitle)
                .font(Theme.Font.display)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { report(geometry) }
                            .onChange(of: geometry.frame(in: .named(ScrollSpace.document)).maxY) { _, _ in
                                report(geometry)
                            }
                    }
                }
        }
    }

    private var metaLine: String {
        var parts = [Session.dayLabel(for: session.day).uppercased()]
        if !segments.isEmpty { parts.append("\(segments.count) LINES") }
        if !keyframes.isEmpty { parts.append("\(keyframes.count) FRAMES") }
        if session.hasVideo { parts.append("VIDEO") }
        return parts.joined(separator: "  ·  ")
    }

    /// Half the pane, with a floor so the controls are never crushed into each
    /// other on a narrow window. Nil until the pane has been measured, which
    /// leaves the bar unconstrained for one layout pass rather than collapsing.
    private var barWidth: CGFloat? {
        guard paneWidth > 0 else { return nil }
        return max(520, paneWidth * 0.5)
    }

    /// Whether this recording captured anything from the screen.
    private var hasScreen: Bool {
        session.hasVideo || !keyframes.isEmpty
    }

    private var screenBadge: String? {
        if session.hasVideo { return "video" }
        if !keyframes.isEmpty { return "\(keyframes.count) frames" }
        return "none"
    }

    private func load() {
        let transcript = SessionStore.loadTranscript(in: session.directory)
        segments = (transcript?.segments ?? []).sorted { $0.start < $1.start }
        longestSegment = segments.map(\.duration).max() ?? 0
        keyframes = (transcript?.keyframes ?? []).sorted { $0.time < $1.time }
        sections = (transcript?.sections ?? []).chronological
        notes.load(session.directory)
        player.load(session)
        loadWaveform()
        termOccurrences = TermsPane.occurrences(in: segments, terms: glossary.activeTerms)
        // A session with no screen has no pane worth showing, so do not strand
        // the switch on an empty one after navigating.
        // A recording with no screen has no pane worth showing, so fall back
        // rather than stranding the switch on an empty one — the cost of
        // carrying the choice across recordings that do not all have the same
        // panes to offer.
        if !hasScreen, pane == .screen { paneRaw = Pane.transcript.rawValue }
    }

    /// Cached summaries come back inline; anything else is read off the main
    /// thread, since building one streams both WAVs end to end and would
    /// otherwise stall the window on opening a long recording.
    private func loadWaveform() {
        waveform = nil
        if let cached = WaveformSummary.cached(in: session.directory) {
            waveform = cached
            return
        }
        let directory = session.directory
        Task.detached(priority: .userInitiated) {
            let built = WaveformSummary.build(in: directory)
            await MainActor.run {
                // The session may have changed while this was running.
                guard directory == session.directory else { return }
                waveform = built
            }
        }
    }

    // MARK: - Header

    /// Transient state: playback errors, re-transcription progress, AI output.
    ///
    /// Split out of the old header, which carried all of this under a large
    /// title and a row of chips. The title now lives in the document and the
    /// chips in the overflow menu, but this still needs a place at the top of
    /// the pane — it is the pane talking about itself, not about the meeting.
    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = player.error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
            }

            if let enhanceError = enhancer.error {
                Text(enhanceError)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
                    .lineLimit(2)
            }

            if let aiError = ai.error {
                Text(aiError)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
                    .lineLimit(3)
                    .help(aiError)
            }

            if let answer = ai.panelAnswer {
                AIAnswerPanel(
                    title: ai.panelTitle,
                    answer: answer,
                    onSave: { ai.savePanelToNotes(session: session) },
                    onDismiss: { ai.dismissPanel() }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// Whether the strip has anything to say. Without this it contributes its
    /// padding to every session that is simply sitting there.
    private var hasStatus: Bool {
        player.error != nil
            || enhancer.error != nil
            || ai.error != nil
            || ai.panelAnswer != nil
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 14) {
            BarButton(
                systemImage: player.isPlaying ? "pause.fill" : "play.fill",
                tint: Theme.system,
                isProminent: player.isPlaying,
                isEnabled: player.duration > 0,
                tooltip: player.isPlaying ? "Pause" : "Play"
            ) {
                player.toggle()
            }
            .keyboardShortcut(.space, modifiers: [])

            Text(displayTime.clockString)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            // While dragging, the scrubber owns the value; on release it seeks
            // once, rather than scrubbing the engine on every pixel of movement.
            WaveformScrubber(
                summary: waveform,
                duration: player.duration,
                currentTime: displayTime,
                onScrub: { time in
                    scrubbing = true
                    scrubValue = time
                },
                onCommit: { time in
                    scrubbing = false
                    scrubValue = time
                    player.seek(to: time)
                }
            )
            .disabled(player.duration == 0)

            Text(player.duration.clockString)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .leading)
        }
        .floatingBar(maxWidth: barWidth)
    }

    private var displayTime: TimeInterval {
        scrubbing ? scrubValue : player.currentTime
    }

    // MARK: - Sections

    /// Models actually on disk. Offering one that would need a 600 MB download
    /// mid-task would be a poor surprise.
    private var downloadedModels: [WhisperModel] {
        WhisperModel.catalog.filter { models.isDownloaded($0) && $0.isRecommended }
    }

    private func run(_ model: WhisperModel, replacing: Bool) {
        enhancer.enhance(session: session, using: model, replacingExisting: replacing) {}
    }

    private var assignedType: MeetingType? {
        meetingTypes.type(id: session.typeID)
    }

    /// The keyframe on screen at the playhead.
    ///
    /// Resolved here so the screen pane's inputs change only when the picture
    /// does, rather than on every playback tick.
    private var currentKeyframeFile: String? {
        guard !keyframes.isEmpty else { return nil }
        let time = player.currentTime + 0.01

        // Binary search, like the active line. A scan is cheap for the seventy
        // frames a slide deck produces and much less so for the thousands a
        // long screen recording does — and either way it runs on every tick.
        var low = 0
        var high = keyframes.count
        while low < high {
            let mid = (low + high) / 2
            if keyframes[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return keyframes[max(0, low - 1)].file
    }

    /// The line being spoken now.
    ///
    /// Resolved here rather than inside the transcript so that the transcript's
    /// inputs only change when the line does — playback time itself ticks 20x a
    /// second and would otherwise re-render every row that often.
    /// Binary search rather than a scan: this runs on every playback tick, and a
    /// linear pass over a long transcript 20 times a second is real work for an
    /// answer that changes once a sentence.
    private var activeSegmentID: TranscriptSegment.ID? { activeSegment?.id }

    /// The segment itself, so callers that need its text do not then search the
    /// array for it — the screen pane's subtitle was doing exactly that on every
    /// tick, an O(n) scan behind an O(log n) lookup.
    private var activeSegment: TranscriptSegment? {
        let time = player.currentTime
        guard !segments.isEmpty else { return nil }

        // Last index whose line has already started.
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }

        // Mic and system lines interleave and can overlap, so the match is not
        // always the newest one started. Walk back — but only as far as the
        // longest line, since nothing older can still be running.
        var index = low - 1
        while index >= 0, time - segments[index].start <= longestSegment {
            let segment = segments[index]
            if time < max(segment.end, segment.start + 0.3) { return segment }
            index -= 1
        }
        return nil
    }

    /// Re-reads before writing, since an AI action may have rewritten the
    /// transcript since this view loaded.
    private func updateSegment(_ segment: TranscriptSegment, text: String) {
        guard var transcript = SessionStore.loadTranscript(in: session.directory),
              let index = transcript.segments.firstIndex(where: { $0.id == segment.id })
        else { return }
        transcript.segments[index].text = text
        transcript.segments[index].tier = .polished
        SessionStore.saveTranscript(transcript, in: session.directory)
        load()
    }

    private func addSection(at time: TimeInterval) {
        sections.append(MeetingSection(title: "Section \(sections.count + 1)", start: time))
        sections = sections.chronological
        saveSections()
    }

    private func renameSection(_ section: MeetingSection, to title: String) {
        guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
        sections[index].title = title
        saveSections()
    }

    private func deleteSection(_ section: MeetingSection) {
        sections.removeAll { $0.id == section.id }
        saveSections()
    }

    /// Re-reads before writing: an AI action may have rewritten the transcript
    /// since this view loaded, and sections must not clobber that.
    private func saveSections() {
        guard var transcript = SessionStore.loadTranscript(in: session.directory) else { return }
        transcript.sections = sections.isEmpty ? nil : sections
        SessionStore.saveTranscript(transcript, in: session.directory)
        sessions.refresh()
    }

    private func copyTranscript() {
        let text = sessions.exportText(session)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

