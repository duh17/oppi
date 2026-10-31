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
/// as a sheet whose reader bar has the dismiss control and the document's edit
/// entry (a pencil and a "…" holding Edit with Session). A file on the server's
/// host shows in the file viewer with the stack's bar; a Skill's own file also
/// opens in the editor there. Edit with Session opens the guided revision sheet
/// with the staged comments as the request.
///
/// The pencil opens our editor on the document the subject names: an Agent's
/// prompt or a Schedule's prompt, saved through that record's version, or
/// nothing at all for text the app holds (the Pi prompt), which keeps the "…".
@MainActor
final class ReviewableControlMarkdownViewController: UIViewController, RouterModalContainer {
    private enum Viewer {
        /// Text the caller holds, in the full-screen reader; what it shows is
        /// `shownText`, so a draft or an edit can replace it.
        case fullScreen
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
    /// The real host file the revision names (`Selected existing host file`),
    /// nil when `sourcePath` is only a label for text the app holds.
    let targetPath: String?
    private let viewer: Viewer
    private let languageHint: String?
    /// The server whose records this reader edits, when the caller has it (an
    /// Agent's or a schedule's page does). Nil falls back to the active server.
    private let serverConnection: ServerConnection?
    /// What the edit entry edits. `.snapshot` means the text has no document
    /// behind it, so only Edit with Session is offered.
    let subject: DocumentEditSubject

    private let comments = ChatReviewCommentsController()
    private var guidedSessionHandoff = ControlRevisionSheetHandoff()
    private weak var guidedSheet: GuidedControlSessionViewController?
    private var loadedDraftSessionId: String?
    /// What the reader shows: the document the caller passed, and again what it
    /// is after an edit (read fresh from the record).
    private var shownText: String
    private var didReadEditSubject = false
    /// The document as the record holds it now, for after an edit: a prompt's
    /// reader shows the whole definition, not just the prompt.
    private let refreshDocument: (@MainActor () async -> String?)?

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
        targetPath: String? = nil,
        subject: DocumentEditSubject = .snapshot,
        connection: ServerConnection? = nil,
        refreshDocument: (@MainActor () async -> String?)? = nil
    ) {
        viewer = .fullScreen
        languageHint = "markdown"
        self.subject = subject
        self.serverConnection = connection
        self.refreshDocument = refreshDocument
        shownText = content
        self.domain = domain
        self.targetId = targetId
        self.targetName = targetName
        self.sourceLabel = sourceLabel
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        super.init(nibName: nil, bundle: nil)
    }

    /// A file at `hostFilePath` on the server, read directly from the host
    /// like any other host file: images, PDFs, and relative Markdown images
    /// work. Host files keep the stack's bar, so Edit is a bar item there;
    /// with `skillFile` the pencil opens the editor and the "…" holds Edit with
    /// Session.
    init(
        hostFilePath: String,
        serverId: String,
        title: String,
        skillFile: SkillFileEditTarget? = nil,
        domain: ControlSessionDomain,
        targetId: String,
        targetName: String,
        sourceLabel: String,
        connection: ServerConnection
    ) {
        viewer = .hostFile(serverId: serverId, title: title, skillFile: skillFile, connection: connection)
        languageHint = Self.languageHint(for: hostFilePath)
        subject = .snapshot
        serverConnection = connection
        refreshDocument = nil
        shownText = ""
        self.domain = domain
        self.targetId = targetId
        self.targetName = targetName
        self.sourceLabel = sourceLabel
        self.sourcePath = hostFilePath
        self.targetPath = hostFilePath
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var root: AppRootEnvironment? {
        AppRootEnvironment.near(self)
    }

    /// A skill file opens under its own server's scope; other targets live on
    /// the server the screen handed in, else the active one.
    private var connection: ServerConnection? {
        if case .hostFile(_, _, _, let connection) = viewer { return connection }
        return serverConnection ?? root?.coordinator.activeConnection
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

    /// The document's edit entry: a pencil for a prompt this screen can write
    /// back, and the "…" that holds Edit with Session. The owner picks the
    /// backend, titles and presents the editor, and holds the prompt's mode.
    private lazy var editOwner = makeEditOwner()

    private func makeEditOwner() -> DocumentEditOwner {
        DocumentEditOwner(
            subject: subject,
            // Read when the owner reads: a sheet can resolve its server after it
            // is built, and a nil captured here would hide the pencil for good.
            serverId: { [weak self] in
                self?.connection?.currentServerId ?? self?.connection?.sessionStore.activeServerId
            },
            agentAction: DocumentAgentEditAction { [weak self] in self?.presentGuidedRevision() },
            backend: { [weak self] in
                guard let self, let api = self.connection?.apiClient else { return nil }
                return .make(for: subject, api: api)
            },
            handlers: .init(
                didFinishEditing: { [weak self] in self?.reloadDocument() },
                didReload: { [weak self] in self?.setNeedsUpdateProperties() },
                makePreview: { [weak self] text in
                    guard let self else { return UIViewController() }
                    return FullScreenCodeViewController(
                        content: .markdown(content: text, filePath: sourcePath),
                        presentationMode: .contentOnly()
                    )
                }
            ),
            onChange: { [weak self] in self?.setNeedsUpdateProperties() }
        )
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
                skillFile: skillFile,
                agentEdit: DocumentAgentEditAction { [weak self] in self?.presentGuidedRevision() }
            ),
            services: .init(connection: connection)
        )
        self.fileViewer = fileViewer
        embed(fileViewer)
    }

