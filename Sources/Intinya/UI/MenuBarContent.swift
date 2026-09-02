import SwiftUI

/// The status item's menu — the one place recording can be driven without the
/// main window being frontmost, so it carries the full transport (start, stop,
/// pause, resume) rather than just the start/stop toggle.
struct MenuBarContent: View {
    @EnvironmentObject private var recorder: Recorder
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        transport
        Text(status)

        Divider()
        session

        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private var transport: some View {
        Button(recorder.isRecording ? "Stop Recording" : "Start Recording") {
            recorder.toggleRecording()
        }
        .disabled(!recorder.isModelReady)
        .keyboardShortcut("r")

        // Pause only exists mid-session; Recorder.togglePause() no-ops
        // otherwise, so the row would be a dead entry when idle.
        if recorder.isRecording {
            Button(recorder.isPaused ? "Resume" : "Pause") {
                recorder.togglePause()
            }
            .keyboardShortcut("p")
        }
    }

    @ViewBuilder
    private var session: some View {
        Button("Open Meeting") {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.showMainWindow()
            } else {
                openWindow(id: "main")
            }
        }
        .keyboardShortcut("o")

        Button("Reveal Recordings") {
            guard let url = recorder.activeDirectory else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        // activeDirectory, not currentSessionDirectory: the latter empties when
        // a session ends, which is exactly when you want to go look at it.
        .disabled(recorder.activeDirectory == nil)
    }

    /// One line, matching the badge on the icon: elapsed time while a session
    /// is live, and otherwise whatever is stopping one from starting.
    private var status: String {
        if recorder.isRecording {
            let clock = recorder.monitor.elapsed.clockString
            return recorder.isPaused ? "Paused · \(clock)" : "Recording · \(clock)"
        }
        if !recorder.missingPermissions.isEmpty {
            let list = recorder.missingPermissions.map(\.rawValue).joined(separator: " and ")
            return "Needs \(list) access"
        }
        return recorder.status
    }
}
