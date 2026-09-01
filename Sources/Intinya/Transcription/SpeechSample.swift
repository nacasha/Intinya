import AVFoundation

/// Generates a known Indonesian test utterance on-device, so models can be
/// benchmarked without shipping an audio asset or sending anything to a server.
///
/// The sentence is deliberately code-switched the way a real standup is — that
/// is the thing we actually need to measure, and a clean monolingual sample
/// would flatter every model equally.
enum SpeechSample {

    /// Ground truth for the word-error-rate comparison.
    static let referenceText = """
    Oke, jadi untuk sprint ini kita fokus ke deployment backend dulu. \
    Ada beberapa bug di endpoint API yang harus di-fix sebelum release minggu depan. \
    Tolong update statusnya di backlog ya, terus kabarin kalau ada blocker.
    """

    static let voiceIdentifier = "com.apple.voice.compact.id-ID.Damayanti"
    static let languageCode = "id-ID"

    struct Sample {
        let samples: [Float]      // 16 kHz mono
        let duration: TimeInterval
        let reference: String
    }

    enum SampleError: LocalizedError {
        case noIndonesianVoice
        case synthesisFailed

        var errorDescription: String? {
            switch self {
            case .noIndonesianVoice:
                return "No Indonesian system voice is installed. Add one in "
                     + "System Settings › Accessibility › Spoken Content › System Voice."
            case .synthesisFailed:
                return "Could not synthesise the benchmark sample."
            }
        }
    }

    static var isAvailable: Bool { indonesianVoice() != nil }

    private static func indonesianVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            ?? AVSpeechSynthesisVoice.speechVoices().first {
                $0.language.hasPrefix("id")
            }
    }

    /// Renders the reference sentence to 16 kHz mono samples. Nothing is played
    /// aloud — `write` synthesises straight to buffers.
    ///
    /// `write` delivers buffers on an internal queue and signals completion with
    /// a zero-length buffer. If a voice misbehaves that marker never arrives, so
    /// a watchdog resumes the wait instead.
    ///
    /// The watchdog deliberately does NOT use a task group: a group awaits its
    /// children when the scope exits, and cancelling a task parked in
    /// `withCheckedContinuation` does not resume it — so a group-based timeout
    /// hangs forever on exactly the case it was meant to protect against.
    static func render(timeout: TimeInterval = 30) async throws -> Sample {
        guard let voice = indonesianVoice() else { throw SampleError.noIndonesianVoice }

        let utterance = AVSpeechUtterance(string: referenceText)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        let collector = Collector()
        let synthesizer = AVSpeechSynthesizer()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumer = OnceResumer(continuation)

            // Watchdog: fires the continuation if the end marker never arrives.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumer.fire()
            }

            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                guard pcm.frameLength > 0 else {
                    resumer.fire()          // end-of-synthesis marker
                    return
                }
                collector.append(pcm)
            }
        }

        synthesizer.stopSpeaking(at: .immediate)

        let samples = collector.samples
        guard !samples.isEmpty else { throw SampleError.synthesisFailed }

        return Sample(
            samples: samples,
            duration: Double(samples.count) / AudioResampler.targetSampleRate,
            reference: referenceText
        )
    }
}

/// Accumulates synthesised buffers. `write` calls back on its own queue, so the
/// resampler and the sample array are both lock-guarded.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private let resampler = AudioResampler()
    private var storage: [Float] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(contentsOf: resampler.resample(buffer))
    }

    var samples: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Guarantees a continuation resumes exactly once, even if the synthesiser
/// emits more than one end marker.
private final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func fire() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
