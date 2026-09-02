import AVFoundation
import Foundation
import SwiftUI

/// Owns the capture pipeline and the transcript.
///
/// Flow per track:  capture -> 16kHz mono -> WAV on disk (for the enhanced pass)
///                                        -> LiveChunker -> TranscriptionEngine
@MainActor
final class Recorder: ObservableObject {

    // MARK: Published state

    @Published private(set) var isRecording = false
    /// Permissions the app needs but has not been granted.
    @Published private(set) var missingPermissions: [Permission] = []
    @Published private(set) var isPaused = false
    @Published private(set) var sections: [MeetingSection] = []
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var status: String = "Idle"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isModelReady = false
    /// Set when a load fails, so the UI can offer a retry rather than requiring
    /// a relaunch. Killing the app mid-download leaves exactly this state.
    @Published private(set) var modelFailed = false
    /// Chunks decoding right now, per track — so a placeholder can be drawn on
    /// the side the text will actually arrive on.
    @Published private(set) var pending: [AudioSource: Int] = [:]

    /// Provisional text for the utterance still being spoken, per track.
    ///
    /// Decoded from a snapshot of the open buffer every second or so, so words
    /// appear while you talk instead of after you stop. Never persisted, never
    /// in `segments` — the real chunk replaces it when the utterance closes,
    /// and its tail is wrong often enough that saving it would be saving noise.
    @Published private(set) var partials: [AudioSource: TranscriptSegment] = [:]
    /// Tracks with a provisional decode running, so previews never stack up
    /// behind a slow one.
    private var partialInFlight: Set<AudioSource> = []
    private var timerTicks = 0

    var pendingChunks: Int { pending.values.reduce(0, +) }

    /// Waveform levels and elapsed time. A separate object on purpose — see
    /// `RecordingMonitor`.
    let monitor = RecordingMonitor()

    /// What is actually being captured right now. A recording app has to be
    /// unambiguous about this — it's a trust requirement, not decoration.
    @Published private(set) var micActive = false
    @Published private(set) var systemActive = false

    /// The session just written to disk, once its queue has drained.
    @Published private(set) var lastSessionDirectory: URL?
    /// True once a session has been enhanced. Set when reopening a session that
    /// already carries enhanced text.
    @Published private(set) var isEnhanced = false

    /// Set once a recording has stopped **and** every queued chunk has been
    /// transcribed and written. Only then is the session complete on disk, which
    /// is what the rest of the app needs before it can show or act on it.
    @Published private(set) var completedSessionID: String?


    // MARK: Pipeline

    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private var engine: TranscriptionEngine
    @Published private(set) var activeModel: WhisperModel

    private let ingest = CaptureIngest()
    private let screen = ScreenCapture()

    // MARK: Screen capture

    /// Chosen before recording; persisted with the session so playback knows
    /// what to show.
    /// Chosen before or during recording; decides how the AI summarises later.
    @Published private(set) var meetingTypeID: UUID?

    /// Applies a type, along with the capture mode it prefers.
    ///
    /// The capture default only lands when not recording — the screen stream is
    /// already running by then, and silently switching it mid-meeting would
    /// change what is being recorded without asking.
    func useMeetingType(_ type: MeetingType?) {
        meetingTypeID = type?.id
        if let type, !isRecording {
            screenMode = type.screenMode
        }
        if lastSessionDirectory != nil || isRecording { persistTranscript() }
    }

    @Published var screenMode: ScreenCaptureMode = .off
    @Published var screenTarget: ScreenTarget?
    @Published private(set) var screenTargets: [ScreenTarget] = []
    @Published private(set) var keyframeCount = 0
    @Published private(set) var screenActive = false

    func refreshScreenTargets() async {
        screenTargets = await ScreenCapture.availableTargets()
        // Default to the whole screen, and recover if a chosen window has closed.
        if screenTarget == nil || !screenTargets.contains(where: { $0.id == screenTarget?.id }) {
            screenTarget = screenTargets.first
        }
    }

