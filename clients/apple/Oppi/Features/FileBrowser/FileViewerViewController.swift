import Network
import UIKit

/// One file, read from where it lives and shown by type: text in the UIKit
/// reader (`FullScreenCodeViewController`) or the code editor, everything else
/// in the `FileRenderer` its preview category names (`FileRendererRegistry`).
/// Large text files ask before loading.
///
/// `.pushed` is a screen of its own: a file the reader shows (text, a book)
/// shows the reader's glass bar and hides the stack's, so the screen has one
/// bar (`readerOwnsBar`); other kinds and host files keep the stack's bar. `.treePane` sits beside a list or under a review header;
/// its Edit control is a bar item for the embedding screen (`bar`).
///
/// Re-showing the viewer (a full-screen modal over it, or a pop back from a
/// pushed wiki link) re-reads the file and rebuilds the reader only when its
/// text changed, so inline players survive; a missing or denied file replaces
/// stale text.
@MainActor
final class FileViewerViewController: UIViewController, NavigationBarHiding {
    struct Configuration {
        let workspaceId: String
        var worktreeId: String? = nil
        var serverId: String? = nil
        var filePath: String
        var fileName: String
        /// Replaces the bar title, as a Skill file names its path inside the Skill.
        var title: String? = nil
        var source: FileBrowserContentSource = .workspaceFile
        var sessionId: String? = nil
        var controlSessionId: String? = nil
        var workspaceRuntime: WorkspaceRuntime? = nil
        /// Known size from a directory listing; nil when opened elsewhere.
        var fileSize: Int? = nil
        var chromeMode: FileBrowserContentChromeMode = .pushed
        var allowsHorizontalBackSwipe = true
        var navigationContext: FileBrowserNavigationContext? = nil
        var lineAnchor: SourceLineAnchor? = nil
        var headingAnchor: ReaderHeadingAnchor? = nil
        var addToChatDestination: ComposerCanvasDestination? = nil
        /// Embedding review screens keep one staged-comment button of their
        /// own; the viewer must not draw a second one over previous-file.
        var showsReviewCommentStash = true
        /// Where selected-text comments go when the host owns them (a Skill
        /// file stages them for its revision session). Nil: `reviewCommentSelectionScope`.
        var reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil
        var reviewCommentSelectionScope: ReviewCommentSelectionScope? = nil
        /// A host file that is an editable Skill's own file. Only `.hostFile`.
        var skillFile: SkillFileEditTarget? = nil
        /// Edit with Session, offered beside the pencil by the edit entry.
        var agentEdit: DocumentAgentEditAction? = nil
        /// This viewer is the root of a trailing side pane: its reader names
        /// the file in a title and closes the pane with an X, not a back chevron.
        var isPaneRoot = false
        /// Read the file as Git stores it at this revision, not the working
        /// tree (a diff's Before or After of a file with no text diff). Never edited.
        var revision: String? = nil

        /// Reads the file the way its viewer does; reader resources resolve
        /// against the same origin. A list row shares its file through it too.
        var fileAccess: FileViewerFileAccess {
            FileViewerFileAccess(
                source: source,
                serverId: serverId,
                workspaceId: workspaceId,
                worktreeId: worktreeId,
                sessionId: sessionId,
                controlSessionId: controlSessionId,
                workspaceRuntime: workspaceRuntime,
                revision: revision
            )
        }
    }

    /// The server-scoped services the viewer reads through.
    struct Services {
        let apiClient: @MainActor () -> APIClient?
        let audioPlayer: AudioPlayerService?
        let sessionStore: SessionStore?
        /// The server's pins, where it keeps them, for the … menu's Pin.
        let pins: @MainActor () -> PinStore?

        init(connection: ServerConnection) {
            apiClient = { connection.apiClient }
            audioPlayer = connection.audioPlayer
            sessionStore = connection.sessionStore
            pins = { connection.pinsAvailable ? connection.pins : nil }
        }

        init(
            apiClient: APIClient?,
            audioPlayer: AudioPlayerService? = nil,
            sessionStore: SessionStore? = nil,
            pins: PinStore? = nil
        ) {
            self.apiClient = { apiClient }
            self.audioPlayer = audioPlayer
            self.sessionStore = sessionStore
            self.pins = { pins }
        }
    }

