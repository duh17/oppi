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
/// show, and the composer values that are not the draft. The controller and
/// its UIKit footer, title, and bar items read it in `updateProperties()`,
/// so a change reaches each without one pushing to another.
@MainActor @Observable
final class ChatScreenModel {
    var composerTextBeforeRecording: String?
    var busyStreamingBehavior: StreamingBehavior = .steer
    var isPreparingAttachments = false
    var attachmentPreparationText: String?
    var messageQueueError: String?

    var showOutline = false
    var showGit = false
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
    /// An extension drawer is expanded, so drawer rows that link to child sessions show
    /// their live tails.
    var extensionDrawerExpanded = false
    var reviewCommentStashPresentation: ReviewCommentStripChrome.StashPresentation?
    var activeReviewCommentRequest: ReviewCommentSelectionRequest?
    /// Bumped when Settings → Chat → Style changes.
    var chatDisplayRefresh = 0
    /// Bumped when Settings → Chat → Top Bar changes which buttons the bar
    /// shows or their order.
    var topBarRefresh = 0
    /// A folder terminal is being resolved for this chat. The bar disables its
    /// Terminal action meanwhile, so one tap cannot push two screens.
    var isOpeningTerminal = false
    /// The bar title's widest size (`updateTitleMaxWidth`).
    var titleMaxWidth: CGFloat = 320

    init(selectedFilePanelTab: ChatFileBrowserPanelTab) {
        self.selectedFilePanelTab = selectedFilePanelTab
    }
}

/// The chat screen. UIKit owns its structure: the timeline
/// (`ChatTimelineController`), the footer leaves, the composer
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
    var timelineView: UICollectionView?
    let composer = ChatComposerOwner()
    let footerStack = UIStackView()
    /// Set once the footer rows, title, and jump hint are installed.
    var footerAbove: ChatFooterAboveView?
    let canvasAnchor = ComposerCanvasDestinationAnchorController()
    lazy var trailingColumn = TrailingColumnController(screen: self)
    /// Modals the chat presents; each is one router presentation slot.
    let modals = ChatModalSlots()
    let barItems = ChatBarItems()

    /// The bottom the timeline and footer sit on: the keyboard's top, or the
    /// safe area while a field in the trailing column has the keyboard
    /// (`TrailingColumnKeyboardScreen`).
    let contentBottomGuide = UILayoutGuide()
    var bottomFollowsKeyboard: NSLayoutConstraint?
    var bottomAtSafeArea: NSLayoutConstraint?

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

    var timelineTopOverlap: CGFloat = 0
    var footerHeight: CGFloat = 0
    var timelineWidth: CGFloat = 0
    /// The workspace shell this chat was mounted under, for the shell-swap
    /// scroll handoff.
    var mountedPresentation: WorkspaceNavigationPresentation = .stack
    var lastTimelineChrome: ChatTimelineChromeKey?
    var observed = ChatObservedValues()
    var sessionEntryTask: Task<Void, Never>?
    var hasAppeared = false
    /// The workspace route held this chat's session when it appeared. Only
    /// such a chat can tell from `AppNavigation` that it was left; one pushed
    /// straight onto a stack (`pushChat`) never ends an incognito session.
    var isRouteManaged = false
    /// Watches the route for an incognito chat hidden while still in it, so a
    /// later change that drops the session ends it. Cancelled when this chat shows again.
    var incognitoRouteWatch: IncognitoRouteWatch?
    nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    var cachedReviewCommentRouter: (templates: [UUID], router: ReviewCommentSelectionRouter)?
#if DEBUG
    var hasSeededE2EChatImageAttachment = false
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

    var reviewCommentLocalScopeId: String? {
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

    var reviewCommentPathFormatting: ReviewCommentPathFormatting {
        Self.reviewCommentPathFormattingPolicy(controlDomain: session?.control?.domain)
    }

    var composerDraftKey: ComposerDraftKey? {
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
    var composerDraftIsMemoryOnly: Bool {
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

    var sessionDisplayName: String {
        session?.displayTitle ?? "Session \(String(sessionId.prefix(8)))"
    }

    /// An attached durable session is busy exactly while its replica holds `pi.live.run`;
    /// others, and a durable session between sockets, read the session status.
    var isBusy: Bool {
        if let running = sessionManager.conversationStream?.isRunning { return running }
        return session?.status == .busy || session?.status == .stopping
    }

    var isStopping: Bool {
        actionHandler.isStopping || session?.status == .stopping
    }

    var isStopped: Bool {
        session?.status == .stopped
    }

    /// The Agent's chat style on this device when it has one, else Settings →
    /// Chat → Style, at every width.

    var canPersistSessionDefaults: Bool {
        session?.supportsPersistingDefaults ?? true
    }

    lazy var canvasDestination = ComposerCanvasDestination(sessionId: sessionId) { [weak self] attachment, recognizedText in
        guard let self else { return false }
        return Self.deliverCanvasToComposer(
            attachment: attachment,
            recognizedText: recognizedText,
            draftController: composerDraftController
        )
    }
}