    // MARK: Audio sources

    /// Chosen input, or nil to follow the system default.
    @Published var micDevice: MicDevice?
    @Published private(set) var micDevices: [MicDevice] = []
    @Published var systemSource: SystemAudioSource = .systemWide
    @Published private(set) var systemSources: [SystemAudioSource] = [.systemWide]

    /// Persisted by UID, never by `AudioDeviceID` — see `MicDevice`. Unlike
    /// `screenTarget`, which is a per-meeting choice deliberately left transient,
    /// these describe your hardware setup and should survive a relaunch.
    @AppStorage("capture.micDeviceUID") private var savedMicUID = ""
    @AppStorage("capture.systemSource") private var savedSystemSourceID = ""

    func refreshAudioSources() async {
        micDevices = AudioDevices.inputs()
        // Recover if the chosen interface has been unplugged: fall back to the
        // system default rather than recording silence from a device that is gone.
        if let device = micDevice, !micDevices.contains(where: { $0.uid == device.uid }) {
            micDevice = nil
            savedMicUID = ""
        }

        systemSources = await SystemAudioCapture.availableSources()
        if !systemSources.contains(where: { $0.id == systemSource.id }) {
            systemSource = .systemWide
            savedSystemSourceID = ""
        }
    }

    /// Restores the persisted choices. Called once at launch.
    func restoreAudioSources() async {
        micDevices = AudioDevices.inputs()
        micDevice = AudioDevices.resolve(uid: savedMicUID)

        systemSources = await SystemAudioCapture.availableSources()
        systemSource = systemSources.first { $0.id == savedSystemSourceID } ?? .systemWide
    }

    func useMicDevice(_ device: MicDevice?) {
        guard !isRecording else { return }
        micDevice = device
        savedMicUID = device?.uid ?? ""
    }

    func useSystemSource(_ source: SystemAudioSource) {
        guard !isRecording else { return }
        systemSource = source
        savedSystemSourceID = source.isSystemWide ? "" : source.id
    }

    /// What the mic chip shows. The default input is named rather than labelled
    /// "Default", so the chip always says what is actually being recorded.
    var micLabel: String {
        micDevice?.name ?? AudioDevices.defaultInput()?.name ?? "No mic"
    }

    private var startedAt: Date?
    /// Recorded seconds completed before the current run segment.
    ///
    /// Elapsed time has to track **recorded audio**, not wall clock. Paused time
    /// never reaches the WAV, so a clock-based timer would drift away from the
    /// audio and every transcript timestamp with it.
    private var accumulated: TimeInterval = 0
    private var timer: Timer?
    private var sessionDirectory: URL?

    init(liveModel: WhisperModel = .defaultLive) {
        activeModel = liveModel
        engine = TranscriptionEngine(model: liveModel, glossary: .active)

        // The ingest pipeline does the per-packet work on its own queue and
        // calls back on main, already throttled.
        ingest.onChunk = { [weak self] chunk, source in
            self?.enqueue(chunk, from: source)
        }
        ingest.onLevel = { [weak self] level in
            self?.apply(level)
        }
        screen.onKeyframe = { [weak self] _ in
            self?.keyframeCount += 1
        }
        screen.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    /// Swaps the live model. Refuses mid-recording rather than silently changing
    /// models halfway through a transcript.
    func useModel(_ model: WhisperModel) {
        guard model != activeModel else {
            ensureModelReady()
            return
        }
        guard !isRecording else {
            errorMessage = "Stop recording before switching models."
            return
        }

        modelTask?.cancel()
        modelTask = Task { [weak self] in
            guard let self else { return }
            await self.engine.unload()
            await MainActor.run {
                self.activeModel = model
                self.engine = TranscriptionEngine(model: model, glossary: .active)
                self.isModelReady = false
            }
            await self.prepareModel()
            await MainActor.run { self.modelTask = nil }
        }
    }

    // MARK: Permissions

    enum Permission: String, Identifiable, Hashable {
        case microphone = "Microphone"
        case screenRecording = "Screen Recording"

        var id: String { rawValue }

        /// Deep link to the exact Privacy pane.
        var settingsURL: URL? {
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }
        }
    }

