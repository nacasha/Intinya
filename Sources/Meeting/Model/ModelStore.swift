import Foundation
import SwiftUI
import WhisperKit

/// Tracks which models are on disk, downloads them on demand, and holds
/// benchmark results.
enum ModelRole {
    case live
    case enhanced
    case both

    var label: String {
        switch self {
        case .live: return "live"
        case .enhanced: return "enhanced"
        case .both: return "live and enhanced"
        }
    }
}

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
    @AppStorage("liveModel") var liveModelRaw: String = WhisperModel.defaultLive.rawValue
    /// The model used for the tier-2 enhanced pass.
    @AppStorage("enhancedModel") var enhancedModelRaw: String = WhisperModel.defaultEnhanced.rawValue

    var liveModel: WhisperModel {
        get { WhisperModel(rawValue: liveModelRaw) ?? .defaultLive }
        set { liveModelRaw = newValue.rawValue }
    }

    var enhancedModel: WhisperModel {
        get { WhisperModel(rawValue: enhancedModelRaw) ?? .defaultEnhanced }
        set { enhancedModelRaw = newValue.rawValue }
    }

    /// A model in use by either role must not be deleted out from under it.
    func role(of model: WhisperModel) -> ModelRole? {
        if model == liveModel && model == enhancedModel { return .both }
        if model == liveModel { return .live }
        if model == enhancedModel { return .enhanced }
        return nil
    }

    var isEnhancedModelReady: Bool { isDownloaded(enhancedModel) }

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
        Self.downloadRoot.appendingPathComponent(model.rawValue, isDirectory: true)
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

    /// A model is only usable once all three CoreML components are present —
    /// a partial download must not be presented as ready.
    private func isComplete(_ model: WhisperModel) -> Bool {
        let base = folder(for: model)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        return required.allSatisfy {
            FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path)
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

        downloadTasks[model] = Task { [weak self] in
            defer { Task { @MainActor in self?.downloadTasks[model] = nil } }
            do {
                _ = try await WhisperKit.download(variant: model.rawValue) { progress in
                    Task { @MainActor in
                        guard let self else { return }
                        if case .downloading = self.states[model] {
                            self.states[model] = .downloading(progress.fractionCompleted)
                        }
                    }
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
        if let role = role(of: model) {
            lastError = "\(model.displayName) is the active \(role.label) model. Pick another first."
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