    private enum Phase: Equatable {
        case loading
        case sizeWarning(Int)
        /// A failed read; `retry` when reading again could succeed.
        case error(String, retry: Bool)
        /// The server has no file at the path (404): the pane's missing state.
        case missing
        case text(String)
        /// The file at `path`, loaded by its renderer. Every load passes
        /// through `.loading`, so only the same renderer compares equal.
        case rendered(any FileRenderer, path: String)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): true
            case (.sizeWarning(let a), .sizeWarning(let b)): a == b
            case (.error(let a, let retryA), .error(let b, let retryB)): a == b && retryA == retryB
            case (.missing, .missing): true
            case (.text(let a), .text(let b)): a == b
            case (.rendered(let a, _), .rendered(let b, _)): a === b
            default: false
            }
        }
    }

    /// What the page shows; a new key replaces the mounted content.
    private enum MountKey: Equatable {
        case phase(generation: Int)
        case sizeWarning(generation: Int, expensive: Bool)
        case editor(ObjectIdentifier)
    }

    private(set) var configuration: Configuration
    let bar = FileViewerBar()
    private let services: Services

    var onNavigationSelectionChange: ((FileBrowserSelection) -> Void)?
    /// Back from the reader's chevron or a swipe. Nil closes this screen.
    var onBackNavigation: (() -> Void)?
    var onLineAnchorNotice: (@MainActor @Sendable (String) -> Void)?
    /// The text editor opened or closed.
    var onEditingChange: ((Bool) -> Void)?
    /// The browser's shared positions, else the viewer's own: a remount (a task save) keeps the place.
    var markdownViewportRestore = FileBrowserViewportRestore()
    /// The Org headings folded in each file this viewer has shown, by ordinal.
    /// A save mounts a new reader, which starts from these.
    private var orgFolds: [String: Set<Int>] = [:]

    // MARK: State

    private var activeSelection: FileBrowserSelection?
    private var content: Phase = .loading {
        didSet {
            if content != oldValue {
                contentGeneration &+= 1
                if case .rendered(let renderer, _) = oldValue { renderer.release() }
            }
            setNeedsUpdateProperties()
        }
    }
    private var contentGeneration = 0
    /// Path whose text `content` holds, so a re-shown viewer revalidates instead of rebuilding.
    private var loadedTextPath: String?
    /// The host path the shown text resolved to; reader resources resolve against it.
    private var loadedHostFilePath: String?
    private var isExpensiveNetwork = false {
        didSet { if isExpensiveNetwork != oldValue { setNeedsUpdateProperties() } }
    }
    /// The API client of the last load, for reader resources and the editor.
    private var loadedApiClient: APIClient?
    /// The tagged read of the displayed bytes, the open editor, and the edit
    /// entry's bar items. One owner decides all three.
    private lazy var editOwner = makeEditOwner()
    private var reportedEditing = false
    /// While content loads, the stack's bar stays as the last settled content
    /// left it, so next/previous between two text files never slides it.
    private var settledHidesHostBar = false

    private var loadTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private(set) var isOnScreen = false

    // MARK: Views

    /// Clips the page while it slides to the next file.
    private let transitionView = UIView()
    /// The shown file: content and the motion marker. Moves as one page.
    private let pageView = UIView()
    private var mountedKey: MountKey?
    private var mountedView: UIView?
    private var mountedChildren: [UIViewController] = []
    /// Hosted SwiftUI leaves report their height through these; a leaf
    /// nothing holds stops resizing its slot.
    private var mountedBackSwipe: HorizontalBackSwipeGestureInstaller?
    weak var reader: FullScreenCodeViewController?
    private var sizeWarning: FileViewerSizeWarningView?
    /// The unavailable or failed state on screen, kept to repaint on a theme change.
    private var stateView: (view: UIContentUnavailableView, state: LoadState)?
    /// Under the reader: the reader's own page color, so the band below its
    /// safe area (the home indicator) does not show the viewer's lighter page.
    private var readerPage: UIView?
#if DEBUG
    private var motionMarker: FileMotionDebugMarker?
