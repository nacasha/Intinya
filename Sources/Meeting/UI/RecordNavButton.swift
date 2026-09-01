import SwiftUI

/// The Record destination in the sidebar, as a button rather than a nav row.
///
/// Record is not a peer of Glossary and Settings. It is the thing the app is
/// for, and every other row is somewhere you go afterwards — so it gets the one
/// piece of colour in the sidebar and a shape nothing else has.
///
/// It stays a *navigation* control: pressing it opens the record pane, it does
/// not start recording. Arming a microphone from a sidebar row you might click
/// while looking for something else is not a mistake worth making possible.
/// What it does do is report — while a recording runs it turns red, pulses, and
/// counts up, so the state is visible from anywhere in the app.
struct RecordNavButton: View {
    let isSelected: Bool
    let isRecording: Bool
    let isPaused: Bool
    /// Read through a nested observer rather than by the caller.
    ///
    /// `RecordingMonitor` publishes audio levels twenty times a second
    /// alongside the clock. Reading `elapsed` in the sidebar would make every
    /// one of those invalidate the whole sidebar — the session list included —
    /// so only the label below observes it.
    let monitor: RecordingMonitor?
    let action: () -> Void

    @State private var hovering = false
    @State private var pulsing = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                dot

                Text(isRecording ? (isPaused ? "Paused" : "Recording") : "Record")
                    .font(.system(size: 13, weight: .semibold))

                Spacer(minLength: 4)

                if isRecording, let monitor {
                    ElapsedTick(monitor: monitor, color: foreground.opacity(0.75))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(background)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.18), value: isRecording)
        .animation(.smooth(duration: 0.18), value: isSelected)
        .animation(.smooth(duration: 0.18), value: isPaused)
    }

    /// The dot that makes it read as a record button rather than a menu item.
    ///
    /// Squares off into a stop glyph while running, which is the one shape
    /// change people already know from every recorder they have used.
    private var dot: some View {
        RoundedRectangle(cornerRadius: isRecording && !isPaused ? 2.5 : 6, style: .continuous)
            .fill(isRecording ? Color.white : Theme.recording)
            .frame(
                width: isRecording && !isPaused ? 9 : 12,
                height: isRecording && !isPaused ? 9 : 12
            )
            .frame(width: 14, height: 14)
            .opacity(isRecording && !isPaused && pulsing ? 0.45 : 1)
            .onAppear {
                guard isRecording else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onChange(of: isRecording) { _, running in
                pulsing = false
                guard running else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }

    // MARK: - Appearance

    /// Three states, in descending loudness: recording is filled red, selected
    /// is a red wash, and at rest it is a tinted outline. Selection never uses
    /// the system accent here — a blue row would put this back among the others.
    private var background: Color {
        if isRecording { return isPaused ? .orange : Theme.recording }
        if isSelected { return Theme.recording.opacity(hovering ? 0.18 : 0.14) }
        return Theme.recording.opacity(hovering ? 0.10 : 0.06)
    }

    private var foreground: Color {
        isRecording ? .white : Theme.recording
    }

    private var border: Color {
        if isRecording { return .clear }
        return Theme.recording.opacity(isSelected ? 0.45 : 0.22)
    }
}


/// The clock, alone in its own view so its ticks stop here.
private struct ElapsedTick: View {
    @ObservedObject var monitor: RecordingMonitor
    let color: Color

    var body: some View {
        Text(monitor.elapsed.clockString)
            .font(Theme.Font.caption)
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
    }
}
