import Foundation

// Custom entry point so the app can also run headless.
//
//   Meeting.app/Contents/MacOS/Meeting --benchmark [variant ...]
//
// Benchmarking from the terminal is useful on its own — comparing four models
// means four multi-minute model loads, which is a bad fit for a modal sheet.
if CommandLine.arguments.contains("--benchmark") {
    BenchmarkCLI.main()
} else if CommandLine.arguments.contains("--list-models") {
    BenchmarkCLI.listModels()
} else if CommandLine.arguments.contains("--enhance") {
    EnhanceCLI.main()
} else if CommandLine.arguments.contains("--mictest") {
    MicTestCLI.main()
} else if CommandLine.arguments.contains("--chunkbench") {
    ChunkBenchCLI.main()
} else if CommandLine.arguments.contains("--screens") {
    ScreenCLI.main()
} else if CommandLine.arguments.contains("--polish") {
    PolishCLI.main()
} else {
    MeetingApp.main()
}
