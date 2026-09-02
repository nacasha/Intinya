import AudioCommon
import Foundation
import SwiftUI
import WhisperKit

/// Tracks which models are on disk, downloads them on demand, and holds
/// benchmark results.
@MainActor
final class ModelStore: ObservableObject {

    enum DownloadState: Equatable {
        case notDownloaded
        case downloading(Double)   // 0...1
        case downloaded(sizeMB: Int)
        case failed(String)
    }

    @Published private(set) var states: [WhisperModel: DownloadState] = [:]
    @Published private(set) var benchmarks: [WhisperModel: BenchmarkResult] = [:]
    @Published private(set) var benchmarkingModel: WhisperModel?
    @Published private(set) var benchmarkStatus: String?
    @Published private(set) var lastError: String?

    /// The model used for live transcription. Persisted across launches.
    ///
    /// The only assigned role. There is no "enhanced model" setting — the
    /// enhanced pass takes its model from the Transcribe menu at the moment
    /// you run it, because that choice depends on the recording at hand.
    @AppStorage("liveModel") var liveModelRaw: String = WhisperModel.defaultLive.rawValue

    var liveModel: WhisperModel {
        get { WhisperModel(rawValue: liveModelRaw) ?? .defaultLive }
        set { liveModelRaw = newValue.rawValue }
    }

    /// The live model must not be deleted out from under the recorder.
    func isActiveLive(_ model: WhisperModel) -> Bool { model == liveModel }

    private var downloadTasks: [WhisperModel: Task<Void, Never>] = [:]
    /// Measured on-disk sizes, filled in off the main thread.
    private var sizeCache: [WhisperModel: Int] = [:]

    init() {
        // Existence checks only — see refreshStates().
        refreshStates()
        recomputeSizes()
    }

    // MARK: - Disk state

    /// WhisperKit's default download location.
    static var downloadRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    func folder(for model: WhisperModel) -> URL {
        switch model.family {
        case .whisper:
            return Self.downloadRoot.appendingPathComponent(model.rawValue, isDirectory: true)
        case .qwen:
            // speech-swift's own cache layout — the engine loads from here, so
            // the store must point at the same place or downloads double up.
            // getCacheDirectory only throws when Caches/ itself is unavailable;
            // the fallback mirrors its sanitised-key layout for that edge.
            return (try? HuggingFaceDownloader.getCacheDirectory(for: model.rawValue))
                ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("qwen3-speech", isDirectory: true)
                    .appendingPathComponent(
                        HuggingFaceDownloader.sanitizedCacheKey(for: model.rawValue),
                        isDirectory: true
                    )
        }
    }

    /// Cheap: three `fileExists` calls per model, nothing recursive.
    ///
    /// This runs during `@StateObject` initialisation, which happens before
    /// SwiftUI instantiates the scene. Anything slow here blocks the main thread
    /// before the first frame — the window is never created and the app looks
    /// blank. Measuring directory sizes here (which recursed through multi-GB
    /// CoreML bundles) did exactly that.
    func refreshStates() {
        for model in WhisperModel.allCases {
            // Preserve in-flight downloads across a refresh.
            if case .downloading = states[model] { continue }
            states[model] = isComplete(model)
                ? .downloaded(sizeMB: sizeCache[model] ?? model.downloadMB)
                : .notDownloaded
        }
    }