    /// The full-screen reader, built once the sheet is in the window, where
    /// the app root (quick comments, the active server) is.
    private func embedReaderIfNeeded() {
        guard reader == nil, case .fullScreen = viewer else { return }
        let reader = FullScreenCodeViewController(
            content: .markdown(content: shownText, filePath: sourcePath),
            reviewCommentSelectionContext: selectionContext,
            editItems: editOwner.barItems
        )
        self.reader = reader
        embed(reader)
    }

    /// The document as the record holds it now: after an edit the reader shows
    /// the whole definition again, not the prompt alone. A kept draft never
    /// replaces it, so what the reader shows is always the document.
    private func reloadDocument() {
        guard let refreshDocument else {
            setNeedsUpdateProperties()
            return
        }
        Task { [weak self] in
            guard let self, let text = await refreshDocument() else { return }
            showText(text)
        }
    }

    /// The text the reader shows, when the document behind it changed.
    private func showText(_ text: String) {
        guard shownText != text else { return }
        shownText = text
        rebuildReader()
    }

    /// The reader is built for one body of text, so new text is a new reader.
    private func rebuildReader() {
        guard case .fullScreen = viewer, let reader else { return }
        reader.willMove(toParent: nil)
        reader.view.removeFromSuperview()
        reader.removeFromParent()
        self.reader = nil
        embedReaderIfNeeded()
        setNeedsUpdateProperties()
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
        startEditReadIfNeeded()
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
        if let fileViewer {
            fileViewer.bar.apply(to: navigationItem)
            return
        }
        reader?.setEditBarItems(editOwner.barItems)
        editOwner.presentEditorIfNeeded(from: self)
    }

    /// The host is removing this reader: hand the editor's buffer back first, so
    /// the session never keeps a provider over a freed text view.
    func finishEditing() {
        editOwner.finishEditing()
    }

    // MARK: The document

    /// One read of the document behind the prompt: the pencil appears only for a
    /// document the server answered for, and a kept draft opens the editor on
    /// itself without changing what the reader shows.
    private func startEditReadIfNeeded() {
        guard !didReadEditSubject, subject != .snapshot else { return }
        didReadEditSubject = true
        Task { [weak self] in
            guard let self else { return }
            _ = await editOwner.read()
            setNeedsUpdateProperties()
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

    private func presentGuidedRevision() {
        guard guidedSheet == nil, let connection, let root else { return }
        let configuration = GuidedControlComposerConfiguration(
            domain: domain,
            intent: .revise,
            targetId: targetId,
            targetName: targetName,
            targetPath: targetPath,
            // Staged comments are the request: they send with no text.
            allowsEmptyRequest: true,
            placeholder: "Describe how this \(domain.title) should change…",
            stagedComments: comments
        )
        let sheet = GuidedControlSessionViewController(
            configuration: configuration,
            root: root,
            // A skill file opens under its own server's scope, not
            // necessarily the active one.
            connection: { connection },
            onSessionPrepared: { [weak self] target in
                guard let self else { return }
                openRevisionSession(target, navigation: root.navigation)
            }
        )
        guidedSheet = sheet
        Router.present(
            sheet,
            presentation: .sheet.inNavigation(),
            from: self,
            theme: root.themeStore,
            onDismiss: { [weak self] in self?.completeGuidedSessionHandoff() }
        )
    }

    /// The screen to close when the revision session opens: this reader's own
    /// screen when it is presented as a sheet, nil when it is pushed on a
    /// stack (a Skill file), which stays under the chat.
    private var presentedReaderScreen: UIViewController? {
        var screen: UIViewController = self
        while let parent = screen.parent, !(parent is UINavigationController) {
            screen = parent
        }
        guard screen.navigationController == nil, screen.presentingViewController != nil else { return nil }
        return screen
    }

    /// Opens the revision session's chat. A presented reader finishes first,
    /// taking the guided sheet above it along, so the chat is not left under
    /// either sheet. A pushed reader closes only the guided sheet and keeps
    /// its place in the stack beneath the chat.
    func openRevisionSession(_ target: WorkspaceSessionNavTarget, navigation: AppNavigation) {
        guard let reader = presentedReaderScreen else {
            guidedSessionHandoff.prepare(target)
            closeGuidedRevision()
            return
        }
        Router.finish(reader)
        Task { @MainActor in
            await Task.yield()
            navigation.openWorkspaceSession(target)
        }
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
        errorAlerts.show(title: String(localized: "Unable to Edit"), message: message)
    }
}
