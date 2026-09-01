import SwiftUI

/// Pre-recording choice of what to capture from the screen.
struct ScreenCapturePicker: View {
    @EnvironmentObject private var recorder: Recorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Screen Capture")
                    .font(Theme.Font.display)
                Text("Recorded alongside the audio, in the same session folder.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(ScreenCaptureMode.allCases) { mode in
                        ModeCard(mode: mode, isSelected: recorder.screenMode == mode) {
                            recorder.screenMode = mode
                        }
                    }

                    if recorder.screenMode != .off {
                        targetSection
                    }
                }
                .padding(18)
            }

            Divider().opacity(0.5)

            HStack {
                if recorder.screenMode == .video, #unavailable(macOS 15.0) {
                    Label("Video needs macOS 15; keyframes work on 14.", systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .frame(width: 560, height: 560)
        .background(.ultraThinMaterial)
        .task { await recorder.refreshScreenTargets() }
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CAPTURE")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await recorder.refreshScreenTargets() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(Theme.Font.caption)
                }
                .controlSize(.small)
            }
            .padding(.top, 6)

            if recorder.screenTargets.isEmpty {
                Text("No capture targets found. Screen Recording permission is required.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
            }

            ForEach(recorder.screenTargets) { target in
                TargetRow(target: target, isSelected: recorder.screenTarget?.id == target.id) {
                    recorder.screenTarget = target
                }
            }
        }
    }
}

private struct ModeCard: View {
    let mode: ScreenCaptureMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Theme.system : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.label).font(Theme.Font.title)
                    Text(mode.detail)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.system) : AnyShapeStyle(.tertiary))
            }
            .padding(13)
            .background {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(isSelected ? Theme.system.opacity(0.10) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(isSelected ? Theme.system.opacity(0.45) : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: isSelected)
    }
}

private struct TargetRow: View {
    let target: ScreenTarget
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: target.isWindow ? "macwindow" : "display")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Theme.system : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(target.subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.system)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Theme.system.opacity(0.12) : Color.primary.opacity(0.03))
            }
        }
        .buttonStyle(.plain)
    }
}
