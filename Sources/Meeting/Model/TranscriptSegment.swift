import Foundation

/// Which capture track a segment came from.
///
/// Keeping mic and system audio as separate tracks is what gives us speaker
/// attribution for free — no diarization model required.
enum AudioSource: String, Codable, Hashable, CaseIterable {
    case mic
    case system

    var label: String {
        switch self {
        case .mic: return "You"
        case .system: return "Them"
        }
    }
}

/// Which pass produced the text. Tier 1 lands fast and rough; tier 2 replaces it
/// in place once the accurate model catches up.
enum TranscriptTier: Int, Codable, Comparable {
    case live = 0
    case enhanced = 1
    case polished = 2

    static func < (lhs: TranscriptTier, rhs: TranscriptTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable {
    let id: UUID
    let source: AudioSource
    /// Seconds from the start of the recording.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var tier: TranscriptTier

    init(
        id: UUID = UUID(),
        source: AudioSource,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        tier: TranscriptTier = .live
    ) {
        self.id = id
        self.source = source
        self.start = start
        self.end = end
        self.text = text
        self.tier = tier
    }

    var duration: TimeInterval { max(0, end - start) }

    /// Used to decide which enhanced window a live segment belongs to.
    var midpoint: TimeInterval { start + duration / 2 }
}
