import Foundation
import SwiftUI

/// Runs AI actions against one session and applies their results.
@MainActor
final class AIActionRunner: ObservableObject {

    @Published private(set) var running: AIAction?
    @Published private(set) var queued: [AIAction] = []
    @Published private(set) var error: String?
    /// One-line note of what the last action changed.
    @Published private(set) var outcome: String?
    /// Bumped when a run ends. See `SessionEnhancer.completions`.
    @Published private(set) var completions = 0
    /// Free-form answer from an action whose output is `.panel`.
    @Published var panelAnswer: String?
    @Published var panelTitle: String = ""

    /// Optional absolute path, for a CLI installed somewhere unusual.
    @AppStorage("ai.binaryPath") var binaryPath: String = ""

    private var task: Task<Void, Never>?

    var isRunning: Bool { running != nil }

    var isAvailable: Bool {
        ShellEnvironment.locate(binaryPath.isEmpty ? "claude" : binaryPath) != nil
    }

    // MARK: - Running

    func run(
        _ actions: [AIAction],
        userInput: String = "",
        session: Session,
        glossary: GlossaryStore,
        meetingType: MeetingType?,
        onFinish: @escaping () -> Void
    ) {
        guard !isRunning, !actions.isEmpty else { return }
        error = nil
        outcome = nil
        panelAnswer = nil
        queued = Array(actions.dropFirst())

        let override = binaryPath.isEmpty ? nil : binaryPath
        let vocabulary = glossary.activeGlossary

        task = Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor in
                    self?.running = nil
                    self?.queued = []
                    self?.task = nil
                    self?.completions += 1
                    onFinish()
                }
            }

            var notes: [String] = []

            for action in actions {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.running = action
                    self?.queued = Array(actions.drop(while: { $0.id != action.id }).dropFirst())
                }

                // Re-read each time: a repair earlier in the chain must be what
                // the summary and term extraction actually see.
                guard let transcript = SessionStore.loadTranscript(in: session.directory),
                      !transcript.segments.isEmpty else {
                    await MainActor.run { self?.error = "This recording has no transcript." }
                    return
                }
                let segments = transcript.segments.sorted { $0.start < $1.start }

                do {
                    let result = try await MeetingAI.run(
                        action: action,
                        userInput: userInput,
                        segments: segments,
                        glossary: vocabulary,
                        meetingType: meetingType,
                        provider: ClaudeCodeProvider(),
                        binaryOverride: override
                    )
                    let note = await MainActor.run {
                        self?.apply(result, action: action, segments: segments,
                                    transcript: transcript, session: session, glossary: glossary) ?? ""
                    }
                    if !note.isEmpty { notes.append(note) }
                } catch {
                    await MainActor.run { self?.error = error.localizedDescription }
                    return
                }
            }

            await MainActor.run {
                self?.outcome = notes.isEmpty ? "Nothing to change" : notes.joined(separator: " · ")
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = nil
        queued = []
    }

    func dismissPanel() { panelAnswer = nil }

    /// Keeps a panel answer by appending it to the session's notes.
    func savePanelToNotes(session: Session) {
        guard let answer = panelAnswer, !answer.isEmpty else { return }
        append(answer, to: session.directory)
        panelAnswer = nil
        outcome = "Saved to notes"
    }

    /// Runs against a transcript that is still growing.
    ///
    /// Takes a snapshot and hands results straight back rather than writing to
    /// disk. During a recording the transcript lives in the recorder, and a
    /// write here would be overwritten by the next persist — worse, corrections
    /// are addressed by line *number*, and more lines arrive while the model is
    /// thinking, so an index resolved later would land on the wrong utterance.
    /// The snapshot pins them to segment identity instead.
    func runLive(
        _ actions: [AIAction],
        userInput: String = "",
        snapshot: [TranscriptSegment],
        glossary: GlossaryStore,
        meetingType: MeetingType?,
        apply: @escaping (AIAction, MeetingAI.Result, [TranscriptSegment]) -> Void
    ) {
        guard !isRunning, !actions.isEmpty, !snapshot.isEmpty else { return }
        error = nil
        outcome = nil
        panelAnswer = nil

        let override = binaryPath.isEmpty ? nil : binaryPath
        let vocabulary = glossary.activeGlossary

        // Detached: a `Task {}` created here inherits the main actor, and the
        // work it wraps has no business being scheduled against the thread that
        // draws the waveform.
        task = Task.detached(priority: .utility) { [weak self] in
            defer {
                Task { @MainActor in
                    self?.running = nil
                    self?.queued = []
                    self?.task = nil
                    self?.completions += 1
                }
            }

            for action in actions {
                if Task.isCancelled { return }
                await MainActor.run { self?.running = action }
                do {
                    let result = try await MeetingAI.run(
                        action: action,
                        userInput: userInput,
                        segments: snapshot,
                        glossary: vocabulary,
                        meetingType: meetingType,
                        provider: ClaudeCodeProvider(),
                        binaryOverride: override
                    )
                    await MainActor.run {
                        if action.output == .panel {
                            let text = result.answer.isEmpty ? result.summary : result.answer
                            if !text.isEmpty {
                                self?.panelTitle = action.title
                                self?.panelAnswer = text
                            }
                        }
                        apply(action, result, snapshot)
                    }
                } catch {
                    await MainActor.run { self?.error = error.localizedDescription }
                    return
                }
            }
        }
    }

    // MARK: - Applying

    private func apply(
        _ result: MeetingAI.Result,
        action: AIAction,
        segments: [TranscriptSegment],
        transcript: SessionTranscript,
        session: Session,
        glossary: GlossaryStore
    ) -> String {
        switch action.output {
        case .transcript:
            guard !result.corrections.isEmpty else { return "" }
            var updated = segments
            for (number, corrected) in result.corrections where number <= updated.count {
                updated[number - 1].text = corrected
                updated[number - 1].tier = .polished
            }
            var out = transcript
            out.segments = updated
            SessionStore.saveTranscript(out, in: session.directory)
            let count = result.corrections.count
            return "\(count) line\(count == 1 ? "" : "s") repaired"

        case .notes:
            let text = result.summary.isEmpty ? result.answer : result.summary
            guard !text.isEmpty else { return "" }
            append(text, to: session.directory)
            return "written to notes"

        case .glossary:
            let learned = glossary.learn(result.terms, from: session.id)
            guard !learned.isEmpty else { return "no new terms" }
            return "\(learned.count) term\(learned.count == 1 ? "" : "s") learned"

        case .title:
            guard !result.title.isEmpty else { return "" }
            var out = transcript
            out.title = result.title
            SessionStore.saveTranscript(out, in: session.directory)
            return "titled \u{201C}\(result.title)\u{201D}"

        case .panel:
            let text = result.answer.isEmpty ? result.summary : result.answer
            guard !text.isEmpty else { return "" }
            panelTitle = action.title
            panelAnswer = text
            return ""
        }
    }

    /// Appended, never overwriting — notes are hand-written and must not be
    /// replaced by a machine.
    private func append(_ text: String, to directory: URL) {
        let existing = Notes.load(in: directory)
        let merged = existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? text
            : existing + "\n\n---\n\n" + text
        Notes.save(merged, in: directory)
    }
}
