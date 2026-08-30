import Foundation
import SwiftUI

/// Enumerates, loads, and deletes recorded sessions.
@MainActor
final class SessionStore: ObservableObject {

    @Published private(set) var sessions: [Session] = []
    @Published private(set) var lastError: String?

    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting/Sessions", isDirectory: true)
    }

    init() {
        // Scanning happens off the main thread — see refresh().
        refresh()
    }

    // MARK: - Listing

    /// Rescans the sessions directory off the main thread.
    ///
    /// Describing a session opens both WAVs and parses its transcript JSON. Done
    /// synchronously from `init()` — which runs during `@StateObject` setup,
    /// before SwiftUI creates the scene — that work blocks the first frame, and
    /// the cost grows with every recording made.
    func refresh() {
        // Coalesced: a single AI action can trigger several writes, and each one
        // used to kick off a full rescan of every recording.
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let scanned = await Task.detached(priority: .userInitiated) { Self.scan() }.value
            guard !Task.isCancelled else { return }
            self?.sessions = scanned
        }
    }

    private var pendingRefresh: Task<Void, Never>?

    nonisolated private static func scan() -> [Session] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(describe)
            .sorted { $0.recordedAt > $1.recordedAt }   // newest first
    }

    nonisolated private static func describe(_ directory: URL) -> Session? {
        let fm = FileManager.default
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")

        // A session needs at least one audio track to be worth listing.
        guard fm.fileExists(atPath: micURL.path) || fm.fileExists(atPath: systemURL.path) else {
            return nil
        }

        let transcript = loadTranscript(in: directory)

        // Prefer the recorded timestamp; fall back to the folder's mtime for
        // sessions written before transcripts were persisted.
        let recordedAt = transcript?.recordedAt
            ?? (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date.distantPast

        // Duration from the audio itself, since a transcript may be absent and
        // an interrupted recording's header may understate it.
        let duration = transcript?.duration
            ?? [micURL, systemURL].compactMap { try? WAVReader(url: $0).duration }.max()
            ?? 0

        guard duration > 0.5 else { return nil }

        // Bounded: enough of the transcript to search, without holding every
        // recording's full text in memory.
        let haystack = ([
            transcript?.title,
            directory.lastPathComponent,
        ].compactMap { $0 }
            + (transcript?.segments.prefix(120).map(\.text) ?? [])
            + [Notes.load(in: directory).prefix(2000).description])
            .joined(separator: " ")
            .lowercased()

        return Session(
            id: directory.lastPathComponent,
            directory: directory,
            recordedAt: recordedAt,
            duration: duration,
            segmentCount: transcript?.segments.count ?? 0,
            title: transcript?.title,
            hasTranscript: transcript != nil && !(transcript?.segments.isEmpty ?? true),
            isEnhanced: transcript?.isEnhanced ?? false,
            hasNotes: Notes.exists(in: directory),
            keyframeCount: transcript?.keyframes?.count ?? 0,
            hasVideo: fm.fileExists(atPath: directory.appendingPathComponent("screen.mov").path),
            sectionCount: transcript?.sections?.count ?? 0,
            typeID: transcript?.typeID,
            hasAudio: AudioProbe.hasAudio(in: directory),
            preview: (transcript?.segments.prefix(4).map(\.text).joined(separator: " ") ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .prefix(220)
                .description,
            searchText: haystack
        )
    }

    // MARK: - Transcript I/O

    nonisolated static func transcriptURL(in directory: URL) -> URL {
        directory.appendingPathComponent("transcript.json")
    }

    /// Assigns a type to a saved session.
    nonisolated static func setType(_ typeID: UUID?, in directory: URL) {
        guard var transcript = loadTranscript(in: directory) else { return }
        transcript.typeID = typeID
        saveTranscript(transcript, in: directory)
    }

    nonisolated static func loadTranscript(in directory: URL) -> SessionTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionTranscript.self, from: data)
    }

    @discardableResult
    nonisolated static func saveTranscript(_ transcript: SessionTranscript, in directory: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(transcript) else { return false }
        return (try? data.write(to: transcriptURL(in: directory), options: .atomic)) != nil
    }

    // MARK: - Mutation

    func delete(_ session: Session) {
        do {
            try FileManager.default.removeItem(at: session.directory)
            refresh()
        } catch {
            lastError = "Could not delete recording: \(error.localizedDescription)"
        }
    }

    func reveal(_ session: Session) {
        NSWorkspace.shared.activateFileViewerSelecting([session.directory])
    }

    /// Plain-text export, mostly so a transcript can leave the app at all.
    func exportText(_ session: Session) -> String {
        guard let transcript = Self.loadTranscript(in: session.directory) else { return "" }
        return transcript.segments
            .sorted { $0.start < $1.start }
            .map { "[\($0.start.clockString)] \($0.source.label): \($0.text)" }
            .joined(separator: "\n")
    }
}
