import CoreAudio
import CoreGraphics
import Foundation

/// An input device that can feed the microphone track.
///
/// `uid` is what gets persisted, never `id`: `AudioDeviceID` is assigned by
/// CoreAudio at enumeration time and is not stable across a reboot or a replug,
/// so storing it would silently point at a different device later.
struct MicDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// Input channels. Zero means the device cannot actually be recorded — an
    /// aggregate or virtual device that advertises a sample rate but exposes no
    /// input. Filtered out at enumeration rather than discovered by failing.
    let channels: Int
}

/// What the system-audio track should listen to.
///
/// Deliberately separate from `ScreenTarget`: screen capture runs its own
/// `SCStream` so that the screen target cannot dictate the audio filter, and the
/// same separation is what lets this be chosen independently.
struct SystemAudioSource: Identifiable, Hashable, Codable {
    enum Kind: Hashable, Codable {
        /// Everything audible on the display — the original behaviour.
        case systemWide
        /// One application, plus its helper processes.
        case app(bundleID: String)
        case window(CGWindowID)
    }

    let kind: Kind
    let title: String
    let subtitle: String

    var id: String {
        switch kind {
        case .systemWide: return "system-wide"
        case .app(let bundleID): return "app-\(bundleID)"
        case .window(let id): return "window-\(id)"
        }
    }

    static let systemWide = SystemAudioSource(
        kind: .systemWide,
        title: "All system audio",
        subtitle: "Everything the machine plays"
    )

    var isSystemWide: Bool {
        if case .systemWide = kind { return true }
        return false
    }

    var systemImage: String {
        switch kind {
        case .systemWide: return "speaker.wave.3"
        case .app: return "app.badge"
        case .window: return "macwindow"
        }
    }

    /// Whether a running application belongs to this source.
    ///
    /// Chromium and Electron apps play audio from a *helper* process, not the
    /// process that owns the window — `com.google.Chrome.helper.renderer` rather
    /// than `com.google.Chrome`. Matching the parent alone is why per-app capture
    /// records silence on Chrome, Slack, Discord, Teams and VS Code, which is
    /// most of the apps a meeting actually runs in. Helpers namespace themselves
    /// under the parent bundle ID, so a prefix match collects them.
    func matches(bundleID candidate: String) -> Bool {
        guard case .app(let bundleID) = kind else { return false }
        return candidate == bundleID || candidate.hasPrefix(bundleID + ".")
    }
}
