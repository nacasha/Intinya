import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures the default input device via AVAudioEngine and emits 16 kHz mono.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler = AudioResampler()
    private var isRunning = false

    /// Called on the audio tap's thread with 16 kHz mono samples.
    var onSamples: (([Float]) -> Void)?
    /// Reports a device that went away or changed mid-recording.
    var onError: ((String) -> Void)?

    private var configurationObserver: NSObjectProtocol?

    /// Starts capture, optionally from a specific input device.
    ///
    /// `nil` follows the system default input, which is the original behaviour
    /// and the fallback when a previously chosen device has been unplugged.
    func start(device: MicDevice? = nil) throws {
        guard !isRunning else { return }

        let input = engine.inputNode

        // Point the engine at the chosen device before anything reads a format
        // from it. `AVAudioEngine` has no API for this — the device lives on the
        // input node's underlying audio unit, and it can only be set while the
        // engine is stopped.
        if let device {
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                input.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw CaptureError.deviceUnavailable(device.name)
            }
        }

        // Every check below has to happen *before* `installTap`. That method
        // raises an Objective-C exception on a bad format, and an ObjC exception
        // is not catchable by Swift `try` — it unwinds straight past the caller's
        // error handling, which is how a failure here ended up aborting the whole
        // start sequence with no message.
        //
        // These validate whatever the engine is *now* pointed at, which is why
        // they run after the device is set rather than before.
        guard device != nil || AVCaptureDevice.default(for: .audio) != nil else {
            throw CaptureError.noInputDevice
        }

        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)

        // An aggregate or virtual device can advertise a sample rate while
        // exposing no channels at all; that is what "input hw format invalid"
        // means, and it is the case a sample-rate check alone lets through.
        guard hardware.channelCount > 0, hardware.sampleRate > 0,
              format.channelCount > 0, format.sampleRate > 0
        else {
            throw CaptureError.invalidInputFormat(
                device?.name ?? describe(device: AVCaptureDevice.default(for: .audio))
            )
        }

        // 4096 frames at the device rate is ~85ms — small enough to feel live,
        // large enough that the resampler isn't thrashed.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.resample(buffer)
            if !samples.isEmpty { self.onSamples?(samples) }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        observeConfigurationChanges()
    }

    /// Unplugging an interface, or switching input, reconfigures the engine and
    /// silently stops delivering samples. Without this the recording would keep
    /// running and simply capture nothing.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let format = self.engine.inputNode.inputFormat(forBus: 0)
            guard format.channelCount == 0 || format.sampleRate == 0 else { return }
            self.onError?("The microphone became unavailable — recording stopped capturing it.")
            self.stop()
        }
    }

    /// Names the device in the error, since the fix is usually to change it.
    private func describe(device: AVCaptureDevice?) -> String {
        device?.localizedName ?? "the current input device"
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Prompts for mic access if it hasn't been decided yet.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

enum CaptureError: LocalizedError {
    case noInputDevice
    case invalidInputFormat(String)
    case deviceUnavailable(String)
    case noDisplayAvailable
    case screenRecordingDenied
    case windowGone
    case videoUnavailable
    case appGone(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available. Connect one, then pick it from the mic chip."
        case .invalidInputFormat(let device):
            return "\(device) reports no usable input channels, so it cannot be recorded. "
                 + "This usually means an aggregate or virtual audio device — "
                 + "pick a real microphone from the mic chip."
        case .deviceUnavailable(let device):
            return "\(device) could not be opened. It may have been unplugged or taken by "
                 + "another app — pick a different microphone from the mic chip."
        case .noDisplayAvailable:
            return "No display available to attach the system audio capture to."
        case .screenRecordingDenied:
            return "Screen Recording permission is required to capture system audio. "
                 + "Grant it in System Settings › Privacy & Security › Screen Recording, then restart Meeting."
        case .windowGone:
            return "That window has closed. Pick another capture target."
        case .videoUnavailable:
            return "Screen video recording requires macOS 15 or later. Keyframes work on macOS 14."
        case .appGone(let name):
            return "\(name) is no longer running, so its audio cannot be captured. "
                 + "Pick another source, or switch back to all system audio."
        }
    }
}
