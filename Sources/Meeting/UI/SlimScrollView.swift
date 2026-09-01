import SwiftUI

/// The scroll view's coordinate space, so content can ask where it sits
/// relative to the viewport — whether a heading has scrolled past the top, for
/// instance.
///
/// Outside `SlimScrollView` because that type is generic over its content, and
/// a static on a generic cannot be named without also naming the content type.
enum ScrollSpace {
    static let document = "slim-scroll"
}

/// Where a scroller is and how much of the content it covers.
struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewportHeight: CGFloat = 0

    var overflows: Bool { contentHeight > viewportHeight + 1 }
    /// How far the content can travel.
    var travel: CGFloat { max(0, contentHeight - viewportHeight) }
}

/// The scrollbar: a thumb and nothing else.
///
/// No track, no gutter, no border, and no reserved width — it floats over the
/// content, so a reading column is exactly as wide with it as without.
///
/// Draggable. The offset is set through `ScrollController`, which drives the
/// `NSScrollView` underneath: SwiftUI alone has no way to move a `ScrollView`
/// to an arbitrary position — `scrollTo(id:)` cannot express "43% down" — but
/// the AppKit scroll view we already reach for measuring takes a point.
struct ScrollThumbControl: View {
    let metrics: ScrollMetrics
    let controller: ScrollController
    var isVisible: Bool
    var isEmphasised: Bool = false
    /// Called while dragging, so the caller can hold the thumb up.
    var onDragChanged: (Bool) -> Void = { _ in }

    static let width: CGFloat = 5
    static let inset: CGFloat = 4
    /// The grabbable strip. Wider than the thumb, because a 5pt target is a
    /// test of aim rather than a control.
    static let hitWidth: CGFloat = 15
    private static let minimumLength: CGFloat = 32

    @State private var dragOrigin: CGFloat?

    private var track: CGFloat { max(1, metrics.viewportHeight - Self.inset * 2) }

    private var length: CGFloat {
        guard metrics.contentHeight > 0 else { return Self.minimumLength }
        // Proportional to how much of the content is on screen, with a floor so
        // it does not shrink to a dot on a long transcript.
        return max(Self.minimumLength, track * (metrics.viewportHeight / metrics.contentHeight))
    }

    private var progress: CGFloat {
        metrics.travel > 0 ? min(1, max(0, metrics.offset / metrics.travel)) : 0
    }

    var body: some View {
        if metrics.overflows {
            Capsule()
                .fill(Color.primary.opacity(isEmphasised ? 0.34 : 0.22))
                .frame(width: Self.width, height: length)
                .frame(width: Self.hitWidth)
                .contentShape(Rectangle())
                .padding(.trailing, Self.inset)
                .offset(y: Self.inset + progress * (track - length))
                .opacity(isVisible ? 1 : 0)
                .gesture(drag)
                .animation(.smooth(duration: 0.2), value: isVisible)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let origin = dragOrigin ?? metrics.offset
                if dragOrigin == nil {
                    dragOrigin = origin
                    onDragChanged(true)
                }
                // A point of thumb travel is worth more than a point of content
                // travel, by exactly the ratio the thumb was shortened by.
                let usable = max(1, track - length)
                let scale = metrics.travel / usable
                controller.scroll(to: origin + value.translation.height * scale)
            }
            .onEnded { _ in
                dragOrigin = nil
                onDragChanged(false)
            }
    }
}

/// A scroll view wearing `ScrollThumbControl` instead of the system scroller.
struct SlimScrollView<Content: View>: View {
    /// Keeps the thumb up whenever the content overflows, rather than fading.
    var isPersistent: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var metrics = ScrollMetrics()
    @State private var controller = ScrollController()
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var isActive = false
    @State private var token = 0

    private var isVisible: Bool {
        metrics.overflows && (isPersistent || isActive || isHovering || isDragging)
    }

    var body: some View {
        ScrollView {
            content()
                // Inside the content, not on the ScrollView: only a view within
                // the document has the scroll view as an ancestor to find.
                .background {
                    ScrollBridge(controller: controller) { new in
                        let moved = abs(new.offset - metrics.offset) > 0.5
                        metrics = new
                        if moved { flash() }
                    }
                }
        }
        // `.never`, not `.hidden`: `.hidden` still lets the system reveal the
        // indicator while scrolling, which is a second scrollbar beside ours.
        .scrollIndicators(.never)
        .coordinateSpace(name: ScrollSpace.document)
        .overlay(alignment: .topTrailing) {
            ScrollThumbControl(
                metrics: metrics,
                controller: controller,
                isVisible: isVisible,
                isEmphasised: isHovering || isDragging,
                onDragChanged: { isDragging = $0 }
            )
        }
        .onHover { isHovering = $0 }
    }

    /// Shows the thumb for a moment after the content moves.
    private func flash() {
        isActive = true
        token &+= 1
        let current = token
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard current == token else { return }
            isActive = false
        }
    }
}
