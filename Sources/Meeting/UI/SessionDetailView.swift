import SwiftUI

/// Playback view for a past recording: transport, scrubber, and a transcript
/// that highlights the line currently playing and seeks when you click one.
struct SessionDetailView: View {
    let session: Session

    @EnvironmentObject private var sessions: SessionStore
    @EnvironmentObject private var glossary: GlossaryStore
    @StateObject private var player = SessionPlayer()
    /// Supplied by `ActivityCenter`, not created here — work has to outlive this
    /// view so navigating away does not cancel it.
    @ObservedObject var ai: AIActionRunner
    @ObservedObject var enhancer: SessionEnhancer
    @StateObject private var notes = NotesDocument()
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    @State private var segments: [TranscriptSegment] = []
    /// Longest line in the transcript, which bounds how far the active-line
    /// lookup has to walk back. Recomputed with the transcript, not per tick.
    @State private var longestSegment: TimeInterval = 0
    @State private var keyframes: [ScreenCapture.Keyframe] = []
    @State private var sections: [MeetingSection] = []
    /// Resolved when the session loads.
    ///
    /// This used to be a computed property that read and parsed transcript.json
    /// — inside `body`, which runs on every playback tick. A disk read and a
    /// JSON parse twenty times a second is not something a label should cost.
    @State private var transcribedWith: String?
    @State private var scrubbing = false
    @State private var scrubValue: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            AccordionStack(panels: panels, storageKey: "session")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.5)
            transport
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 420)
        .background(.ultraThinMaterial)
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
        .onDisappear { player.stop() }
    }

    /// Notes on top, transcript in the middle, screen at the bottom.
    private var panels: [AccordionPanel] {
        [
            AccordionPanel(
                id: "notes",
                title: "Notes",
                systemImage: "note.text",
                badge: notes.savedLabel,
                accent: .orange
            ) {
                NotesView(document: notes, hasSession: true)
            },

            AccordionPanel(
                id: "transcript",
                title: "Transcript",
                systemImage: "text.bubble",
                badge: transcriptBadge,
                accent: Theme.mic
            ) {
                if segments.isEmpty {
                    noTranscript
                } else {
                    TranscriptView(
                        segments: segments,
                        isRecording: false,
                        activeID: activeSegmentID,
                        isPlaying: true,
                        onSeek: { player.play(from: $0.start) },
                        onEdit: { updateSegment($0, text: $1) },
                        sections: sections,
                        onAddSection: { addSection(at: $0) },
                        onRenameSection: { renameSection($0, to: $1) },
                        onDeleteSection: { deleteSection($0) }
                    )
                    .equatable()
                }
            },

            AccordionPanel(
                id: "screen",
                title: "Screen",
                systemImage: session.hasVideo ? "video" : "photo.stack",
                badge: screenBadge,
                accent: Theme.system
            ) {
                ScreenPlaybackView(
                    directory: session.directory,
                    keyframes: keyframes,
                    hasVideo: session.hasVideo,
                    currentFile: currentKeyframeFile,
                    videoPlayer: player.videoPlayer,
                    onSeek: { player.play(from: $0) }
                )
                .equatable()
            },
        ]
    }

    private var transcriptBadge: String? {
        guard !segments.isEmpty else { return "none" }
        var parts = ["\(segments.count) lines"]
        if !sections.isEmpty { parts.append("\(sections.count) sections") }
        return parts.joined(separator: " · ")
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
        transcribedWith = (transcript?.enhancedModel ?? transcript?.liveModel)
            .flatMap { WhisperModel(rawValue: $0)?.displayName }
        notes.load(session.directory)
        player.load(session)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(Theme.Font.display)
                    HStack(spacing: 6) {
                        Text(session.fullTitle)
                        if let model = transcribedWith {
                            Text("·")
                            Label(model, systemImage: "cube.box")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
                    Text(session.subtitle)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(player.duration.clockString)
                    .font(Theme.Font.timer)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                // Assignable after the fact: the summary, and any filtering, are
                // just as useful applied retroactively, and a required dropdown
                // before recording is friction at the worst possible moment.
                HeaderActionMenu(
                    title: assignedType?.name ?? "No Type",
                    systemImage: assignedType?.systemImage ?? "square.grid.2x2",
                    help: "Decides how the AI summary is written"
                ) {
                    ForEach(meetingTypes.types) { type in
                        Button {
                            SessionStore.setType(type.id, in: session.directory)
                            meetingTypes.noteUsed(type)
                            sessions.refresh()
                        } label: {
                            Label(type.name, systemImage: type.systemImage)
                        }
                    }
                    Divider()
                    Button("No Type") {
                        SessionStore.setType(nil, in: session.directory)
                        sessions.refresh()
                    }
                }

                Spacer()

                HeaderActionMenu(
                    title: enhancer.isRunning
                        ? (enhancer.runningModel?.displayName ?? "Transcribing")
                        : "Transcribe",
                    systemImage: "waveform.badge.magnifyingglass",
                    isBusy: enhancer.isRunning,
                    isEnabled: !enhancer.isRunning,
                    help: "Re-run transcription from the audio with a model you choose"
                ) {
                    if downloadedModels.isEmpty {
                        Text("No models downloaded")
                    } else {
                        Section("Improve rough lines") {
                            ForEach(downloadedModels) { model in
                                Button {
                                    run(model, replacing: false)
                                } label: {
                                    Label(model.displayName, systemImage: "wand.and.sparkles")
                                }
                            }
                        }
                        Section("Re-transcribe everything") {
                            ForEach(downloadedModels) { model in
                                Button {
                                    run(model, replacing: true)
                                } label: {
                                    Label(model.displayName, systemImage: "arrow.counterclockwise")
                                }
                            }
                        }
                    }
                }

                AIActionsMenu(session: session, runner: ai) {}
                .environmentObject(glossary)

                HeaderAction(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    isEnabled: !segments.isEmpty,
                    help: "Copy the transcript as timestamped text"
                ) {
                    copyTranscript()
                }

                HeaderAction(
                    title: "Reveal",
                    systemImage: "folder",
                    help: "Show this recording in Finder"
                ) {
                    sessions.reveal(session)
                }
            }

            if let error = player.error {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
            }

            if let progress = enhancer.progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.system)
                        .frame(width: 160)
                    Text(enhancer.status ?? "Enhancing…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { enhancer.cancel() }
                        .controlSize(.small)
                }
            }

            if let enhanceError = enhancer.error {
                Text(enhanceError)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
                    .lineLimit(2)
            }

            if let action = ai.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(ai.queued.isEmpty
                         ? "\(action.title)…"
                         : "\(action.title)… (\(ai.queued.count) more)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { ai.cancel() }
                        .controlSize(.small)
                }
            }

            if let outcome = ai.outcome {
                Label(outcome, systemImage: "checkmark.seal.fill")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.system)
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
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    private var noTranscript: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No transcript for this recording")
                .font(Theme.Font.title)
                .foregroundStyle(.secondary)
            Text("The audio is still here and will play. Recordings made before\ntranscripts were saved have no text.")
                .font(Theme.Font.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 14) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.system.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .disabled(player.duration == 0)
            .keyboardShortcut(.space, modifiers: [])

            Text(displayTime.clockString)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            // While dragging, the slider owns the value; on release it seeks
            // once, rather than scrubbing the engine on every pixel of movement.
            Slider(
                value: Binding(
                    get: { displayTime },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(player.duration, 0.1),
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { player.seek(to: scrubValue) }
                }
            )
            .tint(Theme.system)
            .disabled(player.duration == 0)

            Text(player.duration.clockString)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial)
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
        let time = player.currentTime
        return (keyframes.last { $0.time <= time + 0.01 } ?? keyframes.first)?.file
    }

    /// The line being spoken now.
    ///
    /// Resolved here rather than inside the transcript so that the transcript's
    /// inputs only change when the line does — playback time itself ticks 20x a
    /// second and would otherwise re-render every row that often.
    /// Binary search rather than a scan: this runs on every playback tick, and a
    /// linear pass over a long transcript 20 times a second is real work for an
    /// answer that changes once a sentence.
    private var activeSegmentID: TranscriptSegment.ID? {
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
            if time < max(segment.end, segment.start + 0.3) { return segment.id }
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

