import Foundation

/// `Meeting --audio-sources`
///
/// Lists the input devices and the applications available as capture sources.
/// Exercises both discovery paths without going through the UI, and doubles as a
/// permission check: no inputs means Microphone is not granted, no apps means
/// Screen Recording is not.
enum AudioSourceCLI {

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        Task {
            defer { CFRunLoopStop(CFRunLoopGetMain()) }

            let devices = AudioDevices.inputs()
            let defaultUID = AudioDevices.defaultInput()?.uid

            print("Input devices (\(devices.count)):")
            if devices.isEmpty {
                print("  none — connect a microphone, and check Microphone permission in")
                print("  System Settings > Privacy & Security > Microphone.")
            }
            for device in devices {
                let marker = device.uid == defaultUID ? " (default)" : ""
                print("  \(device.name)\(marker)")
                print("    \(device.channels) input channel\(device.channels == 1 ? "" : "s")  ·  \(device.uid)")
            }

            let sources = await SystemAudioCapture.availableSources()
            let apps = sources.filter { !$0.isSystemWide }

            print("\nSystem audio sources (\(sources.count)):")
            print("  All system audio  —  everything the machine plays")
            if apps.isEmpty {
                print("  no apps listed — Screen Recording permission is required, grant it in")
                print("  System Settings > Privacy & Security > Screen Recording.")
            }
            for source in apps {
                print("  \(source.title)  —  \(source.subtitle)")
            }
        }

        CFRunLoopRun()
        exit(0)
    }
}
