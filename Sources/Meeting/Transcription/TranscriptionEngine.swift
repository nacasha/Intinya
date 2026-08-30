import Foundation
import WhisperKit

/// Wraps WhisperKit with the decoding configuration this app depends on.
///
/// Three settings here matter more than the choice of model:
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
actor TranscriptionEngine {
    private var whisperKit: WhisperKit?
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

    var isLoaded: Bool { whisperKit != nil }

    /// Downloads (first run only) and loads the model into memory.
    func load(progress: (@Sendable (String) -> Void)? = nil) async throws {
        guard whisperKit == nil else { return }

        progress?("Loading \(model.displayName)…")
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
        progress?("Ready")
    }

    func unload() {
        whisperKit = nil
        cachedPromptTokens = nil
    }

    func updateGlossary(_ glossary: Glossary) {
        self.glossary = glossary
        cachedPromptTokens = Self.promptTokens(for: glossary, tokenizer: whisperKit?.tokenizer)
    }

    /// Transcribes a chunk of 16 kHz mono audio. Returns nil when the decoder
    /// produced nothing usable.
    func transcribe(samples: [Float]) async throws -> String? {
        guard let whisperKit else { return nil }

        let results = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: decodingOptions()
        )
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return Self.isUsable(text) ? text : nil
    }

    /// Transcribes a window and returns timestamped segments, shifted by
    /// `offset` so they line up with the recording as a whole.
    ///
    /// Used by the enhanced pass, which needs timestamps to know which live
    /// segments a window replaces.
    func transcribeTimed(samples: [Float], offset: TimeInterval) async throws -> [TimedText] {
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
