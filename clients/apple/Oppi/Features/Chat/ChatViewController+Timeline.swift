import UIKit

// The chat's timeline and the values only it reads: chrome style, extension
// surfaces, the reader, and the destinations a row opens.

extension ChatViewController {
    /// The Agent's chat style on this device when it has one, else Settings →
    /// Chat → Style, at every width.
    var chatDisplayStyle: AppPreferences.ChatDisplay.Style {
        _ = model.chatDisplayRefresh
        return AppPreferences.ChatDisplay.style(serverId: resolvedServerId, agentId: session?.launch?.agentId)
    }

    var timelineChromeStyle: ChatTimelineChromeStyle {
        .for(chatDisplayStyle)
    }

    private var workStripStyle: AppPreferences.ChatDisplay.WorkStripStyle {
        _ = model.chatDisplayRefresh
        return AppPreferences.ChatDisplay.workStripStyle
    }

    /// The session's extension surfaces without the working text. The working
    /// row observes that text itself; reading it here would rerun this screen's
    /// `updateProperties()` on every elapsed-time tick.
    var extensionSurfaceState: ExtensionSurfaceState {
        extensionSurface.layout
    }

    var extensionSurface: SessionExtensionSurface {
        connection.extensionSurfaces.surface(for: sessionId)
    }

    var contextUsageSnapshot: ContextUsageSnapshot {
        let fallbackWindow: Int?
        if let model = session?.model {
            fallbackWindow = inferContextWindow(from: model)
        } else {
            fallbackWindow = nil
        }

        return ContextUsageSnapshot(
            tokens: session?.contextTokens,
            window: session?.contextWindow ?? fallbackWindow
        )
    }

    /// Commit and path-pill destinations are built here, not by the timeline, so the timeline
    /// holds no app services.
    private var timelineDestinationAction: ChatTimelineOpenDestination {
        let presenter = ChatTimelineDestinationPresenter(connection: connection)
        // Regular width opens it beside the chat, like the reader; narrow
        // width keeps the modal.
        return { [weak self] request in
            if request.placement != .here {
                let content = presenter.paneContent(for: request)
                PaneOpenMenu.open(request.placement, from: request.sourceView) { content }
            } else if let self, opensPanelsBeside {
                showPanel(.timeline(request.panelTarget))
            } else {
                presenter.open(request)
            }
        }
    }

    /// Older history pages load through this chat's own session runtime, rebound to the
    /// connection it already uses. The timeline only decides when to call it.
    private var olderTimelinePageAction: @MainActor () async -> Bool {
        let sessionManager = sessionManager
        let connection = connection
        return {
            let loaded = await sessionManager.loadOlderTracePage(
                connection: connection,
                sessionStore: connection.sessionStore
            )
            Self.reportOlderHistoryFailure(loaded: loaded, sessionManager: sessionManager, connection: connection)
            return loaded
        }
    }

    /// An older page the user asked for (Show Earlier, an outline jump) that the server did
    /// not deliver says so, instead of leaving the tap with no visible result.
    static func reportOlderHistoryFailure(
        loaded: Bool,
        sessionManager: ChatSessionManager,
        connection: ServerConnection
    ) {
        guard !loaded, sessionManager.olderHistoryLoadFailed else { return }
        connection.extensionToast = Self.olderHistoryFailureMessage
    }

    /// An outline jump that could not reach its row says why, so a tap never does nothing.
    static func reportOlderHistoryJump(_ outcome: ChatSessionManager.OlderHistoryJump, connection: ServerConnection) {
        switch outcome {
        case .reached: return
        case .failed: connection.extensionToast = olderHistoryFailureMessage
        case .notInHistory: connection.extensionToast = "That entry is no longer in this chat's history."
        }
    }

    private static let olderHistoryFailureMessage = "Couldn't load earlier messages from the server. Try again."

    static func currentToolFileTarget(
        serverId: String?,
        routeScope: SessionRouteScope?,
        sessionId: String,
        path: String
    ) -> WorkspaceLinkedFileNavTarget? {
        guard let serverId, !serverId.isEmpty else { return nil }
        switch routeScope {
        case .workspace(let workspaceId) where !workspaceId.isEmpty:
            return .sessionFile(
                serverId: serverId,
                workspaceId: workspaceId,
                sessionId: sessionId,
                path: path,
                sourceSessionId: sessionId
            )
        case .control:
            // Control sessions are owner-host sessions and have no workspace
            // route. Preserve that declared origin instead of inventing one.
            return .hostFile(
                serverId: serverId,
                workspaceId: "",
                path: path,
                sourceSessionId: sessionId,
                controlSessionId: sessionId
            )
        case .workspace, nil:
            return nil
        }
    }

