import UIKit

// The chat's session and turn actions: model and thinking, resume, rename,
// sharing, tree navigation, and forks.

extension ChatViewController {
    var hasShareSlashCommand: Bool {
        chatState.slashCommands.contains { command in
            command.name.caseInsensitiveCompare("share") == .orderedSame
        }
    }

    func handleModelSelection(_ model: ModelInfo) {
        switch ModelSwitchPolicy.decision(
            currentModel: session?.model,
            selectedModel: model,
            messageCount: session?.messageCount ?? 0
        ) {
        case .unchanged:
            return
        case .applyImmediately:
            applyModelSelection(model)
        }
    }

    func applyModelSelection(_ model: ModelInfo) {
        AppPreferences.RecentModels.record(ModelSwitchPolicy.fullModelID(for: model))
        actionHandler.setModel(
            model,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: sessionId
        )
    }

    func setThinking(_ level: ThinkingLevel) {
        actionHandler.setThinking(
            level,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId
        )
    }

    func saveThinkingAsDefault() {
        actionHandler.setThinking(
            chatState.thinkingLevel,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            persist: true
        )
    }

    func resumeSession() {
        actionHandler.resumeSession(
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            sessionId: sessionId
        )
    }

    func rename(to name: String) {
        actionHandler.rename(
            name,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: sessionId
        )
    }

    func copySessionID() {
        UIPasteboard.general.string = sessionId
    }

    func shareSessionFromTitleMenu() {
        guard hasShareSlashCommand else {
            reducer.process(
                .error(sessionId: sessionId, message: "Share command is not enabled for this workspace.")
            )
            return
        }

        shareReview.reset()
        model.showShareRedactionSheet = true
    }

    func sendShareSlashCommand(
        clearComposer: Bool,
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance
    ) {
        guard hasShareSlashCommand else {
            reducer.process(
                .error(sessionId: sessionId, message: "Share command is not enabled for this workspace.")
            )
            return
        }

        let sessionManagerRef = sessionManager
        let policy = AppPreferences.Share.redactionPolicy
        let submission: ChatComposerDraftController.SubmissionSnapshot?
        if clearComposer {
            guard let startedSubmission = beginComposerSubmission(
                draftClearance: draftClearance
            ) else { return }
            submission = startedSubmission
        } else {
            submission = nil
        }

        actionHandler.shareSession(
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            redactionPolicy: policy,
            onSendSucceeded: { [weak self] in
                if let submission {
                    self?.composerDraftController.completeSubmission(submission)
                    self?.dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                }
            },
            onAsyncFailure: { [weak self] in
                if let submission {
                    self?.composerDraftController.failSubmission(submission)
                }
            },
            onNeedsReconnect: {
                sessionManagerRef.reconnect()
            }
        )
    }

    func scheduleSharePreflight() {
        let connection = connection
        shareReview.schedulePreflight { policy in
            try await connection.prepareShareSession(redactionPolicy: policy)
        }
    }

    func cancelSharePreflight() {
        shareReview.cancelPreflight()
    }

    func publishSessionWithCurrentRedactionPolicy() {
        let sessionManagerRef = sessionManager
        let policy = shareReview.policy.normalized

        AppPreferences.Share.setRedactionPolicy(policy)
        cancelSharePreflight()
        model.showShareRedactionSheet = false

        actionHandler.shareSession(
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            redactionPolicy: policy,
            onNeedsReconnect: {
                sessionManagerRef.reconnect()
            }
        )
    }

    // MARK: - Tree navigation and forks

    enum TreeNavigationError: LocalizedError {
        case sessionNotReady
        case navigationCancelled
        case navigationAborted
        case historyReloadFailed

        var errorDescription: String? {
            switch self {
            case .sessionNotReady:
                return "Wait for the current turn to finish before navigating the tree."
            case .navigationCancelled:
                return "Tree navigation was cancelled before switching branches."
            case .navigationAborted:
                return "Tree navigation was aborted before switching branches."
            case .historyReloadFailed:
                return "Switched branches, but failed to reload timeline history."
            }
        }
    }

    /// Shared by the outline callback and mounted navigation regression tests.
    /// Loading stays in the chat; the timeline receives only the selected ID.
    /// `loadTarget` reports whether history now holds the target. A target that never
    /// loaded gets no scroll: its jump could never land, and while pending it kept the
    /// timeline from following the live tail.
    static func selectOutlineTimelineEntry(
        _ targetID: String,
        items: [ChatItem],
        scrollController: ChatScrollController,
        loadTarget: @escaping @MainActor () async -> Bool
    ) {
        if items.contains(where: { $0.id == targetID }) {
            scrollController.scrollTargetID = targetID
            return
        }
        Task { @MainActor in
            guard await loadTarget() else { return }
            scrollController.scrollTargetID = targetID
        }
    }

    func navigateFromTree(_ request: SessionTreeNavigationRequest) async throws {
        guard session?.status == .ready else {
            throw TreeNavigationError.sessionNotReady
        }

        let result = try await connection.navigateTree(
            targetId: request.targetId,
            summarize: request.summarize,
            customInstructions: request.customInstructions,
            replaceInstructions: request.replaceInstructions,
            label: request.label
        )

        if result.cancelled {
            throw TreeNavigationError.navigationCancelled
        }

        if result.aborted == true {
            throw TreeNavigationError.navigationAborted
        }

        let historyReloaded = await sessionManager.forceHistoryReload(
            connection: connection,
            sessionStore: sessionStore
        )

        guard historyReloaded else {
            throw TreeNavigationError.historyReloadFailed
        }

        let viewUpdate = TreeNavigationViewUpdate.from(
            targetId: request.targetId,
            editorText: result.editorText,
            showComposer: model.showComposer
        )

        scrollController.scrollTargetID = viewUpdate.scrollTargetID
        composerDraftController.replaceMessage(
            text: viewUpdate.inputText,
            repoPointers: [],
            pendingAttachments: []
        )

        if viewUpdate.shouldFocusComposer {
            composer.requestFocus()
        }
    }

    func forkFromMessage(_ entryId: String) {
        guard let workspaceId = session?.workspaceId, !workspaceId.isEmpty else {
            reducer.process(.error(sessionId: sessionId, message: "Missing workspace context for fork."))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let forked = try await self.connection.forkIntoNewSessionFromTimelineEntry(
                    entryId,
                    sourceSessionId: self.sessionId,
                    workspaceId: workspaceId
                )

                let title = forked.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Session \(forked.id.prefix(8))"
                self.reducer.appendSystemEvent("Fork created as new session: \(displayName)")

                self.pushChat(sessionId: forked.id, workspaceId: forked.workspaceId ?? workspaceId)
            } catch {
                self.reducer.process(.error(sessionId: self.sessionId, message: "Fork failed: \(error.localizedDescription)"))
            }
        }
    }
}
