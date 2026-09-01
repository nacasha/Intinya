import SwiftUI

/// A plain-text editor that grows with its content instead of scrolling.
///
/// `TextEditor` is an `NSScrollView` and always scrolls itself, which is why
/// the notes page behaved unlike the transcript: the heading stayed pinned
/// while the text moved underneath it, and the page had two scrollers with
/// different ideas about where the top was. An editor with no scroller of its
/// own can sit inside the document's scroll view, so heading and text move
/// together and one thumb covers the whole page.
///
/// A bare `NSTextView`, deliberately — not one inside an `NSScrollView`. Height
/// is reported back so SwiftUI can give it the room its text needs.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    /// Keeps an empty note a big enough target to click into.
    var minimumHeight: CGFloat = 220
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.font = font
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.autoresizingMask = [.width]
        view.string = text
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            // Only when the value genuinely differs: assigning `string` resets
            // the insertion point, so doing it on every update would fight the
            // cursor on every keystroke.
            view.string = text
        }
        if view.font != font { view.font = font }
        context.coordinator.reportHeight(of: view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        private var lastHeight: CGFloat = 0

        init(_ parent: GrowingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            reportHeight(of: view)
        }

        func reportHeight(of view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height
            let height = max(parent.minimumHeight, ceil(used) + 4)
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            // Out of the current layout pass: reporting a size change from
            // inside one is what SwiftUI warns about, and it can loop.
            DispatchQueue.main.async { [parent] in parent.onHeightChange(height) }
        }
    }
}