    /// Permissions whose system dialog can no longer appear.
    ///
    /// macOS only shows a permission dialog while the answer is *undetermined*.
    /// Once denied, `requestAccess` returns immediately and silently — so asking
    /// again does nothing and Settings is the only route left.
    @Published private(set) var promptExhausted: Set<Permission> = []

    /// Checks without prompting, so it is safe to call on every appearance.
    func refreshPermissions() {
        var missing: [Permission] = []

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            promptExhausted.remove(.microphone)
        case .notDetermined:
            missing.append(.microphone)
            promptExhausted.remove(.microphone)
        default:
            // Denied or restricted: the dialog is no longer available.
            missing.append(.microphone)
            promptExhausted.insert(.microphone)
        }

        // Asked directly rather than inferred from a failure: ScreenCaptureKit
        // reports a missing grant as a generic error, which makes "denied" and
        // "genuinely broken" indistinguishable. There is no API that separates
        // "undetermined" from "denied" here, so the prompt is attempted once and
        // marked exhausted only if it fails to help.
        if CGPreflightScreenCaptureAccess() {
            promptExhausted.remove(.screenRecording)
        } else {
            missing.append(.screenRecording)
        }

        missingPermissions = missing
    }

    func canPrompt(for permission: Permission) -> Bool {
        !promptExhausted.contains(permission)
    }

    /// Shows the system dialog if macOS will still display one.
    func requestAccess(to permission: Permission) async {
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await MicCapture.requestAccess()
            }
        case .screenRecording:
            CGRequestScreenCaptureAccess()
        }

        refreshPermissions()
        // Still missing after asking means the dialog never appeared.
        if missingPermissions.contains(permission) {
            promptExhausted.insert(permission)
        }
    }

    func openSettings(for permission: Permission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Prompts for anything undecided, then reports what is still missing.
    private func requestPermissions() async -> [Permission] {
        for permission in missingPermissions where canPrompt(for: permission) {
            await requestAccess(to: permission)
        }
        refreshPermissions()
        return missingPermissions
    }

    var permissionMessage: String? {
        guard !missingPermissions.isEmpty else { return nil }
        let list = missingPermissions.map(\.rawValue).joined(separator: " and ")
        return "\(list) access is required to record. "
             + "Grant it in System Settings › Privacy & Security, then restart Meeting."
    }

    // MARK: Model

    /// Owns the model-loading task.
    ///
    /// Loading must **not** live in a view's `.task`: SwiftUI cancels those when
    /// the view goes away or changes identity, and a background refresh
    /// elsewhere re-rendering the detail pane was enough to cancel a download
    /// mid-flight (`NSURLErrorDomain -999`). Held here, on a long-lived object,
    /// it survives whatever the UI does.
    private var modelTask: Task<Void, Never>?

    /// Idempotent: safe to call from `onAppear` on every render.
    /// Forces another attempt after a failure.
    func retryModel() {
        modelTask?.cancel()
        modelTask = nil
        modelFailed = false
        ensureModelReady()
    }

    func ensureModelReady() {
        guard !isModelReady, modelTask == nil else { return }
        modelTask = Task { [weak self] in
            await self?.prepareModel()
            await MainActor.run { self?.modelTask = nil }
        }
    }

    func prepareModel() async {
        status = "Loading model…"
        modelFailed = false
        do {
            try await engine.load { [weak self] message in
                Task { @MainActor in self?.status = message }
            }
            isModelReady = true
            status = "Ready"
        } catch {
            isModelReady = false
            modelFailed = true
            status = "Model failed to load"
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Recording

    func toggleRecording() {
        Task { isRecording ? await stop() : await start() }
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        segments.removeAll()
        completedSessionID = nil
        lastSessionDirectory = nil
        keyframeCount = 0
        pending = [:]
        partials = [:]

        guard isModelReady else {
            errorMessage = "The transcription model is still loading."
            return
        }

        // Permissions are settled before a session folder exists. Starting
        // half-permitted used to leave an empty recording behind and produce a
        // transcript missing one side of the conversation.
        let missing = await requestPermissions()
        guard missing.isEmpty else {
            errorMessage = permissionMessage
            status = "Permission required"
            return
        }

        do {
            try openSession()
        } catch {
            errorMessage = "Could not create the session folder: \(error.localizedDescription)"
            return
        }

        mic.onSamples = { [weak self] samples in
            self?.ingest.push(samples, from: .mic)
        }
        mic.onError = { [weak self] message in
            Task { @MainActor in
                self?.micActive = false
                self?.errorMessage = message
            }
        }
        do {
            try mic.start(device: micDevice)
            micActive = true
        } catch {
            micActive = false
            errorMessage = error.localizedDescription

            // A chosen device that will not open must not cost you the mic
            // track when there is a working default sitting right there. Retry
            // once unscoped, and say so rather than silently changing input.
            if micDevice != nil {
                do {
                    try mic.start(device: nil)
                    micActive = true
                    errorMessage = "\(error.localizedDescription) Recording from the default input instead."
                } catch {
                    micActive = false
                }
            }
        }

        // System audio — this is the half that needs Screen Recording.
        system.onSamples = { [weak self] samples in
            self?.ingest.push(samples, from: .system)
        }
        system.onStreamError = { [weak self] error in
            Task { @MainActor in
                self?.systemActive = false
                self?.errorMessage = "System audio stopped: \(error.localizedDescription)"
            }
        }
        do {
            try await system.start(source: systemSource)
            systemActive = true
        } catch {
            errorMessage = error.localizedDescription

            // Same reasoning as the mic: if the chosen app has quit, fall back
            // to capturing everything rather than losing the track entirely.
            if !systemSource.isSystemWide {
                do {
                    try await system.start(source: .systemWide)
                    systemActive = true
                    errorMessage = "\(error.localizedDescription) Capturing all system audio instead."
                } catch {
                    systemActive = false
                }
            }
        }

        guard micActive || systemActive else {
            status = "Nothing to capture"
            closeSession {}
            return
        }

        // Screen capture is best-effort: a failure here must not cost you the
        // audio recording, which is the part that cannot be redone.
        if screenMode != .off, let target = screenTarget, let directory = sessionDirectory {
            do {
                try await screen.start(mode: screenMode, target: target, sessionDirectory: directory)
                screenActive = true
            } catch {
                errorMessage = "Screen capture unavailable: \(error.localizedDescription)"
                screenActive = false
            }
        }

        isRecording = true
        isPaused = false
        accumulated = 0
        sections = []
        startedAt = Date()
        status = "Recording"
        startTimer()
    }

    /// Suspends capture without ending the session.
    func togglePause() {
        guard isRecording else { return }
        if isPaused {
            startedAt = Date()
            isPaused = false
            ingest.setPaused(false)
            status = "Recording"
            startTimer()
        } else {
            // Bank what has been recorded so far, then stop counting.
            accumulated = monitor.elapsed
            isPaused = true
            ingest.setPaused(true)
            // A pause is a natural utterance boundary; flush so the last words
            // appear now rather than after resume.
            ingest.flush()
            // The flushed chunks supersede any preview of the same audio.
            partials = [:]
            stopTimer()
            status = "Paused"
        }
    }

    /// Marks a new section at the current point in the recording.
    @discardableResult
    func addSection(titled title: String, at time: TimeInterval? = nil) -> MeetingSection {
        let section = MeetingSection(title: title, start: time ?? monitor.elapsed)
        sections.append(section)
        sections = sections.chronological
        persistTranscript()
        return section
    }

    /// Replaces a line's text by hand. Marked polished so a later enhanced pass
    /// does not silently overwrite the correction.
    func updateSegment(_ segment: TranscriptSegment, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        segments[index].text = text
        segments[index].tier = .polished
        persistTranscript()
    }

    /// Applies AI corrections to the transcript being recorded.
    ///
    /// Matched by identity, not position: lines keep arriving while the model
    /// works, so an index captured earlier would now point somewhere else.
    func applyCorrections(_ corrections: [UUID: String]) -> Int {
        var applied = 0
        for (id, text) in corrections {
            guard let index = segments.firstIndex(where: { $0.id == id }) else { continue }
            segments[index].text = text
            segments[index].tier = .polished
            applied += 1
        }
        if applied > 0 { persistTranscript() }
        return applied
    }

    /// Where notes and transcript for the running session are written.
    var activeDirectory: URL? { sessionDirectory ?? lastSessionDirectory }

    func removeSection(_ section: MeetingSection) {
        sections.removeAll { $0.id == section.id }
        persistTranscript()
    }

    func renameSection(_ section: MeetingSection, to title: String) {
        guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
        sections[index].title = title
        persistTranscript()
    }

    func stop() async {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        ingest.setPaused(false)
        status = "Finishing…"
        stopTimer()
        // Previews die with the recording; the drained chunks are the record.
        partials = [:]

        mic.stop()
        await system.stop()
        await screen.stop()
        micActive = false
        systemActive = false
        screenActive = false

        // Flush whatever is still buffered so the last sentence isn't lost.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            closeSession { continuation.resume() }
        }

        lastSessionDirectory = sessionDirectory
        // Live chunks may still be decoding; persist now so nothing is lost if
        // the app quits, and again when they land.
        persistTranscript()
        status = pendingChunks > 0 ? "Finishing transcription…" : "Stopped"
        // Nothing queued means the session is already complete.
        completeIfDrained()
    }

    /// Bumped on every write, so the library can re-read rather than trust a
    /// snapshot taken before the last chunks landed.
    @Published private(set) var transcriptRevision = 0

    /// Writes the transcript alongside the audio so the session can be reopened.
    func persistTranscript() {
        guard let directory = lastSessionDirectory ?? sessionDirectory else { return }
        let transcript = SessionTranscript(
            segments: orderedSegments,
            recordedAt: startedAt ?? Date(),
            duration: monitor.elapsed,
            liveModel: activeModel.rawValue,
            enhancedModel: nil,
            keyframes: screen.keyframes.isEmpty ? nil : screen.keyframes,
            screenMode: screenMode == .off ? nil : screenMode,
            micDevice: micLabel,
            systemAudioSource: systemSource.isSystemWide ? nil : systemSource.title,
            sections: sections.isEmpty ? nil : sections.chronological,
            typeID: meetingTypeID
        )
        SessionStore.saveTranscript(transcript, in: directory)
        transcriptRevision += 1
    }

    /// Called whenever a chunk finishes. The session is only finished once the
    /// queue has drained — trailing chunks routinely land after the stop.
    private func completeIfDrained() {
        guard !isRecording, pendingChunks == 0,
              let directory = lastSessionDirectory,
              completedSessionID == nil
        else { return }
        persistTranscript()
        completedSessionID = directory.lastPathComponent
    }

    /// Clears the record screen for the next meeting.
    ///
    /// Deliberately separate from `stop()`: the transcript must stay on screen
    /// until the session has been handed over, or trailing chunks would be
    /// appended to an emptied list and saved over the real transcript.
    func resetForNextRecording() {
        segments.removeAll()
        sections = []
        accumulated = 0
        monitor.reset()
        completedSessionID = nil
        lastSessionDirectory = nil
        sessionDirectory = nil
        isEnhanced = false
        errorMessage = nil
        keyframeCount = 0
        status = isModelReady ? "Ready" : status
    }


    /// Applies a throttled level update from the ingest queue.
    private func apply(_ level: CaptureIngest.Level) {
        monitor.record(level: level.rms, for: level.source)
    }

    /// Hands a chunk to the engine. The engine is an actor, so concurrent calls
    /// from both tracks serialise on their own; segments are ordered by their
    /// timestamps at render time rather than by completion order.
    private func enqueue(_ chunk: LiveChunker.Chunk, from source: AudioSource) {
        pending[source, default: 0] += 1
        Task { [engine] in
            defer {
                Task { @MainActor in
                    self.pending[source] = max(0, (self.pending[source] ?? 1) - 1)
                    self.completeIfDrained()
                }
            }
            do {
                guard let text = try await engine.transcribe(samples: chunk.samples) else { return }
                await MainActor.run {
                    // The durable line covers the preview's span — retire it.
                    if let partial = self.partials[source], partial.start < chunk.end {
                        self.partials[source] = nil
                    }
                    self.segments.append(
                        TranscriptSegment(
                            source: source,
                            start: chunk.start,
                            end: chunk.end,
                            text: text,
                            tier: .live
                        )
                    )
                    // The last chunks often land after stop; keep disk current.
                    if !self.isRecording { self.persistTranscript() }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Session files

    private func openSession() throws {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // "Meeting", not "Intinya", after the rename. The recordings already on
        // disk live under this path, and changing it would not migrate them —
        // it would hide them. The folder name is storage, not branding.
            .appendingPathComponent("Meeting/Sessions", isDirectory: true)
        let stamp = DateFormatter.sessionStamp.string(from: Date())
        let directory = base.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        sessionDirectory = directory
        try ingest.start(
            micURL: directory.appendingPathComponent("mic.wav"),
            systemURL: directory.appendingPathComponent("system.wav")
        )
    }

    /// Flushes the ingest queue, then persists. Trailing chunks are delivered
    /// before the completion runs, so nothing recorded is dropped on stop.
    private func closeSession(then completion: @escaping () -> Void) {
        ingest.finish(completion: completion)
    }

    /// Where this session's audio landed — the enhanced pass reads from here.
    var currentSessionDirectory: URL? { sessionDirectory }

    // MARK: Timer

    private func startTimer() {
        timerTicks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt, !self.isPaused else { return }
                self.monitor.setElapsed(self.accumulated + Date().timeIntervalSince(startedAt))
                // Every 4th tick: the preview cadence rides the elapsed timer
                // so it starts and stops with recording by construction.
                self.timerTicks += 1
                if self.timerTicks % 4 == 0 { self.refreshPartials() }
            }
        }
    }

    /// Decodes a snapshot of the still-open utterance on each track so words
    /// appear while you speak.
    ///
    /// Provisional by construction: the snapshot ends mid-sentence, so the last
    /// few words wobble between refreshes until the real segment replaces the
    /// row. Real chunks always outrank previews for the engine — a track with
    /// a queued chunk, or a preview still decoding, is skipped this round.
    private func refreshPartials() {
        guard isRecording, isModelReady else { return }
        ingest.snapshotPending { [weak self] snapshots in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                for (chunk, source) in snapshots {
                    guard self.pending[source, default: 0] == 0,
                          !self.partialInFlight.contains(source)
                    else { continue }
                    self.partialInFlight.insert(source)

                    Task { [engine = self.engine] in
                        let text = try? await engine.transcribe(samples: chunk.samples)
                        await MainActor.run {
                            self.partialInFlight.remove(source)
                            guard self.isRecording else { return }
                            // Stale if the utterance closed while this was
                            // decoding: the durable line owns this span now.
                            let lastEnd = self.segments
                                .filter { $0.source == source }
                                .map(\.end).max() ?? 0
                            guard chunk.start >= lastEnd - 0.25 else { return }
                            if let text = text.flatMap({ $0 }) {
                                self.partials[source] = TranscriptSegment(
                                    source: source,
                                    start: chunk.start,
                                    end: chunk.end,
                                    text: text,
                                    tier: .live
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var orderedSegments: [TranscriptSegment] {
        segments.sorted { $0.start < $1.start }
    }
}

extension DateFormatter {
    /// Colon-free so the folder name survives Finder and shell round-trips.
    static let sessionStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
