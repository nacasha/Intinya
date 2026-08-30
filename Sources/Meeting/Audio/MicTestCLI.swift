import AVFoundation
import Foundation

/// `Meeting --mictest [seconds]`
///
/// Diagnoses the most dangerous failure mode this app has: macOS hands an app
/// **digital silence** rather than an error when a microphone grant is not in
/// effect. Recording then "succeeds" and produces a silent file. Because the app
/// is ad-hoc signed, every rebuild changes its code signature and can invalidate
/// the existing grant — so this check is worth having on hand.
enum MicTestCLI {

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        let seconds = CommandLine.arguments
            .drop(while: { $0 != "--mictest" })
            .dropFirst()
            .compactMap(Double.init)
            .first ?? 5.0

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        print("Microphone authorization: \(describe(status))")

        if let device = AVCaptureDevice.default(for: .audio) {
            print("Default input device:    \(device.localizedName)")
        } else {
            print("Default input device:    none found")
        }
        print("")

        var failed = false

        Task {
            defer { CFRunLoopStop(CFRunLoopGetMain()) }

            let granted = await MicCapture.requestAccess()
            guard granted else {
                print("Access denied. Grant it in System Settings › Privacy & Security › Microphone.")
                failed = true
                return
            }

            let capture = MicCapture()
            let meter = Meter()
            capture.onSamples = { meter.add($0) }

            do {
                try capture.start()
            } catch {
                print("Could not start capture: \(error.localizedDescription)")
                failed = true
                return
            }

            print("Listening for \(Int(seconds))s — say something…")
            for tick in 1...Int(seconds) {
                try? await Task.sleep(for: .seconds(1))
                print(String(format: "  %ds  peak %.4f", tick, meter.peakAndReset()))
            }
            capture.stop()

            print("")
            if meter.overallPeak == 0 {
                print("RESULT: SILENT — every sample was exactly zero.")
                print("")
                print("macOS delivers silence instead of an error when the microphone")
                print("grant is not in effect. Because this app is ad-hoc signed, each")
                print("rebuild changes its signature and can invalidate the grant.")
                print("")
                print("Fix: remove Meeting from System Settings › Privacy & Security ›")
                print("Microphone, then relaunch and approve the prompt again.")
                failed = true
            } else if meter.overallPeak < 0.01 {
                print(String(format: "RESULT: VERY QUIET — peak %.4f. Signal exists but input gain is low.",
                             meter.overallPeak))
            } else {
                print(String(format: "RESULT: OK — peak %.4f. Microphone capture is working.",
                             meter.overallPeak))
            }
        }

        CFRunLoopRun()
        exit(failed ? 1 : 0)
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Float = 0
        private(set) var overallPeak: Float = 0

        func add(_ samples: [Float]) {
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
            lock.lock()
            current = max(current, peak)
            overallPeak = max(overallPeak, peak)
            lock.unlock()
        }

        func peakAndReset() -> Float {
            lock.lock()
            defer { current = 0; lock.unlock() }
            return current
        }
    }
}
