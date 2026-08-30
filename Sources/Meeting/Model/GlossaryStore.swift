import Foundation
import SwiftUI

/// A term the app has learned, with where it came from.
///
/// Provenance is worth keeping: a glossary that just appears is hard to trust or
/// prune. Knowing a term arrived from Tuesday's meeting is what makes it
/// reviewable.
struct LearnedTerm: Codable, Identifiable, Hashable {
    var term: String
    var addedAt: Date
    /// Session id, when the term came from a recording rather than by hand.
    var sessionID: String?

    var id: String { term.lowercased() }
    var isManual: Bool { sessionID == nil }
}

/// Owns the vocabulary that primes Whisper's decoder.
///
/// These terms are not decoration: they become the prompt that conditions
/// transcription, so editing this list directly changes how the next recording
/// is transcribed.
@MainActor
final class GlossaryStore: ObservableObject {

    @Published private(set) var learned: [LearnedTerm] = []
    @Published var disabledBuiltins: Set<String> = [] {
        didSet { saveDisabled() }
    }

    private static let key = "glossary.learnedTerms.v2"
    private static let legacyKey = "glossary.learnedTerms"
    private static let disabledKey = "glossary.disabledBuiltins"
    /// The prompt window is limited; stale names crowd out current ones.
    static let capacity = 120

    init() { load() }

    // MARK: - Derived

    var builtins: [String] { Glossary.default.terms }

    var activeTerms: [String] {
        learned.map(\.term) + builtins.filter { !disabledBuiltins.contains($0.lowercased()) }
    }

    /// What actually gets sent to Whisper.
    var activeGlossary: Glossary { Glossary(terms: activeTerms) }

    var promptPreview: String { activeGlossary.promptText() }

    // MARK: - Mutation

    /// Adds terms discovered by an AI pass. Returns only the genuinely new ones.
    @discardableResult
    func learn(_ terms: [String], from sessionID: String?) -> [String] {
        let known = Set(learned.map(\.id)).union(builtins.map { $0.lowercased() })
        let fresh = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 1 && $0.count <= 40 }
            .filter { !known.contains($0.lowercased()) }

        guard !fresh.isEmpty else { return [] }

        let now = Date()
        let added = fresh.map { LearnedTerm(term: $0, addedAt: now, sessionID: sessionID) }
        learned = Array((added + learned).prefix(Self.capacity))
        save()
        return fresh
    }

    @discardableResult
    func add(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return false }
        guard !learned.contains(where: { $0.id == trimmed.lowercased() }) else { return false }
        learned.insert(LearnedTerm(term: trimmed, addedAt: Date(), sessionID: nil), at: 0)
        save()
        return true
    }

    func remove(_ term: LearnedTerm) {
        learned.removeAll { $0.id == term.id }
        save()
    }

    func removeAllLearned() {
        learned.removeAll()
        save()
    }

    func toggleBuiltin(_ term: String) {
        let key = term.lowercased()
        if disabledBuiltins.contains(key) {
            disabledBuiltins.remove(key)
        } else {
            disabledBuiltins.insert(key)
        }
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([LearnedTerm].self, from: data) {
            learned = decoded
        } else if let legacy = defaults.stringArray(forKey: Self.legacyKey) {
            // Terms saved before provenance existed; keep them, dated unknown.
            learned = legacy.map { LearnedTerm(term: $0, addedAt: .distantPast, sessionID: nil) }
            save()
        }
        disabledBuiltins = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(learned) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
        // Mirrored to the plain list the non-UI code paths read.
        Glossary.learned = learned.map(\.term)
    }

    private func saveDisabled() {
        UserDefaults.standard.set(Array(disabledBuiltins), forKey: Self.disabledKey)
    }
}
