import Foundation

// MARK: - Ask lifecycle helpers

extension ServerConnection {

    func askRequest(from request: ExtensionUIRequest) -> AskRequest? {
        guard request.method == "ask",
              let questions = request.askQuestions,
              !questions.isEmpty else {
            return nil
        }

        return AskRequest(
            id: request.id,
            sessionId: request.sessionId,
            questions: questions,
            allowCustom: request.allowCustom ?? true,
            timeout: request.timeout
        )
    }

    func presentAskRequest(_ ask: AskRequest, for sessionId: String) {
        pendingAskRequests.removeValue(forKey: sessionId)
        activeAskRequest = ask
        askRequestStore.set(ask, for: sessionId)
        if let workspaceId = attentionWorkspaceId(
            explicitWorkspaceId: ask.workspaceId,
            sessionId: sessionId
        ) {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
        // The agent is blocked waiting for user input, so silence is expected.
        silenceWatchdog.stop()
    }

    func stashPendingAskRequest(
        _ ask: AskRequest,
        for sessionId: String,
        keepStoreEntry: Bool = true
    ) {
        pendingAskRequests[sessionId] = ask
        if keepStoreEntry {
            askRequestStore.set(ask, for: sessionId)
        } else {
            askRequestStore.remove(for: sessionId)
        }
        if let workspaceId = attentionWorkspaceId(
            explicitWorkspaceId: ask.workspaceId,
            sessionId: sessionId
        ) {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
    }

    func restorePendingAskRequestIfNeeded(for sessionId: String) {
        let restored = pendingAskRequests.removeValue(forKey: sessionId)
            ?? askRequestStore.pending(for: sessionId)

        if let restored {
            activeAskRequest = restored
            askRequestStore.set(restored, for: sessionId)
            if let workspaceId = attentionWorkspaceId(
                explicitWorkspaceId: restored.workspaceId,
                sessionId: sessionId
            ) {
                syncWorkspaceSummary(workspaceId: workspaceId)
            }
        } else {
            activeAskRequest = nil
        }
    }

    func stashActiveAskIfNeeded(keepStoreEntry: Bool = true) {
        guard let focusedSessionId, let ask = activeAskRequest else { return }
        stashPendingAskRequest(ask, for: focusedSessionId, keepStoreEntry: keepStoreEntry)
        activeAskRequest = nil
    }

    func clearAskState(for sessionId: String?) {
        guard let sessionId else {
            activeAskRequest = nil
            return
        }

        let explicitWorkspaceId = pendingAskRequests[sessionId]?.workspaceId
            ?? askRequestStore.pending(for: sessionId)?.workspaceId
            ?? (activeAskRequest?.sessionId == sessionId ? activeAskRequest?.workspaceId : nil)
        let removedWorkspaceId = attentionWorkspaceId(
            explicitWorkspaceId: explicitWorkspaceId,
            sessionId: sessionId
        )
        pendingAskRequests.removeValue(forKey: sessionId)
        askRequestStore.remove(for: sessionId)

        if activeAskRequest?.sessionId == sessionId {
            activeAskRequest = nil
        }
        if let removedWorkspaceId {
            syncWorkspaceSummary(workspaceId: removedWorkspaceId)
        }
    }

    // MARK: - Generic extension dialog lifecycle helpers

    func presentExtensionDialog(_ request: ExtensionUIRequest, for sessionId: String) {
        pendingExtensionDialogs.removeValue(forKey: sessionId)
        extensionTimeoutTask?.cancel()
        activeExtensionDialog = request
        scheduleExtensionTimeout(request)
    }

    func stashPendingExtensionDialog(_ request: ExtensionUIRequest, for sessionId: String) {
        pendingExtensionDialogs[sessionId] = request
    }

    func restorePendingExtensionDialogIfNeeded(for sessionId: String) {
        guard let restored = pendingExtensionDialogs.removeValue(forKey: sessionId) else {
            activeExtensionDialog = nil
            return
        }

        cancelExtensionTimeout()
        activeExtensionDialog = restored
        scheduleExtensionTimeout(restored)
    }

    func stashActiveExtensionDialogIfNeeded() {
        guard let focusedSessionId, let request = activeExtensionDialog else { return }
        pendingExtensionDialogs[focusedSessionId] = request
        activeExtensionDialog = nil
        cancelExtensionTimeout()
    }

    func clearExtensionDialog(for sessionId: String?) {
        guard let sessionId else {
            activeExtensionDialog = nil
            cancelExtensionTimeout()
            return
        }

        pendingExtensionDialogs.removeValue(forKey: sessionId)
        guard activeExtensionDialog?.sessionId == sessionId else { return }
        activeExtensionDialog = nil
        cancelExtensionTimeout()
    }

    private func cancelExtensionTimeout() {
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
    }
}
