import Foundation

/// Headless tier-2 runner:
///
///   Meeting --enhance <sessionDirectory> [modelVariant]
///
/// Useful for re-running the enhanced pass over an old session, and for
/// checking what a different model would have produced.
enum EnhanceCLI {

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)

        let args = CommandLine.arguments
        let rest = Array(args.drop(while: { $0 != "--enhance" }).dropFirst())
            .filter { !$0.hasPrefix("--") }

        guard let path = rest.first else {
            FileHandle.standardError.write(Data("usage: Meeting --enhance <sessionDir> [model]\n".utf8))
            exit(1)
        }

        let model = rest.dropFirst().first.flatMap { name in
            WhisperModel(rawValue: name) ?? WhisperModel.allCases.first { $0.rawValue.contains(name) }
        } ?? .defaultLive

        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var failed = false

        print("Session: \(directory.lastPathComponent)")
        print("Model:   \(model.displayName)  (\(model.rawValue))\n")

        Task {
            defer { CFRunLoopStop(CFRunLoopGetMain()) }

            let pass = EnhancedPass(model: model)
            let started = Date()
            var lines: [(AudioSource, TimedText)] = []

            do {
                try await pass.run(
                    sessionDirectory: directory,
                    onProgress: { progress in
                        print(String(format: "  [%3.0f%%] %@", progress.fraction * 100, progress.message))
                    },
                    onWindow: { window in
                        for segment in window.segments {
                            lines.append((window.source, segment))
                        }
                    }
                )
            } catch {
                FileHandle.standardError.write(Data("FAILED: \(error.localizedDescription)\n".utf8))
                failed = true
                return
            }

            let elapsed = Date().timeIntervalSince(started)
            print("\nTranscript (\(lines.count) segments, \(String(format: "%.1f", elapsed))s):\n")
            for (source, line) in lines.sorted(by: { $0.1.start < $1.1.start }) {
                print(String(format: "  [%@ %6.1fs] %@", source.label, line.start, line.text))
            }

            // Persist so the session opens in the app with its transcript.
            let segments = lines.map { source, line in
                TranscriptSegment(
                    source: source,
                    start: line.start,
                    end: line.end,
                    text: line.text,
                    tier: .enhanced
                )
            }.sorted { $0.start < $1.start }

            let existing = SessionStore.loadTranscript(in: directory)
            let transcript = SessionTranscript(
                segments: segments,
                recordedAt: existing?.recordedAt
                    ?? (try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date(),
                duration: segments.last?.end ?? 0,
                liveModel: existing?.liveModel,
                enhancedModel: model.rawValue
            )
            if SessionStore.saveTranscript(transcript, in: directory) {
                print("\nWrote transcript.json (\(segments.count) segments)")
            }
        }

        CFRunLoopRun()
        exit(failed ? 1 : 0)
    }
}
