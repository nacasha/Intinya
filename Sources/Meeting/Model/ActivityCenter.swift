import Combine
import Foundation
import SwiftUI

/// Owns the long-running work for every session.
///
/// The transcription and AI runners used to be `@StateObject` on the detail
/// view, which tied them to that view's lifetime — navigating elsewhere threw
/// away a running pass, and coming back showed no sign it had ever started.
/// Held here, work continues regardless of what is on screen, and any view can
/// ask whether a recording is busy.
@MainActor
final class ActivityCenter: ObservableObject {

    /// Key for the recording in progress, which has no session id yet.
    static let liveKey = "__live__"

    private var enhancers: [String: SessionEnhancer] = [:]
    private var runners: [String: AIActionRunner] = [:]
    /// Keeps the centre's own publisher firing when a child's state changes,
    /// so list indicators update rather than only the detail view.
    private var relays: [String: Set<AnyCancellable>] = [:]

    // MARK: - Accessors

    func enhancer(for sessionID: String) -> SessionEnhancer {
        if let existing = enhancers[sessionID] { return existing }
        let created = SessionEnhancer()
        enhancers[sessionID] = created
        relay(created, for: sessionID)
        return created
    }

    func ai(for sessionID: String) -> AIActionRunner {
        if let existing = runners[sessionID] { return existing }
        let created = AIActionRunner()
        runners[sessionID] = created
        relay(created, for: sessionID)
        return created
    }

    private func relay(_ object: some ObservableObject, for sessionID: String) {
        let cancellable = object.objectWillChange.sink { [weak self] _ in
            // The child publishes *before* its change lands, so hop a turn to
            // report the settled state.
            Task { @MainActor in self?.objectWillChange.send() }
        }
        relays[sessionID, default: []].insert(AnyCancellable(cancellable))
    }

    // MARK: - Queries

    func isBusy(_ sessionID: String) -> Bool {
        (enhancers[sessionID]?.isRunning ?? false) || (runners[sessionID]?.isRunning ?? false)
    }

    /// Short description of what is running, for a tooltip.
    func label(for sessionID: String) -> String? {
        if let enhancer = enhancers[sessionID], enhancer.isRunning {
            return enhancer.runningModel.map { "Transcribing with \($0.displayName)" }
                ?? "Transcribing"
        }
        if let runner = runners[sessionID], let action = runner.running {
            return action.title
        }
        return nil
    }

    /// Determinate progress where there is any.
    func progress(for sessionID: String) -> Double? {
        enhancers[sessionID]?.progress
    }

    var busyCount: Int {
        Set(enhancers.filter { $0.value.isRunning }.keys)
            .union(runners.filter { $0.value.isRunning }.keys)
            .count
    }

    /// Drops finished work for a deleted recording.
    func forget(_ sessionID: String) {
        enhancers[sessionID]?.cancel()
        runners[sessionID]?.cancel()
        enhancers[sessionID] = nil
        runners[sessionID] = nil
        relays[sessionID] = nil
    }
}