    /// A model is only usable once all its components are present — a partial
    /// download must not be presented as ready.
    private func isComplete(_ model: WhisperModel) -> Bool {
        let base = folder(for: model)
        switch model.family {
        case .whisper:
            let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
            return required.allSatisfy {
                FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path)
            }
        case .qwen:
            // vocab.json is the last file fromPretrained reads; weightsExist
            // alone would pass between the weights and tokenizer downloads.
            return HuggingFaceDownloader.weightsExist(in: base)
                && FileManager.default.fileExists(atPath: base.appendingPathComponent("vocab.json").path)
        }
    }

    /// Measures actual disk usage in the background and refines the displayed
    /// sizes once known. Until then the catalog's download size stands in.
    private func recomputeSizes() {
        let targets = WhisperModel.allCases
            .filter { isDownloaded($0) }
            .map { ($0, folder(for: $0)) }
        guard !targets.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            var sizes: [WhisperModel: Int] = [:]
            for (model, url) in targets {
                sizes[model] = Self.directorySize(url)
            }
            await MainActor.run { self?.applySizes(sizes) }
        }
    }

    private func applySizes(_ sizes: [WhisperModel: Int]) {
        sizeCache.merge(sizes) { _, new in new }
        for (model, size) in sizes {
            if case .downloaded = states[model] {
                states[model] = .downloaded(sizeMB: size)
            }
        }
    }

    nonisolated private static func directorySize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        var total = 0
        for case let fileURL as URL in enumerator {
            total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total / 1_000_000
    }

    var totalDiskUsageMB: Int {
        states.values.reduce(0) { sum, state in
            if case .downloaded(let mb) = state { return sum + mb }
            return sum
        }
    }

    // MARK: - Download

    func download(_ model: WhisperModel) {
        guard downloadTasks[model] == nil else { return }
        states[model] = .downloading(0)
        lastError = nil

        let destination = folder(for: model)
        downloadTasks[model] = Task { [weak self] in
            defer { Task { @MainActor in self?.downloadTasks[model] = nil } }
            do {
                switch model.family {
                case .whisper:
                    _ = try await WhisperKit.download(variant: model.rawValue) { progress in
                        Task { @MainActor in
                            self?.applyDownloadProgress(model, progress.fractionCompleted)
                        }
                    }
                case .qwen:
                    // Same call, file list, and destination as speech-swift's
                    // fromPretrained, so loading later finds a warm cache.
                    try await HuggingFaceDownloader.downloadWeights(
                        modelId: model.rawValue,
                        to: destination,
                        additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json"],
                        progressHandler: { fraction in
                            Task { @MainActor in
                                self?.applyDownloadProgress(model, fraction)
                            }
                        }
                    )
                }
                await MainActor.run {
                    // Must clear the downloading state first: `refreshStates`
                    // deliberately skips models mid-download, so leaving it set
                    // pinned the row at 100% forever.
                    self?.settle(model)
                    self?.recomputeSizes()
                }
            } catch {
                await MainActor.run {
                    self?.states[model] = .failed(error.localizedDescription)
                    self?.lastError = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyDownloadProgress(_ model: WhisperModel, _ fraction: Double) {
        if case .downloading = states[model] {
            states[model] = .downloading(fraction)
        }
    }

    func cancelDownload(_ model: WhisperModel) {
        downloadTasks[model]?.cancel()
        downloadTasks[model] = nil
        // A cancelled download leaves a partial folder behind; clear it so the
        // model doesn't linger in a half-present state.
        try? FileManager.default.removeItem(at: folder(for: model))
        settle(model)
    }

    /// Re-evaluates one model from disk, whatever it was doing before.
    private func settle(_ model: WhisperModel) {
        states[model] = isComplete(model)
            ? .downloaded(sizeMB: sizeCache[model] ?? model.downloadMB)
            : .notDownloaded
    }

    func delete(_ model: WhisperModel) {
        if isActiveLive(model) {
            lastError = "\(model.displayName) is the active live model. Pick another first."
            return
        }
        do {
            try FileManager.default.removeItem(at: folder(for: model))
            benchmarks[model] = nil
            refreshStates()
        } catch {
            lastError = "Could not delete: \(error.localizedDescription)"
        }
    }

    // MARK: - Benchmark

    var canBenchmark: Bool { SpeechSample.isAvailable }

    /// Measures the model on this machine using synthesised Indonesian speech.
    func benchmark(_ model: WhisperModel) {
        guard benchmarkingModel == nil else { return }
        benchmarkingModel = model
        benchmarkStatus = "Preparing sample…"
        lastError = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.benchmarkingModel = nil
                    self.benchmarkStatus = nil
                }
            }
            do {
                let sample = try await SpeechSample.render()
                let result = try await ModelBenchmark.run(model: model, sample: sample) { message in
                    Task { @MainActor in self.benchmarkStatus = message }
                }
                await MainActor.run {
                    self.benchmarks[model] = result
                    self.refreshStates()
                }
            } catch {
                await MainActor.run {
                    self.lastError = "Benchmark failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Measured size once known, otherwise the catalog's download size.
    func sizeLabel(for model: WhisperModel) -> String {
        WhisperModel.sizeLabel(megabytes: sizeCache[model] ?? model.downloadMB)
    }

    func isDownloaded(_ model: WhisperModel) -> Bool {
        if case .downloaded = states[model] { return true }
        return false
    }
}
