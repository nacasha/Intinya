import AVFoundation
import SwiftUI

/// Plays a session's two tracks in sync, mixed.
///
/// Mic and system were captured as separate files but share a timeline, so they
/// are scheduled on two player nodes into a common mixer rather than mixed down
/// on disk. That keeps per-track volume possible and avoids materialising an
/// hour of audio in memory.
@MainActor
final class SessionPlayer: ObservableObject {

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var error: String?
    /// Which tracks this recording actually contains playable audio for.
    ///
    /// Published rather than derived on demand: SwiftUI only re-renders on
    /// published changes, so a plain lookup into the node map goes stale and a
    /// track with an empty file keeps rendering as available.
    @Published private(set) var availableSources: Set<AudioSource> = []

    /// Per-track mute, so you can isolate one side of the conversation.
    @Published var micEnabled = true { didSet { applyVolumes() } }
    @Published var systemEnabled = true { didSet { applyVolumes() } }

    /// The screen recording, when the session has one. Driven by this transport
    /// rather than playing on its own — the audio is the master clock, because
    /// transcript timestamps are derived from it.
    @Published private(set) var videoPlayer: AVPlayer?
    private var videoDuration: TimeInterval = 0

    /// Re-sync the video if it drifts further than this from the audio clock.
    /// Below roughly this much, a correction is more visible than the drift.
    private static let driftTolerance: TimeInterval = 0.25

    private let engine = AVAudioEngine()
    private var tracks: [(node: AVAudioPlayerNode, file: AVAudioFile)] = []
    private var sourceMap: [AudioSource: AVAudioPlayerNode] = [:]

    /// Where the current schedule started, in session time. Node playback time
    /// counts from the schedule, not from zero, so seeking needs this offset.
    private var scheduleOrigin: TimeInterval = 0
    private var timer: Timer?

    // MARK: - Loading

    func load(_ session: Session) {
        stop()
        tracks.removeAll()
        sourceMap.removeAll()
        availableSources = []
        videoPlayer = nil
        videoDuration = 0
        error = nil
        currentTime = 0

        let candidates: [(AudioSource, URL)] = [
            (.mic, session.directory.appendingPathComponent("mic.wav")),
            (.system, session.directory.appendingPathComponent("system.wav")),
        ]

        var longest: TimeInterval = 0

        for (source, url) in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            // Repair first: AVAudioFile honours the header, so an interrupted
            // recording would otherwise read as empty and play as silence.
            WAVHeaderRepair.repairIfNeeded(at: url)

            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { continue }

            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            tracks.append((node, file))
            sourceMap[source] = node
            availableSources.insert(source)
            longest = max(longest, Double(file.length) / file.processingFormat.sampleRate)
        }

        // Load the screen recording before the audio guard: a session could in
        // principle have video and no usable audio.
        let videoURL = session.directory.appendingPathComponent("screen.mov")
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let asset = AVURLAsset(url: videoURL)
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            // Muted: the screen recording's audio is already captured on the
            // system track, and playing both would double every voice.
            player.isMuted = true
            player.actionAtItemEnd = .pause
            videoPlayer = player

            let seconds = CMTimeGetSeconds(asset.duration)
            if seconds.isFinite, seconds > 0 {
                videoDuration = seconds
                longest = max(longest, seconds)
            }
        }

        guard !tracks.isEmpty || videoPlayer != nil else {
            error = "This recording has no playable audio."
            duration = 0
            return
        }

        duration = longest
        applyVolumes()

        do {
            try engine.start()
        } catch {
            self.error = "Could not start audio playback: \(error.localizedDescription)"
            return
        }
        schedule(from: 0)
    }

    func hasTrack(_ source: AudioSource) -> Bool {
        availableSources.contains(source)
    }

    // MARK: - Transport

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard !tracks.isEmpty || videoPlayer != nil else { return }
        // Restart from the top if the last play ran to the end.
        if currentTime >= duration - 0.05 {
            schedule(from: 0)
            seekVideo(to: 0)
        }

        if !engine.isRunning { try? engine.start() }
        tracks.forEach { $0.node.play() }
        videoPlayer?.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        tracks.forEach { $0.node.pause() }
        videoPlayer?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        tracks.forEach { $0.node.stop() }
        videoPlayer?.pause()
        isPlaying = false
        stopTimer()
        engine.stop()
    }

    /// Jumps to a point in session time and keeps playing if it already was.
    func seek(to time: TimeInterval) {
        guard !tracks.isEmpty || videoPlayer != nil else { return }
        let target = min(max(0, time), max(0, duration - 0.05))
        let wasPlaying = isPlaying

        tracks.forEach { $0.node.stop() }
        schedule(from: target)
        seekVideo(to: target)
        currentTime = target

        if wasPlaying {
            if !engine.isRunning { try? engine.start() }
            tracks.forEach { $0.node.play() }
            videoPlayer?.play()
            startTimer()
        }
    }

    private func seekVideo(to time: TimeInterval) {
        guard let videoPlayer else { return }
        let clamped = min(max(0, time), max(0, videoDuration))
        videoPlayer.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    /// Convenience for tapping a transcript line — a small lead-in makes the
    /// first word audible instead of clipped.
    func play(from time: TimeInterval) {
        seek(to: max(0, time - 0.25))
        if !isPlaying { play() }
    }

    // MARK: - Internals

    private func schedule(from time: TimeInterval) {
        scheduleOrigin = time
        for (node, file) in tracks {
            let rate = file.processingFormat.sampleRate
            let startFrame = AVAudioFramePosition(time * rate)
            guard startFrame < file.length else { continue }
            let frames = AVAudioFrameCount(file.length - startFrame)
            guard frames > 0 else { continue }
            node.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: frames,
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { _ in }
        }
    }

    private func applyVolumes() {
        sourceMap[.mic]?.volume = micEnabled ? 1 : 0
        sourceMap[.system]?.volume = systemEnabled ? 1 : 0
    }

    /// Position comes from the node's render clock rather than a wall timer, so
    /// the highlight stays locked to the audio instead of drifting.
    private func elapsedFromNode() -> TimeInterval? {
        guard let node = tracks.first?.node,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Nudges the video back onto the audio clock when it slips.
    ///
    /// Two independent clocks will always diverge slightly; correcting only past
    /// a tolerance keeps the picture from visibly stuttering on every tick.
    private func correctVideoDrift(against time: TimeInterval) {
        guard let videoPlayer, videoDuration > 0 else { return }
        guard time <= videoDuration else { return }

        let videoTime = CMTimeGetSeconds(videoPlayer.currentTime())
        guard videoTime.isFinite else { return }

        if abs(videoTime - time) > Self.driftTolerance {
            videoPlayer.seek(
                to: CMTime(seconds: time, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
    }

    private func startTimer() {
        stopTimer()
        // 20 Hz: fast enough that highlighting feels attached to the audio,
        // slow enough not to thrash SwiftUI diffing on a long transcript.
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let time: TimeInterval
                if let elapsed = self.elapsedFromNode() {
                    time = self.scheduleOrigin + elapsed
                } else if let videoPlayer = self.videoPlayer {
                    // Video-only session: it becomes the clock by default.
                    let videoTime = CMTimeGetSeconds(videoPlayer.currentTime())
                    guard videoTime.isFinite else { return }
                    time = videoTime
                } else {
                    return
                }

                if time >= self.duration {
                    self.currentTime = self.duration
                    self.pause()
                } else {
                    self.currentTime = time
                    self.correctVideoDrift(against: time)
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
