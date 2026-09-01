import Foundation

/// Tier 2: re-transcribes a finished session's audio with a more accurate model.
///
/// This is a second *read* of the recording, not a second recording — the WAVs
/// were written during capture. It streams the file in windows and reports each
/// one as it completes, so the transcript visibly sharpens instead of sitting
/// still until the whole pass finishes.
actor EnhancedPass {

    struct Window: Sendable {
        let source: AudioSource
        let start: TimeInterval
        let end: TimeInterval
        let segments: [TimedText]
    }

    struct Progress: Sendable {
        let fraction: Double
        let message: String
    }

    /// How much audio to hand the decoder at a time.
    ///
    /// Whisper works in 30-second windows internally and WhisperKit's VAD
    /// chunker splits within whatever we pass. 120s balances that against
    /// progressive updates — smaller windows update more often but re-pay the
    /// per-call overhead and lose cross-sentence context at each boundary.
    private static let windowSeconds: TimeInterval = 120

    private let engine: TranscriptionEngine
    let model: WhisperModel

    init(model: WhisperModel) {
        self.model = model
        self.engine = TranscriptionEngine(model: model, glossary: .active)
    }

    func cancel() { isCancelled = true }
    private var isCancelled = false

    /// Runs the pass over both tracks of a session directory.
    ///
    /// Tracks are processed sequentially rather than concurrently: they share
    /// one model instance, and two large CoreML inferences competing for the ANE
    /// is slower in wall-clock than doing them in order.
    func run(
        sessionDirectory: URL,
        onProgress: @Sendable @escaping (Progress) -> Void,
        onWindow: @Sendable @escaping (Window) -> Void
    ) async throws {
        isCancelled = false

        let tracks: [(AudioSource, URL)] = [
            (.mic, sessionDirectory.appendingPathComponent("mic.wav")),
            (.system, sessionDirectory.appendingPathComponent("system.wav")),
        ].filter { FileManager.default.fileExists(atPath: $0.1.path) }

        guard !tracks.isEmpty else { throw PassError.noAudio }

        onProgress(Progress(fraction: 0, message: "Loading \(model.displayName)…"))
        try await engine.load()

        // Total work is the sum of both tracks' durations, so the bar reflects
        // real remaining time rather than jumping between two per-track bars.
        var readers: [(AudioSource, WAVReader)] = []
        for (source, url) in tracks {
            let reader = try WAVReader(url: url)
            if reader.duration > 0.5 { readers.append((source, reader)) }
        }
        let totalSeconds = readers.reduce(0.0) { $0 + $1.1.duration }
        guard totalSeconds > 0 else { throw PassError.noAudio }

        var completedSeconds: Double = 0

        for (source, reader) in readers {
            while !reader.isAtEnd {
                if isCancelled { throw CancellationError() }

                let windowStart = reader.currentTime
                let samples = try reader.read(seconds: Self.windowSeconds)
                guard !samples.isEmpty else { break }

                let windowEnd = reader.currentTime
                let segments = try await engine.transcribeTimed(
                    samples: samples,
                    offset: windowStart
                )

                onWindow(Window(
                    source: source,
                    start: windowStart,
                    end: windowEnd,
                    segments: segments
                ))

                completedSeconds += windowEnd - windowStart
                onProgress(Progress(
                    fraction: min(1.0, completedSeconds / totalSeconds),
                    message: "Enhancing \(source.label.lowercased()) · \(Int(completedSeconds))s of \(Int(totalSeconds))s"
                ))
            }
        }

        await engine.unload()
        onProgress(Progress(fraction: 1.0, message: "Enhanced"))
    }

    enum PassError: LocalizedError {
        case noAudio

        var errorDescription: String? {
            switch self {
            case .noAudio: return "This session has no audio to enhance."
            }
        }
    }
}
