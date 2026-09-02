import SwiftUI

struct ContentView: View {
    /// Which half of the session the pane is showing.
    ///
    /// The same switch playback uses. It replaces the accordion, which made you
    /// trade one for the other, and the app-name title that sat where it is now
    /// — naming the app in the middle of the app.
    private enum Pane: Hashable {
        case transcript
        case notes
    }

    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var store: ModelStore
    @State private var showingModels = false
    @State private var showingScreenPicker = false
    @State private var showingAudioPicker = false
    /// Width of the detail pane, for capping the bottom bar.
    @State private var paneWidth: CGFloat = 0
    @State private var pane: Pane = .transcript
    /// Height of the bands floating over the top of the page, so the page can
    /// leave room for whatever is currently there.
    @State private var bandsHeight: CGFloat = 0
    @StateObject private var notes = NotesDocument()
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    @EnvironmentObject private var activity: ActivityCenter

    var body: some View {
        VStack(spacing: 0) {
            // Fixed, like playback's: always present, so its space is not worth
            // taking back.
            compactHeader
                // Topmost, so a dropdown hanging out of the header is not
                // painted over by what comes after it in this stack.
                .zIndex(2)
            Divider().opacity(0.5)
                .zIndex(1)

            // Everything else floats over the page: the bar, the fade, and the
            // bands that come and go. The page runs to the foot of the window
            // and scrolls beneath them, the same as playback.
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .bottomFade(height: Theme.barClearance)
                .overlay(alignment: .bottom) { footer }
                .overlay(alignment: .top) { statusBands }
        }
        // Must declare that it fills the split-view detail pane. Without this a
        // detail pane that momentarily resolves to zero size renders blank and
        // then settles into a broken layout.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.content)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { paneWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in paneWidth = width }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showingModels) {
            ModelPickerView().environmentObject(store)
        }
        .sheet(isPresented: $showingScreenPicker) {
            ScreenCapturePicker().environmentObject(recorder)
        }
        .sheet(isPresented: $showingAudioPicker) {
            AudioSourcePicker().environmentObject(recorder)
        }
        // onAppear, not .task: loading is owned by the recorder so that a
        // re-render cannot cancel it. Both calls are idempotent.
        .onAppear {
            recorder.useModel(store.liveModel)
            recorder.refreshPermissions()
            Task { await recorder.restoreAudioSources() }
            notes.load(recorder.lastSessionDirectory)
            if recorder.meetingTypeID == nil, let last = meetingTypes.lastUsed {
                recorder.useMeetingType(last)
            }
        }
        .onChange(of: recorder.lastSessionDirectory) { _, directory in
            notes.load(directory)
        }
        // Grants are made in System Settings, so re-check whenever the app comes
        // back to the front rather than only at launch.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            recorder.refreshPermissions()
        }
        .onChange(of: store.liveModel) { _, newModel in
            recorder.useModel(newModel)
        }
    }

    /// One pane at a time, on the same reading column as playback.
    @ViewBuilder
    private var pageContent: some View {
        switch pane {
        case .transcript:
            TranscriptView(
                segments: recorder.orderedSegments,
                isRecording: recorder.isRecording,
                onEdit: { recorder.updateSegment($0, text: $1) },
                sections: recorder.sections,
                onAddSection: recorder.isRecording || !recorder.segments.isEmpty
                    ? { recorder.addSection(titled: "Section \(recorder.sections.count + 1)", at: $0) }
                    : nil,
                onRenameSection: { recorder.renameSection($0, to: $1) },
                onDeleteSection: { recorder.removeSection($0) },
                pending: recorder.pending,
                partials: recorder.partials,
                bottomClearance: Theme.barClearance,
                topClearance: bandsHeight
            )
            .equatable()

        case .notes where recorder.lastSessionDirectory == nil:
            NotesView(document: notes, hasSession: false)

        case .notes:
            GeometryReader { geometry in
                SlimScrollView {
                    NotesView(
                        document: notes,
                        hasSession: recorder.lastSessionDirectory != nil,
                        // No heading on this pane, so the editor takes all of it
                        // bar the paddings.
                        minimumHeight: max(240, geometry.size.height - 60 - bandsHeight - Theme.barClearance)
                    )
                    .measure()
                    .padding(.top, bandsHeight)
                    .padding(.bottom, Theme.barClearance)
                }
            }
        }
    }

    private var activeType: MeetingType? {
        meetingTypes.type(id: recorder.meetingTypeID)
    }

    /// Both audio chips open the same sheet — picking a mic and picking what
    /// system audio to listen to is one decision, made at the same moment.
    private var micButton: some View {
        BarButton(
            systemImage: "mic.fill",
            tint: recorder.micActive && !recorder.isPaused ? Theme.mic : nil,
            isEnabled: !recorder.isRecording,
            showsMenuIndicator: false,
            tooltip: recorder.isRecording
                ? "Stop recording to change the microphone"
                : "Recording from \(recorder.micLabel)"
        ) {
            showingAudioPicker = true
        }
    }

    private var systemButton: some View {
        BarButton(
            systemImage: "speaker.wave.2.fill",
            tint: recorder.systemActive && !recorder.isPaused ? Theme.system : nil,
            isEnabled: !recorder.isRecording,
            tooltip: recorder.isRecording
                ? "Stop recording to change the system audio source"
                : "Capturing \(recorder.systemSource.title)"
        ) {
            showingAudioPicker = true
        }
    }

    private var screenButton: some View {
        BarButton(
            systemImage: recorder.screenMode.systemImage,
            tint: recorder.screenActive ? Theme.system : nil,
            isEnabled: !recorder.isRecording,
            tooltip: recorder.isRecording
                ? "Stop recording to change screen capture"
                : screenHelp
        ) {
            showingScreenPicker = true
        }
    }

    /// Names the target, since the chip itself is only an icon now.
    private var screenHelp: String {
        guard recorder.screenMode != .off else {
            return "Not capturing the screen"
        }
        let target = recorder.screenTarget?.title ?? recorder.screenMode.label
        return "Capturing \(target) as \(recorder.screenMode.label.lowercased())"
    }

    /// Half the pane, with a floor so the controls are never crushed together
    /// on a narrow window.
    private var barWidth: CGFloat? {
        guard paneWidth > 0 else { return nil }
        return max(520, paneWidth * 0.5)
    }

    // MARK: Header

    /// One row, matching playback: pane switch and state on the left, the
    /// actions on the right.
    private var compactHeader: some View {
        HStack(spacing: 10) {
            HeaderSwitch(
                options: [
                    .init(value: Pane.transcript, title: "Transcript", systemImage: "text.alignleft"),
                    .init(value: Pane.notes, title: "Notes", systemImage: "note.text"),
                ],
                selection: $pane
            )

            if recorder.isPaused {
                Text("PAUSED")
                    .font(Theme.Font.label)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
            }

            Spacer(minLength: 12)

            LiveAIMenu(runner: activity.ai(for: ActivityCenter.liveKey))

            HeaderMenu(
                title: activeType?.name ?? "No Type",
                systemImage: activeType?.systemImage ?? "square.grid.2x2",
                help: "Decides how the AI summarises this meeting, and preselects screen capture",
                items: meetingTypes.types.map { type in
                    .action(type.name, systemImage: type.systemImage) {
                        recorder.useMeetingType(type)
                        meetingTypes.noteUsed(type)
                    }
                } + [
                    .separator,
                    .action("No Type", systemImage: "slash.circle") {
                        recorder.useMeetingType(nil)
                    },
                ]
            )
        }
        .padding(.horizontal, 20)
        .frame(height: Theme.headerHeight)
    }

    /// Transient state — AI output, errors, the permission warning.
    ///
    /// A band over the page rather than a row in the stack, so it does not push
    /// the transcript down as it comes and goes. Same treatment playback gives
    /// its own status strip.
    private var statusBands: some View {
        VStack(spacing: 0) {
            if !recorder.missingPermissions.isEmpty {
                PermissionBanner(
                    permissions: recorder.missingPermissions,
                    message: recorder.permissionMessage ?? ""
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                Divider().opacity(0.5)
            }

            if hasStatus {
                VStack(alignment: .leading, spacing: 10) {
            if let answer = activity.ai(for: ActivityCenter.liveKey).panelAnswer {
                AIAnswerPanel(
                    title: activity.ai(for: ActivityCenter.liveKey).panelTitle,
                    answer: answer,
                    onSave: {
                        guard let directory = recorder.activeDirectory else { return }
                        let existing = Notes.load(in: directory)
                        Notes.save(
                            existing.isEmpty ? answer : existing + "\n\n---\n\n" + answer,
                            in: directory
                        )
                        activity.ai(for: ActivityCenter.liveKey).dismissPanel()
                        notes.reload()
                    },
                    onDismiss: { activity.ai(for: ActivityCenter.liveKey).dismissPanel() }
                )
            }

            if let aiError = activity.ai(for: ActivityCenter.liveKey).error {
                ErrorBanner(message: aiError)
            }

            if let message = recorder.errorMessage {
                ErrorBanner(message: message)
            }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider().opacity(0.5)
            }
        }
        .background(Theme.content)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { bandsHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in bandsHeight = height }
            }
        }
    }

    private var hasStatus: Bool {
        activity.ai(for: ActivityCenter.liveKey).panelAnswer != nil
            || activity.ai(for: ActivityCenter.liveKey).error != nil
            || recorder.errorMessage != nil
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            BarButton(
                systemImage: "cube.box",
                tooltip: recorder.isModelReady
                    ? "Transcribing with \(recorder.activeModel.displayName)"
                    : "Preparing the transcription model…"
            ) {
                showingModels = true
            }

            if recorder.modelFailed {
                BarButton(
                    systemImage: "arrow.clockwise",
                    title: "Retry",
                    tint: .orange,
                    tooltip: recorder.errorMessage ?? "Try loading the model again"
                ) {
                    recorder.retryModel()
                }
            }

            micButton
            systemButton
            screenButton

            if recorder.keyframeCount > 0 {
                Text("\(recorder.keyframeCount) frames")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            WaveformPair(
                monitor: recorder.monitor,
                micActive: recorder.micActive && !recorder.isPaused,
                systemActive: recorder.systemActive && !recorder.isPaused
            )
            .frame(height: 26)
            .frame(minWidth: 48, maxWidth: .infinity)
            .padding(.horizontal, 4)

            if recorder.isRecording {
                BarButton(
                    systemImage: recorder.isPaused ? "play.fill" : "pause.fill",
                    title: recorder.isPaused ? "Resume" : "Pause",
                    tint: .orange,
                    // Filled while paused, mirroring Stop: a filled capsule
                    // always means "this state is currently active".
                    isProminent: recorder.isPaused
                ) {
                    recorder.togglePause()
                }
            }

            BarButton(
                systemImage: recorder.isRecording ? "stop.fill" : "record.circle",
                title: recorder.isRecording ? "Stop" : "Record",
                tint: Theme.recording,
                isProminent: recorder.isRecording,
                isEnabled: recorder.isModelReady && recorder.missingPermissions.isEmpty,
                tooltip: recorder.missingPermissions.isEmpty
                    ? ""
                    : (recorder.permissionMessage ?? "")
            ) {
                recorder.toggleRecording()
            }
        }
        .floatingBar(maxWidth: barWidth)
    }
}

