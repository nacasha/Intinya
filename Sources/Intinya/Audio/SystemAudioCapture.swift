import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Captures system audio via ScreenCaptureKit and emits 16 kHz mono.
///
/// `excludesCurrentProcessAudio` is essential: without it the app's own output
/// (including anything it plays back) loops straight into the transcript.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let resampler = AudioResampler()
    private let sampleQueue = DispatchQueue(label: "meeting.system-audio", qos: .userInitiated)

    var onSamples: (([Float]) -> Void)?
    var onStreamError: ((Error) -> Void)?

    /// Starts capture, scoped to `source`.
    ///
    /// Defaults to everything, which is the original behaviour.
    func start(source: SystemAudioSource = .systemWide) async throws {
        guard stream == nil else { return }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            // SCK reports a denied TCC prompt as a generic failure here.
            throw CaptureError.screenRecordingDenied
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // We only want audio, but SCStream still needs a video configuration.
        // Keep it at the minimum so we're not paying to composite frames.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let filter = try Self.filter(for: source, in: content)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - Scoping

    /// Mirrors `ScreenCapture.filter(for:in:)`, but for audio.
    private static func filter(
        for source: SystemAudioSource,
        in content: SCShareableContent
    ) throws -> SCContentFilter {
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayAvailable
        }

        switch source.kind {
        case .systemWide:
            return SCContentFilter(display: display, excludingWindows: [])

        case .app:
            // Every process belonging to the app, helpers included — see
            // `SystemAudioSource.matches(bundleID:)` for why the parent process
            // alone is usually the wrong answer.
            let apps = content.applications.filter { source.matches(bundleID: $0.bundleIdentifier) }
            guard !apps.isEmpty else { throw CaptureError.appGone(source.title) }
            return SCContentFilter(display: display, including: apps, exceptingWindows: [])

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.windowGone
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// Everything that could plausibly be making sound.
    ///
    /// SCK cannot tell us who is actually playing audio, so this lists apps that
    /// own a real window — the same "skip the chrome" filtering
    /// `ScreenCapture.availableTargets()` applies — and hides our own helpers.
    static func availableSources() async -> [SystemAudioSource] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        ) else { return [.systemWide] }

        let ownID = Bundle.main.bundleIdentifier ?? ""

        // Collapse to one entry per app: helpers are captured implicitly by the
        // prefix match, so listing them separately would just be noise.
        var seen = Set<String>()
        var apps: [SystemAudioSource] = []
        for window in content.windows
            where window.frame.width > 200 && window.frame.height > 150
                && !(window.title ?? "").isEmpty
        {
            guard let app = window.owningApplication else { continue }
            let id = app.bundleIdentifier
            guard !id.isEmpty, id != ownID, !id.hasPrefix(ownID + "."), seen.insert(id).inserted
            else { continue }
            apps.append(SystemAudioSource(
                kind: .app(bundleID: id),
                title: app.applicationName,
                subtitle: id
            ))
        }
        apps.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return [.systemWide] + apps
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = resampler.resample(buffer)
        if !samples.isEmpty { onSamples?(samples) }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStreamError?(error)
    }

    /// Bridges SCK's CMSampleBuffer into an AVAudioPCMBuffer the converter accepts.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd)
        else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
