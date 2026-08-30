import AVFoundation

/// Converts arbitrary input audio to the 16 kHz mono Float32 that Whisper expects.
///
/// One instance per capture track; `AVAudioConverter` holds resampler state, so
/// reusing it across buffers avoids clicks at buffer boundaries.
final class AudioResampler {
    static let targetSampleRate: Double = 16_000

    static let targetFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Failed to build 16kHz mono target format")
        }
        return format
    }()

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// Downmixes and resamples to 16 kHz mono, returning raw samples.
    func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let inFormat = buffer.format

        if sourceFormat != inFormat {
            converter = AVAudioConverter(from: inFormat, to: Self.targetFormat)
            // Plain averaging downmix; better than dropping a channel, which
            // would silently lose half of a stereo system-audio stream.
            converter?.downmix = true
            sourceFormat = inFormat
        }
        guard let converter else { return [] }

        let ratio = Self.targetSampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: capacity
        ) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, error == nil,
              let channel = output.floatChannelData?[0]
        else { return [] }

        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

extension Array where Element == Float {
    /// Root-mean-square level, used to drive the waveform.
    var rms: Float {
        guard !isEmpty else { return 0 }
        var sum: Float = 0
        for sample in self { sum += sample * sample }
        return (sum / Float(count)).squareRoot()
    }
}
