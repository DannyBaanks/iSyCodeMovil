import Foundation

/// What the app shows about the Docker sandbox the agent is working in.
public struct SandboxLinkState: Equatable, Sendable {
    public var projectName: String
    public var directory: String
    public var repo: String?
    public var defaultBranch: String?
    public var hasGitHubAccount: Bool
    public var sandboxID: String
    public var phase: String
    public var remainingMs: Double
    public var explanation: String
    /// Files that looked like secrets and were left on the computer.
    public var excludedFiles: [String]
    public var lastPullRequest: SandboxPullRequest?

    public var canOpenPullRequest: Bool { hasGitHubAccount && repo != nil }

    /// "1 h 20 min", "12 min" or nil when the countdown is not running.
    public var remainingLabel: String? {
        guard phase == "active", remainingMs > 0 else { return nil }
        let minutes = Int((remainingMs / 60_000).rounded(.up))
        if minutes >= 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
        }
        return "\(minutes) min"
    }

    public var phaseLabel: String {
        switch phase {
        case "active": return "Activo"
        case "suspended": return "En pausa"
        case "destroyed": return "Destruido"
        default: return phase
        }
    }
}

/// Renders a conversation as Markdown so it can be shared or archived.
public enum ConversationExport {
    public static func markdown(title: String, project: String?, events: [TimelineEvent]) -> String {
        var lines = ["# \(title)"]
        if let project, !project.isEmpty { lines.append("_Proyecto: \(project)_") }
        lines.append("")
        for event in events {
            switch event.kind {
            case .userPrompt:
                guard let text = event.promptText, !text.isEmpty else { continue }
                lines.append("## Tú")
                lines.append(text)
                lines.append("")
            case .assistantText:
                guard let text = event.assistantText, !text.isEmpty else { continue }
                lines.append("## Asistente")
                lines.append(text)
                lines.append("")
            case .toolCall, .toolResult:
                guard let name = event.toolName, !name.isEmpty else { continue }
                let detail = (event.toolArguments ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\(String($0.value.prefix(80)))" }
                    .joined(separator: " ")
                lines.append(detail.isEmpty ? "- `\(name)`" : "- `\(name)` \(detail)")
                lines.append("")
            default:
                continue
            }
        }
        return lines.joined(separator: "\n")
    }
}
