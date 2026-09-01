import Foundation

/// A kind of meeting, and what a good summary of it looks like.
///
/// The point of a type is not the label — it is `summaryPrompt`. A standup
/// summary and a refinement summary are genuinely different documents, and the
/// single generic prompt produced a paragraph where you wanted six bullets with
/// names against them.
struct MeetingType: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var systemImage: String
    /// One line, shown in the list.
    var detail: String
    /// What the summary should contain. Edited by the user.
    ///
    /// Only the *content* spec lives here. The shared transcript context and the
    /// JSON contract the app parses are added around it, so an edit here cannot
    /// break the response format.
    var summaryPrompt: String
    /// Capture mode to preselect when recording this kind of meeting.
    var screenMode: ScreenCaptureMode
    /// Usual attendees. Helps the AI attribute lines to names.
    var participants: [String]
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        systemImage: String,
        detail: String,
        summaryPrompt: String,
        screenMode: ScreenCaptureMode = .off,
        participants: [String] = [],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.detail = detail
        self.summaryPrompt = summaryPrompt
        self.screenMode = screenMode
        self.participants = participants
        self.isBuiltIn = isBuiltIn
    }
}

extension MeetingType {

    /// Starting set. Editable — a fixed list would be wrong for any specific
    /// team within a week.
    static var starters: [MeetingType] {
        [
            MeetingType(
                name: "Daily Standup",
                systemImage: "sun.horizon",
                detail: "Short, per-person updates and blockers.",
                summaryPrompt: """
                Summarise this as a daily standup, grouped by person.

                ## Updates
                One heading per person who actually spoke, using the name as it \
                was said. Under each, at most three short bullets: what they \
                finished, what they are working on next, and anything slowing \
                them down.

                ## Blockers
                Repeat every blocker raised, with who owns it and who they need \
                something from. Omit this section if nobody raised one.

                Do not invent updates for people who did not speak. Keep each \
                bullet to a single line.
                """,
                screenMode: .off,
                isBuiltIn: true
            ),

            MeetingType(
                name: "Sprint Review",
                systemImage: "checkmark.seal",
                detail: "Demos, stakeholder feedback, what was accepted.",
                summaryPrompt: """
                Summarise this as a sprint review.

                ## Demoed
                What was shown, and by whom.

                ## Feedback
                What reviewers said, attributed to who said it. Keep the actual \
                objection or praise, not a paraphrase that loses it.

                ## Accepted and Deferred
                Items explicitly accepted, and anything pushed to a later sprint \
                with the stated reason.

                ## Follow-ups
                With an owner where one was named.

                Only include what was genuinely discussed.
                """,
                screenMode: .video,
                isBuiltIn: true
            ),

            MeetingType(
                name: "Backlog Refinement",
                systemImage: "list.bullet.indent",
                detail: "Per-ticket scope, estimates, and open questions.",
                summaryPrompt: """
                Summarise this as a backlog refinement, organised by ticket.

                Use one `##` heading per ticket or item discussed, titled with the \
                ticket name or id as it was spoken. Under each:
                - Scope that was agreed
                - Estimate, if one was given
                - Open questions
                - Decisions made

                ## Unresolved
                Anything left genuinely open at the end.

                If an item was mentioned only in passing, leave it out.
                """,
                screenMode: .keyframes,
                isBuiltIn: true
            ),

            MeetingType(
                name: "One-to-One",
                systemImage: "person.2",
                detail: "Topics and commitments. Factual, not evaluative.",
                summaryPrompt: """
                Summarise this as a one-to-one.

                ## Topics
                Briefly, what was discussed.

                ## Commitments
                What each person agreed to do, with the owner.

                ## Follow-up
                Anything to revisit next time.

                Stay factual and neutral. Do not characterise anyone's tone, \
                mood, or performance, and do not draw conclusions that were not \
                said out loud.
                """,
                screenMode: .off,
                isBuiltIn: true
            ),

            MeetingType(
                name: "General Meeting",
                systemImage: "bubble.left.and.bubble.right",
                detail: "The default when nothing more specific fits.",
                summaryPrompt: """
                Summarise this meeting.

                ## Ringkasan
                Three to six bullets covering what was actually discussed.

                ## Action Items
                With an owner where one was stated.

                ## Keputusan
                Decisions that were actually made.

                Omit any section that has nothing in it. Do not invent action \
                items or decisions.
                """,
                screenMode: .off,
                isBuiltIn: true
            ),
        ]
    }
}
