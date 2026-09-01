import Foundation

/// Peak envelope for a session's system-audio track, at a resolution suited to
/// drawing a scrubber rather than to analysis.
///
/// System audio only. The mic track is your own voice, which is usually the
/// quieter half and the half you are not scrubbing for — the thing you hunt for
/// in a recording is where *they* were talking. Reading one WAV instead of two
/// also halves the cost of building this.
///
/// Cached beside the audio as `waveform.json`. Building it reads the WAV end to
/// end, which is fast but not free — an hour-long track is ~230 MB — and the
/// answer never changes, so it is paid once per recording rather than once per
/// visit.
struct WaveformSummary: Codable {
    /// Peaks in 0...1, oldest first.
    var peaks: [Float]
    var duration: TimeInterval

    /// Size of the file this was built from.
    ///
    /// The invalidation key, matching how `AudioProbe` caches: a recording's
    /// audio never changes in place, but a truncated WAV that later gets its
    /// header repaired does change size, and that summary is stale.
    var bytes: Int

    static let buckets = 700

    var isEmpty: Bool { peaks.isEmpty }

    // MARK: - Cache

    private static let fileName = "system.wav"

    private static func cacheURL(in directory: URL) -> URL {
        directory.appendingPathComponent("waveform.json")
    }

    /// Returns the cached summary, or nil when it is missing or out of date.
    static func cached(in directory: URL) -> WaveformSummary? {
        guard let data = try? Data(contentsOf: cacheURL(in: directory)),
              let summary = try? JSONDecoder().decode(WaveformSummary.self, from: data),
              summary.bytes == fileSize(in: directory)
        else { return nil }
        return summary
    }

    /// Builds the summary, writing it to the cache. Call off the main thread.
    @discardableResult
    static func build(in directory: URL) -> WaveformSummary? {
        guard let envelope = envelope(of: directory.appendingPathComponent(fileName)) else {
            return nil
        }

        let summary = WaveformSummary(
            peaks: normalise(envelope.values, by: envelope.peak),
            duration: envelope.duration,
            bytes: fileSize(in: directory)
        )
        guard !summary.isEmpty else { return nil }

        if let data = try? JSONEncoder().encode(summary) {
            try? data.write(to: cacheURL(in: directory), options: .atomic)
        }
        return summary
    }

    // MARK: - Reading

    private static func fileSize(in directory: URL) -> Int {
        let url = directory.appendingPathComponent(fileName)
        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        return (size ?? 0)?.intValue ?? 0
    }

    private static func envelope(of url: URL) -> (values: [Float], peak: Float, duration: TimeInterval)? {
        guard FileManager.default.fileExists(atPath: url.path),
              let reader = try? WAVReader(url: url),
              reader.duration > 0
        else { return nil }

        let total = max(1, Int(reader.duration * AudioResampler.targetSampleRate))
        let perBucket = max(1, total / buckets)

        var values = [Float](repeating: 0, count: buckets)
        var peak: Float = 0
        var index = 0

        // A second at a time. Large enough that the per-read overhead vanishes,
        // small enough that an hour-long track never sits in memory at once.
        while let chunk = try? reader.read(seconds: 1.0), !chunk.isEmpty {
            for sample in chunk {
                let bucket = min(buckets - 1, index / perBucket)
                let magnitude = abs(sample)
                if magnitude > values[bucket] { values[bucket] = magnitude }
                if magnitude > peak { peak = magnitude }
                index += 1
            }
        }
        return (values, peak, reader.duration)
    }

    /// Scales to 0...1 and applies a square root, which is what makes speech
    /// legible: peaks in conversation sit far below full scale, and drawn
    /// linearly a normal voice is a barely visible ripple along the axis.
    private static func normalise(_ values: [Float], by ceiling: Float) -> [Float] {
        guard ceiling > 0.0001, !values.isEmpty else { return [] }
        return values.map { ($0 / ceiling).squareRoot() }
    }
}
