import SwiftUI
import UIKit

// The chat's Git and Files panels, the screens they present, and the pages
// the UIKit Files panel pushes (`SessionFilePages`). UIKit owns the screen
// (`ChatViewController`) and its footer, title, and jump hint
// (`ChatFooterViews`).

extension AppScenePhase {
    var isActive: Bool { phase == .active }
    /// The scene cannot present a frame: timeline publication pauses.
    var pausesTimelinePresentation: Bool {
        ChatViewController.shouldPauseTimelinePresentation(for: phase)
    }
}

extension ChatViewController {
    static func shouldPauseTimelinePresentation(for phase: ScenePhase) -> Bool {
        phase == .inactive || phase == .background
    }

    /// The Git panel (UIKit), as a sheet or in the trailing column: the
    /// workspace context bar, always expanded, on this chat's server and
    /// navigation. A review staged for this session, or a comment started in a
    /// file review, closes the panel so it reaches the composer; a session
    /// started from it closes the panel and pushes onto this chat's stack.
    func gitPanelScreen() -> RouterScreen {
        .controller({ [weak self] in
            guard let self else { preconditionFailure("The Git panel presents only while its chat is alive") }
            let closePanel: () -> Void = { [weak self] in self?.model.showGit = false }
            return GitPanelViewController(
                context: { [weak self] in self?.gitPanelContext },
                options: .init(
                    showCleanWorkspace: true,
                    initiallyExpanded: true,
                    isPanel: true,
                    onReviewInCurrentSession: { [weak self] prompt, files in
                        closePanel()
                        self?.stageWorkspaceReviewInCurrentSession(prompt: prompt, files: files)
                    },
                    fileDetailReviewCommentScope: SessionFilePages.closingPanelScope(
                        .activeSession(self.reviewCommentSelectionRouter),
                        closePanel: closePanel
                    ),
                    // A session started from the panel opens on this chat's
                    // stack, not inside the sheet or column.
                    pushChat: { [weak self] chat in
                        guard let self else { return }
                        closePanel()
                        Router.push(chat, from: self)
                    }
                ),
                connection: self.connection,
                apiClient: self.apiClient,
                navigation: self.appNavigation,
                onClose: closePanel
            )
        })
    }

    /// The Git panel's status and session, read in its `updateProperties()`,
    /// so it follows the Git status store and the session.
    var gitPanelContext: WorkspaceContextBarView.Context {
        let session = session
        let store = connection.gitStatusStore
        let loaded = loadedGitStatus
        return WorkspaceContextBarView.Context(
            gitStatus: loaded,
            // Another checkout's status in the store (another workspace, or
            // another worktree of this one) means this chat's is on its way
            // (the chat loads it when it appears), not missing.
            isLoading: loaded == nil && (store.isLoading || !tracksOwnGitStatus),
            workspaceId: session?.workspaceId,
            sessionId: sessionId,
            worktreeId: session?.worktreeId,
            serverId: serverIdHint ?? connection.currentServerId
        )
    }

    /// Whether this chat's workspace may be a Git repository, so the bar offers
    /// Git (`ChatBarItems.mayOfferGit`), from the status loaded for this
    /// workspace only.
    var mayHaveGit: Bool {
        guard let workspaceId = session?.workspaceId else { return false }
        let workspace = connection.workspaceStore.workspaces.first { $0.id == workspaceId }
        return ChatBarItems.mayOfferGit(gitStatusEnabled: workspace?.gitStatusEnabled, loadedStatus: loadedGitStatus)
    }

    /// The Git status of this chat's workspace and worktree, or nil while the
    /// shared store holds another checkout's (`GitStatusStore.status`). The
    /// bar's availability, badge, accessibility value, menu glance, and the
    /// Git panel all read this one.
    var loadedGitStatus: GitStatus? {
        guard let workspaceId = session?.workspaceId else { return nil }
        return connection.gitStatusStore.status(workspaceId: workspaceId, worktreeId: session?.worktreeId)
    }

    /// Whether the shared store is tracking this chat's checkout yet.
    private var tracksOwnGitStatus: Bool {
        guard let workspaceId = session?.workspaceId else { return false }
        return connection.gitStatusStore.tracks(workspaceId: workspaceId, worktreeId: session?.worktreeId)
    }