    /// Origin stamp applied by ``openTimelineReader``.
    /// Uses the live composer destination when it belongs to this chat;
    /// otherwise the source-chat composer destination. Always overwrites any
    /// incoming payload stamp, including nil.
    static func stampedTimelineReaderPayload(
        _ payload: ChatReaderPayload,
        sessionId: String,
        composerDestination: ComposerCanvasDestination,
        lockOrigin: ScopedLockTarget? = nil
    ) -> ChatReaderPayload {
        let destination = ComposerCanvasActiveDestination.current.flatMap { current in
            current.sessionId == sessionId ? current : nil
        } ?? composerDestination
        return payload.stamped(with: destination, lockOrigin: lockOrigin)
    }

    /// This chat's lock scope; a reader opened from it follows the same lock.
    private var readerLockOrigin: ScopedLockTarget? {
        guard let serverId = resolvedServerId else { return nil }
        return ScopedLockService.shared.sessionTarget(
            serverId: serverId,
            sessionId: sessionId,
            workspaceId: session?.workspaceId ?? workspaceIdHint
        )
    }

    func openTimelineReader(_ payload: ChatReaderPayload) {
        guard let store = root?.chatReaderPayloadStore else { return }
        scrollController.suspendForNavigation()
        // The row may show a tool's output; the document it names is the live
        // file the pencil edits, read from this chat's own checkout.
        var readerPayload = Self.stampedTimelineReaderPayload(
            payload,
            sessionId: sessionId,
            composerDestination: canvasDestination,
            lockOrigin: readerLockOrigin
        )
        if case .document(let content, _) = readerPayload.kind {
            readerPayload.editSubject = liveFileSubject(for: content)
        }
        // Regular width shows every top-bar destination in the attached
        // leaf beside this chat, the reader included; narrow width keeps
        // the pushed `.chatReader` route.
        // The store keeps only what the shell's stack still names; a panel
        // reader holds its payload once it resolves it.
        let target = store.store(readerPayload, retaining: appNavigation.containsChatReader)
        if opensPanelsBeside {
            showPanel(.reader(target))
        } else {
            appNavigation.openChatReader(target)
        }
    }

    /// The live file a reader's bytes name, when this chat can resolve one. The
    /// row may show a tool's output; the pencil edits the file on disk now. A
    /// path in this chat's checkout reads as that workspace file; any other path
    /// the tool reported reads through this session, and the server names the
    /// origin that edits it (a sandbox session's path stays in its sandbox).
    private func liveFileSubject(for content: FullScreenCodeContent) -> DocumentEditSubject? {
        guard let path = content.filePath,
              let serverId = resolvedServerId,
              let workspaceId = timelineWorkspaceId,
              let workspace = connection.workspaceStore.workspaces.first(where: { $0.id == workspaceId }) else {
            return nil
        }
        guard let workspacePath = WorkspaceFileEditPath.reportedPath(
            path,
            runtime: workspace.runtime,
            hostMount: workspace.hostMount,
            worktreeId: session?.worktreeId
        ) else {
            return .file(
                serverId: serverId,
                source: .sessionFile(sessionId: sessionId),
                workspaceId: workspaceId,
                worktreeId: nil,
                path: path,
                skillFile: nil,
                fileKind: FileKind.detect(from: path),
                context: FileEditReadContext(sessionId: sessionId)
            )
        }
        return .file(
            serverId: serverId,
            source: .workspaceFile,
            workspaceId: workspaceId,
            worktreeId: session?.worktreeId,
            path: workspacePath,
            skillFile: nil,
            fileKind: FileKind.detect(from: workspacePath)
        )
    }

    /// The file a tool row changed, over the chat as a tap opens it, or in a
    /// pane from the row's menu.
    private func openCurrentToolFile(path: String, placement: PaneOpenPlacement) {
        let serverId = resolvedServerId
        guard let target = Self.currentToolFileTarget(
            serverId: serverId,
            routeScope: focusedRouteScope,
            sessionId: sessionId,
            path: path
        ), let serverId else {
            connection.extensionToast = "Could not open the current file"
            return
        }
        guard placement == .here else {
            PaneOpenMenu.open(placement, from: view) { PaneOpenContent(file: target) }
            return
        }

        NotificationCenter.default.post(
            name: .workspaceLinkedFileWillOpen,
            object: sessionId,
            userInfo: [Notification.Name.workspaceLinkedFileSourceServerIDKey: serverId]
        )
        appNavigation.openReferencedWorkspaceLinkedFile(
            target,
            sourceSession: WorkspaceSessionNavTarget(
                serverId: serverId,
                sessionId: sessionId,
                routeScope: focusedRouteScope
            )
        )
    }

