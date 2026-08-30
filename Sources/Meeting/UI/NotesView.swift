import SwiftUI

/// Plain markdown editing for a session's notes.
///
/// No toolbar: the save state moved to the panel header, and a preview toggle
/// was overhead for what is a scratchpad during a meeting. Markdown still
/// renders wherever notes are read back — the AI summary panel, and export.
struct NotesView: View {
    @ObservedObject var document: NotesDocument
    let hasSession: Bool

    var body: some View {
        Group {
            if hasSession {
                TextEditor(text: $document.text)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { document.flush() }
    }

    private var unavailable: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Notes attach to a recording")
                .font(Theme.Font.title)
                .foregroundStyle(.secondary)
            Text("Start recording, and notes save alongside the audio.")
                .font(Theme.Font.body)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
