import SwiftUI

/// Pre-recording choice of which microphone and which system audio to record.
///
/// Both tracks in one sheet because they are one decision — "what am I capturing
/// for this meeting" — and because the two lists are short enough to sit together.
struct AudioSourcePicker: View {
    @EnvironmentObject private var recorder: Recorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Sources")
                    .font(Theme.Font.display)
                Text("Recorded as two separate tracks, which is what gives you speaker attribution.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    micSection
                    systemSection
                }
                .padding(18)
            }

            Divider().opacity(0.5)

            HStack {
                if !recorder.systemSource.isSystemWide {
                    Label("App audio excludes notification sounds and other apps.",
                          systemImage: "info.circle")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
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
        .task { await recorder.refreshAudioSources() }
    }

    // MARK: - Microphone

    private var micSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "MICROPHONE") {
                await recorder.refreshAudioSources()
            }

            if recorder.micDevices.isEmpty {
                Text("No input devices found. Connect a microphone, or check Microphone permission.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
            }

            // Following the system default is a real choice, not an absence of
            // one — it is what you want on a laptop that moves between desks.
            SourceRow(
                icon: "mic",
                title: "System default",
                subtitle: AudioDevices.defaultInput()?.name ?? "None available",
                isSelected: recorder.micDevice == nil,
                accent: Theme.mic
            ) {
                recorder.useMicDevice(nil)
            }

            ForEach(recorder.micDevices) { device in
                SourceRow(
                    icon: "mic.fill",
                    title: device.name,
                    subtitle: device.channels == 1 ? "Mono" : "\(device.channels) channels",
                    isSelected: recorder.micDevice?.uid == device.uid,
                    accent: Theme.mic
                ) {
                    recorder.useMicDevice(device)
                }
            }
        }
    }

    // MARK: - System audio

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "SYSTEM AUDIO") {
                await recorder.refreshAudioSources()
            }

            ForEach(recorder.systemSources) { source in
                SourceRow(
                    icon: source.systemImage,
                    title: source.title,
                    subtitle: source.isSystemWide
                        ? source.subtitle
                        : "Includes helper processes",
                    isSelected: recorder.systemSource.id == source.id,
                    accent: Theme.system
                ) {
                    recorder.useSystemSource(source)
                }
            }
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let refresh: () async -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise").font(Theme.Font.caption)
            }
            .controlSize(.small)
        }
    }
}

private struct SourceRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.title).lineLimit(1)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.10) : Color.primary.opacity(0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.35) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
