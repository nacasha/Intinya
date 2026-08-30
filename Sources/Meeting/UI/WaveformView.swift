import SwiftUI

/// Live level meter for one capture track.
///
/// This is the highest-impact element in the whole UI — it's what makes the app
/// feel alive while recording, and it's what tells you at a glance that the
/// track is actually receiving audio.
struct WaveformView: View {
    let levels: [Float]
    let color: Color
    var isActive: Bool = true

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }

            let barCount = levels.count
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            let midY = size.height / 2

            for (index, level) in levels.enumerated() {
                // Older samples fade out, so the meter reads left-to-right in time.
                let age = Double(index) / Double(max(1, barCount - 1))
                let opacity = isActive ? (0.25 + 0.75 * age) : 0.15

                let height = max(2, CGFloat(level) * size.height * 0.92)
                let x = CGFloat(index) * (barWidth + spacing)
                let rect = CGRect(x: x, y: midY - height / 2, width: barWidth, height: height)

                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(color.opacity(opacity))
                )
            }
        }
        // Deliberately no .drawingGroup() and no implicit animation here.
        //
        // drawingGroup() rasterises into an offscreen Metal buffer every frame;
        // under the CPU pressure of live transcription that is a source of blank
        // and mis-sized frames, and a few dozen rounded rects do not need it.
        // Animating an array-valued property also makes SwiftUI interpolate the
        // whole array on each change — the levels already arrive smoothed at
        // 20 Hz, which is what the animation was faking.
    }
}

/// Shows unambiguously which sources are being captured. For a recording app
/// this is a trust requirement, not decoration.
struct TrackBadge: View {
    let source: AudioSource
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: source == .mic ? "mic.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
            Text(source == .mic ? "MIC" : "SYSTEM")
                .font(Theme.Font.label)
                .tracking(0.6)
        }
        .foregroundStyle(isActive ? Theme.accent(for: source) : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule().fill(
                isActive
                    ? Theme.accent(for: source).opacity(0.16)
                    : Color.primary.opacity(0.05)
            )
        }
        .overlay {
            Capsule().stroke(
                isActive ? Theme.accent(for: source).opacity(0.35) : .clear,
                lineWidth: 1
            )
        }
        .opacity(isActive ? 1 : 0.55)
        .animation(.smooth(duration: 0.25), value: isActive)
    }
}
