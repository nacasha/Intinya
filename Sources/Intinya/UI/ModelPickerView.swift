import SwiftUI

/// The model manager: a sidebar of compact rows, one detail pane.
///
/// Mirrors the app's main split — material sidebar for navigation, opaque
/// `Theme.content` for the surface you read — so the modal feels like a room
/// in the same house rather than a dialog bolted on. The previous design
/// stacked a full card per model, which meant fifteen cards of repeated
/// buttons and ~2,000 points of scrolling to compare anything; here rows
/// carry only identity and status, and every verb lives in the detail pane.
struct ModelPickerView: View {
    @EnvironmentObject private var store: ModelStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("models.filter") private var filterRaw = Filter.all.rawValue
    @AppStorage("models.selected") private var selectedRaw = ""

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

    /// Falls back to the live model so the pane is never empty on first open.
    private var selected: WhisperModel {
        WhisperModel(rawValue: selectedRaw) ?? store.liveModel
    }

    private func matchesFilter(_ model: WhisperModel) -> Bool {
        switch filter {
        case .all: return true
        case .installed: return store.isDownloaded(model)
        case .available: return !store.isDownloaded(model)
        }
    }

    private func visible(in family: ModelFamily) -> [WhisperModel] {
        WhisperModel.catalog.filter { $0.family == family && matchesFilter($0) }
    }

    private func count(_ filter: Filter) -> Int {
        switch filter {
        case .all: return WhisperModel.catalog.count
        case .installed: return WhisperModel.catalog.filter(store.isDownloaded).count
        case .available: return WhisperModel.catalog.filter { !store.isDownloaded($0) }.count
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 296)
                .background(.ultraThinMaterial)

            Divider().opacity(0.5)

            ModelDetail(model: selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.content)
        }
        .frame(width: 840, height: 600)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Models")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)

