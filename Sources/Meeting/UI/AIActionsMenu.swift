import SwiftUI

/// The AI actions available for one recording.
struct AIActionsMenu: View {
    let session: Session
    @ObservedObject var runner: AIActionRunner
    @EnvironmentObject private var glossary: GlossaryStore
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    let onFinish: () -> Void

    @State private var promptingAction: AIAction?
    @State private var userInput = ""

    var body: some View {
        HeaderActionMenu(
            title: runner.isRunning ? "Working" : "AI",
            systemImage: "sparkles",
            tint: Theme.system,
            isBusy: runner.isRunning,
            isEnabled: !runner.isRunning && session.hasTranscript,
            help: session.hasTranscript
                ? "Run an AI action on this recording"
                : "This recording has no transcript yet"
        ) {
            Button {
                runner.run(AIAction.runAll, session: session, glossary: glossary,
                           meetingType: meetingTypes.type(id: session.typeID), onFinish: onFinish)
            } label: {
                Label("Run All", systemImage: "wand.and.stars")
            }
            .help("Repair, summarise, and extract terms, in that order.")

            Divider()

            ForEach(AIAction.all) { action in
                Button {
                    if action.needsInput != nil {
                        userInput = ""
                        promptingAction = action
                    } else {
                        runner.run([action], session: session, glossary: glossary,
                                   meetingType: meetingTypes.type(id: session.typeID),
                                   onFinish: onFinish)
                    }
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
                .help(action.detail)
            }
        }
        .sheet(item: $promptingAction) { action in
            InputPrompt(action: action, text: $userInput) {
                runner.run([action], userInput: userInput, session: session,
                           glossary: glossary,
                           meetingType: meetingTypes.type(id: session.typeID),
                           onFinish: onFinish)
            }
        }
    }
}

/// Collects the free text an action needs before running.
private struct InputPrompt: View {
    let action: AIAction
    @Binding var text: String
    let onRun: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(action.title, systemImage: action.systemImage)
                    .font(Theme.Font.title)
                Text(action.detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(height: 90)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty, let hint = action.needsInput {
                        Text(hint)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run") {
                    onRun()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Shows an answer that was not written anywhere, with the option to keep it.
struct AIAnswerPanel: View {
    let title: String
    let answer: String
    let onSave: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: "sparkles")
                    .font(Theme.Font.label)
                    .foregroundStyle(Theme.system)
                Spacer()
                Button("Save to Notes", action: onSave).controlSize(.small)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ScrollView {
                MarkdownText(markdown: answer)
            }
            .frame(maxHeight: 220)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Theme.system.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .stroke(Theme.system.opacity(0.25), lineWidth: 1)
        }
    }
}
