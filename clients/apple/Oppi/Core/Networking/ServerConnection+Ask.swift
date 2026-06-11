import Foundation

// MARK: - Ask lifecycle helpers

extension ServerConnection {

    func storeAskRequest(_ ask: AskRequest, for sessionId: String, isFocusedSession: Bool) {
        let inserted = askRequestStore.set(ask, for: sessionId)
        if let workspaceId = attentionWorkspaceId(
            explicitWorkspaceId: ask.workspaceId,
            sessionId: sessionId
        ) {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
        if inserted, ReleaseFeatures.localAttentionNotificationsEnabled {
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
        let removals = askRequestStore.remove(id: requestId)
        guard !removals.isEmpty else { return }

        var removedWorkspaceIds = Set<String>()
        var changedSessionIds = Set<String>()

        for removal in removals {
            if let workspaceId = attentionWorkspaceId(
                explicitWorkspaceId: removal.request.workspaceId,
                sessionId: removal.sessionId
            ) {
                removedWorkspaceIds.insert(workspaceId)
            }
            changedSessionIds.insert(removal.sessionId)
        }

        if ReleaseFeatures.localAttentionNotificationsEnabled {
            for sessionId in changedSessionIds {
                AttentionNotificationService.shared.cancelAskNotification(sessionId: sessionId)
                if let nextAsk = askRequestStore.pending(for: sessionId) {
                    AttentionNotificationService.shared.notifyAskIfNeeded(
                        nextAsk,
                        activeSessionId: focusedSessionId
                    )
                }
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
        appendExtensionDialog(request, for: sessionId)
        syncExtensionDialogWorkspaceSummary(sessionId: sessionId, explicitWorkspaceId: request.workspaceId)
        if isFocusedSession {
            // Blocking extension dialogs wait for user input, so silence is expected.
            silenceWatchdog.stop()
        }
    }

    func clearExtensionDialog(for sessionId: String?) {
        guard let sessionId else {
            guard let focusedSessionId else { return }
            let explicitWorkspaceId = pendingExtensionDialogQueues[focusedSessionId]?.first?.workspaceId
            if pendingExtensionDialogQueues.removeValue(forKey: focusedSessionId) != nil {
                syncExtensionDialogWorkspaceSummary(sessionId: focusedSessionId, explicitWorkspaceId: explicitWorkspaceId)
            }
            return
        }

        let explicitWorkspaceId = pendingExtensionDialogQueues[sessionId]?.first?.workspaceId
        if pendingExtensionDialogQueues.removeValue(forKey: sessionId) != nil {
            syncExtensionDialogWorkspaceSummary(sessionId: sessionId, explicitWorkspaceId: explicitWorkspaceId)
        }
    }

    func clearExtensionDialog(id requestId: String) {
        var changedSessions: [(sessionId: String, workspaceId: String?)] = []
        for sessionId in Array(pendingExtensionDialogQueues.keys) {
            guard var queue = pendingExtensionDialogQueues[sessionId] else { continue }
            let removedWorkspaceId = queue.first(where: { $0.id == requestId })?.workspaceId
            let originalCount = queue.count
            queue.removeAll { $0.id == requestId }
            guard queue.count != originalCount else { continue }
            if queue.isEmpty {
                pendingExtensionDialogQueues.removeValue(forKey: sessionId)
            } else {
                pendingExtensionDialogQueues[sessionId] = queue
            }
            changedSessions.append((sessionId: sessionId, workspaceId: removedWorkspaceId))
        }

        for changed in changedSessions {
            syncExtensionDialogWorkspaceSummary(sessionId: changed.sessionId, explicitWorkspaceId: changed.workspaceId)
        }
    }

    func hasPendingExtensionDialog(for sessionId: String) -> Bool {
        !(pendingExtensionDialogQueues[sessionId]?.isEmpty ?? true)
    }

    func appendExtensionDialog(_ request: ExtensionUIRequest, for sessionId: String) {
        var queue = pendingExtensionDialogQueues[sessionId] ?? []
        if let existingIndex = queue.firstIndex(where: { $0.id == request.id }) {
            queue[existingIndex] = request
        } else {
            queue.append(request)
        }
        pendingExtensionDialogQueues[sessionId] = queue
    }

    func replaceActiveExtensionDialog(_ request: ExtensionUIRequest, for sessionId: String) {
        var queue = pendingExtensionDialogQueues[sessionId] ?? []
        if queue.isEmpty {
            queue = [request]
        } else {
            queue[0] = request
        }
        pendingExtensionDialogQueues[sessionId] = queue
        syncExtensionDialogWorkspaceSummary(sessionId: sessionId, explicitWorkspaceId: request.workspaceId)
    }

    private func syncExtensionDialogWorkspaceSummary(sessionId: String, explicitWorkspaceId: String? = nil) {
        if let workspaceId = attentionWorkspaceId(explicitWorkspaceId: explicitWorkspaceId, sessionId: sessionId) {
            syncWorkspaceSummary(workspaceId: workspaceId)
        }
    }

}
