import Foundation

/// Headless benchmark runner.
enum BenchmarkCLI {

    static func listModels() {
        print("Multilingual models (English-only variants are excluded):\n")
        for model in WhisperModel.catalog {
            let flag = model.isRecommended ? " " : "!"
            print(String(
                format: "%@ %-38s %8s  %-10s %@",
                flag,
                (model.rawValue as NSString).utf8String!,
                (model.sizeLabel as NSString).utf8String!,
                (model.expectedAccuracy.label as NSString).utf8String!,
                model.expectedLive.label
            ))
        }
        print("\n! = not recommended for Indonesian")
    }

    static func main() {
        let args = CommandLine.arguments
        let requested = args
            .drop(while: { $0 != "--benchmark" })
            .dropFirst()
            .filter { !$0.hasPrefix("--") }

        let models: [WhisperModel] = requested.isEmpty
            ? [WhisperModel.defaultLive]
            : requested.compactMap { name in
                WhisperModel(rawValue: name)
                    ?? WhisperModel.allCases.first { $0.rawValue.contains(name) }
            }

        guard !models.isEmpty else {
            FileHandle.standardError.write(Data("No matching model. Try --list-models\n".utf8))
            exit(1)
        }

        // Line-buffer stdout so progress appears when piped, not all at the end.
        setvbuf(stdout, nil, _IOLBF, 0)

        // The main run loop must keep spinning: AVSpeechSynthesizer delivers its
        // callbacks through it, so blocking main on a semaphore would deadlock
        // the very synthesis we are waiting for.
        var failed = false

        Task {
            defer {
                CFRunLoopStop(CFRunLoopGetMain())
            }

            print("Rendering Indonesian benchmark sample…")
            let sample: SpeechSample.Sample
            do {
                sample = try await SpeechSample.render()
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                failed = true
                return
            }

            print(String(format: "Sample: %.1fs of speech\n", sample.duration))
            print("Reference:")
            print("  \(SpeechSample.referenceText)\n")

            for model in models {
                print("── \(model.displayName)  (\(model.rawValue))")
                do {
                    let result = try await ModelBenchmark.run(model: model, sample: sample) { message in
                        print("   \(message)")
                    }
                    report(result)
                } catch {
                    print("   FAILED: \(error.localizedDescription)\n")
                    failed = true
                }
            }

            print("Notes:")
            print("  Speed is the reliable number — it is measured on this machine.")
            print("  Accuracy is measured on clean synthesised speech read by an")
            print("  Indonesian TTS voice, which pronounces embedded English terms")
            print("  with Indonesian phonetics. Every model mangles them similarly,")
            print("  so the accuracy spread between models is compressed. Judge")
            print("  code-switching on a real recording, not on this number.")
        }

        CFRunLoopRun()
        exit(failed ? 1 : 0)
    }

    private static func report(_ result: BenchmarkResult) {
        print(String(format: "   load          %.1fs", result.loadSeconds))
        print(String(format: "   transcribe    %.2fs for %.1fs of audio", result.transcribeSeconds, result.audioSeconds))
        print(String(format: "   speed         %.1fx realtime  (%@)", result.realtimeFactor, result.liveVerdict.label))
        print(String(format: "   accuracy      %d%%  (WER %.2f)", result.accuracyPercent, result.wordErrorRate))
        print("   output        \(result.transcript)")
        print("")
    }
}
