import UIKit

enum ReviewableControlMarkdownDraftKey {
    static func make(
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String
    ) -> String {
        let resolvedServerId = serverId ?? fallbackServerId ?? "unscoped-server"
        return "\(resolvedServerId):\(domain.rawValue):\(targetId)"
    }
}

enum ReviewableControlMarkdownEditFlow: Equatable {
    case directSession
    case guidedRevision
}

struct ControlRevisionSheetHandoff {
    private var pendingTarget: WorkspaceSessionNavTarget?

    mutating func prepare(_ target: WorkspaceSessionNavTarget) {
        pendingTarget = target
    }

    mutating func completeAfterDismissal() -> WorkspaceSessionNavTarget? {
        defer { pendingTarget = nil }
        return pendingTarget
    }
}

@MainActor
enum ControlRevisionCommentTransfer {
    @discardableResult
    static func moveStagedComments(
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String?,
        toSessionId: String,
        comments: ChatReviewCommentsController = ChatReviewCommentsController()
    ) throws -> Int {
        guard let targetId else { return 0 }
        let draftSessionId = ReviewableControlMarkdownDraftKey.make(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            domain: domain,
            targetId: targetId
        )
        return try comments.moveStagedComments(
            fromLocalScopeId: ReviewCommentLocalScope.controlDraft,
            fromSessionId: draftSessionId,
            toLocalScopeId: SessionRouteScope.control.composerDraftScopeID,
            toSessionId: toSessionId
        )
    }
}

enum ControlRevisionCommentNavigationError: Error, Equatable {
    case serverUnavailable
}

extension ControlRevisionCommentNavigationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .serverUnavailable:
            return "Could not open the new Oppi session"
        }
    }
}

@MainActor
enum ControlRevisionCommentNavigation {
    struct Handoff {
        let serverId: String
        let movedCount: Int
    }

    static func moveStagedComments(
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String?,
        toSessionId: String,
        comments: ChatReviewCommentsController = ChatReviewCommentsController()
    ) throws -> Handoff {
        guard let resolvedServerId = serverId ?? fallbackServerId else {
            throw ControlRevisionCommentNavigationError.serverUnavailable
        }
        let movedCount = try ControlRevisionCommentTransfer.moveStagedComments(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            domain: domain,
            targetId: targetId,
            toSessionId: toSessionId,
            comments: comments
        )
        return Handoff(serverId: resolvedServerId, movedCount: movedCount)
    }

    /// Build the ordinary control-chat route after the durable comment move.
    /// A zero-comment draft is still a valid handoff; navigation must not be
    /// conditional on having review comments to transfer.
    static func makeSessionTarget(
        serverId: String?,
        fallbackServerId: String?,
        domain: ControlSessionDomain,
        targetId: String?,
        toSessionId: String,
        comments: ChatReviewCommentsController = ChatReviewCommentsController()
    ) throws -> WorkspaceSessionNavTarget {
        let handoff = try moveStagedComments(
            serverId: serverId,
            fallbackServerId: fallbackServerId,
            domain: domain,
            targetId: targetId,
            toSessionId: toSessionId,
            comments: comments
        )
        return WorkspaceSessionNavTarget(
            serverId: handoff.serverId,
            sessionId: toSessionId,
            routeScope: .control
        )
    }

    /// Build a route after an atomic launch has already carried the comments in
    /// its initial prompt. Nothing moves into the ordinary composer stash.
    static func makeAtomicLaunchSessionTarget(
        serverId: String?,
        fallbackServerId: String?,
        toSessionId: String
    ) throws -> WorkspaceSessionNavTarget {
        guard let resolvedServerId = serverId ?? fallbackServerId else {
            throw ControlRevisionCommentNavigationError.serverUnavailable
        }
        return WorkspaceSessionNavTarget(
            serverId: resolvedServerId,
            sessionId: toSessionId,
            routeScope: .control
        )
    }

}

@MainActor
struct ControlRevisionSessionRetryState {
    var createdSession: Session?
    var starterPromptDelivered = false
    var requestId: String
    private var frozenGuidedLaunch: GuidedControlSessionAtomicLaunch?

    init(requestId: String = UUID().uuidString) {
        self.requestId = requestId
    }

    mutating func freeze(_ candidate: GuidedControlSessionAtomicLaunch) -> GuidedControlSessionAtomicLaunch {
        if let frozenGuidedLaunch { return frozenGuidedLaunch }
        frozenGuidedLaunch = candidate
        return candidate
    }

