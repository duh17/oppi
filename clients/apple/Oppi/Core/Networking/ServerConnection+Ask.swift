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
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            AttentionNotificationService.shared.notifyAskIfNeeded(
                ask,
                activeSessionId: focusedSessionId
            )
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
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            AttentionNotificationService.shared.notifyAskIfNeeded(
                ask,
                activeSessionId: focusedSessionId
            )
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
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            AttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)
        }

        if activeAskRequest?.sessionId == sessionId {
            activeAskRequest = nil
        }
        if let removedWorkspaceId {
            syncWorkspaceSummary(workspaceId: removedWorkspaceId)
        }
    }

    func clearAskRequest(id requestId: String) {
        var removedWorkspaceIds = Set<String>()
        var removedSessionIds = Set<String>()

        if let activeAskRequest, activeAskRequest.id == requestId {
            if let workspaceId = attentionWorkspaceId(
                explicitWorkspaceId: activeAskRequest.workspaceId,
                sessionId: activeAskRequest.sessionId
            ) {
                removedWorkspaceIds.insert(workspaceId)
            }
            removedSessionIds.insert(activeAskRequest.sessionId)
            self.activeAskRequest = nil
        }

        for (sessionId, ask) in Array(pendingAskRequests) where ask.id == requestId {
            if let workspaceId = attentionWorkspaceId(
                explicitWorkspaceId: ask.workspaceId,
                sessionId: sessionId
            ) {
                removedWorkspaceIds.insert(workspaceId)
            }
            removedSessionIds.insert(sessionId)
            pendingAskRequests.removeValue(forKey: sessionId)
        }

        for (sessionId, ask) in askRequestStore.pending where ask.id == requestId {
            if let workspaceId = attentionWorkspaceId(
                explicitWorkspaceId: ask.workspaceId,
                sessionId: sessionId
            ) {
                removedWorkspaceIds.insert(workspaceId)
            }
            removedSessionIds.insert(sessionId)
            askRequestStore.remove(for: sessionId)
        }

        if ReleaseFeatures.localAttentionNotificationsEnabled {
            for sessionId in removedSessionIds {
                AttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)
            }
        }

        for workspaceId in removedWorkspaceIds {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
    }

    // MARK: - Generic extension dialog lifecycle helpers

    func presentExtensionDialog(_ request: ExtensionUIRequest, for sessionId: String) {
        pendingExtensionDialogs.removeValue(forKey: sessionId)
        extensionTimeoutTask?.cancel()
        activeExtensionDialog = request
        scheduleExtensionTimeout(request)
        syncExtensionDialogWorkspaceSummary(sessionId: sessionId)
    }

    func stashPendingExtensionDialog(_ request: ExtensionUIRequest, for sessionId: String) {
        pendingExtensionDialogs[sessionId] = request
        syncExtensionDialogWorkspaceSummary(sessionId: sessionId)
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
            let previousSessionId = activeExtensionDialog?.sessionId
            activeExtensionDialog = nil
            cancelExtensionTimeout()
            if let previousSessionId {
                syncExtensionDialogWorkspaceSummary(sessionId: previousSessionId)
            }
            return
        }

        let hadPending = pendingExtensionDialogs.removeValue(forKey: sessionId) != nil
        let hadActive = activeExtensionDialog?.sessionId == sessionId
        if hadActive {
            activeExtensionDialog = nil
            cancelExtensionTimeout()
        }
        if hadPending || hadActive {
            syncExtensionDialogWorkspaceSummary(sessionId: sessionId)
        }
    }

    func clearExtensionDialog(id requestId: String) {
        var clearedActive = false
        var changedSessionIds = Set<String>()
        if activeExtensionDialog?.id == requestId {
            if let sessionId = activeExtensionDialog?.sessionId {
                changedSessionIds.insert(sessionId)
            }
            activeExtensionDialog = nil
            clearedActive = true
        }

        for (sessionId, request) in Array(pendingExtensionDialogs) where request.id == requestId {
            pendingExtensionDialogs.removeValue(forKey: sessionId)
            changedSessionIds.insert(sessionId)
        }

        if clearedActive {
            cancelExtensionTimeout()
        }
        for sessionId in changedSessionIds {
            syncExtensionDialogWorkspaceSummary(sessionId: sessionId)
        }
    }

    func hasPendingExtensionDialog(for sessionId: String) -> Bool {
        activeExtensionDialog?.sessionId == sessionId || pendingExtensionDialogs[sessionId] != nil
    }

    private func syncExtensionDialogWorkspaceSummary(sessionId: String) {
        if let workspaceId = attentionWorkspaceId(explicitWorkspaceId: nil, sessionId: sessionId) {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
    }

    private func cancelExtensionTimeout() {
        extensionTimeoutTask?.cancel()
        extensionTimeoutTask = nil
    }
}
