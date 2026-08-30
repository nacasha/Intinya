import Foundation

/// The environment a GUI-launched app must borrow before it can run CLI tools.
///
/// A process launched from Finder inherits a minimal PATH — on this machine
/// `/usr/gnu/bin:/usr/local/bin:/bin:/usr/bin:.` — which excludes `~/.local/bin`,
/// npm/bun global prefixes, and everything else a developer actually installs
/// into. Worse, `claude` is often a shell *alias*, which no spawned process can
/// ever see. Naively running `claude` fails with "command not found", and that
/// is the usual reason this whole approach appears not to work.
///
/// So: start the user's login shell once, capture its entire environment, and
/// hand that to every child process.
enum ShellEnvironment {

    private static var cached: [String: String]?
    private static let lock = NSLock()

    /// Captured environment, resolved once per launch.
    static func current() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let resolved = capture() ?? ProcessInfo.processInfo.environment
        cached = resolved
        return resolved
    }

    static func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// Runs the login shell and reads back its environment.
    ///
    /// The shell writes to a temp file rather than stdout: a `.zshrc` that
    /// prints a banner, a motd, or a version-manager notice would otherwise be
    /// mixed into the output. `env -0` is null-delimited so values containing
    /// newlines survive intact.
    private static func capture(timeout: TimeInterval = 5) -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-shell-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: captureURL) }

        // Interactive first (that is where most PATH edits live), then a plain
        // login shell if an interactive rc file blocks or exits early.
        for arguments in [["-i", "-l", "-c"], ["-l", "-c"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = arguments + ["/usr/bin/env -0 > \"$MEETING_ENV_CAPTURE\""]
            var environment = ProcessInfo.processInfo.environment
            environment["MEETING_ENV_CAPTURE"] = captureURL.path
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            guard (try? process.run()) != nil else { continue }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                usleep(50_000)
            }
            if process.isRunning {
                process.terminate()
                continue
            }

            guard let data = try? Data(contentsOf: captureURL), !data.isEmpty else { continue }
            let parsed = parse(data)
            if parsed["PATH"] != nil { return parsed }
        }
        return nil
    }

    private static func parse(_ data: Data) -> [String: String] {
        var environment: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let line = String(data: entry, encoding: .utf8),
                  let separator = line.firstIndex(of: "=")
            else { continue }
            let key = String(line[line.startIndex..<separator])
            let value = String(line[line.index(after: separator)...])
            environment[key] = value
        }
        return environment
    }

    /// Absolute path of a CLI tool, searched across the captured PATH.
    static func locate(_ tool: String) -> String? {
        // An absolute path configured by hand wins outright.
        if tool.contains("/") {
            return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil
        }

        var directories = (current()["PATH"] ?? "").split(separator: ":").map(String.init)
        // Common install locations, in case the shell probe failed entirely.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        directories += [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]

        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