    mutating func recordCreatedSession(_ session: Session, promptDelivered: Bool) {
        createdSession = session
        starterPromptDelivered = promptDelivered
    }

    mutating func resetForNextLaunch(requestId: String = UUID().uuidString) {
        createdSession = nil
        starterPromptDelivered = false
        frozenGuidedLaunch = nil
        self.requestId = requestId
    }
}

enum ControlRevisionSessionLaunchError: LocalizedError, Equatable {
    case initialPromptNotSent

    var errorDescription: String? {
        switch self {
        case .initialPromptNotSent:
            "Oppi could not send the initial request. Try again."
        }
    }
}

@MainActor
enum ControlRevisionSessionLaunchCoordinator {
    struct PreparedSession {
        let session: Session
        let starterPromptDelivered: Bool
    }

    static func prepare(
        existingSession: Session?,
        starterPromptDelivered: Bool,
        create: () async throws -> (session: Session, prompted: Bool),
        onSessionCreated: (Session, Bool) -> Void
    ) async throws -> PreparedSession {
        if starterPromptDelivered, let existingSession {
            return PreparedSession(session: existingSession, starterPromptDelivered: true)
        }

        // A not-sent response is retried through the same idempotent create
        // request. Never follow creation with a second ordinary prompt.
        let response = try await create()
        onSessionCreated(response.session, response.prompted)
        guard response.prompted else {
            throw ControlRevisionSessionLaunchError.initialPromptNotSent
        }
        return PreparedSession(session: response.session, starterPromptDelivered: true)
    }
}

/// Full-screen Markdown or text-file review that keeps selected-text comments
/// local until the user explicitly asks an Oppi control session to apply them.
///
/// Text the caller already holds shows in the full-screen reader, presented
/// as a sheet whose reader bar has the dismiss control and Edit (Edit with
/// Oppi). A file on the server's host shows in the file viewer with the
/// stack's bar; a Skill's own file also opens in the editor there. Edit runs
/// a revision session directly, or through the guided revision sheet.
@MainActor
final class ReviewableControlMarkdownViewController: UIViewController, RouterModalContainer {
    private enum Viewer {
        /// Text the caller already holds, in the full-screen reader.
        case fullScreen(FullScreenCodeContent)
        /// A file on the server's host, in the shared file viewer, read on
        /// the target's server.
        case hostFile(serverId: String, title: String, skillFile: SkillFileEditTarget?, connection: ServerConnection)
    }

    var onDismissed: (() -> Void)?

    let domain: ControlSessionDomain
    let targetId: String
    let targetName: String
    let sourceLabel: String
    let sourcePath: String
    let editFlow: ReviewableControlMarkdownEditFlow
    private let viewer: Viewer
    private let languageHint: String?

    private let comments = ChatReviewCommentsController()
    private var guidedSessionHandoff = ControlRevisionSheetHandoff()
    private weak var guidedSheet: HostedScreenController?
    private var isCreatingSession = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var createdSession: Session?
    private var starterPromptDelivered = false
    private let starterPromptRequestId = UUID().uuidString
    private var loadedDraftSessionId: String?

    private var reader: FullScreenCodeViewController?
    /// The file viewer of a host file; its bar is this screen's.
    private(set) var fileViewer: FileViewerViewController?

    init(
        content: String,
        domain: ControlSessionDomain,
        targetId: String,
        targetName: String,
        sourceLabel: String,
        sourcePath: String,
        editFlow: ReviewableControlMarkdownEditFlow = .directSession
    ) {
        viewer = .fullScreen(.markdown(content: content, filePath: sourcePath))
        languageHint = "markdown"
        self.domain = domain
        self.targetId = targetId
        self.targetName = targetName
        self.sourceLabel = sourceLabel
        self.sourcePath = sourcePath
        self.editFlow = editFlow
        super.init(nibName: nil, bundle: nil)
    }

