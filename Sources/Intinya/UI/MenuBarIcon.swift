import AppKit

/// The status item's icon: always a waveform, badged with a red dot while
/// recording and a yellow one while paused.
///
/// Drawn as an `NSImage` rather than composed as a SwiftUI label because
/// `MenuBarExtra` flattens its label into a template image — every pixel is
/// repainted with the menu bar's foreground colour, so a coloured dot arrives
/// black. Turning the template flag off keeps the colour, at the cost of
/// tinting the waveform ourselves; the unbadged icon stays a template so it
/// still inverts against the highlight when the menu is open.
enum MenuBarIcon {

    enum Badge {
        case none
        case recording
        case paused

        var color: NSColor? {
            switch self {
            case .none: nil
            case .recording: .systemRed
            case .paused: .systemYellow
            }
        }

        var label: String {
            switch self {
            case .none: "Intinya"
            case .recording: "Recording"
            case .paused: "Recording paused"
            }
        }
    }

    /// Wide enough to hold the badge, so the waveform does not shift sideways
    /// when recording starts.
    private static let size = NSSize(width: 20, height: 16)
    private static let dotDiameter: CGFloat = 6.5
    /// Clear ring punched around the dot so it reads as a badge rather than as
    /// another peak of the waveform.
    private static let dotGap: CGFloat = 1.5

    static func image(recording: Bool, paused: Bool) -> NSImage {
        image(badge: recording ? (paused ? .paused : .recording) : .none)
    }

    static func image(badge: Badge) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            guard let symbol else { return true }

            let rect = fit(symbol.size, into: NSRect(
                x: 0,
                y: 0,
                width: size.width - dotDiameter / 2,
                height: size.height))
            symbol.draw(in: rect)

            if let color = badge.color {
                // labelColor resolves against whatever appearance the menu bar
                // is drawing in, so this tracks light/dark like a template
                // image would.
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                drawBadge(color)
            }
            return true
        }
        image.isTemplate = badge.color == nil
        image.accessibilityDescription = badge.label
        return image
    }

    private static var symbol: NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        return NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private static func drawBadge(_ color: NSColor) {
        let dot = NSRect(
            x: size.width - dotDiameter,
            y: size.height - dotDiameter,
            width: dotDiameter,
            height: dotDiameter)

        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: dot.insetBy(dx: -dotGap, dy: -dotGap)).fill()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// Aspect-preserving centre fit, so a symbol swap cannot stretch the icon.
    private static func fit(_ size: NSSize, into bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let scaled = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(
            x: bounds.minX + (bounds.width - scaled.width) / 2,
            y: bounds.minY + (bounds.height - scaled.height) / 2,
            width: scaled.width,
            height: scaled.height)
    }
}
