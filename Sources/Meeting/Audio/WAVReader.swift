import AVFoundation

/// Sequential reader for the session WAVs.
///
/// Deliberately parses the RIFF chunks by hand instead of using `AVAudioFile`.
/// A recording that was interrupted — crash, force quit, power loss — still has
/// all of its audio on disk but a `data` chunk header claiming zero bytes, and
/// `AVAudioFile` honours that header and reports an empty file. Reading the size
/// from the file itself recovers those sessions instead of silently discarding
/// a meeting's audio.
///
/// It also streams in windows rather than loading whole: an hour of 16 kHz float
/// audio is ~230 MB per track, and there are two.
final class WAVReader {

    private let handle: FileHandle
    private let resampler = AudioResampler()
    private let format: AVAudioFormat
    private let bytesPerFrame: Int
    private let dataOffset: UInt64
    private let dataBytes: Int

    /// True when the header understated the data size and we recovered it.
    let wasTruncated: Bool
    let duration: TimeInterval

    private var bytesRead: Int = 0

    init(url: URL) throws {
        let fileSize = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0

        handle = try FileHandle(forReadingFrom: url)
        let header = try handle.read(upToCount: 4096) ?? Data()
        guard header.count >= 44,
              header.prefix(4) == Data("RIFF".utf8),
              header.dropFirst(8).prefix(4) == Data("WAVE".utf8)
        else { throw ReadError.notAWAVFile }

        // Walk the chunk list — `fmt ` is not guaranteed to be first, and some
        // writers insert LIST/fact chunks before `data`.
        var cursor = 12
        var channels = 1
        var sampleRate: Double = 16_000
        var bitsPerSample = 16
        var foundFormat = false
        var declaredDataBytes = 0
        var dataStart: Int? = nil

        func u32(_ offset: Int) -> Int {
            guard offset + 4 <= header.count else { return 0 }
            return header.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt32.self).littleEndian)
            }
        }
        func u16(_ offset: Int) -> Int {
            guard offset + 2 <= header.count else { return 0 }
            return header.subdata(in: offset..<(offset + 2)).withUnsafeBytes {
                Int($0.loadUnaligned(as: UInt16.self).littleEndian)
            }
        }

        while cursor + 8 <= header.count {
            let id = header.subdata(in: cursor..<(cursor + 4))
            let size = u32(cursor + 4)

            if id == Data("fmt ".utf8) {
                channels = max(1, u16(cursor + 10))
                sampleRate = Double(u32(cursor + 12))
                bitsPerSample = u16(cursor + 22)
                foundFormat = true
            } else if id == Data("data".utf8) {
                declaredDataBytes = size
                dataStart = cursor + 8
                break
            }
            // Chunks are word-aligned.
            cursor += 8 + size + (size % 2)
        }

        guard foundFormat, let dataStart, bitsPerSample == 16, sampleRate > 0 else {
            throw ReadError.unsupportedFormat
        }

        let availableBytes = max(0, fileSize - dataStart)
        // The recovery: trust the file, not a header that was never finalised.
        let usableBytes = (declaredDataBytes == 0 || declaredDataBytes > availableBytes)
            ? availableBytes
            : declaredDataBytes

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else { throw ReadError.unsupportedFormat }

        self.format = format
        self.bytesPerFrame = channels * 2
        self.dataOffset = UInt64(dataStart)
        self.dataBytes = usableBytes
        self.wasTruncated = declaredDataBytes != usableBytes
        self.duration = Double(usableBytes / max(1, bytesPerFrame)) / sampleRate

        try handle.seek(toOffset: self.dataOffset)
    }

    deinit { try? handle.close() }

    var isAtEnd: Bool { bytesRead >= dataBytes }

    /// Time offset of the next sample to be read.
    var currentTime: TimeInterval {
        Double(bytesRead / max(1, bytesPerFrame)) / format.sampleRate
    }

    /// Reads up to `seconds` of audio as 16 kHz mono. Empty array at EOF.
    func read(seconds: TimeInterval) throws -> [Float] {
        guard !isAtEnd else { return [] }

        let wantedFrames = Int(seconds * format.sampleRate)
        let remainingFrames = (dataBytes - bytesRead) / bytesPerFrame
        let frames = min(wantedFrames, remainingFrames)
        guard frames > 0 else { return [] }

        guard let raw = try handle.read(upToCount: frames * bytesPerFrame), !raw.isEmpty else {
            bytesRead = dataBytes
            return []
        }
        bytesRead += raw.count

        let actualFrames = raw.count / bytesPerFrame
        guard actualFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(actualFrames)),
              let destination = buffer.int16ChannelData?[0]
        else { return [] }

        buffer.frameLength = AVAudioFrameCount(actualFrames)
        raw.withUnsafeBytes { source in
            destination.update(
                from: source.bindMemory(to: Int16.self).baseAddress!,
                count: actualFrames * Int(format.channelCount)
            )
        }

        // Routed through the resampler so a session captured at another rate,
        // or in stereo, still converts to the 16 kHz mono Whisper expects.
        return resampler.resample(buffer)
    }

    enum ReadError: LocalizedError {
        case notAWAVFile
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .notAWAVFile: return "That file is not a WAV recording."
            case .unsupportedFormat: return "Unsupported WAV format — expected 16-bit PCM."
            }
        }
    }
}
