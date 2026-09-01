import SwiftUI

/// Every control that sits in a bottom bar.
///
/// The bars had grown four shapes for the same idea: 40pt capsules for the
/// capture chips, 34pt circles for play and screen, and text capsules with their
/// own padding for Record and Pause. Nothing about those controls differs except
/// whether they carry a label and how loud they are, so they are one component
/// with two variants rather than four implementations.
///
/// Height is fixed for all of them, which is what makes a bar read as one row
/// rather than as buttons of assorted sizes sharing a capsule.
struct BarButton: View {
    let systemImage: String
    /// Nil for icon-only. The value belongs in `tooltip` in that case.
    var title: String? = nil
    /// Nil is the resting grey; a colour marks the control as live.
    var tint: Color?
    /// Filled in the tint rather than washed with it — for the one primary
    /// action in a bar, and for a state that is currently active.
    var isProminent: Bool = false
    var isEnabled: Bool = true
    var showsMenuIndicator: Bool = false
    var tooltip: String = ""
    let action: () -> Void

    @State private var isHovering = false

    static let height: CGFloat = 40

    var body: some View {
        Button(action: action) { chip }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .onHover { isHovering = $0 }
            .tooltip(tooltip, isHovering: isHovering && isEnabled)
    }

    private var chip: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: title == nil ? 13 : 12, weight: .semibold))

            if let title {
                Text(title)
                    .font(Theme.Font.title)
                    .lineLimit(1)
                    // Without this the label wraps a character per line as soon
                    // as the bar runs short of room.
                    .fixedSize()
            }

            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, title == nil ? 0 : 18)
        // Icon-only chips are square, so they read as circles rather than as
        // labelled buttons that lost their label.
        .frame(minWidth: title == nil ? Self.height : 0)
        .frame(height: Self.height)
        .background { Capsule().fill(background) }
        .overlay { Capsule().stroke(border, lineWidth: 1) }
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .animation(.smooth(duration: 0.18), value: isHovering)
        .animation(.smooth(duration: 0.22), value: isProminent)
    }

    private var foreground: some ShapeStyle {
        if isProminent { return AnyShapeStyle(.white) }
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(.secondary)
    }

    private var background: Color {
        if isProminent { return tint ?? .accentColor }
        let base = tint ?? .primary
        let opacity = tint == nil
            ? (isHovering ? 0.10 : 0.05)
            : (isHovering ? 0.24 : 0.16)
        return base.opacity(opacity)
    }

    private var border: Color {
        if isProminent { return .clear }
        return (tint ?? .primary).opacity(tint == nil ? 0.07 : 0.30)
    }
}
