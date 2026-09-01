import SwiftUI

/// One row of a `HeaderMenu`.
///
/// A described list rather than a `@ViewBuilder`, because the menu draws the
/// rows itself: it needs to know which are selectable to move a highlight
/// through them with the arrow keys, which a closure full of arbitrary views
/// cannot tell it.
struct HeaderMenuItem: Identifiable {
    enum Kind {
        case action
        case destructive
        case separator
        /// A heading over the rows beneath it.
        case section
        /// A line of text where rows would be — "No models downloaded".
        case info
    }

    let id = UUID()
    var title: String = ""
    var systemImage: String?
    var kind: Kind = .action
    var isEnabled: Bool = true
    var action: () -> Void = {}

    var isSelectable: Bool {
        switch kind {
        case .action, .destructive: return isEnabled
        case .separator, .section, .info: return false
        }
    }

    static func action(
        _ title: String,
        systemImage: String? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> Self {
        Self(title: title, systemImage: systemImage, kind: .action,
             isEnabled: isEnabled, action: action)
    }

    static func section(_ title: String) -> Self {
        Self(title: title, kind: .section)
    }

    static func info(_ title: String) -> Self {
        Self(title: title, kind: .info)
    }

    static func destructive(
        _ title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> Self {
        Self(title: title, systemImage: systemImage, kind: .destructive, isEnabled: isEnabled, action: action)
    }

    static var separator: Self {
        Self(kind: .separator)
    }
}

/// A dropdown drawn by the app rather than by AppKit.
///
/// SwiftUI's `Menu` is an `NSMenu`, which is the one surface in the app that
/// cannot be styled — no say over its font, row height, corner radius or
/// colour. Beside a capsule chip set in the app's own type, a stock menu looks
/// borrowed. This wears `ActionChip` for its trigger and the same surface and
/// shadow as the app's other floating layers.
///
/// What it gives up, honestly: an `NSMenu` can extend past the window's edge and
/// flips itself when it would run off the bottom of the screen. This panel lives
/// in the view tree and is trapped inside the window, so it suits a short list
/// near the top of a pane — which is what the header menus are — and not a long
/// one near the bottom.
///
/// Keyboard: arrows move the highlight, Return chooses, Escape closes. Those
/// come free from `NSMenu` and are most of what is lost by leaving it, so they
/// are written back rather than skipped.
struct HeaderMenu: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var isBusy: Bool = false
    var isEnabled: Bool = true
    var help: String = ""
    let items: [HeaderMenuItem]

    @State private var isOpen = false
    @State private var isHovering = false
    @State private var highlighted: UUID?
    /// Frames in window coordinates, for deciding whether a click landed
    /// outside the menu.
    @State private var panelFrame: CGRect = .zero
    @State private var triggerFrame: CGRect = .zero
    @State private var monitor: Any?

    private static let gap: CGFloat = 6

    var body: some View {
        Button {
            setOpen(!isOpen)
        } label: {
            ActionChip(
                title: title,
                systemImage: systemImage,
                tint: tint,
                isBusy: isBusy,
                showsMenuIndicator: true,
                isHovering: isHovering || isOpen,
                isEnabled: isEnabled
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { triggerFrame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in triggerFrame = frame }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isOpen {
                panel
                    // Zero-height frame anchored to its top, so the panel hangs
                    // below the trigger without occupying any layout space —
                    // the same trick the tooltip uses to sit above one.
                    .frame(height: 0, alignment: .top)
                    .offset(y: Self.gap)
            }
        }
        // Otherwise the controls after this one in the row draw over the panel.
        .zIndex(isOpen ? 2 : 0)
        .onChange(of: isOpen) { _, open in
            if open { startWatching() } else { stopWatching() }
        }
        .onDisappear(perform: stopWatching)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                row(item)
            }
        }
        .padding(5)
        .frame(minWidth: 180, alignment: .leading)
        .background(Theme.content, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        // Outside the background, not on the filled shape. It was glass that
        // could not have a shadow — anything opaque behind it to cast one is
        // what the blur would then sample. On a solid surface the two are no
        // longer in tension, which is the trade this makes.
        .shadow(color: .black.opacity(0.20), radius: 14, y: 6)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { panelFrame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, frame in panelFrame = frame }
            }
        }
        .fixedSize()
        // Anchored at the top, so it unfolds from the button rather than
        // fading in over it.
        .transition(
            .scale(scale: 0.94, anchor: .top)
                .combined(with: .opacity)
                .combined(with: .offset(y: -4))
        )
    }

    @ViewBuilder
    private func row(_ item: HeaderMenuItem) -> some View {
        switch item.kind {
        case .separator:
            Divider().opacity(0.5).padding(.vertical, 3)

        case .section:
            Text(item.title.uppercased())
                .font(Theme.Font.label)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)

        case .info:
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)

        case .action, .destructive:
            let isHighlighted = highlighted == item.id

            Button {
                choose(item)
            } label: {
                HStack(spacing: 8) {
                    if let systemImage = item.systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 14, alignment: .leading)
                    }
                    Text(item.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 12)
                }
                .foregroundStyle(foreground(item))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHighlighted ? highlight(item) : .clear)
                }
                .contentShape(Rectangle())
                // On the label's own content, not on the `Button` around it.
                // A plain-styled button hands its tracking area to its label,
                // so hover attached to the button never fires — the same trap
                // that kept the tooltip from ever appearing.
                //
                // Drives the very highlight the arrow keys move, so mouse and
                // keyboard never disagree about which row is current.
                .onHover { hovering in
                    guard item.isSelectable else { return }
                    if hovering {
                        highlighted = item.id
                    } else if highlighted == item.id {
                        highlighted = nil
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!item.isEnabled)
        }
    }

    private func foreground(_ item: HeaderMenuItem) -> some ShapeStyle {
        guard item.isEnabled else { return AnyShapeStyle(.tertiary) }
        if case .destructive = item.kind { return AnyShapeStyle(Theme.recording) }
        return AnyShapeStyle(.primary)
    }


    private func highlight(_ item: HeaderMenuItem) -> Color {
        if case .destructive = item.kind { return Theme.recording.opacity(0.14) }
        return Color.primary.opacity(0.08)
    }

    private func choose(_ item: HeaderMenuItem) {
        setOpen(false)
        item.action()
    }

    /// Every open and close goes through here.
    ///
    /// The panel's transition only plays inside an animated transaction, and a
    /// bare `isOpen = false` from a key handler or a click monitor is not one —
    /// the menu would appear with a flourish and then vanish instantly.
    private func setOpen(_ open: Bool) {
        withAnimation(.smooth(duration: 0.16)) { isOpen = open }
    }

    // MARK: - Dismissal and keys

    /// Watches for the clicks and keys an `NSMenu` would have handled itself.
    private func startWatching() {
        highlighted = nil
        stopWatching()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                return handle(key: event)
            }
            // A click inside the panel is the panel's own business, and a click
            // on the trigger belongs to the button, which toggles. Anything
            // else closes the menu.
            //
            // The trigger has to be excluded or clicking it while open does
            // nothing visible: this monitor closes the menu on mouse-down, then
            // the button's action fires on mouse-up and toggles it straight
            // back open.
            //
            // Testing the panel rather than closing unconditionally matters for
            // the same reason in reverse — closing on mouse-down would mean its
            // rows never see the mouse-up that fires them.
            let location = point(of: event)
            if !panelFrame.contains(location), !triggerFrame.contains(location) {
                setOpen(false)
            }
            return event
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// SwiftUI's global space has its origin at the top left of the window's
    /// content; an event's is at the bottom left. Hence the flip.
    private func point(of event: NSEvent) -> CGPoint {
        guard let content = event.window?.contentView else { return .zero }
        let location = event.locationInWindow
        return CGPoint(x: location.x, y: content.bounds.height - location.y)
    }

    private func handle(key event: NSEvent) -> NSEvent? {
        let selectable = items.filter(\.isSelectable)
        guard !selectable.isEmpty else { return event }

        switch event.keyCode {
        case 53:                                        // Escape
            setOpen(false)
            return nil
        case 125, 126:                                  // Down, Up
            let step = event.keyCode == 125 ? 1 : -1
            let current = selectable.firstIndex { $0.id == highlighted }
            let next = current.map { ($0 + step + selectable.count) % selectable.count }
                ?? (step > 0 ? 0 : selectable.count - 1)
            highlighted = selectable[next].id
            return nil
        case 36, 76:                                    // Return, Enter
            if let item = selectable.first(where: { $0.id == highlighted }) {
                choose(item)
                return nil
            }
            return event
        default:
            return event
        }
    }
}
