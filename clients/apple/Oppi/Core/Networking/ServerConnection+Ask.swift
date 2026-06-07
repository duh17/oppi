import Foundation

// MARK: - Ask lifecycle helpers

extension ServerConnection {

    func storeAskRequest(_ ask: AskRequest, for sessionId: String, isFocusedSession: Bool) {
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
        if isFocusedSession {
            // The agent is blocked waiting for user input, so silence is expected.
            silenceWatchdog.stop()
        }
    }

    func syncActiveAskWorkspaceSummary() {
        guard let focusedSessionId,
              let restored = askRequestStore.pending(for: focusedSessionId) else { return }
        if let workspaceId = attentionWorkspaceId(
            explicitWorkspaceId: restored.workspaceId,
            sessionId: focusedSessionId
        ) {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
    }

    func clearAskState(for sessionId: String?) {
        guard let sessionId else {
            if let focusedSessionId {
                clearAskState(for: focusedSessionId)
            }
            return
        }

        let explicitWorkspaceId = askRequestStore.pending(for: sessionId)?.workspaceId
        let removedWorkspaceId = attentionWorkspaceId(
            explicitWorkspaceId: explicitWorkspaceId,
            sessionId: sessionId
        )
        askRequestStore.remove(for: sessionId)
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            AttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)
        }

        if let removedWorkspaceId {
            syncWorkspaceSummary(workspaceId: removedWorkspaceId)
        }
    }

    func clearAskRequest(id requestId: String) {
        var removedWorkspaceIds = Set<String>()
        var removedSessionIds = Set<String>()

        for (sessionId, ask) in Array(askRequestStore.pending) where ask.id == requestId {
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

    // MARK: - Sheet-backed extension request lifecycle helpers

    func storeExtensionDialog(
        _ request: ExtensionUIRequest,
        for sessionId: String,
        isFocusedSession: Bool
    ) {
        pendingExtensionDialogs[sessionId] = request
        syncExtensionDialogWorkspaceSummary(sessionId: sessionId)
        if isFocusedSession {
            // Blocking extension dialogs wait for user input, so silence is expected.
            silenceWatchdog.stop()
        }
    }

    func clearExtensionDialog(for sessionId: String?) {
        guard let sessionId else {
            guard let focusedSessionId else { return }
            if pendingExtensionDialogs.removeValue(forKey: focusedSessionId) != nil {
                syncExtensionDialogWorkspaceSummary(sessionId: focusedSessionId)
            }
            return
        }

        if pendingExtensionDialogs.removeValue(forKey: sessionId) != nil {
            syncExtensionDialogWorkspaceSummary(sessionId: sessionId)
        }
    }

    func clearExtensionDialog(id requestId: String) {
        var changedSessionIds = Set<String>()
        for (sessionId, request) in Array(pendingExtensionDialogs) where request.id == requestId {
            pendingExtensionDialogs.removeValue(forKey: sessionId)
            changedSessionIds.insert(sessionId)
        }

        for sessionId in changedSessionIds {
            syncExtensionDialogWorkspaceSummary(sessionId: sessionId)
        }
    }

    func hasPendingExtensionDialog(for sessionId: String) -> Bool {
        pendingExtensionDialogs[sessionId] != nil
    }

    private func syncExtensionDialogWorkspaceSummary(sessionId: String) {
        if let workspaceId = attentionWorkspaceId(explicitWorkspaceId: nil, sessionId: sessionId) {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
    }

}
