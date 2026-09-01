import Foundation
import WhisperKit

/// Slices a continuous 16 kHz stream into utterance-sized chunks at silence
/// boundaries.
///
/// Cutting on fixed intervals splits words mid-syllable, which Whisper handles
/// badly. Cutting on silence also keeps us from feeding the decoder long quiet
/// stretches — Whisper's silence hallucination is noticeably worse in Indonesian
/// than in English, so gating here is a correctness measure, not an optimisation.
///
/// Voice activity is computed **incrementally**, one frame at a time as audio
/// arrives, and cached. Re-running the VAD over the whole pending buffer on
/// every incoming packet is O(buffer) per packet — and since the buffer grows to
/// 14 seconds, that cost climbs until it stalls whatever thread it runs on.
final class LiveChunker {
    /// Don't emit anything shorter than this — too little context to decode well.
    private let minChunkSeconds: Double = 1.2
    /// Force a cut at this length even mid-speech, so live text keeps flowing.
    private let maxChunkSeconds: Double = 14.0
    /// Trailing quiet required before we treat the utterance as finished.
    private let trailingSilenceSeconds: Double = 0.45

    private let sampleRate: Double = AudioResampler.targetSampleRate
    private let frameSeconds: Double = 0.1
    private let frameSamples: Int

    private let vad: EnergyVAD

    /// Audio not yet emitted.
    private var buffer: [Float] = []
    /// One flag per complete frame at the head of `buffer`.
    private var flags: [Bool] = []
    /// Samples at the head of `buffer` already covered by `flags`.
    private var analyzedSamples = 0
    /// Absolute sample offset of `buffer[0]` since the recording started.
    private var bufferStartSample = 0

    init() {
        frameSamples = Int(frameSeconds * sampleRate)
        vad = EnergyVAD(
            sampleRate: Int(AudioResampler.targetSampleRate),
            frameLength: Float(frameSeconds),
            energyThreshold: 0.022
        )
    }

    struct Chunk {
        let samples: [Float]
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Appends samples and returns any chunks that are ready to transcribe.
    func append(_ samples: [Float]) -> [Chunk] {
        buffer.append(contentsOf: samples)
        analyzeNewFrames()

        var ready: [Chunk] = []
        while let chunk = nextChunk() { ready.append(chunk) }
        return ready
    }

    /// Emits whatever is left, regardless of length. Call on stop.
    func drain() -> Chunk? {
        defer { reset() }
        guard buffer.count >= Int(0.3 * sampleRate) else { return nil }
        return makeChunk(sampleCount: buffer.count)
    }

    // MARK: - Incremental voice activity

    /// Runs the VAD only over frames that have newly completed — O(new samples).
    private func analyzeNewFrames() {
        let unanalyzed = buffer.count - analyzedSamples
        let completeFrames = unanalyzed / frameSamples
        guard completeFrames > 0 else { return }

        let start = analyzedSamples
        let end = start + completeFrames * frameSamples
        let slice = Array(buffer[start..<end])

        flags.append(contentsOf: vad.voiceActivity(in: slice))
        analyzedSamples = end
    }

    // MARK: - Cutting

    private func nextChunk() -> Chunk? {
        let minFrames = Int(minChunkSeconds / frameSeconds)
        let maxFrames = Int(maxChunkSeconds / frameSeconds)
        let silenceFrames = Int(trailingSilenceSeconds / frameSeconds)

        guard flags.count >= minFrames else { return nil }

        if flags.count >= maxFrames {
            return cut(atFrame: maxFrames)
        }
        guard flags.count > silenceFrames else { return nil }

        // Only cut if the *tail* is silent — mid-utterance pauses shouldn't split.
        guard flags.suffix(silenceFrames).allSatisfy({ !$0 }) else { return nil }

        let speechFrames = flags.count - silenceFrames
        // All silence: drop it rather than hand Whisper a blank window.
        guard flags.prefix(speechFrames).contains(true) else {
            discardAnalyzed()
            return nil
        }
        guard speechFrames >= minFrames else { return nil }
        return cut(atFrame: speechFrames)
    }

    /// Cuts on a frame boundary so `buffer` and `flags` stay aligned.
    private func cut(atFrame frameCount: Int) -> Chunk {
        let sampleCount = min(buffer.count, frameCount * frameSamples)
        let chunk = makeChunk(sampleCount: sampleCount)

        buffer.removeFirst(sampleCount)
        flags.removeFirst(min(flags.count, frameCount))
        analyzedSamples = max(0, analyzedSamples - sampleCount)
        bufferStartSample += sampleCount
        return chunk
    }

    /// Throws away analysed silence without emitting it.
    private func discardAnalyzed() {
        let sampleCount = min(buffer.count, flags.count * frameSamples)
        buffer.removeFirst(sampleCount)
        flags.removeAll(keepingCapacity: true)
        analyzedSamples = max(0, analyzedSamples - sampleCount)
        bufferStartSample += sampleCount
    }

    private func reset() {
        bufferStartSample += buffer.count
        buffer.removeAll(keepingCapacity: true)
        flags.removeAll(keepingCapacity: true)
        analyzedSamples = 0
    }

    private func makeChunk(sampleCount: Int) -> Chunk {
        Chunk(
            samples: Array(buffer[0..<sampleCount]),
            start: Double(bufferStartSample) / sampleRate,
            end: Double(bufferStartSample + sampleCount) / sampleRate
        )
    }
}
