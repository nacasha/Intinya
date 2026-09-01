import SwiftUI

/// A top-level destination in the sidebar.
///
/// Exists so the items cannot drift apart: a plain `Label` takes the accent
/// colour for its icon, which is why one entry rendered blue while its
/// neighbours were grey. Every navigation row goes through here.
struct SidebarItem: View {
    /// Fixed so every row's text starts at the same x.
    ///
    /// SF Symbols have different intrinsic widths — `mic.circle` is noticeably
    /// wider than `character.book.closed` — so an unconstrained icon slot makes
    /// each label start somewhere slightly different.
    static let iconWidth: CGFloat = 18

    let title: String
    let systemImage: String
    /// Overrides the icon colour for a live state, e.g. recording.
    var tint: Color?
    /// Trailing count, such as the number of learned terms.
    var badge: String?
    /// Trailing status dot.
    var indicator: Color?

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(title)
                Spacer(minLength: 4)

                if let badge {
                    Text(badge)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                }
                if let indicator {
                    Circle()
                        .fill(indicator)
                        .frame(width: 7, height: 7)
                }
            }
        } icon: {
            Image(systemName: systemImage)
                // A fixed size too, so symbols with different optical weights do
                // not render at different scales.
                .font(.system(size: 12))
                .frame(width: Self.iconWidth, alignment: .center)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
    }
}


/// A pinned navigation row.
///
/// Not a `List` row: the destinations sit above the scrolling recordings, so
/// they cannot live in the same scroll view. This reproduces the selected
/// appearance a `List` would have given them.
struct SidebarNavRow: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var badge: String?
    var indicator: Color?
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SidebarItem(
                title: title,
                systemImage: systemImage,
                tint: isSelected ? .white : tint,
                badge: badge,
                indicator: indicator
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.14), value: isSelected)
    }

    private var background: some ShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0))
    }
}
