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
        role: Role? = nil
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

        if let role {
            prompt = wrap(prompt.trimmingCharacters(in: .whitespacesAndNewlines), in: role)
        }

        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts the role's instructions ahead of the task, so a fresh worker
    /// reads its role first and the task last.
    /// A prompt that already starts with the role header (for example one
    /// recovered from the transcript on relaunch) is left as it is.
    public static func wrap(_ task: String, in role: Role) -> String {
        let header = "# Role: \(role.name)"
        if task.hasPrefix(header) { return task }
        var parts = [header]
        if let description = role.description { parts.append(description) }
        if !role.body.isEmpty { parts.append(role.body) }
        parts.append("# Task\n\n\(task)")
        return parts.joined(separator: "\n\n")
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
