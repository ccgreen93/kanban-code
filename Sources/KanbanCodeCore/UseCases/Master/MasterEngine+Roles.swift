import Foundation

// MARK: - Role hand-off

extension MasterEngine {
    /// Moves a card to its next role: records the finished stage with its
    /// session, switches the card's role, model and effort, ends the old
    /// session and launches a fresh one in the same worktree with the next
    /// role's prompt. In free placement the card also moves to the role's
    /// column.
    ///
    /// - Parameters:
    ///   - requester: the card's own agent, a control agent, or the human.
    ///     Agents may only follow `auto` arrows; the human may pick any role.
    ///   - delay: wait before ending the old session, so the command that
    ///     asked for the hand-off gets its answer before its own session ends.
    @discardableResult
    public func handOffRole(
        cardId: String,
        to next: String,
        summary: String?,
        requester: RoleHandoff.Requester,
        delay: Duration = .zero
    ) async throws -> String {
        guard let link = store.state.links[cardId] else {
            throw RoleHandoff.Failure.cardNotFound(cardId)
        }
        guard store.state.isOwnedLocally(link) else { throw RoleHandoff.Failure.remoteCard }
        let library = RoleLibrary.load()
        let nextRole = try RoleHandoff.validate(card: link, next: next, library: library, requester: requester)
        let oldTmux = link.tmuxLink?.sessionName

        store.dispatch(.applyRoleHandoff(cardId: cardId, next: nextRole, summary: summary))
        guard var updated = store.state.links[cardId] else {
            throw RoleHandoff.Failure.cardNotFound(cardId)
        }
        KanbanCodeLog.info("roles", "Hand-off card=\(cardId.prefix(12)) \(link.role ?? "none") -> \(nextRole.name) by=\(requester)")

        let settings = try? await settingsStore.read()
        let project = settings?.projects.first { $0.path == updated.projectPath }
        // A long task is stored shortened; the first stage's transcript has it in full.
        if PromptPreview.isPreview(updated) {
            updated.promptBody = await PromptPreview.fullPrompt(
                for: updated, transcriptPath: updated.roleHistory?.first?.sessionPath)
        }
        let prompt = RoleHandoff.prompt(for: updated, library: library, project: project, settings: settings)
        let launchPath = updated.worktreeLink?.path ?? updated.projectPath ?? NSHomeDirectory()
        let column = RoleHandoff.column(for: nextRole, placement: store.state.cardPlacement)
        let assistant = updated.effectiveAssistant
        let serviceId = updated.apiServiceId
        let skipPermissions = platform.skipPermissions()

        Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            if let oldTmux { try? await self.tmux.killSession(name: oldTmux) }
            self.launch(
                cardId: cardId,
                prompt: prompt,
                projectPath: launchPath,
                worktreeName: nil,
                runRemotely: false,
                skipPermissions: skipPermissions,
                assistant: assistant,
                serviceIdOverride: serviceId,
                keepSelection: true
            )
            if let column { self.store.dispatch(.moveCard(cardId: cardId, to: column)) }
        }
        return cardId
    }

    /// Gives a card a role without a hand-off (card menu > Role).
    public func setRole(cardId: String, to name: String?) {
        let role = name.flatMap { RoleLibrary.load().role(named: $0) }
        guard name == nil || role != nil else { return }
        store.dispatch(.setCardRole(cardId: cardId, role: role))
    }
}
