import Observation
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

/// The chat screen's own state: what it opens, what its footer and drawers
/// show, and the composer values that are not the draft. The controller reads
/// it in `updateProperties()`, and the chat's hosted SwiftUI leaves (footer,
/// context bar) read the same model, so a change reaches both without either
/// pushing to the other.
@MainActor @Observable
final class ChatScreenModel {
    var composerTextBeforeRecording: String?
    var busyStreamingBehavior: StreamingBehavior = .steer
    var isPreparingAttachments = false
    var attachmentPreparationText: String?
    var messageQueueError: String?

    var showOutline = false
    var isFilePanelVisible = false
    var showContextInspector = false
    var showModelPicker = false
    var showComposer = false
    var showShareRedactionSheet = false
    var selectedFilePanelTab: ChatFileBrowserPanelTab

    var visibleAudioStripItemIDs: Set<String> = []
    var nowPlayingDrawerExpanded = false
    var reviewCommentDrawerExpanded = false
    var extensionDrawerCollapseRequestID = 0
    var reviewCommentStashPresentation: ReviewCommentStripChrome.StashPresentation?
    var contextBarCollapseToken = 0
    var contextBarExpanded = false
    var activeReviewCommentRequest: ReviewCommentSelectionRequest?
    /// Bumped when Settings → Chat → Style changes.
    var chatDisplayRefresh = 0
    /// The bar title's widest size (`updateTitleMaxWidth`).
    var titleMaxWidth: CGFloat = 320

    init(selectedFilePanelTab: ChatFileBrowserPanelTab) {
        self.selectedFilePanelTab = selectedFilePanelTab
    }
}

/// The chat screen. UIKit owns its structure: the timeline
/// (`ChatTimelineController`), the context bar and footer leaves, the composer
/// (`ChatComposerOwner`), its bar items, and every presentation. It reads the
/// session, the connection's stores, and its own `ChatScreenModel` in
/// `updateProperties()`; streaming never reaches it, because the timeline
/// observes `TimelineReducer` itself.
///
/// The session is fixed for the controller's lifetime. A host that swaps one
/// session's chat for another's builds a new controller: reusing one kept its
/// runtime, and the new session never connected (blank timeline after a
/// notification tap from another chat).
@MainActor
final class ChatViewController: UIViewController {
    enum LocalSlashCommand: Equatable {
        case compact
    }

    let sessionId: String
    let serverIdHint: String?
    let workspaceIdHint: String?
    let routeScope: SessionRouteScope?
    /// Presenter-local values: this chat's server, its API client, and the
    /// navigation it reports to (the chat commit viewer has its own, so its
    /// chat cannot take the app's pending quick-session message).
    let connection: ServerConnection
    let apiClient: APIClient?
    let appNavigation: AppNavigation

    let sessionManager: ChatSessionManager
    private let sessionRuntimeLease: ChatSessionManagerLease
    let scrollController = ChatScrollController()
    let actionHandler = ChatActionHandler()
    let voiceInputManager = VoiceInputManager.shared
    let audioLifecycleCoordinator = AudioLifecycleCoordinator()
    let liveVoiceController = LiveVoiceCallController()
    let composerDraftController: ChatComposerDraftController
    let reviewComments = ChatReviewCommentsController()
    let outlineAvailability = ChatTimelineOutlineAvailability()
    let shareReview = ShareSessionRedactionReview()
    let model: ChatScreenModel

    let timeline = ChatTimelineController()
    private(set) var timelineView: UICollectionView?
    let composer = ChatComposerOwner()
    let footerStack = UIStackView()
    let scrim = UIView()
    var contextBarLeaf: HostedLeaf?
    var footerAboveLeaf: HostedLeaf?
    var footerBelowLeaf: HostedLeaf?
    var stoppedFooterLeaf: HostedLeaf?
    var jumpToBottomLeaf: HostedLeaf?
    private var titleHost: HostedContentController?
    let canvasAnchor = ComposerCanvasDestinationAnchorController()
    lazy var trailingColumn = TrailingColumnController(screen: self)
    /// The navigator the chat's hosted leaves push and present through.
    var leafNavigator: ScreenNavigator?
    /// Modals the chat presents; each is one router presentation slot.
    let modals = ChatModalSlots()
    let barItems = ChatBarItems()

    /// The bottom the timeline and footer sit on: the keyboard's top, or the
    /// safe area while a field in the trailing column has the keyboard
    /// (`TrailingColumnKeyboardScreen`).
    private let contentBottomGuide = UILayoutGuide()
    private var bottomFollowsKeyboard: NSLayoutConstraint?
    private var bottomAtSafeArea: NSLayoutConstraint?

    private var timelineTopOverlap: CGFloat = 0
    private var footerHeight: CGFloat = 0
    var timelineWidth: CGFloat = 0
    /// The workspace shell this chat was mounted under, for the shell-swap
    /// scroll handoff.
    private var mountedPresentation: WorkspaceNavigationPresentation = .stack
    private var lastTimelineChrome: ChatTimelineChromeKey?
    private var observed = ChatObservedValues()
    private var sessionEntryTask: Task<Void, Never>?
    private var hasAppeared = false
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
    private var cachedReviewCommentRouter: (templates: [UUID], router: ReviewCommentSelectionRouter)?
#if DEBUG
    private var hasSeededE2EChatImageAttachment = false
#endif

