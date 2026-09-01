import Foundation

/// A recorded meeting on disk.
///
/// A session is a directory holding `mic.wav`, `system.wav`, and — once the
/// recording stops — `transcript.json`. Sessions recorded before transcript
/// persistence existed still load; they just have audio and no text.
struct Session: Identifiable, Hashable {
    /// The directory name, which is also the timestamp.
    let id: String
    let directory: URL
    let recordedAt: Date
    let duration: TimeInterval
    let segmentCount: Int
    /// Generated from the transcript. Absent until an AI pass has run.
    let title: String?
    let hasTranscript: Bool
    let isEnhanced: Bool
    let hasNotes: Bool
    let keyframeCount: Int
    let hasVideo: Bool
    let sectionCount: Int
    let typeID: UUID?
    /// Whether either track carries audible sound.
    let hasAudio: Bool
    /// First words of the transcript, for the library cards.
    let preview: String
    /// Lowercased haystack for the sidebar filter.
    let searchText: String

    /// What the row shows.
    ///
    /// A timestamp says *when* and never *what*, which is useless once there are
    /// dozens of recordings — so a generated title wins when one exists. The day
    /// is already the section header, so the fallback is just the time.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return Self.timeFormatter.string(from: recordedAt)
    }

    /// Full date and time, for the detail header.
    var fullTitle: String {
        Self.titleFormatter.string(from: recordedAt)
    }

    /// Captured nothing at all.
    ///
    /// Not judged on length: a four-minute recording that transcribed nothing is
    /// as empty as a four-second one. But it *is* judged on whether sound was
    /// actually captured — a recording with audio and no transcript still has
    /// something in it, and can be transcribed later.
    var isEmpty: Bool {
        !hasTranscript
            && !hasNotes
            && sectionCount == 0
            && keyframeCount == 0
            && !hasVideo
            // Audio that was never transcribed is still worth keeping — the
            // transcript can be produced later with Enhance. Only a recording
            // that captured nothing at all is genuinely empty.
            && !hasAudio
    }

    var day: Date {
        Calendar.current.startOfDay(for: recordedAt)
    }

    /// Deliberately short. Four facts crammed into one grey line is not
    /// scannable; the rest are shown as icons instead.
    var subtitle: String {
        hasTranscript
            ? "\(duration.clockString) · \(segmentCount) lines"
            : "\(duration.clockString) · no transcript"
    }

    /// Secondary attributes, as symbols.
    var markers: [String] {
        var symbols: [String] = []
        if hasVideo { symbols.append("video") }
        else if keyframeCount > 0 { symbols.append("photo.stack") }
        if sectionCount > 0 { symbols.append("text.insert") }
        if hasNotes { symbols.append("note.text") }
        if isEnhanced { symbols.append("checkmark.seal.fill") }
        return symbols
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// "Today" / "Yesterday" / "25 Aug" for a section header.
    static func dayLabel(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(day, equalTo: .now, toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
        )
        return formatter.string(from: day)
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// What gets written to `transcript.json`.
struct SessionTranscript: Codable {
    var segments: [TranscriptSegment]
    var recordedAt: Date
    var duration: TimeInterval
    /// Short label generated from the transcript.
    var title: String?
    var liveModel: String?
    var enhancedModel: String?
    /// Screen stills, when the session was recorded with keyframe capture.
    var keyframes: [ScreenCapture.Keyframe]?
    var screenMode: ScreenCaptureMode?
    /// What actually recorded this, for the same reason the model names are
    /// kept: months later, "why is this track quiet" is answered by knowing
    /// which mic and which app it came from. Optional, so transcripts written
    /// before source selection existed still decode.
    var micDevice: String?
    var systemAudioSource: String?
    var sections: [MeetingSection]?
    var typeID: UUID?

    var isEnhanced: Bool {
        !segments.isEmpty && segments.allSatisfy { $0.tier >= .enhanced }
    }
}
