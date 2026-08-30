import SwiftUI

/// Shared look for the actions across the top of a recording.
///
/// A `Menu` and a `Button` are different controls with different default
/// chrome, which is why the AI dropdown never matched its neighbours. Both now
/// wear the same chip, so the row reads as one set.
private struct ActionChip: View {
    let title: String
    let systemImage: String
    /// Nil is the neutral treatment; a colour marks a primary action.
    var tint: Color?
    var isBusy: Bool = false
    var showsMenuIndicator: Bool = false
    var isHovering: Bool
    var isEnabled: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 11, height: 11)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }

            Text(title)
                .font(Theme.Font.caption)
                .fontWeight(.medium)

            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule().fill(background)
        }
        .overlay {
            Capsule().stroke(border, lineWidth: 1)
        }
        .contentShape(Capsule())
        // Understated: these sit next to the recording title, so they should
        // respond without competing with it.
        .scaleEffect(isHovering && isEnabled ? 1.03 : 1)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.smooth(duration: 0.18), value: isHovering)
        .animation(.smooth(duration: 0.18), value: isBusy)
    }

    private var foreground: some ShapeStyle {
        guard let tint else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(tint)
    }

    private var background: Color {
        let base = tint ?? .primary
        let opacity = tint == nil
            ? (isHovering ? 0.11 : 0.06)
            : (isHovering ? 0.20 : 0.13)
        return base.opacity(isEnabled ? opacity : opacity * 0.6)
    }

    private var border: Color {
        (tint ?? .primary).opacity(tint == nil ? 0.09 : 0.28)
    }
}

/// A single action.
struct HeaderAction: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var isBusy: Bool = false
    var isEnabled: Bool = true
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ActionChip(
                title: title,
                systemImage: systemImage,
                tint: tint,
                isBusy: isBusy,
                isHovering: isHovering,
                isEnabled: isEnabled
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// A dropdown wearing the same chip as `HeaderAction`.
struct HeaderActionMenu<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var isBusy: Bool = false
    var isEnabled: Bool = true
    var help: String = ""
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            ActionChip(
                title: title,
                systemImage: systemImage,
                tint: tint,
                isBusy: isBusy,
                showsMenuIndicator: true,
                isHovering: isHovering,
                isEnabled: isEnabled
            )
        }
        // `.button` + `.plain` is what actually strips the Menu's own bezel;
        // `.borderlessButton` still draws chrome around the label, which is why
        // this control kept looking different from the buttons beside it.
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
