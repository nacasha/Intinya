import Foundation
import SwiftUI

/// Runs the tier-2 pass against any saved session.
///
/// Previously enhancement lived on the recorder and could only be applied to the
/// recording you had just finished. Keyed on a directory instead, it works on
/// anything in the library — and survives navigating away from the record screen.
@MainActor
final class SessionEnhancer: ObservableObject {

    @Published private(set) var progress: Double?
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    /// Bumped when a pass ends, so a detail view can reload without having to
    /// own the runner or hold a closure back into its own state.
    @Published private(set) var completions = 0

    private var task: Task<Void, Never>?
    private var pass: EnhancedPass?
    private var replacingExisting = false

    var isRunning: Bool { progress != nil }

    /// The model currently running, for the progress label.
    @Published private(set) var runningModel: WhisperModel?

    /// - Parameter replacingExisting: when true, every line in each finished
    ///   window is replaced, including ones already enhanced or hand-edited.
    ///   When false, only the rougher live text is upgraded.
    func enhance(
        session: Session,
        using model: WhisperModel,
        replacingExisting: Bool = false,
        onFinish: @escaping () -> Void
    ) {
        guard task == nil else { return }
        runningModel = model
        self.replacingExisting = replacingExisting
        error = nil
        progress = 0
        status = "Preparing…"

        let directory = session.directory
        let pass = EnhancedPass(model: model)
        self.pass = pass

        task = Task { [weak self] in
            defer {
                Task { @MainActor in
                    self?.task = nil
                    self?.pass = nil
                    self?.progress = nil
                    self?.status = nil
                    self?.runningModel = nil
                    self?.completions += 1
                    onFinish()
                }
            }
            do {
                try await pass.run(
                    sessionDirectory: directory,
                    onProgress: { update in
                        Task { @MainActor in
                            self?.progress = update.fraction
                            self?.status = update.message
                        }
                    },
                    onWindow: { window in
                        Task { @MainActor in self?.apply(window, in: directory) }
                    }
                )
            } catch is CancellationError {
                // Whatever landed before the cancel is already saved.
            } catch {
                await MainActor.run { self?.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        if let pass { Task { await pass.cancel() } }
        task?.cancel()
        task = nil
        progress = nil
        status = nil
    }

    /// Swaps a window of live text for the enhanced version.
    ///
    /// Replacement is by time range rather than segment-to-segment matching: the
    /// two passes chunk audio differently, so their boundaries don't correspond
    /// and pairing them up would drop or duplicate text.
    ///
    /// Written straight to disk each window, so quitting mid-pass keeps whatever
    /// was already improved.
    private func apply(_ window: EnhancedPass.Window, in directory: URL) {
        guard var transcript = SessionStore.loadTranscript(in: directory) else { return }

        transcript.segments.removeAll { segment in
            guard segment.source == window.source,
                  segment.midpoint >= window.start,
                  segment.midpoint < window.end
            else { return false }
            // A re-transcription replaces the window outright; an enhancement
            // only upgrades text that has not already been improved.
            return replacingExisting || segment.tier < .enhanced
        }
        transcript.segments.append(contentsOf: window.segments.map {
            TranscriptSegment(
                source: window.source,
                start: $0.start,
                end: $0.end,
                text: $0.text,
                tier: .enhanced
            )
        })
        transcript.segments.sort { $0.start < $1.start }
        transcript.enhancedModel = pass?.model.rawValue
        SessionStore.saveTranscript(transcript, in: directory)
    }
}
