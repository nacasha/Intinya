import Foundation

/// Owns everything that happens per audio packet, on a background queue.
///
/// None of this work belongs on the main thread: WAV writing is disk I/O, and
/// chunking runs voice-activity detection. Doing it inline in a `@MainActor`
/// method — which is what this code used to do — stalls SwiftUI while recording
/// and blanks the window.
///
/// Callbacks come back on the main queue, already throttled, so the UI only
/// updates as often as it can actually render.
final class CaptureIngest {

    struct Level {
        let source: AudioSource
        let rms: Float
    }

    /// Delivered on the main queue.
    var onChunk: ((LiveChunker.Chunk, AudioSource) -> Void)?
    var onLevel: ((Level) -> Void)?

    /// Serial: the chunkers and writers are not thread-safe, and audio packets
    /// must stay in order.
    private let queue = DispatchQueue(label: "meeting.ingest", qos: .userInitiated)

    private var chunkers: [AudioSource: LiveChunker] = [:]
    private var writers: [AudioSource: WAVWriter] = [:]

    /// Level updates are coalesced to ~20 Hz. Audio arrives far faster than the
    /// display refreshes, and every published change costs a SwiftUI pass.
    private var lastLevelSent: [AudioSource: CFAbsoluteTime] = [:]
    private var peakSinceSend: [AudioSource: Float] = [:]
    private static let levelInterval: CFAbsoluteTime = 0.05

    // MARK: - Lifecycle

    func start(micURL: URL, systemURL: URL) throws {
        var thrown: Error?
        queue.sync {
            self.chunkers = [.mic: LiveChunker(), .system: LiveChunker()]
            self.isPaused = false
            self.lastLevelSent = [:]
            self.peakSinceSend = [:]
            do {
                self.writers = [
                    .mic: try WAVWriter(url: micURL),
                    .system: try WAVWriter(url: systemURL),
                ]
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
    }

    /// Flushes remaining audio and closes the files. Trailing chunks are
    /// delivered through `onChunk` before the completion runs.
    func finish(completion: @escaping () -> Void) {
        queue.async {
            for (source, chunker) in self.chunkers {
                if let tail = chunker.drain() {
                    DispatchQueue.main.async { self.onChunk?(tail, source) }
                }
            }
            self.writers.values.forEach { $0.finish() }
            self.writers.removeAll()
            self.chunkers.removeAll()
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - Hot path

    /// While paused, samples are dropped rather than buffered: the recording is
    /// the audio actually kept, so a pause simply produces no audio at all.
    private var isPaused = false

    func setPaused(_ paused: Bool) {
        queue.async { self.isPaused = paused }
    }

    /// Flushes buffered audio without closing the files, so the last utterance
    /// before a pause is transcribed instead of waiting for resume.
    func flush() {
        queue.async {
            for (source, chunker) in self.chunkers {
                if let tail = chunker.drain() {
                    DispatchQueue.main.async { self.onChunk?(tail, source) }
                }
            }
        }
    }

    /// Snapshots the not-yet-closed utterance on each track, for provisional
    /// decoding. Non-consuming: the chunkers keep their buffers and will emit
    /// the same audio as a real chunk when the utterance ends.
    /// Delivered on the main queue, like `onChunk`.
    func snapshotPending(_ completion: @escaping ([(LiveChunker.Chunk, AudioSource)]) -> Void) {
        queue.async {
            var snapshots: [(LiveChunker.Chunk, AudioSource)] = []
            if !self.isPaused {
                for (source, chunker) in self.chunkers {
                    if let chunk = chunker.peek() { snapshots.append((chunk, source)) }
                }
            }
            DispatchQueue.main.async { completion(snapshots) }
        }
    }

    /// Called from the capture threads. Returns immediately.
    func push(_ samples: [Float], from source: AudioSource) {
        queue.async {
            guard !self.isPaused else { return }
            self.writers[source]?.append(samples)

            if let chunker = self.chunkers[source] {
                for chunk in chunker.append(samples) {
                    DispatchQueue.main.async { self.onChunk?(chunk, source) }
                }
            }

            self.trackLevel(samples, from: source)
        }
    }

    private func trackLevel(_ samples: [Float], from source: AudioSource) {
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        let rms = samples.isEmpty ? 0 : (sumSquares / Float(samples.count)).squareRoot()

        peakSinceSend[source] = max(peakSinceSend[source] ?? 0, rms)

        let now = CFAbsoluteTimeGetCurrent()
        let last = lastLevelSent[source] ?? 0
        guard now - last >= Self.levelInterval else { return }
        lastLevelSent[source] = now

        let level = Level(source: source, rms: peakSinceSend[source] ?? 0)
        peakSinceSend[source] = 0
        DispatchQueue.main.async { self.onLevel?(level) }
    }
}
