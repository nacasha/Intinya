import Foundation
import SwiftUI

/// Owns the meeting types and which one is used by default.
@MainActor
final class MeetingTypeStore: ObservableObject {

    @Published private(set) var types: [MeetingType] = []
    @AppStorage("meetingType.lastUsed") private var lastUsedRaw: String = ""

    private static let key = "meetingTypes.v1"

    init() { load() }

    /// Preselected for a new recording — the one used last, so the common case
    /// costs nothing.
    var lastUsed: MeetingType? {
        types.first { $0.id.uuidString == lastUsedRaw } ?? types.first
    }

    func type(id: UUID?) -> MeetingType? {
        guard let id else { return nil }
        return types.first { $0.id == id }
    }

    func noteUsed(_ type: MeetingType) {
        lastUsedRaw = type.id.uuidString
    }

    // MARK: - Editing

    func update(_ type: MeetingType) {
        guard let index = types.firstIndex(where: { $0.id == type.id }) else { return }
        types[index] = type
        save()
    }

    @discardableResult
    func add() -> MeetingType {
        let new = MeetingType(
            name: "New Template",
            systemImage: "sparkles",
            detail: "Describe when to use this.",
            summaryPrompt: """
            Summarise this meeting.

            ## Ringkasan
            What was discussed.

            ## Action Items
            With an owner where one was stated.
            """
        )
        types.append(new)
        save()
        return new
    }

    func remove(_ type: MeetingType) {
        // Built-ins can be edited but not deleted: losing them would leave a
        // session pointing at a type that no longer exists.
        guard !type.isBuiltIn else { return }
        types.removeAll { $0.id == type.id }
        save()
    }

    /// Restores a built-in's original prompt.
    func reset(_ type: MeetingType) {
        guard let original = MeetingType.starters.first(where: { $0.name == type.name }),
              let index = types.firstIndex(where: { $0.id == type.id })
        else { return }
        var restored = original
        restored.id = type.id
        types[index] = restored
        save()
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([MeetingType].self, from: data),
           !decoded.isEmpty {
            types = decoded
        } else {
            types = MeetingType.starters
            save()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(types) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
