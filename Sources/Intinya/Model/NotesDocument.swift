import Foundation
import SwiftUI

/// The notes for one session, and when they were last written.
///
/// The save state lives here rather than inside the editor so the panel header
/// can show it — a status line inside the editor competes with the writing area
/// for the same space.
@MainActor
final class NotesDocument: ObservableObject {

    @Published var text: String = "" {
        didSet { if text != lastWritten { scheduleSave() } }
    }
    @Published private(set) var savedAt: Date?

    private var directory: URL?
    private var lastWritten: String = ""
    private var saveTask: Task<Void, Never>?

    /// Long enough not to write on every keystroke, short enough that quitting
    /// shortly after typing keeps the text.
    private static let debounce: Duration = .milliseconds(600)

    var savedLabel: String? {
        savedAt.map { "saved \($0.formatted(date: .omitted, time: .shortened))" }
    }

    /// Points at a session, flushing whatever the previous one had pending.
    func load(_ directory: URL?) {
        guard directory != self.directory else { return }
        flush()

        self.directory = directory
        savedAt = nil
        let loaded = directory.map { Notes.load(in: $0) } ?? ""
        lastWritten = loaded
        text = loaded
    }

    /// Re-reads from disk, discarding the in-memory copy.
    ///
    /// The AI actions append a summary to `notes.md` behind this document's
    /// back. Without a reload the stale text stays on screen and the next
    /// keystroke writes it back over the summary.
    func reload() {
        guard let directory else { return }
        saveTask?.cancel()
        saveTask = nil
        let loaded = Notes.load(in: directory)
        lastWritten = loaded
        text = loaded
        savedAt = Date()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = text
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.write(snapshot) }
        }
    }

    /// Writes immediately — for pane switches, teardown, and session changes.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard text != lastWritten else { return }
        write(text)
    }

    private func write(_ snapshot: String) {
        guard let directory else { return }
        Notes.save(snapshot, in: directory)
        lastWritten = snapshot
        savedAt = Date()
    }
}
