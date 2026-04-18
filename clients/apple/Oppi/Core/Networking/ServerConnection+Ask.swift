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
    }

    func restorePendingAskRequestIfNeeded(for sessionId: String) {
        let restored = pendingAskRequests.removeValue(forKey: sessionId)
            ?? askRequestStore.pending(for: sessionId)

        if let restored {
            activeAskRequest = restored
            askRequestStore.set(restored, for: sessionId)
        } else {
            activeAskRequest = nil
        }
    }

    func stashActiveAskIfNeeded(keepStoreEntry: Bool = true) {
        guard let activeSessionId, let ask = activeAskRequest else { return }
        stashPendingAskRequest(ask, for: activeSessionId, keepStoreEntry: keepStoreEntry)
        activeAskRequest = nil
    }

    func clearAskState(for sessionId: String?) {
        guard let sessionId else {
            activeAskRequest = nil
            return
        }

        pendingAskRequests.removeValue(forKey: sessionId)
        askRequestStore.remove(for: sessionId)

        if activeAskRequest?.sessionId == sessionId {
            activeAskRequest = nil
        }
    }
}
