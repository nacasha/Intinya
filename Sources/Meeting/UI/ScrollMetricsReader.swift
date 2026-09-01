import SwiftUI

/// Moves an `NSScrollView` on the thumb's behalf.
///
/// SwiftUI cannot express this: a `ScrollView` has no settable offset, and
/// `scrollTo(id:)` cannot say "43% down". The AppKit scroll view underneath
/// takes a point, and we already have a handle on it from measuring.
final class ScrollController {
    weak var scrollView: NSScrollView?

    func scroll(to y: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let limit = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(limit, max(0, y))))
        // Without this the clip view moves but the scroll view does not notice,
        // so nothing that depends on the offset updates.
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Connects SwiftUI to the `NSScrollView` beneath a scrollable view: reports its
/// position, hands the controller a reference, and turns off its own scroller.
///
/// `TextEditor` and `ScrollView` are both `NSScrollView` underneath, with no
/// SwiftUI-visible offset. Rather than reimplement either as an
/// `NSViewRepresentable`, this rides along — a zero-size view that walks up to
/// the enclosing scroll view and watches its clip view.
///
/// Must be placed *within* the scrolling content. A background on the scroll
/// view itself is a sibling layer, with no scroll view above it to find.
///
/// Deliberately quiet on failure. If the hierarchy is not what we expect it
/// reports nothing, the thumb never appears, and scrolling still works normally
/// — a missing indicator, not a crash or a misplaced one.
struct ScrollBridge: NSViewRepresentable {
    let controller: ScrollController
    let onChange: (ScrollMetrics) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onChange: onChange)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Next runloop: until this returns the view is not in a window, and so
        // has no ancestors to walk.
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.attach(from: nsView)
        context.coordinator.report()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        let controller: ScrollController
        var onChange: (ScrollMetrics) -> Void
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        init(controller: ScrollController, onChange: @escaping (ScrollMetrics) -> Void) {
            self.controller = controller
            self.onChange = onChange
        }

        func attach(from view: NSView) {
            guard let found = view.enclosingScrollView else { return }

            // Re-applied even when already attached: SwiftUI rebuilds the
            // scroller on some layout passes, and a one-shot setting does not
            // survive that.
            //
            // `.scrollIndicators(.never)` does not cover this. It governs
            // SwiftUI's overlay indicator, not the AppKit scroller, and when the
            // system shows scroll bars always — or decides to, because a mouse
            // is attached — that scroller is *legacy* style and reserves a
            // channel of width beside the content instead of floating over it.
            found.hasVerticalScroller = false
            found.scrollerStyle = .overlay
            found.autohidesScrollers = true

            guard found !== scrollView else { return }
            detach()
            scrollView = found
            controller.scrollView = found

            let clip = found.contentView
            clip.postsBoundsChangedNotifications = true
            found.postsFrameChangedNotifications = true

            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.report() })
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: found, queue: .main
            ) { [weak self] _ in self?.report() })

            report()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            scrollView = nil
        }

        func report() {
            guard let scrollView, let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            onChange(ScrollMetrics(
                offset: max(0, clip.bounds.origin.y),
                contentHeight: document.frame.height,
                viewportHeight: clip.bounds.height
            ))
        }
    }
}

extension View {
    /// Replaces an AppKit scroller with a draggable `ScrollThumbControl`.
    ///
    /// For `TextEditor` and anything else that scrolls itself. Pair with
    /// `.scrollIndicators(.never)`.
    func slimScrollbar() -> some View {
        modifier(SlimScrollbar())
    }
}

private struct SlimScrollbar: ViewModifier {
    @State private var metrics = ScrollMetrics()
    @State private var controller = ScrollController()
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var isActive = false
    @State private var token = 0

    private var isVisible: Bool {
        metrics.overflows && (isActive || isHovering || isDragging)
    }

    func body(content: Content) -> some View {
        content
            .background {
                ScrollBridge(controller: controller) { new in
                    // Only a move should flash the thumb. A resize changes the
                    // metrics too, and flashing on every window drag would put
                    // a scrollbar on screen for something the user is not doing.
                    let moved = abs(new.offset - metrics.offset) > 0.5
                    metrics = new
                    if moved { flash() }
                }
            }
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
