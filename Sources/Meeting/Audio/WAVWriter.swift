import Foundation

/// Streams 16 kHz mono Float32 samples to a 16-bit PCM WAV file as they arrive.
///
/// Writing to disk during capture is what makes the enhanced pass a second
/// *read* rather than a second recording — tier 2 re-runs over this file while
/// tier 1 is still going.
final class WAVWriter {
    private let handle: FileHandle
    private(set) var sampleCount: Int = 0
    let url: URL

    private let sampleRate: Int
    /// Samples written since the header was last patched.
    private var samplesSinceFlush: Int = 0
    /// Roughly every 5 seconds of audio at 16 kHz.
    private let flushInterval = 16_000 * 5

    init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        // Placeholder header; sizes are patched in `finish()`.
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        try? handle.write(contentsOf: pcm)
        sampleCount += samples.count

        // Patch the RIFF sizes periodically so a recording that is interrupted —
        // crash, force quit, power loss — is still a playable, readable file
        // rather than a header claiming zero bytes over megabytes of audio.
        samplesSinceFlush += samples.count
        if samplesSinceFlush >= flushInterval {
            samplesSinceFlush = 0
            flushHeader()
        }
    }

    /// Rewrites the header in place, then returns to the end for further writes.
    private func flushHeader() {
        guard let end = try? handle.offset() else { return }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: sampleCount * 2))
        try? handle.seek(toOffset: end)
    }

    /// Patches the RIFF sizes and closes the file.
    func finish() {
        flushHeader()
        try? handle.close()
    }

    private static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var data = Data()
        func ascii(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1)                       // PCM
        u16(1)                       // mono
        u32(sampleRate)
        u32(sampleRate * 2)          // byte rate
        u16(2)                       // block align
        u16(16)                      // bits per sample
        ascii("data"); u32(dataBytes)
        return data
    }
}