    init(
        sessionId: String,
        connection: ServerConnection,
        navigation: AppNavigation,
        apiClient: APIClient?? = nil,
        serverIdHint: String? = nil,
        workspaceIdHint: String? = nil,
        routeScope: SessionRouteScope? = nil,
        initialInputText: String = "",
        initialPendingFiles: [PendingFileReference] = []
    ) {
        self.sessionId = sessionId
        self.connection = connection
        self.apiClient = apiClient ?? connection.apiClient
        self.appNavigation = navigation
        self.serverIdHint = serverIdHint
        self.workspaceIdHint = workspaceIdHint
        let routeScope = routeScope ?? workspaceIdHint.map(SessionRouteScope.workspace)
        self.routeScope = routeScope
        let manager = ChatSessionManager(
            sessionId: sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: routeScope
        )
        sessionManager = manager
        sessionRuntimeLease = ChatSessionManagerLease(manager: manager)
        composerDraftController = ChatComposerDraftController(
            initialText: initialInputText,
            initialRepoPointers: initialPendingFiles
        )
        model = ChatScreenModel(
            selectedFilePanelTab: ChatFileBrowserPanelTabStore.shared.tab(for: sessionId)
        )
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Leaving for good, exactly once: a covered chat can be destroyed without
    /// a second disappearance (stack rebuilds, stack↔split, a lock). Inline
    /// video stops here; fullscreen and Picture in Picture hold its player
    /// past the cell, so a closed chat kept playing.
    isolated deinit {
        if let timelineView {
            timeline.dismantle(timelineView)
        }
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Derived state

    var root: AppRootEnvironment? { HostFactory.root(near: self) }
    var sessionStore: SessionStore { connection.sessionStore }
    var chatState: ChatSessionState { connection.chatState }
    var audioPlayer: AudioPlayerService { connection.audioPlayer }

    /// The screen the stack shows: this chat, or the shell route around it.
    /// Bar items, pushes, and `finish()` go through it.
    var screen: UIViewController {
        (parent as? ChatRouteViewController) ?? self
    }

    /// Per-session reducer, owned by sessionManager.
    var reducer: TimelineReducer { sessionManager.reducer }

    var session: Session? {
        sessionStore.sessions.first { $0.id == sessionId }
    }

    var assistantIdentityPresentation: AssistantIdentityPresentation {
        AssistantIdentityPresentation.resolve(
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon
        )
    }

    var timelineWorkspaceId: String? {
        let sessionWorkspaceId = session?.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sessionWorkspaceId, !sessionWorkspaceId.isEmpty {
            return sessionWorkspaceId
        }
        let fallback = workspaceIdHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback : nil
    }

    var focusedRouteScope: SessionRouteScope? {
        if session?.usesControlRoutes == true { return .control }
        if let timelineWorkspaceId { return .workspace(timelineWorkspaceId) }
        return routeScope
    }

    var resolvedServerId: String? {
        serverIdHint ?? connection.currentServerId ?? sessionStore.activeServerId
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
        // Skill and extension sessions edit host files at their exact paths.
        controlDomain == .skills || controlDomain == .extensions ? .verbatim : .normalizedDisplay
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

    /// Shared by the viewer destination and composer callback.
    /// Accept only if the message-mode draft actually stored the attachment.
    @discardableResult
    static func deliverCanvasToComposer(
        attachment: PendingAttachment,
        recognizedText _: String,
        draftController: ChatComposerDraftController
    ) -> Bool {
        var nextAttachments = draftController.pendingAttachments
        if !nextAttachments.contains(where: { $0.id == attachment.id }) {
            nextAttachments.append(attachment)
        }
        return draftController.setPendingAttachments(nextAttachments)
            && draftController.pendingAttachments.contains(where: { $0.id == attachment.id })
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

    /// The composer writes its text here; the mode decides which draft it edits.
    func setComposerText(_ newText: String) {
        let mode = Self.resolvedComposerMode(
            hasReviewComment: model.activeReviewCommentRequest != nil,
            hasAskRequest: activeComposerAskRequest != nil
        )
        composerDraftController.updateVisibleText(newText, for: mode)
    }

    /// Message mode stores an attachment-bar update; a refused non-message
    /// update discards any unreferenced draft files.
    func setComposerPendingAttachments(_ newAttachments: [PendingAttachment]) {
        composerDraftController.setPendingAttachments(newAttachments)
    }

    /// The bar shows the message draft's attachments; an Ask answer or a
    /// review comment carries none.
    var composerVisibleAttachments: [PendingAttachment] {
        composerDraftController.mode == .message ? composerDraftController.pendingAttachments : []
    }

    var availableSlashCommands: [SlashCommand] {
        Self.availableSlashCommands(from: chatState.slashCommands)
    }

    var hasShareSlashCommand: Bool {
        chatState.slashCommands.contains { command in
            command.name.caseInsensitiveCompare("share") == .orderedSame
        }
    }

    var sessionDisplayName: String {
        session?.displayTitle ?? "Session \(String(sessionId.prefix(8)))"
    }

    var isBusy: Bool {
        session?.status == .busy || session?.status == .stopping
    }

    var isStopping: Bool {
        actionHandler.isStopping || session?.status == .stopping
    }

    var isStopped: Bool {
        session?.status == .stopped
    }

    /// Settings → Chat → Style, for every session and width.
    var chatDisplayStyle: AppPreferences.ChatDisplay.Style {
        _ = model.chatDisplayRefresh
        return AppPreferences.ChatDisplay.style
    }

    var timelineChromeStyle: ChatTimelineChromeStyle {
        .for(chatDisplayStyle)
    }

    private var workStripStyle: AppPreferences.ChatDisplay.WorkStripStyle {
        _ = model.chatDisplayRefresh
        return AppPreferences.ChatDisplay.workStripStyle
    }

    private var messageQueueState: MessageQueueState {
        connection.messageQueueStore.queue(for: sessionId)
    }

    var hasQueuedMessages: Bool {
        !messageQueueState.steering.isEmpty || !messageQueueState.followUp.isEmpty
    }

    var showsMessageQueue: Bool {
        hasQueuedMessages || model.messageQueueError != nil
    }

    var messageQueueSurfaceConfiguration: MessageQueueSurfaceConfiguration {
        MessageQueueSurfaceConfiguration(
            queue: messageQueueState,
            onRemove: { [weak self] itemId in
                guard let self else { return }
                self.model.messageQueueError = nil
                try await self.connection.removeQueuedMessage(itemId: itemId, sessionIdOverride: self.sessionId)
            },
            onEditInComposer: { [weak self] in try await self?.restoreQueuedMessagesToComposer() },
            error: model.messageQueueError
        )
    }

    var extensionSurfaceState: ExtensionSurfaceState? {
        connection.extensionSurfaceBySession[sessionId]
    }

    var activeComposerAskRequest: AskRequest? {
        connection.askRequestStore.pending(for: sessionId)
    }

    var composerAskRequest: AskRequest? {
        Self.resolvedComposerAskRequest(
            activeComposerAskRequest,
            hasReviewComment: model.activeReviewCommentRequest != nil
        )
    }

    var hasBlockingExtensionInput: Bool {
        activeComposerAskRequest != nil || connection.hasPendingExtensionDialog(for: sessionId)
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

    var canPersistSessionDefaults: Bool {
        session?.supportsPersistingDefaults ?? true
    }

    var showsNowPlayingPill: Bool {
        InAppNowPlayingChrome.shouldShowChatPill(
            hasActivePlayback: audioPlayer.hasActivePlayback,
            playbackItemID: InAppNowPlayingChrome.playbackItemID(
                playingItemID: audioPlayer.playingItemID,
                loadingItemID: audioPlayer.loadingItemID
            ),
            visibleStripItemIDs: model.visibleAudioStripItemIDs
        )
    }

    var showsReviewCommentPill: Bool {
        ReviewCommentStripChrome.shouldShowPill(
            stagedCount: reviewComments.stagedCount,
            isDraftingComment: model.activeReviewCommentRequest != nil
        )
    }

    var notifyChipState: ExtensionNotifyChipStore.SessionState? {
        connection.extensionNotifyChipStore.state(for: sessionId)
    }

    var showsNotifyChip: Bool {
        notifyChipState != nil
    }

    var extensionSurfaceLinkContext: ExtensionSurfaceLinkContext {
        ExtensionSurfaceLinkContext(
            serverID: resolvedServerId,
            workspaceID: session?.workspaceId ?? sessionStore.workspaceId(for: sessionId),
            sessionID: sessionId
        )
    }

    /// Commit and path-pill destinations are built here, not by the timeline, so the timeline
    /// holds no app services.
    private var timelineDestinationAction: ChatTimelineOpenDestination {
        let presenter = ChatTimelineDestinationPresenter(connection: connection)
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

    private lazy var canvasDestination = ComposerCanvasDestination(sessionId: sessionId) { [weak self] attachment, recognizedText in
        self?.deliverCanvasToComposer(attachment: attachment, recognizedText: recognizedText) ?? false
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
        appNavigation.openChatReader(
            store.store(
                Self.stampedTimelineReaderPayload(
                    payload,
                    sessionId: sessionId,
                    composerDestination: canvasDestination,
                    lockOrigin: readerLockOrigin
                ),
                retaining: appNavigation.containsChatReader
            )
        )
    }

    private func openCurrentToolFile(path: String) {
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

    /// The router review-comment selections reach this chat through. Rebuilt
    /// only when the quick-comment templates change, so the canvas anchor and
    /// the panels keep one router.
    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter {
        let templates = QuickCommentTemplate.quickCommentTemplates(root?.quickCommentTemplateStore.templates ?? [])
        let ids = templates.map(\.id)
        if let cached = cachedReviewCommentRouter, cached.templates == ids {
            return cached.router
        }
        let router = ReviewCommentSelectionRouter(
            dispatchWithPresentation: { [weak self] request, _ in
                self?.handleReviewCommentSelection(request)
            },
            inlineSave: { [weak self] body, request in
                self?.saveReviewComment(body: body, request: request) ?? false
            },
            inlineQuickComments: templates,
            voiceInputManager: voiceInputManager,
            stash: reviewComments
        )
        cachedReviewCommentRouter = (ids, router)
        return router
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let collectionView = timeline.makeCollectionView(
            configuration: makeTimelineConfiguration(),
            contentRoot: root
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        timelineView = collectionView

        view.addLayoutGuide(contentBottomGuide)
        let followsKeyboard = contentBottomGuide.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        bottomFollowsKeyboard = followsKeyboard
        bottomAtSafeArea = contentBottomGuide.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)

        // Dismiss scrim: dims the timeline so content doesn't bleed through
        // the context bar's glass, and collapses the bar on tap. A
        // semi-opaque fill instead of clear prevents the visual overlap
        // between expanded bar content and the timeline behind.
        scrim.translatesAutoresizingMaskIntoConstraints = false
        scrim.isHidden = true
        scrim.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
        view.addSubview(scrim)

        footerStack.axis = .vertical
        footerStack.alignment = .fill
        footerStack.spacing = 0
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerStack)

        NSLayoutConstraint.activate([
            contentBottomGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentBottomGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentBottomGuide.topAnchor.constraint(equalTo: view.topAnchor),
            followsKeyboard,
            // The timeline reaches up under the navigation bar so rows scroll
            // under its glass; `topOverlap` keeps the first row below the bar
            // and the context bar.
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: contentBottomGuide.bottomAnchor),
            scrim.topAnchor.constraint(equalTo: view.topAnchor),
            scrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footerStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: contentBottomGuide.bottomAnchor),
        ])

        composer.source = self
        addChild(composer)
        composer.didMove(toParent: self)

        addChild(canvasAnchor)
        canvasAnchor.view.frame = .zero
        canvasAnchor.view.isHidden = true
        view.addSubview(canvasAnchor.view)
        canvasAnchor.didMove(toParent: self)

        addChild(trailingColumn)
        trailingColumn.view.frame = .zero
        view.addSubview(trailingColumn.view)
        trailingColumn.didMove(toParent: self)

        modals.anchor = self
        barItems.chat = self
        installNotificationObservers()
        installLeavesIfNeeded()
        registerForTraitChanges(
            [UITraitHorizontalSizeClass.self, UITraitPreferredContentSizeCategory.self]
        ) { (self: Self, _) in
            self.setNeedsUpdateProperties()
        }
        if #available(iOS 27.1, *) {
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (self: Self, _) in
                self.setNeedsUpdateProperties()
            }
        }
    }

    /// Hosted leaves need the app root, which a controller finds once it is
    /// in its stack.
    private func installLeavesIfNeeded() {
        guard footerAboveLeaf == nil, let root else { return }
        leafNavigator = ScreenNavigator.forUIKitScreen(screen, root: root)

        let contextBar = makeContextBarLeaf(root: root)
        add(contextBar)
        view.insertSubview(contextBar.view, aboveSubview: scrim)
        contextBarLeaf = contextBar

        let above = makeFooterAboveLeaf(root: root)
        let below = makeFooterBelowLeaf(root: root)
        let stopped = makeStoppedFooterLeaf(root: root)
        for leaf in [above, below, stopped] {
            add(leaf)
        }
        footerStack.addArrangedSubview(above.view)
        footerStack.addArrangedSubview(composer.view)
        footerStack.addArrangedSubview(below.view)
        footerStack.addArrangedSubview(stopped.view)
        footerAboveLeaf = above
        footerBelowLeaf = below
        stoppedFooterLeaf = stopped

        // The title view lives in the navigation bar, outside this
        // controller's view, so its host is not a child controller: UIKit
        // raises when a child's view sits outside its parent's.
        let title = makeTitleHost(root: root)
        titleHost = title
        barItems.titleControl.install(title.view)

        let jump = makeJumpToBottomLeaf(root: root)
        add(jump)
        view.addSubview(jump.view)
        jumpToBottomLeaf = jump

        NSLayoutConstraint.activate([
            contextBar.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contextBar.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            contextBar.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            jump.view.widthAnchor.constraint(equalToConstant: ChatViewController.jumpToBottomSlotSize),
            jump.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -27),
            jump.view.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -10),
        ])
        for leaf in [contextBar, above, below, stopped, jump] {
            leaf.onHeightChange = { [weak self] in self?.view.setNeedsLayout() }
        }
    }

