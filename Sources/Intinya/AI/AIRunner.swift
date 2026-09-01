import Foundation

/// Runs a provider CLI once and returns its text.
enum AIRunner {

    /// - Parameters:
    ///   - input: sent on stdin — the transcript, notes, whatever the task needs.
    ///   - binaryOverride: an absolute path configured by the user, if any.
    static func run(
        provider: AIProvider,
        instruction: String,
        input: String,
        binaryOverride: String? = nil,
        timeout: TimeInterval = 300
    ) async throws -> String {
        let tool = binaryOverride?.isEmpty == false ? binaryOverride! : provider.defaultBinary
        guard let executable = ShellEnvironment.locate(tool) else {
            throw AIError.binaryNotFound(tool)
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Utility, not userInitiated: this competes with live transcription,
            // which is the one thing that cannot be redone if it falls behind.
            DispatchQueue.global(qos: .utility).async {
                do {
                    let output = try execute(
                        executable: executable,
                        arguments: provider.arguments(instruction: instruction),
                        input: input,
                        timeout: timeout
                    )
                    continuation.resume(returning: try provider.extractText(from: output))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func execute(
        executable: String,
        arguments: [String],
        input: String,
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ShellEnvironment.current()
        // The CLI is a Node process that will happily take every core. Recording
        // and transcription must win that contest.
        process.qualityOfService = .utility

        // A scratch directory, so the tool does not pick up project config from
        // wherever the app happens to have been launched, and cannot touch the
        // recording. The app owns its files; the tool only transforms text.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-ai-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        process.currentDirectoryURL = scratch

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw AIError.launchFailed(error.localizedDescription)
        }

        // Read concurrently with writing: a large prompt can fill the pipe
        // buffer, and writing everything before reading would deadlock.
        var outputData = Data()
        var errorData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        DispatchQueue.global().async {
            stdinPipe.fileHandleForWriting.write(Data(input.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        // Blocking on the process rather than polling it. The old loop woke this
        // thread ten times a second for the whole run — minutes, on a long
        // meeting — for no reason other than to check a flag.
        let timedOut = Atomic(false)
        let killer = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set(true)
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        process.waitUntilExit()
        killer.cancel()
        // Always drain the readers, even on timeout, or their threads leak.
        group.wait()

        if timedOut.value {
            throw AIError.timedOut(timeout)
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AIError.toolReported(
                message.isEmpty ? "exit code \(process.terminationStatus)" : String(message.prefix(400))
            )
        }
        return output
    }
}


/// Minimal thread-safe flag, for coordinating the timeout with the reader.
private final class Atomic<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Value) {
        lock.lock(); storage = newValue; lock.unlock()
    }
}
