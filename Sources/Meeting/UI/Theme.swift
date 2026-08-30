import SwiftUI

/// A small, deliberate design system. Default-everything is what makes SwiftUI
/// apps look generic — a real type ramp and a two-accent palette is most of the
/// distance to looking designed.
enum Theme {
    /// Mic track — warm. "You".
    static let mic = Color(red: 0.98, green: 0.62, blue: 0.31)
    /// System track — cool. "Them".
    static let system = Color(red: 0.42, green: 0.71, blue: 0.98)
    static let recording = Color(red: 0.98, green: 0.36, blue: 0.38)

    static func accent(for source: AudioSource) -> Color {
        source == .mic ? mic : system
    }

    enum Font {
        static let display = SwiftUI.Font.system(size: 34, weight: .semibold, design: .rounded)
        static let timer = SwiftUI.Font.system(size: 44, weight: .medium, design: .rounded)
            .monospacedDigit()
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 14, weight: .regular)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
            .monospacedDigit()
        static let label = SwiftUI.Font.system(size: 10, weight: .bold)
    }

    static let corner: CGFloat = 14
}

extension TimeInterval {
    /// Built by hand rather than with `String(format:)`, which goes through
    /// varargs and a format parser. That is irrelevant once, and very much not
    /// irrelevant once per transcript line per render pass.
    var clockString: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        var out = ""
        out.reserveCapacity(8)
        if hours > 0 {
            out += String(hours)
            out.append(":")
            out.appendPadded(minutes)
        } else {
            out.appendPadded(minutes)
        }
        out.append(":")
        out.appendPadded(seconds)
        return out
    }
}

private extension String {
    /// Two digits, zero-padded. Only ever called with 0...59.
    mutating func appendPadded(_ value: Int) {
        if value < 10 { append("0") }
        append(String(value))
    }
}