#endif
    private lazy var previousFileItem = makeAdjacentItem(.previous)
    private lazy var nextFileItem = makeAdjacentItem(.next)
    private let stashButton = ReviewCommentStashFloatingButton()

    // Bar items, kept while their inputs hold.
    private var shareItem: UIBarButtonItem?
    private var shareItemKey: Int?

    init(configuration: Configuration, services: Services) {
        self.configuration = configuration
        self.services = services
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows another file of the same origin in place: a list's new
    /// selection. The file previous/next already moved to stays as it is.
    func show(_ selection: FileBrowserSelection, navigationContext: FileBrowserNavigationContext?) {
        configuration.navigationContext = navigationContext
        let alreadyShown = selection.path == currentFilePath
        configuration.filePath = selection.path
        configuration.fileName = selection.name
        configuration.fileSize = selection.size
        activeSelection = nil
        setNeedsUpdateProperties()
        // Re-showing the file on screen (a tree refresh, a resize) keeps its
        // open editor and its session; another file's entry starts over before
        // its bytes are read, so no control outlives the previous file.
        guard !alreadyShown else { return }
        editOwner.begin(subject: editSubject(for: selection.path))
        content = .loading
        if isOnScreen { startLoad() }
    }

    var fileAccess: FileViewerFileAccess { configuration.fileAccess }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        transitionView.clipsToBounds = true
        let root: UIView = view
        for (subview, parent) in [(transitionView, root), (pageView, transitionView)] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: parent.topAnchor),
                subview.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            ])
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        // Like SwiftUI's `.task(id:)`: every appearance reads the file again.
        startLoad()
        networkTask?.cancel()
        networkTask = Task { [weak self] in await self?.checkNetworkCost() }
        if case .rendered(let renderer, _) = content {
            renderer.viewerDidAppear()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        loadTask?.cancel()
        loadTask = nil
        networkTask?.cancel()
        networkTask = nil
        if case .rendered(let renderer, _) = content {
            renderer.viewerDidDisappear()
            if renderer.retention == .releaseOffScreen { content = .loading }
        }
        if isLeaving {
            // Popped or dismissed: the editor hands its buffer to the session.
            editOwner.finishEditing()
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            editOwner.finishEditing()
        }
    }

    /// This viewer, or the screen it sits in, is going away rather than
    /// being covered.
    private var isLeaving: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isMovingFromParent || controller.isBeingDismissed { return true }
            current = controller.parent
        }
        return navigationController?.isBeingDismissed ?? false
    }

    override func updateProperties() {
        super.updateProperties()
        let themeID = AppRootEnvironment.near(self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = palette.ui.bg
        reconcileContent(palette: palette)
        updateMountedContent(palette: palette)
        updateFloatingControls(themeID: themeID)
        updateBar()
        updateHostNavigationBar(animated: true)
        let editing = editOwner.isEditing
        if editing != reportedEditing {
            reportedEditing = editing
            onEditingChange?(editing)
        }
    }

    // MARK: Derived state

    private var currentSelection: FileBrowserSelection {
        activeSelection ?? FileBrowserSelection(
            path: configuration.filePath,
            name: configuration.fileName,
            size: configuration.fileSize
        )
    }

    private var currentFilePath: String { currentSelection.path }
    private var currentFileName: String { currentSelection.name }

    private var viewerTitle: String {
        if let title = configuration.title { return title }
        return FileBrowserContentRenderingPolicy.navigationTitle(
            source: configuration.source,
            path: currentFilePath,
            fileName: currentFileName
        )
    }

    /// The reader shows the file: loaded text (not the editor), or the reader a
    /// renderer mounted for its kind (a book, `mountReader(_:)`).
    private var showsReader: Bool {
        switch content {
        case .text: !editOwner.isEditing
        case .rendered: reader != nil
        case .loading, .sizeWarning, .error, .missing: false
        }
    }

    /// The reader draws the screen's one bar: a pushed reader showing the file.
    /// The stack's bar hides, and the file's buttons go on the reader's (`fileBar(on:)`).
    private var readerOwnsBar: Bool {
        readerDrawsChrome && showsReader
    }

    private func readerPresentationMode(
        back: @escaping @MainActor @Sendable () -> Void
    ) -> FullScreenCodeViewController.PresentationMode {
        guard readerDrawsChrome else { return .contentOnly(onBackSwipe: back) }
        return configuration.isPaneRoot ? .pane(title: viewerTitle, onDismiss: back) : .embedded(onDismiss: back)
    }

    /// A reader here draws its own glass bar and Back; else it is content only
    /// and this viewer's bar carries everything (host files, a tree pane).
    private var readerDrawsChrome: Bool {
        FileBrowserContentRenderingPolicy.readerDrawsChrome(
            for: configuration.chromeMode,
            source: configuration.source
        )
    }

    private func makeEditOwner() -> DocumentEditOwner {
        DocumentEditOwner(
            subject: .snapshot,
            agentAction: configuration.agentEdit,
            backend: { [weak self] in
                guard let self, let api = loadedApiClient ?? services.apiClient() else { return nil }
                return .api(api)
            },
            reviewCommentSelectionScope: configuration.reviewCommentSelectionScope,
            handlers: .init(
                // The file's reader shows the text the editor left, and the viewer
                // reloads what it must (a deleted file's draft discarded).
                didFinishEditing: { [weak self] in
                    guard let self, let session = editOwner.session else { return }
                    content = .text(session.currentText)
                },
                didReload: { [weak self] in self?.startLoad(force: true) },
                makePreview: { [weak self] text in
                    guard let self else { return UIViewController() }
                    return FullScreenCodeViewController(
                        content: fullScreenContent(text: text),
                        presentationMode: .contentOnly()
                    )
                }
            ),
            onChange: { [weak self] in self?.setNeedsUpdateProperties() }
        )
    }

    /// What the edit entry sees of the file at `path`, read in the context of the session this
    /// viewer came from. Only the file it was opened for reads as its Skill's own file.
    private func editSubject(for path: String) -> DocumentEditSubject {
        if configuration.revision != nil { return .snapshot }
        return .file(
            serverId: configuration.serverId,
            source: configuration.source,
            workspaceId: configuration.workspaceId,
            worktreeId: configuration.worktreeId,
            path: path,
            skillFile: path == configuration.filePath ? configuration.skillFile : nil,
            fileKind: FileKind.detect(from: path),
            context: FileEditReadContext(sessionId: configuration.sessionId, controlSessionId: configuration.controlSessionId)
        )
    }

    /// Text and renderers that say so own the back swipe; the viewer handles it for the rest.
    private var parentOwnsBackSwipe: Bool {
        switch content {
        case .text: false
        case .rendered(let renderer, _): !renderer.ownsBackSwipe
        case .loading, .sizeWarning, .error, .missing: true
        }
    }

    var readerSelectionContext: ReviewCommentSelectionContext? {
        configuration.reviewCommentSelectionContext
            ?? configuration.reviewCommentSelectionScope?.makeContext(sessionId: configuration.sessionId)
    }

    private func adjacentSelection(_ direction: FileBrowserNavigationDirection) -> FileBrowserSelection? {
        configuration.navigationContext?.selection(adjacentTo: currentFilePath, direction: direction)
    }

    private var canGoPrevious: Bool { !editOwner.isEditing && adjacentSelection(.previous) != nil }
    private var canGoNext: Bool { !editOwner.isEditing && adjacentSelection(.next) != nil }

    /// Previous and next file as reader bar actions, where there is one.
    /// Horizontal swipes stay reserved for Back.
    private var adjacentOffers: [ReaderBarAction: [UIBarButtonItem]] {
        var offers: [ReaderBarAction: [UIBarButtonItem]] = [:]
        if canGoPrevious { offers[.previousFile] = [previousFileItem] }
        if canGoNext { offers[.nextFile] = [nextFileItem] }
        return offers
    }

    private func makeAdjacentItem(_ direction: FileBrowserNavigationDirection) -> UIBarButtonItem {
        let action: ReaderBarAction = direction == .previous ? .previousFile : .nextFile
        let item = UIBarButtonItem(
            title: action.label,
            image: UIImage(systemName: action.systemImage),
            primaryAction: UIAction { [weak self] _ in self?.navigateToAdjacentFile(direction) }
        )
        item.accessibilityLabel = direction == .previous ? "Previous file" : "Next file"
        item.accessibilityIdentifier = direction == .previous ? "fileViewer.previous" : "fileViewer.next"
        return item
    }

    private enum BarHolder { case viewer, reader }

    /// The file's buttons and … menu items, on the one bar that shows them:
    /// the reader's while it owns the screen's bar (`readerOwnsBar`), else this
    /// viewer's. Nothing while the editor owns the bar.
    private func fileBar(on holder: BarHolder) -> (offers: [ReaderBarAction: [UIBarButtonItem]], menu: [UIMenuElement]) {
        guard (holder == .reader) == readerOwnsBar, !editOwner.isEditing else { return ([:], []) }
        // The previous and next file are on every file's bar.
        var offers = adjacentOffers
        var menu: [UIMenuElement] = []
        // Edit, the content-only reader's own buttons (Find, Copy, …), and the
        // … menu (Open in Pane, Pin) wait for the file to load. A pushed
        // viewer's own bar (an image, PDF, video, or file card) has none of them.
        let loading: Bool = if case .loading = content { true } else { false }
        if !loading, holder == .reader || !readerDrawsChrome {
            offers.merge(editOwner.readerOffers) { own, _ in own }
            if holder == .viewer { offers.merge(reader?.barOffers ?? [:]) { own, _ in own } }
            menu = documentMenu
        }
        // A text reader shares the text it shows; a book shares the archive
        // only this viewer read.
        let readerSharesText: Bool = if holder == .reader, case .text = content { true } else { false }
        if !readerSharesText, let share = shareBarItem() { offers[.share] = [share] }
        return (offers, menu)
    }

    // MARK: Content

    private var wantedKey: MountKey {
        switch content {
        case .sizeWarning:
            return .sizeWarning(generation: contentGeneration, expensive: isExpensiveNetwork)
        case .text:
            if let session = editOwner.session, editOwner.isEditing { return .editor(ObjectIdentifier(session)) }
            return .phase(generation: contentGeneration)
        default:
            return .phase(generation: contentGeneration)
        }
    }

    private func reconcileContent(palette: ThemePalette) {
        let key = wantedKey
        guard key != mountedKey else { return }
        unmountContent()
        mountedKey = key
        let mounted: UIView
        switch content {
        case .loading:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            mounted = centered(spinner)
        case .sizeWarning(let bytes):
            let warning = FileViewerSizeWarningView(
                fileName: currentFileName,
                bytes: bytes,
                isExpensiveNetwork: isExpensiveNetwork,
                palette: palette
            ) { [weak self] in self?.startLoad(force: true) }
            addPage(warning)
            sizeWarning = warning
            mounted = warning
        case .error(let message, let retry):
            mounted = unavailable(.failed(
                title: String(localized: "Unable to Load"),
                message: message,
                retry: retry ? RetryAction { [weak self] in self?.startLoad(force: true) } : nil
            ))
        case .missing:
            mounted = unavailable(.paneMissing(.file, retry: RetryAction { [weak self] in self?.startLoad(force: true) }))
        case .text(let text):
            if let page = editOwner.makeEditorPage(checkoutSubtitle: checkoutSubtitle), editOwner.isEditing {
                mounted = mountEditor(page)
            } else {
                mounted = mountReader(text: text)
            }
        case .rendered(let renderer, _):
            mounted = renderer.mount(in: self)
        }
        mountedView = mounted
        if FileBrowserContentRenderingPolicy.shouldInstallHorizontalBackSwipe(
            allowsHorizontalBackSwipe: configuration.allowsHorizontalBackSwipe,
            parentOwnsBackSwipe: parentOwnsBackSwipe
        ) {
            let installer = HorizontalBackSwipeGestureInstaller { [weak self] in self?.navigateBack() }
            installer.install(on: backSwipeTarget(in: mounted))
            mountedBackSwipe = installer
        }
#if DEBUG
        if FileMotionDebugMarker.isEnabled {
            let marker = FileMotionDebugMarker(path: currentFilePath)
            marker.translatesAutoresizingMaskIntoConstraints = false
            pageView.addSubview(marker)
            NSLayoutConstraint.activate([
                marker.topAnchor.constraint(equalTo: pageView.safeAreaLayoutGuide.topAnchor),
                marker.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
                marker.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            ])
            motionMarker = marker
        }
#endif
    }

    /// The image page scrolls; the swipe belongs on its scroll view.
    private func backSwipeTarget(in mounted: UIView) -> UIView {
        mounted.subviews.first { $0 is UIScrollView } ?? mounted
    }

#if DEBUG
    /// Test seam: the open editor's bar items, so a test can resolve the
    /// Editor Options menu the way the menu itself does.
    var editorBarItemsForTesting: WorkspaceFileEditBarItems? { editOwner.editorPage?.barItems }
#endif

    private func unmountContent() {
        editOwner.finishEditing()
        for child in mountedChildren {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        mountedChildren = []
        mountedView?.removeFromSuperview()
        mountedView = nil
        mountedBackSwipe = nil
        reader = nil
        sizeWarning = nil
        stateView = nil
        readerPage = nil
#if DEBUG
        motionMarker?.removeFromSuperview()
        motionMarker = nil
#endif
    }

    func mountChild<Attached>(_ controller: UIViewController, attach: () -> Attached) -> Attached {
        addChild(controller)
        let attached = attach()
        controller.didMove(toParent: self)
        mountedChildren.append(controller)
        return attached
    }

    /// A full-page container on `pageView`, inside the safe area unless asked.
    func addPage(_ page: UIView) {
        page.translatesAutoresizingMaskIntoConstraints = false
        pageView.insertSubview(page, at: 0)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pageView.topAnchor),
            page.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
        ])
    }

    private func centered(_ subview: UIView) -> UIView {
        let page = UIView()
        addPage(page)
        subview.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.centerXAnchor.constraint(equalTo: page.safeAreaLayoutGuide.centerXAnchor),
            subview.centerYAnchor.constraint(equalTo: page.safeAreaLayoutGuide.centerYAnchor),
        ])
        return page
    }

    func unavailable(_ state: LoadState) -> UIView {
        let unavailable = makeStateView(state)
        addPage(unavailable)
        return unavailable
    }

    func makeStateView(_ state: LoadState) -> UIContentUnavailableView {
        let view = UIContentUnavailableView(
            configuration: .loadState(state, palette: ThemeRuntimeState.currentPalette())
        )
        stateView = (view, state)
        return view
    }

    func removeStateView() {
        stateView?.view.removeFromSuperview()
        stateView = nil
    }

    private func mountReader(text: String) -> UIView {
        let path = currentFilePath
        let back: @MainActor @Sendable () -> Void = { [weak self] in self?.navigateBack() }
        let file = fileBar(on: .reader)
        let reader = FullScreenCodeViewController(
            content: fullScreenContent(text: text),
            presentationMode: readerPresentationMode(back: back),
            reviewCommentSelectionContext: readerSelectionContext,
            lineAnchor: activeSelection == nil ? configuration.lineAnchor : nil,
            lineAnchorNotice: onLineAnchorNotice,
            headingAnchor: activeSelection == nil ? configuration.headingAnchor : nil,
            hostOffers: file.offers,
            hostMenu: file.menu,
            markdownViewportIntent: markdownViewportRestore.state[path],
            onMarkdownViewportIntentChange: { [weak self] in self?.markdownViewportRestore.state[path] = $0 },
            taskEditing: editOwner.makeReaderTaskEditing(path: path) { [weak self] text in if self?.isCurrentFile(path) == true { self?.content = .text(text) } },
            orgFolds: OrgFoldMemory(folded: orgFolds[path] ?? []) { [weak self] in self?.orgFolds[path] = $0 },
            addToChatDestination: configuration.addToChatDestination
        )
        return mountReaderPage(reader)
    }

    func mountReader(_ content: FullScreenCodeContent) -> UIView {
        let back: @MainActor @Sendable () -> Void = { [weak self] in self?.navigateBack() }
        return mountReaderPage(FullScreenCodeViewController(
            content: content,
            presentationMode: readerPresentationMode(back: back),
            reviewCommentSelectionContext: readerSelectionContext,
            addToChatDestination: configuration.addToChatDestination
        ))
    }

    private func mountReaderPage(_ reader: FullScreenCodeViewController) -> UIView {
        // Without a bar of its own, the reader's Find, Outline, Copy, source
        // toggle, and Viewing Options join this viewer's (`updateBar`).
        reader.onBarOffersChange = { [weak self] in self?.updateBar() }
        let page = UIView()
        addPage(page)
        mountChild(reader) {
            reader.view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(reader.view)
            let safe = page.safeAreaLayoutGuide
            // The reader's own glass bar sits at the top of a pushed screen,
            // and its side rail (the Duo's) at the screen's edge: the reader
            // spans the page and keeps its text and controls in its own safe area.
            NSLayoutConstraint.activate([
                reader.view.topAnchor.constraint(
                    equalTo: readerDrawsChrome ? page.topAnchor : safe.topAnchor
                ),
                reader.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                reader.view.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                reader.view.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            ])
        }
        self.reader = reader
        readerPage = page
        return page
    }

    /// Hosts the edit entry's editor page: the page draws its own header
    /// (checkout, conflict banner, notice) and owns the editor and its bar.
    private func mountEditor(_ editorPage: DocumentEditEditorPage) -> UIView {
        let page = UIView()
        addPage(page)
        mountChild(editorPage) {
            editorPage.view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(editorPage.view)
            NSLayoutConstraint.activate([
                editorPage.view.topAnchor.constraint(equalTo: page.topAnchor),
                editorPage.view.bottomAnchor.constraint(equalTo: page.bottomAnchor),
                editorPage.view.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                editorPage.view.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            ])
        }
        return page
    }

    /// A page that owns the back swipe handles back itself when the host allows the swipe.
    func installOwnBackSwipe(on view: UIView) {
        guard configuration.allowsHorizontalBackSwipe else { return }
        let installer = HorizontalBackSwipeGestureInstaller { [weak self] in self?.navigateBack() }
        installer.install(on: view)
        mountedBackSwipe = installer
    }

    /// Updates what stays mounted: the reader's Edit action and floating
    /// counts, the editor's preview and replacement, its header, the
    /// renderer's own state, and the theme colors of the pages this viewer draws.
    private func updateMountedContent(palette: ThemePalette) {
        sizeWarning?.apply(palette)
        if let stateView {
            stateView.view.configuration = UIContentUnavailableConfiguration.loadState(stateView.state, palette: palette)
        }
        readerPage?.backgroundColor = palette.ui.bgDark
        if let reader {
            let file = fileBar(on: .reader)
            reader.setHostBar(offers: file.offers, menu: file.menu)
        }
        editOwner.updateEditorPage(palette: palette, checkoutSubtitle: checkoutSubtitle)
        if case .rendered(let renderer, _) = content {
            renderer.updateMounted(palette: palette)
        }
    }

    private func updateFloatingControls(themeID: ThemeID) {
        // The reader draws its own staged-comment button.
        let usesReaderStash: Bool = if case .text = content { true } else { false }
        stashButton.update(
            on: view,
            presenter: self,
            stash: configuration.showsReviewCommentStash && !usesReaderStash
                ? configuration.reviewCommentSelectionScope?.router.stash
                : nil,
            leadingAccessoryCount: 0,
            palette: themeID.palette
        )
    }

    // MARK: Bar

    private func updateBar() {
        let editing = editOwner.isEditing
        let file = fileBar(on: .viewer)
        bar.reader.presenter = self
        if bar.title != viewerTitle { bar.title = viewerTitle }
        // The editor owns the bar while typing: status, Preview, Done.
        bar.show(
            offers: file.offers, documentActions: file.menu,
            editorItems: editing ? editOwner.barItems : [], isEditing: editing
        )
        bar.apply(to: navigationItem)
    }

    /// The … menu's document actions: the editor's, then Open in New Pane
    /// and Open in Pane ▸ for this file on a window wide enough for panes,
    /// then Pin or Unpin.
    private var documentMenu: [UIMenuElement] {
        let pin: [UIMenuElement] = pinTarget != nil && services.pins() != nil ? [pinMenu] : []
        return (paneFile == nil ? editOwner.menuActions : editOwner.menuActions + [paneMenu]) + pin
    }

    /// Read when the menu opens: Pin or Unpin for the file shown then.
    private lazy var pinMenu = makePinMenu()

    private func makePinMenu() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated { completion(self?.pinMenuElements() ?? []) }
        }
    }

    private func pinMenuElements() -> [UIMenuElement] {
        guard let target = pinTarget, let pins = services.pins(), let api = services.apiClient(), let view = viewIfLoaded else {
            return []
        }
        return [PinMenu.toggle(
            route: target, identifiers: ("fileBrowser.pin.add", "fileBrowser.pin.remove"),
            pins: pins, api: api, view: view
        ).action]
    }

    /// The file as a pin names it: a main-checkout workspace file, or a home
    /// file written `~/…`. Nil for anything a pin cannot name.
    private var pinTarget: PaneRoute? {
        guard configuration.revision == nil else { return nil }
        let path = currentFilePath
        switch configuration.source {
        case .workspaceFile where configuration.worktreeId == nil && !path.hasPrefix("/"):
            return .file(.workspace(id: configuration.workspaceId, worktree: nil), path: path, line: nil)
        case .hostFile where path.hasPrefix("~/"):
            return .file(.host, path: path, line: nil)
        default:
            return nil
        }
    }

    /// Built when the menu opens, from the panes the window has then. One
    /// element, so the bar sees the same menu while nothing else changed.
    private lazy var paneMenu = makePaneMenu()

    private func makePaneMenu() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            // The menu asks on the main thread.
            MainActor.assumeIsolated { completion(self?.paneMenuElements() ?? []) }
        }
    }

    private func paneMenuElements() -> [UIMenuElement] {
        guard let view = viewIfLoaded else { return [] }
        return PaneOpenMenu.items(near: view, includesOpenHere: false) { [weak self] placement in
            guard let self, let file = paneFile, let view = viewIfLoaded else { return }
            PaneOpenMenu.open(placement, from: view) { PaneOpenContent(file: file) }
        }.map(\.element)
    }

    /// The file shown now as a pane opens it, from the same origin; nil for a
    /// revision or a session-touched file, which a pane cannot name.
    private var paneFile: WorkspaceLinkedFileNavTarget? {
        guard configuration.revision == nil, let serverId = configuration.serverId else { return nil }
        let path = currentFilePath
        switch configuration.source {
        case .workspaceFile:
            return .workspaceFile(
                serverId: serverId, workspaceId: configuration.workspaceId, worktreeId: configuration.worktreeId,
                path: path, lineAnchor: activeSelection == nil ? configuration.lineAnchor : nil,
                sourceSessionId: configuration.sessionId
            )
        case .sessionFile(let sessionId):
            return .sessionFile(
                serverId: serverId, workspaceId: configuration.workspaceId, sessionId: sessionId, path: path,
                sourceSessionId: configuration.sessionId
            )
        case .hostFile:
            return .hostFile(
                serverId: serverId, workspaceId: configuration.workspaceId, path: path,
                sourceSessionId: configuration.sessionId, controlSessionId: configuration.controlSessionId
            )
        case .sessionTouched:
            return nil
        }
    }

    private func shareBarItem() -> UIBarButtonItem? {
        if shareItemKey == contentGeneration, let shareItem { return shareItem }
        shareItemKey = contentGeneration
        shareItem = switch content {
        case .text(let text): ShareableFile.loaded(.fromText(text, filePath: currentFilePath)).barItem(from: self)
        case .rendered(let renderer, _): renderer.share.barItem(from: self)
        case .loading, .sizeWarning, .error, .missing: nil
        }
        return shareItem
    }

    /// The stack's bar hides while the reader shows its own (`readerOwnsBar`). The
    /// stack asks as this viewer's screen comes forward; content that changes
    /// the answer while it is in front calls `updateHostNavigationBar`.
    var hidesNavigationBar: Bool {
        guard configuration.chromeMode == .pushed else { return false }
        if case .loading = content { return settledHidesHostBar }
        return readerOwnsBar
    }

    private func updateHostNavigationBar(animated: Bool) {
        guard configuration.chromeMode == .pushed else { return }
        if case .loading = content {} else { settledHidesHostBar = readerOwnsBar }
        navigationController?.updateNavigationBar(for: self, animated: animated && isOnScreen)
    }

    /// The controller in the navigation stack: this viewer, or the screen
    /// that embeds it.
    private var stackScreen: UIViewController {
        var current: UIViewController = self
        while let parent = current.parent, !(parent is UINavigationController) {
            current = parent
        }
        return current
    }

    // MARK: Editing

    /// Where the file writes to, shown above the open editor: a worktree, or
    /// the main checkout of a session that runs on one.
    private var checkoutSubtitle: String? {
        FileBrowserContentRenderingPolicy.checkoutSubtitle(
            source: configuration.source,
            worktreeId: configuration.worktreeId,
            sessionWorktreeId: configuration.sessionId.flatMap { services.sessionStore?.session(id: $0) }
                .flatMap { $0.workspaceId == configuration.workspaceId ? $0.worktreeId : nil }
        )
    }

    // MARK: Loading

    /// Threshold for showing a file size warning (1 MB).
    private static let sizeWarningThreshold = 1_024 * 1_024

    private func startLoad(force: Bool = false) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadContent(force: force) }
    }

    private func loadContent(force: Bool = false) async {
        guard let api = services.apiClient() else {
            content = .error(String(localized: "Not connected"), retry: true)
            return
        }
        // Reappearing over an open editor must not reload over the buffer (subjects, not the canonical identity).
        if editOwner.isEditing, editOwner.identity != nil,
           editOwner.subject == editSubject(for: currentSelection.path) {
            return
        }

        let requestedSelection = currentSelection
        let requestedPath = requestedSelection.path
        let requestedCategory = FileKind.detect(from: requestedPath).previewCategory
        if !force, case .rendered(let renderer, let path) = content,
           renderer.retention == .keepOnReshow, path == requestedPath {
            return
        }

        loadedApiClient = api
        // The read that follows adopts whatever this file's edit entry resolves:
        // a tagged read and a live or kept draft, or nothing to edit at all.
        editOwner.begin(subject: editSubject(for: requestedPath))

        // Every re-show reads again: after AVKit fullscreen from an inline
        // Markdown video, or a pop back from a pushed wiki link. Rebuilding the
        // reader there recreates every inline player, so re-read first and
        // rebuild only when the shown text changed. Transient failures keep its
        // inline players; missing or denied files must not show stale text.
        if !force, loadedTextPath == requestedPath, case .text(let shownText) = content {
            do {
                guard let read = try await readText(api: api, path: requestedPath) else { return }
                if case .bytes(let data, let editedText, _) = read,
                   readerText(data: data, editedText: editedText, path: requestedPath) == shownText {
                    return
                }
            } catch {
                guard isCurrentFile(requestedPath),
                      Self.isHTTPError(error, statusCodes: [401, 403, 404]) else { return }
                loadedTextPath = nil
                loadedHostFilePath = nil
                content = Self.failure(error)
                return
            }
        }

        // For text files with known size above threshold, show a warning first.
        if !force, requestedCategory == .text,
           let size = requestedSelection.size, size > Self.sizeWarningThreshold {
            content = .sizeWarning(size)
            return
        }

        loadedTextPath = nil
        loadedHostFilePath = nil
        content = .loading

        do {
            if let renderer = FileRendererRegistry.renderer(for: requestedCategory) {
                guard let rendered = try await renderer.load(renderInput(api: api, path: requestedPath)) else { return }
                showMeasured(.rendered(rendered, path: requestedPath), bytes: requestedSelection.size) {
                    "\(requestedCategory)"
                }
                await rendered.finishLoading()
                return
            }
            guard let read = try await readText(api: api, path: requestedPath) else { return }
            switch read {
            case .deletedDraft(let text):
                // Gone on the server: a kept draft reopens in the
                // non-writing deleted state instead of an error page.
                content = .text(text)
            case .bytes(let data, let editedText, let resolvedHostPath):
                if let resolvedHostPath {
                    loadedHostFilePath = resolvedHostPath
                }
                if let text = readerText(data: data, editedText: editedText, path: requestedPath) {
                    loadedTextPath = requestedPath
                    showMeasured(.text(text), bytes: data.count) {
                        FullScreenCodeContent.fromText(text, filePath: requestedPath).kindName
                    }
                    return
                }
                // Bytes the reader cannot show open as the category their path
                // names: a host web page as an image, anything else as binary.
                let category: FilePreviewCategory = showsAsWebString(requestedPath) ? .image : .binary
                guard let renderer = FileRendererRegistry.renderer(for: category),
                      let rendered = try await renderer.load(renderInput(api: api, path: requestedPath, preread: data))
                else { return }
                content = .rendered(rendered, path: requestedPath)
            }
        } catch {
            guard isCurrentFile(requestedPath) else { return }
            // Text over the server's limit for a whole read opens as a file
            // card, which shares or saves it without reading it into memory.
            if Self.isHTTPError(error, statusCodes: [413]), requestedCategory == .text {
                let notice = String(localized: "Too large to show here. Share it, save it to Files, or open it in another app.")
                do {
                    if let card = try await BinaryFileRenderer.load(
                        renderInput(api: api, path: requestedPath, notice: notice)
                    ) {
                        content = .rendered(card, path: requestedPath)
                    }
                    return
                } catch {
                    guard isCurrentFile(requestedPath) else { return }
                    content = Self.failure(error)
                    return
                }
            }
            content = Self.failure(error)
        }
    }

    /// The page for a failed read: the missing state for a file the server
    /// does not have, else the error, with Retry only when reading again
    /// could succeed. A refusal the server repeats for the same request (a
    /// 4xx other than a timeout or rate limit) offers none.
    private static func failure(_ error: Error) -> Phase {
        if isHTTPError(error, statusCodes: [404]) { return .missing }
        let refused = isHTTPError(error, statusCodes: Set(400..<500).subtracting([408, 429]))
        return .error(error.localizedDescription, retry: !refused)
    }

    /// Shows a freshly read file and records `app.file_open`: how long mounting
    /// and laying it out took, and the footprint before and 2 s after, once its
    /// drawing and any deferred render have landed. A file of unknown size, or
    /// one the person left within those 2 s, is not recorded. No path or name
    /// leaves the device: only the shown kind and a size bucket.
    private func showMeasured(_ loaded: Phase, bytes: Int?, kind: () -> String) {
        let footprintBefore = AppDiagnosticsService.currentFootprintMB()
        let start = ContinuousClock.now
        content = loaded
        updatePropertiesIfNeeded()
        view.layoutIfNeeded()
        let elapsed = start.duration(to: .now).components
        let durationMs = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        guard let bytes else { return }
        let kind = kind()
        let path = currentFilePath
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, currentFilePath == path, content == loaded else { return }
            Telemetry.record(AppFileOpen(
                durationMs: durationMs,
                footprintBeforeMb: footprintBefore.map(Double.init),
                footprintAfterMb: AppDiagnosticsService.currentFootprintMB().map(Double.init),
                contentType: kind,
                inputSize: TelemetryTag.InputSize(bytes: bytes)
            ))
        }
    }

    private func renderInput(
        api: APIClient,
        path: String,
        preread: Data? = nil,
        notice: String? = nil
    ) -> FileRenderInput {
        FileRenderInput(
            api: api,
            currentAPI: services.apiClient,
            access: fileAccess,
            path: path,
            fileName: currentFileName,
            audioPlayer: services.audioPlayer,
            preread: preread,
            listedSize: currentSelection.path == path ? currentSelection.size : nil,
            notice: notice,
            isCurrent: { [weak self] in self?.isCurrentFile(path) ?? false }
        )
    }

    private enum ReaderRead {
        case bytes(Data, editedText: String?, resolvedHostPath: String?)
        /// The file is gone; its kept draft opens in the editor.
        case deletedDraft(String)
    }

    /// One read of a text file. Editable text goes through the edit entry's
    /// tagged read, so a live or recovered draft wins over disk. Nil when the
    /// person moved to another file meanwhile.
    private func readText(api: APIClient, path: String) async throws -> ReaderRead? {
        switch await editOwner.read() {
        case .ownRead:
            break
        case .deletedDraft(let text):
            guard isCurrentFile(path) else { return nil }
            return .deletedDraft(text)
        case .bytes(let snapshot, let draftText):
            guard isCurrentFile(path) else { return nil }
            return .bytes(snapshot.bytes, editedText: draftText, resolvedHostPath: editOwner.resolvedHostPath)
        }
        guard let read = try await renderInput(api: api, path: path).bytes() else { return nil }
        return .bytes(read.data, editedText: nil, resolvedHostPath: read.resolvedHostPath)
    }

    /// A host HTML or SVG file, which the reader shows from its fetched string.
    private func showsAsWebString(_ path: String) -> Bool {
        configuration.source == .hostFile && HostFilePreviewPolicy.usesStringFetchViewer(for: path)
    }

    /// The text the reader shows, or nil when the bytes are not text it shows.
    /// Only text-category files get here, so a web string is HTML; its edit
    /// draft does not apply.
    private func readerText(data: Data, editedText: String?, path: String) -> String? {
        if showsAsWebString(path) {
            return String(data: data, encoding: .utf8)
        }
        return editedText ?? String(data: data, encoding: .utf8)
    }

    /// Reader content with the file's origin, for relative images, media,
    /// 3D scenes, and captions.
    private func fullScreenContent(text: String) -> FullScreenCodeContent {
        fileAccess.fullScreenContent(
            text: text,
            sourcePath: loadedHostFilePath ?? currentFilePath,
            api: loadedApiClient ?? services.apiClient(),
            audioPlayer: services.audioPlayer
        )
    }

    private func isCurrentFile(_ requestedPath: String) -> Bool {
        !Task.isCancelled && currentFilePath == requestedPath
    }

    private static func isHTTPError(_ error: Error, statusCodes: Set<Int>) -> Bool {
        switch error {
        case APIError.server(let status, _), APIError.codedServer(let status, _, _):
            return statusCodes.contains(status)
        default:
            return false
        }
    }

    /// One-shot check for an expensive network (cellular, hotspot).
    private func checkNetworkCost() async {
        let expensive = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.isExpensive)
            }
            monitor.start(queue: DispatchQueue(label: "com.oppi.file-browser-net-check"))
        }
        guard !Task.isCancelled else { return }
        isExpensiveNetwork = expensive
    }

    // MARK: Navigation

    private func navigateToAdjacentFile(_ direction: FileBrowserNavigationDirection) {
        guard let next = adjacentSelection(direction) else { return }
        let spec = FileBrowserPushTransitionPolicy.directionalSpec(
            for: direction,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )
        let outgoing = spec == nil ? nil : pageView.snapshotView(afterScreenUpdates: false)
        activeSelection = next
        content = .loading
        onNavigationSelectionChange?(next)
        startLoad()
        updatePropertiesIfNeeded()
        guard let spec, let outgoing else { return }
        outgoing.frame = pageView.frame
        transitionView.addSubview(outgoing)
        let width = transitionView.bounds.width
        let flip: CGFloat = view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
        func offset(_ edge: FileBrowserPushTransitionEdge) -> CGAffineTransform {
            CGAffineTransform(translationX: (edge == .trailing ? width : -width) * flip, y: 0)
        }
        pageView.transform = offset(spec.insertion)
        pageView.alpha = 0
        UIView.animate(
            withDuration: FileBrowserPushTransitionPolicy.duration,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) { [pageView] in
            pageView.transform = .identity
            pageView.alpha = 1
            outgoing.transform = offset(spec.removal)
            outgoing.alpha = 0
        } completion: { _ in
            outgoing.removeFromSuperview()
        }
    }

    /// Back: the host's action, else close the screen the viewer is.
    func navigateBack() {
        if let onBackNavigation {
            onBackNavigation()
            return
        }
        Router.finish(stackScreen)
    }
}