    /// What the Git button says at a glance: the branch, and how many changed
    /// files the panel lists when it opens (the session's own in the main
    /// checkout, every change in the session's worktree). Nil outside Git.
    var gitBarSummary: (branch: String?, changedFiles: Int)? {
        gitGlance.map { ($0.status.branch, $0.changedFiles) }
    }

    /// The Git item's details in the menu, after its label: the changed-file
    /// count the button shows, the lines those files changed, and the commits
    /// the branch is ahead of and behind its upstream. Nil outside Git.
    var gitMenuDetail: String? {
        guard let glance = gitGlance else { return nil }
        return ChatBarItems.gitMenuDetail(
            changedFiles: glance.changedFiles,
            added: glance.added,
            removed: glance.removed,
            ahead: glance.status.ahead,
            behind: glance.status.behind
        )
    }

    /// The Git status and the counts the panel opens with, scoped the way the
    /// panel scopes them (`ContextBarScoping`, This session).
    private var gitGlance: (status: GitStatus, changedFiles: Int, added: Int, removed: Int)? {
        guard let gitStatus = loadedGitStatus, gitStatus.isGitRepo else { return nil }
        let session = session
        let filters = ContextBarScoping.filtersToSession(
            sessionId: sessionId,
            worktreeId: session?.worktreeId,
            fileScope: .session
        )
        let scope = filters
            ? ContextBarScoping.sessionScope(gitStatus: gitStatus, changedFiles: session?.changeStats?.changedFiles)
            : nil
        return (
            gitStatus,
            ContextBarScoping.displayFileCount(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope),
            ContextBarScoping.displayAddedLines(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope),
            ContextBarScoping.displayRemovedLines(gitStatus: gitStatus, filtersToSession: filters, sessionScope: scope)
        )
    }

    /// The Files panel (UIKit), as a sheet or in the trailing column. It
    /// reads this chat's session, server stores, and tab live; once the chat
    /// is gone it shows what it last read.
    func filePanelScreen() -> RouterScreen {
        .controller({ [weak self] in
            guard let self, let root = self.root else {
                preconditionFailure("The Files panel presents only while its chat is alive")
            }
            return ChatFilePanelViewController(
                root: root,
                inputs: { [weak self] in self?.filePanelInputs },
                tab: { [weak self] in self?.model.selectedFilePanelTab ?? .changed },
                setTab: { [weak self] tab in
                    guard let self else { return }
                    self.model.selectedFilePanelTab = tab
                    ChatFileBrowserPanelTabStore.shared.setTab(tab, for: self.sessionId)
                },
                onClose: { [weak self] in self?.closeChatFilePanel() }
            )
        })
    }

    /// The Files panel's values: the session's files and checkout, this
    /// chat's server stores, and its review-comment scope.
    private var filePanelInputs: ChatFilePanelInputs {
        let session = session
        return ChatFilePanelInputs(
            sessionId: sessionId,
            workspaceId: session?.workspaceId,
            changedFiles: session?.changeStats?.changedFiles ?? [],
            serverId: serverIdHint ?? connection.currentServerId,
            worktreeId: session?.worktreeId,
            reviewCommentSelectionScope: .activeSession(reviewCommentSelectionRouter),
            connection: connection,
            apiClient: apiClient,
            fileIndexStore: connection.fileIndexStore,
            gitStatusStore: connection.gitStatusStore,
            navigation: appNavigation,
            closePanel: { [weak self] in self?.closeChatFilePanel() }
        )
    }

    func reviewCommentStashScreen(_ presentation: ReviewCommentStripChrome.StashPresentation) -> RouterScreen {
        let comments = reviewComments
        return .controller({
            ReviewCommentStashViewController(
                stash: comments,
                editing: presentation.initialEditingComment,
                onClose: { [weak self] in self?.model.reviewCommentStashPresentation = nil }
            )
        })
    }

