import Foundation

/// A named division inside a single recording — one ticket, one agenda item.
///
/// Timestamps are **recording-relative**, matching the audio, not wall clock.
/// That distinction matters once pause exists: paused time is never written to
/// the WAV, so anything measured against the clock would drift out of sync with
/// the audio it is supposed to label.
struct MeetingSection: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    /// Seconds from the start of the recording.
    var start: TimeInterval

    init(id: UUID = UUID(), title: String, start: TimeInterval) {
        self.id = id
        self.title = title
        self.start = start
    }
}

extension Array where Element == MeetingSection {
    var chronological: [MeetingSection] {
        sorted { $0.start < $1.start }
    }

    /// The section a moment belongs to.
    func section(at time: TimeInterval) -> MeetingSection? {
        chronological.last { $0.start <= time }
    }
}
