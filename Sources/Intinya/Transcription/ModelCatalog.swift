import Foundation

/// How good the transcript is expected to be on Indonesian, before measuring.
///
/// These are *expectations* derived from model size and family — the authoritative
/// number is the one the on-device benchmark measures for you.
enum AccuracyGrade: Int, Comparable, Codable {
    case unusable = 0
    case poor = 1
    case workable = 2
    case good = 3
    case veryGood = 4
    case excellent = 5

    static func < (l: AccuracyGrade, r: AccuracyGrade) -> Bool { l.rawValue < r.rawValue }

    var label: String {
        switch self {
        case .unusable: return "Unusable"
        case .poor: return "Poor"
        case .workable: return "Workable"
        case .good: return "Good"
        case .veryGood: return "Very good"
        case .excellent: return "Excellent"
        }
    }
}

/// Whether the model can keep up with a live meeting.
enum LiveSuitability: Int, Codable {
    case comfortable   // clears realtime with headroom to spare
    case marginal      // roughly keeps up; falls behind when both tracks are busy
    case tooSlow       // enhanced pass only

    var label: String {
        switch self {
        case .comfortable: return "Good for live"
        case .marginal: return "Marginal for live"
        case .tooSlow: return "Enhanced pass only"
        }
    }
}

/// The multilingual WhisperKit CoreML variants.
///
/// Every `.en` variant and the whole `distil-whisper` family are deliberately
/// absent: Distil-Whisper is an English-only distillation and the `.en` models
/// are English-only by construction. Both produce garbage on Indonesian, so
/// offering them would just be a trap.
///
/// Naming, which is genuinely confusing in this repo:
///   * `large-v3-v20240930` **is** OpenAI's large-v3-turbo (pruned decoder,
///     ~half the size of large-v3). Still fully multilingual.
///   * A trailing `_turbo` is WhisperKit's own ANE-optimised encoder packaging.
///     It is *not* a smaller model — `large-v3_turbo` is slightly larger than
///     `large-v3`. It buys speed, not disk.
///   * A trailing `_NNNMB` is a quantised build: much smaller and faster, with
///     some accuracy given up.
enum WhisperModel: String, CaseIterable, Identifiable, Codable, Hashable {
    case tiny = "openai_whisper-tiny"
    case base = "openai_whisper-base"
    case smallQuantized = "openai_whisper-small_216MB"
    case small = "openai_whisper-small"
    case medium = "openai_whisper-medium"
    case turboQuantized547 = "openai_whisper-large-v3-v20240930_547MB"
    case turboQuantized626 = "openai_whisper-large-v3-v20240930_626MB"
    case turbo = "openai_whisper-large-v3-v20240930"
    case turboANE = "openai_whisper-large-v3-v20240930_turbo"
    case largeV3Quantized = "openai_whisper-large-v3_947MB"
    case largeV3 = "openai_whisper-large-v3"
    case largeV3ANE = "openai_whisper-large-v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .base: return "Base"
        case .smallQuantized: return "Small (compressed)"
        case .small: return "Small"
        case .medium: return "Medium"
        case .turboQuantized547: return "Large v3 Turbo (547MB)"
        case .turboQuantized626: return "Large v3 Turbo (626MB)"
        case .turbo: return "Large v3 Turbo"
        case .turboANE: return "Large v3 Turbo (ANE)"
        case .largeV3Quantized: return "Large v3 (compressed)"
        case .largeV3: return "Large v3"
        case .largeV3ANE: return "Large v3 (ANE)"
        }
    }

    /// Real download size, measured from the model repo.
    var downloadMB: Int {
        switch self {
        case .tiny: return 77
        case .base: return 147
        case .smallQuantized: return 217
        case .small: return 486
        case .medium: return 1530
        case .turboQuantized547: return 550
        case .turboQuantized626: return 627
        case .turbo: return 1620
        case .turboANE: return 1638
        case .largeV3Quantized: return 948
        case .largeV3: return 3090
        case .largeV3ANE: return 3195
        }
    }

    var expectedAccuracy: AccuracyGrade {
        switch self {
        case .tiny: return .unusable
        case .base: return .poor
        case .smallQuantized: return .workable
        case .small: return .workable
        case .medium: return .good
        case .turboQuantized547: return .good
        case .turboQuantized626: return .veryGood
        case .turbo, .turboANE: return .veryGood
        case .largeV3Quantized: return .veryGood
        case .largeV3, .largeV3ANE: return .excellent
        }
    }

    var expectedLive: LiveSuitability {
        switch self {
        case .tiny, .base, .smallQuantized, .small: return .comfortable
        // Measured, not estimated: Large v3 Turbo 626MB runs at 6.3x realtime on
        // Apple Silicon — comfortably live. The earlier "marginal" rating here
        // was a guess from model size, and benchmarking disproved it.
        case .turboQuantized547, .turboQuantized626: return .comfortable
        case .medium, .turbo, .turboANE: return .marginal
        case .largeV3Quantized, .largeV3, .largeV3ANE: return .tooSlow
        }
    }

    var isQuantized: Bool {
        rawValue.hasSuffix("MB")
    }

    /// Honest one-liner, including where the model actively fails.
    var note: String {
        switch self {
        case .tiny:
            return "Too small for Indonesian — output is mostly wrong. Listed for completeness only."
        case .base:
            return "Still below the Indonesian threshold. Drops affixes and mangles most English terms."
        case .smallQuantized:
            return "Compressed Small. Same speed class, slightly rougher than Small. Good when disk is tight."
        case .small:
            return "The practical floor for Indonesian, and the fastest model worth using live."
        case .medium:
            return "Clearly better Indonesian than Small. Handles code-switching more reliably."
        case .turboQuantized547:
            return "Compressed Large v3 Turbo. Punches well above its size; the value pick."
        case .turboQuantized626:
            return "Best overall pick. Measured at 6.3x realtime — accurate enough for the enhanced pass, fast enough for live."
        case .turbo:
            return "OpenAI's large-v3-turbo — pruned decoder, fully multilingual. The default enhanced pass."
        case .turboANE:
            return "Large v3 Turbo with WhisperKit's ANE-optimised encoder. Same accuracy, faster, slightly larger."
        case .largeV3Quantized:
            return "Compressed Large v3. Near-full accuracy at a third of the disk."
        case .largeV3:
            return "Highest accuracy available. Too slow for live; use it for the enhanced pass."
        case .largeV3ANE:
            return "Large v3 with ANE-optimised encoder. Fastest way to run full Large v3."
        }
    }

    /// Models that are actively harmful to pick, surfaced but flagged.
    var isRecommended: Bool {
        expectedAccuracy >= .workable
    }

    /// Human-readable size. Formatted explicitly because SwiftUI applies locale
    /// digit grouping to a bare `Int`, which renders 3090 MB as "3.090 MB" —
    /// indistinguishable from 3.09 MB.
    var sizeLabel: String { Self.sizeLabel(megabytes: downloadMB) }

    static func sizeLabel(megabytes: Int) -> String {
        megabytes >= 1000
            ? String(format: "%.1f GB", Double(megabytes) / 1000.0)
            : "\(megabytes) MB"
    }

    /// Large v3 Turbo 626MB rather than Small: it measured 6.3x realtime, which
    /// clears live comfortably, and live transcription is accuracy-bound rather
    /// than speed-bound on Apple Silicon.
    static let defaultLive: WhisperModel = .turboQuantized626
    static let defaultEnhanced: WhisperModel = .turboQuantized626

    /// Ordered smallest-first so the picker reads as a ramp.
    static var catalog: [WhisperModel] {
        allCases.sorted { $0.downloadMB < $1.downloadMB }
    }
}