    /// Share with redaction review. The sheet reads `shareReview` itself, so
    /// the preview updates while it is up.
    func shareRedactionScreen() -> RouterScreen {
        .controller({ [weak self] in
            guard let self else { preconditionFailure("Share presents only while its chat is alive") }
            return ShareSessionRedactionViewController(
                review: self.shareReview,
                isSharing: { [weak self] in self?.actionHandler.isSending ?? false },
                onRefresh: { [weak self] in self?.scheduleSharePreflight() },
                onShare: { [weak self] in self?.publishSessionWithCurrentRedactionPolicy() },
                onCancel: { [weak self] in
                    self?.cancelSharePreflight()
                    self?.model.showShareRedactionSheet = false
                }
            )
        })
    }

    /// The session title's widest size, from the chat's own width (the
    /// timeline column), not the screen: a split column or a resized window
    /// leaves less.
    func updateTitleMaxWidth() {
        let accessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let reservedChromeWidth: CGFloat = accessibilitySize ? 220 : 178
        let upperBound: CGFloat = accessibilitySize ? 260 : 320
        let next = max(132, min(upperBound, timelineWidth - reservedChromeWidth))
        if model.titleMaxWidth != next { model.titleMaxWidth = next }
    }

    var conversationTitleSubtitle: String? {
        guard timelineChromeStyle == .conversation, let model = session?.model else { return nil }
        return "\(shortModelName(model)) \u{00B7} \(chatState.thinkingLevel.compactTitle)"
    }
}

// MARK: - Composer source

extension ChatViewController: ChatComposerSource {
    private var composerTheme: (colors: ComposerThemeColors, theme: AppTheme) {
        let themeStore = root?.themeStore
        let themeID = themeStore?.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        return (ComposerThemeColors(palette: themeID.palette), themeStore?.appTheme ?? themeID.appTheme)
    }

    var composerContent: ComposerBarContent {
        let (colors, theme) = composerTheme
        let reviewing = model.activeReviewCommentRequest != nil
        let ask = composerAskRequest
        return ComposerBarContent(
            text: composerDraftController.text,
            textBeforeRecording: model.composerTextBeforeRecording,
            pendingAttachments: composerVisibleAttachments,
            pendingRepoPointers: composerDraftController.repoPointers,
            isBusy: isBusy,
            busyStreamingBehavior: model.busyStreamingBehavior,
            isSending: composerIsSending,
            pendingReviewCommentCount: reviewing ? 0 : reviewComments.stagedCount,
            placeholderOverride: reviewing ? "Comment…" : nil,
            allowsEmptySubmit: false,
            sendProgressText: model.attachmentPreparationText ?? actionHandler.sendProgressText,
            isStopping: isStopping,
            // A call owns the microphone; the composer offers neither dictation nor a second call.
            voiceInputManager: liveVoiceCallOwnsMic ? nil : voiceInputManager,
            onLiveVoiceSelected: liveVoiceEntry,
            // The input bar is the call surface while a call holds the composer.
            liveVoiceCall: liveVoiceController.composerCall,
            showForceStop: actionHandler.showForceStop,
            isForceStopInFlight: actionHandler.isForceStopInFlight,
            askRequest: ask,
            slashCommands: availableSlashCommands,
            fileSuggestions: chatState.fileSuggestions,
            appliesOuterPadding: true,
            alwaysShowActionRow: false,
            allowsExpansion: ask == nil,
            allowsAttachments: true,
            attachmentButtonPlacement: .leading,
            actionRowMinimumHeight: 0,
            showsAccessoryRow: true,
            autocorrectionEnabled: true,
            inputAccessibilityIdentifier: "chat.input",
            sendAccessibilityIdentifier: "chat.send",
            actionRow: composerActionRow(colors: colors, theme: theme),
            colors: colors,
            reduceMotion: UIAccessibility.isReduceMotionEnabled,
            suppressKeyboard: false,
            focusRequestID: 0,
            keyboardLanguage: nil,
            keyStripHeight: 0,
            mediaImportEpoch: 0
        )
    }