    // MARK: - Timeline

    func makeTimelineConfiguration() -> ChatTimelineConfiguration {
        let extensionLayout = extensionSurfaceState
        return ChatTimelineConfiguration(
            items: [],
            hiddenCount: 0,
            renderWindowStep: TimelineRenderWindowPolicy.renderWindowStep,
            // Busy is not chrome: the timeline reads `sessionManager.isBusy` on
            // every apply so it lands with the rows.
            streamingAssistantID: nil,
            sessionId: sessionId,
            serverId: resolvedServerId,
            workspaceId: timelineWorkspaceId,
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon,
            // A message card names another session, so its header draws that
            // session's identity from its launch snapshot. An unknown sender
            // stays nil and reads as the global avatar.
            senderLaunch: { [sessionStore] sessionId in
                sessionStore.session(id: sessionId)?.launch
            },
            readAloudAvailable: connection.speechAvailable,
            routeScope: focusedRouteScope,
            onFork: { [weak self] in self?.forkFromMessage($0) },
            onOpenCurrentFile: { [weak self] in self?.openCurrentToolFile(path: $0, placement: $1) },
            onOpenSession: { [weak self] in self?.openChildSession($0) },
            onOpenChatReader: { [weak self] in self?.openTimelineReader($0) },
            onBackSwipe: { [weak self] in self?.navigateBackFromChat() },
            onShowEarlier: {},
            scrollController: scrollController,
            reducer: reducer,
            toolOutputStore: reducer.toolOutputStore,
            toolArgsStore: reducer.toolArgsStore,
            toolSegmentStore: reducer.toolSegmentStore,
            toolDetailsStore: reducer.toolDetailsStore,
            sessionContent: connection.sessionContent,
            iconAssetCache: connection.iconAssetCache,
            openDestination: timelineDestinationAction,
            loadOlderPage: olderTimelinePageAction,
            currentModel: session?.model,
            extensionSurface: extensionSurface,
            extensionHiddenThinkingLabel: extensionLayout.hiddenThinkingLabel,
            audioPlayer: audioPlayer,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            topOverlap: timelineTopOverlap,
            bottomOverlap: footerHeight,
            onVisibleAudioStripItemIDsChange: { [weak self] ids in
                guard let self, self.model.visibleAudioStripItemIDs != ids else { return }
                self.model.visibleAudioStripItemIDs = ids
            },
            ownsTimelineProjection: true,
            quietModeEnabled: chatDisplayStyle.foldsWork,
            workStripStyle: workStripStyle,
            chromeStyle: timelineChromeStyle,
            sessionManager: sessionManager,
            outlineAvailability: outlineAvailability
        )
    }

    /// Pushes chrome to the timeline when a value it shows changed. Streaming
    /// and busy are not this clock: the timeline observes the reducer and the
    /// session runtime itself, and this never reads `reducer.items`.
    func updateTimelineChrome() {
        guard let timelineView else { return }
        let extensionLayout = extensionSurfaceState
        let key = ChatTimelineChromeKey(
            workingVisible: extensionLayout.working?.visible,
            hiddenThinkingLabel: extensionLayout.hiddenThinkingLabel,
            serverId: resolvedServerId,
            workspaceId: timelineWorkspaceId,
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon,
            readAloudAvailable: connection.speechAvailable,
            routeScope: focusedRouteScope,
            model: session?.model,
            topOverlap: timelineTopOverlap,
            bottomOverlap: footerHeight,
            quietMode: chatDisplayStyle.foldsWork,
            workStripStyle: workStripStyle,
            chromeStyle: timelineChromeStyle,
            reviewTemplates: reviewCommentSelectionRouter.inlineQuickComments.map(\.id)
        )
        guard key != lastTimelineChrome else { return }
        lastTimelineChrome = key
        timeline.update(configuration: makeTimelineConfiguration(), collectionView: timelineView)
    }

}

struct ChatTimelineChromeKey: Equatable {
    let workingVisible: Bool?
    let hiddenThinkingLabel: String?
    let serverId: String?
    let workspaceId: String?
    let agentId: String?
    let agentIcon: IconChoice?
    /// `capabilities.speech`: reloaded on foreground and after a failed read aloud.
    let readAloudAvailable: Bool
    let routeScope: SessionRouteScope?
    let model: String?
    let topOverlap: CGFloat
    let bottomOverlap: CGFloat
    let quietMode: Bool
    let workStripStyle: AppPreferences.ChatDisplay.WorkStripStyle
    let chromeStyle: ChatTimelineChromeStyle
    let reviewTemplates: [UUID]
}
