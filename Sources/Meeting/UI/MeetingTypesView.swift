import SwiftUI

/// Meeting types, and the prompt each one uses for its AI summary.
struct MeetingTypesView: View {
    @EnvironmentObject private var store: MeetingTypeStore
    @State private var selectedID: UUID?

    private var selected: MeetingType? {
        store.types.first { $0.id == selectedID } ?? store.types.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 240)
            Divider().opacity(0.5)
            detail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 640, minHeight: 420)
        .background(.ultraThinMaterial)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            if selectedID == nil { selectedID = store.types.first?.id }
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Types")
                    .font(.system(size: 20, weight: .semibold))
                Text("Each type summarises differently.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.types) { type in
                        TypeRow(type: type, isSelected: type.id == selected?.id) {
                            selectedID = type.id
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider().opacity(0.4)

            HStack {
                Button {
                    selectedID = store.add().id
                } label: {
                    Label("New Type", systemImage: "plus")
                        .font(Theme.Font.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let selected {
            MeetingTypeDetail(type: selected)
                .id(selected.id)
        } else {
            Text("Select a type")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TypeRow: View {
    let type: MeetingType
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: type.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.system) : AnyShapeStyle(.secondary))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(type.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(type.detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected
                          ? Theme.system.opacity(0.14)
                          : Color.primary.opacity(hovering ? 0.05 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The editable definition of one type.
private struct MeetingTypeDetail: View {
    @EnvironmentObject private var store: MeetingTypeStore
    let type: MeetingType

    @State private var draft: MeetingType
    @State private var saveTask: Task<Void, Never>?

    init(type: MeetingType) {
        self.type = type
        _draft = State(initialValue: type)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider().opacity(0.4)
                promptSection
                captureSection
                participantsSection
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onDisappear { flush() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: draft.systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.system)
                    .frame(width: 26)

                TextField("Name", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))

                if draft.isBuiltIn {
                    HeaderAction(
                        title: "Reset",
                        systemImage: "arrow.uturn.backward",
                        help: "Restore this type's original prompt"
                    ) {
                        store.reset(draft)
                        draft = store.type(id: draft.id) ?? draft
                    }
                } else {
                    HeaderAction(
                        title: "Delete",
                        systemImage: "trash",
                        tint: Theme.recording,
                        help: "Remove this type"
                    ) {
                        store.remove(draft)
                    }
                }
            }

            TextField("When to use this", text: $draft.detail)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SUMMARY PROMPT")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.system)
                Spacer()
                Text("used by AI › Summary & Action Items")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("Describe what the summary should contain. The transcript and the response format are added automatically, so this cannot break the output.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $draft.summaryPrompt)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 240)
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEFAULT SCREEN CAPTURE")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)

            Picker("", selection: $draft.screenMode) {
                ForEach(ScreenCaptureMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Text(draft.screenMode.detail)
                .font(Theme.Font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var participantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("USUAL PARTICIPANTS")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)

            Text("Comma separated. Given to the AI so it can attribute lines to names instead of \"Them\".")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(
                "Rizal, Dimas, Sarah",
                text: Binding(
                    get: { draft.participants.joined(separator: ", ") },
                    set: { draft.participants = $0
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty } }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 420)
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = draft
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run { store.update(snapshot) }
        }
    }

    private func flush() {
        saveTask?.cancel()
        store.update(draft)
    }
}
