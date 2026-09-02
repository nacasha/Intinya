import Foundation

/// Prompt conditioning for Whisper.
///
/// This is the highest-leverage fix for Indonesian/English code-switching.
/// Without a seeded prompt, Whisper phonetically Indonesianises embedded English
/// terms ("developer" -> "depeloper", "SQL" -> "eskuel"). Priming the decoder
/// with a natural Indonesian sentence that *already contains* English technical
/// vocabulary teaches it that this mixture is expected.
struct Glossary: Codable, Equatable {
    /// Domain terms that should survive in their English spelling.
    var terms: [String]

    static let `default` = Glossary(terms: [
        // Engineering
        "deploy", "deployment", "staging", "production", "release", "rollback",
        "API", "endpoint", "database", "query", "SQL", "backend", "frontend",
        "bug", "fix", "issue", "pull request", "review", "merge", "branch",
        "server", "cache", "latency", "timeout", "log", "monitoring",
        // Process
        "meeting", "standup", "sprint", "backlog", "roadmap", "milestone",
        "deadline", "timeline", "scope", "blocker", "follow up", "action item",
        "update", "progress", "priority", "estimate",
        // Business
        "revenue", "budget", "cost", "target", "growth", "user", "customer",
        "product", "feature", "launch", "metric", "report", "stakeholder",
    ])

    /// Terms learned from previous meetings, persisted across launches.
    ///
    /// This closes a loop worth noticing: the AI pass extracts recurring proper
    /// nouns from a finished transcript, they land here, and this text is what
    /// primes Whisper's decoder on the *next* recording. Each meeting makes the
    /// following one slightly more accurate.
    private static let learnedKey = "glossary.learnedTerms"

    static var learned: [String] {
        get { UserDefaults.standard.stringArray(forKey: learnedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: learnedKey) }
    }

    @discardableResult
    static func learn(_ terms: [String]) -> [String] {
        let existing = learned
        let known = Set(existing.map { $0.lowercased() })
            .union(Glossary.default.terms.map { $0.lowercased() })

        let fresh = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 1 && $0.count < 40 }
            .filter { !known.contains($0.lowercased()) }

        guard !fresh.isEmpty else { return [] }
        // Newest first, capped: the prompt window is limited, and stale names
        // crowd out the ones actually being said now.
        learned = Array((fresh + existing).prefix(60))
        return fresh
    }

    /// Base terms plus everything learned so far.
    static var active: Glossary {
        Glossary(terms: learned + Glossary.default.terms)
    }

    /// A natural code-switched Indonesian sentence used to prime the decoder.
    ///
    /// Whisper's prompt window is limited (roughly half the 448-token context),
    /// so this is deliberately kept short and representative rather than an
    /// exhaustive term dump.
    func promptText(maxTerms: Int = 40) -> String {
        let picked = terms.prefix(maxTerms).joined(separator: ", ")
        return "Ini rekaman meeting tim dalam bahasa Indonesia. "
            + "Peserta sering memakai istilah bahasa Inggris di tengah kalimat, "
            + "misalnya: \(picked). "
            + "Tulis istilah bahasa Inggris dengan ejaan bahasa Inggris yang benar."
    }

    /// The bare term list, for decoders that take vocabulary hints as context
    /// rather than a fake transcript preamble (Qwen3-ASR).
    ///
    /// Deliberately not a sentence: Qwen echoes its context back over silence
    /// or mumbled audio, and a parroted word list is caught by the engine's
    /// echo guard, whereas a parroted natural sentence reads like transcript.
    func termList(maxTerms: Int = 60) -> String {
        terms.prefix(maxTerms).joined(separator: ", ")
    }
}
