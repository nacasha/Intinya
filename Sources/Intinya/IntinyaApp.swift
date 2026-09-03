import SwiftUI

/// Keeps the app alive when the main window closes — and, crucially, keeps the
/// window itself alive so it can come back.
///
/// Returning false from `applicationShouldTerminateAfterLastWindowClosed` stops
/// a closed window from killing an in-progress recording. On its own, though, it
/// strands the app: the process keeps running with zero windows, clicking the
/// Dock icon does nothing, and `open` on an already-running app is a no-op. The
/// app looks blank because there is genuinely nothing on screen.
///
/// So the close button hides the window instead of destroying it, and reopening
/// brings the same window back.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Resolve the login-shell environment now, in the background. Otherwise
        // the first AI action pays for spawning a shell inline, mid-meeting.
        Task.detached(priority: .utility) {
            _ = ShellEnvironment.current()
        }

        // The scene's window exists by the next runloop pass.
        DispatchQueue.main.async { [weak self] in
            self?.adoptMainWindow()
        }
    }

    private func adoptMainWindow() {
        guard mainWindow == nil else { return }
        // The MenuBarExtra also owns a window; take the real one.
        mainWindow = NSApp.windows.first { $0.canBecomeMain && $0.contentView != nil }
        mainWindow?.delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Hide rather than close, so the window can be restored intact.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// Dock click, or `open` on the running app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        adoptMainWindow()
        guard let window = mainWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct IntinyaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = Recorder()
    @StateObject private var modelStore = ModelStore()
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var glossaryStore = GlossaryStore()
    @StateObject private var meetingTypeStore = MeetingTypeStore()
    @StateObject private var activityCenter = ActivityCenter()
    @StateObject private var glossaryIndex = GlossaryIndex()
    // App-level, so the library is indexed once and survives leaving the search
    // screen — a fresh index on every visit is a re-read of every transcript.
    @StateObject private var searchIndex = SearchIndex()

    var body: some Scene {
        Window("Intinya", id: "main") {
            RootView()
                .environmentObject(recorder)
                .environmentObject(modelStore)
                .environmentObject(sessionStore)
                .environmentObject(glossaryStore)
                .environmentObject(meetingTypeStore)
                .environmentObject(activityCenter)
                .environmentObject(glossaryIndex)
                .environmentObject(searchIndex)
                // The chips, sidebar rows and transcript controls are all custom
                // shapes, so AppKit's focus ring lands as a rounded rectangle
                // that traces none of them. Set once here rather than per
                // button: this reads through the environment, so it covers
                // sheets and anything added later.
                .focusEffectDisabled()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        // Recording controls shouldn't require the main window to be frontmost.
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(recorder)
        } label: {
            Image(nsImage: MenuBarIcon.image(recording: recorder.isRecording, paused: recorder.isPaused))
        }
        .menuBarExtraStyle(.menu)
    }
}
