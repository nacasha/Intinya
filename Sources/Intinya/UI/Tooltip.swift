import SwiftUI

/// A hover label, drawn in the view tree.
///
/// Three approaches, and the reasons the first two failed are why this looks the
/// way it does:
///
/// * `.help()` never fired. These are `.plain` buttons whose label installs its
///   own `onHover`, and that tracking area owns the mouse, so AppKit never
///   installs its tooltip on the button.
/// * A `.popover` was visible but ate clicks. An `NSPopover` becomes the key
///   window, so the first click on the control it describes only dismisses the
///   popover — the button underneath never sees it.
///
/// An overlay has neither problem, and it was only unusable earlier because
/// hover was being read from the wrong view. Now that the control owns its own
/// hover state and passes it in, the label can be a plain overlay that does not
/// participate in hit testing at all.
struct Tooltip: ViewModifier {
    let text: String
    /// Driven by the caller's own hover state, since the only reliable source is
    /// the innermost view that draws the control — see `BarButton`, where the
    /// same flag already drives the hover fill.
    let isHovering: Bool
    var edge: VerticalEdge = .top

    private static let gap: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if isHovering, !text.isEmpty {
                    label
                        // Zero-height frame, anchored so the label hangs off it.
                        //
                        // Positioning this with `.alignmentGuide` looked right on
                        // paper and did nothing in practice — the guide never
                        // took, and the label sat centred on the control it was
                        // meant to sit beside. A zero-height frame needs no guide
                        // to cooperate: the frame contributes nothing to the
                        // layout, and the label extends out of it in the one
                        // direction the anchor allows.
                        .frame(height: 0, alignment: edge == .top ? .bottom : .top)
                        .offset(y: edge == .top ? -Self.gap : Self.gap)
                }
            }
            // Otherwise the next control in the row draws over the label.
            .zIndex(isHovering ? 1 : 0)
    }

    private var label: some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            // Sized to the text and exempt from the parent's width, so a long
            // value does not stretch the control it is describing.
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.content)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            }
            // The whole point: a label that describes a control must never come
            // between the pointer and that control.
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.smooth(duration: 0.12), value: isHovering)
    }
}

extension View {
    /// Shows `text` while `isHovering`. An empty string shows nothing.
    func tooltip(_ text: String, isHovering: Bool, edge: VerticalEdge = .top) -> some View {
        modifier(Tooltip(text: text, isHovering: isHovering, edge: edge))
    }
}
