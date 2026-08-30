import Foundation

/// Free-form markdown kept alongside a recording, as `notes.md`.
///
/// Plain markdown on disk rather than a field inside `transcript.json`: notes
/// are the part of a session a person writes by hand, and they should stay
/// readable and editable without this app.
enum Notes {

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("notes.md")
    }

    static func load(in directory: URL) -> String {
        (try? String(contentsOf: url(in: directory), encoding: .utf8)) ?? ""
    }

    static func exists(in directory: URL) -> Bool {
        let path = url(in: directory).path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return !load(in: directory).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @discardableResult
    static func save(_ text: String, in directory: URL) -> Bool {
        let target = url(in: directory)
        // An emptied note removes the file rather than leaving a stub behind.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try? FileManager.default.removeItem(at: target)
            return true
        }
        return (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil
    }
}