    private func composerActionRow(colors: ComposerThemeColors, theme: AppTheme) -> ComposerActionRow {
        if model.activeReviewCommentRequest != nil {
            let templates = QuickCommentTemplate.quickCommentTemplates(root?.quickCommentTemplateStore.templates ?? [])
            return ComposerActionRow(
                leading: templates.map { template in
                    .reviewChip(
                        id: "chat.reviewComment.\(template.id.uuidString)",
                        title: template.title,
                        systemImage: template.systemImage,
                        onTap: { [weak self] in self?.applyQuickCommentTemplate(template) }
                    )
                },
                trailing: [.reviewCancel { [weak self] in self?.cancelReviewCommentInput() }],
                leadingScrolls: true
            )
        }
        return .sessionToolbar(
            modelTitle: session?.model.map(shortModelName) ?? "Model",
            modelProvider: session?.model.flatMap(providerFromModel),
            thinkingLevel: chatState.thinkingLevel,
            thinkingTint: UIColor(theme.thinking.color(for: chatState.thinkingLevel)),
            supportedThinkingLevels: ThinkingLevelMenuSource.levels(
                for: session?.model,
                in: chatState.cachedModels
            ),
            colors: colors,
            onModelTap: { [weak self] in self?.model.showModelPicker = true },
            onThinkingSelect: { [weak self] level in self?.setThinking(level) },
            onSaveThinkingAsDefault: canPersistSessionDefaults ? { [weak self] in
                self?.saveThinkingAsDefault()
            } : nil
        )
    }

    var composerDraftStore: ComposerDraftStore? { root?.composerDraftStore }
    var composerMediaImportGate: ComposerMediaImportGate? { composerDraftController.mediaImportGate }

    func composerSetText(_ text: String) { setComposerText(text) }
    func composerSetTextBeforeRecording(_ value: String?) { model.composerTextBeforeRecording = value }
    func composerSetPendingAttachments(_ value: [PendingAttachment]) { setComposerPendingAttachments(value) }
    func composerSetPendingRepoPointers(_ value: [PendingFileReference]) {
        composerDraftController.repoPointers = value
    }
    func composerSetBusyStreamingBehavior(_ value: StreamingBehavior) { model.busyStreamingBehavior = value }

    func composerSend() { sendComposerAction(draftClearance: .afterSuccess) }
    func composerStop() { stopTurn() }
    func composerForceStop() { forceStopTurn() }
    func composerExpand() { presentComposer() }

    func composerSubmitAsk(
        _ request: AskRequest,
        answers: [String: AskAnswer],
        completion: @escaping AskResponseSubmission.Completion
    ) {
        handleComposerAskSubmit(request, answers, completion: completion)
    }

    func composerIgnoreAsk(_ request: AskRequest, completion: @escaping AskResponseSubmission.Completion) {
        handleComposerAskIgnoreAll(request, completion: completion)
    }

    func composerFileSuggestionQuery(_ query: String?) { updateFileSuggestions(query: query) }

    func composerPrepareVoiceInput(_ manager: VoiceInputManager) async throws {
        try await prepareChatVoiceInput(manager)
    }

    var isComposerExpanded: Bool { model.showComposer }
    func composerExpandedDidClose() { model.showComposer = false }

    func makeExpandedComposer() -> ExpandedComposerViewController {
        let configuration = ExpandedComposerConfiguration(
            voiceInputManager: liveVoiceCallOwnsMic ? nil : voiceInputManager,
            onPrepareVoiceInput: { [weak self] in try await self?.prepareChatVoiceInput($0) },
            onLiveVoiceSelected: liveVoiceEntry,
            onSend: { [weak self] in self?.sendComposerAction(draftClearance: .afterSuccess) },
            onModelTap: { [weak self] in self?.model.showModelPicker = true },
            onThinkingSelect: { [weak self] level in self?.setThinking(level) },
            onSaveThinkingAsDefault: canPersistSessionDefaults ? { [weak self] in
                self?.saveThinkingAsDefault()
            } : nil,
            onFileSuggestionQuery: { [weak self] query in self?.updateFileSuggestions(query: query) },
            onTextChange: { [weak self] in self?.setComposerText($0) },
            onTextBeforeRecordingChange: { [weak self] in self?.model.composerTextBeforeRecording = $0 },
            onAttachmentsChange: { [weak self] in self?.setComposerPendingAttachments($0) },
            onRepoPointersChange: { [weak self] in self?.composerDraftController.repoPointers = $0 },
            composerDraftStore: root?.composerDraftStore,
            mediaImportGate: composerDraftController.mediaImportGate,
            preservesVoiceInputOnDismiss: true
        )
        return ExpandedComposerViewController(configuration: configuration, live: expandedComposerLiveState)
    }

