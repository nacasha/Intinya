import CoreGraphics
import Foundation

/// What, if anything, to capture from the screen alongside the audio.
enum ScreenCaptureMode: String, CaseIterable, Identifiable, Codable {
    case off
    case keyframes
    case video

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "No screen"
        case .keyframes: return "Keyframes"
        case .video: return "Video"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "Audio only."
        case .keyframes:
            return "A still each time the screen changes. Best for slides — small, and every frame is one click from the transcript."
        case .video:
            return "Continuous recording. Use for demos and anything where motion matters. Larger files, and encoding competes with live transcription."
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "rectangle.slash"
        case .keyframes: return "photo.stack"
        case .video: return "video"
        }
    }
}

/// What to point the capture at.
struct ScreenTarget: Identifiable, Hashable {
    enum Kind: Hashable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
    }

    let kind: Kind
    let title: String
    let subtitle: String

    var id: String {
        switch kind {
        case .display(let id): return "display-\(id)"
        case .window(let id): return "window-\(id)"
        }
    }

    var isWindow: Bool {
        if case .window = kind { return true }
        return false
    }
}
