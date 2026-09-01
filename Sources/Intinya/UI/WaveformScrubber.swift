import SwiftUI

/// The playback scrubber, drawn as the recording's own waveform.
///
/// The system-audio track, mirrored about the centre line. A plain slider tells
/// you where you are; this also tells you where the talking is, so scrubbing to
/// "the bit after the long silence" is something you can aim at rather than
/// hunt for.
struct WaveformScrubber: View {
    let summary: WaveformSummary?
    let duration: TimeInterval
    /// Where playback currently is.
    let currentTime: TimeInterval
    /// Called continuously while dragging, so the time label tracks the cursor.
    let onScrub: (TimeInterval) -> Void
    /// Called once on release, which is when the engine actually seeks.
    let onCommit: (TimeInterval) -> Void

    @State private var dragTime: TimeInterval?
    @State private var hoverFraction: Double?

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, (dragTime ?? currentTime) / duration))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width

            ZStack(alignment: .leading) {
                Canvas { context, size in
                    draw(in: &context, size: size)
                }

                // The playhead. Drawn over everything, and kept 2pt wide so it
                // stays visible against a dense waveform.
                if duration > 0 {
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2)
                        .offset(x: progress * width - 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0 so a plain click seeks, rather than needing
                // a drag before anything happens.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let time = time(at: value.location.x, width: width)
                        dragTime = time
                        onScrub(time)
                    }
                    .onEnded { value in
                        guard duration > 0 else { return }
                        let time = time(at: value.location.x, width: width)
                        dragTime = nil
                        onCommit(time)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverFraction = min(1, max(0, point.x / max(1, width)))
                case .ended: hoverFraction = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let hoverFraction, duration > 0, dragTime == nil {
                    Text((hoverFraction * duration).clockString)
                        .font(Theme.Font.label)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.regularMaterial))
                        .offset(x: hoverFraction * width - 18, y: -6)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 38)
    }

    private func time(at x: CGFloat, width: CGFloat) -> TimeInterval {
        min(duration, max(0, Double(x / max(1, width)) * duration))
    }

    // MARK: - Drawing

    /// One Canvas rather than a stack of shapes: 700 bars would cost far more
    /// as views than the drawing itself does.
    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard let summary, !summary.isEmpty else {
            // No summary yet — a flat axis, so the control keeps the same
            // footprint while the waveform is still being computed.
            let axis = CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)
            context.fill(Path(axis), with: .color(.secondary.opacity(0.25)))
            return
        }

        let mid = size.height / 2
        let played = progress * size.width
        let count = summary.peaks.count
        guard count > 0 else { return }

        let step = size.width / CGFloat(count)
        let barWidth = max(1, step * 0.62)

        for (index, peak) in summary.peaks.enumerated() {
            let x = CGFloat(index) * step + (step - barWidth) / 2
            // Mirrored about the axis: one bar centred on the centre line,
            // rather than two drawn back to back.
            let half = max(0.5, CGFloat(peak) * (mid - 2))
            let bar = CGRect(x: x, y: mid - half, width: barWidth, height: half * 2)

            // Past the playhead the waveform stays visible but recedes, so the
            // played portion reads as progress without the rest disappearing.
            let isPlayed = x <= played
            context.fill(
                Path(roundedRect: bar, cornerRadius: barWidth / 2),
                with: .color(Theme.system.opacity(isPlayed ? 0.95 : 0.28))
            )
        }
    }
}
