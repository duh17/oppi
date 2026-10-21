import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "QuickSession")

struct AgentQuickSessionSubmitKey: Equatable {
    let serverId: String
    let workspaceId: String
    let worktreeId: String
    let agentId: String
    let parentSessionId: String?
    let prompt: String
    let attachmentIds: [String]
    let modelId: String?
    let thinkingLevel: ThinkingLevel?
    let engine: SessionEngine
}

/// One Agent launch's stable launch and turn ids, kept across retries until
/// the server confirms delivery.
struct AgentQuickSessionSubmitAttempt {
    let key: AgentQuickSessionSubmitKey
    let launchIdempotencyKey: String
    let clientTurnId: String
    var sessionId: String?
    var uploadedAttachments: [ChatAttachmentRef]?
}

enum QuickSessionError: LocalizedError {
    case noConnection
    case noWorkspace
    case agentLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .noConnection: return "Server is offline"
        case .noWorkspace: return "Choose a workspace first."
        case .agentLaunchFailed(let reason): return reason
        }
    }
}

/// Starting the session: plain Pi creates it (the chat sends the first
/// message), a saved Agent launches and is prompted here, then Quick Session
/// closes and opens the new chat.
extension QuickSessionModel {
    /// Parent id for a launch on `serverId`; a session id only means something on its own server.
    private func threadParentSessionId(onServer serverId: String) -> String? {
        guard let threadParent, threadParent.serverId == serverId else { return nil }
        return threadParent.sessionId
    }

