import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var store: ModelStore
    @State private var showingModels = false
    @State private var showingScreenPicker = false
    @StateObject private var notes = NotesDocument()
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    @EnvironmentObject private var activity: ActivityCenter

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            AccordionStack(panels: panels, storageKey: "record")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Sits directly above the Record button it is blocking, rather than
            // at the far end of the window from it.
            if !recorder.missingPermissions.isEmpty {
                Divider().opacity(0.5)
                PermissionBanner(
                    permissions: recorder.missingPermissions,
                    message: recorder.permissionMessage ?? ""
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            footer
        }
        // Must declare that it fills the split-view detail pane. Without this a
        // detail pane that momentarily resolves to zero size renders blank and
        // then settles into a broken layout.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 420)
        .background(.ultraThinMaterial)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showingModels) {
            ModelPickerView().environmentObject(store)
        }
        .sheet(isPresented: $showingScreenPicker) {
            ScreenCapturePicker().environmentObject(recorder)
        }
        // onAppear, not .task: loading is owned by the recorder so that a
        // re-render cannot cancel it. Both calls are idempotent.
        .onAppear {
            recorder.useModel(store.liveModel)
            recorder.refreshPermissions()
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

    /// Notes above the transcript, matching the playback layout.
    private var panels: [AccordionPanel] {
        [
            AccordionPanel(
                id: "notes",
                title: "Notes",
                systemImage: "note.text",
                badge: notes.savedLabel,
                accent: .orange
            ) {
                NotesView(document: notes, hasSession: recorder.lastSessionDirectory != nil)
            },
            AccordionPanel(
                id: "transcript",
                title: "Transcript",
                systemImage: "text.bubble",
                badge: sectionBadge,
                accent: Theme.mic
            ) {
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
                    pending: recorder.pending
                )
                .equatable()
            },
        ]
    }

    private var sectionBadge: String? {
        var parts: [String] = []
        if !recorder.segments.isEmpty { parts.append("\(recorder.segments.count) lines") }
        if !recorder.sections.isEmpty { parts.append("\(recorder.sections.count) sections") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var activeType: MeetingType? {
        meetingTypes.type(id: recorder.meetingTypeID)
    }

    private var screenButton: some View {
        Button {
            showingScreenPicker = true
        } label: {
            CaptureChip(
                title: recorder.screenMode == .off
                    ? "NO SCREEN"
                    : (recorder.screenTarget?.title ?? recorder.screenMode.label).uppercased(),
                systemImage: recorder.screenMode.systemImage,
                tint: recorder.screenActive ? Theme.system : nil
            )
        }
        .buttonStyle(.plain)
        .disabled(recorder.isRecording)
        .help(recorder.isRecording
              ? "Stop recording to change screen capture"
              : "Choose what to capture from the screen")
    }

    private var timerColor: Color {
        if recorder.isPaused { return .orange }
        return recorder.isRecording ? Theme.recording : .secondary
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting")
                        .font(Theme.Font.display)
                    Text(recorder.status)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                Spacer()
                HStack(spacing: 10) {
                    if recorder.isPaused {
                        Text("PAUSED")
                            .font(Theme.Font.label)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.orange.opacity(0.16)))
                    }
                    ElapsedLabel(monitor: recorder.monitor, color: timerColor)
                }
            }

            HStack(spacing: 10) {
                HeaderActionMenu(
                    title: activeType?.name ?? "No Type",
                    systemImage: activeType?.systemImage ?? "square.grid.2x2",
                    help: "Decides how the AI summarises this meeting, and preselects screen capture"
                ) {
                    ForEach(meetingTypes.types) { type in
                        Button {
                            recorder.useMeetingType(type)
                            meetingTypes.noteUsed(type)
                        } label: {
                            Label(type.name, systemImage: type.systemImage)
                        }
                    }
                    Divider()
                    Button("No Type") { recorder.useMeetingType(nil) }
                }

                LiveAIMenu(runner: activity.ai(for: ActivityCenter.liveKey))

                Spacer()
            }

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
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                showingModels = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cube.box")
                        .font(.system(size: 10))
                    Text(recorder.isModelReady
                         ? "\(recorder.activeModel.displayName) · id"
                         : "Preparing model…")
                        .font(Theme.Font.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Choose transcription model")

            if recorder.modelFailed {
                Button { recorder.retryModel() } label: {
                    CaptureChip(
                        title: "RETRY",
                        systemImage: "arrow.clockwise",
                        tint: .orange
                    )
                }
                .buttonStyle(.plain)
                .help(recorder.errorMessage ?? "Try loading the model again")
            }

            TrackBadge(source: .mic, isActive: recorder.micActive && !recorder.isPaused)
            TrackBadge(source: .system, isActive: recorder.systemActive && !recorder.isPaused)
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
            .frame(minWidth: 80)
            .layoutPriority(-1)
            .padding(.horizontal, 4)

            if recorder.isRecording {
                PauseButton(isPaused: recorder.isPaused) {
                    recorder.togglePause()
                }
            }

            RecordButton(
                isRecording: recorder.isRecording,
                isEnabled: recorder.isModelReady && recorder.missingPermissions.isEmpty
            ) {
                recorder.toggleRecording()
            }
            .help(recorder.missingPermissions.isEmpty
                  ? ""
                  : recorder.permissionMessage ?? "")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }
}

struct RecordButton: View {
    let isRecording: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isRecording ? Color.white : Theme.recording)
                        .frame(width: isRecording ? 10 : 13, height: isRecording ? 10 : 13)
                        .clipShape(RoundedRectangle(cornerRadius: isRecording ? 2 : 7, style: .continuous))
                }
                .frame(width: 14, height: 14)

                Text(isRecording ? "Stop" : "Record")
                    .font(Theme.Font.title)
            }
            .foregroundStyle(isRecording ? .white : .primary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                Capsule()
                    .fill(isRecording ? Theme.recording : Color.primary.opacity(isHovering ? 0.12 : 0.07))
            }
            .overlay {
                Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .scaleEffect(isHovering && isEnabled ? 1.03 : 1)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.2), value: isRecording)
        .animation(.smooth(duration: 0.2), value: isHovering)
        .keyboardShortcut("r", modifiers: [.command])
    }
}

/// Pause/Resume, built to the same shape as `RecordButton`.
///
/// Matching the transport button matters: these two sit side by side and both
/// change the recording state, so a small bordered control next to a large
/// capsule read as unrelated things.
struct PauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    @State private var isHovering = false

    private var tint: Color { .orange }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 14, height: 14)

                Text(isPaused ? "Resume" : "Pause")
                    .font(Theme.Font.title)
            }
            // Filled while paused, mirroring Stop: a filled capsule always means
            // "this state is currently active".
            .foregroundStyle(isPaused ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                Capsule().fill(isPaused ? tint : tint.opacity(isHovering ? 0.22 : 0.14))
            }
            .overlay {
                Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.03 : 1)
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.2), value: isPaused)
        .animation(.smooth(duration: 0.2), value: isHovering)
        .keyboardShortcut("p", modifiers: [.command])
        .help(isPaused ? "Resume recording" : "Pause without ending the recording")
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




/// Isolated so only this label re-renders on the timer tick.
private struct ElapsedLabel: View {
    @ObservedObject var monitor: RecordingMonitor
    let color: Color

    var body: some View {
        Text(monitor.elapsed.clockString)
            .font(Theme.Font.timer)
            .foregroundStyle(color)
            .contentTransition(.numericText())
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
