import Foundation
import SwiftUI

/// The fast-changing parts of a recording: waveform levels and elapsed time.
///
/// Split out of `Recorder` deliberately. Those values update twenty times a
/// second, and every view observing `Recorder` — including the sidebar, with its
/// filtering and day-grouping — was being invalidated at that rate. Nested
/// observable objects do not propagate, which is exactly what is wanted here:
/// only the views that actually draw a waveform subscribe to this.
@MainActor
final class RecordingMonitor: ObservableObject {

    static let history = 96

    @Published private(set) var micLevels: [Float] = Array(repeating: 0, count: RecordingMonitor.history)
    @Published private(set) var systemLevels: [Float] = Array(repeating: 0, count: RecordingMonitor.history)
    @Published private(set) var elapsed: TimeInterval = 0

    func record(level: Float, for source: AudioSource) {
        // Perceptual-ish curve; raw RMS is too flat to look like anything.
        let scaled = min(1.0, sqrt(level) * 2.4)
        switch source {
        case .mic:
            micLevels.removeFirst()
            micLevels.append(scaled)
        case .system:
            systemLevels.removeFirst()
            systemLevels.append(scaled)
        }
    }

    func setElapsed(_ value: TimeInterval) { elapsed = value }

    func reset() {
        micLevels = Array(repeating: 0, count: Self.history)
        systemLevels = Array(repeating: 0, count: Self.history)
        elapsed = 0
    }
}