    func handleSend(startsLiveVoice: Bool = false) {
        guard !isCreating else { return }
        // A saved Agent may still be resolving; sending now would launch it as a plain session.
        if engineDecision.blocksLaunch {
            error = agentResolution == .failed
                ? "The saved Agent did not load. Choose Pi to start without it."
                : "Loading your Agent. Try again in a moment."
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let transportText = PendingFileReference.appendReferenceBlock(
            to: trimmed,
            files: pendingRepoPointers
        )
        let launchDecision = QuickSessionLaunchRouting.plan(
            for: QuickSessionLaunchRequest(
                workspaceId: selectedWorkspace?.id,
                worktreeId: QuickSessionWorktreePickerPolicy.resolvedWorktreeId(
                    selectedId: selectedWorktreeId,
                    worktrees: worktrees
                ),
                agentId: selectedAgentId,
                prompt: transportText,
                hasAttachments: !pendingAttachments.isEmpty,
                hasRepoReferences: !pendingRepoPointers.isEmpty,
                startsLiveVoice: startsLiveVoice
            )
        )

        let plan: QuickSessionLaunchPlan
        switch launchDecision {
        case .success(let resolved):
            plan = resolved
        case .failure(let validationError):
            error = validationError.localizedDescription
            return
        }

        guard let workspace = selectedWorkspace, workspace.id == plan.workspaceId else {
            error = QuickSessionLaunchValidationError.missingWorkspace.localizedDescription
            return
        }

        let modelId = effectiveModelId
        let thinking = thinkingLevel
        let agentThinking = agentThinkingOverride
        let submittedPayload = currentDraftPayload
        let submittedDraft = persistQuickSessionDraft()?.payload

        isCreating = true
        error = nil

        let telemetryStartedAtMs = ChatSessionTelemetry.nowMs()
        let telemetryTags = [
            "source": "sheet",
            "selection": selectedWorkspaceSelectionSource,
            "has_message": trimmed.isEmpty ? "0" : "1",
            "has_attachments": pendingAttachments.isEmpty ? "0" : "1",
            "has_repo_refs": pendingRepoPointers.isEmpty ? "0" : "1",
            "has_model": modelId == nil ? "0" : "1",
            "has_agent": selectedAgentId == nil ? "0" : "1",
            "worktree": plan.worktreeId == WorkspaceWorktree.mainId ? "main" : "other",
            "engine": engine.rawValue,
            "incognito": launchesIncognito ? "1" : "0",
        ]

        // Capture references before dismiss tears Quick Session down.
        let nav = navigation
        let coordinator = coordinator
        let serverId = selectedServerId ?? coordinator.activeServerId ?? "default"
        let attachments = pendingAttachments
        let parentSessionId = threadParentSessionId(onServer: serverId)
        let launchEngine = self.engine
        let incognito = launchesIncognito

        Task { @MainActor in
            // A locked server or workspace asks before anything is created or
            // sent; cancel keeps the sheet and its draft, and submits nothing.
            guard await ScopedLockService.shared.authorize(
                .workspace(serverId: serverId, workspaceId: workspace.id)
            ) else {
                isCreating = false
                restoreStoredDraftAfterLiveVoiceStart()
                return
            }
            do {
                // Use the correct server's API client
                guard let targetConnection = coordinator.connection(for: serverId),
                      let api = targetConnection.apiClient else {
                    throw QuickSessionError.noConnection
                }

                var session: Session
                let autoSendMessage: String?
                let autoSendAttachments: [PendingAttachment]?

                switch plan.mode {
                case .plainPi:
                    // Create session without prompt — we'll send through WebSocket
                    let response = try await api.createWorkspaceSession(
                        workspaceId: workspace.id,
                        model: modelId,
                        thinking: thinking.rawValue,
                        ephemeral: incognito ? true : nil,
                        worktreeId: plan.worktreeId,
                        parentSessionId: parentSessionId,
                        engine: launchEngine
                    )
                    session = response.session
                    if incognito {
                        // The creator opens a new Incognito session without being asked.
                        ScopedLockService.shared.noteCreated(.session(session, serverId: serverId))
                    }
                    autoSendMessage = plan.shouldAutoSend ? transportText : nil
                    autoSendAttachments = plan.shouldAutoSend ? attachments : nil
                    AppPreferences.QuickSession.saveThinkingLevel(thinking)

                case .agent(let agentId):
                    // Keep stable launch and turn IDs until authoritative delivery is
                    // confirmed. Retrying an ambiguous HTTP failure must resume the same
                    // Agent session rather than create and prompt a second one.
                    let submitKey = AgentQuickSessionSubmitKey(
                        serverId: serverId,
                        workspaceId: workspace.id,
                        worktreeId: plan.worktreeId,
                        agentId: agentId,
                        parentSessionId: parentSessionId,
                        prompt: plan.prompt,
                        attachmentIds: attachments.map(\.id),
                        modelId: modelId,
                        thinkingLevel: agentThinking,
                        engine: launchEngine
                    )
                    var attempt: AgentQuickSessionSubmitAttempt
                    if let pending = agentSubmitAttempt, pending.key == submitKey {
                        attempt = pending
                    } else {
                        let attemptId = UUID().uuidString
                        attempt = AgentQuickSessionSubmitAttempt(
                            key: submitKey,
                            launchIdempotencyKey: "ios-agent-launch-\(attemptId)",
                            clientTurnId: "quick-agent-\(attemptId)"
                        )
                        agentSubmitAttempt = attempt
                    }

                    let launchedSessionId: String
                    if let pendingSessionId = attempt.sessionId {
                        launchedSessionId = pendingSessionId
                    } else {
                        do {
                            let response = try await api.launchAgentSession(
                                agentId: agentId,
                                prompt: nil,
                                workspaceId: workspace.id,
                                worktreeId: plan.worktreeId,
                                model: modelId,
                                thinkingLevel: agentThinking,
                                parentSessionId: parentSessionId,
                                engine: launchEngine,
                                idempotencyKey: attempt.launchIdempotencyKey
                            )
                            // Create-only launch: prompt is sent after attachment upload.
                            // Reject non-accepted receipts and missing sessions.
                            guard response.receipt.accepted, let launched = response.session else {
                                throw QuickSessionError.agentLaunchFailed(
                                    response.receipt.promptError
                                        ?? response.receipt.reason
                                        ?? "The Agent did not start. Review its configuration and try again."
                                )
                            }
                            launchedSessionId = launched.id
                            attempt.sessionId = launched.id
                            agentSubmitAttempt = attempt
                        } catch let failure as AgentLaunchFailureResponse {
                            launchFailure = failure
                            throw QuickSessionError.agentLaunchFailed(failure.localizedDescription)
                        }
                    }

                    let scope = SessionRouteScope.workspace(workspace.id)
                    session = try await api.resumeWorkspaceSession(
                        workspaceId: workspace.id,
                        sessionId: launchedSessionId
                    )
                    let uploaded: [ChatAttachmentRef]
                    if let pendingUploads = attempt.uploadedAttachments {
                        uploaded = pendingUploads
                    } else {
                        uploaded = try await PendingAttachmentUploader.upload(
                            attachments,
                            api: api,
                            scope: scope,
                            sessionId: launchedSessionId
                        )
                        attempt.uploadedAttachments = uploaded
                        agentSubmitAttempt = attempt
                    }
                    // An Agent started into a Live Voice call may have nothing typed: the
                    // caller's first words are its first message.
                    if !plan.prompt.isEmpty || !uploaded.isEmpty {
                        try await api.sendWorkspaceSessionCommand(
                            workspaceId: workspace.id,
                            sessionId: launchedSessionId,
                            message: .prompt(
                                message: plan.prompt,
                                attachments: uploaded.isEmpty ? nil : uploaded,
                                requestId: attempt.clientTurnId,
                                clientTurnId: attempt.clientTurnId
                            )
                        )
                    }
                    session = try await api.getSession(scope: scope, sessionId: launchedSessionId).session
                    agentSubmitAttempt = nil
                    autoSendMessage = nil
                    autoSendAttachments = nil
                }

                // Upsert into the target server's session store — not the
                // active server's store, which may differ for cross-server
                // quick sessions.
                targetConnection.sessionStore.upsert(session)

                AppPreferences.QuickSession.saveWorkspaceId(workspace.id)
                if shouldRememberAgentSelection {
                    AppPreferences.QuickSession.saveAgentId(selectedAgentId)
                }
                ChatSessionTelemetry.recordTimingMetric(
                    .quickSessionCreateMs,
                    durationMs: max(0, ChatSessionTelemetry.nowMs() - telemetryStartedAtMs),
                    workspaceId: workspace.id,
                    tags: telemetryTags.merging(["status": "ok"]) { _, new in new }
                )
                logger.notice("Quick session created: \(session.id, privacy: .public) in workspace \(workspace.name, privacy: .public)")

                // Single atomic write — QuickSessionPresentation unpacks it on dismiss.
                nav.pendingQuickSessionNav = QuickSessionNav(
                    target: WorkspaceNavTarget(serverId: serverId, workspace: workspace),
                    sessionId: session.id,
                    autoSendMessage: autoSendMessage,
                    autoSendAttachments: autoSendAttachments,
                    startsLiveVoice: startsLiveVoice
                )

                launchedDraftPayload = submittedPayload
                if let submittedDraft {
                    composerDraftStore?.clearQuickSessionDraft(ifPayload: submittedDraft)
                }
                onDismiss()
            } catch {
                if let failure = error as? AgentLaunchFailureResponse {
                    launchFailure = failure
                }
                let errorKind = ChatSessionTelemetry.metricErrorKind(for: error)
                ChatSessionTelemetry.recordTimingMetric(
                    .quickSessionCreateMs,
                    durationMs: max(0, ChatSessionTelemetry.nowMs() - telemetryStartedAtMs),
                    workspaceId: workspace.id,
                    tags: telemetryTags.merging([
                        "status": "error",
                        "error_kind": errorKind,
                    ]) { _, new in new }
                )
                ChatSessionTelemetry.recordCountMetric(
                    .quickSessionError,
                    workspaceId: workspace.id,
                    tags: [
                        "source": "sheet",
                        "selection": selectedWorkspaceSelectionSource,
                        "error_kind": errorKind,
                    ]
                )
                self.error = error.localizedDescription
                isCreating = false
                logger.error("Quick session creation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