    /// The jump-to-bottom hint's slot; the button sits at its bottom trailing corner.
    static let jumpToBottomSlotSize: CGFloat = 44

    private func add(_ leaf: HostedLeaf) {
        addChild(leaf.host)
        leaf.host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearIfNeeded(animated: animated)
        // Bar items come back after a pop that was cancelled (`viewWillDisappear`).
        barItems.isSuspended = false
        setNeedsUpdateProperties()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Leaving the stack: take the chat's items off the bar now. UIKit
        // otherwise fades them out after the pop, and for that moment the
        // chat's Back, Files, and context still answer on the screen below.
        if screen.isMovingFromParent || screen.isBeingDismissed {
            barItems.clear()
        }
    }

    /// Runs once per appearance, from the first of `viewWillAppear` and
    /// `viewDidAppear`. A child added while its parent is mid-transition (the
    /// shell route builds the chat in its first `updateProperties()`, during
    /// the push) gets only `viewDidAppear`; skipping the work there left the
    /// chat unfocused and its session stream unopened.
    private func appearIfNeeded(animated: Bool) {
        guard !hasAppeared else { return }
        hasAppeared = true
        installLeavesIfNeeded()
        // The chat never shows the stack's bottom toolbar.
        screen.navigationController?.setToolbarHidden(true, animated: animated)
        handleAppear()
#if DEBUG
        seedE2EChatImageAttachmentIfRequested()
#endif
        applyExtensionToolsExpandedState()
        startSessionEntryTasks()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appearIfNeeded(animated: animated)
        // Modals asked for while the chat was off screen present now.
        modals.sync()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // A sheet over the chat keeps it in the window; only leaving the
        // window (a push, a full-screen cover, a pop) is a disappearance.
        guard viewIfLoaded?.window == nil || isMovingFromParent || screen.isMovingFromParent else { return }
        handleDisappear()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let timelineView else { return }
        // Measured in window coordinates from the two frames, never from an
        // inset: it covers the bar and the context bar below it.
        let header: UIView = contextBarLeaf?.view ?? view
        let headerFrame = contextBarLeaf == nil
            ? CGRect(x: 0, y: view.safeAreaInsets.top, width: view.bounds.width, height: 0)
            : header.bounds
        let top = ChatTimelineChromeOverlap.topInset(
            timelineFrame: timelineView.convert(timelineView.bounds, to: nil),
            headerFrame: header.convert(headerFrame, to: nil)
        )
        let bottom = footerStack.frame.height
        let width = timelineView.bounds.width
        if abs(top - timelineTopOverlap) > 0.5 || abs(bottom - footerHeight) > 0.5 || abs(width - timelineWidth) > 0.5 {
            timelineTopOverlap = top
            footerHeight = bottom
            timelineWidth = width
            setNeedsUpdateProperties()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        installLeavesIfNeeded()
        let root = root
        view.backgroundColor = root?.themeStore.backgroundColor
        let palette = root?.themeStore.activeThemeID.palette ?? ThemeRuntimeState.currentPalette()
        scrim.backgroundColor = ComposerThemeColors(palette: palette).bg.withAlphaComponent(0.5)
        timeline.contentRoot = root
        _ = model.chatDisplayRefresh

        observeChanges()
        updateTitleMaxWidth()
        updateTimelineChrome()
        updateFooter()
        barItems.update()
        updateSidePanels()
        updateModals()
        canvasAnchor.destination = canvasDestination
        canvasAnchor.reviewCommentSelectionRouter = reviewCommentSelectionRouter
    }

    // MARK: - Timeline

    private func makeTimelineConfiguration() -> ChatTimelineConfiguration {
        let isBusy = isBusy
        let extensionSurface = extensionSurfaceState
        return ChatTimelineConfiguration(
            items: [],
            hiddenCount: 0,
            renderWindowStep: TimelineRenderWindowPolicy.renderWindowStep,
            isBusy: isBusy,
            showsWorkingIndicator: isBusy && (extensionSurface?.working?.visible ?? true),
            streamingAssistantID: nil,
            sessionId: sessionId,
            serverId: resolvedServerId,
            workspaceId: timelineWorkspaceId,
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon,
            routeScope: focusedRouteScope,
            onFork: { [weak self] in self?.forkFromMessage($0) },
            onOpenCurrentFile: { [weak self] in self?.openCurrentToolFile(path: $0) },
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
            extensionWorkingState: extensionSurface?.working,
            extensionHiddenThinkingLabel: extensionSurface?.hiddenThinkingLabel,
            audioPlayer: audioPlayer,
            audioLifecycleCoordinator: audioLifecycleCoordinator,
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
    /// is not this clock: the timeline observes the reducer itself, and this
    /// never reads `reducer.items`.
    private func updateTimelineChrome() {
        guard let timelineView else { return }
        let extensionSurface = extensionSurfaceState
        let key = ChatTimelineChromeKey(
            isBusy: isBusy,
            workingVisible: extensionSurface?.working?.visible,
            extensionWorkingState: extensionSurface?.working,
            hiddenThinkingLabel: extensionSurface?.hiddenThinkingLabel,
            serverId: resolvedServerId,
            workspaceId: timelineWorkspaceId,
            agentId: session?.launch?.agentId,
            agentIcon: session?.launch?.agentIcon,
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

    // MARK: - Observed changes

    /// The chat's reactions to store changes (the SwiftUI screen's
    /// `onChange`s): each fires when its value changes, not on the first pass.
    private func observeChanges() {
        let session = session
        let next = ChatObservedValues(
            sessionTitle: session?.displayTitle,
            sessionModel: session?.model,
            sessionStatus: session?.status,
            entryState: sessionManager.entryState,
            askRequestID: activeComposerAskRequest?.id,
            toolsExpanded: extensionSurfaceState?.toolsExpanded,
            editorTextRevision: chatState.extensionEditorTextUpdate?.revision,
            jumpToBottomVisible: scrollController.isJumpToBottomHintVisible,
            showsNowPlayingPill: showsNowPlayingPill,
            showsReviewCommentPill: showsReviewCommentPill,
            liveVoiceHoldsComposer: liveVoiceController.holdsComposer,
            draftKey: ChatDraftAttachmentKey(key: composerDraftKey, isEphemeral: composerDraftIsMemoryOnly),
            reviewCommentLoadKey: ReviewCommentLoadKey(localScopeId: reviewCommentLocalScopeId, sessionId: sessionId),
            scenePhaseIsActive: AppScenePhase.shared.isActive,
            scenePhasePausesTimeline: AppScenePhase.shared.pausesTimelinePresentation
        )
        let previous = observed
        observed = next
        guard previous.isInitialized else {
            // First pass: the keyed tasks run once, as `.task(id:)` did.
            attachComposerDraftIfPossible()
            loadReviewCommentsIfPossible()
            return
        }
        if previous.sessionTitle != next.sessionTitle || previous.sessionModel != next.sessionModel {
            audioPlayer.setSessionContext(session)
        }
        if previous.draftKey != next.draftKey {
            attachComposerDraftIfPossible()
        }
        if previous.reviewCommentLoadKey != next.reviewCommentLoadKey {
            loadReviewCommentsIfPossible()
        }
        if previous.editorTextRevision != next.editorTextRevision {
            handleExtensionEditorTextUpdate()
        }
        if previous.askRequestID != next.askRequestID {
            synchronizeComposerMode()
        }
        if previous.toolsExpanded != next.toolsExpanded {
            applyExtensionToolsExpandedState()
        }
        if previous.sessionStatus != next.sessionStatus {
            handleSessionStatusChange(next.sessionStatus)
        }
        if previous.entryState != next.entryState, let entryState = next.entryState {
            handleEntryStateChange(entryState)
        }
        if previous.scenePhaseIsActive != next.scenePhaseIsActive
            || previous.scenePhasePausesTimeline != next.scenePhasePausesTimeline {
            handleScenePhaseChange()
        }
        if !previous.jumpToBottomVisible, next.jumpToBottomVisible {
            model.contextBarCollapseToken &+= 1
        }
        if previous.showsNowPlayingPill, !next.showsNowPlayingPill {
            model.nowPlayingDrawerExpanded = false
        }
        if previous.showsReviewCommentPill, !next.showsReviewCommentPill {
            model.reviewCommentDrawerExpanded = false
        }
        if previous.liveVoiceHoldsComposer, !next.liveVoiceHoldsComposer {
            // The draft set aside when the call started returns when it ends.
            composerDraftController.restoreSetAsideMessage()
            synchronizeComposerMode()
        }
    }

    private func installNotificationObservers() {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AppPreferences.ChatDisplay.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.chatDisplayRefresh += 1 }
            },
            center.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.viewIfLoaded?.window != nil else { return }
                    self.model.contextBarCollapseToken &+= 1
                }
            },
            center.addObserver(
                forName: AudioPlayerService.stateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let objectID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
                let playing = notification.userInfo?[AudioPlayerService.playingItemIDUserInfoKey] as? String
                let loading = notification.userInfo?[AudioPlayerService.loadingItemIDUserInfoKey] as? String
                MainActor.assumeIsolated {
                    self?.handleAudioPlayerStateChange(objectID: objectID, playing: playing, loading: loading)
                }
            },
            center.addObserver(
                forName: .workspaceLinkedFileWillOpen,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let sessionId = notification.object as? String
                let sourceServerID = notification.userInfo?[Notification.Name.workspaceLinkedFileSourceServerIDKey] as? String
                MainActor.assumeIsolated {
                    guard let self, sessionId == self.sessionId,
                          let sourceServerID, sourceServerID == self.connection.currentServerId else { return }
                    // Capture while the source timeline still owns its live geometry;
                    // a push or pop can report tail geometry before the chat disappears.
                    self.scrollController.suspendForNavigation()
                }
            },
        ]
    }

