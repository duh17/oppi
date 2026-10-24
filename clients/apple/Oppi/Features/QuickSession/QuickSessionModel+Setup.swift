import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSession")

/// Opening Quick Session: the start it was asked for, the draft, the initial
/// destination, the microphone, and a Live Voice start's unattended launch.
extension QuickSessionModel {
    /// Loads the draft, picks the destination, claims the microphone, and
    /// applies the start. Quick Session's controller runs it once as it
    /// appears; closing Quick Session cancels it. `requestDictation` and
    /// `focusComposer` run once the composer is ready, for a dictation start
    /// and a typing start.
    func setUp(
        requestDictation: () -> Void,
        focusComposer: () async -> Void
    ) async {
        // Snapshot before any await so a draft load cannot lose the start.
        let start = navigation.pendingQuickSessionStart ?? QuickSessionStart()
        navigation.pendingQuickSessionStart = nil
        let launchContext = start.context
        let startsLiveVoice = start.mode == .liveVoice
        // A requested call launches by itself, so it must not send a draft left from an
        // earlier Quick Session: that draft stays saved, untouched, for next time.
        keepsStoredDraft = startsLiveVoice

        if let composerDraftStore {
            await composerDraftStore.load()
            if Task.isCancelled { return }
        }
        if !keepsStoredDraft {
            loadStoredDraft()
        }

        // With the experiment off no call starts, so there is no server answer to wait for.
        if startsLiveVoice, AppPreferences.Experiments.liveVoiceEnabled {
            await awaitServerCatalog(serverId: launchContext?.serverId ?? coordinator.activeServerId)
            if Task.isCancelled { return }
        }

        shouldRememberAgentSelection = launchContext?.agentId == nil
        threadParent = launchContext?.threadParent

        // Inbox workspace+worktree beats last-used. Agent launch still filters
        // to that server, then last used > explicit default > first available.
        let candidates = rawServerWorkspaces.map {
            QuickSessionLaunchSelection.Candidate(
                serverId: $0.serverId,
                workspaceId: $0.workspace.id,
                name: $0.workspace.name
            )
        }
        let pick = QuickSessionLaunchSelection.initialWorkspace(
            launchContext: launchContext,
            workspaces: candidates,
            preferred: nil
        )
        liveVoicePickIsRequested = QuickSessionLaunchSelection.isRequestedTarget(
            pick,
            launchContext: launchContext,
            workspaces: candidates
        )
        if let pick {
            if let worktreeId = pick.worktreeId {
                selectedWorktreeId = QuickSessionWorktreePickerPolicy.normalizedLaunchWorktreeId(worktreeId)
            }
            selectedWorkspace = rawServerWorkspaces.first(where: {
                $0.serverId == pick.serverId && $0.workspace.id == pick.workspaceId
            })?.workspace
            selectedWorkspaceSelectionSource = pick.source
            selectedServerId = pick.serverId
        } else if let launchContext {
            selectedServerId = launchContext.serverId
        } else {
            selectedServerId = coordinator.activeServerId
        }

        let manager = VoiceInputManager.shared
        voiceInputManager = manager
        await ComposerShared.cancelVoiceInputOnDismiss(manager: manager)
        if Task.isCancelled { return }
        configureVoiceInputForSelectedServer(manager)

        if let payload = start.payload {
            applyInitialPayload(payload)
        }
        agentResolution = pendingAgentResolution(requestedAgentId: launchContext?.agentId)
        isInitialized = true
        await drainPendingDictationCleanupQueue()
        if Task.isCancelled { return }

        let readyAction = QuickSessionDictationLaunch.afterComposerReady(
            pendingStart: start.mode == .dictation
        )
        // The composer owns starting voice (suppress keyboard, then record).
        // Starting from Quick Session itself raced the bar and left the keyboard up.
        if readyAction == .startDictation {
            requestDictation()
        }

        await loadAgentsForSelectedServer(requestedAgentId: launchContext?.agentId)

        // A call takes over the composer; raising the keyboard first would only flash it.
        if readyAction == .focusForTyping, !startsLiveVoice {
            await focusComposer()
        }

        if let api = selectedServerConnection()?.apiClient {
            await selectedChatState.refreshModelCache(api: api)
        }
        if Task.isCancelled { return }

        if startsLiveVoice {
            startRequestedLiveVoice(requestedAgentId: launchContext?.agentId)
        }
    }

