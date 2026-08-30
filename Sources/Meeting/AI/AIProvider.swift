import Foundation

/// A local CLI that can answer a prompt.
///
/// Deliberately one-shot text-in / text-out. The agent CLIs also support a
/// persistent streaming session with tool permissions, but that machinery exists
/// for hosting interactive coding agents — transcript repair is a single
/// transformation, and the simple shape is an order of magnitude less code.
protocol AIProvider {
    var id: String { get }
    var displayName: String { get }
    /// The executable to look for on PATH.
    var defaultBinary: String { get }
    /// Arguments for a one-shot run, given the instruction.
    func arguments(instruction: String) -> [String]
    /// Pulls the model's text out of whatever the CLI printed.
    func extractText(from stdout: String) throws -> String
}

/// Claude Code (`claude -p`).
///
/// The app never authenticates: it spawns the user's own `claude`, which reads
/// its credentials from `~/.claude` exactly as it does in a terminal. The
/// subscription is consumed by Claude Code itself — there is no API key here,
/// and nothing for this app to store.
struct ClaudeCodeProvider: AIProvider {
    let id = "claude-code"
    let displayName = "Claude Code"
    let defaultBinary = "claude"

    func arguments(instruction: String) -> [String] {
        // The transcript goes on stdin; only the instruction is an argument, so
        // a long meeting cannot overflow the argument size limit.
        ["-p", instruction, "--output-format", "json"]
    }

    func extractText(from stdout: String) throws -> String {
        guard let data = stdout.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AIError.unreadableOutput(String(stdout.prefix(400)))
        }
        if envelope["is_error"] as? Bool == true {
            throw AIError.toolReported(
                (envelope["result"] as? String) ?? "The CLI reported an error."
            )
        }
        guard let result = envelope["result"] as? String, !result.isEmpty else {
            throw AIError.unreadableOutput("No result field in the CLI response.")
        }
        return result
    }
}

/// Escape hatch for any other CLI, or for flags that change under us.
///
/// `{prompt}` in the template is replaced with the instruction; everything
/// arrives on stdin as usual, and stdout is taken as the answer verbatim.
struct CustomCommandProvider: AIProvider {
    let id = "custom"
    let displayName = "Custom command"
    let defaultBinary: String
    let template: [String]

    init(binary: String, template: [String]) {
        self.defaultBinary = binary
        self.template = template
    }

    func arguments(instruction: String) -> [String] {
        template.map { $0 == "{prompt}" ? instruction : $0 }
    }

    func extractText(from stdout: String) throws -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIError.unreadableOutput("The command printed nothing.") }
        return trimmed
    }
}

enum AIError: LocalizedError {
    case binaryNotFound(String)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case toolReported(String)
    case unreadableOutput(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let tool):
            return "Could not find \"\(tool)\". Install it, or set the full path in AI settings. "
                 + "A GUI app does not see shell aliases, and its PATH excludes ~/.local/bin."
        case .launchFailed(let message):
            return "Could not start the AI tool: \(message)"
        case .timedOut(let seconds):
            return "The AI tool did not finish within \(Int(seconds))s."
        case .toolReported(let message):
            return "The AI tool reported an error: \(message)"
        case .unreadableOutput(let detail):
            return "Could not read the AI tool's output. \(detail)"
        case .badResponse(let detail):
            return "The AI response was not in the expected format. \(detail)"
        }
    }
}