    @objc private func scrimTapped() {
        model.contextBarCollapseToken &+= 1
    }

    // MARK: - Footer

    private func updateFooter() {
        let stopped = isStopped
        composer.view.isHidden = stopped
        scrim.isHidden = !model.contextBarExpanded
        let jumpVisible = scrollController.isJumpToBottomHintVisible
        // The hint's slot stays laid out so the button can animate in and
        // out; it takes touches only while the button shows.
        jumpToBottomLeaf?.view.isUserInteractionEnabled = jumpVisible
    }

    // MARK: - Keyboard

    /// Whether the timeline and footer follow the keyboard. The trailing
    /// column turns it off while a field in its panel (Outline search) has
    /// the keyboard: the keyboard spans the window, and following it lifted
    /// this chat's composer over its timeline beside the panel.
    var followsKeyboard: Bool = true {
        didSet {
            guard followsKeyboard != oldValue else { return }
            bottomFollowsKeyboard?.isActive = followsKeyboard
            bottomAtSafeArea?.isActive = !followsKeyboard
        }
    }

    func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    // MARK: - Lifecycle actions

    private func handleAppear() {
        // A stack/split shell swap remounts this chat: pick up the reading
        // position the same chat had in the other shell before history lands.
        mountedPresentation = appNavigation.workspaceNavigationPresentation
        let shellSwapRemount = ChatScrollShellSwapHandoff.shared.chatDidAppear(
            sessionId: sessionId,
            controller: scrollController,
            presentation: mountedPresentation
        )
        var appearMetadata = ChatMountTelemetry.appearMetadata(
            sessionId: sessionId,
            shellSwapRemount: shellSwapRemount,
            presentation: mountedPresentation.telemetryLabel
        )
        appearMetadata["footprintMB"] =
            AppDiagnosticsService.currentFootprintMB().map(String.init) ?? "n/a"
        ClientLog.info(
            "Navigation",
            "Chat appeared",
            metadata: appearMetadata,
            flush: true
        )

        // Re-establish command routing immediately on re-entry.
        // The async sessionManager.connect() task starts shortly after appear,
        // but users can tap toolbar controls before that task has a chance to
        // refocus the connection on this session.
        connection.prepareForSessionReentry(
            sessionId,
            workspaceIdHint: workspaceIdHint,
            routeScope: focusedRouteScope
        )

        sessionManager.markAppeared()
        sessionManager.claimFocusOnAppear(connection: connection, sessionStore: sessionStore)
        if AppScenePhase.shared.pausesTimelinePresentation {
            sessionManager.coalescer.pause()
        } else if AppScenePhase.shared.isActive,
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
            connection.gitStatusStore.loadInitial(
                workspaceId: wsId,
                worktreeId: session?.worktreeId,
                apiClient: api,
                gitStatusEnabled: ws?.gitStatusEnabled ?? true
            )
        }
        // Pre-load file index for @file fuzzy search
        if let wsId = session?.workspaceId, let api = connection.apiClient {
            connection.fileIndexStore.ensureLoaded(workspaceId: wsId, apiClient: api)
        }
    }

    /// What runs each time the chat appears: bind the session, prewarm voice,
    /// then start a pending quick-voice call and send a pending quick-session
    /// message. Cancelled when the chat leaves the window.
    private func startSessionEntryTasks() {
        audioPlayer.setSessionContext(session)
        activateChatVoiceComposer(voiceInputManager)
        audioLifecycleCoordinator.setPlaybackInterrupter(audioPlayer)
        // Dictation must use the concrete player as the hardware source of truth.
        // The lifecycle coordinator owns presentation state and can be stale across
        // direct-speak/reconnect edges; using it here can make the mic appear wedged.
        voiceInputManager.setPlaybackInterrupter(audioPlayer)
        // Manager owns loop restarts. Leaving the chat must not cancel the
        // connect loop; this only binds the session identity.
        sessionManager.ensureConnected(
            connection: connection,
            sessionStore: sessionStore
        )
        loadReviewCommentsIfPossible()

        sessionEntryTask?.cancel()
        sessionEntryTask = Task { [weak self] in
            await self?.runSessionEntry()
        }
    }

    private func runSessionEntry() async {
        Task { [voiceInputManager] in
            // Pre-warm voice input pipeline in background (model check + transcriber creation)
            await voiceInputManager.prewarm(source: "chat_view_task")
        }

        // A quick voice session opens straight into its call. The call takes the
        // composer first, so the quick message below lands in it and sends during
        // the call instead of being set aside as a draft.
        if appNavigation.pendingLiveVoiceSessionId == sessionId {
            appNavigation.pendingLiveVoiceSessionId = nil
            startLiveVoice()
        }

        // Auto-send pending message from QuickSessionSheet.
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

    private func handleDisappear() {
        hasAppeared = false
        sessionEntryTask?.cancel()
        sessionEntryTask = nil
        let shellSwapRemount = mountedPresentation != appNavigation.workspaceNavigationPresentation
        var disappearMetadata = ChatMountTelemetry.disappearMetadata(
            sessionId: sessionId,
            shellSwapRemount: shellSwapRemount,
            presentation: mountedPresentation.telemetryLabel
        )
        disappearMetadata["footprintMB"] =
            AppDiagnosticsService.currentFootprintMB().map(String.init) ?? "n/a"
        ClientLog.info(
            "Navigation",
            "Chat disappeared",
            metadata: disappearMetadata,
            flush: true
        )
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
        connection.extensionNotifyChipStore.collapseForHiddenChat(sessionId: sessionId)
        actionHandler.cleanup()
        // Releases this runtime's focus claim only; a newer chat for the
        // same session keeps its stream (late or repeated cleanup is a no-op).
        sessionManager.cleanup()
        let liveVoiceController = liveVoiceController
        let composerDraftStore = root?.composerDraftStore
        let sessionManager = sessionManager
        let connection = connection
        Task {
            await liveVoiceController.leave()
            if let composerDraftStore {
                await composerDraftStore.flush()
            }
            await sessionManager.flushSnapshotIfNeeded(connection: connection, force: true)
        }
    }

    private func handleScenePhaseChange() {
        if AppScenePhase.shared.pausesTimelinePresentation {
            // The timeline stays mounted while the scene cannot present a
            // frame. Keep transport and shared session status alive, but make
            // timeline publication a hard presentation boundary.
            sessionManager.coalescer.pause()
            return
        }

        guard AppScenePhase.shared.isActive else { return }
        if sessionManager.coalescer.resume() {
            sessionManager.reloadTimelineAfterPresentationOverflow(
                connection: connection,
                sessionStore: sessionStore
            )
        }
    }

    private func handleAudioPlayerStateChange(objectID: ObjectIdentifier?, playing: String?, loading: String?) {
        guard objectID == ObjectIdentifier(audioPlayer) else { return }
        audioLifecycleCoordinator.syncPlaybackState(
            playingItemID: playing?.isEmpty == false ? playing : nil,
            loadingItemID: loading?.isEmpty == false ? loading : nil
        )
    }

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
        let connection = connection
        let sessionId = sessionId
        Task {
            try? await connection.requestMessageQueue(sessionIdOverride: sessionId)
        }
    }

    private func handleEntryStateChange(_ newState: ChatSessionManager.SessionEntryState) {
        if newState == .streaming {
            actionHandler.clearReconnectFailure()
        }
    }

    private var isReadyForQuickSend: Bool {
        guard sessionManager.entryState == .streaming else { return false }
        return connection.wsClient?.status == .connected
    }

    private func handleExtensionEditorTextUpdate() {
        guard let update = chatState.extensionEditorTextUpdate,
              update.sessionId == sessionId else {
            return
        }
        applyExtensionEditorText(update.text)
    }

    private func applyExtensionToolsExpandedState() {
        guard let toolsExpanded = extensionSurfaceState?.toolsExpanded else { return }
        reducer.applyExtensionToolsExpanded(toolsExpanded)
    }

