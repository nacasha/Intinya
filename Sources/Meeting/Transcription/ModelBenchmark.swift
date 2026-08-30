import Foundation

/// A measurement taken on *this* machine — the only speed number worth trusting,
/// since realtime factor depends entirely on the chip.
struct BenchmarkResult: Codable, Equatable {
    let model: WhisperModel
    /// Seconds of audio processed per second of wall clock. >1 beats realtime.
    let realtimeFactor: Double
    /// Word error rate against the reference sentence, 0...1. Lower is better.
    let wordErrorRate: Double
    let loadSeconds: Double
    let transcribeSeconds: Double
    let transcript: String
    let audioSeconds: Double

    /// Live transcription needs headroom, not a bare pass: chunks keep arriving
    /// from two tracks while the previous one is still decoding.
    var liveVerdict: LiveSuitability {
        if realtimeFactor >= 3.0 { return .comfortable }
        if realtimeFactor >= 1.4 { return .marginal }
        return .tooSlow
    }

    var accuracyPercent: Int { Int((1.0 - wordErrorRate) * 100) }
}

enum ModelBenchmark {

    /// Loads the model, transcribes a synthetic Indonesian sample, and measures
    /// both speed and accuracy.
    ///
    /// The accuracy figure is measured on clean synthesised speech, so it is an
    /// optimistic ceiling — real meeting audio (crosstalk, room noise, phone
    /// compression) will always score worse. It is useful for *ranking* models
    /// against each other, not as an absolute promise.
    static func run(
        model: WhisperModel,
        sample: SpeechSample.Sample,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> BenchmarkResult {

        progress?("Loading \(model.displayName)…")
        let engine = TranscriptionEngine(model: model)
        let loadStart = Date()
        try await engine.load()
        let loadSeconds = Date().timeIntervalSince(loadStart)

        progress?("Transcribing sample…")
        let start = Date()
        let text = try await engine.transcribe(samples: sample.samples) ?? ""
        let transcribeSeconds = Date().timeIntervalSince(start)

        await engine.unload()

        let rtf = transcribeSeconds > 0 ? sample.duration / transcribeSeconds : 0
        let wer = wordErrorRate(reference: sample.reference, hypothesis: text)

        return BenchmarkResult(
            model: model,
            realtimeFactor: rtf,
            wordErrorRate: wer,
            loadSeconds: loadSeconds,
            transcribeSeconds: transcribeSeconds,
            transcript: text,
            audioSeconds: sample.duration
        )
    }

    // MARK: - Word error rate

    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let ref = normalize(reference)
        let hyp = normalize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        let distance = levenshtein(ref, hyp)
        return min(1.0, Double(distance) / Double(ref.count))
    }

    /// Lowercases, strips punctuation, and collapses whitespace so that
    /// "di-fix." and "difix" aren't counted as different errors than they are.
    private static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func levenshtein(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
