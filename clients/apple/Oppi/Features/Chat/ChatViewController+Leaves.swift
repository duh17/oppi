import SwiftUI
import UIKit

// The chat's leaf content: the context bar (UIKit), the footer rows around
// the composer, the jump-to-bottom hint, the session title, the SwiftUI
// panels it presents (review comments, Share), and the pages
// the UIKit Files panel pushes (`SessionFilePages`). UIKit owns the screen
// (`ChatViewController`); these are hosted with `HostFactory.leaf`,
// `HostFactory.content`, or `RouterScreen.hosted`, with the chat's
// presenter-local values applied explicitly (`leafScope`).

/// The chat, held weakly by its hosted leaves: the controller owns them.
struct ChatLeafContext {
    weak var chat: ChatViewController?
}

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

    /// Presenter-local values for the chat's leaves and modals. They run with
    /// the app root services, so this chat's server, API client, reducer
    /// stores, navigation, and composer media gate go on explicitly.
    func leafScope<Content: View>(_ content: Content) -> some View {
        content
            .withServerScopedEnvironment(connection)
            .environment(\.apiClient, apiClient)
            .environment(sessionManager.reducer)
            .environment(sessionManager.reducer.toolOutputStore)
            .environment(sessionManager.reducer.toolArgsStore)
            .environment(appNavigation)
            .environment(\.composerMediaImportGate, composerDraftController.mediaImportGate)
            .environment(\.openChatReader, ChatReaderOpenAction { [weak self] payload in
                self?.openTimelineReader(payload)
            })
    }

    /// A leaf in the chat's own screen pushes and presents through the
    /// chat's navigator.
    private func hostedLeaf<Content: View>(_ content: Content, root: AppRootEnvironment) -> HostedLeaf {
        HostFactory.leaf(
            leafScope(content).environment(\.screenNavigator, leafNavigator ?? .unattached),
            root: root
        )
    }

    /// The workspace context bar over the top of the timeline, below the bar.
    /// Its reviews present from this chat, on its server and navigation.
    func makeContextBar() -> WorkspaceContextBarView {
        let bar = WorkspaceContextBarView(
            context: contextBarContext,
            options: .init(
                onReviewInCurrentSession: { [weak self] prompt, files in
                    self?.stageWorkspaceReviewInCurrentSession(prompt: prompt, files: files)
                },
                fileDetailReviewCommentScope: .activeSession(reviewCommentSelectionRouter)
            ),
            connection: connection,
            apiClient: apiClient,
            navigation: appNavigation
        )
        bar.presenter = self
        bar.onExpandedChanged = { [weak self] in self?.handleContextBarExpandedChanged($0) }
        return bar
    }

    /// The context bar's Git status and session. Read in `updateProperties()`,
    /// so the bar follows the Git status store and the session.
    var contextBarContext: WorkspaceContextBarView.Context {
        let session = session
        return WorkspaceContextBarView.Context(
            gitStatus: connection.gitStatusStore.gitStatus,
            isLoading: connection.gitStatusStore.isLoading,
            workspaceId: session?.workspaceId,
            sessionId: sessionId,
            worktreeId: session?.worktreeId,
            serverId: serverIdHint ?? connection.currentServerId,
            collapseToken: model.contextBarCollapseToken
        )
    }

    func makeFooterAboveLeaf(root: AppRootEnvironment) -> HostedLeaf {
        hostedLeaf(ChatFooterAboveLeaf(context: ChatLeafContext(chat: self)), root: root)
    }

    func makeFooterBelowLeaf(root: AppRootEnvironment) -> HostedLeaf {
        hostedLeaf(ChatFooterBelowLeaf(context: ChatLeafContext(chat: self)), root: root)
    }

    func makeStoppedFooterLeaf(root: AppRootEnvironment) -> HostedLeaf {
        hostedLeaf(ChatStoppedFooterLeaf(context: ChatLeafContext(chat: self)), root: root)
    }

    func makeJumpToBottomLeaf(root: AppRootEnvironment) -> HostedLeaf {
        hostedLeaf(ChatJumpToBottomLeaf(context: ChatLeafContext(chat: self)), root: root)
    }

    /// The bar's session title; the controller installs its view in
    /// `ChatTitleControl`, which owns the tap and the menu.
    func makeTitleHost(root: AppRootEnvironment) -> HostedContentController {
        let host = HostFactory.content(ChatTitleLeaf(context: ChatLeafContext(chat: self)), root: root)
        host.sizingOptions = .intrinsicContentSize
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        return host
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
        .hosted { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            let commentsController = self.reviewComments
            return AnyView(self.leafScope(ReviewCommentStashContent(
                comments: commentsController.stagedComments,
                focusedCommentId: nil,
                onEdit: { [commentsController] comment, body in
                    commentsController.update(comment, body: body) == nil
                },
                onDelete: { [weak self] comment in
                    self?.deleteReviewComment(comment)
                },
                onClose: { [weak self] in self?.model.reviewCommentStashPresentation = nil },
                initialEditingComment: presentation.initialEditingComment
            )))
        }
    }

    /// Reads `shareReview` in the sheet's own graph, so the preview updates
    /// while the sheet is up.
    func shareRedactionScreen() -> RouterScreen {
        .hosted { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(self.leafScope(ChatShareRedactionLeaf(context: ChatLeafContext(chat: self))))
        }
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

// MARK: - Leaves

/// The rows above the composer: the extension strip with the review-comment
/// and now-playing pills, their drawers, the reconnect failure, and session
/// warnings. Each row is 8 pt from the next, and from the composer.
private struct ChatFooterAboveLeaf: View {
    let context: ChatLeafContext

    var body: some View {
        if let chat = context.chat, !chat.isStopped {
            content(chat)
        }
    }

    @ViewBuilder
    private func content(_ chat: ChatViewController) -> some View {
        let surface = chat.extensionSurfaceState
        let showsReviewCommentPill = chat.showsReviewCommentPill
        let showsNowPlayingPill = chat.showsNowPlayingPill
        let showsMessageQueue = chat.showsMessageQueue
        let showsNotifyChip = chat.showsNotifyChip
        let showsStrip = !chat.hasBlockingExtensionInput && ReviewCommentStripChrome.shouldShowAboveEditorStrip(
            showsReviewCommentPill: showsReviewCommentPill,
            showsNowPlayingPill: showsNowPlayingPill,
            hasAboveEditorSurface: surface.hasVisibleContent(in: .aboveEditor),
            showsMessageQueue: showsMessageQueue,
            showsNotifyChip: showsNotifyChip
        )
        let reconnectFailure = chat.actionHandler.reconnectFailureMessage
        let warnings = ChatSessionWarningChrome.messages(from: chat.session?.warnings)
        let audioPlayer = chat.audioPlayer
        if showsStrip || reconnectFailure != nil || !warnings.isEmpty {
            VStack(spacing: 8) {
                if showsStrip {
                    ExtensionSurfacePanel(
                        surface: surface,
                        placement: .aboveEditor,
                        messageQueue: showsMessageQueue ? chat.messageQueueSurfaceConfiguration : nil,
                        linkContext: chat.extensionSurfaceLinkContext,
                        onOpenURL: { [weak chat] in chat?.openExtensionSurfaceURL($0) ?? false },
                        onExpandedEntryChange: { [weak chat] in chat?.handleExtensionDrawerExpansion($0) },
                        collapseRequestID: chat.model.extensionDrawerCollapseRequestID,
                        showsLeadingStripContent: showsReviewCommentPill || showsNowPlayingPill,
                        showsTrailingStripContent: showsNotifyChip,
                        leadingStripContent: {
                            HStack(spacing: 8) {
                                if showsReviewCommentPill {
                                    ReviewCommentStripPill(
                                        count: chat.reviewComments.stagedCount,
                                        isExpanded: chat.model.reviewCommentDrawerExpanded,
                                        onToggle: { [weak chat] in chat?.toggleReviewCommentDrawer() },
                                        onOpenFullScreen: { [weak chat] in chat?.presentReviewCommentStashSheet() }
                                    )
                                }
                                if showsNowPlayingPill {
                                    InAppNowPlayingPill(
                                        audioPlayer: audioPlayer,
                                        accessibilityPrefix: "chat.nowPlaying",
                                        isExpanded: chat.model.nowPlayingDrawerExpanded,
                                        onExpand: { [weak chat] in chat?.toggleNowPlayingDrawer() },
                                        onOpen: { [weak chat] in chat?.openTimelineReader(.nowPlaying(audioPlayer)) }
                                    )
                                }
                            }
                        },
                        trailingStripContent: {
                            if let notifyState = chat.notifyChipState {
                                ExtensionNotifyChip(
                                    state: notifyState,
                                    onToggleExpanded: { [weak chat] in
                                        withAnimation(.easeOut(duration: 0.10)) { chat?.toggleNotifyChip() }
                                    }
                                )
                            }
                        }
                    )
                    .padding(.horizontal, 16)

                    if showsReviewCommentPill, chat.model.reviewCommentDrawerExpanded {
                        ReviewCommentStashDrawer(
                            comments: chat.reviewComments.stagedComments,
                            focusedCommentId: nil,
                            onEdit: { [weak chat] comment in
                                chat?.presentReviewCommentStashSheet(editing: comment)
                            },
                            onDelete: { [weak chat] comment in
                                chat?.deleteReviewComment(comment)
                            }
                        )
                        .padding(.horizontal, 16)
                    }

                    if showsNowPlayingPill, chat.model.nowPlayingDrawerExpanded {
                        InAppNowPlayingDrawer(
                            audioPlayer: audioPlayer,
                            accessibilityPrefix: "chat.nowPlaying",
                            onOpen: { [weak chat] in chat?.openTimelineReader(.nowPlaying(audioPlayer)) }
                        )
                        .padding(.horizontal, 16)
                    }

                    if let notifyState = chat.notifyChipState, notifyState.isExpanded {
                        ExtensionNotifyDrawer(
                            state: notifyState,
                            onCollapse: { [weak chat] in
                                withAnimation(.easeOut(duration: 0.10)) { chat?.collapseNotifyChip() }
                            },
                            onDismiss: { [weak chat] in
                                guard let chat else { return }
                                chat.connection.extensionNotifyChipStore.dismiss(sessionId: chat.sessionId)
                            },
                            onOpenURL: { [weak chat] in chat?.openExtensionSurfaceURL($0) ?? false }
                        )
                        .padding(.horizontal, 16)
                    }
                }

                if let reconnectFailure {
                    ChatFooterNotice(text: reconnectFailure, tint: .themeRed, color: Color.themeRed)
                }

                ForEach(warnings, id: \.self) { warning in
                    ChatFooterNotice(text: warning, tint: .themeYellow, color: Color.themeYellow)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

/// A reconnect failure or session warning above the composer.
private struct ChatFooterNotice: View {
    let text: String
    let tint: ThemeShapeStyle
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 1)

            Text(text)
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
                .fill(color.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        }
        .padding(.horizontal, 16)
    }
}

/// The extension panel below the composer, 8 pt under it.
private struct ChatFooterBelowLeaf: View {
    let context: ChatLeafContext

    var body: some View {
        if let chat = context.chat, !chat.isStopped, !chat.hasBlockingExtensionInput,
           chat.extensionSurfaceState.hasVisibleContent(in: .belowEditor) {
            ExtensionSurfacePanel(
                surface: chat.extensionSurfaceState,
                placement: .belowEditor,
                linkContext: chat.extensionSurfaceLinkContext,
                onOpenURL: { [weak chat] in chat?.openExtensionSurfaceURL($0) ?? false },
                onExpandedEntryChange: { [weak chat] in chat?.handleExtensionDrawerExpansion($0) },
                collapseRequestID: chat.model.extensionDrawerCollapseRequestID
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}

/// A stopped session's footer, in place of the composer.
private struct ChatStoppedFooterLeaf: View {
    let context: ChatLeafContext

    var body: some View {
        if let chat = context.chat, chat.isStopped {
            SessionEndedFooter(
                session: chat.session,
                isResuming: chat.actionHandler.isResuming,
                onResume: { [weak chat] in chat?.resumeSession() }
            )
        }
    }
}

/// The jump-to-bottom hint in its slot at the timeline's bottom trailing corner.
private struct ChatJumpToBottomLeaf: View {
    let context: ChatLeafContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let chat = context.chat
        let visible = chat?.scrollController.isJumpToBottomHintVisible == true
        ZStack(alignment: .bottomTrailing) {
            if let chat, visible {
                JumpToBottomHintButton(
                    isBusy: chat.isBusy,
                    modelId: chat.session?.model,
                    onTap: { [weak chat] in chat?.scrollController.requestScrollToBottom() }
                )
                .transition(ThemeMotion.scaleFade(scale: 0.96, anchor: .bottomTrailing, reduceMotion: reduceMotion))
            }
        }
        .frame(
            width: ChatViewController.jumpToBottomSlotSize,
            height: ChatViewController.jumpToBottomSlotSize,
            alignment: .bottomTrailing
        )
        .animation(ThemeMotion.easeInOut(duration: 0.18, reduceMotion: reduceMotion), value: visible)
    }
}

/// The session title in the bar.
private struct ChatTitleLeaf: View {
    let context: ChatLeafContext

    var body: some View {
        if let chat = context.chat {
            let session = chat.session
            ChatSessionTitleView(
                sessionId: chat.sessionId,
                sessionDisplayName: chat.sessionDisplayName,
                assistantIdentityPresentation: chat.assistantIdentityPresentation,
                agentIcon: session?.launch?.agentIcon,
                cost: session?.cost,
                terminalMirrorIndicator: TerminalMirrorIndicatorPresentation(session: session),
                maxWidth: chat.model.titleMaxWidth,
                isDurableEngine: session?.engine == .durable,
                subtitle: chat.conversationTitleSubtitle
            )
        }
    }
}

/// The pages the Files panel's Changed tab pushes, still SwiftUI: a Git
/// change's review, or the current bytes of a file the session touched. Each
/// runs in its own screen, so the panel's server, API client, and navigation
/// go on explicitly.
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
        let page = SessionTouchedFileContentView(
            workspaceId: workspaceId,
            sessionId: sessionId,
            filePath: path,
            fileName: path.lastPathComponentForDisplay,
            navigationContext: navigationContext
        )
        .environment(\.reviewCommentSelectionScope, reviewCommentSelectionScope)
        let connection = inputs.connection
        let apiClient = inputs.apiClient
        let navigation = inputs.navigation
        navigator.push {
            page.presenterScope(connection: connection, apiClient: apiClient, navigation: navigation)
        }
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

/// Share with redaction review. Reads `shareReview` in the sheet's own graph.
private struct ChatShareRedactionLeaf: View {
    let context: ChatLeafContext

    var body: some View {
        if let chat = context.chat {
            let review = chat.shareReview
            ShareSessionRedactionSheet(
                policy: Bindable(review).policy,
                preflight: review.preflight,
                isAnalyzing: review.isAnalyzing,
                errorMessage: review.errorMessage,
                isSharing: chat.actionHandler.isSending,
                onRefresh: { [weak chat] in chat?.scheduleSharePreflight() },
                onShare: { [weak chat] in chat?.publishSessionWithCurrentRedactionPolicy() },
                onCancel: { [weak chat] in
                    chat?.cancelSharePreflight()
                    chat?.model.showShareRedactionSheet = false
                }
            )
            .onAppear { [weak chat] in
                review.reset()
                chat?.scheduleSharePreflight()
            }
            .onChange(of: review.policy) { [weak chat] _, newPolicy in
                let normalized = newPolicy.normalized
                if normalized != review.policy {
                    review.policy = normalized
                    return
                }
                AppPreferences.Share.setRedactionPolicy(normalized)
                chat?.scheduleSharePreflight()
            }
        }
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
    var isDurableEngine = false
    /// Read here, in the hosted title: SwiftUI invalidates an `@AppStorage`
    /// reader on every `UserDefaults` write in the process, whatever the key,
    /// and read higher up each write re-rendered everything above it,
    /// the timeline host once included.
    @AppStorage(AppPreferences.Experiments.durableSessionsKey) private var durableSessionsExperimentEnabled = false
    /// Conversation layout: model and thinking under the title, e.g.
    /// "gpt-5 \u{00B7} High".
    var subtitle: String? = nil
    var iconIsDecorative = true
    var iconAccessibilityIdentifier: String?

    var body: some View {
        VStack(spacing: 1) {
            titleRow
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("chat.title.subtitle")
            }
        }
        .frame(maxWidth: maxWidth)
        .clipped()
    }

    private var titleRow: some View {
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

            if isDurableEngine && durableSessionsExperimentEnabled {
                Text("Durable")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .fixedSize()
                    .accessibilityIdentifier("chat.title.durable")
            }
        }
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

