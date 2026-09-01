import SwiftUI

/// Everything configurable that is not a document.
///
/// Glossary and meeting types get their own screens because they are content
/// you edit; this is for the settings behind them — which models run, which CLI
/// answers the AI actions, and where it all lives on disk.
struct SettingsView: View {
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    @EnvironmentObject private var sessions: SessionStore

    /// Same key the AI runner reads.
    @AppStorage("ai.binaryPath") private var binaryPath: String = ""

    @State private var toolStatus: ToolStatus = .checking
    @State private var recordingsBytes: Int?
    @State private var modelBytes: Int?
    @State private var showingModels = false

    private enum ToolStatus: Equatable {
        case checking
        case found(path: String, version: String)
        case missing
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    transcription
                    library
                    ai
                    storage
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.content)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showingModels) {
            ModelPickerView().environmentObject(models)
        }
        .task {
            checkTool()
            measureDisk()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(Theme.Font.display)
            Text("Models, the AI tool, and where recordings are kept.")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }

    // MARK: - Transcription

    private var downloaded: [WhisperModel] {
        WhisperModel.catalog.filter { models.isDownloaded($0) }
    }

    private var transcription: some View {
        Section2(title: "Transcription", subtitle: "Which Whisper model runs when.") {
            VStack(alignment: .leading, spacing: 10) {
                RolePicker(
                    role: "Live",
                    detail: "Runs during the meeting. Must beat realtime.",
                    current: models.liveModel,
                    choices: downloaded,
                    isReady: models.isDownloaded(models.liveModel)
                ) { models.liveModel = $0 }

                RolePicker(
                    role: "Enhanced",
                    detail: "Re-transcribes afterwards. Accuracy over speed.",
                    current: models.enhancedModel,
                    choices: downloaded,
                    isReady: models.isEnhancedModelReady
                ) { models.enhancedModel = $0 }
            }
        }
    }

    private var library: some View {
        Section2(
            title: "Downloaded Models",
            subtitle: downloaded.isEmpty
                ? "None yet. Open Manage Models to download one."
                : "On this Mac and ready to use."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(downloaded) { model in
                    DownloadedModelRow(
                        model: model,
                        isLive: models.liveModel == model,
                        isEnhanced: models.enhancedModel == model,
                        sizeLabel: models.sizeLabel(for: model),
                        onUseLive: { models.liveModel = model },
                        onUseEnhanced: { models.enhancedModel = model },
                        onDelete: { models.delete(model) }
                    )
                }

                HStack(spacing: 8) {
                    HeaderAction(
                        title: "Manage Models",
                        systemImage: "cube.box",
                        tint: Theme.system,
                        help: "Download, benchmark, and compare models"
                    ) { showingModels = true }

                    if let error = models.lastError {
                        Text(error)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.recording)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - AI

    private var ai: some View {
        Section2(
            title: "AI Actions",
            subtitle: "Runs your own Claude Code. No API key, and nothing for this app to store — the CLI authenticates itself."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                switch toolStatus {
                case .checking:
                    Label("Looking for claude…", systemImage: "hourglass")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)

                case .found(let path, let version):
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Claude Code found", systemImage: "checkmark.circle.fill")
                            .font(Theme.Font.body)
                            .foregroundStyle(.green)
                        Text("\(path)\(version.isEmpty ? "" : "  ·  \(version)")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }

                case .missing:
                    VStack(alignment: .leading, spacing: 4) {
                        Label("claude not found", systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Font.body)
                            .foregroundStyle(.orange)
                        // The usual cause, and not obvious.
                        Text("A GUI app does not see shell aliases, and its PATH excludes ~/.local/bin. Set the full path below.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("BINARY PATH")
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Leave empty to search automatically", text: $binaryPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        HeaderAction(title: "Check", systemImage: "arrow.clockwise") {
                            checkTool()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Storage

    private var storage: some View {
        Section2(title: "Storage", subtitle: "Everything stays on this Mac.") {
            VStack(alignment: .leading, spacing: 12) {
                StorageRow(
                    label: "Recordings",
                    detail: "\(sessions.sessions.count) sessions",
                    bytes: recordingsBytes,
                    path: SessionStore.root
                )
                StorageRow(
                    label: "Whisper models",
                    detail: "Downloaded on demand",
                    bytes: modelBytes,
                    path: ModelStore.downloadRoot
                )
            }
        }
    }

    // MARK: - Work

    private func checkTool() {
        toolStatus = .checking
        let override = binaryPath.trimmingCharacters(in: .whitespaces)

        Task.detached(priority: .userInitiated) {
            guard let path = ShellEnvironment.locate(override.isEmpty ? "claude" : override) else {
                await MainActor.run { toolStatus = .missing }
                return
            }
            // `--version` costs nothing and confirms the binary actually runs,
            // which merely existing on disk does not.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            process.environment = ShellEnvironment.current()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            var version = ""
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                version = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let resolved = version
            await MainActor.run { toolStatus = .found(path: path, version: resolved) }
        }
    }

    private func measureDisk() {
        let roots = [SessionStore.root, ModelStore.downloadRoot]
        Task.detached(priority: .utility) {
            let sizes = roots.map(Self.directorySize)
            await MainActor.run {
                recordingsBytes = sizes[0]
                modelBytes = sizes[1]
            }
        }
    }

    nonisolated private static func directorySize(_ url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }
}

// MARK: - Pieces

private struct Section2<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.system)
                Text(subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Picks the model for one role, from what is already downloaded.
private struct RolePicker: View {
    let role: String
    let detail: String
    let current: WhisperModel
    let choices: [WhisperModel]
    let isReady: Bool
    let onSelect: (WhisperModel) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(role)
                    .font(.system(size: 12, weight: .medium))
                Text(isReady ? detail : "Not downloaded — \(detail)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            HeaderMenu(
                title: current.displayName,
                systemImage: "cube.box",
                tint: isReady ? nil : .orange,
                help: detail,
                items: choices.isEmpty
                    ? [.info("No models downloaded")]
                    : choices.map { model in
                        .action(
                            "\(model.displayName) — \(model.expectedLive.label)",
                            systemImage: model == current ? "checkmark" : "cube.box"
                        ) {
                            onSelect(model)
                        }
                    }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }
}

private struct DownloadedModelRow: View {
    let model: WhisperModel
    let isLive: Bool
    let isEnhanced: Bool
    let sizeLabel: String
    let onUseLive: () -> Void
    let onUseEnhanced: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: .medium))
                    if isLive {
                        Tag(text: "LIVE", color: Theme.mic)
                    }
                    if isEnhanced {
                        Tag(text: "ENHANCED", color: Theme.system)
                    }
                }
                Text("\(model.expectedAccuracy.label) · \(model.expectedLive.label)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Text(sizeLabel)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            if hovering {
                if !isLive {
                    HeaderAction(title: "Live", systemImage: "dot.radiowaves.left.and.right",
                                 help: "Use for live transcription", action: onUseLive)
                }
                if !isEnhanced {
                    HeaderAction(title: "Enhanced", systemImage: "wand.and.sparkles",
                                 help: "Use for the enhanced pass", action: onUseEnhanced)
                }
                // An in-use model cannot be deleted out from under a role.
                HeaderAction(
                    title: "Delete",
                    systemImage: "trash",
                    tint: Theme.recording,
                    isEnabled: !isLive && !isEnhanced,
                    help: isLive || isEnhanced
                        ? "In use — pick another model for this role first"
                        : "Remove this model from disk",
                    action: onDelete
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0.04))
        }
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.14), value: hovering)
    }
}

private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Theme.Font.label)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

private struct StorageRow: View {
    let label: String
    let detail: String
    let bytes: Int?
    let path: URL

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            Text(bytes.map { WhisperModel.sizeLabel(megabytes: $0 / 1_000_000) } ?? "…")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            HeaderAction(title: "Reveal", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([path])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }
}
