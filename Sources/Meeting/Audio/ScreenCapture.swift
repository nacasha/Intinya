import AVFoundation
import CoreImage
@preconcurrency import ScreenCaptureKit

/// Captures the screen alongside the audio, as either change-triggered stills or
/// a continuous video file.
///
/// Runs its **own** `SCStream`, separate from `SystemAudioCapture`. Sharing one
/// stream would mean the screen target dictates the audio filter — pick a single
/// window to record and you would silently stop capturing system audio from
/// everything else. Two streams keeps the two decisions independent.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private var recordingOutput: AnyObject?     // SCRecordingOutput, macOS 15+
    private let frameQueue = DispatchQueue(label: "meeting.screen", qos: .utility)

    private var mode: ScreenCaptureMode = .off
    private var framesDirectory: URL?
    private var startedAt: CFAbsoluteTime = 0

    /// Downscaled greyscale signature of the last kept frame.
    private var lastSignature: [UInt8]?
    private var lastCaptureAt: CFAbsoluteTime = 0

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Emitted on the main queue when a keyframe is written.
    var onKeyframe: ((Keyframe) -> Void)?
    var onError: ((String) -> Void)?

    struct Keyframe: Codable, Hashable {
        let time: TimeInterval
        let file: String
    }

    private(set) var keyframes: [Keyframe] = []

    // MARK: - Discovery

    /// Displays and on-screen windows worth offering as capture targets.
    static func availableTargets() async -> [ScreenTarget] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        ) else { return [] }

        var targets: [ScreenTarget] = content.displays.enumerated().map { index, display in
            ScreenTarget(
                kind: .display(display.displayID),
                title: content.displays.count == 1 ? "Entire Screen" : "Display \(index + 1)",
                subtitle: "\(display.width) × \(display.height)"
            )
        }

        // Skip the chrome: tiny windows and untitled ones are menu bar items,
        // shadows, and status overlays rather than things worth recording.
        let windows = content.windows
            .filter { $0.frame.width > 200 && $0.frame.height > 150 }
            .filter { !($0.title ?? "").isEmpty }
            .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }

        targets += windows.map { window in
            ScreenTarget(
                kind: .window(window.windowID),
                title: window.title ?? "Untitled",
                subtitle: window.owningApplication?.applicationName ?? "Unknown app"
            )
        }
        return targets
    }

    // MARK: - Lifecycle

    func start(mode: ScreenCaptureMode, target: ScreenTarget, sessionDirectory: URL) async throws {
        guard mode != .off else { return }
        self.mode = mode
        keyframes = []
        lastSignature = nil
        lastCaptureAt = 0
        startedAt = CFAbsoluteTimeGetCurrent()

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter = try Self.filter(for: target, in: content)
        let config = SCStreamConfiguration()

        switch mode {
        case .keyframes:
            // Half-ish resolution is plenty for reading slides back, and keeps
            // both the diffing and the written files cheap.
            let size = Self.captureSize(for: filter, scale: 0.5)
            config.width = size.width
            config.height = size.height
            // The diff decides what to keep; 2 fps is enough to catch a slide
            // change without paying for 60.
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            config.pixelFormat = kCVPixelFormatType_32BGRA
        case .video:
            let size = Self.captureSize(for: filter, scale: 1.0)
            config.width = size.width
            config.height = size.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        case .off:
            return
        }
        config.queueDepth = 5
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)

        switch mode {
        case .keyframes:
            let directory = sessionDirectory.appendingPathComponent("frames", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            framesDirectory = directory
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)

        case .video:
            guard #available(macOS 15.0, *) else { throw CaptureError.videoUnavailable }
            let configuration = SCRecordingOutputConfiguration()
            configuration.outputURL = sessionDirectory.appendingPathComponent("screen.mov")
            configuration.outputFileType = .mov
            configuration.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: configuration, delegate: self)
            try stream.addRecordingOutput(output)
            recordingOutput = output

        case .off:
            return
        }

        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        if #available(macOS 15.0, *), let output = recordingOutput as? SCRecordingOutput {
            try? stream.removeRecordingOutput(output)
        }
        recordingOutput = nil
        try? await stream.stopCapture()
    }

    // MARK: - Filters

    private static func filter(for target: ScreenTarget, in content: SCShareableContent) throws -> SCContentFilter {
        switch target.kind {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id })
                ?? content.displays.first
            else { throw CaptureError.noDisplayAvailable }
            return SCContentFilter(display: display, excludingWindows: [])

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.windowGone
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    /// Capture dimensions must be even for H.264, and are clamped so a Retina
    /// display doesn't produce needlessly enormous frames.
    private static func captureSize(for filter: SCContentFilter, scale: Double) -> (width: Int, height: Int) {
        let rect = filter.contentRect
        let pointScale = filter.pointPixelScale
        var width = Int(rect.width * Double(pointScale) * scale)
        var height = Int(rect.height * Double(pointScale) * scale)

        let maxDimension = 2560
        if max(width, height) > maxDimension {
            let ratio = Double(maxDimension) / Double(max(width, height))
            width = Int(Double(width) * ratio)
            height = Int(Double(height) * ratio)
        }
        return (max(2, width - width % 2), max(2, height - height % 2))
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, mode == .keyframes, sampleBuffer.isValid else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        considerKeyframe(pixelBuffer)
    }

    /// Keeps a frame only when the screen has meaningfully changed.
    ///
    /// Comparison is on a 32x32 greyscale signature rather than the full image:
    /// it is ~1000 comparisons instead of millions, and it ignores the noise
    /// (antialiasing, cursor blink, video scrub bars) that would otherwise make
    /// every frame look different.
    private func considerKeyframe(_ pixelBuffer: CVPixelBuffer) {
        guard let signature = signature(of: pixelBuffer) else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if let previous = lastSignature {
            let changed = Self.difference(previous, signature)
            // 6% of cells differing beyond the per-cell threshold reads as a real
            // content change rather than a cursor moving.
            guard changed > 0.06 else { return }
            // Never faster than one frame a second, so an animation cannot
            // produce hundreds of files.
            guard now - lastCaptureAt > 1.0 else { return }
        }

        lastSignature = signature
        lastCaptureAt = now
        write(pixelBuffer, at: now - startedAt)
    }

    private func signature(of pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let side = 32
        let scaled = image
            .transformed(by: CGAffineTransform(
                scaleX: Double(side) / image.extent.width,
                y: Double(side) / image.extent.height
            ))

        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        context.render(
            scaled,
            toBitmap: &bytes,
            rowBytes: side * 4,
            bounds: CGRect(x: 0, y: 0, width: side, height: side),
            format: .BGRA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Collapse to luminance; colour shifts alone are not interesting.
        var luminance = [UInt8]()
        luminance.reserveCapacity(side * side)
        var index = 0
        while index + 2 < bytes.count {
            let blue = Int(bytes[index])
            let green = Int(bytes[index + 1])
            let red = Int(bytes[index + 2])
            let value = (red * 30 + green * 59 + blue * 11) / 100
            luminance.append(UInt8(min(255, value)))
            index += 4
        }
        return luminance
    }

    /// Fraction of cells that changed beyond a per-cell tolerance.
    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > 12 {
            changed += 1
        }
        return Double(changed) / Double(a.count)
    }

    private func write(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        guard let directory = framesDirectory else { return }
        // Centisecond-prefixed so the directory sorts chronologically.
        let filename = String(format: "%08d.jpg", Int(max(0, time) * 100))
        let url = directory.appendingPathComponent(filename)

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) else { return }
        do {
            try context.writeJPEGRepresentation(
                of: image,
                to: url,
                colorSpace: colorSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]
            )
        } catch {
            return
        }

        let keyframe = Keyframe(time: max(0, time), file: filename)
        keyframes.append(keyframe)
        DispatchQueue.main.async { self.onKeyframe?(keyframe) }
    }

    // MARK: - Delegates

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        DispatchQueue.main.async {
            self.onError?("Screen capture stopped: \(error.localizedDescription)")
        }
    }
}

@available(macOS 15.0, *)
extension ScreenCapture: SCRecordingOutputDelegate {
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.onError?("Screen recording failed: \(error.localizedDescription)")
        }
    }
}