    /// The chat's current draft and session values for the open expanded composer.
    var expandedComposerLiveState: ExpandedComposerLiveState {
        let (colors, theme) = composerTheme
        return ExpandedComposerLiveState(
            text: composerDraftController.text,
            textBeforeRecording: model.composerTextBeforeRecording,
            pendingAttachments: composerVisibleAttachments,
            pendingRepoPointers: composerDraftController.repoPointers,
            isBusy: isBusy,
            busyStreamingBehavior: model.busyStreamingBehavior,
            slashCommands: availableSlashCommands,
            fileSuggestions: chatState.fileSuggestions,
            session: session,
            thinkingLevel: chatState.thinkingLevel,
            supportedThinkingLevels: ThinkingLevelMenuSource.levels(
                for: session?.model,
                in: chatState.cachedModels
            ),
            isSubmitInFlight: composerIsSending,
            colors: colors,
            thinkingTint: UIColor(theme.thinking.color(for: chatState.thinkingLevel))
        )
    }
}

/// The pages the Files panel's Changed tab pushes: a Git change's review,
/// or the current bytes of a file the session touched. Each runs in its own
/// screen, so the panel's server, API client, and navigation go on
/// explicitly.
@MainActor
enum SessionFilePages {
    static func reviewDetail(
        workspaceId: String,
        sessionId: String,
        file: WorkspaceReviewFile,
        worktreeId: String?,
        serverId: String?,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?,
        navigationFiles: [WorkspaceReviewFile]
    ) -> WorkspaceReviewFileDetailViewController.Configuration {
        WorkspaceReviewFileDetailViewController.Configuration(
            workspaceId: workspaceId,
            selectedSessionId: sessionId,
            file: file,
            worktreeId: worktreeId,
            serverId: serverId,
            reviewCommentSelectionScope: reviewCommentSelectionScope,
            navigationFiles: navigationFiles,
            showsFileListInspector: false
        )
    }

    /// Pushes the review with the chat's server, API client, and navigation.
    static func pushReview(
        _ configuration: WorkspaceReviewFileDetailViewController.Configuration,
        inputs: ChatFilePanelInputs,
        navigator: ScreenNavigator
    ) {
        navigator.push(WorkspaceReviewFileDetailViewController(
            configuration: configuration,
            connection: inputs.connection,
            apiClient: inputs.apiClient,
            navigation: inputs.navigation
        ))
    }

    static func pushSessionTouchedFile(
        workspaceId: String,
        sessionId: String,
        path: String,
        navigationContext: FileBrowserNavigationContext,
        reviewCommentSelectionScope: ReviewCommentSelectionScope?,
        inputs: ChatFilePanelInputs,
        navigator: ScreenNavigator
    ) {
        let connection = inputs.connection
        let store = connection.workspaceStore
        let workspace = store.activeServerId
            .flatMap { store.workspacesByServer[$0]?.first { $0.id == workspaceId } }
            ?? store.workspaces.first { $0.id == workspaceId }
        let configuration = FileViewerViewController.Configuration(
            workspaceId: workspaceId,
            serverId: inputs.serverId,
            filePath: path,
            fileName: path.lastPathComponentForDisplay,
            source: .sessionTouched(SessionTouchedFileOrigin(
                sessionId: sessionId,
                workspaceRuntime: workspace?.runtime,
                hostMount: workspace?.hostMount
            )),
            sessionId: sessionId,
            workspaceRuntime: workspace?.runtime,
            navigationContext: navigationContext,
            reviewCommentSelectionScope: reviewCommentSelectionScope
        )
        navigator.push(FileViewerViewController(
            configuration: configuration,
            services: .init(
                apiClient: inputs.apiClient,
                audioPlayer: connection.audioPlayer,
                sessionStore: connection.sessionStore
            )
        ))
    }

    /// A comment started on a pushed file closes the panel first, so it
    /// reaches the chat's composer.
    static func closingPanelScope(
        _ scope: ReviewCommentSelectionScope?,
        closePanel: @escaping () -> Void
    ) -> ReviewCommentSelectionScope? {
        guard case .activeSession(let router) = scope else { return scope }
        return .activeSession(router.retargetingDispatch { request in
            closePanel()
            router.dispatch(request)
        })
    }
}
