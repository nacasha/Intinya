import Foundation

/// `Meeting --polish <sessionDir> [--dry-run]`
///
/// Runs tier 3 over a finished session. Useful on its own for re-polishing old
/// recordings, and it exercises the whole CLI-provider path without the UI.
enum PolishCLI {

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        let args = CommandLine.arguments
        let dryRun = args.contains("--dry-run")
        let rest = Array(args.drop(while: { $0 != "--polish" }).dropFirst())
            .filter { !$0.hasPrefix("--") }

        guard let path = rest.first else {
            FileHandle.standardError.write(Data("usage: Meeting --polish <sessionDir> [--dry-run]\n".utf8))
            exit(1)
        }
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        guard let transcript = SessionStore.loadTranscript(in: directory),
              !transcript.segments.isEmpty else {
            FileHandle.standardError.write(Data("No transcript.json in that session.\n".utf8))
            exit(1)
        }
        let segments = transcript.segments.sorted { $0.start < $1.start }

        print("Session:  \(directory.lastPathComponent)")
        print("Segments: \(segments.count)")
        if let claude = ShellEnvironment.locate("claude") {
            print("Provider: Claude Code — \(claude)")
        } else {
            FileHandle.standardError.write(Data("claude not found on the captured PATH.\n".utf8))
            exit(1)
        }
        print("\nRunning… (a long meeting can take a couple of minutes)\n")

        var failed = false

        Task {
            defer { CFRunLoopStop(CFRunLoopGetMain()) }
            do {
                let started = Date()
                var result = MeetingAI.Result()
                for action in AIAction.runAll {
                    print("  \(action.title)…")
                    let partial = try await MeetingAI.run(
                        action: action,
                        segments: segments,
                        glossary: Glossary.active,
                        provider: ClaudeCodeProvider(),
                        binaryOverride: nil
                    )
                    result.corrections.merge(partial.corrections) { _, new in new }
                    if !partial.summary.isEmpty { result.summary = partial.summary }
                    result.terms += partial.terms
                }
                let elapsed = Date().timeIntervalSince(started)

                print(String(format: "Done in %.1fs — %d line(s) corrected\n", elapsed, result.corrections.count))

                for (number, corrected) in result.corrections.sorted(by: { $0.key < $1.key }) {
                    let original = segments[number - 1].text
                    print("── line \(number)")
                    print("   before: \(original)")
                    print("   after:  \(corrected)\n")
                }

                if !result.terms.isEmpty {
                    print("Glossary candidates: \(result.terms.joined(separator: ", "))\n")
                }
                print("── Summary\n")
                print(result.summary.isEmpty ? "(none)" : result.summary)

                guard !dryRun else {
                    print("\n(dry run — nothing written)")
                    return
                }

                var updated = segments
                for (number, corrected) in result.corrections {
                    updated[number - 1].text = corrected
                    updated[number - 1].tier = .polished
                }
                var out = transcript
                out.segments = updated
                SessionStore.saveTranscript(out, in: directory)

                if !result.summary.isEmpty {
                    let existing = Notes.load(in: directory)
                    let merged = existing.isEmpty
                        ? result.summary
                        : existing + "\n\n---\n\n" + result.summary
                    Notes.save(merged, in: directory)
                }
                // Same learning loop as the app path: terms found here prime
                // Whisper's decoder on the next recording.
                let learned = Glossary.learn(result.terms)
                if !learned.isEmpty {
                    print("Learned \(learned.count) new term(s) for future transcripts.")
                }
                print("\nWrote transcript.json and notes.md")
            } catch {
                FileHandle.standardError.write(Data("FAILED: \(error.localizedDescription)\n".utf8))
                failed = true
            }
        }

        CFRunLoopRun()
        exit(failed ? 1 : 0)
    }
}