    /// A Live Voice start (the Live Voice control, a Shortcut) launches as soon as the sheet
    /// has its target, exactly as if the user had tapped Live Voice. Anything that keeps it
    /// from launching stays on screen as the sheet's error, with the sheet open to fix it.
    private func startRequestedLiveVoice(requestedAgentId: String?) {
        // The Live Voice control and the Shortcuts open Quick Session before they can read
        // Settings, so a call asked for with the experiment off ends here, with the reason.
        guard AppPreferences.Experiments.liveVoiceEnabled else {
            error = "Live Voice is an experiment. Turn it on in Settings → Experiments."
            return
        }
        // The call starts unattended, so it starts only where it was asked to: never in a
        // fallback workspace or with another Agent the user did not see picked.
        guard liveVoicePickIsRequested, selectedWorkspace != nil else {
            error = "Choose a workspace for Live Voice."
            return
        }
        if let requestedAgentId, selectedAgentId != requestedAgentId {
            if error == nil { error = "Live Voice didn't start with that Agent. Pick one, then tap Live Voice." }
            return
        }
        guard liveVoiceCalls.mayStartCall else {
            error = "Live Voice is already on a call. End it, then start a new one."
            return
        }
        guard let liveVoiceEntry else {
            error = selectedServerConnection()?.serverCapabilities == nil
                ? "Oppi couldn't reach the server to start Live Voice."
                : "Live Voice isn't set up on this server."
            return
        }
        liveVoiceEntry()
    }

    /// A Live Voice start picks its workspace and checks the server's voice backend right
    /// away, so it first gets the server's current answer and, on a cold launch, waits
    /// briefly for the workspace list.
    private func awaitServerCatalog(serverId: String?) async {
        guard let serverId, let connection = coordinator.connection(for: serverId) else { return }
        // The capabilities held may predate a server restart or update: coming to the
        // foreground (an Action Button press) re-reads them without waiting. Read them now
        // (joining a read in flight), so the call is judged on the server as it is.
        await connection.refreshStreamCapabilities()
        if Task.isCancelled { return }
        await waitUntil(timeout: .seconds(10)) {
            connection.serverCapabilities != nil && connection.workspaceStore.isLoaded
        }
        // A server that just started may still be checking its voice backend; its
        // capability follows the follow-up read about two seconds later.
        await waitUntil(timeout: .seconds(4)) { connection.liveVoiceAvailable }
    }

    /// Returns once `condition` holds or `timeout` passes; closing the sheet ends it at once.
    private func waitUntil(
        timeout: Duration,
        _ condition: @escaping @MainActor @Sendable () -> Bool
    ) async {
        guard !condition() else { return }
        let observer = Task { @MainActor in
            for await met in Observations(condition) where met { return }
        }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            observer.cancel()
        }
        await withTaskCancellationHandler {
            await observer.value
        } onCancel: {
            observer.cancel()
        }
        deadline.cancel()
    }

    // MARK: Dictation cleanup

    private func drainPendingDictationCleanupQueue() async {
        for cleanup in AppPreferences.QuickSession.pendingDictationCleanups {
            await attemptPendingDictationCleanup(cleanup)
        }
    }

    private func attemptPendingDictationCleanup(
        _ cleanup: AppPreferences.QuickSession.PendingDictationCleanup
    ) async {
        guard let connection = coordinator.connection(for: cleanup.serverId),
              let api = connection.apiClient else {
            return
        }

        do {
            try await api.deleteWorkspaceSession(
                workspaceId: cleanup.workspaceId,
                sessionId: cleanup.sessionId
            )
            connection.sessionStore.remove(id: cleanup.sessionId)
            await TimelineCache.shared.removeTrace(cleanup.sessionId, serverId: cleanup.serverId)
            AppPreferences.QuickSession.removePendingDictationCleanup(cleanup)
        } catch let apiError as APIError {
            if case .server(let status, _) = apiError, status == 404 {
                connection.sessionStore.remove(id: cleanup.sessionId)
                await TimelineCache.shared.removeTrace(cleanup.sessionId, serverId: cleanup.serverId)
                AppPreferences.QuickSession.removePendingDictationCleanup(cleanup)
            } else {
                logger.warning("Failed to delete queued quick dictation session \(cleanup.sessionId, privacy: .public): \(apiError.localizedDescription, privacy: .public)")
            }
        } catch {
            logger.warning("Failed to delete queued quick dictation session \(cleanup.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
