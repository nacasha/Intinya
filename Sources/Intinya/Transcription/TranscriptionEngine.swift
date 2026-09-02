import Foundation
import Qwen3ASR
import WhisperKit

/// Runs whichever backend the chosen model needs — WhisperKit for the Whisper
/// family, speech-swift for Qwen3-ASR — behind one interface, so the recorder,
/// enhanced pass, and benchmark never care which family is active.
///
/// For Whisper, three settings matter more than the choice of model:
///
/// 1. `language: "id"` is pinned and `detectLanguage` is off. Whisper detects
///    language per 30-second window, so with auto-detect a code-switched meeting
///    flips to `en` mid-conversation and back. That flip is what produces
///    garbage — pinning to Indonesian transcribes embedded English words in place.
/// 2. `task: .transcribe` is forced. Under `.translate` Whisper silently renders
///    Indonesian speech as English text: the app looks like it works and the
///    transcript is wrong.
/// 3. `promptTokens` seeds the decoder with code-switched Indonesian so English
///    technical terms keep their English spelling.
///
/// Qwen3-ASR gets the same treatment through different levers: the language is
/// pinned via its prompt (full names, not ISO codes), and the glossary goes in
/// as plain `context` text — no token budget games required.
actor TranscriptionEngine {
    private var whisperKit: WhisperKit?
    private var qwen: Qwen3ASRModel?
    private(set) var model: WhisperModel
    private var glossary: Glossary
    private var cachedPromptTokens: [Int]?

    enum State: Equatable {
        case idle
        case loading(String)
        case ready
        case failed(String)
    }

    init(model: WhisperModel, glossary: Glossary = .default) {
        self.model = model
        self.glossary = glossary
    }

    var isLoaded: Bool { whisperKit != nil || qwen != nil }

    /// Downloads (first run only) and loads the model into memory.
    func load(progress: (@Sendable (String) -> Void)? = nil) async throws {
        guard !isLoaded else { return }

        progress?("Loading \(model.displayName)…")
        switch model.family {
        case .whisper:
            let config = WhisperKitConfig(
                model: model.rawValue,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            whisperKit = kit
            cachedPromptTokens = Self.promptTokens(for: glossary, tokenizer: kit.tokenizer)
        case .qwen:
            qwen = try await Qwen3ASRModel.fromPretrained(
                modelId: model.rawValue,
                progressHandler: { _, message in progress?(message) }
            )
        }
        progress?("Ready")
    }

    func unload() {
        whisperKit = nil
        qwen = nil
        cachedPromptTokens = nil
    }

    func updateGlossary(_ glossary: Glossary) {
        self.glossary = glossary
        cachedPromptTokens = Self.promptTokens(for: glossary, tokenizer: whisperKit?.tokenizer)
    }

    /// Transcribes a chunk of 16 kHz mono audio. Returns nil when the decoder
    /// produced nothing usable.
    func transcribe(samples: [Float]) async throws -> String? {
        let text: String
        switch model.family {
        case .whisper:
            guard let whisperKit else { return nil }
            let results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: decodingOptions()
            )
            text = results.map(\.text).joined(separator: " ")
        case .qwen:
            guard let qwen else { return nil }
            return qwenTranscribe(qwen, samples: samples)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.isUsable(trimmed) ? trimmed : nil
    }

    /// Transcribes a window and returns timestamped segments, shifted by
    /// `offset` so they line up with the recording as a whole.
    ///
    /// Used by the enhanced pass, which needs timestamps to know which live
    /// segments a window replaces.
    func transcribeTimed(samples: [Float], offset: TimeInterval) async throws -> [TimedText] {
        switch model.family {
        case .whisper:
            guard let whisperKit else { return [] }
            let results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: decodingOptions(chunked: true)
            )
            return results
                .flatMap(\.segments)
                .compactMap { segment in
                    let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard Self.isUsable(text) else { return nil }
                    return TimedText(
                        start: offset + Double(segment.start),
                        end: offset + Double(segment.end),
                        text: text
                    )
                }
        case .qwen:
            guard let qwen else { return [] }
            // Qwen3-ASR emits no timestamps, so timing comes from slicing the
            // window ourselves: cut at the quietest moment near each target
            // boundary and stamp each slice with its position in the window.
            // Coarser than Whisper's per-sentence segments, but the enhanced
            // pass only needs to know which live segments a span replaces.
            let sampleRate = Int(AudioResampler.targetSampleRate)
            var segments: [TimedText] = []
            for slice in Self.quietSplit(samples: samples, sampleRate: sampleRate) {
                guard let text = qwenTranscribe(qwen, samples: Array(samples[slice])) else { continue }
                segments.append(TimedText(
                    start: offset + Double(slice.lowerBound) / Double(sampleRate),
                    end: offset + Double(slice.upperBound) / Double(sampleRate),
                    text: text
                ))
            }
            return segments
        }
    }

    // MARK: - Qwen decoding

    /// Full language name, not an ISO code — Qwen3-ASR's prompt format is
    /// literally "language Indonesian". Pinned for the same reason Whisper's
    /// `language: "id"` is: auto-detect flips on code-switched meetings.
    private static let qwenLanguage = "Indonesian"

    /// The glossary as decoder context — the bare term list, not Whisper's
    /// narrative preamble. Qwen parrots its context back over silence, and a
    /// parroted natural-language preamble reads exactly like transcript; a
    /// parroted term list is caught by `isContextEcho`. The cap just keeps a
    /// runaway glossary from crowding the decode.
    private func qwenContext() -> String? {
        let text = glossary.termList()
        guard !text.isEmpty else { return nil }
        return String(text.prefix(600))
    }

    /// One Qwen decode plus the output filters both call sites need.
    private func qwenTranscribe(_ qwen: Qwen3ASRModel, samples: [Float]) -> String? {
        let context = qwenContext()
        let text = qwen.transcribe(
            audio: samples,
            sampleRate: Int(AudioResampler.targetSampleRate),
            language: Self.qwenLanguage,
            context: context
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isUsable(text), !Self.isContextEcho(text, context: context) else { return nil }
        return text
    }

    /// True when the output is the biasing context read back, not speech.
    ///
    /// The tell is order: someone in a meeting may *say* several glossary
    /// terms, but only an echo reproduces eight of them in the context's
    /// exact sequence.
    static func isContextEcho(_ text: String, context: String?) -> Bool {
        guard let context else { return false }

        func words(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }

        let outputWords = words(text)
        let runLength = 8
        // Below the run length, isUsable's checks are all we can do — a short
        // echo is indistinguishable from the terms genuinely being spoken.
        guard outputWords.count >= runLength else { return false }

        let haystack = " " + words(context).joined(separator: " ") + " "
        for start in 0...(outputWords.count - runLength) {
            let run = " " + outputWords[start..<(start + runLength)].joined(separator: " ") + " "
            if haystack.contains(run) { return true }
        }
        return false
    }

    /// Slices a long window into ~28 s spans, cutting at the quietest 0.3 s
    /// frame within ±3 s of each target boundary so cuts land between words.
    /// 28 s keeps every slice under the model's 30 s training horizon.
    static func quietSplit(samples: [Float], sampleRate: Int) -> [Range<Int>] {
        let target = 28 * sampleRate
        let search = 3 * sampleRate
        let frame = sampleRate / 3

        var slices: [Range<Int>] = []
        var start = 0
        while samples.count - start > target + search {
            let ideal = start + target
            var quietest = ideal
            var lowest = Float.greatestFiniteMagnitude
            var candidate = ideal - search
            while candidate + frame <= ideal + search {
                var energy: Float = 0
                for sample in samples[candidate..<(candidate + frame)] {
                    energy += sample * sample
                }
                if energy < lowest {
                    lowest = energy
                    quietest = candidate + frame / 2
                }
                candidate += frame
            }
            slices.append(start..<quietest)
            start = quietest
        }
        if start < samples.count {
            slices.append(start..<samples.count)
        }
        return slices
    }

    private func decodingOptions(chunked: Bool = false) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,           // never .translate — see class docs
            language: "id",              // pinned; no per-window flipping
            temperature: 0.0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: !chunked,
            promptTokens: cachedPromptTokens,
            // Slightly stricter than default: Indonesian hallucinations tend to
            // be highly repetitive, which shows up as a low compression ratio.
            compressionRatioThreshold: 2.2,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            chunkingStrategy: chunked ? .vad : nil
        )
    }

    private static func promptTokens(for glossary: Glossary, tokenizer: WhisperTokenizer?) -> [Int]? {
        guard let tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + glossary.promptText())
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        // Whisper reserves roughly half its 448-token context for the prompt.
        // Overflowing it crowds out the audio window, so trim hard.
        return Array(tokens.suffix(200))
    }

    /// Filters out the stock phrases Whisper emits over silence.
    private static func isUsable(_ text: String) -> Bool {
        guard text.count > 1 else { return false }
        let normalized = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let hallucinations: Set<String> = [
            "terima kasih", "terima kasih telah menonton",
            "terima kasih sudah menonton", "sampai jumpa",
            "subtitle by", "silakan berlangganan",
            "thank you", "thanks for watching", "you",
        ]
        if hallucinations.contains(normalized) { return false }
        // A "word" repeated more than 4x in a row is a decoder loop.
        let words = normalized.split(separator: " ")
        if words.count > 4, Set(words).count == 1 { return false }
        return true
    }
}

/// A timestamped fragment of transcript, relative to the start of the recording.
struct TimedText: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}