extension FileViewerViewController: FileRendererHost {}

/// The file viewer the Files screen (`FileBrowserViewController`) shows:
/// beside the tree (`make`), or pushed above the list (`pushReader`).
@MainActor
enum FileBrowserViewerFactory {
    /// One file of the browser, read on the browser's server.
    struct Request {
        let workspaceId: String
        let worktreeId: String?
        let serverId: String?
        let source: FileBrowserContentSource
        let selection: FileBrowserSelection
        let navigationContext: FileBrowserNavigationContext?
        let services: FileBrowserServices
        let viewportRestore: FileBrowserViewportRestore
    }

    /// The open file beside the tree, or alone when a column selection is
    /// kept in compact width, as a child controller. Its bar items (Edit,
    /// the editor's controls) are in `bar` for the browser's bar; another
    /// selection on the same server goes through `show(_:navigationContext:)`.
    static func make(
        _ request: Request,
        onSelectionChange: @escaping (FileBrowserSelection) -> Void,
        onBack: @escaping () -> Void
    ) -> FileViewerViewController {
        let viewer = viewer(request, chromeMode: .treePane)
        viewer.onNavigationSelectionChange = onSelectionChange
        viewer.onBackNavigation = onBack
        return viewer
    }

    /// The viewer as its own screen above the browser: host files, and every
    /// file of the chat panel.
    static func pushReader(_ request: Request, from host: UIViewController) {
        Router.push(viewer(request, chromeMode: .pushed), from: host)
    }

