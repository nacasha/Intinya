import Foundation

/// `Meeting --screens`
///
/// Lists the displays and windows available as capture targets. Exercises the
/// ScreenCaptureKit discovery path without going through the UI, and doubles as
/// a permission check: an empty list means Screen Recording is not granted.
enum ScreenCLI {

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        Task {
            defer { CFRunLoopStop(CFRunLoopGetMain()) }

            let targets = await ScreenCapture.availableTargets()
            guard !targets.isEmpty else {
                print("No capture targets found.")
                print("Screen Recording permission is required — grant it in")
                print("System Settings > Privacy & Security > Screen Recording.")
                return
            }

            let displays = targets.filter { !$0.isWindow }
            let windows = targets.filter(\.isWindow)

            print("Displays (\(displays.count)):")
            for target in displays {
                print("  \(target.title)  —  \(target.subtitle)")
            }
            print("\nWindows (\(windows.count)):")
            for target in windows.prefix(25) {
                print(String(format: "  %-38s  %@",
                             (String(target.title.prefix(36)) as NSString).utf8String!,
                             target.subtitle))
            }
            if windows.count > 25 { print("  … and \(windows.count - 25) more") }
        }

        CFRunLoopRun()
        exit(0)
    }
}