/// Missing permissions, with a way to fix them.
///
/// Distinct from a plain error: this is actionable and blocks recording, so it
/// links straight to the relevant Privacy pane rather than describing a path.
private struct PermissionBanner: View {
    @EnvironmentObject private var recorder: Recorder
    let permissions: [Recorder.Permission]
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 12))

            VStack(alignment: .leading, spacing: 7) {
                Text(message)
                    .font(Theme.Font.body)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    ForEach(permissions) { permission in
                        // Ask macOS first; Settings is offered only once the
                        // dialog is no longer available.
                        let canPrompt = recorder.canPrompt(for: permission)
                        Button {
                            if canPrompt {
                                Task { await recorder.requestAccess(to: permission) }
                            } else {
                                recorder.openSettings(for: permission)
                            }
                        } label: {
                            Label(
                                canPrompt
                                    ? "Allow \(permission.rawValue)"
                                    : "Open \(permission.rawValue) Settings",
                                systemImage: canPrompt ? "checkmark.shield" : "arrow.up.forward.app"
                            )
                            .font(Theme.Font.caption)
                        }
                        .controlSize(.small)
                        .help(canPrompt
                              ? "Show the macOS permission dialog"
                              : "Already denied, so macOS will not ask again — grant it in Settings")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        }
    }
}

private struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
            // Framework errors can be paragraphs of URLs; keep the banner to a
            // readable size and let the full text through the tooltip.
            Text(message)
                .font(Theme.Font.body)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(message)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.recording)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.recording.opacity(0.12))
        }
        .transition(.opacity.combined(with: .offset(y: -4)))
    }
}





/// Isolated so the twenty-per-second level updates invalidate only the meters.
private struct WaveformPair: View {
    @ObservedObject var monitor: RecordingMonitor
    let micActive: Bool
    let systemActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            WaveformView(levels: monitor.micLevels, color: Theme.mic, isActive: micActive)
            WaveformView(levels: monitor.systemLevels, color: Theme.system, isActive: systemActive)
        }
    }
}
