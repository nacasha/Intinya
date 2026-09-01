import SwiftUI

/// Shared look for the actions across the top of a recording.
///
/// A `Menu` and a `Button` are different controls with different default
/// chrome, which is why the AI dropdown never matched its neighbours. Both now
/// wear the same chip, so the row reads as one set.
/// Internal rather than private: `HeaderMenu` wears the same chip, and the whole
/// point of that type is that a custom dropdown is indistinguishable from the
/// buttons beside it.
struct ActionChip: View {
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
                .lineLimit(1)
                // A chip is as wide as its label. Without this the row wraps
                // "Copy" to "Co / py" the moment the window is narrow enough
                // that the actions no longer fit side by side.
                .fixedSize()

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
        .fixedSize()
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

/// A two-way switch for the actions row.
///
/// Wears the same capsule language as `HeaderAction`, but inverted: the track
/// is the recessed surface and the selected option is the raised one, so it
/// reads as a choice between states rather than as two buttons that happen to
/// sit together.
struct HeaderSwitch<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        let systemImage: String
        var id: Value { value }
    }

    let options: [Option]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: option.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                        Text(option.title)
                            .font(Theme.Font.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            // Without this the labels wrap a character per line
                            // as soon as the actions row runs short of space,
                            // collapsing the switch into an unreadable stack.
                            .fixedSize()
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Theme.content)
                                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.09), lineWidth: 1))
        .fixedSize()
        .animation(.smooth(duration: 0.18), value: selection)
    }
}
