import SwiftUI
import UIKit

struct TreeNavigationViewUpdate: Equatable {
    let scrollTargetID: String
    let inputText: String
    let shouldFocusComposer: Bool

    static func from(targetId: String, editorText: String?, showComposer: Bool) -> Self {
        let normalized = editorText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return Self(
            scrollTargetID: targetId,
            inputText: normalized,
            shouldFocusComposer: !normalized.isEmpty && !showComposer
        )
    }
}

struct ExtensionSurfaceSessionLink: Equatable {
    let sessionId: String
    let workspaceId: String?

    static func parse(_ url: URL, defaultWorkspaceId: String? = nil) -> Self? {
        guard url.scheme?.lowercased() == "oppi",
              url.host?.lowercased() == "session",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let pathParts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let rawId = pathParts.first, !rawId.isEmpty else {
            return nil
        }

        let sessionId = rawId.removingPercentEncoding ?? rawId
        guard !sessionId.isEmpty else { return nil }

        let queryWorkspaceId = components.queryItems?.first { $0.name == "workspaceId" }?.value
        let workspaceId = normalized(queryWorkspaceId) ?? normalized(defaultWorkspaceId)
        return Self(sessionId: sessionId, workspaceId: workspaceId)
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum ChatSessionWarningChrome {
    static func messages(from warnings: [String]?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for warning in warnings ?? [] {
            let trimmed = warning.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

struct ChatView: View {
    enum LocalSlashCommand: Equatable {
        case compact
    }

    let sessionId: String
    private let serverIdHint: String?
    private let workspaceIdHint: String?
    private let routeScope: SessionRouteScope?
    private let ownsWorkspacePathBackNavigation: Bool

    @Environment(ServerConnection.self) private var connection
    @Environment(ChatSessionState.self) private var chatState
    @AppStorage(AppPreferences.Experiments.durableSessionsKey) private var durableSessionsExperimentEnabled = false
    @Environment(AskRequestStore.self) private var askRequestStore
    @Environment(SessionStore.self) private var sessionStore
    @Environment(AudioPlayerService.self) private var audioPlayer
    @Environment(GitStatusStore.self) private var gitStatusStore
    @Environment(FileIndexStore.self) private var fileIndexStore
    @Environment(MessageQueueStore.self) private var messageQueueStore
    @Environment(AppNavigation.self) private var appNavigation
    @Environment(\.chatReaderPayloadStore) private var chatReaderPayloadStore
    @Environment(QuickCommentTemplateStore.self) private var quickCommentTemplateStore
    @Environment(\.composerDraftStore) private var composerDraftStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss

    @State private var sessionManager: ChatSessionManager
    @State private var sessionRuntimeLease: ChatSessionManagerLease
    @State private var scrollController = ChatScrollController()
    @State private var actionHandler = ChatActionHandler()
    @State private var voiceInputManager = VoiceInputManager.shared
    @State private var audioLifecycleCoordinator = AudioLifecycleCoordinator()
    @State private var composerDraftController: ChatComposerDraftController

    @State private var composerTextBeforeRecording: String?
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var messageQueueError: String?
#if DEBUG
    @State private var hasSeededE2EChatImageAttachment = false
#endif
    @State private var busyStreamingBehavior: StreamingBehavior = .steer
    @State private var isPreparingAttachments = false
    @State private var attachmentPreparationText: String?

    @State private var showOutline = false
    @State private var outlineAvailability = ChatTimelineOutlineAvailability()
    @State private var isFilePanelVisible = false
    @State private var selectedFilePanelTab: ChatFileBrowserPanelTab
    @State private var showModelPicker = false
    @State private var showComposer = false
    @State private var sessionRouteToOpen: SessionRoute?
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var forkedSessionToOpen: ForkRoute?
    @State private var showShareRedactionSheet = false
    @State private var shareRedactionPolicy = AppPreferences.Share.redactionPolicy
    @State private var sharePreflightResult: ShareSessionPrepareResult?
    @State private var sharePreflightError: String?
    @State private var isSharePreflightRunning = false
    @State private var sharePreflightTask: Task<Void, Never>?

    @State private var showContextInspector = false
    @State private var isKeyboardVisible = false
    @State private var footerHeight: CGFloat = 0
    @State private var timelineChromeFrame: CGRect = .zero
    @State private var headerChromeFrame: CGRect = .zero
    /// The workspace shell this chat was mounted under, for the shell-swap
    /// scroll handoff.
    @State private var mountedPresentation: WorkspaceNavigationPresentation = .stack
    @State private var visibleAudioStripItemIDs: Set<String> = []
    @State private var nowPlayingDrawerExpanded = false
    @State private var reviewCommentDrawerExpanded = false
    @State private var extensionDrawerCollapseRequestID = 0
    @State private var reviewCommentStashPresentation: ReviewCommentStripChrome.StashPresentation?
    @State private var composerExternalFocusRequestID = 0
    @State private var contextBarCollapseToken = 0
    @State private var contextBarExpanded = false
    @State private var reviewComments = ChatReviewCommentsController()
    @State private var activeReviewCommentRequest: ReviewCommentSelectionRequest?
    @State private var focusedReviewCommentId: String?
    @State private var chatDisplayRefresh = 0

    init(
        sessionId: String,
        serverIdHint: String? = nil,
        workspaceIdHint: String? = nil,
        routeScope: SessionRouteScope? = nil,
        initialInputText: String = "",
        initialPendingFiles: [PendingFileReference] = [],
        ownsWorkspacePathBackNavigation: Bool = false
    ) {
        self.sessionId = sessionId
        self.serverIdHint = serverIdHint
        self.workspaceIdHint = workspaceIdHint
        self.routeScope = routeScope
            ?? workspaceIdHint.map(SessionRouteScope.workspace)
        self.ownsWorkspacePathBackNavigation = ownsWorkspacePathBackNavigation
        let manager = ChatSessionManager(
            sessionId: sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: self.routeScope
        )
        _sessionManager = State(initialValue: manager)
        _sessionRuntimeLease = State(initialValue: ChatSessionManagerLease(manager: manager))
        _composerDraftController = State(initialValue: ChatComposerDraftController(
            initialText: initialInputText,
            initialRepoPointers: initialPendingFiles
        ))
        _selectedFilePanelTab = State(initialValue: ChatFileBrowserPanelTabStore.shared.tab(for: sessionId))
    }

    private struct ForkRoute: Identifiable, Hashable {
        let id: String
        let workspaceId: String?
    }

    private struct SessionRoute: Identifiable, Hashable {
        let id: String
        let workspaceId: String?
    }

    private struct ComposerDraftAttachmentKey: Equatable {
        let key: ComposerDraftKey?
        let isEphemeral: Bool
    }

    private enum TreeNavigationError: LocalizedError {
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

    /// Per-session reducer, owned by sessionManager.
    private var reducer: TimelineReducer { sessionManager.reducer }

    private var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    private var workspace: Workspace? {
        guard let workspaceId = session?.workspaceId else { return nil }
        return connection.workspaceStore.workspaces.first { $0.id == workspaceId }
    }

    private var assistantIdentityPresentation: AssistantIdentityPresentation {
        AssistantIdentityPresentation.resolve(
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon
        )
    }

    private var timelineWorkspaceId: String? {
        let sessionWorkspaceId = session?.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sessionWorkspaceId, !sessionWorkspaceId.isEmpty {
            return sessionWorkspaceId
        }
        let fallback = workspaceIdHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback : nil
    }

    private var focusedRouteScope: SessionRouteScope? {
        if session?.control != nil || session?.isControlConversation == true { return .control }
        if let timelineWorkspaceId { return .workspace(timelineWorkspaceId) }
        return routeScope
    }

    private var reviewCommentLocalScopeId: String? {
        Self.reviewCommentLocalScopeId(routeScope: focusedRouteScope)
    }

    static func reviewCommentLocalScopeId(routeScope: SessionRouteScope?) -> String? {
        switch routeScope {
        case .control:
            return SessionRouteScope.control.composerDraftScopeID
        case .workspace(let workspaceId):
            return workspaceId
        case nil:
            return nil
        }
    }

    static func reviewCommentPathFormattingPolicy(
        controlDomain: ControlSessionDomain?
    ) -> ReviewCommentPathFormatting {
        controlDomain == .skills ? .verbatim : .normalizedDisplay
    }

    private var reviewCommentPathFormatting: ReviewCommentPathFormatting {
        Self.reviewCommentPathFormattingPolicy(controlDomain: session?.control?.domain)
    }

    private var composerDraftKey: ComposerDraftKey? {
        guard let serverID = connection.currentServerId ?? sessionStore.activeServerId,
              let workspaceID = focusedRouteScope?.composerDraftScopeID else {
            return nil
        }
        return ComposerDraftKey(
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionId
        )
    }

    private var composerDraftAttachmentKey: ComposerDraftAttachmentKey {
        ComposerDraftAttachmentKey(
            key: composerDraftKey,
            isEphemeral: composerDraftIsMemoryOnly
        )
    }

    /// Unknown session metadata stays memory-only until the session record confirms
    /// that local persistence is allowed. This avoids briefly writing incognito text.
    private var composerDraftIsMemoryOnly: Bool {
        Self.composerDraftIsMemoryOnly(
            hasSessionMetadata: session != nil,
            isEphemeral: session?.ephemeral
        )
    }

    static func composerDraftIsMemoryOnly(
        hasSessionMetadata: Bool,
        isEphemeral: Bool?
    ) -> Bool {
        !hasSessionMetadata || isEphemeral == true
    }

    static func resolvedComposerMode(
        hasReviewComment: Bool,
        hasAskRequest: Bool
    ) -> ChatComposerDraftController.Mode {
        if hasReviewComment { return .reviewComment }
        if hasAskRequest { return .ask }
        return .message
    }

    /// Apply a composer attachment-bar update. Message mode stores it; a refused
    /// non-message update discards any unreferenced draft files.
    @discardableResult
    static func applyPendingAttachments(
        _ newAttachments: [PendingAttachment],
        draftController: ChatComposerDraftController,
        current: [PendingAttachment]
    ) -> [PendingAttachment]? {
        guard draftController.setPendingAttachments(newAttachments) else {
            return nil
        }
        return newAttachments
    }

    /// Shared by the viewer destination and composer callback.
    /// Accept only if the message-mode draft actually stored the attachment.
    @discardableResult
    static func deliverCanvasToComposer(
        attachment: PendingAttachment,
        recognizedText _: String,
        draftController: ChatComposerDraftController,
        pendingAttachments: inout [PendingAttachment]
    ) -> Bool {
        var nextAttachments = pendingAttachments
        if !nextAttachments.contains(where: { $0.id == attachment.id }) {
            nextAttachments.append(attachment)
        }
        guard draftController.setPendingAttachments(nextAttachments),
              draftController.pendingAttachments.contains(where: { $0.id == attachment.id }) else {
            return false
        }
        pendingAttachments = draftController.pendingAttachments
        return true
    }

    static func resolvedComposerAskRequest(
        _ askRequest: AskRequest?,
        hasReviewComment: Bool
    ) -> AskRequest? {
        hasReviewComment ? nil : askRequest
    }

    static func localSlashCommand(for text: String) -> LocalSlashCommand? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.caseInsensitiveCompare("/compact") == .orderedSame ? .compact : nil
    }

    static func availableSlashCommands(from serverCommands: [SlashCommand]) -> [SlashCommand] {
        guard !serverCommands.contains(where: {
            $0.name.caseInsensitiveCompare("compact") == .orderedSame
        }) else {
            return serverCommands
        }

        return serverCommands + [SlashCommand(
            name: "compact",
            description: "Compact context",
            source: .builtin
        )]
    }

    private var composerTextBinding: Binding<String> {
        Binding(
            get: { composerDraftController.text },
            set: { newText in
                let mode = Self.resolvedComposerMode(
                    hasReviewComment: activeReviewCommentRequest != nil,
                    hasAskRequest: activeComposerAskRequest != nil
                )
                composerDraftController.updateVisibleText(newText, for: mode)
            }
        )
    }

    private var composerRepoPointersBinding: Binding<[PendingFileReference]> {
        Binding(
            get: { composerDraftController.repoPointers },
            set: { composerDraftController.repoPointers = $0 }
        )
    }

    private var composerPendingAttachmentsBinding: Binding<[PendingAttachment]> {
        Binding(
            get: { pendingAttachments },
            set: { newAttachments in
                guard let accepted = Self.applyPendingAttachments(
                    newAttachments,
                    draftController: composerDraftController,
                    current: pendingAttachments
                ) else { return }
                pendingAttachments = accepted
            }
        )
    }

    private var availableSlashCommands: [SlashCommand] {
        Self.availableSlashCommands(from: chatState.slashCommands)
    }

    private var hasShareSlashCommand: Bool {
        chatState.slashCommands.contains { command in
            command.name.caseInsensitiveCompare("share") == .orderedSame
        }
    }

    private var sessionDisplayName: String {
        session?.displayTitle ?? "Session \(String(sessionId.prefix(8)))"
    }

    private var isBusy: Bool {
        session?.status == .busy || session?.status == .stopping
    }

    private var isStopping: Bool {
        actionHandler.isStopping || session?.status == .stopping
    }

    private var isStopped: Bool {
        session?.status == .stopped
    }

    /// Compact turns are a narrow-width density mode. Settings shows the
    /// toggle under the same rule (`SettingsChatPage`); change both together.
    private var compactTurnsEnabled: Bool {
        _ = chatDisplayRefresh
        return horizontalSizeClass == .compact
            && AppPreferences.ChatDisplay.isCompactTurnsEnabled
    }

    private var workStripStyle: AppPreferences.ChatDisplay.WorkStripStyle {
        _ = chatDisplayRefresh
        return AppPreferences.ChatDisplay.workStripStyle
    }

    private var messageQueueState: MessageQueueState {
        messageQueueStore.queue(for: sessionId)
    }

    private var hasQueuedMessages: Bool {
        !messageQueueState.steering.isEmpty || !messageQueueState.followUp.isEmpty
    }

    private var showsMessageQueue: Bool {
        hasQueuedMessages || messageQueueError != nil
    }

    private var messageQueueSurfaceConfiguration: MessageQueueSurfaceConfiguration {
        MessageQueueSurfaceConfiguration(
            queue: messageQueueState,
            onRemove: { itemId in
                messageQueueError = nil
                try await connection.removeQueuedMessage(itemId: itemId, sessionIdOverride: sessionId)
            },
            onEditInComposer: { try await restoreQueuedMessagesToComposer() },
            error: messageQueueError
        )
    }

    private var extensionSurfaceState: ExtensionSurfaceState? {
        connection.extensionSurfaceBySession[sessionId]
    }

    private var activeComposerAskRequest: AskRequest? {
        askRequestStore.pending(for: sessionId)
    }

    private var composerAskRequest: AskRequest? {
        Self.resolvedComposerAskRequest(
            activeComposerAskRequest,
            hasReviewComment: activeReviewCommentRequest != nil
        )
    }

    private var hasBlockingExtensionInput: Bool {
        activeComposerAskRequest != nil || connection.hasPendingExtensionDialog(for: sessionId)
    }

    /// Show toolbar when composing (keyboard up) or at bottom of chat.
    /// Hide when scrolled up to read history.

    private var contextUsageSnapshot: ContextUsageSnapshot {
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

    var body: some View {
        chatContent
            .environment(sessionManager.reducer)
            .environment(sessionManager.reducer.toolOutputStore)
            .environment(sessionManager.reducer.toolArgsStore)
            .environment(\.composerMediaImportGate, composerDraftController.mediaImportGate)
    }

    private var chatTimeline: some View {
        ChatTimelineView(
            sessionId: sessionId,
            serverId: serverIdHint ?? connection.currentServerId ?? sessionStore.activeServerId,
            workspaceId: timelineWorkspaceId,
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon,
            routeScope: focusedRouteScope,
            isBusy: isBusy,
            extensionWorkingState: extensionSurfaceState?.working,
            extensionHiddenThinkingLabel: extensionSurfaceState?.hiddenThinkingLabel,
            currentModel: session?.model,
            sessionContent: connection.sessionContent,
            iconAssetCache: connection.iconAssetCache,
            openDestination: timelineDestinationAction,
            loadOlderPage: olderTimelinePageAction,
            scrollController: scrollController,
            sessionManager: sessionManager,
            audioLifecycleCoordinator: audioLifecycleCoordinator,
            quietModeEnabled: compactTurnsEnabled,
            workStripStyle: workStripStyle,
            onFork: forkFromMessage,
            onOpenCurrentFile: openCurrentToolFile,
            onOpenChatReader: openTimelineReader,
            onBackSwipe: navigateBackFromChat,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            topOverlap: timelineTopOverlap,
            bottomOverlap: footerHeight,
            onVisibleAudioStripItemIDsChange: { ids in
                visibleAudioStripItemIDs = ids
            },
            outlineAvailability: outlineAvailability
        )
    }

    /// Commit and path-pill destinations are built here, not by the timeline, so the timeline
    /// holds no app services.
    private var timelineDestinationAction: ChatTimelineOpenDestination {
        let presenter = ChatTimelineDestinationPresenter(
            connection: connection,
            audioPlayer: audioPlayer,
            composerDraftStore: composerDraftStore
        )
        return { presenter.open($0) }
    }

    /// Older history pages load through this chat's own session runtime, rebound to the
    /// connection it already uses. The timeline only decides when to call it.
    private var olderTimelinePageAction: @MainActor () async -> Bool {
        let sessionManager = sessionManager
        let connection = connection
        return {
            await sessionManager.loadOlderTracePage(
                connection: connection,
                sessionStore: connection.sessionStore
            )
        }
    }

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

    private var composerCanvasDestination: ComposerCanvasDestination {
        ComposerCanvasDestination(sessionId: sessionId) { attachment, recognizedText in
            deliverCanvasToComposer(
                attachment: attachment,
                recognizedText: recognizedText
            )
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
        guard let serverId = serverIdHint ?? connection.currentServerId ?? sessionStore.activeServerId else {
            return nil
        }
        return ScopedLockService.shared.sessionTarget(
            serverId: serverId,
            sessionId: sessionId,
            workspaceId: session?.workspaceId ?? workspaceIdHint
        )
    }

    private func openTimelineReader(_ payload: ChatReaderPayload) {
        guard let store = chatReaderPayloadStore else { return }
        scrollController.suspendForNavigation()
        appNavigation.openChatReader(
            store.store(
                Self.stampedTimelineReaderPayload(
                    payload,
                    sessionId: sessionId,
                    composerDestination: composerCanvasDestination,
                    lockOrigin: readerLockOrigin
                ),
                retaining: appNavigation.containsChatReader
            )
        )
    }

    private func openCurrentToolFile(path: String) {
        let serverId = serverIdHint ?? connection.currentServerId ?? sessionStore.activeServerId
        guard let target = Self.currentToolFileTarget(
            serverId: serverId,
            routeScope: focusedRouteScope,
            sessionId: sessionId,
            path: path
        ), let serverId else {
            connection.extensionToast = "Could not open the current file"
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

    private var showsNowPlayingPill: Bool {
        InAppNowPlayingChrome.shouldShowChatPill(
            hasActivePlayback: audioPlayer.hasActivePlayback,
            playbackItemID: InAppNowPlayingChrome.playbackItemID(
                playingItemID: audioPlayer.playingItemID,
                loadingItemID: audioPlayer.loadingItemID
            ),
            visibleStripItemIDs: visibleAudioStripItemIDs
        )
    }

    private var showsReviewCommentPill: Bool {
        ReviewCommentStripChrome.shouldShowPill(
            stagedCount: reviewComments.stagedCount,
            isDraftingComment: activeReviewCommentRequest != nil
        )
    }

    private func toggleNowPlayingDrawer() {
        let next = ReviewCommentStripChrome.toggleNowPlaying(
            .init(
                commentsExpanded: reviewCommentDrawerExpanded,
                nowPlayingExpanded: nowPlayingDrawerExpanded
            )
        )
        reviewCommentDrawerExpanded = next.commentsExpanded
        nowPlayingDrawerExpanded = next.nowPlayingExpanded
        if nowPlayingDrawerExpanded {
            dismissKeyboard()
        }
    }

    private func toggleReviewCommentDrawer() {
        let next = ReviewCommentStripChrome.toggleComments(
            .init(
                commentsExpanded: reviewCommentDrawerExpanded,
                nowPlayingExpanded: nowPlayingDrawerExpanded
            )
        )
        reviewCommentDrawerExpanded = next.commentsExpanded
        nowPlayingDrawerExpanded = next.nowPlayingExpanded
        if reviewCommentDrawerExpanded {
            // Extension panels own their selection; ask both placements to
            // collapse without hiding their pills or resetting their content.
            extensionDrawerCollapseRequestID &+= 1
            dismissKeyboard()
        }
    }

    private func handleExtensionDrawerExpansion(_ expanded: Bool) {
        if expanded {
            reviewCommentDrawerExpanded = false
            dismissKeyboard()
        }
    }

    private var timelineTopOverlap: CGFloat {
        ChatTimelineChromeOverlap.topInset(
            timelineFrame: timelineChromeFrame,
            headerFrame: headerChromeFrame
        )
    }

    private var chatTimelineScaffold: some View {
        chatTimeline
            // Measured inside `ignoresSafeArea`: the frame reaches up under
            // the navigation bar (see ChatTimelineChromeOverlap).
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .global)
            } action: {
                timelineChromeFrame = $0
            }
            .ignoresSafeArea(.container, edges: .top)
            .overlay {
                // Dismiss scrim: dims the timeline so content doesn't
                // bleed through the context bar's glass effect, and
                // collapses the bar on tap. Using a semi-opaque fill
                // instead of Color.clear prevents the visual overlap
                // between expanded bar content and the timeline behind.
                if contextBarExpanded {
                    Rectangle().fill(.themeDimScrim)
                        .ignoresSafeArea()
                        .onTapGesture { contextBarCollapseToken &+= 1 }
                }
            }
            .overlay(alignment: .top) {
                WorkspaceContextBar(
                    gitStatus: gitStatusStore.gitStatus,
                    isLoading: gitStatusStore.isLoading,
                    workspaceId: session?.workspaceId,
                    sessionId: sessionId,
                    worktreeId: session?.worktreeId,
                    serverId: serverIdHint ?? connection.currentServerId,
                    onReviewInCurrentSession: { prompt, files in
                        stageWorkspaceReviewInCurrentSession(prompt: prompt, files: files)
                    },
                    fileDetailReviewCommentScope: .activeSession(reviewCommentSelectionRouter),
                    collapseToken: contextBarCollapseToken,
                    onExpandedChanged: handleContextBarExpandedChanged
                )
                .modifier(ChatTimelineChromeOverlap.HuggingHeader())
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    headerChromeFrame = $0
                }
            }
            .overlay(alignment: .bottom) {
                footerArea
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
            .overlay(alignment: .bottomTrailing) {
                if scrollController.isJumpToBottomHintVisible {
                    JumpToBottomHintButton(
                        isBusy: isBusy,
                        modelId: session?.model,
                        onTap: { scrollController.requestScrollToBottom() }
                    )
                    .padding(.trailing, 27)
                    .padding(.bottom, footerHeight + 10)
                    .transition(ThemeMotion.scaleFade(scale: 0.96, anchor: .bottomTrailing, reduceMotion: reduceMotion))
                }
            }
            .animation(ThemeMotion.easeInOut(duration: 0.18, reduceMotion: reduceMotion), value: scrollController.isJumpToBottomHintVisible)
            .onChange(of: scrollController.isJumpToBottomHintVisible) { _, visible in
                if visible { contextBarCollapseToken &+= 1 }
            }

            .onChange(of: showsNowPlayingPill) { _, visible in
                if !visible {
                    nowPlayingDrawerExpanded = false
                }
            }
            .onChange(of: showsReviewCommentPill) { _, visible in
                if !visible {
                    reviewCommentDrawerExpanded = false
                }
            }
    }

    private var chatContent: some View {
        chatLifecycleContent
    }

    private var chatPresentationContent: some View {
        readingToolbarVerticalEdge { edge in
            chatPresentation(railEdge: edge)
        }
    }

    @ViewBuilder
    private func chatPresentation(railEdge: HorizontalEdge?) -> some View {
        let joinsRail = railEdge != nil
        configuredChatContent(railEdge: railEdge)
            .inspector(isPresented: sidePanelPresented(railEdge: railEdge)) { chatSidePanel }
            .chatAuxiliaryPresentation(
                isPresented: joinsRail && horizontalSizeClass == .regular ? .constant(false) : $showOutline,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { outlineSheet }
            .chatAuxiliaryPresentation(
                isPresented: joinsRail && horizontalSizeClass == .regular ? .constant(false) : $isFilePanelVisible,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { filePanelSheet }
            .sheet(isPresented: $showModelPicker) { modelPickerSheet }
            .sheet(item: $reviewCommentStashPresentation) { presentation in
                reviewCommentStashSheet(presentation)
            }
            .chatAuxiliaryPresentation(
                isPresented: joinsRail && horizontalSizeClass == .regular ? .constant(false) : $showContextInspector,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { contextInspectorSheet }
            .chatAuxiliaryPresentation(
                isPresented: $showShareRedactionSheet,
                prefersFullScreen: prefersFullScreenChatAuxiliaryPresentation
            ) { shareRedactionSheet }
            .fullScreenCover(isPresented: $showComposer) { composerSheet }
            .alert("Rename Session", isPresented: $showRenameAlert) { renameAlert }
    }

    private var chatSessionTaskContent: some View {
        chatPresentationContent
            .task(id: composerDraftAttachmentKey) {
                attachComposerDraftIfPossible()
            }
            .task(id: sessionId) {
                audioPlayer.setSessionContext(session)
                activateChatVoiceComposer(voiceInputManager)
                audioLifecycleCoordinator.setPlaybackInterrupter(audioPlayer)
                // Dictation must use the concrete player as the hardware source of truth.
                // The lifecycle coordinator owns presentation state and can be stale across
                // direct-speak/reconnect edges; using it here can make the mic appear wedged.
                voiceInputManager.setPlaybackInterrupter(audioPlayer)
                // Manager owns loop restarts. This task only binds the session
                // identity; cancelling it must not cancel the connect loop.
                sessionManager.ensureConnected(
                    connection: connection,
                    sessionStore: sessionStore
                )
            }
            .task {
                // Pre-warm voice input pipeline in background (model check + transcriber creation)
                if ReleaseFeatures.voiceInputEnabled {
                    await voiceInputManager.prewarm(source: "chat_view_task")
                }
            }
            .task(id: ReviewCommentLoadKey(localScopeId: reviewCommentLocalScopeId, sessionId: sessionId)) {
                loadReviewCommentsIfPossible()
            }
            .onChange(of: session?.displayTitle) { _, _ in
                audioPlayer.setSessionContext(session)
            }
            .onChange(of: session?.model) { _, _ in
                audioPlayer.setSessionContext(session)
            }
            .task(id: sessionId) {
                // Auto-send pending message from QuickSessionSheet.
                // Keyed on sessionId so it re-fires if the view is reused
                // for a different session (onChange self-healing path).
                guard let message = appNavigation.pendingQuickSessionMessage else { return }
                let attachments = appNavigation.pendingQuickSessionAttachments ?? []
                // Consume immediately so it doesn't re-fire
                appNavigation.pendingQuickSessionMessage = nil
                appNavigation.pendingQuickSessionAttachments = nil

                // Pre-fill the composer so the user sees their message while connecting.
                composerDraftController.replaceMessage(
                    text: message,
                    pendingAttachments: attachments
                )
                pendingAttachments = attachments

                // Wait for the session stream to be established AND the WebSocket
                // to be connected. The stream can briefly reach .streaming then
                // drop during app launch; retry the wait if it bounces.
                let deadline = ContinuousClock.now + .seconds(15)
                while true {
                    if Task.isCancelled { return }
                    if ContinuousClock.now >= deadline { return } // Timeout — user can send manually
                    if isReadyForQuickSend { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }

                // Brief settle for UI
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }

                // Auto-send through the normal WebSocket flow
                sendPrompt()
            }
    }

    private var chatLifecycleContent: some View {
        chatSessionTaskContent
            .onReceive(NotificationCenter.default.publisher(for: AppPreferences.ChatDisplay.didChangeNotification)) { _ in
                chatDisplayRefresh += 1
            }
            .onAppear {
                handleAppear()
#if DEBUG
                seedE2EChatImageAttachmentIfRequested()
#endif
                applyExtensionToolsExpandedState()
            }
            .background {
                ComposerCanvasDestinationAnchor(
                    destination: composerCanvasDestination,
                    reviewCommentSelectionRouter: reviewCommentSelectionRouter
                )
            }
            .onChange(of: chatState.extensionEditorTextUpdate?.revision) { _, _ in
                handleExtensionEditorTextUpdate()
            }
            .onChange(of: activeComposerAskRequest?.id) { _, _ in
                synchronizeComposerMode()
            }
            .onChange(of: extensionSurfaceState?.toolsExpanded) { _, _ in
                applyExtensionToolsExpandedState()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
                contextBarCollapseToken &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            .onChange(of: session?.status) { _, newStatus in
                handleSessionStatusChange(newStatus)
            }
            .onChange(of: sessionManager.entryState) { _, newState in
                handleEntryStateChange(newState)
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhaseChange(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: AudioPlayerService.stateDidChangeNotification)) { notification in
                handleAudioPlayerStateChange(notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .workspaceLinkedFileWillOpen)) { notification in
                guard notification.object as? String == sessionId,
                      let sourceServerID = notification.userInfo?[Notification.Name.workspaceLinkedFileSourceServerIDKey] as? String,
                      sourceServerID == connection.currentServerId else {
                    return
                }
                // Capture while the source timeline still owns its live geometry;
                // NavigationStack teardown can report tail geometry before onDisappear.
                scrollController.suspendForNavigation()
            }
            .onChange(of: sessionId) { oldId, newId in
                // Self-healing: when SwiftUI reuses this view at the same
                // structural position with a different session ID (e.g.
                // deep-link navigation, quick session switch), @State is
                // preserved. Detect the mismatch and reset all session-
                // specific state so the timeline and connection match.
                guard sessionManager.sessionId != newId else { return }

                // Tear down old session. cleanup() releases only the old
                // runtime's own focus claim (live audio still defers it).
                actionHandler.cleanup()
                sessionManager.cleanup()
                scrollController.cancel()
                ChatScrollShellSwapHandoff.shared.chatDidDisappear(
                    sessionId: oldId,
                    controller: scrollController,
                    mountedPresentation: mountedPresentation,
                    currentPresentation: mountedPresentation
                )
                visibleAudioStripItemIDs = []
                chatReaderPayloadStore?.removeAll()
                nowPlayingDrawerExpanded = false
                reviewCommentDrawerExpanded = false
                reviewCommentStashPresentation = nil

                // Stand up new session. Detach the draft key before any new
                // workspace metadata resolves so edits cannot hit the old session.
                composerDraftController.detachForSessionChange()
                sessionManager = ChatSessionManager(
                    sessionId: newId,
                    workspaceIdHint: workspaceIdHint,
                    routeScope: focusedRouteScope
                )
                sessionRuntimeLease.manager = sessionManager
                // The chat on screen now shows newId: claim it like an appear.
                sessionManager.claimFocusOnAppear(connection: connection, sessionStore: sessionStore)
                // Session switches can happen while the scene is already
                // inactive/background (deep link, iPad multitasking). The new
                // coalescer starts unpaused — re-apply the hard boundary.
                if Self.shouldPauseTimelinePresentation(for: scenePhase) {
                    sessionManager.coalescer.pause()
                }
                scrollController = ChatScrollController()
                ChatScrollShellSwapHandoff.shared.chatDidAppear(
                    sessionId: newId,
                    controller: scrollController,
                    presentation: mountedPresentation
                )
                reviewComments = ChatReviewCommentsController()
                activeReviewCommentRequest = nil
                focusedReviewCommentId = nil
                pendingAttachments = []
                contextBarExpanded = false
                showOutline = false
                isFilePanelVisible = false
                selectedFilePanelTab = ChatFileBrowserPanelTabStore.shared.tab(for: newId)
                showContextInspector = false
                attachComposerDraftIfPossible()
            }
            .onChange(of: selectedFilePanelTab) { _, newTab in
                ChatFileBrowserPanelTabStore.shared.setTab(newTab, for: sessionId)
            }
            .onDisappear {
                // Freeze the viewport before cleanup can publish an empty timeline
                // and make collection geometry look tail-attached during the push.
                scrollController.suspendForNavigation()
                ChatScrollShellSwapHandoff.shared.chatDidDisappear(
                    sessionId: sessionId,
                    controller: scrollController,
                    mountedPresentation: mountedPresentation,
                    currentPresentation: appNavigation.workspaceNavigationPresentation
                )
                guard !appNavigation.isCoveringChat(sessionId: sessionId) else { return }
                actionHandler.cleanup()
                // Releases this runtime's focus claim only; a newer chat for the
                // same session keeps its stream (late or repeated cleanup is a no-op).
                sessionManager.cleanup()
                Task {
                    if let composerDraftStore {
                        await composerDraftStore.flush()
                    }
                    await sessionManager.flushSnapshotIfNeeded(connection: connection, force: true)
                }
            }
    }

    /// A regular-width window (iPad, the iPhone Duo inner display, a large
    /// iPhone in landscape) has room for full-screen panels.
    private var prefersFullScreenChatAuxiliaryPresentation: Bool {
        horizontalSizeClass == .regular
    }

    private func configuredChatContent(railEdge: HorizontalEdge?) -> some View {
        configuredChatToolbarContent(railEdge: railEdge)
    }

    @ViewBuilder
    private func configuredChatToolbarContent(railEdge: HorizontalEdge?) -> some View {
        let joinsRail = railEdge != nil
        configuredChatNavigationContent(railEdge: railEdge)
            .toolbarVisibility(.hidden, for: .tabBar)
            .toolbarVisibility(
                WorkspaceSessionNavigationChromePolicy.bottomBarVisibility(on: .sessionTimeline),
                for: .bottomBar
            )
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbar {
                if joinsRail {
                    chatRailToolbarContent(railEdge: railEdge)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        chatLeadingToolbarItem
                    }

                    ToolbarItem(placement: .principal) {
                        chatPrincipalToolbarItem
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        chatTrailingToolbarItem(railEdge: railEdge)
                    }
                }
            }
    }

    /// One control per rail slot, top to bottom: back, session, files,
    /// outline, context. The title text has no room on the rail, so the
    /// session slot is the avatar and carries the title's menu actions.
    /// Overflow empties the rail from the bottom; on a short rail (the Duo
    /// cover display in landscape) Back, Files, and Context stay, and the
    /// session menu and outline go to the overflow menu first.
    @ToolbarContentBuilder
    private func chatRailToolbarContent(railEdge: HorizontalEdge?) -> some ToolbarContent {
        if usesCustomChatBackButton {
            verticalRailToolbarItem(joinsVerticalRail: true) {
                chatBackButton
            }
            .chatRailKeepsVisible()
        }
        verticalRailToolbarItem(joinsVerticalRail: true) {
            chatRailSessionMenu
        }
        if session?.workspaceId != nil {
            verticalRailToolbarItem(joinsVerticalRail: true) {
                chatFilesToolbarItem
            }
            .chatRailKeepsVisible()
        }
        if outlineAvailability.isAvailable {
            verticalRailToolbarItem(joinsVerticalRail: true) {
                chatOutlineButton(railEdge: railEdge)
            }
        }
        verticalRailToolbarItem(joinsVerticalRail: true) {
            contextRingButton(railEdge: railEdge)
        }
        .chatRailKeepsVisible()
    }

    private var chatRailSessionMenu: some View {
        Menu {
            Section(sessionDisplayName) {
                Button("Rename", systemImage: "pencil") {
                    renameText = session?.name ?? ""
                    showRenameAlert = true
                }
                Button("Copy Session ID", systemImage: "doc.on.doc") {
                    copySessionID()
                }
                Button("Share Session", systemImage: "square.and.arrow.up") {
                    shareSessionFromTitleMenu()
                }
                .disabled(!hasShareSlashCommand)
            }
        } label: {
            switch assistantIdentityPresentation {
            case .agent:
                AgentIconView(
                    value: session?.launch?.agentIcon,
                    size: AgentIconSizingPolicy.titleTextMinimum,
                    isDecorative: true,
                    renderStyle: .chatTitle
                )
            case .globalAvatar:
                PiAvatarView(size: 22)
            }
        }
        .accessibilityLabel("Session")
        .accessibilityValue(sessionDisplayName)
        .accessibilityIdentifier("chat.rail.session")
    }

    /// At most one side panel at a time; the newest request wins.
    private enum ChatSidePanel {
        case files, outline, context
    }

    /// The column needs regular width. On a narrow rail screen (the Duo's
    /// cover display) the inspector would become a sheet, so the existing
    /// sheets stay in charge there. `railEdge` is the system's preferred
    /// edge, nil where no vertical bar is placed.
    private func usesTrailingSidePanel(railEdge: HorizontalEdge?) -> Bool {
        railEdge != nil && horizontalSizeClass == .regular
    }

    /// Content follows the panel flags alone. Gating it on the rail too can
    /// leave a presented column empty while the rail trait settles.
    private var activeSidePanel: ChatSidePanel? {
        if isFilePanelVisible { return .files }
        if showOutline { return .outline }
        if showContextInspector { return .context }
        return nil
    }

    private func sidePanelPresented(railEdge: HorizontalEdge?) -> Binding<Bool> {
        Binding(
            get: { usesTrailingSidePanel(railEdge: railEdge) && activeSidePanel != nil },
            set: { presented in
                guard !presented else { return }
                isFilePanelVisible = false
                showOutline = false
                showContextInspector = false
            }
        )
    }

    @ViewBuilder
    private var chatSidePanel: some View {
        Group {
            switch activeSidePanel {
            case .files: filePanelSheet
            case .outline: outlineSheet
            case .context: contextInspectorSheet
            case nil: EmptyView()
            }
        }
        .inspectorColumnWidth(min: 320, ideal: 400, max: 520)
    }

    /// Rail buttons stay visible beside an open panel, so they switch panels.
    private func showSidePanel(_ panel: ChatSidePanel?) {
        isFilePanelVisible = panel == .files
        showOutline = panel == .outline
        showContextInspector = panel == .context
    }

    private func configuredChatNavigationContent(railEdge: HorizontalEdge?) -> some View {
        chatTimelineScaffold
            .themedScrollSurface()
            // On the side rail the system draws the title as its own strip
            // above the timeline. The rail session menu carries the name.
            .navigationTitle(railEdge == nil ? sessionDisplayName : "")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(usesCustomChatBackButton)
            .navigationDestination(item: $forkedSessionToOpen) { route in
                Self(sessionId: route.id, workspaceIdHint: route.workspaceId)
            }
            .navigationDestination(item: $sessionRouteToOpen) { route in
                Self(sessionId: route.id, workspaceIdHint: route.workspaceId)
            }
            .environment(\.openChatReader, ChatReaderOpenAction(handler: openTimelineReader))
    }

    @ViewBuilder
    private var footerArea: some View {
        if isStopped {
            SessionEndedFooter(
                session: session,
                isResuming: actionHandler.isResuming,
                onResume: {
                    actionHandler.resumeSession(
                        connection: connection,
                        reducer: reducer,
                        sessionStore: sessionStore,
                        sessionManager: sessionManager,
                        sessionId: sessionId
                    )
                }
            )
        } else {
            VStack(spacing: 8) {
                if !hasBlockingExtensionInput {
                    let surface = extensionSurfaceState ?? ExtensionSurfaceState()
                    if ReviewCommentStripChrome.shouldShowAboveEditorStrip(
                        showsReviewCommentPill: showsReviewCommentPill,
                        showsNowPlayingPill: showsNowPlayingPill,
                        hasAboveEditorSurface: surface.hasVisibleContent(in: .aboveEditor),
                        showsMessageQueue: showsMessageQueue
                    ) {
                        ExtensionSurfacePanel(
                            surface: surface,
                            placement: .aboveEditor,
                            messageQueue: showsMessageQueue ? messageQueueSurfaceConfiguration : nil,
                            linkContext: extensionSurfaceLinkContext,
                            onOpenURL: openExtensionSurfaceURL,
                            onExpandedEntryChange: handleExtensionDrawerExpansion,
                            collapseRequestID: extensionDrawerCollapseRequestID,
                            showsLeadingStripContent: showsReviewCommentPill || showsNowPlayingPill,
                            leadingStripContent: {
                                HStack(spacing: 8) {
                                    if showsReviewCommentPill {
                                        ReviewCommentStripPill(
                                            count: reviewComments.stagedCount,
                                            isExpanded: reviewCommentDrawerExpanded,
                                            onToggle: toggleReviewCommentDrawer,
                                            onOpenFullScreen: { presentReviewCommentStashSheet() }
                                        )
                                    }
                                    if showsNowPlayingPill {
                                        InAppNowPlayingPill(
                                            audioPlayer: audioPlayer,
                                            accessibilityPrefix: "chat.nowPlaying",
                                            isExpanded: nowPlayingDrawerExpanded,
                                            onExpand: toggleNowPlayingDrawer,
                                            onOpen: { openTimelineReader(.nowPlaying(audioPlayer)) }
                                        )
                                    }
                                }
                            }
                        )
                        .padding(.horizontal, 16)

                        if showsReviewCommentPill, reviewCommentDrawerExpanded {
                            reviewCommentStashDrawer
                                .padding(.horizontal, 16)
                        }

                        if showsNowPlayingPill, nowPlayingDrawerExpanded {
                            InAppNowPlayingDrawer(
                                audioPlayer: audioPlayer,
                                accessibilityPrefix: "chat.nowPlaying",
                                onOpen: { openTimelineReader(.nowPlaying(audioPlayer)) }
                            )
                            .padding(.horizontal, 16)
                        }
                    }
                }

                if let reconnectFailureMessage = actionHandler.reconnectFailureMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.themeRed)
                            .padding(.top, 1)

                        Text(reconnectFailureMessage)
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.themeRed.opacity(0.08))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.themeRed.opacity(0.35), lineWidth: 1)
                    }
                    .padding(.horizontal, 16)
                }

                ForEach(ChatSessionWarningChrome.messages(from: session?.warnings), id: \.self) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.themeYellow)
                            .padding(.top, 1)

                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.themeFg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.themeYellow.opacity(0.08))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.themeYellow.opacity(0.35), lineWidth: 1)
                    }
                    .padding(.horizontal, 16)
                }

                ChatInputBar(
                    text: composerTextBinding,
                    textBeforeRecording: $composerTextBeforeRecording,
                    pendingAttachments: composerPendingAttachmentsBinding,
                    pendingRepoPointers: composerRepoPointersBinding,

                    isBusy: isBusy,
                    busyStreamingBehavior: $busyStreamingBehavior,
                    isSending: composerIsSending,
                    pendingReviewCommentCount: activeReviewCommentRequest == nil ? reviewComments.stagedCount : 0,
                    placeholderOverride: activeReviewCommentRequest == nil ? nil : "Comment…",
                    sendProgressText: attachmentPreparationText ?? actionHandler.sendProgressText,
                    isStopping: isStopping,
                    voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
                    onPrepareVoiceInput: prepareChatVoiceInput,
                    showForceStop: actionHandler.showForceStop,
                    isForceStopInFlight: actionHandler.isForceStopInFlight,
                    askRequest: composerAskRequest,
                    onAskSubmit: handleComposerAskSubmit,
                    onAskIgnoreAll: handleComposerAskIgnoreAll,

                    slashCommands: availableSlashCommands,
                    fileSuggestions: chatState.fileSuggestions,
                    onFileSuggestionQuery: { query in
                        updateFileSuggestions(query: query)
                    },
                    onSend: { sendComposerAction(draftClearance: .afterSuccess) },
                    onStop: stopTurn,
                    onForceStop: {
                        actionHandler.forceStop(
                            connection: connection, reducer: reducer,
                            sessionStore: sessionStore, sessionId: sessionId
                        )
                    },
                    onExpand: presentComposer,
                    externalFocusRequestID: composerExternalFocusRequestID,
                    appliesOuterPadding: true,
                    alwaysShowActionRow: false,
                    allowsExpansion: composerAskRequest == nil,
                    actionRow: {
                        composerActionRow
                    }
                )

                if !hasBlockingExtensionInput,
                   let surface = extensionSurfaceState,
                   surface.hasVisibleContent(in: .belowEditor) {
                    ExtensionSurfacePanel(
                        surface: surface,
                        placement: .belowEditor,
                        linkContext: extensionSurfaceLinkContext,
                        onOpenURL: openExtensionSurfaceURL,
                        onExpandedEntryChange: handleExtensionDrawerExpansion,
                        collapseRequestID: extensionDrawerCollapseRequestID
                    )
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private var composerActionRow: some View {
        if let request = activeReviewCommentRequest {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(QuickCommentTemplate.quickCommentTemplates(quickCommentTemplateStore.templates)) { template in
                            Button {
                                applyQuickCommentTemplate(template)
                            } label: {
                                Label(template.title, systemImage: template.systemImage)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.themeBgHighlight.opacity(0.85), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.themeFg)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    cancelReviewCommentInput()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(.themeBgHighlight.opacity(0.85), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.themeFgDim)
                .accessibilityLabel("Cancel comment")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Comment actions for selected text: \(request.selectedText)")
        } else {
            SessionToolbar(
                session: session,
                thinkingLevel: chatState.thinkingLevel,
                supportedThinkingLevels: ThinkingLevelMenuSource.levels(
                    for: session?.model,
                    in: chatState.cachedModels
                ),
                onModelTap: { showModelPicker = true },
                onThinkingSelect: { level in
                    actionHandler.setThinking(
                        level,
                        connection: connection,
                        reducer: reducer,
                        sessionId: sessionId
                    )
                },
                onSaveThinkingAsDefault: canPersistSessionDefaults ? {
                    actionHandler.setThinking(
                        chatState.thinkingLevel,
                        connection: connection,
                        reducer: reducer,
                        sessionId: sessionId,
                        persist: true
                    )
                } : nil
            )
        }
    }

    private var canPersistSessionDefaults: Bool {
        session?.supportsPersistingDefaults ?? true
    }

    private func toggleChatFilePanel(source: String) {
        AppHaptics.toolbarExpansion()
        let willShow = !isFilePanelVisible
        isFilePanelVisible = willShow
        ClientLog.info("FileBrowser", "Chat files toggle tapped", metadata: [
            "sessionId": sessionId,
            "workspaceId": session?.workspaceId ?? "none",
            "isFilePanelVisible": String(isFilePanelVisible),
            "selectedTab": selectedFilePanelTab.rawValue,
            "source": source,
        ])
        if isFilePanelVisible {
            showOutline = false
            showContextInspector = false
        }
    }

    private func closeChatFilePanel() {
        isFilePanelVisible = false
    }

    private var usesCustomChatBackButton: Bool {
        appNavigation.workspaceNavigationPresentation == .stack
            || appNavigation.workspaceNavigationPresentation == .split
    }

    @ViewBuilder
    private var chatLeadingToolbarItem: some View {
        HStack(spacing: 10) {
            if usesCustomChatBackButton {
                chatBackButton
            }

            chatFilesToolbarItem
        }
        .accessibilityElement(children: .contain)
    }

    private var chatBackButton: some View {
        Button(action: navigateBackFromChat) {
            Image(systemName: "chevron.left")
                .font(.headline.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
        .accessibilityIdentifier("chat.toolbar.back")
    }

    private func navigateBackFromChat() {
        if ownsWorkspacePathBackNavigation,
           appNavigation.workspaceNavigationPresentation == .stack {
            // Let SwiftUI coordinate the pop with its hosting-controller cache.
            // Mutating NavigationPath directly during toolbar layout can force a
            // synchronous NavigationStack reconciliation on the main thread.
            dismiss()
            return
        }
        if appNavigation.workspaceNavigationPresentation == .split {
            if !appNavigation.splitDetailPath.isEmpty {
                dismiss()
                return
            }
            appNavigation.showSessionInboxInSplit()
            return
        }
        dismiss()
    }

    @ViewBuilder
    private var chatFilesToolbarItem: some View {
        if session?.workspaceId != nil {
            Button {
                toggleChatFilePanel(source: "top_leading_pill")
            } label: {
                Image(systemName: isFilePanelVisible ? "folder.fill" : "folder")
                    .font(.subheadline)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFilePanelVisible ? .themeBlue : .themeFg)
            .accessibilityLabel(isFilePanelVisible ? "Close chat files" : "Open chat files")
            .accessibilityIdentifier("chat.toolbar.files")
        }
    }

    @ViewBuilder
    private var chatPrincipalToolbarItem: some View {
        Button {
            renameText = session?.name ?? ""
            showRenameAlert = true
        } label: {
            sessionTitleLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rename session")
        .accessibilityValue(
            assistantIdentityPresentation == .globalAvatar
                ? sessionDisplayName
                : "\(sessionDisplayName), launched with a saved Agent"
        )
        .contextMenu {
            Button("Copy Session ID", systemImage: "doc.on.doc") {
                copySessionID()
            }
            Button("Share Session", systemImage: "square.and.arrow.up") {
                shareSessionFromTitleMenu()
            }
            .disabled(!hasShareSlashCommand)
        }
    }

    @ViewBuilder
    private func chatTrailingToolbarItem(railEdge: HorizontalEdge?) -> some View {
        HStack(spacing: 2) {
            // Do not read `reducer.items` here. Content-only streaming would
            // rebuild ChatView and `updateUIView`. The UIKit clock publishes
            // this boolean on empty/nonempty transitions and session bind.
            if outlineAvailability.isAvailable {
                chatOutlineButton(railEdge: railEdge)
            }

            contextRingButton(railEdge: railEdge)
        }
    }

    private func chatOutlineButton(railEdge: HorizontalEdge?) -> some View {
        let sidePanel = usesTrailingSidePanel(railEdge: railEdge)
        return Button {
            if sidePanel {
                showSidePanel(showOutline ? nil : .outline)
            } else {
                showOutline = true
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.subheadline)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(sidePanel && showOutline ? .themeBlue : .themeFg)
        .accessibilityLabel("Open session outline")
        .accessibilityIdentifier("chat.toolbar.outline")
    }

    private func contextRingButton(railEdge: HorizontalEdge?) -> some View {
        let sidePanel = usesTrailingSidePanel(railEdge: railEdge)
        return Button {
            AppHaptics.toolbarExpansion()
            if sidePanel {
                showSidePanel(showContextInspector ? nil : .context)
            } else {
                showContextInspector = true
            }
        } label: {
            ContextUsageRingBadge(
                usage: contextUsageSnapshot
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.toolbar.context")
        .accessibilityLabel("Open context inspector")
    }

    /// Sized from the chat's own width (the measured timeline column), not the
    /// screen: a split column or a resized window leaves less.
    private var chatPrincipalTitleMaxWidth: CGFloat {
        let reservedChromeWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 220 : 178
        let upperBound: CGFloat = dynamicTypeSize.isAccessibilitySize ? 260 : 320
        return max(132, min(upperBound, timelineChromeFrame.width - reservedChromeWidth))
    }

    private var sessionTitleLabel: some View {
        ChatSessionTitleView(
            sessionId: sessionId,
            sessionDisplayName: sessionDisplayName,
            assistantIdentityPresentation: assistantIdentityPresentation,
            agentIcon: session?.launch?.agentIcon,
            cost: session?.cost,
            terminalMirrorIndicator: TerminalMirrorIndicatorPresentation(session: session),
            maxWidth: chatPrincipalTitleMaxWidth,
            showsDurableLabel: durableSessionsExperimentEnabled && session?.engine == .durable
        )
    }

    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter {
        ReviewCommentSelectionRouter(
            dispatchWithPresentation: { request, presentingViewController in
                handleReviewCommentSelection(request, presentingViewController: presentingViewController)
            },
            inlineSave: { body, request in
                saveReviewComment(body: body, request: request)
            },
            inlineQuickComments: QuickCommentTemplate.quickCommentTemplates(quickCommentTemplateStore.templates),
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
            stash: reviewComments
        )
    }

    // MARK: - Actions

    private func updateFileSuggestions(query: String?) {
        if let query {
            connection.fetchFileSuggestions(query: query)
        } else {
            connection.clearFileSuggestions()
        }
    }

    @MainActor
    private func handleReviewCommentSelection(
        _ request: ReviewCommentSelectionRequest,
        presentingViewController: UIViewController? = nil
    ) {
        activeReviewCommentRequest = request
        composerDraftController.setMode(.reviewComment, resetTransientInput: true)
        composerTextBeforeRecording = nil
        pendingAttachments = []
        composerExternalFocusRequestID &+= 1
        contextBarCollapseToken &+= 1
    }

    private func applyQuickCommentTemplate(_ template: QuickCommentTemplate) {
        let text = template.quickCommentText
        guard !text.isEmpty else { return }
        let trimmed = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            composerDraftController.text = text
        } else if composerDraftController.text.hasSuffix("\n") {
            composerDraftController.text += text
        } else {
            composerDraftController.text += "\n" + text
        }
        composerExternalFocusRequestID &+= 1
    }

    private func cancelReviewCommentInput() {
        activeReviewCommentRequest = nil
        synchronizeComposerMode()
        composerTextBeforeRecording = nil
    }

    private func sendComposerAction(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance = .afterSuccess
    ) {
        if activeReviewCommentRequest != nil {
            sendActiveReviewComment()
        } else {
            sendPrompt(draftClearance: draftClearance)
        }
    }

    private func stopTurn() {
        Task { @MainActor in
            let abort: @MainActor () async -> Void = {
                guard connection.isFocusedSession(sessionId) else { return }
                actionHandler.stop(
                    connection: connection, reducer: reducer, sessionStore: sessionStore,
                    sessionManager: sessionManager, sessionId: sessionId
                )
            }
            // Nothing queued: send a plain Stop. take_queue only exists on newer
            // servers, so requiring it here would leave Stop dead on an older one.
            guard hasQueuedMessages else {
                await abort()
                return
            }
            await MessageQueueComposerRestore.stopAfterRestoring(
                restore: { try await restoreQueuedMessagesToComposer() },
                abort: abort,
                onError: { error in messageQueueError = error.localizedDescription }
            )
        }
    }

    private func restoreQueuedMessagesToComposer() async throws {
        guard connection.isFocusedSession(sessionId) else { return }
        messageQueueError = nil
        let withdrawn = try await connection.takeMessageQueue(sessionIdOverride: sessionId)
        guard let plan = MessageQueueComposerRestore.plan(
            queue: withdrawn,
            currentText: composerDraftController.text,
            currentPendingAttachments: pendingAttachments
        ) else { return }
        composerDraftController.replaceMessage(text: plan.text, pendingAttachments: plan.pendingAttachments)
        pendingAttachments = plan.pendingAttachments
        composerTextBeforeRecording = nil
        if !showComposer { composerExternalFocusRequestID &+= 1 }
    }

    private func sendActiveReviewComment() {
        guard let request = activeReviewCommentRequest else { return }
        let body = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let didSave = saveReviewComment(body: body, request: request)
        if didSave {
            activeReviewCommentRequest = nil
            synchronizeComposerMode()
            composerTextBeforeRecording = nil
            loadReviewCommentsIfPossible()
        }
    }

    private func presentComposer() {
        guard activeComposerAskRequest == nil else { return }
        AppHaptics.toolbarExpansion()
        showComposer = true
    }

    @MainActor
    private func stageWorkspaceReviewInCurrentSession(prompt: String, files: [PendingFileReference]) {
        composerDraftController.mutateMessage { text, repoPointers in
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = prompt
            } else if text.hasSuffix("\n\n") {
                text += prompt
            } else if text.hasSuffix("\n") {
                text += "\n" + prompt
            } else {
                text += "\n\n" + prompt
            }

            for file in files where !repoPointers.contains(where: { $0.id == file.id }) {
                repoPointers.append(file)
            }
        }

        if isStopped {
            showComposer = true
        } else if !showComposer {
            composerExternalFocusRequestID &+= 1
        }
    }

    @MainActor
    private func applyExtensionEditorText(_ text: String) {
        composerDraftController.replaceMessage(text: text)
        if isStopped {
            showComposer = true
        } else if !showComposer {
            composerExternalFocusRequestID &+= 1
        }
    }

    private func loadReviewCommentsIfPossible() {
        reviewComments.load(localScopeId: reviewCommentLocalScopeId, sessionId: sessionId)
    }

    @discardableResult
    private func saveReviewComment(body: String, request: ReviewCommentSelectionRequest) -> Bool {
        if let error = reviewComments.save(
            body: body,
            request: request,
            localScopeId: reviewCommentLocalScopeId,
            sessionId: sessionId
        ) {
            connection.extensionToast = error
            return false
        }
        AppHaptics.success()
        return true
    }

    private func deleteReviewComment(_ comment: ReviewComment) {
        reviewComments.delete(comment)
    }

    private func clearSentReviewComments(ids: [String]) {
        reviewComments.clearSent(ids: ids)
    }

    private var extensionSurfaceLinkContext: ExtensionSurfaceLinkContext {
        ExtensionSurfaceLinkContext(
            serverID: serverIdHint ?? connection.currentServerId ?? sessionStore.activeServerId,
            workspaceID: session?.workspaceId ?? sessionStore.workspaceId(for: sessionId),
            sessionID: sessionId
        )
    }

    @MainActor
    private func openExtensionSurfaceURL(_ url: URL) -> Bool {
        let context = extensionSurfaceLinkContext
        switch ExtensionSurfaceLinkRouting.action(
            for: url,
            serverID: context.serverID,
            workspaceID: context.workspaceID,
            currentSessionId: sessionId
        ) {
        case .pushSession(let link):
            connection.prepareForSessionReentry(link.sessionId, workspaceIdHint: link.workspaceId)
            sessionRouteToOpen = SessionRoute(id: link.sessionId, workspaceId: link.workspaceId)
            return true
        case .ignore:
            return true
        case .resourceReference(let reference):
            NotificationCenter.default.post(name: .resourceReferenceTapped, object: reference)
            return true
        case .webLink(let destination):
            NotificationCenter.default.post(name: .webLinkTapped, object: destination)
            return true
        case .fileLink(let payload):
            NotificationCenter.default.post(name: .fileLinkTapped, object: payload)
            return true
        case .inviteDeepLink(let destination):
            NotificationCenter.default.post(name: .inviteDeepLinkTapped, object: destination)
            return true
        case .unhandled:
            return false
        }
    }

    @MainActor
    private func attachComposerDraftIfPossible() {
        guard let composerDraftStore, let composerDraftKey else { return }
        composerDraftController.attach(
            store: composerDraftStore,
            key: composerDraftKey,
            isEphemeral: composerDraftIsMemoryOnly
        )
        pendingAttachments = composerDraftController.pendingAttachments
        synchronizeComposerMode()
    }

    @MainActor
    private func synchronizeComposerMode() {
        let mode = Self.resolvedComposerMode(
            hasReviewComment: activeReviewCommentRequest != nil,
            hasAskRequest: activeComposerAskRequest != nil
        )
        if mode == .ask {
            showComposer = false
        }
        composerDraftController.setMode(mode)
        if mode == .message {
            pendingAttachments = composerDraftController.pendingAttachments
        } else {
            pendingAttachments = []
        }
    }

    @discardableResult
    private func deliverCanvasToComposer(attachment: PendingAttachment, recognizedText: String) -> Bool {
        Self.deliverCanvasToComposer(
            attachment: attachment,
            recognizedText: recognizedText,
            draftController: composerDraftController,
            pendingAttachments: &pendingAttachments
        )
    }

    @MainActor
    private func handleAppear() {
        // A stack/split shell swap remounts this chat: pick up the reading
        // position the same chat had in the other shell before history lands.
        mountedPresentation = appNavigation.workspaceNavigationPresentation
        ChatScrollShellSwapHandoff.shared.chatDidAppear(
            sessionId: sessionId,
            controller: scrollController,
            presentation: mountedPresentation
        )

        // Re-establish command routing immediately on re-entry.
        // The async sessionManager.connect() task starts shortly after onAppear,
        // but users can tap toolbar controls before that task has a chance to
        // refocus the connection on this session.
        connection.prepareForSessionReentry(
            sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: focusedRouteScope
        )

        sessionManager.markAppeared()
        sessionManager.claimFocusOnAppear(connection: connection, sessionStore: sessionStore)
        if Self.shouldPauseTimelinePresentation(for: scenePhase) {
            sessionManager.coalescer.pause()
        } else if scenePhase == .active,
                  sessionManager.coalescer.resume() {
            sessionManager.reloadTimelineAfterPresentationOverflow(
                connection: connection,
                sessionStore: sessionStore
            )
        }
        voiceInputManager.loadPreferences()
        attachComposerDraftIfPossible()
        // Load initial git status for the workspace
        if let wsId = session?.workspaceId, let api = connection.apiClient {
            let ws = connection.workspaceStore.workspaces.first { $0.id == wsId }
            gitStatusStore.loadInitial(
                workspaceId: wsId,
                worktreeId: session?.worktreeId,
                apiClient: api,
                gitStatusEnabled: ws?.gitStatusEnabled ?? true
            )
        }
        // Pre-load file index for @file fuzzy search
        if let wsId = session?.workspaceId, let api = connection.apiClient {
            fileIndexStore.ensureLoaded(workspaceId: wsId, apiClient: api)
        }
    }

    private var chatDictationServerId: String? {
        if let id = connection.currentServerId, !id.isEmpty { return id }
        if let credentials = connection.credentials {
            return "\(credentials.host):\(credentials.port)"
        }
        return nil
    }

    private func prepareChatVoiceInput(_ manager: VoiceInputManager) async throws {
        ComposerShared.prepareConversationVoiceInput(
            manager: manager,
            serverId: chatDictationServerId,
            sessionId: sessionId,
            credentials: connection.credentials,
            connection: connection,
            playbackInterrupter: audioPlayer,
            workspaceId: session?.workspaceId ?? workspaceIdHint
        )
    }

    private func activateChatVoiceComposer(_ manager: VoiceInputManager) {
        guard let serverId = chatDictationServerId else { return }
        _ = manager.activateConversationComposer(
            serverId: serverId,
            sessionId: sessionId,
            credentials: connection.credentials,
            connection: connection,
            workspaceId: session?.workspaceId ?? workspaceIdHint
        )
        manager.setPlaybackInterrupter(audioPlayer)
    }

    static func shouldPauseTimelinePresentation(for phase: ScenePhase) -> Bool {
        phase == .inactive || phase == .background
    }

    @MainActor
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if Self.shouldPauseTimelinePresentation(for: phase) {
            // The timeline stays mounted while the scene cannot present a
            // frame. Keep transport and shared session status alive, but make
            // timeline publication a hard presentation boundary.
            sessionManager.coalescer.pause()
            return
        }

        guard phase == .active else { return }
        if sessionManager.coalescer.resume() {
            sessionManager.reloadTimelineAfterPresentationOverflow(
                connection: connection,
                sessionStore: sessionStore
            )
        }
    }

#if DEBUG
    @MainActor
    private func seedE2EChatImageAttachmentIfRequested() {
        guard !hasSeededE2EChatImageAttachment else { return }
        guard let rawBase64 = ProcessInfo.processInfo.environment["OPPI_E2E_CHAT_PENDING_IMAGE_BASE64"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBase64.isEmpty else {
            return
        }

        hasSeededE2EChatImageAttachment = true
        let compactBase64 = rawBase64.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compactBase64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else {
            return
        }

        let configuredMimeType = ProcessInfo.processInfo.environment["OPPI_E2E_CHAT_PENDING_IMAGE_MIME_TYPE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let mimeType = configuredMimeType.isEmpty ? "image/png" : configuredMimeType
        let attachment = PendingAttachment(
            id: "e2e-chat-image",
            source: .image,
            displayName: Self.e2eImageDisplayName(mimeType: mimeType),
            thumbnail: image,
            imageAttachment: ImageAttachment(data: compactBase64, mimeType: mimeType),
            localFileData: nil,
            localMimeType: nil
        )
        if !pendingAttachments.contains(where: { $0.id == attachment.id }) {
            pendingAttachments.append(attachment)
            composerDraftController.setPendingAttachments(pendingAttachments)
        }
    }

    private static func e2eImageDisplayName(mimeType: String) -> String {
        switch mimeType.split(separator: ";", maxSplits: 1).first?.lowercased() {
        case "image/jpeg", "image/jpg":
            return "e2e-image.jpg"
        case "image/gif":
            return "e2e-image.gif"
        case "image/webp":
            return "e2e-image.webp"
        default:
            return "e2e-image.png"
        }
    }
#endif

    @MainActor
    private func handleExtensionEditorTextUpdate() {
        guard let update = chatState.extensionEditorTextUpdate,
              update.sessionId == sessionId else {
            return
        }
        applyExtensionEditorText(update.text)
    }

    @MainActor
    private func applyExtensionToolsExpandedState() {
        guard let toolsExpanded = extensionSurfaceState?.toolsExpanded else { return }
        reducer.applyExtensionToolsExpanded(toolsExpanded)
    }

    @MainActor
    private func handleSessionStatusChange(_ newStatus: SessionStatus?) {
        if newStatus != .stopping {
            actionHandler.resetStopState()
            sessionManager.cancelReconciliation()
        }

        let shouldReconnectStoppedSession: Bool
        if let newStatus, newStatus != .stopped,
           case .stopped = sessionManager.entryState {
            shouldReconnectStoppedSession = true
        } else {
            shouldReconnectStoppedSession = false
        }

        if shouldReconnectStoppedSession {
            // A visible session can enter as stopped, then become busy when a
            // external session link resumes the current turn. The stopped entry
            // path intentionally avoided WSS; restart the connect task now so
            // live parent output is subscribed. Queue sync runs after the
            // stream reconnects, so skip the pre-reconnect get_queue request.
            sessionManager.reconnect()
            return
        }

        guard newStatus == .busy else { return }
        Task {
            try? await connection.requestMessageQueue(sessionIdOverride: sessionId)
        }
    }

    @MainActor
    private func handleEntryStateChange(_ newState: ChatSessionManager.SessionEntryState) {
        if newState == .streaming {
            actionHandler.clearReconnectFailure()
        }
    }

    @MainActor
    private var isReadyForQuickSend: Bool {
        guard sessionManager.entryState == .streaming else { return false }
        return connection.wsClient?.status == .connected
    }

    private var composerIsSending: Bool {
        Self.composerSendIsInFlight(
            isPreparingAttachments: isPreparingAttachments,
            actionIsSending: actionHandler.isSending,
            draftSubmissionIsInFlight: composerDraftController.isSubmissionInFlight
        )
    }

    static func composerSendIsInFlight(
        isPreparingAttachments: Bool,
        actionIsSending: Bool,
        draftSubmissionIsInFlight: Bool
    ) -> Bool {
        isPreparingAttachments || actionIsSending || draftSubmissionIsInFlight
    }

    static func beginComposerSubmission(
        draftController: ChatComposerDraftController,
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance,
        isPreparingAttachments: Bool,
        actionIsSending: Bool
    ) -> ChatComposerDraftController.SubmissionSnapshot? {
        guard !composerSendIsInFlight(
            isPreparingAttachments: isPreparingAttachments,
            actionIsSending: actionIsSending,
            draftSubmissionIsInFlight: draftController.isSubmissionInFlight
        ) else { return nil }
        return draftController.beginSubmission(draftClearance: draftClearance)
    }

    enum ComposerPromptSendOutcome {
        case ignored
        case uploaded(
            submission: ChatComposerDraftController.SubmissionSnapshot,
            attachments: [ChatAttachmentRef],
            sourceAttachments: [PendingAttachment]
        )
        case failed(Error)
    }

    /// Production send path for inline and expanded composers. Uploads the
    /// captured submission's Class B draft files, then the caller dispatches.
    @MainActor
    struct ComposerPromptSendState {
        var pendingAttachments: [PendingAttachment]
        var isPreparingAttachments: Bool
    }

    static func sendPrompt(
        draftController: ChatComposerDraftController,
        state: ComposerPromptSendState,
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance,
        actionIsSending: Bool,
        upload: ([PendingAttachment]) async throws -> [ChatAttachmentRef]
    ) async -> (ComposerPromptSendOutcome, ComposerPromptSendState) {
        var state = state
        draftController.setPendingAttachments(state.pendingAttachments)
        guard let submission = beginComposerSubmission(
            draftController: draftController,
            draftClearance: draftClearance,
            isPreparingAttachments: state.isPreparingAttachments,
            actionIsSending: actionIsSending
        ) else {
            return (.ignored, state)
        }
        if draftClearance == .immediately {
            state.pendingAttachments = []
        }

        let sourceAttachments = submission.pendingAttachments
        state.isPreparingAttachments = true
        do {
            let attachments = try await upload(sourceAttachments)
            state.isPreparingAttachments = false
            return (
                .uploaded(
                    submission: submission,
                    attachments: attachments,
                    sourceAttachments: sourceAttachments
                ),
                state
            )
        } catch {
            state.isPreparingAttachments = false
            draftController.failSubmission(submission)
            state.pendingAttachments = draftClearance == .afterSuccess
                ? draftController.pendingAttachments
                : sourceAttachments
            return (.failed(error), state)
        }
    }

    @MainActor
    private func handleAudioPlayerStateChange(_ notification: Notification) {
        guard notification.object as? AudioPlayerService === audioPlayer else { return }
        let playing = notification.userInfo?[AudioPlayerService.playingItemIDUserInfoKey] as? String
        let loading = notification.userInfo?[AudioPlayerService.loadingItemIDUserInfoKey] as? String
        audioLifecycleCoordinator.syncPlaybackState(
            playingItemID: playing?.isEmpty == false ? playing : nil,
            loadingItemID: loading?.isEmpty == false ? loading : nil
        )
    }

    @MainActor
    private func handleContextBarExpandedChanged(_ expanded: Bool) {
        contextBarExpanded = expanded
        guard expanded else { return }

        // Avoid overlap between expanded git context and composer when the
        // software keyboard is visible.
        dismissKeyboard()
    }

    @MainActor
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    @MainActor
    private func dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle() {
        guard composerDraftController.mode == .message,
              composerDraftController.text.isEmpty,
              composerDraftController.repoPointers.isEmpty,
              pendingAttachments.isEmpty,
              composerTextBeforeRecording == nil else {
            return
        }
        dismissKeyboard()
    }

    private func uploadPendingLocalAttachments(
        _ sourceAttachments: [PendingAttachment]
    ) async throws -> [ChatAttachmentRef] {
        guard let api = connection.apiClient else {
            throw APIError.server(status: 503, message: "No server connection available")
        }
        guard let routeScope = focusedRouteScope else {
            throw TreeNavigationError.sessionNotReady
        }
        return try await PendingAttachmentUploader.upload(
            sourceAttachments,
            api: api,
            scope: routeScope,
            sessionId: sessionId,
            onProgress: { attachmentPreparationText = $0 }
        )
    }

    private func uploadPreparationErrorMessage(_ error: Error) -> String {
        if case let APIError.server(status, message) = error {
            if status == 404 {
                return "This server does not support attachment uploads yet."
            }
            return message
        }
        return error.localizedDescription
    }

    private func handleComposerAskSubmit(
        _ ask: AskRequest,
        _ answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {
        guard let payload = ask.responsePayload(from: answers) else {
            connection.extensionToast = "Couldn't prepare this response. Try again."
            completion(.retryableFailure)
            return
        }
        deliverComposerAskResponse(ask, payload: payload, completion: completion)
    }

    private func handleComposerAskIgnoreAll(
        _ ask: AskRequest,
        completion: @escaping AskResponseSubmission.Completion
    ) {
        deliverComposerAskResponse(ask, payload: .cancelled, completion: completion)
    }

    private func deliverComposerAskResponse(
        _ ask: AskRequest,
        payload: ExtensionUIResponsePayload,
        completion: @escaping AskResponseSubmission.Completion
    ) {
        guard activeComposerAskRequest?.id == ask.id else {
            completion(.completed)
            return
        }
        composerDraftController.clearSubmittedAskAnswer()
        Task {
            let result = await Self.deliverAskResponse(
                send: {
                    try await connection.respondToExtensionUI(
                        id: ask.id, sessionId: ask.sessionId, payload: payload
                    )
                },
                reconcile: { await connection.hydrateSessionDialogs(sessionId: ask.sessionId) },
                isPending: { connection.askRequestStore.pending(for: ask.sessionId)?.id == ask.id },
                showFailure: { connection.extensionToast = "Couldn't confirm response: \($0.localizedDescription). Try again." }
            )
            completion(result)
        }
    }

    /// A failed transport can have delivered before its acknowledgement was
    /// lost. Repair the existing dialog projection first. If still pending (or
    /// repair is unavailable), retry the same Ask ID: the server's first-wins
    /// response handling ignores IDs already settled, never answers twice.
    @MainActor
    static func deliverAskResponse(
        send: () async throws -> Void,
        reconcile: () async -> Void,
        isPending: () -> Bool,
        showFailure: (Error) -> Void
    ) async -> AskResponseSubmission.Result {
        do {
            try await send()
            return .completed
        } catch {
            // Do not start a stale request's repair after live settlement or
            // replacement. Hydration also fences store writes during its await.
            guard isPending() else { return .completed }
            await reconcile()
            guard isPending() else { return .completed }
            showFailure(error)
            return .retryableFailure
        }
    }

    private func beginComposerSubmission(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance
    ) -> ChatComposerDraftController.SubmissionSnapshot? {
        Self.beginComposerSubmission(
            draftController: composerDraftController,
            draftClearance: draftClearance,
            isPreparingAttachments: isPreparingAttachments,
            actionIsSending: actionHandler.isSending
        )
    }

    private func completeComposerSubmission(
        _ submission: ChatComposerDraftController.SubmissionSnapshot,
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance
    ) {
        let didClearSubmittedDraft = composerDraftController.completeSubmission(submission)
        if draftClearance == .afterSuccess {
            pendingAttachments = didClearSubmittedDraft
                ? []
                : composerDraftController.pendingAttachments
        }
    }

    private func failComposerSubmission(
        _ submission: ChatComposerDraftController.SubmissionSnapshot,
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance,
        originalPendingAttachments: [PendingAttachment]
    ) {
        composerDraftController.failSubmission(submission)
        pendingAttachments = draftClearance == .afterSuccess
            ? composerDraftController.pendingAttachments
            : originalPendingAttachments
    }

    private func sendPrompt(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance = .afterSuccess
    ) {
        guard !composerIsSending else { return }

        let rawTrimmedInput = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.localSlashCommand(for: rawTrimmedInput) == .compact {
            let originalPendingAttachments = pendingAttachments
            composerDraftController.setPendingAttachments(originalPendingAttachments)
            guard let submission = beginComposerSubmission(draftClearance: draftClearance) else { return }
            if draftClearance == .immediately {
                pendingAttachments = []
            }
            composerTextBeforeRecording = nil
            actionHandler.compact(
                connection: connection,
                reducer: reducer,
                sessionId: sessionId,
                onSendSucceeded: {
                    completeComposerSubmission(submission, draftClearance: draftClearance)
                    dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                },
                onAsyncFailure: {
                    failComposerSubmission(
                        submission,
                        draftClearance: draftClearance,
                        originalPendingAttachments: originalPendingAttachments
                    )
                }
            )
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/reload") == .orderedSame {
            let originalPendingAttachments = pendingAttachments
            composerDraftController.setPendingAttachments(originalPendingAttachments)
            guard let submission = beginComposerSubmission(draftClearance: draftClearance) else { return }
            if draftClearance == .immediately {
                pendingAttachments = []
            }
            composerTextBeforeRecording = nil
            actionHandler.reloadResources(
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId,
                onSendSucceeded: {
                    completeComposerSubmission(submission, draftClearance: draftClearance)
                    dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                },
                onAsyncFailure: {
                    failComposerSubmission(
                        submission,
                        draftClearance: draftClearance,
                        originalPendingAttachments: originalPendingAttachments
                    )
                }
            )
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/share") == .orderedSame {
            sendShareSlashCommand(clearComposer: true, draftClearance: draftClearance)
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/review-comments") == .orderedSame {
            composerDraftController.clearMessage()
            pendingAttachments = []
            composerTextBeforeRecording = nil
            connection.extensionToast = "Review comments use compact inline selection now."
            dismissKeyboard()
            return
        }

        let originalInputText = composerDraftController.text
        let originalPendingRepoPointers = composerDraftController.repoPointers
        let timelineItems = reducer.items
        let reviewText = reviewComments.appendReviewBlock(
            to: originalInputText,
            pathFormatting: reviewCommentPathFormatting,
            currentSourceRevision: { comment in
                SemanticCommentFreshness.currentRevision(for: comment, timelineItems: timelineItems)
            }
        )
        let text = PendingFileReference.appendReferenceBlock(to: reviewText, files: originalPendingRepoPointers)
        let stagedReviewCommentIds = reviewComments.stagedCommentIds
        let sessionManagerRef = sessionManager
        let scrollRef = scrollController

        Task { @MainActor in
            let (outcome, nextState) = await Self.sendPrompt(
                draftController: composerDraftController,
                state: ComposerPromptSendState(
                    pendingAttachments: pendingAttachments,
                    isPreparingAttachments: isPreparingAttachments
                ),
                draftClearance: draftClearance,
                actionIsSending: actionHandler.isSending,
                upload: { sourceAttachments in
                    let pendingLocalAttachments = sourceAttachments.filter {
                        $0.source == .image || $0.source == .localFile
                    }
                    attachmentPreparationText = pendingLocalAttachments.isEmpty ? nil : "Uploading attachments…"
                    return try await self.uploadPendingLocalAttachments(sourceAttachments)
                }
            )
            pendingAttachments = nextState.pendingAttachments
            isPreparingAttachments = nextState.isPreparingAttachments
            attachmentPreparationText = nil
            switch outcome {
            case .ignored:
                return
            case .failed(let error):
                reducer.process(.error(sessionId: sessionId, message: self.uploadPreparationErrorMessage(error)))
            case .uploaded(let submission, let attachments, let sourceAttachments):
                let optimisticDisplayText = UserMessageAttachmentPresentation.makeDisplayText(
                    text: reviewText,
                    pendingAttachments: sourceAttachments,
                    pendingRepoPointers: originalPendingRepoPointers,
                    uploadedAttachments: attachments
                )
                let optimisticImages = sourceAttachments.compactMap(\.imageAttachment)
                let dispatchIsBusy = isBusy
                let sendBehavior = ComposerAutocomplete.streamingBehavior(
                    for: rawTrimmedInput,
                    isBusy: dispatchIsBusy,
                    selected: busyStreamingBehavior,
                    commands: availableSlashCommands
                )
                let restored = actionHandler.sendPrompt(
                    text: text,
                    attachments: attachments,
                    optimisticDisplayText: optimisticDisplayText,
                    optimisticImages: optimisticImages,
                    isBusy: dispatchIsBusy,
                    busyStreamingBehavior: sendBehavior,
                    connection: connection,
                    reducer: reducer,
                    sessionId: sessionId,
                    sessionStore: sessionStore,
                    sessionManager: sessionManager,
                    onDispatchStarted: {
                        // The timeline row or queue item is the send confirmation.
                        // Waiting for ack left this draft in the field while the
                        // agent was already working on it.
                        composerDraftController.clearVisibleTextForDispatchedSubmission(submission)
                        composerTextBeforeRecording = nil
                        if draftClearance == .immediately {
                            pendingAttachments = []
                        }

                        // Scroll after the optimistic row is in the collection.
                        // The draft clear above must not wait for that turn.
                        DispatchQueue.main.async {
                            scrollRef.requestScrollToBottom()
                        }
                    },
                    onSendSucceeded: {
                        completeComposerSubmission(submission, draftClearance: draftClearance)
                        clearSentReviewComments(ids: stagedReviewCommentIds)
                        dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                    },
                    onAsyncFailure: { _, _ in
                        failComposerSubmission(
                            submission,
                            draftClearance: draftClearance,
                            originalPendingAttachments: sourceAttachments
                        )
                    },
                    onNeedsReconnect: {
                        sessionManagerRef.reconnect()
                    }
                )
                if !restored.isEmpty {
                    failComposerSubmission(
                        submission,
                        draftClearance: draftClearance,
                        originalPendingAttachments: sourceAttachments
                    )
                }
            }
        }
    }

    private func handleModelSelection(_ model: ModelInfo) {
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

    private func applyModelSelection(_ model: ModelInfo) {
        AppPreferences.RecentModels.record(ModelSwitchPolicy.fullModelID(for: model))
        actionHandler.setModel(
            model,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: sessionId
        )
    }

    private func copySessionID() {
        UIPasteboard.general.string = sessionId
    }

    private func shareSessionFromTitleMenu() {
        guard hasShareSlashCommand else {
            reducer.process(
                .error(sessionId: sessionId, message: "Share command is not enabled for this workspace.")
            )
            return
        }

        shareRedactionPolicy = AppPreferences.Share.redactionPolicy
        sharePreflightResult = nil
        sharePreflightError = nil
        showShareRedactionSheet = true
    }

    private func sendShareSlashCommand(
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
        let originalPendingAttachments = pendingAttachments
        let submission: ChatComposerDraftController.SubmissionSnapshot?
        if clearComposer {
            composerDraftController.setPendingAttachments(originalPendingAttachments)
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
            onDispatchStarted: {
                guard clearComposer, draftClearance == .immediately else { return }
                pendingAttachments = []
            },
            onSendSucceeded: {
                if let submission {
                    completeComposerSubmission(submission, draftClearance: draftClearance)
                    dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                }
            },
            onAsyncFailure: {
                if let submission {
                    failComposerSubmission(
                        submission,
                        draftClearance: draftClearance,
                        originalPendingAttachments: originalPendingAttachments
                    )
                }
            },
            onNeedsReconnect: {
                sessionManagerRef.reconnect()
            }
        )
    }

    private func scheduleSharePreflight() {
        sharePreflightTask?.cancel()
        isSharePreflightRunning = true
        sharePreflightError = nil

        let policy = shareRedactionPolicy.normalized

        sharePreflightTask = Task { @MainActor in
            defer { isSharePreflightRunning = false }

            do {
                try await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, showShareRedactionSheet else { return }
                let prepared = try await connection.prepareShareSession(redactionPolicy: policy)
                guard !Task.isCancelled else { return }
                sharePreflightResult = prepared
                sharePreflightError = nil
            } catch {
                guard !Task.isCancelled else { return }
                sharePreflightResult = nil
                sharePreflightError = error.localizedDescription
            }
        }
    }

    private func cancelSharePreflight() {
        sharePreflightTask?.cancel()
        sharePreflightTask = nil
        isSharePreflightRunning = false
    }

    private func publishSessionWithCurrentRedactionPolicy() {
        let sessionManagerRef = sessionManager
        let policy = shareRedactionPolicy.normalized

        AppPreferences.Share.setRedactionPolicy(policy)
        cancelSharePreflight()
        showShareRedactionSheet = false

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

    // MARK: - Sheets & Alerts

    private var outlineSheet: some View {
        SessionOutlineView(
            items: reducer.items,
            sessionId: sessionId,
            workspaceId: session?.workspaceId,
            onSelect: { targetID in
                Self.selectOutlineTimelineEntry(
                    targetID,
                    items: reducer.items,
                    scrollController: scrollController
                ) {
                    _ = await sessionManager.loadTracePageAround(
                        entryId: targetID,
                        connection: connection,
                        sessionStore: sessionStore
                    )
                }
            },
            onFork: forkFromMessage,
            onNavigateTreeNode: { request in
                try await navigateFromTree(request)
            },
            loadTree: { filterMode in
                try await connection.getSessionTree(filterMode: filterMode)
            },
            loadOutline: {
                guard let routeScope = focusedRouteScope else {
                    throw TreeNavigationError.sessionNotReady
                }
                return try await connection.getSessionTraceOutline(
                    routeScope: routeScope,
                    sessionId: sessionId
                )
            },
            toolDetails: { reducer.toolDetailsStore.details(for: $0) },
            onClose: { showOutline = false }
        )
    }

    /// Shared by the outline callback and mounted navigation regression tests.
    /// Loading stays in ChatView; the timeline receives only the selected ID.
    static func selectOutlineTimelineEntry(
        _ targetID: String,
        items: [ChatItem],
        scrollController: ChatScrollController,
        loadTarget: @escaping @MainActor () async -> Void
    ) {
        if items.contains(where: { $0.id == targetID }) {
            scrollController.scrollTargetID = targetID
            return
        }
        Task { @MainActor in
            await loadTarget()
            scrollController.scrollTargetID = targetID
        }
    }

    private var filePanelSheet: some View {
        NavigationStack {
            ChatFileBrowserPanel(
                sessionId: sessionId,
                workspaceId: session?.workspaceId,
                changedFiles: session?.changeStats?.changedFiles ?? [],
                selectedTab: $selectedFilePanelTab,
                fileDetailReviewCommentScope: .activeSession(reviewCommentSelectionRouter),
                serverId: serverIdHint ?? connection.currentServerId,
                worktreeId: session?.worktreeId
            )
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { closeChatFilePanel() }
                }
            }
        }
    }

    private func presentReviewCommentStashSheet(editing comment: ReviewComment? = nil) {
        reviewCommentDrawerExpanded = false
        reviewCommentStashPresentation = ReviewCommentStripChrome.StashPresentation(editing: comment)
        dismissKeyboard()
    }

    private func reviewCommentStashSheet(
        _ presentation: ReviewCommentStripChrome.StashPresentation
    ) -> some View {
        let commentsController = reviewComments

        return ReviewCommentStashSheet(
            comments: commentsController.stagedComments,
            focusedCommentId: focusedReviewCommentId,
            initialEditingComment: presentation.initialEditingComment,
            onEdit: { [commentsController] comment, body in
                commentsController.update(comment, body: body) == nil
            },
            onDelete: { comment in
                deleteReviewComment(comment)
            },
            onClose: { reviewCommentStashPresentation = nil }
        )
    }

    private var reviewCommentStashDrawer: some View {
        ReviewCommentStashDrawer(
            comments: reviewComments.stagedComments,
            focusedCommentId: focusedReviewCommentId,
            onEdit: { comment in
                presentReviewCommentStashSheet(editing: comment)
            },
            onDelete: { comment in
                deleteReviewComment(comment)
            }
        )
    }

    private var shareRedactionSheet: some View {
        ShareSessionRedactionSheet(
            policy: $shareRedactionPolicy,
            preflight: sharePreflightResult,
            isAnalyzing: isSharePreflightRunning,
            errorMessage: sharePreflightError,
            isSharing: actionHandler.isSending,
            onRefresh: {
                scheduleSharePreflight()
            },
            onShare: {
                publishSessionWithCurrentRedactionPolicy()
            },
            onCancel: {
                cancelSharePreflight()
                showShareRedactionSheet = false
            }
        )
        .onAppear {
            shareRedactionPolicy = AppPreferences.Share.redactionPolicy
            sharePreflightResult = nil
            sharePreflightError = nil
            scheduleSharePreflight()
        }
        .onDisappear {
            cancelSharePreflight()
        }
        .onChange(of: shareRedactionPolicy) { _, newPolicy in
            let normalized = newPolicy.normalized
            if normalized != shareRedactionPolicy {
                shareRedactionPolicy = normalized
                return
            }
            AppPreferences.Share.setRedactionPolicy(normalized)
            scheduleSharePreflight()
        }
    }

    @MainActor
    private func navigateFromTree(_ request: SessionOutlineView.TreeNavigationRequest) async throws {
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
            showComposer: showComposer
        )

        scrollController.scrollTargetID = viewUpdate.scrollTargetID
        composerDraftController.replaceMessage(
            text: viewUpdate.inputText,
            repoPointers: []
        )
        pendingAttachments = []

        if viewUpdate.shouldFocusComposer {
            composerExternalFocusRequestID &+= 1
        }
    }

    private func forkFromMessage(_ entryId: String) {
        guard let workspaceId = session?.workspaceId, !workspaceId.isEmpty else {
            reducer.process(.error(sessionId: sessionId, message: "Missing workspace context for fork."))
            return
        }

        Task {
            do {
                let forked = try await connection.forkIntoNewSessionFromTimelineEntry(
                    entryId,
                    sourceSessionId: sessionId,
                    workspaceId: workspaceId
                )

                let title = forked.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Session \(forked.id.prefix(8))"
                reducer.appendSystemEvent("Fork created as new session: \(displayName)")

                forkedSessionToOpen = ForkRoute(id: forked.id, workspaceId: forked.workspaceId ?? workspaceId)
            } catch {
                reducer.process(.error(sessionId: sessionId, message: "Fork failed: \(error.localizedDescription)"))
            }
        }
    }

    private var currentWorkspace: Workspace? {
        guard let wsId = session?.workspaceId else { return nil }
        return connection.workspaceStore.workspaces.first { $0.id == wsId }
    }

    private var contextInspectorSheet: some View {
        NavigationStack {
            ContextInspectorView(
                session: session,
                workspace: currentWorkspace,
                loadSessionStats: {
                    try await connection.getSessionStats()
                }
            )
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { showContextInspector = false }
                        .accessibilityIdentifier("chat.context.close")
                }
            }
        }
        .environment(\.reviewCommentSelectionScope, .activeSession(reviewCommentSelectionRouter))
    }

    private var modelPickerSheet: some View {
        ModelPickerSheet(
            currentModel: session?.model,
            onSelect: handleModelSelection,
            onSetDefault: canPersistSessionDefaults ? { model in
                guard let api = connection.apiClient else { throw QuickSessionError.noConnection }
                try await ModelDefaultPersistence.save(
                    model,
                    agentId: session?.launch?.agentId,
                    api: api
                )
                applyModelSelection(model)
                if session?.launch?.agentId == nil, let models = try? await api.listModels() {
                    chatState.cachedModels = models
                }
            } : nil,
            defaultAgentId: session?.launch?.agentId
        )
        .presentationDetents([.medium, .large])
    }

    private var composerSheet: some View {
        ExpandedComposerView(
            text: composerTextBinding,
            textBeforeRecording: $composerTextBeforeRecording,
            pendingAttachments: composerPendingAttachmentsBinding,
            pendingRepoPointers: composerRepoPointersBinding,
            isBusy: isBusy,
            busyStreamingBehavior: busyStreamingBehavior,
            slashCommands: availableSlashCommands,
            fileSuggestions: chatState.fileSuggestions,
            onFileSuggestionQuery: { query in
                updateFileSuggestions(query: query)
            },
            session: session,
            thinkingLevel: chatState.thinkingLevel,
            voiceInputManager: ReleaseFeatures.voiceInputEnabled ? voiceInputManager : nil,
            onPrepareVoiceInput: prepareChatVoiceInput,
            onSend: { sendComposerAction(draftClearance: .afterSuccess) },
            onModelTap: { showModelPicker = true },
            onThinkingSelect: { level in
                actionHandler.setThinking(
                    level,
                    connection: connection,
                    reducer: reducer,
                    sessionId: sessionId
                )
            },
            onSaveThinkingAsDefault: canPersistSessionDefaults ? {
                actionHandler.setThinking(
                    chatState.thinkingLevel,
                    connection: connection,
                    reducer: reducer,
                    sessionId: sessionId,
                    persist: true
                )
            } : nil,
            supportedThinkingLevels: ThinkingLevelMenuSource.levels(
                for: session?.model,
                in: chatState.cachedModels
            ),
            isSubmitInFlight: composerIsSending,
            preservesVoiceInputOnDismiss: true
        )
    }

    @ViewBuilder
    private var renameAlert: some View {
        TextField("Session name", text: $renameText)
        Button("Rename") {
            actionHandler.rename(
                renameText,
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId
            )
        }
        Button("Cancel", role: .cancel) {}
    }
}

struct ChatSessionTitleView: View {
    let sessionId: String
    let sessionDisplayName: String
    let assistantIdentityPresentation: AssistantIdentityPresentation
    let agentIcon: IconChoice?
    let cost: Double?
    let terminalMirrorIndicator: TerminalMirrorIndicatorPresentation?
    let maxWidth: CGFloat
    /// Durable Sessions experiment: marks a durable-engine session.
    var showsDurableLabel = false
    var iconIsDecorative = true
    var iconAccessibilityIdentifier: String?

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                switch assistantIdentityPresentation {
                case .agent:
                    agentIconView()
                case .globalAvatar:
                    PiAvatarView(size: 20)
                }

                Text(sessionDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let cost, cost > 0 {
                    Text(SessionFormatting.costString(cost))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.themeComment)
                        .fixedSize()
                }

                if let terminalMirrorIndicator {
                    TerminalMirrorIndicatorView(presentation: terminalMirrorIndicator)
                }

                if showsDurableLabel {
                    Text("Durable")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .fixedSize()
                        .accessibilityIdentifier("chat.title.durable")
                }
            }
        }
        .frame(maxWidth: maxWidth)
        .clipped()
    }

    @ViewBuilder
    private func agentIconView() -> some View {
        let icon = AgentIconView(
            value: agentIcon,
            size: AgentIconSizingPolicy.titleTextMinimum,
            isDecorative: iconIsDecorative,
            renderStyle: .chatTitle
        )

        if let iconAccessibilityIdentifier {
            icon
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier(iconAccessibilityIdentifier)
        } else {
            icon
        }
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func chatRailKeepsVisible() -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}

private extension View {
    func chatAuxiliaryPresentation<PresentedContent: View>(
        isPresented: Binding<Bool>,
        prefersFullScreen: Bool,
        @ViewBuilder content: @escaping () -> PresentedContent
    ) -> some View {
        // Both presenters stay attached so a size-class change (rotation, a
        // fold, iPad multitasking) moves the panel instead of swapping this
        // view's identity, which would rebuild the chat timeline underneath.
        sheet(isPresented: prefersFullScreen ? .constant(false) : isPresented) {
            content()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: prefersFullScreen ? isPresented : .constant(false), content: content)
    }
}
