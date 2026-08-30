import Foundation

/// Answers "does this recording contain any audible sound?" without reading the
/// whole file.
///
/// Reading every session's WAV in full during a library scan would be hundreds
/// of megabytes. Sampling short windows spread across the file is enough: sound
/// that never once crosses the threshold anywhere in the recording is not sound
/// anyone can hear.
enum AudioProbe {

    /// Windows to sample across the file.
    private static let windowCount = 24
    /// Each window, in samples at 16 kHz.
    private static let windowSamples = 8_000     // 0.5s

    /// Roughly -34 dBFS. Digital silence reads 0; a live microphone in a quiet
    /// room still has a noise floor well under this, so the threshold separates
    /// "nothing was captured" from "quiet but real".
    static let audibleThreshold: Float = 0.02

    /// Peak amplitude found, 0...1.
    static func peak(of url: URL) -> Float {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 4096), header.count >= 44,
              header.prefix(4) == Data("RIFF".utf8)
        else { return 0 }

        // Locate the data chunk; `fmt ` is not guaranteed to come first.
        var cursor = 12
        var dataStart = 0
        var declared = 0
        while cursor + 8 <= header.count {
            let id = header.subdata(in: cursor..<(cursor + 4))
            let size = header.subdata(in: (cursor + 4)..<(cursor + 8)).withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt32.self).littleEndian)
            }
            if id == Data("data".utf8) {
                dataStart = cursor + 8
                declared = size
                break
            }
            cursor += 8 + size + (size % 2)
        }
        guard dataStart > 0 else { return 0 }

        let fileSize = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
        let available = max(0, fileSize - dataStart)
        // An interrupted recording leaves a zero-length header over real audio.
        let bytes = (declared == 0 || declared > available) ? available : declared
        guard bytes > 1_024 else { return 0 }

        let totalFrames = bytes / 2
        let stride = max(windowSamples, totalFrames / windowCount)
        var peak: Float = 0
        var frame = 0

        while frame < totalFrames {
            let offset = UInt64(dataStart + frame * 2)
            try? handle.seek(toOffset: offset)
            let wanted = min(windowSamples, totalFrames - frame) * 2
            guard wanted > 0, let chunk = try? handle.read(upToCount: wanted), !chunk.isEmpty else { break }

            chunk.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for sample in samples {
                    let magnitude = abs(Float(Int16(littleEndian: sample))) / 32768
                    if magnitude > peak { peak = magnitude }
                }
            }
            // Loud enough already; no point reading the rest.
            if peak >= audibleThreshold { return peak }
            frame += stride
        }
        return peak
    }

    /// True when either track carries audible sound.
    ///
    /// Cached by path and file size. Probing dominates a library scan (about
    /// 100 ms for a dozen recordings, growing linearly), and the answer cannot
    /// change for a finished recording — only a re-record would, and that
    /// changes the size.
    static func hasAudio(in directory: URL) -> Bool {
        ["mic.wav", "system.wav"].contains { name in
            let url = directory.appendingPathComponent(name)
            let size = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
            let key = "\(url.path)#\(size)"

            cacheLock.lock()
            if let cached = cache[key] {
                cacheLock.unlock()
                return cached >= audibleThreshold
            }
            cacheLock.unlock()

            let measured = peak(of: url)

            cacheLock.lock()
            cache[key] = measured
            cacheLock.unlock()
            return measured >= audibleThreshold
        }
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: Float] = [:]
}
