import SwiftUI

struct ModelPickerView: View {
    @EnvironmentObject private var store: ModelStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("models.filter") private var filterRaw = Filter.all.rawValue

    enum Filter: String, CaseIterable, Identifiable {
        case all, installed, available
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .installed: return "Installed"
            case .available: return "Not Installed"
            }
        }
    }

    private var filter: Filter { Filter(rawValue: filterRaw) ?? .all }

    private var visible: [WhisperModel] {
        WhisperModel.catalog.filter { model in
            switch filter {
            case .all: return true
            case .installed: return store.isDownloaded(model)
            case .available: return !store.isDownloaded(model)
            }
        }
    }

    private func count(_ filter: Filter) -> Int {
        switch filter {
        case .all: return WhisperModel.catalog.count
        case .installed: return WhisperModel.catalog.filter(store.isDownloaded).count
        case .available: return WhisperModel.catalog.filter { !store.isDownloaded($0) }.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(WhisperModel.catalog) { model in
                        ModelCard(model: model)
                    }
                }
                .padding(20)
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 640, height: 620)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Models")
                        .font(Theme.Font.display)
                    Text("Multilingual only — English-only models are excluded because they cannot transcribe Indonesian.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Picker("", selection: $filterRaw) {
                ForEach(Filter.allCases) { option in
                    Text("\(option.label) (\(count(option)))").tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.top, 2)

            HStack(spacing: 14) {
                RoleSummary(
                    title: "Live",
                    model: store.liveModel,
                    color: Theme.mic,
                    ready: store.isDownloaded(store.liveModel)
                )
                RoleSummary(
                    title: "Enhanced",
                    model: store.enhancedModel,
                    color: Theme.system,
                    ready: store.isDownloaded(store.enhancedModel)
                )
                Spacer()
            }
            .padding(.top, 4)

            if let error = store.lastError {
                Text(error)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("\(WhisperModel.sizeLabel(megabytes: store.totalDiskUsageMB)) on disk", systemImage: "internaldrive")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let benchmarking = store.benchmarkingModel {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(store.benchmarkStatus ?? "Measuring \(benchmarking.displayName)…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !store.canBenchmark {
                Text("Install an Indonesian system voice to enable benchmarking")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }
}

// MARK: - Card

private struct ModelCard: View {
    @EnvironmentObject private var store: ModelStore
    let model: WhisperModel

    private var state: ModelStore.DownloadState {
        store.states[model] ?? .notDownloaded
    }
    private var role: ModelRole? { store.role(of: model) }
    private var result: BenchmarkResult? { store.benchmarks[model] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            Text(model.note)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            metrics
            actionRow
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(role != nil ? Theme.mic.opacity(0.10) : Color.primary.opacity(0.04))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .stroke(role != nil ? Theme.mic.opacity(0.5) : Color.primary.opacity(0.08),
                        lineWidth: role != nil ? 1.5 : 1)
        }
        .opacity(model.isRecommended ? 1 : 0.62)
        .animation(.smooth(duration: 0.25), value: state)
        .animation(.smooth(duration: 0.25), value: store.liveModelRaw)
        .animation(.smooth(duration: 0.25), value: store.enhancedModelRaw)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Text(model.displayName)
                .font(Theme.Font.title)

            if store.liveModel == model {
                Tag(text: "LIVE", color: Theme.mic)
            }
            if store.enhancedModel == model {
                Tag(text: "ENHANCED", color: Theme.system)
            }
            if case .downloaded = state {
                Tag(text: "INSTALLED", color: .green)
            }
            if model.isQuantized {
                Tag(text: "COMPRESSED", color: .secondary)
            }
            if !model.isRecommended {
                Tag(text: "NOT RECOMMENDED", color: Theme.recording)
            }

            Spacer()

            HStack(spacing: 5) {
                if case .downloaded = state {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                }
                Text(model.sizeLabel)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Expected ratings until the model has been measured; once a benchmark has
    /// run, the measured numbers take over and are labelled as such.
    private var metrics: some View {
        HStack(spacing: 8) {
            if let result {
                Metric(
                    icon: "checkmark.seal",
                    title: "\(result.accuracyPercent)% accurate",
                    subtitle: "measured",
                    color: accuracyColor(result.wordErrorRate)
                )
                .help("Measured on synthesised speech read by an Indonesian voice, "
                    + "which over-pronounces English terms. Use it as a sanity check, "
                    + "not as a ranking of code-switching ability.")
                Metric(
                    icon: "gauge.with.needle",
                    title: String(format: "%.1f× realtime", result.realtimeFactor),
                    subtitle: result.liveVerdict.label,
                    color: liveColor(result.liveVerdict)
                )
                .help("Measured on this Mac. This is the number to trust when "
                    + "choosing a live model.")
            } else {
                Metric(
                    icon: "checkmark.seal",
                    title: model.expectedAccuracy.label,
                    subtitle: "expected",
                    color: gradeColor(model.expectedAccuracy)
                )
                Metric(
                    icon: "gauge.with.needle",
                    title: model.expectedLive.label,
                    subtitle: "expected",
                    color: liveColor(model.expectedLive)
                )
            }
            Spacer()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            switch state {
            case .notDownloaded:
                Button {
                    store.download(model)
                } label: {
                    Label("Download \(model.sizeLabel)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                Text("\(Int(fraction * 100))%")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancelDownload(model) }
                    .controlSize(.small)

            case .downloaded:
                Button("Use for live") { store.liveModel = model }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.liveModel == model)
                    .help("Transcribes during the meeting. Needs to beat realtime.")

                Button("Use for enhanced") { store.enhancedModel = model }
                    .controlSize(.small)
                    .disabled(store.enhancedModel == model)
                    .help("Re-transcribes the recording afterwards for accuracy. Speed matters less.")

                Button {
                    store.benchmark(model)
                } label: {
                    Label(result == nil ? "Measure" : "Re-measure", systemImage: "stopwatch")
                }
                .controlSize(.small)
                .disabled(store.benchmarkingModel != nil || !store.canBenchmark)

                Button(role: .destructive) {
                    store.delete(model)
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .disabled(role != nil)

            case .failed(let message):
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
                    .lineLimit(2)
                Button("Retry") { store.download(model) }
                    .controlSize(.small)
            }

            Spacer()
        }
    }

    private func gradeColor(_ grade: AccuracyGrade) -> Color {
        switch grade {
        case .unusable, .poor: return Theme.recording
        case .workable: return .orange
        case .good, .veryGood, .excellent: return .green
        }
    }

    private func accuracyColor(_ wer: Double) -> Color {
        if wer <= 0.15 { return .green }
        if wer <= 0.35 { return .orange }
        return Theme.recording
    }

    private func liveColor(_ suitability: LiveSuitability) -> Color {
        switch suitability {
        case .comfortable: return .green
        case .marginal: return .orange
        case .tooSlow: return .secondary
        }
    }
}

// MARK: - Bits

private struct Metric: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.10))
        }
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.Font.label)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}


/// Shows which model each role currently uses, and whether it is downloaded.
private struct RoleSummary: View {
    let title: String
    let model: WhisperModel
    let color: Color
    let ready: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? color : Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased())
                    .font(Theme.Font.label)
                    .foregroundStyle(color)
                Text(ready ? model.displayName : "\(model.displayName) — not downloaded")
                    .font(Theme.Font.caption)
                    .foregroundStyle(ready ? .secondary : Color.orange)
            }
        }
    }
}