            Picker("", selection: $filterRaw) {
                ForEach(Filter.allCases) { option in
                    Text("\(option.label) (\(count(option)))").tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    providerSection("Whisper", family: .whisper)
                    providerSection("Qwen3-ASR", family: .qwen)

                    if visible(in: .whisper).isEmpty && visible(in: .qwen).isEmpty {
                        Text("No models match this filter.")
                            .font(Theme.Font.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            Divider().opacity(0.5)
            roleFooter
        }
    }

    @ViewBuilder
    private func providerSection(_ title: String, family: ModelFamily) -> some View {
        let models = visible(in: family)
        if !models.isEmpty {
            Text(title.uppercased())
                .font(Theme.Font.label)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(models) { model in
                ModelRow(model: model, isSelected: model == selected)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedRaw = model.rawValue }
            }
        }
    }

    /// Which model records live — always visible, since assigning it is the
    /// whole reason this window exists. The enhanced pass has no assigned
    /// model: the Transcribe menu on a recording asks per run.
    private var roleFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            roleLine("LIVE", model: store.liveModel, color: Theme.mic)

            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 9))
                Text("\(WhisperModel.sizeLabel(megabytes: store.totalDiskUsageMB)) on disk")
            }
            .font(Theme.Font.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func roleLine(_ title: String, model: WhisperModel, color: Color) -> some View {
        let ready = store.isDownloaded(model)
        return Button {
            selectedRaw = model.rawValue
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(ready ? color : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(color)
                    .frame(width: 62, alignment: .leading)
                Text(model.displayName)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !ready {
                    Text("not downloaded")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Show \(model.displayName)")
    }
}

// MARK: - Row

/// Identity and status only. Everything actionable lives in the detail pane.
private struct ModelRow: View {
    @EnvironmentObject private var store: ModelStore
    let model: WhisperModel
    let isSelected: Bool

    private var state: ModelStore.DownloadState {
        store.states[model] ?? .notDownloaded
    }

    var body: some View {
        HStack(spacing: 9) {
            statusDot

            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(store.sizeLabel(for: model))
                    if case .downloading(let fraction) = state {
                        Text("· downloading \(Int(fraction * 100))%")
                            .foregroundStyle(Theme.system)
                    } else if case .failed = state {
                        Text("· failed")
                            .foregroundStyle(Theme.recording)
                    }
                }
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if store.liveModel == model {
                RoleDot(color: Theme.mic, label: "Live model")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.09) : .clear)
        }
        .opacity(model.isRecommended ? 1 : 0.55)
    }

    @ViewBuilder
    private var statusDot: some View {
        switch state {
        case .downloading(let fraction):
            ProgressRing(fraction: fraction)
                .frame(width: 14, height: 14)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.recording)
        case .notDownloaded:
            Image(systemName: "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}

/// A small colored dot marking a role in the row, with the name in a tooltip.
private struct RoleDot: View {
    let color: Color
    let label: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(label)
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Theme.system, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Detail

private struct ModelDetail: View {
    @EnvironmentObject private var store: ModelStore
    let model: WhisperModel

    private var state: ModelStore.DownloadState {
        store.states[model] ?? .notDownloaded
    }
    private var isLive: Bool { store.isActiveLive(model) }
    private var result: BenchmarkResult? { store.benchmarks[model] }
    private var isBenchmarking: Bool { store.benchmarkingModel == model }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                metrics

                if case .downloaded = state {
                    roles
                    benchmark
                }
                installSection

                if let error = store.lastError {
                    Text(error)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.recording)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.smooth(duration: 0.25), value: state)
        .animation(.smooth(duration: 0.25), value: store.liveModelRaw)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(model.displayName)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                if !model.isRecommended {
                    Tag(text: "NOT RECOMMENDED", color: Theme.recording)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Text(model.family == .qwen ? "Qwen3-ASR · MLX" : "Whisper · CoreML")
                Text("·")
                Text(store.sizeLabel(for: model))
                if model.isQuantized {
                    Text("·")
                    Text("compressed")
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)

            Text(model.note)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// Expected ratings until measured; measured numbers take over and say so.
    private var metrics: some View {
        HStack(spacing: 10) {
            if let result {
                MetricTile(
                    icon: "checkmark.seal.fill",
                    value: "\(result.accuracyPercent)%",
                    title: "accurate",
                    footnote: "measured here",
                    color: accuracyColor(result.wordErrorRate)
                )
                .help("Measured on synthesised speech read by an Indonesian voice, "
                    + "which over-pronounces English terms. Use it as a sanity check, "
                    + "not as a ranking of code-switching ability.")
                MetricTile(
                    icon: "gauge.with.needle.fill",
                    value: String(format: "%.1f×", result.realtimeFactor),
                    title: "realtime",
                    footnote: result.liveVerdict.label,
                    color: liveColor(result.liveVerdict)
                )
                .help("Measured on this Mac. This is the number to trust when "
                    + "choosing a live model.")
                MetricTile(
                    icon: "bolt.fill",
                    value: String(format: "%.1fs", result.loadSeconds),
                    title: "to load",
                    footnote: "at recording start",
                    color: .secondary
                )
            } else {
                MetricTile(
                    icon: "checkmark.seal",
                    value: model.expectedAccuracy.label,
                    title: "accuracy",
                    footnote: "expected",
                    color: gradeColor(model.expectedAccuracy)
                )
                MetricTile(
                    icon: "gauge.with.needle",
                    value: model.expectedLive.label,
                    title: "for live use",
                    footnote: "expected",
                    color: liveColor(model.expectedLive)
                )
            }
        }
    }

    /// Assigning the live model is the primary act in this window. Enhanced
    /// runs are deliberately not assigned here — the Transcribe menu on a
    /// recording asks which model to use at the moment it matters.
    private var roles: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Use this model")
            RoleCard(
                title: "Live transcription",
                detail: "Transcribes while you record. Needs to beat realtime. "
                    + "For re-transcribing a finished recording, pick any installed model "
                    + "from the Transcribe menu on that recording.",
                color: Theme.mic,
                isActive: isLive
            ) { store.liveModel = model }
        }
    }

    private var benchmark: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Benchmark")

            if isBenchmarking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(store.benchmarkStatus ?? "Measuring…")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        store.benchmark(model)
                    } label: {
                        Label(result == nil ? "Measure on this Mac" : "Re-measure", systemImage: "stopwatch")
                    }
                    .controlSize(.small)
                    .disabled(store.benchmarkingModel != nil || !store.canBenchmark)

                    if !store.canBenchmark {
                        Text("Install an Indonesian system voice to enable benchmarking")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let result {
                Text("“\(result.transcript)”")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    }
                    .help("What this model heard in the benchmark sample — read it to judge quality yourself.")
            }
        }
    }

    @ViewBuilder
    private var installSection: some View {
        switch state {
        case .notDownloaded:
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Not installed")
                Button {
                    store.download(model)
                } label: {
                    Label("Download \(model.sizeLabel)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }

        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Downloading")
                HStack(spacing: 10) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                    Text("\(Int(fraction * 100))%")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { store.cancelDownload(model) }
                        .controlSize(.small)
                }
            }

        case .downloaded:
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Installed · \(store.sizeLabel(for: model))")
                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        store.delete(model)
                    } label: {
                        Label("Delete from disk", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(isLive)

                    if isLive {
                        Text("In use as the live model — pick another first.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Download failed")
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.recording)
                    .lineLimit(3)
                Button {
                    store.download(model)
                } label: {
                    Label("Retry download", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Font.label)
            .foregroundStyle(.tertiary)
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

private struct MetricTile: View {
    let icon: String
    let value: String
    let title: String
    let footnote: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(footnote)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(minWidth: 108, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.08))
        }
    }
}

/// One role, as a pressable card: active state shows as a filled border, and
/// pressing an inactive card assigns the role to the shown model.
private struct RoleCard: View {
    let title: String
    let detail: String
    let color: Color
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(color)
                    }
                }
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? color.opacity(0.10) : Color.primary.opacity(0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isActive ? color.opacity(0.55) : Color.primary.opacity(0.08),
                            lineWidth: isActive ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .help(isActive ? "\(title) uses this model now" : "Use this model for \(title.lowercased())")
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
