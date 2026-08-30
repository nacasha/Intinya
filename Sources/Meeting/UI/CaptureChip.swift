import SwiftUI

/// The small status chips along the bottom of the record screen.
///
/// Shared for the same reason the sidebar rows are: the model, track, screen and
/// type chips had each grown their own copy of this styling, which is how they
/// drift apart.
struct CaptureChip: View {
    let title: String
    let systemImage: String
    /// Nil is the resting grey; a colour marks the chip as live.
    var tint: Color?
    var isEnabled: Bool = true
    var showsMenuIndicator: Bool = false
    var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
            Text(title)
                .font(Theme.Font.label)
                .tracking(0.6)
                .lineLimit(1)
            if showsMenuIndicator {
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
                    .opacity(0.55)
            }
        }
        .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill((tint ?? .primary).opacity(fill))
        }
        .overlay {
            Capsule().stroke((tint ?? .primary).opacity(tint == nil ? 0.06 : 0.3), lineWidth: 1)
        }
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.smooth(duration: 0.18), value: isHovering)
        .animation(.smooth(duration: 0.25), value: tint != nil)
    }

    private var fill: Double {
        if tint != nil { return isHovering ? 0.22 : 0.16 }
        return isHovering ? 0.10 : 0.05
    }
}

/// A chip that opens a menu.
struct CaptureChipMenu<Content: View>: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var isEnabled: Bool = true
    var help: String = ""
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            CaptureChip(
                title: title,
                systemImage: systemImage,
                tint: tint,
                isEnabled: isEnabled,
                showsMenuIndicator: true,
                isHovering: isHovering
            )
        }
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
