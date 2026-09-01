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