    /// The viewer's file, origin, and review scope (the chat's, in its file
    /// panel) for `request`.
    static func configuration(
        _ request: Request,
        chromeMode: FileBrowserContentChromeMode
    ) -> FileViewerViewController.Configuration {
        FileViewerViewController.Configuration(
            workspaceId: request.workspaceId,
            worktreeId: request.worktreeId,
            serverId: request.serverId,
            filePath: request.selection.path,
            fileName: request.selection.name,
            source: request.source,
            fileSize: request.selection.size,
            chromeMode: chromeMode,
            navigationContext: request.navigationContext,
            reviewCommentSelectionScope: request.services.reviewCommentSelectionScope
        )
    }

    /// Reads on the browser's server stores (the session's checkout, audio
    /// playback) with the browser's API client, and shares its viewport store.
    private static func viewer(
        _ request: Request,
        chromeMode: FileBrowserContentChromeMode
    ) -> FileViewerViewController {
        let services = request.services
        let viewer = FileViewerViewController(
            configuration: configuration(request, chromeMode: chromeMode),
            services: .init(
                apiClient: services.apiClient,
                audioPlayer: services.connection.audioPlayer,
                sessionStore: services.connection.sessionStore,
                pins: services.connection.pinsAvailable ? services.connection.pins : nil
            )
        )
        viewer.markdownViewportRestore = request.viewportRestore
        return viewer
    }
}
