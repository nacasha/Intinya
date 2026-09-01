import SwiftUI

/// AI actions against the transcript as it stands mid-recording.
struct LiveAIMenu: View {
    @EnvironmentObject private var recorder: Recorder
    @EnvironmentObject private var glossary: GlossaryStore
    @EnvironmentObject private var meetingTypes: MeetingTypeStore
    @ObservedObject var runner: AIActionRunner

    @State private var promptingAction: AIAction?
    @State private var userInput = ""

    private var hasTranscript: Bool { !recorder.segments.isEmpty }

    var body: some View {
        HeaderMenu(
            title: "AI",
            systemImage: "sparkles",
            tint: Theme.system,
            isBusy: runner.isRunning,
            isEnabled: !runner.isRunning && hasTranscript,
            help: hasTranscript
                ? "Run an AI action on what has been transcribed so far"
                : "Nothing transcribed yet",
            items: AIAction.live.map { action in
                .action(action.title, systemImage: action.systemImage) {
                    if action.needsInput != nil {
                        userInput = ""
                        promptingAction = action
                    } else {
                        run(action)
                    }
                }
            }
        )
        .sheet(item: $promptingAction) { action in
            LiveInputPrompt(action: action, text: $userInput) { run(action) }
        }
    }

    private func run(_ action: AIAction) {
        runner.runLive(
            [action],
            userInput: userInput,
            snapshot: recorder.orderedSegments,
            glossary: glossary,
            meetingType: meetingTypes.type(id: recorder.meetingTypeID)
        ) { action, result, snapshot in
            apply(action, result, snapshot)
        }
    }

    private func apply(_ action: AIAction, _ result: MeetingAI.Result, _ snapshot: [TranscriptSegment]) {
        switch action.output {
        case .transcript:
            // Line numbers are resolved against the snapshot, then carried as
            // ids — by now the transcript has almost certainly grown.
            var byID: [UUID: String] = [:]
            for (line, text) in result.corrections where line >= 1 && line <= snapshot.count {
                byID[snapshot[line - 1].id] = text
            }
            _ = recorder.applyCorrections(byID)

        case .notes:
            let text = result.summary.isEmpty ? result.answer : result.summary
            guard !text.isEmpty, let directory = recorder.activeDirectory else { return }
            let existing = Notes.load(in: directory)
            Notes.save(
                existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? text
                    : existing + "\n\n---\n\n" + text,
                in: directory
            )

        case .glossary:
            glossary.learn(result.terms, from: nil)

        case .title, .panel:
            break   // the runner already holds the panel answer
        }
    }
}

private struct LiveInputPrompt: View {
    let action: AIAction
    @Binding var text: String
    let onRun: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Label(action.title, systemImage: action.systemImage)
                    .font(Theme.Font.title)
                Text("Answered from what has been transcribed so far.")
                    .font(Theme.Font.body)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(height: 80)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Run") { onRun(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