    /// A file at `hostFilePath` on the server, read directly from the host
    /// like any other host file: images, PDFs, and relative Markdown images
    /// work. Host files keep the stack's bar, so Edit is a bar item there;
    /// with `skillFile` it offers the editor beside Edit with Oppi.
    init(
        hostFilePath: String,
        serverId: String,
        title: String,
        skillFile: SkillFileEditTarget? = nil,
        domain: ControlSessionDomain,
        targetId: String,
        targetName: String,
        sourceLabel: String,
        editFlow: ReviewableControlMarkdownEditFlow = .directSession,
        connection: ServerConnection
    ) {
        viewer = .hostFile(serverId: serverId, title: title, skillFile: skillFile, connection: connection)
        languageHint = Self.languageHint(for: hostFilePath)
        self.domain = domain
        self.targetId = targetId
        self.targetName = targetName
        self.sourceLabel = sourceLabel
        self.sourcePath = hostFilePath
        self.editFlow = editFlow
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var root: AppRootEnvironment? {
        HostFactory.root(near: self)
    }

    /// A skill file opens under its own server's scope; other targets live
    /// on the active server.
    private var connection: ServerConnection? {
        if case .hostFile(_, _, _, let connection) = viewer { return connection }
        return root?.coordinator.activeConnection
    }

    private var draftSessionId: String {
        ReviewableControlMarkdownDraftKey.make(
            serverId: connection?.currentServerId,
            fallbackServerId: connection?.sessionStore.activeServerId,
            domain: domain,
            targetId: targetId
        )
    }

    private var selectionContext: ReviewCommentSelectionContext {
        ReviewCommentSelectionContext(
            dispatcher: ReviewCommentSelectionRouter(
                dispatch: { _ in },
                inlineSave: { [weak self] body, request in
                    self?.saveComment(body: body, request: request) ?? false
                },
                inlineQuickComments: QuickCommentTemplate.quickCommentTemplates(
                    root?.quickCommentTemplateStore.templates ?? []
                ),
                stash: comments
            ),
            sessionId: draftSessionId,
            sourceLabel: sourceLabel,
            filePath: sourcePath,
            languageHint: languageHint
        )
    }

    private var navigationActions: [FullScreenViewerNavigationAction] {
        [
            FullScreenViewerNavigationAction(
                id: "edit-in-session",
                title: isCreatingSession ? DocumentEditLabels.startingSession : DocumentEditLabels.edit,
                systemImage: DocumentEditLabels.systemImage,
                accessibilityLabel: DocumentEditLabels.editWithOppi,
                isEnabled: !isCreatingSession,
                handler: { [weak self] in self?.startEdit() }
            ),
        ]
    }

    private var agentEdit: DocumentAgentEditAction {
        DocumentAgentEditAction(isStarting: isCreatingSession) { [weak self] in self?.startEdit() }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        guard case .hostFile(let serverId, let title, let skillFile, let connection) = viewer else { return }
        let fileViewer = FileViewerViewController(
            configuration: .init(
                workspaceId: "",
                serverId: serverId,
                filePath: sourcePath,
                fileName: (sourcePath as NSString).lastPathComponent,
                title: title,
                source: .hostFile,
                reviewCommentSelectionContext: selectionContext,
                skillFile: skillFile
            ),
            services: .init(connection: connection)
        )
        fileViewer.agentEdit = agentEdit
        self.fileViewer = fileViewer
        embed(fileViewer)
    }

    /// The full-screen reader, built once the sheet is in the window, where
    /// the app root (quick comments, the active server) is.
    private func embedReaderIfNeeded() {
        guard reader == nil, case .fullScreen(let content) = viewer else { return }
        let reader = FullScreenCodeViewController(
            content: content,
            reviewCommentSelectionContext: selectionContext,
            navigationActions: navigationActions
        )
        self.reader = reader
        embed(reader)
    }

    private func embed(_ content: UIViewController) {
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        content.didMove(toParent: self)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        loadComments()
        embedReaderIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Once per presentation: UIKit can report the disappearance again.
        if isBeingDismissed || presentingViewController == nil, let onDismissed {
            self.onDismissed = nil
            onDismissed()
        }
    }

    override func updateProperties() {
        super.updateProperties()
        reader?.setNavigationActions(navigationActions)
        if let fileViewer {
            fileViewer.agentEdit = agentEdit
            fileViewer.bar.apply(to: navigationItem)
        }
    }

    /// The target's staged comments, keyed by server, domain, and target.
    private func loadComments() {
        let draftSessionId = draftSessionId
        guard draftSessionId != loadedDraftSessionId else { return }
        loadedDraftSessionId = draftSessionId
        comments.load(localScopeId: ReviewCommentLocalScope.controlDraft, sessionId: draftSessionId)
    }

    // MARK: Edit

    private func startEdit() {
        switch editFlow {
        case .directSession:
            Task { await createOrOpenRevisionSession() }
        case .guidedRevision:
            presentGuidedRevision()
        }
    }

    private var starterPrompt: String {
        ControlSessionStarterPrompt.make(
            domain: domain,
            intent: .revise,
            targetId: targetId,
            targetName: targetName,
            targetPath: domain == .skills ? sourcePath : nil,
            userRequest: "Inspect the current definition and wait for my staged review comments before proposing changes."
        )
    }

    private func presentGuidedRevision() {
        guard guidedSheet == nil, let connection else { return }
        let domain = domain
        let targetId = targetId
        let targetName = targetName
        let targetPath = domain == .skills ? sourcePath : nil
        let comments = comments
        guidedSheet = Router.present(
            presentation: .sheet.inNavigation(),
            from: self,
            onDismiss: { [weak self] in self?.completeGuidedSessionHandoff() },
            content: { [weak self] in
                GuidedControlSessionSheet(
                    domain: domain,
                    intent: .revise,
                    targetId: targetId,
                    targetName: targetName,
                    targetPath: targetPath,
                    placeholder: "Describe how this \(domain.title) should change…",
                    stagedComments: comments,
                    onSessionPrepared: { target in
                        self?.guidedSessionHandoff.prepare(target)
                        self?.closeGuidedRevision()
                    }
                )
                // A skill file opens under its own server's scope, not
                // necessarily the active one.
                .withServerScopedEnvironment(connection)
            }
        )
    }

    private func closeGuidedRevision() {
        guard let guidedSheet, guidedSheet.presentingViewController != nil else { return }
        Router.finish(guidedSheet)
    }

    private func completeGuidedSessionHandoff() {
        guidedSheet = nil
        guard let target = guidedSessionHandoff.completeAfterDismissal() else { return }
        root?.navigation.openWorkspaceSession(target)
    }

    private static func languageHint(for path: String) -> String? {
        switch FileType.detect(from: path, content: "") {
        case .markdown: "markdown"
        case .json: "json"
        case .code(let language): language.displayName
        case .latex: "latex"
        case .orgMode: "org"
        case .mermaid: "mermaid"
        case .graphviz: "dot"
        default: nil
        }
    }

    private func saveComment(body: String, request: ReviewCommentSelectionRequest) -> Bool {
        if let saveError = comments.save(
            body: body,
            request: request,
            localScopeId: ReviewCommentLocalScope.controlDraft,
            sessionId: draftSessionId
        ) {
            presentError(saveError)
            return false
        }
        return true
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "Unable to Edit"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    private func createOrOpenRevisionSession() async {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        defer { isCreatingSession = false }

        do {
            guard let connection, let apiClient = connection.apiClient, let navigation = root?.navigation else {
                presentError("Server is offline")
                return
            }
            let sessionStore = connection.sessionStore
            let domain = domain
            let targetId = targetId
            let targetName = targetName
            let starterPrompt = starterPrompt
            let requestId = starterPromptRequestId

            let prepared = try await ControlRevisionSessionLaunchCoordinator.prepare(
                existingSession: createdSession,
                starterPromptDelivered: starterPromptDelivered,
                create: {
                    let response = try await apiClient.createControlSession(.init(
                        domain: domain,
                        intent: .revise,
                        targetId: targetId,
                        targetName: targetName,
                        name: "Revise \(targetName)",
                        prompt: starterPrompt,
                        launchIdempotencyKey: requestId
                    ))
                    return (
                        response.session,
                        response.prompted ?? (response.session.firstMessage != nil)
                    )
                },
                onSessionCreated: { [weak self] session, delivered in
                    self?.createdSession = session
                    self?.starterPromptDelivered = delivered
                    _ = sessionStore.cacheSessionForNavigation(session)
                }
            )
            let session = prepared.session
            starterPromptDelivered = prepared.starterPromptDelivered

            let sessionTarget = try ControlRevisionCommentNavigation.makeSessionTarget(
                serverId: connection.currentServerId,
                fallbackServerId: sessionStore.activeServerId,
                domain: domain,
                targetId: targetId,
                toSessionId: session.id,
                comments: comments
            )

            close()
            await Task.yield()
            navigation.openWorkspaceSession(sessionTarget)
        } catch {
            presentError("\(error.localizedDescription) Your staged comments are still saved.")
        }
    }

    /// Closes the screen this review is: the presented sheet, or the pushed page.
    private func close() {
        var screen: UIViewController = self
        while let parent = screen.parent, !(parent is UINavigationController) {
            screen = parent
        }
        Router.finish(screen)
    }
}
