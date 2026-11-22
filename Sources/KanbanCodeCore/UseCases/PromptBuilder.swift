import Foundation

/// Builds the final prompt to send to Claude, applying templates from settings and project config.
public enum PromptBuilder {

    /// Build the full prompt for a card, applying appropriate templates.
    ///
    /// For issue cards: applies `githubIssuePromptTemplate` then wraps with `promptTemplate`.
    /// For manual tasks: wraps `promptBody` with `promptTemplate`.
    /// For session cards: uses card name as-is (no template needed).
    public static func buildPrompt(
        card link: Link,
        project: Project? = nil,
        settings: Settings? = nil,
        roles: RoleLibrary? = nil
    ) -> String {
        var prompt: String

        if let issueLink = link.issueLink {
            // GitHub issue: apply issue template
            let issueTemplate = project?.githubIssuePromptTemplate
                ?? settings?.githubIssuePromptTemplate
                ?? "#${number}: ${title}\n\n${body}"
            prompt = applyTemplate(issueTemplate, variables: [
                "number": String(issueLink.number),
                "title": link.name?.replacingOccurrences(of: "#\(issueLink.number): ", with: "") ?? "",
                "body": issueLink.body ?? "",
                "url": issueLink.url ?? "",
            ])
        } else if let promptBody = link.promptBody {
            prompt = promptBody
        } else {
            prompt = link.name ?? ""
        }

        // Wrap with prompt template (prefix/suffix)
        let template = project?.promptTemplate ?? settings?.promptTemplate ?? ""
        if !template.isEmpty {
            if template.contains("${prompt}") {
                prompt = applyTemplate(template, variables: ["prompt": prompt])
            } else {
                // Template has no placeholder — prepend it
                prompt = template + "\n" + prompt
            }
        }

        if let roles, let role = roles.role(named: link.role) {
            prompt = wrap(
                prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                in: role,
                next: roles.transitions.next(after: role.name),
                history: link.roleHistory ?? []
            )
        }

        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts the role's instructions ahead of the task, so a fresh worker
    /// reads its role first, then the task, then what earlier roles did, and
    /// last how to hand off. A task that is itself a wrapped prompt (one
    /// recovered from a transcript, possibly another role's) is unwrapped
    /// first, so roles never nest.
    public static func wrap(
        _ task: String,
        in role: Role,
        next: [RoleEdge] = [],
        history: [RoleStage] = []
    ) -> String {
        let task = unwrapRoleTask(task)
        var parts = ["# Role: \(role.name)"]
        if let description = role.description { parts.append(description) }
        if !role.body.isEmpty { parts.append(role.body) }
        parts.append("# Task\n\n\(task)")
        if !history.isEmpty { parts.append(earlierStages(history)) }
        // A control agent runs the board instead of finishing a stage.
        if !role.controls { parts.append(handoffInstructions(next)) }
        return parts.joined(separator: "\n\n")
    }

    /// The task inside a prompt `wrap` built, or the text unchanged when it
    /// is not one.
    public static func unwrapRoleTask(_ text: String) -> String {
        guard text.hasPrefix("# Role: "), let start = text.range(of: "\n# Task\n\n") else { return text }
        var task = text[start.upperBound...]
        for footer in ["\n\n# Earlier stages on this card", "\n\n# When you are done"] {
            if let end = task.range(of: footer) { task = task[..<end.lowerBound] }
        }
        return String(task)
    }

    /// Each earlier stage's summary, oldest first: the next role's only view
    /// of what came before, since it starts in a fresh session.
    static func earlierStages(_ history: [RoleStage]) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd HH:mm"
        day.locale = Locale(identifier: "en_US_POSIX")
        var lines = ["# Earlier stages on this card", ""]
        for stage in history {
            lines.append("## \(stage.role ?? "no role") → \(stage.handedOffTo) (\(day.string(from: stage.endedAt)))")
            lines.append("")
            lines.append(stage.summary ?? "(no summary)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func handoffInstructions(_ next: [RoleEdge]) -> String {
        guard !next.isEmpty else {
            return "# When you are done\n\nThis is the last role. Report what you did and stop."
        }
        let roles = next.map { edge in
            edge.mode == .auto
                ? "- `\(edge.role)`: hand off when your stage is done"
                : "- `\(edge.role)`: needs the human's yes; recommend it in your report and stop"
        }.joined(separator: "\n")
        return """
        # When you are done

        Commit your work first. The next role starts a fresh session that sees \
        only this card's task and the summaries, not this conversation. Then \
        hand off with a summary it can start from:

        ```
        kanban role handoff <role> - <<'EOF'
        What you did, where it is, what is left or risky.
        EOF
        ```

        Next roles:
        \(roles)

        If none fits, or you need a decision, report and stop.
        """
    }

    /// Replace `${key}` placeholders with values from the variables dictionary.
    public static func applyTemplate(_ template: String, variables: [String: String]) -> String {
        var result = template
        for (key, value) in variables {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }
}
