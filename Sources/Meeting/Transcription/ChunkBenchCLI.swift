import Foundation

/// `Meeting --chunkbench [seconds]`
///
/// Feeds synthetic audio through the live chunker in realistic packet sizes and
/// reports how long the per-packet work takes. This path used to run on the main
/// thread at O(pending buffer) per packet, which stalled the UI as the buffer
/// filled; the numbers here should stay flat as the duration grows.
enum ChunkBenchCLI {

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        let seconds = CommandLine.arguments
            .drop(while: { $0 != "--chunkbench" })
            .dropFirst()
            .compactMap(Double.init)
            .first ?? 120

        let rate = Int(AudioResampler.targetSampleRate)
        // ~85ms at 48kHz resampled to 16kHz, matching a real capture packet.
        let packet = 1365
        let packets = Int(seconds * Double(rate)) / packet

        // Speech-like: tone bursts separated by silence, so the VAD actually
        // finds boundaries instead of trivially rejecting everything.
        var phase: Float = 0
        func makePacket(index: Int) -> [Float] {
            let speaking = (index / 12) % 4 != 3      // ~3s speech, ~1s silence
            return (0..<packet).map { _ in
                phase += 0.05
                return speaking ? sin(phase) * 0.3 : 0
            }
        }

        let chunker = LiveChunker()
        var worst: Double = 0
        var total: Double = 0
        var chunks = 0
        var worstAt: Double = 0

        for index in 0..<packets {
            let samples = makePacket(index: index)
            let started = CFAbsoluteTimeGetCurrent()
            chunks += chunker.append(samples).count
            let elapsed = CFAbsoluteTimeGetCurrent() - started

            total += elapsed
            if elapsed > worst {
                worst = elapsed
                worstAt = Double(index * packet) / Double(rate)
            }
        }

        let audioSeconds = Double(packets * packet) / Double(rate)
        print(String(format: "audio            %.0fs in %d packets", audioSeconds, packets))
        print(String(format: "chunks emitted   %d", chunks))
        print(String(format: "total CPU        %.1f ms", total * 1000))
        print(String(format: "mean per packet  %.3f ms", total / Double(packets) * 1000))
        print(String(format: "worst packet     %.3f ms  (at %.0fs in)", worst * 1000, worstAt))
        print("")
        // A packet arrives every ~85ms. Anything approaching that starves the
        // thread; the old implementation climbed steadily toward it.
        let budget = Double(packet) / Double(rate) * 1000
        print(String(format: "packet budget    %.1f ms — worst case uses %.2f%%", budget, worst * 1000 / budget * 100))
        exit(0)
    }
}