#if DEBUG
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
        let current = composerDraftController.pendingAttachments
        if !current.contains(where: { $0.id == attachment.id }) {
            composerDraftController.setPendingAttachments(current + [attachment])
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

    // MARK: - Drawers

    func toggleNowPlayingDrawer() {
        let next = ReviewCommentStripChrome.toggleNowPlaying(
            .init(
                commentsExpanded: model.reviewCommentDrawerExpanded,
                nowPlayingExpanded: model.nowPlayingDrawerExpanded
            )
        )
        model.reviewCommentDrawerExpanded = next.commentsExpanded
        model.nowPlayingDrawerExpanded = next.nowPlayingExpanded
        if model.nowPlayingDrawerExpanded {
            collapseNotifyChip()
            dismissKeyboard()
        }
    }

    func toggleReviewCommentDrawer() {
        let next = ReviewCommentStripChrome.toggleComments(
            .init(
                commentsExpanded: model.reviewCommentDrawerExpanded,
                nowPlayingExpanded: model.nowPlayingDrawerExpanded
            )
        )
        model.reviewCommentDrawerExpanded = next.commentsExpanded
        model.nowPlayingDrawerExpanded = next.nowPlayingExpanded
        if model.reviewCommentDrawerExpanded {
            // Extension panels own their selection; ask both placements to
            // collapse without hiding their pills or resetting their content.
            model.extensionDrawerCollapseRequestID &+= 1
            collapseNotifyChip()
            dismissKeyboard()
        }
    }

    func handleExtensionDrawerExpansion(_ expanded: Bool) {
        if expanded {
            model.reviewCommentDrawerExpanded = false
            collapseNotifyChip()
            dismissKeyboard()
        }
    }

    func toggleNotifyChip() {
        guard let state = notifyChipState else { return }
        let expanding = !state.isExpanded
        connection.extensionNotifyChipStore.setExpanded(expanding, sessionId: sessionId)
        if expanding {
            model.reviewCommentDrawerExpanded = false
            model.nowPlayingDrawerExpanded = false
            model.extensionDrawerCollapseRequestID &+= 1
            dismissKeyboard()
        }
    }

    func collapseNotifyChip() {
        connection.extensionNotifyChipStore.setExpanded(false, sessionId: sessionId)
    }

    func handleContextBarExpandedChanged(_ expanded: Bool) {
        model.contextBarExpanded = expanded
        guard expanded else { return }
        // Avoid overlap between expanded git context and composer when the
        // software keyboard is visible.
        dismissKeyboard()
    }

    // MARK: - Navigation

    var usesCustomChatBackButton: Bool {
        appNavigation.workspaceNavigationPresentation == .stack
            || appNavigation.workspaceNavigationPresentation == .split
    }

    /// Back closes the chat's screen through the router: pushed (a shell
    /// route, a quick action, a fork), it pops; as the split detail root, the
    /// column shows its list. The bar controls go first: the outgoing bar
    /// keeps them on screen for most of the transition, where a second tap
    /// on Back would close the screen below too.
    func navigateBackFromChat() {
        barItems.clear()
        Router.finish(screen)
    }

    /// Opens another session above this chat, on this chat's server and
    /// navigation (a fork, or a session link from an extension surface).
    func pushChat(sessionId: String, workspaceId: String?) {
        let chat = ChatViewController(
            sessionId: sessionId,
            connection: connection,
            navigation: appNavigation,
            apiClient: apiClient,
            workspaceIdHint: workspaceId
        )
        chat.traitOverrides.appRootEnvironment = root
        Router.push(chat, from: screen)
    }

    func openExtensionSurfaceURL(_ url: URL) -> Bool {
        let context = extensionSurfaceLinkContext
        switch ExtensionSurfaceLinkRouting.action(
            for: url,
            serverID: context.serverID,
            workspaceID: context.workspaceID,
            currentSessionId: sessionId
        ) {
        case .pushSession(let link):
            connection.prepareForSessionReentry(link.sessionId, workspaceIdHint: link.workspaceId)
            pushChat(sessionId: link.sessionId, workspaceId: link.workspaceId)
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

    // MARK: - Composer actions

    func updateFileSuggestions(query: String?) {
        if let query {
            connection.fetchFileSuggestions(query: query)
        } else {
            connection.clearFileSuggestions()
        }
    }

    private func handleReviewCommentSelection(_ request: ReviewCommentSelectionRequest) {
        model.activeReviewCommentRequest = request
        composerDraftController.setMode(.reviewComment, resetTransientInput: true)
        model.composerTextBeforeRecording = nil
        composer.requestFocus()
        if request.startsDictation { composer.requestDictation(owner: .reviewCommentMenu) }
        model.contextBarCollapseToken &+= 1
    }

    func applyQuickCommentTemplate(_ template: QuickCommentTemplate) {
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
        composer.requestFocus()
    }

    func cancelReviewCommentInput() {
        model.activeReviewCommentRequest = nil
        synchronizeComposerMode()
        model.composerTextBeforeRecording = nil
    }

    func sendComposerAction(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance = .afterSuccess
    ) {
        if model.activeReviewCommentRequest != nil {
            sendActiveReviewComment()
        } else {
            sendPrompt(draftClearance: draftClearance)
        }
    }

    func stopTurn() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let abort: @MainActor () async -> Void = { [weak self] in
                guard let self, self.connection.isFocusedSession(self.sessionId) else { return }
                self.actionHandler.stop(
                    connection: self.connection, reducer: self.reducer, sessionStore: self.sessionStore,
                    sessionManager: self.sessionManager, sessionId: self.sessionId
                )
            }
            // Nothing queued: send a plain Stop. take_queue only exists on newer
            // servers, so requiring it here would leave Stop dead on an older one.
            guard self.hasQueuedMessages else {
                await abort()
                return
            }
            await MessageQueueComposerRestore.stopAfterRestoring(
                restore: { [weak self] in try await self?.restoreQueuedMessagesToComposer() },
                abort: abort,
                onError: { [weak self] error in self?.model.messageQueueError = error.localizedDescription }
            )
        }
    }

    func forceStopTurn() {
        actionHandler.forceStop(
            connection: connection, reducer: reducer,
            sessionStore: sessionStore, sessionId: sessionId
        )
    }

    private func restoreQueuedMessagesToComposer() async throws {
        guard connection.isFocusedSession(sessionId) else { return }
        model.messageQueueError = nil
        let withdrawn = try await connection.takeMessageQueue(sessionIdOverride: sessionId)
        guard let plan = MessageQueueComposerRestore.plan(
            queue: withdrawn,
            currentText: composerDraftController.text,
            currentPendingAttachments: composerDraftController.pendingAttachments
        ) else { return }
        composerDraftController.replaceMessage(text: plan.text, pendingAttachments: plan.pendingAttachments)
        model.composerTextBeforeRecording = nil
        if !model.showComposer { composer.requestFocus() }
    }

    private func sendActiveReviewComment() {
        guard let request = model.activeReviewCommentRequest else { return }
        let body = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let didSave = saveReviewComment(body: body, request: request)
        if didSave {
            model.activeReviewCommentRequest = nil
            synchronizeComposerMode()
            model.composerTextBeforeRecording = nil
            loadReviewCommentsIfPossible()
        }
    }

    func presentComposer() {
        guard activeComposerAskRequest == nil else { return }
        AppHaptics.toolbarExpansion()
        model.showComposer = true
    }

    func stageWorkspaceReviewInCurrentSession(prompt: String, files: [PendingFileReference]) {
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
            model.showComposer = true
        } else if !model.showComposer {
            composer.requestFocus()
        }
    }

    private func applyExtensionEditorText(_ text: String) {
        composerDraftController.replaceMessage(text: text)
        if isStopped {
            model.showComposer = true
        } else if !model.showComposer {
            composer.requestFocus()
        }
    }

    private func loadReviewCommentsIfPossible() {
        reviewComments.load(localScopeId: reviewCommentLocalScopeId, sessionId: sessionId)
    }

    @discardableResult
    func saveReviewComment(body: String, request: ReviewCommentSelectionRequest) -> Bool {
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

    func deleteReviewComment(_ comment: ReviewComment) {
        reviewComments.delete(comment)
    }

    private func clearSentReviewComments(ids: [String]) {
        reviewComments.clearSent(ids: ids)
    }

    private func attachComposerDraftIfPossible() {
        guard let composerDraftStore = root?.composerDraftStore, let composerDraftKey else { return }
        composerDraftController.attach(
            store: composerDraftStore,
            key: composerDraftKey,
            isEphemeral: composerDraftIsMemoryOnly
        )
        synchronizeComposerMode()
    }

    func synchronizeComposerMode() {
        let mode = Self.resolvedComposerMode(
            hasReviewComment: model.activeReviewCommentRequest != nil,
            hasAskRequest: activeComposerAskRequest != nil
        )
        if mode == .ask {
            model.showComposer = false
        }
        composerDraftController.setMode(mode)
    }

    @discardableResult
    private func deliverCanvasToComposer(attachment: PendingAttachment, recognizedText: String) -> Bool {
        Self.deliverCanvasToComposer(
            attachment: attachment,
            recognizedText: recognizedText,
            draftController: composerDraftController
        )
    }

    private var chatDictationServerId: String? {
        if let id = connection.currentServerId, !id.isEmpty { return id }
        if let credentials = connection.credentials {
            return "\(credentials.host):\(credentials.port)"
        }
        return nil
    }

    func prepareChatVoiceInput(_ manager: VoiceInputManager) async throws {
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

    var liveVoiceCallOwnsMic: Bool { liveVoiceController.isLive }

    /// The composer's Live Voice entry: none during a call, or for a terminal Pi mirror,
    /// which cannot answer out loud.
    var liveVoiceEntry: (() -> Void)? {
        guard !liveVoiceCallOwnsMic, session?.runtime != .piTui else { return nil }
        return { [weak self] in self?.startLiveVoice() }
    }

    /// Live Voice talks to this chat's session: its agent hears the caller and answers out loud.
    private func startLiveVoice() {
        guard let routeScope = focusedRouteScope else { return }
        // The call starts with an empty field, now rather than on the next pass, so a
        // message placed in the composer right after (a Quick Session's first) is the
        // call's own and sends, not a draft set aside.
        composerDraftController.setAsideMessage()
        model.composerTextBeforeRecording = nil
        synchronizeComposerMode()
        let liveVoiceController = liveVoiceController
        let sessionId = sessionId
        let connection = connection
        Task {
            await liveVoiceController.start(
                sessionId: sessionId,
                routeScope: routeScope,
                using: connection
            )
        }
    }

    private func dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle() {
        // A send that settles after the chat left must not dismiss another screen's keyboard.
        guard !actionHandler.hasLeftChat,
              composerDraftController.mode == .message,
              composerDraftController.text.isEmpty,
              composerDraftController.repoPointers.isEmpty,
              composerDraftController.pendingAttachments.isEmpty,
              model.composerTextBeforeRecording == nil else {
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
            onProgress: { [weak self] in self?.model.attachmentPreparationText = $0 }
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

    func handleComposerAskSubmit(
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

    func handleComposerAskIgnoreAll(
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
        let connection = connection
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

    var composerIsSending: Bool {
        Self.composerSendIsInFlight(
            isPreparingAttachments: model.isPreparingAttachments,
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
    struct ComposerPromptSendState {
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
        guard let submission = beginComposerSubmission(
            draftController: draftController,
            draftClearance: draftClearance,
            isPreparingAttachments: state.isPreparingAttachments,
            actionIsSending: actionIsSending
        ) else {
            return (.ignored, state)
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
            return (.failed(error), state)
        }
    }

    private func beginComposerSubmission(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance
    ) -> ChatComposerDraftController.SubmissionSnapshot? {
        Self.beginComposerSubmission(
            draftController: composerDraftController,
            draftClearance: draftClearance,
            isPreparingAttachments: model.isPreparingAttachments,
            actionIsSending: actionHandler.isSending
        )
    }


    // swiftlint:disable:next function_body_length
    func sendPrompt(
        draftClearance: ChatComposerDraftController.SubmissionDraftClearance = .afterSuccess
    ) {
        guard !composerIsSending else { return }

        let rawTrimmedInput = composerDraftController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.localSlashCommand(for: rawTrimmedInput) == .compact {
            guard let submission = beginComposerSubmission(draftClearance: draftClearance) else { return }
            model.composerTextBeforeRecording = nil
            actionHandler.compact(
                connection: connection,
                reducer: reducer,
                sessionId: sessionId,
                onSendSucceeded: { [weak self] in
                    self?.composerDraftController.completeSubmission(submission)
                    self?.dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                },
                onAsyncFailure: { [weak self] in
                    self?.composerDraftController.failSubmission(submission)
                }
            )
            return
        }

        if rawTrimmedInput.caseInsensitiveCompare("/reload") == .orderedSame {
            guard let submission = beginComposerSubmission(draftClearance: draftClearance) else { return }
            model.composerTextBeforeRecording = nil
            actionHandler.reloadResources(
                connection: connection,
                reducer: reducer,
                sessionStore: sessionStore,
                sessionId: sessionId,
                onSendSucceeded: { [weak self] in
                    self?.composerDraftController.completeSubmission(submission)
                    self?.dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                },
                onAsyncFailure: { [weak self] in
                    self?.composerDraftController.failSubmission(submission)
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
            model.composerTextBeforeRecording = nil
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            let (outcome, nextState) = await Self.sendPrompt(
                draftController: self.composerDraftController,
                state: ComposerPromptSendState(isPreparingAttachments: self.model.isPreparingAttachments),
                draftClearance: draftClearance,
                actionIsSending: self.actionHandler.isSending,
                upload: { [weak self] sourceAttachments in
                    guard let self else { return [] }
                    let pendingLocalAttachments = sourceAttachments.filter {
                        $0.source == .image || $0.source == .localFile
                    }
                    self.model.attachmentPreparationText = pendingLocalAttachments.isEmpty ? nil : "Uploading attachments…"
                    return try await self.uploadPendingLocalAttachments(sourceAttachments)
                }
            )
            self.model.isPreparingAttachments = nextState.isPreparingAttachments
            self.model.attachmentPreparationText = nil
            switch outcome {
            case .ignored:
                return
            case .failed(let error):
                self.reducer.process(.error(sessionId: self.sessionId, message: self.uploadPreparationErrorMessage(error)))
            case .uploaded(let submission, let attachments, let sourceAttachments):
                let optimisticDisplayText = UserMessageAttachmentPresentation.makeDisplayText(
                    text: reviewText,
                    pendingAttachments: sourceAttachments,
                    pendingRepoPointers: originalPendingRepoPointers,
                    uploadedAttachments: attachments
                )
                let optimisticImages = sourceAttachments.compactMap(\.imageAttachment)
                let dispatchIsBusy = self.isBusy
                let sendBehavior = ComposerAutocomplete.streamingBehavior(
                    for: rawTrimmedInput,
                    isBusy: dispatchIsBusy,
                    selected: self.model.busyStreamingBehavior,
                    commands: self.availableSlashCommands
                )
                let restored = self.actionHandler.sendPrompt(
                    text: text,
                    attachments: attachments,
                    optimisticDisplayText: optimisticDisplayText,
                    optimisticImages: optimisticImages,
                    isBusy: dispatchIsBusy,
                    busyStreamingBehavior: sendBehavior,
                    connection: self.connection,
                    reducer: self.reducer,
                    sessionId: self.sessionId,
                    sessionStore: self.sessionStore,
                    sessionManager: self.sessionManager,
                    onDispatchStarted: { [weak self] in
                        guard let self else { return }
                        // The timeline row or queue item is the send confirmation.
                        // Waiting for ack left this draft in the field while the
                        // agent was already working on it.
                        self.composerDraftController.clearVisibleTextForDispatchedSubmission(submission)
                        self.model.composerTextBeforeRecording = nil

                        // Scroll after the optimistic row is in the collection.
                        // The draft clear above must not wait for that turn.
                        DispatchQueue.main.async {
                            scrollRef.requestScrollToBottom()
                        }
                    },
                    onSendSucceeded: { [weak self] in
                        self?.composerDraftController.completeSubmission(submission)
                        self?.clearSentReviewComments(ids: stagedReviewCommentIds)
                        self?.dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                    },
                    onAsyncFailure: { [weak self] _, _ in
                        self?.composerDraftController.failSubmission(submission)
                    },
                    onNeedsReconnect: {
                        sessionManagerRef.reconnect()
                    }
                )
                if !restored.isEmpty {
                    self.composerDraftController.failSubmission(submission)
                }
            }
        }
    }

    func handleModelSelection(_ model: ModelInfo) {
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

    func applyModelSelection(_ model: ModelInfo) {
        AppPreferences.RecentModels.record(ModelSwitchPolicy.fullModelID(for: model))
        actionHandler.setModel(
            model,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: sessionId
        )
    }

    func setThinking(_ level: ThinkingLevel) {
        actionHandler.setThinking(
            level,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId
        )
    }

    func saveThinkingAsDefault() {
        actionHandler.setThinking(
            chatState.thinkingLevel,
            connection: connection,
            reducer: reducer,
            sessionId: sessionId,
            persist: true
        )
    }

    func resumeSession() {
        actionHandler.resumeSession(
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionManager: sessionManager,
            sessionId: sessionId
        )
    }

    func rename(to name: String) {
        actionHandler.rename(
            name,
            connection: connection,
            reducer: reducer,
            sessionStore: sessionStore,
            sessionId: sessionId
        )
    }

    func copySessionID() {
        UIPasteboard.general.string = sessionId
    }

    func shareSessionFromTitleMenu() {
        guard hasShareSlashCommand else {
            reducer.process(
                .error(sessionId: sessionId, message: "Share command is not enabled for this workspace.")
            )
            return
        }

        shareReview.reset()
        model.showShareRedactionSheet = true
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
        let submission: ChatComposerDraftController.SubmissionSnapshot?
        if clearComposer {
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
            onSendSucceeded: { [weak self] in
                if let submission {
                    self?.composerDraftController.completeSubmission(submission)
                    self?.dismissKeyboardAfterSuccessfulComposerSubmissionIfIdle()
                }
            },
            onAsyncFailure: { [weak self] in
                if let submission {
                    self?.composerDraftController.failSubmission(submission)
                }
            },
            onNeedsReconnect: {
                sessionManagerRef.reconnect()
            }
        )
    }

    func scheduleSharePreflight() {
        let connection = connection
        shareReview.schedulePreflight { policy in
            try await connection.prepareShareSession(redactionPolicy: policy)
        }
    }

    func cancelSharePreflight() {
        shareReview.cancelPreflight()
    }

    func publishSessionWithCurrentRedactionPolicy() {
        let sessionManagerRef = sessionManager
        let policy = shareReview.policy.normalized

        AppPreferences.Share.setRedactionPolicy(policy)
        cancelSharePreflight()
        model.showShareRedactionSheet = false

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

    // MARK: - Tree navigation and forks

    enum TreeNavigationError: LocalizedError {
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

    /// Shared by the outline callback and mounted navigation regression tests.
    /// Loading stays in the chat; the timeline receives only the selected ID.
    /// `loadTarget` reports whether history now holds the target. A target that never
    /// loaded gets no scroll: its jump could never land, and while pending it kept the
    /// timeline from following the live tail.
    static func selectOutlineTimelineEntry(
        _ targetID: String,
        items: [ChatItem],
        scrollController: ChatScrollController,
        loadTarget: @escaping @MainActor () async -> Bool
    ) {
        if items.contains(where: { $0.id == targetID }) {
            scrollController.scrollTargetID = targetID
            return
        }
        Task { @MainActor in
            guard await loadTarget() else { return }
            scrollController.scrollTargetID = targetID
        }
    }

    func navigateFromTree(_ request: SessionTreeNavigationRequest) async throws {
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
            showComposer: model.showComposer
        )

        scrollController.scrollTargetID = viewUpdate.scrollTargetID
        composerDraftController.replaceMessage(
            text: viewUpdate.inputText,
            repoPointers: [],
            pendingAttachments: []
        )

        if viewUpdate.shouldFocusComposer {
            composer.requestFocus()
        }
    }

    func forkFromMessage(_ entryId: String) {
        guard let workspaceId = session?.workspaceId, !workspaceId.isEmpty else {
            reducer.process(.error(sessionId: sessionId, message: "Missing workspace context for fork."))
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let forked = try await self.connection.forkIntoNewSessionFromTimelineEntry(
                    entryId,
                    sourceSessionId: self.sessionId,
                    workspaceId: workspaceId
                )

                let title = forked.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Session \(forked.id.prefix(8))"
                self.reducer.appendSystemEvent("Fork created as new session: \(displayName)")

                self.pushChat(sessionId: forked.id, workspaceId: forked.workspaceId ?? workspaceId)
            } catch {
                self.reducer.process(.error(sessionId: self.sessionId, message: "Fork failed: \(error.localizedDescription)"))
            }
        }
    }
}

// MARK: - Observed values

/// The values the chat reacts to when they change; the first pass records them.
private struct ChatObservedValues: Equatable {
    var isInitialized = false
    var sessionTitle: String?
    var sessionModel: String?
    var sessionStatus: SessionStatus?
    var entryState: ChatSessionManager.SessionEntryState?
    var askRequestID: String?
    var toolsExpanded: Bool?
    var editorTextRevision: Int?
    var jumpToBottomVisible = false
    var showsNowPlayingPill = false
    var showsReviewCommentPill = false
    var liveVoiceHoldsComposer = false
    var draftKey: ChatDraftAttachmentKey?
    var reviewCommentLoadKey: ReviewCommentLoadKey?
    var scenePhaseIsActive = false
    var scenePhasePausesTimeline = false

    init() {}

    init(
        sessionTitle: String?,
        sessionModel: String?,
        sessionStatus: SessionStatus?,
        entryState: ChatSessionManager.SessionEntryState,
        askRequestID: String?,
        toolsExpanded: Bool?,
        editorTextRevision: Int?,
        jumpToBottomVisible: Bool,
        showsNowPlayingPill: Bool,
        showsReviewCommentPill: Bool,
        liveVoiceHoldsComposer: Bool,
        draftKey: ChatDraftAttachmentKey,
        reviewCommentLoadKey: ReviewCommentLoadKey,
        scenePhaseIsActive: Bool,
        scenePhasePausesTimeline: Bool
    ) {
        isInitialized = true
        self.sessionTitle = sessionTitle
        self.sessionModel = sessionModel
        self.sessionStatus = sessionStatus
        self.entryState = entryState
        self.askRequestID = askRequestID
        self.toolsExpanded = toolsExpanded
        self.editorTextRevision = editorTextRevision
        self.jumpToBottomVisible = jumpToBottomVisible
        self.showsNowPlayingPill = showsNowPlayingPill
        self.showsReviewCommentPill = showsReviewCommentPill
        self.liveVoiceHoldsComposer = liveVoiceHoldsComposer
        self.draftKey = draftKey
        self.reviewCommentLoadKey = reviewCommentLoadKey
        self.scenePhaseIsActive = scenePhaseIsActive
        self.scenePhasePausesTimeline = scenePhasePausesTimeline
    }
}

private struct ChatDraftAttachmentKey: Equatable {
    let key: ComposerDraftKey?
    let isEphemeral: Bool
}

/// The timeline chrome values the chat pushes; a change in any one pushes them all.
private struct ChatTimelineChromeKey: Equatable {
    let isBusy: Bool
    let workingVisible: Bool?
    let extensionWorkingState: ExtensionWorkingState?
    let hiddenThinkingLabel: String?
    let serverId: String?
    let workspaceId: String?
    let agentId: String?
    let agentIcon: IconChoice?
    let routeScope: SessionRouteScope?
    let model: String?
    let topOverlap: CGFloat
    let bottomOverlap: CGFloat
    let quietMode: Bool
    let workStripStyle: AppPreferences.ChatDisplay.WorkStripStyle
    let chromeStyle: ChatTimelineChromeStyle
    let reviewTemplates: [UUID]
}
