import SwiftUI

/// One section of a vertical accordion.
struct AccordionPanel: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var badge: String?
    var accent: Color = .secondary
    let content: () -> AnyView

    init(
        id: String,
        title: String,
        systemImage: String,
        badge: String? = nil,
        accent: Color = .secondary,
        @ViewBuilder content: @escaping () -> some View
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.accent = accent
        self.content = { AnyView(content()) }
    }
}

/// Vertically stacked, individually collapsible, resizable panels.
///
/// Not `VSplitView`: that gives resizing for free but behaves badly when its
/// children appear and disappear, which is exactly what collapsing does here.
///
/// Sizes are stored as **weights**, not pixels, so the split survives window
/// resizing — a pixel height that made sense in a tall window would swallow a
/// short one.
struct AccordionStack: View {
    let panels: [AccordionPanel]
    /// Persistence key; expansion and weights are remembered per usage site.
    let storageKey: String

    @State private var expanded: Set<String> = []
    @State private var weights: [String: CGFloat] = [:]
    @State private var loaded = false

    private let headerHeight: CGFloat = 34
    private let dividerHeight: CGFloat = 5
    /// A pane never shrinks below this fraction of the flexible space.
    private let minWeight: CGFloat = 0.10

    var body: some View {
        GeometryReader { geometry in
            let available = flexibleSpace(in: geometry.size.height)

            VStack(spacing: 0) {
                ForEach(Array(panels.enumerated()), id: \.element.id) { index, panel in
                    header(panel)

                    if expanded.contains(panel.id) {
                        panel.content()
                            .frame(height: max(0, available * normalizedWeight(panel.id)))
                            .clipped()
                    }

                    if index < panels.count - 1 {
                        divider(above: panel.id, below: panels[index + 1].id, available: available)
                    }
                }

                // Takes up the slack only when every panel is collapsed; with
                // any panel open the content already fills the space.
                Spacer(minLength: 0)
            }
        }
        .onAppear(perform: loadState)
        .onChange(of: expanded) { _, _ in saveState() }
    }

    // MARK: - Header

    private func header(_ panel: AccordionPanel) -> some View {
        let isExpanded = expanded.contains(panel.id)

        return Button {
            withAnimation(.smooth(duration: 0.22)) { toggle(panel.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))

                Image(systemName: panel.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(isExpanded ? AnyShapeStyle(panel.accent) : AnyShapeStyle(.secondary))

                Text(panel.title.uppercased())
                    .font(Theme.Font.label)
                    .tracking(0.7)
                    .foregroundStyle(isExpanded ? AnyShapeStyle(panel.accent) : AnyShapeStyle(.secondary))

                if let badge = panel.badge {
                    Text(badge)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: headerHeight)
            .contentShape(Rectangle())
            .background(.regularMaterial)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Collapse \(panel.title)" : "Expand \(panel.title)")
    }

    // MARK: - Divider

    @ViewBuilder
    private func divider(above: String, below: String, available: CGFloat) -> some View {
        // Only draggable when there is space on both sides to trade.
        let draggable = expanded.contains(above) && expanded.contains(below) && available > 0

        ZStack {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            if draggable {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
            }
        }
        .frame(height: dividerHeight)
        .ifDraggable(draggable) {
            $0.gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        resize(above: above, below: below, by: value.translation.height / available)
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
        }
    }

    private func resize(above: String, below: String, by delta: CGFloat) {
        let a = normalizedWeight(above)
        let b = normalizedWeight(below)
        let total = a + b
        // Clamp so neither side collapses out from under the drag.
        let newA = min(max(minWeight, a + delta), total - minWeight)
        weights[above] = newA
        weights[below] = total - newA
        saveState()
    }

    // MARK: - Sizing

    private func flexibleSpace(in height: CGFloat) -> CGFloat {
        let chrome = CGFloat(panels.count) * headerHeight
            + CGFloat(max(0, panels.count - 1)) * dividerHeight
        return max(0, height - chrome)
    }

    /// Weight of one pane as a fraction of the expanded set.
    private func normalizedWeight(_ id: String) -> CGFloat {
        let expandedIDs = panels.map(\.id).filter { expanded.contains($0) }
        guard expandedIDs.contains(id) else { return 0 }
        let total = expandedIDs.reduce(CGFloat(0)) { $0 + (weights[$1] ?? 1) }
        guard total > 0 else { return 1 / CGFloat(expandedIDs.count) }
        return (weights[id] ?? 1) / total
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
            if weights[id] == nil { weights[id] = 1 }
        }
    }

    // MARK: - Persistence

    private var defaultsKey: String { "accordion.\(storageKey)" }

    private func loadState() {
        guard !loaded else { return }
        loaded = true

        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
            // Drop entries for panels that no longer exist.
            let ids = Set(panels.map(\.id))
            expanded = Set(saved.expanded).intersection(ids)
            weights = saved.weights.filter { ids.contains($0.key) }
        } else {
            // First run only: start with everything open.
            expanded = Set(panels.map(\.id))
        }
        for panel in panels where weights[panel.id] == nil {
            weights[panel.id] = 1
        }
    }

    private func saveState() {
        let state = SavedState(expanded: Array(expanded), weights: weights)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private struct SavedState: Codable {
        var expanded: [String]
        var weights: [String: CGFloat]
    }
}

private extension View {
    /// Applies drag/hover behaviour only where a divider can actually move.
    @ViewBuilder
    func ifDraggable(_ condition: Bool, _ transform: (Self) -> some View) -> some View {
        if condition { transform(self) } else { self }
    }
}
