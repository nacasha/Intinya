import SwiftUI

/// Plain markdown editing for a session's notes.
///
/// No toolbar: the save state moved to the panel header, and a preview toggle
/// was overhead for what is a scratchpad during a meeting. Markdown still
/// renders wherever notes are read back — the AI summary panel, and export.
struct NotesView: View {
    @ObservedObject var document: NotesDocument
    let hasSession: Bool
    /// How tall the editor should be when its text does not fill that much.
    ///
    /// Sized to its content alone, an empty note is a 220pt box with dead space
    /// under it — click below the last line and nothing happens, because there
    /// is no text view there to take the cursor. Filling the pane makes the
    /// whole area what it looks like: somewhere to type.
    var minimumHeight: CGFloat = 220

    @State private var height: CGFloat = 0

    var body: some View {
        Group {
            if hasSession {
                // Grows with its text rather than scrolling itself, so the page
                // it sits on does the scrolling — the same document behaviour
                // the transcript has.
                GrowingTextView(
                    text: $document.text,
                    // The same face and size the transcript is set in. Notes are
                    // prose written beside prose, not code — monospace was a
                    // holdover from treating the file as markdown source rather
                    // than as something you read.
                    font: .systemFont(ofSize: 14),
                    minimumHeight: minimumHeight
                ) { height = $0 }
                .frame(height: height)
                // No horizontal inset: the column's own edge is the margin, so
                // the first character sits on the same line as the title above.
                .padding(.vertical, 12)
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { document.flush() }
    }

    private var unavailable: some View {
        EmptyState(
            systemImage: "note.text",
            title: "Notes attach to a recording",
            detail: "Start recording, and notes save alongside the audio."
        )
    }
}
