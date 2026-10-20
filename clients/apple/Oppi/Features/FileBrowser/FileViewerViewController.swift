import Network
import PDFKit
import UIKit

/// The bar a file viewer asks for: its title and trailing items, and whether
/// the editor owns it. A viewer at the top of a stack applies it to its own
/// navigation item; a screen that embeds one (a route, a review, a file list)
/// reads it in `updateProperties()` and shows the items in its own bar.
@MainActor @Observable
final class FileViewerBar {
    fileprivate(set) var title = ""
    /// In `rightBarButtonItems` order: the first is the trailing-most.
    fileprivate(set) var trailingItems: [UIBarButtonItem] = []
    /// The text editor is open; its status, Preview, and Done own the bar.
    fileprivate(set) var isEditing = false

    /// Shows the title and items on `navigationItem`. Assigns only what
    /// changed, so open menus and glass groups survive.
    func apply(to navigationItem: UINavigationItem) {
        if navigationItem.title != title {
            navigationItem.title = title
        }
        if !(navigationItem.rightBarButtonItems ?? []).elementsEqual(trailingItems, by: ===) {
            navigationItem.rightBarButtonItems = trailingItems
        }
    }
}

/// One file, read from where it lives and shown by type: text in the UIKit
/// reader (`FullScreenCodeViewController`) or the code editor, images, video,
/// audio, PDF, and 3D scenes. Large text files ask before loading.
///
/// `.pushed` is a screen of its own: a text file shows the reader's glass bar
/// and hides the stack's (`readerHostNavigationBar` behavior), host files keep
/// the stack's bar. `.treePane` sits beside a list or under a review header;
/// its Edit control is a bar item for the embedding screen (`bar`).
///
/// Re-showing the viewer (a full-screen modal over it, or a pop back from a
/// pushed wiki link) re-reads the file and rebuilds the reader only when its
/// text changed, so inline players survive; a missing or denied file replaces
/// stale text.
@MainActor
final class FileViewerViewController: UIViewController {
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
    }

    /// The server-scoped services the viewer reads through.
    struct Services {
        let apiClient: @MainActor () -> APIClient?
        let audioPlayer: AudioPlayerService?
        let sessionStore: SessionStore?

        init(connection: ServerConnection) {
            apiClient = { connection.apiClient }
            audioPlayer = connection.audioPlayer
            sessionStore = connection.sessionStore
        }

        init(apiClient: APIClient?, audioPlayer: AudioPlayerService? = nil, sessionStore: SessionStore? = nil) {
            self.apiClient = { apiClient }
            self.audioPlayer = audioPlayer
            self.sessionStore = sessionStore
        }
    }

    private enum Phase: Equatable {
        case loading
        case sizeWarning(Int)
        case error(String)
        case text(String)
        case image(Data)
        case video(AuthenticatedMediaSource)
        case audio(AuthenticatedMediaSource)
        case pdf(Data)
        case usdz(USDZLocalFileStore.Handle)
        case binary

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): true
            case (.sizeWarning(let a), .sizeWarning(let b)): a == b
            case (.error(let a), .error(let b)): a == b
            case (.text(let a), .text(let b)): a == b
            case (.image(let a), .image(let b)): a == b
            case (.video(let a), .video(let b)): a.identity == b.identity
            case (.audio(let a), .audio(let b)): a.identity == b.identity
            case (.pdf(let a), .pdf(let b)): a == b
            case (.usdz(let a), .usdz(let b)): a == b
            case (.binary, .binary): true
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
    /// Edit with Oppi, beside the editor in the one Edit control. Shown in
    /// the viewer's bar items, so for host files and the tree pane.
    var agentEdit: DocumentAgentEditAction? {
        didSet { setNeedsUpdateProperties() }
    }
    var markdownViewportRestore: FileBrowserViewportRestore?

    // MARK: State

    private var activeSelection: FileBrowserSelection?
    private var content: Phase = .loading {
        didSet {
            if content != oldValue { contentGeneration &+= 1 }
            setNeedsUpdateProperties()
        }
    }
    private var contentGeneration = 0
    private var loadedMediaPath: String?
    /// Path whose text `content` holds, so a re-shown viewer revalidates instead of rebuilding.
    private var loadedTextPath: String?
    private var loadedHostFilePath: String?
    private var isExpensiveNetwork = false {
        didSet { if isExpensiveNetwork != oldValue { setNeedsUpdateProperties() } }
    }
    /// The API client of the last load, for reader resources and captions.
    private var loadedApiClient: APIClient?
    private var timedText = TimedText.LoadResult.empty {
        didSet { setNeedsUpdateProperties() }
    }
    private var timedTextLoadFinished = false
    /// Tagged read of the displayed bytes. Nil when the server did not offer
    /// this file for editing; missing capability or other origins stay read-only.
    private var editBase: WorkspaceFileDiskSnapshot?
    private var editMaxBytes: Int? {
        didSet { setNeedsUpdateProperties() }
    }
    private var editSession: WorkspaceFileEditSession? {
        didSet { setNeedsUpdateProperties() }
    }
    private var isEditorOpen = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var isShowingEditPreview = false {
        didSet { setNeedsUpdateProperties() }
    }
    private var editorReplacement: WorkspaceFileEditorReplacement? {
        didSet { setNeedsUpdateProperties() }
    }
    private var editNotice: String? {
        didSet { setNeedsUpdateProperties() }
    }
    private weak var conflictReview: WorkspaceFileConflictReviewViewController?
    private var reportedEditing = false
    /// While content loads, the stack's bar stays as the last settled content
    /// left it, so next/previous between two text files never slides it.
    private var settledHidesHostBar = false

    private var loadTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?
    private var isOnScreen = false

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
    private var mountedLeaves: [HostedLeaf] = []
    private var mountedBackSwipe: HorizontalBackSwipeGestureInstaller?
    private weak var reader: FullScreenCodeViewController?
    private weak var editor: WorkspaceFileEditorViewController?
    private var appliedReplacementID: UUID?
    private var editorHeader: UIStackView?
    private var editBanner: WorkspaceFileEditBannerView?
    private var checkoutLabel: UILabel?
    private var noticeLabel: UILabel?
    private var sizeWarning: FileViewerSizeWarningView?
    private var videoPage: UIView?
    private var audioPlayerController: AudioLyricsPlayerViewController?
    private var videoModel: AuthenticatedMediaPlayerModel?
    private var videoHost: AuthenticatedMediaPlayerHostController?
#if DEBUG
    private var motionMarker: FileMotionDebugMarker?
#endif
    private lazy var adjacentButtons = AdjacentFileNavigatorButtons { [weak self] direction in
        self?.navigateToAdjacentFile(direction)
    }
    private let stashButton = ReviewCommentStashFloatingButton()

    // Bar items, kept while their inputs hold.
    private var editBarItems: WorkspaceFileEditBarItems?
    private var editItem: UIBarButtonItem?
    private var editItemKey: EditItemKey?
    private var shareItem: UIBarButtonItem?
    private var shareItemKey: Int?

    private struct EditItemKey: Equatable {
        let editsFile: Bool
        let hasAgentEdit: Bool
        let isStarting: Bool
    }

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
        guard !alreadyShown else { return }
        beginUSDZSafeLoading()
        if isOnScreen { startLoad() }
    }

    /// Reads the file the way this viewer does; reader resources resolve
    /// against the same origin.
    var fileAccess: FileViewerFileAccess {
        FileViewerFileAccess(
            source: configuration.source,
            serverId: configuration.serverId,
            workspaceId: configuration.workspaceId,
            worktreeId: configuration.worktreeId,
            sessionId: configuration.sessionId,
            controlSessionId: configuration.controlSessionId,
            workspaceRuntime: configuration.workspaceRuntime
        )
    }

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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyHostNavigationBar(animated: animated)
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        isOnScreen = true
        // Like SwiftUI's `.task(id:)`: every appearance reads the file again.
        startLoad()
        networkTask?.cancel()
        networkTask = Task { [weak self] in await self?.checkNetworkCost() }
        if let videoModel, case .video(let source) = content {
            prepareVideo(videoModel, source: source)
        }
        applyHostNavigationBar(animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyHostNavigationBar(animated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        loadTask?.cancel()
        loadTask = nil
        networkTask?.cancel()
        networkTask = nil
        videoModel?.handleDisappear()
        releaseLoadedUSDZHandle()
        if isLeaving {
            // Popped or dismissed: the editor hands its buffer to the session.
            editor?.finishEditing()
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            editor?.finishEditing()
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
        let themeID = HostFactory.root(near: self)?.themeStore.activeThemeID ?? ThemeRuntimeState.currentThemeID()
        let palette = themeID.palette
        view.backgroundColor = UIColor(palette.bg)
        reconcileContent(palette: palette)
        updateMountedContent(palette: palette)
        updateFloatingControls(themeID: themeID)
        updateBar()
        applyHostNavigationBar(animated: true)
        let editing = isEditingText
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

    private var fileExtension: String {
        (currentFilePath as NSString).pathExtension.lowercased()
    }

    /// Text is loaded and the reader (not the editor) shows it.
    private var isUsingFileViewer: Bool {
        if case .text = content { return !isEditorOpen }
        return false
    }

    private var showsEmbeddedNavigationChrome: Bool {
        FileBrowserContentRenderingPolicy.showsNavigationChrome(
            for: configuration.chromeMode,
            source: configuration.source
        )
    }

    private var shouldHideHostNavigationBar: Bool {
        showsEmbeddedNavigationChrome && isUsingFileViewer
    }

    private var isEditingText: Bool {
        if case .text = content { return isEditorOpen && editSession != nil }
        return false
    }

    /// Text, PDF, and 3D scenes own the back swipe; the viewer handles it for the rest.
    private var parentOwnsBackSwipe: Bool {
        switch content {
        case .text, .pdf, .usdz:
            false
        case .loading, .sizeWarning, .error, .image, .video, .audio, .binary:
            true
        }
    }

    private var readerSelectionContext: ReviewCommentSelectionContext? {
        configuration.reviewCommentSelectionContext
            ?? configuration.reviewCommentSelectionScope?.makeContext(sessionId: configuration.sessionId)
    }

    private func adjacentSelection(_ direction: FileBrowserNavigationDirection) -> FileBrowserSelection? {
        configuration.navigationContext?.selection(adjacentTo: currentFilePath, direction: direction)
    }

    private var canGoPrevious: Bool { !isEditingText && adjacentSelection(.previous) != nil }
    private var canGoNext: Bool { !isEditingText && adjacentSelection(.next) != nil }

    private var leadingAccessoryCount: Int {
        AdjacentFileNavigatorLayout.leadingAccessoryCount(
            canGoPrevious: adjacentSelection(.previous) != nil,
            canGoNext: adjacentSelection(.next) != nil
        )
    }

    private var trailingAccessoryCount: Int {
        AdjacentFileNavigatorLayout.trailingAccessoryCount(
            canGoPrevious: adjacentSelection(.previous) != nil,
            canGoNext: adjacentSelection(.next) != nil
        )
    }

    // MARK: Content

    private var wantedKey: MountKey {
        switch content {
        case .sizeWarning:
            return .sizeWarning(generation: contentGeneration, expensive: isExpensiveNetwork)
        case .text:
            if isEditorOpen, let editSession { return .editor(ObjectIdentifier(editSession)) }
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
        case .error(let message):
            mounted = unavailable(
                title: String(localized: "Unable to Load"),
                systemImage: "exclamationmark.triangle",
                message: message
            )
        case .text(let text):
            if isEditorOpen, let editSession {
                mounted = mountEditor(session: editSession)
            } else {
                mounted = mountReader(text: text)
            }
        case .image(let data):
            mounted = mountImage(data)
        case .video(let source):
            mounted = mountVideo(source)
        case .audio(let source):
            mounted = mountAudio(source)
        case .pdf(let data):
            mounted = mountPDF(data)
        case .usdz(let handle):
            mounted = mountUSDZ(handle)
        case .binary:
            mounted = unavailable(
                title: String(localized: "Binary File"),
                systemImage: "doc.fill",
                message: String(localized: "This file type cannot be displayed as text.")
            )
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

    private func unmountContent() {
        if let editor {
            editor.finishEditing()
        }
        if let videoModel {
            videoModel.handleDisappear()
            videoHost?.dispose()
        }
        for child in mountedChildren {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        mountedChildren = []
        mountedLeaves = []
        mountedView?.removeFromSuperview()
        mountedView = nil
        mountedBackSwipe = nil
        reader = nil
        editor = nil
        appliedReplacementID = nil
        editorHeader = nil
        editBanner = nil
        checkoutLabel = nil
        noticeLabel = nil
        sizeWarning = nil
        videoPage = nil
        audioPlayerController = nil
        videoModel = nil
        videoHost = nil
#if DEBUG
        motionMarker?.removeFromSuperview()
        motionMarker = nil
#endif
    }

    /// Adds `controller` as a child whose view fills `container`.
    private func embed(_ controller: UIViewController, in container: UIView, guide: UILayoutGuide? = nil) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controller.view)
        let anchors = guide.map { ($0.topAnchor, $0.bottomAnchor, $0.leadingAnchor, $0.trailingAnchor) }
            ?? (container.topAnchor, container.bottomAnchor, container.leadingAnchor, container.trailingAnchor)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: anchors.0),
            controller.view.bottomAnchor.constraint(equalTo: anchors.1),
            controller.view.leadingAnchor.constraint(equalTo: anchors.2),
            controller.view.trailingAnchor.constraint(equalTo: anchors.3),
        ])
        controller.didMove(toParent: self)
        mountedChildren.append(controller)
    }

    /// A full-page container on `pageView`, inside the safe area unless asked.
    private func addPage(_ page: UIView) {
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

    private func unavailable(title: String, systemImage: String, message: String) -> UIView {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: systemImage)
        configuration.text = title
        configuration.secondaryText = message
        let unavailable = UIContentUnavailableView(configuration: configuration)
        addPage(unavailable)
        return unavailable
    }

    private func mountReader(text: String) -> UIView {
        let path = currentFilePath
        let back: @MainActor @Sendable () -> Void = { [weak self] in self?.navigateBack() }
        let reader = FullScreenCodeViewController(
            content: fullScreenContent(text: text),
            presentationMode: showsEmbeddedNavigationChrome
                ? .embedded(onDismiss: back)
                : .contentOnly(onBackSwipe: back),
            reviewCommentSelectionContext: readerSelectionContext,
            lineAnchor: activeSelection == nil ? configuration.lineAnchor : nil,
            lineAnchorNotice: onLineAnchorNotice,
            navigationActions: editNavigationActions,
            markdownViewportIntent: markdownViewportRestore?.state[path],
            onMarkdownViewportIntentChange: { [weak self] intent in
                self?.markdownViewportRestore?.state[path] = intent
            },
            addToChatDestination: configuration.addToChatDestination
        )
        reader.setLeadingFloatingAccessoryCount(leadingAccessoryCount)
        reader.setTrailingFloatingAccessoryCount(trailingAccessoryCount)
        let page = UIView()
        addPage(page)
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(reader.view)
        let safe = page.safeAreaLayoutGuide
        // The reader's own glass bar sits at the top of a pushed screen.
        NSLayoutConstraint.activate([
            reader.view.topAnchor.constraint(
                equalTo: showsEmbeddedNavigationChrome ? page.topAnchor : safe.topAnchor
            ),
            reader.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            reader.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        reader.didMove(toParent: self)
        mountedChildren.append(reader)
        self.reader = reader
        return page
    }

    private func mountEditor(session: WorkspaceFileEditSession) -> UIView {
        let editor = WorkspaceFileEditorViewController(
            session: session,
            onDone: { [weak self] in self?.endEditing() },
            makePreview: { [weak self] text in
                FullScreenCodeViewController(
                    content: self?.fullScreenContent(text: text) ?? .fromText(text, filePath: session.identity.path),
                    presentationMode: .contentOnly()
                )
            }
        )
        let page = UIView()
        addPage(page)
        let header = UIStackView()
        header.axis = .vertical
        header.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(header)

        let checkout = UILabel()
        checkout.font = .preferredFont(forTextStyle: .caption1)
        checkout.lineBreakMode = .byTruncatingMiddle
        checkout.accessibilityIdentifier = "workspace-file-editor.checkout"
        header.addArrangedSubview(Self.padded(checkout, horizontal: 12, vertical: 4))
        checkoutLabel = checkout

        let banner = WorkspaceFileEditBannerView(
            session: session,
            onReview: { [weak self] in self?.presentConflictReview() },
            onUseDisk: { [weak self] in self?.confirmUseDiskVersion() }
        )
        header.addArrangedSubview(banner)
        editBanner = banner

        let notice = UILabel()
        notice.font = .preferredFont(forTextStyle: .footnote)
        notice.numberOfLines = 0
        header.addArrangedSubview(Self.padded(notice, horizontal: 8, vertical: 8))
        noticeLabel = notice

        addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(editor.view)
        let safe = page.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: safe.topAnchor),
            header.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            editor.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            editor.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            editor.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        editor.didMove(toParent: self)
        mountedChildren.append(editor)
        self.editor = editor
        editorHeader = header
        appliedReplacementID = editorReplacement?.id
        return page
    }

    private static func padded(_ label: UILabel, horizontal: CGFloat, vertical: CGFloat) -> UIView {
        let container = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
        ])
        return container
    }

    private func mountImage(_ data: Data) -> UIView {
        let page = UIView()
        addPage(page)
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(scroll)
        let safe = page.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safe.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        guard let root = HostFactory.root(near: self) else { return page }
        let image = HostFactory.leaf(
            DataImagePreviewView(
                data: data,
                mimeType: MediaMimeType.imageMimeType(forPathExtension: fileExtension),
                maxPixelSize: 2_400,
                heightMode: .unrestricted
            ),
            root: root
        )
        addChild(image.host)
        scroll.addSubview(image.view)
        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            image.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: inset),
            image.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -inset),
            image.view.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: inset),
            image.view.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -inset),
        ])
        image.host.didMove(toParent: self)
        mountedChildren.append(image.host)
        mountedLeaves.append(image)
        return page
    }

    private func mountVideo(_ source: AuthenticatedMediaSource) -> UIView {
        let page = UIView()
        addPage(page)
        videoPage = page
        let model = AuthenticatedMediaPlayerModel()
        let host = AuthenticatedMediaPlayerHostController(model: model)
        // `loadedMediaPath` changes with `content`, so the loader always names
        // the file behind `source`. The host runs it once per source and
        // attaches captions to the player overlay, even during fullscreen.
        host.update(
            model: model,
            sourceIdentity: source.identity,
            chrome: AuthenticatedMediaPlayerHostController.Chrome(
                unavailableTitle: "Video preview unavailable",
                unavailableSystemImage: "film.slash"
            ),
            timedTextLoader: loadedMediaPath.flatMap { makeTimedTextLoader(path: $0, kind: .video) }
        )
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.layer.cornerRadius = 10
        host.view.clipsToBounds = true
        page.addSubview(host.view)
        let safe = page.safeAreaLayoutGuide
        let preferred = host.view.heightAnchor.constraint(equalTo: safe.heightAnchor, multiplier: 0.34)
        preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            host.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
            host.view.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            preferred,
            host.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            host.view.heightAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        host.didMove(toParent: self)
        mountedChildren.append(host)
        videoModel = model
        videoHost = host
        if isOnScreen {
            prepareVideo(model, source: source)
        }
        return page
    }

    private func prepareVideo(_ model: AuthenticatedMediaPlayerModel, source: AuthenticatedMediaSource) {
        model.setVisible(true)
        model.prepare(
            source: source,
            autoplay: false,
            telemetrySource: "authenticated_media",
            telemetryMode: "inline",
            telemetrySessionId: nil,
            onPresentationSize: nil
        )
    }

    private func mountAudio(_ source: AuthenticatedMediaSource) -> UIView {
        let player = AudioLyricsPlayerViewController(configuration: audioConfiguration(source))
        let page = UIView()
        addPage(page)
        embed(player, in: page, guide: page.safeAreaLayoutGuide)
        audioPlayerController = player
        return page
    }

    private var audioItemID: String {
        AudioPlaybackItemID.fileBrowser(
            path: currentFilePath,
            workspaceID: configuration.workspaceId,
            sessionID: configuration.sessionId,
            worktreeID: configuration.worktreeId
        )
    }

    /// Reads the player's `@Observable` state: call from `updateProperties()`
    /// so the lyrics follow what plays.
    private func audioConfiguration(_ source: AuthenticatedMediaSource) -> AudioLyricsPlayerViewController.Configuration {
        let itemID = audioItemID
        let audioPlayer = services.audioPlayer
        let nowPlayingTimedText = audioPlayer?.nowPlayingTimedText
        let playbackTimedText =
            (audioPlayer?.playingItemID == itemID || audioPlayer?.loadingItemID == itemID)
            && !(nowPlayingTimedText?.tracks.isEmpty ?? true)
            ? (nowPlayingTimedText ?? timedText)
            : timedText
        let playbackTimedTextLoader = timedTextLoadFinished
            ? nil
            : makeTimedTextLoader(path: currentFilePath, kind: .audio)
        return AudioLyricsPlayerViewController.Configuration(
            title: currentFileName,
            lyrics: nil,
            itemID: itemID,
            audioPlayer: audioPlayer,
            play: { selectedTimedText in
                audioPlayer?.toggleMediaPlayback(
                    source: source,
                    itemID: itemID,
                    timedText: selectedTimedText ?? playbackTimedText,
                    timedTextLoader: playbackTimedTextLoader
                )
            },
            openFile: nil,
            shareFileData: nil,
            autoplayOnAppear: false,
            showsCloseButton: false,
            usesNavigationBackButton: false,
            titlePresentation: FileBrowserContentRenderingPolicy.audioPlayerTitlePresentation,
            timedText: playbackTimedText,
            sidecarLoader: nil,
            dismiss: { [weak self] in self?.navigateBack() }
        )
    }

    private func mountPDF(_ data: Data) -> UIView {
        guard let document = PDFDocument(data: data) else {
            let invalid = unavailable(
                title: String(localized: "Invalid PDF"),
                systemImage: "doc.badge.exclamationmark",
                message: String(localized: "Could not decode PDF data.")
            )
            installOwnBackSwipe(on: invalid)
            return invalid
        }
        let pdf = PDFView()
        pdf.autoScales = true
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.backgroundColor = .clear
        pdf.document = document
        let page = UIView()
        addPage(page)
        pdf.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(pdf)
        let safe = page.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            pdf.topAnchor.constraint(equalTo: safe.topAnchor),
            pdf.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            pdf.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            pdf.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        installOwnBackSwipe(on: pdf)
        return page
    }

    /// PDF content handles back itself when the host allows the swipe.
    private func installOwnBackSwipe(on view: UIView) {
        guard configuration.allowsHorizontalBackSwipe else { return }
        let installer = HorizontalBackSwipeGestureInstaller { [weak self] in self?.navigateBack() }
        installer.install(on: view)
        mountedBackSwipe = installer
    }

    private func mountUSDZ(_ handle: USDZLocalFileStore.Handle) -> UIView {
        let page = UIView()
        addPage(page)
        guard let root = HostFactory.root(near: self) else { return page }
        let scene = HostFactory.content(
            FileBrowserUSDZPreview(fileURL: handle.url, accessibilityName: currentFileName),
            root: root
        )
        scene.view.backgroundColor = .clear
        embed(scene, in: page, guide: page.safeAreaLayoutGuide)
        return page
    }

    /// Updates what stays mounted: the reader's Edit action and floating
    /// counts, the editor's preview and replacement, its header, the audio
    /// player's lyrics, and the theme colors of the pages this viewer draws.
    private func updateMountedContent(palette: ThemePalette) {
        sizeWarning?.apply(palette)
        editBanner?.update(palette: palette)
        videoPage?.backgroundColor = UIColor(palette.bgDark)
        checkoutLabel?.textColor = UIColor(palette.comment)
        noticeLabel?.textColor = UIColor(palette.comment)
        if let reader {
            reader.setNavigationActions(editNavigationActions)
            reader.setLeadingFloatingAccessoryCount(leadingAccessoryCount)
            reader.setTrailingFloatingAccessoryCount(trailingAccessoryCount)
        }
        if let editor {
            if let editorReplacement, appliedReplacementID != editorReplacement.id {
                appliedReplacementID = editorReplacement.id
                editor.replaceText(editorReplacement.text)
            }
            editor.setShowingPreview(isShowingEditPreview)
            let subtitle = checkoutSubtitle
            checkoutLabel?.text = subtitle
            checkoutLabel?.superview?.isHidden = subtitle == nil
            noticeLabel?.text = editNotice
            noticeLabel?.superview?.isHidden = editNotice == nil
        }
        if let audioPlayerController, case .audio(let source) = content {
            audioPlayerController.apply(audioConfiguration(source))
        }
    }

    private func updateFloatingControls(themeID: ThemeID) {
        adjacentButtons.update(on: view, canGoPrevious: canGoPrevious, canGoNext: canGoNext, themeID: themeID)
        // The reader draws its own staged-comment button.
        let usesReaderStash: Bool = if case .text = content { true } else { false }
        stashButton.update(
            on: view,
            presenter: self,
            scope: configuration.showsReviewCommentStash && !usesReaderStash
                ? configuration.reviewCommentSelectionScope
                : nil,
            leadingAccessoryCount: leadingAccessoryCount,
            palette: themeID.palette
        )
    }

    // MARK: Bar

    private func updateBar() {
        var items: [UIBarButtonItem] = []
        let editing = isEditingText
        if editing, let editSession {
            let editItems = editBarItems ?? WorkspaceFileEditBarItems(
                onTogglePreview: { [weak self] in self?.isShowingEditPreview.toggle() },
                onDone: { [weak self] in self?.endEditing() }
            )
            editBarItems = editItems
            editItems.update(status: editSession.status, isShowingPreview: isShowingEditPreview)
            items = editItems.items
        } else {
            // Left to right: Edit, then Share.
            if showsToolbarEditControl, let edit = documentEditItem() {
                items.append(edit)
            }
            if configuration.chromeMode == .pushed, !isUsingFileViewer, let share = shareBarItem() {
                items.append(share)
            }
            items.reverse()
        }
        if bar.title != viewerTitle { bar.title = viewerTitle }
        if !bar.trailingItems.elementsEqual(items, by: ===) { bar.trailingItems = items }
        if bar.isEditing != editing { bar.isEditing = editing }
        bar.apply(to: navigationItem)
    }

    /// The Edit control lives in the bar (host files, the tree pane) once the
    /// file has loaded, when the editor or Edit with Oppi can run.
    private var showsToolbarEditControl: Bool {
        guard FileBrowserContentRenderingPolicy.editPlacement(
            for: configuration.chromeMode,
            source: configuration.source
        ) == .toolbar else { return false }
        if case .loading = content { return false }
        return agentEdit != nil || (isUsingFileViewer && canBeginEditing)
    }

    private func documentEditItem() -> UIBarButtonItem? {
        let editsFile = isUsingFileViewer && canBeginEditing
        let key = EditItemKey(
            editsFile: editsFile,
            hasAgentEdit: agentEdit != nil,
            isStarting: agentEdit?.isStarting ?? false
        )
        if key == editItemKey, let editItem { return editItem }
        editItemKey = key
        var editFile: (@MainActor () -> Void)?
        if editsFile {
            editFile = { [weak self] in self?.beginEditing() }
        }
        var agent: DocumentAgentEditAction?
        if let agentEdit {
            // The current action starts, whatever the host set since.
            agent = DocumentAgentEditAction(isStarting: agentEdit.isStarting, start: { [weak self] in
                self?.agentEdit?.start()
            })
        }
        editItem = DocumentEditBarItem.make(editFile: editFile, agentEdit: agent)
        return editItem
    }

    private func shareBarItem() -> UIBarButtonItem? {
        if shareItemKey == contentGeneration, let shareItem { return shareItem }
        shareItemKey = contentGeneration
        if let shareable = shareableContent() {
            let item = FileSharePresenter.makeShareBarButtonItem(for: shareable)
            item.title = String(localized: "Share")
            shareItem = item
        } else if case .audio(let source) = content {
            shareItem = makeAudioShareItem(source)
        } else {
            shareItem = nil
        }
        return shareItem
    }

    /// Media stays range-streamed until the user asks to share the file.
    private func makeAudioShareItem(_ source: AuthenticatedMediaSource) -> UIBarButtonItem {
        let filename = currentFileName
        let box = Weak<UIBarButtonItem>()
        let item = UIBarButtonItem(
            title: String(localized: "Share"),
            image: UIImage(systemName: "square.and.arrow.up"),
            primaryAction: UIAction { [weak self] _ in
                guard let button = box.value else { return }
                let token = BarButtonLoadingToken(button: button, tintColor: nil)
                Task { @MainActor in
                    token.start()
                    defer { token.stop() }
                    do {
                        let data = try await source.loadFileData()
                        let item = FileShareService.fileShareItem(data: data, filename: filename)
                        FileSharePresenter.presentActivityController(item: item)
                    } catch is CancellationError {
                        return
                    } catch {
                        self?.presentShareFailure()
                    }
                }
            }
        )
        item.accessibilityIdentifier = "fileBrowser.audio.share"
        box.value = item
        return item
    }

    private func presentShareFailure() {
        let alert = UIAlertController(
            title: String(localized: "Unable to Share File"),
            message: String(localized: "The file could not be downloaded. Please try again."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }

    /// Shareable content of the loaded phase.
    private func shareableContent() -> FileShareService.ShareableContent? {
        switch content {
        case .text(let text):
            return .fromText(text, filePath: currentFilePath)
        case .image(let data):
            return .imageData(data, filename: currentFileName)
        case .pdf(let data):
            return .pdfData(data, filename: currentFileName)
        default:
            return nil
        }
    }

    /// Hides the stack's bar while the reader shows its own (pushed text).
    private func applyHostNavigationBar(animated: Bool) {
        guard configuration.chromeMode == .pushed else { return }
        let hides: Bool
        if case .loading = content {
            hides = settledHidesHostBar
        } else {
            hides = shouldHideHostNavigationBar
            settledHidesHostBar = hides
        }
        guard let navigation = navigationController,
              navigation.topViewController === stackScreen,
              navigation.isNavigationBarHidden != hides else { return }
        navigation.setNavigationBarHidden(hides, animated: animated && isOnScreen)
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

    /// The server offered these displayed bytes for editing, or a session exists.
    private var canBeginEditing: Bool {
        editIdentity(for: currentFilePath) != nil
            && editMaxBytes != nil
            && (editBase != nil || editSession != nil)
    }

    private var checkoutSubtitle: String? {
        FileBrowserContentRenderingPolicy.checkoutSubtitle(
            source: configuration.source,
            worktreeId: configuration.worktreeId,
            sessionWorktreeId: configuration.sessionId.flatMap { services.sessionStore?.session(id: $0) }
                .flatMap { $0.workspaceId == configuration.workspaceId ? $0.worktreeId : nil }
        )
    }

    private var editNavigationActions: [FullScreenViewerNavigationAction] {
        guard canBeginEditing,
              FileBrowserContentRenderingPolicy.editPlacement(
                  for: configuration.chromeMode,
                  source: configuration.source
              ) == .readerNavigationAction else { return [] }
        return [
            FullScreenViewerNavigationAction(
                id: "workspace-file-edit",
                title: DocumentEditLabels.edit,
                systemImage: DocumentEditLabels.systemImage,
                accessibilityLabel: DocumentEditLabels.editFile,
                handler: { [weak self] in self?.beginEditing() }
            ),
        ]
    }

    /// Workspace-origin files on a known server edit by workspace + worktree +
    /// path; a host file edits only as its Skill's own file. Other host and
    /// session files stay read-only.
    private func editIdentity(for path: String) -> WorkspaceFileEditIdentity? {
        guard let serverId = configuration.serverId, !serverId.isEmpty else { return nil }
        switch configuration.source {
        case .workspaceFile:
            guard !configuration.workspaceId.isEmpty else { return nil }
            return WorkspaceFileEditIdentity(
                serverId: serverId,
                workspaceId: configuration.workspaceId,
                worktreeId: configuration.worktreeId,
                path: path
            )
        case .hostFile:
            guard let skillFile = configuration.skillFile, path == configuration.filePath else { return nil }
            return WorkspaceFileEditIdentity(serverId: serverId, skillId: skillFile.skillId, path: skillFile.path)
        case .sessionFile:
            return nil
        }
    }

    private func resetEditState() {
        editBase = nil
        editMaxBytes = nil
        editSession = nil
        isEditorOpen = false
        isShowingEditPreview = false
        editorReplacement = nil
        closeConflictReview()
        editNotice = nil
    }

    /// Record the tagged read and adopt a live session or recover a stored
    /// draft. Returns the text the reader should show when it differs from disk.
    private func prepareEditing(
        identity: WorkspaceFileEditIdentity,
        snapshot: WorkspaceFileDiskSnapshot,
        maxBytes: Int,
        api: APIClient
    ) -> String? {
        editMaxBytes = maxBytes
        editBase = snapshot.etag == nil ? nil : snapshot
        let registry = WorkspaceFileEditSessionRegistry.shared
        if let live = registry.session(for: identity) {
            editSession = live
            if live.hasUnsavedChanges, live.status.stopsAutosave || live.recoveredDraft {
                isEditorOpen = true
            }
            return live.hasUnsavedChanges ? live.currentText : nil
        }
        guard snapshot.etag != nil,
              WorkspaceFileDraftStore.shared.loadResult(identity) != .none,
              let recovered = WorkspaceFileEditSession(
                  identity: identity,
                  disk: snapshot,
                  maxBytes: maxBytes,
                  transport: .api(api)
              ) else { return nil }
        // A recovered draft, or a notice that an unreadable one was moved aside.
        guard recovered.recoveredDraft || recovered.draftNotice != nil else { return nil }
        registry.register(recovered)
        editSession = recovered
        isEditorOpen = true
        return recovered.currentText
    }

    private static func isHTTPError(_ error: Error, statusCodes: Set<Int>) -> Bool {
        switch error {
        case APIError.server(let status, _), APIError.codedServer(let status, _, _):
            return statusCodes.contains(status)
        default:
            return false
        }
    }

    private func beginEditing() {
        guard let identity = editIdentity(for: currentFilePath),
              let maxBytes = editMaxBytes,
              let api = loadedApiClient ?? services.apiClient() else { return }
        let registry = WorkspaceFileEditSessionRegistry.shared
        let session: WorkspaceFileEditSession
        if let live = registry.session(for: identity) {
            session = live
        } else if let existing = editSession, existing.identity == identity {
            // Keeps the newest acknowledged tag after an earlier edit settled.
            session = existing
            registry.register(existing)
        } else if let editBase, let created = WorkspaceFileEditSession(
            identity: identity,
            disk: editBase,
            maxBytes: maxBytes,
            transport: .api(api)
        ) {
            session = created
            registry.register(created)
        } else {
            return
        }
        editSession = session
        editNotice = nil
        isShowingEditPreview = false
        isEditorOpen = true
    }

    /// Done: show the current draft in the reader. The editor teardown
    /// checkpoints and starts the save; the network is not awaited.
    private func endEditing() {
        guard let editSession else {
            isEditorOpen = false
            return
        }
        // Teardown first, so the session holds the final buffer.
        editor?.finishEditing()
        let text = editSession.currentText
        isShowingEditPreview = false
        isEditorOpen = false
        content = .text(text)
    }

    private func useDiskVersion() {
        guard let editSession else { return }
        Task { [weak self] in
            let outcome = await editSession.useDiskVersion()
            guard let self else { return }
            switch outcome {
            case .replaced(let text):
                editNotice = nil
                editorReplacement = WorkspaceFileEditorReplacement(text: text)
                content = .text(text)
            case .missing, .notEditable:
                resetEditState()
                await loadContent(force: true)
            case .unavailable:
                editNotice = String(localized: "Couldn't read the disk version. Your edits were not changed.")
            }
        }
    }

    private func confirmUseDiskVersion() {
        let alert = UIAlertController(
            title: String(localized: "Use Disk Version?"),
            message: String(localized: "Your unsaved edits to this file will be discarded."),
            preferredStyle: .alert
        )
        let discard = UIAlertAction(title: String(localized: "Discard My Edits"), style: .destructive) { [weak self] _ in
            self?.useDiskVersion()
        }
        discard.accessibilityIdentifier = "workspace-file-editor.use-disk.confirm"
        alert.addAction(discard)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func presentConflictReview() {
        guard conflictReview == nil, let editSession else { return }
        let review = WorkspaceFileConflictReviewViewController(
            session: editSession,
            filePath: currentFilePath,
            reviewCommentSelectionScope: configuration.reviewCommentSelectionScope,
            onUseDisk: { [weak self] in
                self?.closeConflictReview()
                self?.useDiskVersion()
            },
            onReplace: { [weak self] in
                editSession.replaceDiskVersion()
                self?.closeConflictReview()
            },
            onClose: { [weak self] in self?.closeConflictReview() }
        )
        conflictReview = review
        Router.present(
            review,
            presentation: .sheet.inNavigation(),
            from: self,
            theme: HostFactory.root(near: self)?.themeStore,
            onDismiss: { [weak self] in self?.conflictReview = nil }
        )
    }

    private func closeConflictReview() {
        guard let conflictReview else { return }
        self.conflictReview = nil
        if conflictReview.presentingViewController != nil {
            Router.finish(conflictReview)
        }
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
            content = .error("Not connected")
            return
        }
        // Reappearing over an open editor must not reload over the buffer.
        if isEditorOpen, let editSession,
           editSession.identity == editIdentity(for: currentSelection.path) {
            return
        }

        let requestedSelection = currentSelection
        let requestedPath = requestedSelection.path
        let requestedExtension = (requestedPath as NSString).pathExtension.lowercased()
        let requestedCategory = FileType.detect(from: requestedPath).previewCategory
        let existingMedia: FileBrowserMediaLoadPolicy.Existing = {
            guard let loadedMediaPath else { return .none }
            switch content {
            case .video: return .video(path: loadedMediaPath)
            case .audio: return .audio(path: loadedMediaPath)
            default: return .none
            }
        }()
        if !FileBrowserMediaLoadPolicy.shouldReload(
            existing: existingMedia,
            requestedPath: requestedPath,
            force: force
        ) {
            return
        }

        loadedApiClient = api

        // Every re-show reads again: after AVKit fullscreen from an inline
        // Markdown video, or a pop back from a pushed wiki link. Rebuilding the
        // reader there recreates every inline player, so re-read first and
        // rebuild only when the shown text changed. Transient failures keep its
        // inline players; missing or denied files must not show stale text.
        if !force, loadedTextPath == requestedPath, case .text(let shownText) = content {
            do {
                guard let read = try await readReaderBytes(
                    api: api, path: requestedPath, category: requestedCategory
                ) else { return }
                if case .bytes(let data, let editedText, _) = read,
                   readerPhase(data: data, editedText: editedText, path: requestedPath, category: requestedCategory)
                    == .text(shownText) {
                    return
                }
            } catch {
                guard isCurrentFile(requestedPath),
                      Self.isHTTPError(error, statusCodes: [401, 403, 404]) else { return }
                loadedTextPath = nil
                loadedHostFilePath = nil
                resetEditState()
                content = .error(error.localizedDescription)
                return
            }
        }

        // For text files with known size above threshold, show a warning first.
        if !force, requestedCategory == .text,
           let size = requestedSelection.size, size > Self.sizeWarningThreshold {
            content = .sizeWarning(size)
            return
        }

        loadedMediaPath = nil
        loadedTextPath = nil
        loadedHostFilePath = nil
        resetEditState()
        timedText = .empty
        timedTextLoadFinished = false
        beginUSDZSafeLoading()

        let access = fileAccess
        do {
            switch requestedCategory {
            case .video:
                let source = try await access.mediaSource(
                    api: api,
                    path: requestedPath,
                    contentTypeHint: MediaMimeType.videoMimeType(forPathExtension: requestedExtension),
                    sourceFileExtension: requestedExtension
                )
                guard isCurrentFile(requestedPath) else { return }
                loadedMediaPath = requestedPath
                content = .video(source)
            case .audio:
                let source = try await access.mediaSource(
                    api: api,
                    path: requestedPath,
                    contentTypeHint: MediaMimeType.audioMimeType(forPathExtension: requestedExtension),
                    sourceFileExtension: requestedExtension
                )
                guard isCurrentFile(requestedPath) else { return }
                loadedMediaPath = requestedPath
                content = .audio(source)
                await loadTimedText(api: api, path: requestedPath, kind: .audio)
            case .usdz:
                let data: Data
                if configuration.source == .hostFile {
                    let file = try await api.browseHostFileContent(
                        path: requestedPath, controlSessionId: configuration.controlSessionId
                    )
                    guard isCurrentFile(requestedPath) else { return }
                    data = file.data
                    loadedHostFilePath = file.resolvedPath
                } else {
                    data = try await access.browseFile(api: api, path: requestedPath)
                }
                guard isCurrentFile(requestedPath) else { return }
                let key = USDZLocalFileStore.cacheKey(
                    kind: configuration.source == .hostFile ? .hostFile : .workspaceFile,
                    workspaceID: configuration.workspaceId,
                    sessionID: configuration.sessionId,
                    worktreeID: configuration.worktreeId,
                    path: requestedPath
                )
                let handle = try await USDZLocalFileStore.shared.store(key: key, data: data)
                guard isCurrentFile(requestedPath) else {
                    await USDZLocalFileStore.shared.release(handle)
                    return
                }
                loadedMediaPath = requestedPath
                content = .usdz(handle)
            case .image, .pdf, .text, .binary:
                guard let read = try await readReaderBytes(
                    api: api, path: requestedPath, category: requestedCategory
                ) else { return }
                switch read {
                case .missingWithDraft(let session, let maxBytes):
                    // Gone on the server: a kept draft reopens in the
                    // non-writing deleted state instead of an error page.
                    editMaxBytes = maxBytes
                    editSession = session
                    isEditorOpen = true
                    content = .text(session.currentText)
                    return
                case .bytes(let data, let editedText, let resolvedHostPath):
                    if let resolvedHostPath {
                        loadedHostFilePath = resolvedHostPath
                    }
                    content = readerPhase(
                        data: data, editedText: editedText, path: requestedPath, category: requestedCategory
                    )
                }
            }
            if case .text = content {
                loadedTextPath = requestedPath
            }
        } catch {
            guard isCurrentFile(requestedPath) else { return }
            content = .error(error.localizedDescription)
        }
    }

    private enum ReaderRead {
        case bytes(Data, editedText: String?, resolvedHostPath: String?)
        case missingWithDraft(WorkspaceFileEditSession, maxBytes: Int)
    }

    /// One read of a document file. Editable text uses the tagged read and
    /// `prepareEditing`, so a live or recovered draft wins over disk. Nil when
    /// the person moved to another file meanwhile.
    private func readReaderBytes(
        api: APIClient,
        path: String,
        category: FilePreviewCategory
    ) async throws -> ReaderRead? {
        if category == .text,
           let identity = editIdentity(for: path),
           let capability = await api.fileEditingCapability(for: identity.owner) {
            // One tagged read: the edit base is exactly the displayed bytes.
            let snapshot: WorkspaceFileDiskSnapshot
            do {
                snapshot = try await api.readFileForEditing(identity)
            } catch let error where Self.isHTTPError(error, statusCodes: [404]) {
                guard isCurrentFile(path) else { return nil }
                guard let session = WorkspaceFileEditRecovery.sessionForMissingFile(
                    identity: identity,
                    maxBytes: capability.maxBytes,
                    transport: .api(api)
                ) else { throw error }
                return .missingWithDraft(session, maxBytes: capability.maxBytes)
            }
            guard isCurrentFile(path) else { return nil }
            let editedText = prepareEditing(
                identity: identity,
                snapshot: snapshot,
                maxBytes: capability.maxBytes,
                api: api
            )
            return .bytes(snapshot.bytes, editedText: editedText, resolvedHostPath: nil)
        }
        if configuration.source == .hostFile {
            let file = try await api.browseHostFileContent(
                path: path, controlSessionId: configuration.controlSessionId
            )
            guard isCurrentFile(path) else { return nil }
            return .bytes(file.data, editedText: nil, resolvedHostPath: file.resolvedPath)
        }
        let data = try await fileAccess.browseFile(api: api, path: path)
        guard isCurrentFile(path) else { return nil }
        return .bytes(data, editedText: nil, resolvedHostPath: nil)
    }

    private func readerPhase(
        data: Data,
        editedText: String?,
        path: String,
        category: FilePreviewCategory
    ) -> Phase {
        if configuration.source == .hostFile, HostFilePreviewPolicy.usesStringFetchViewer(for: path) {
            if FileType.detect(from: path) == .html,
               let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
            return .image(data)
        }
        switch category {
        case .image: return .image(data)
        case .pdf: return .pdf(data)
        case .text:
            if let editedText { return .text(editedText) }
            if let text = String(data: data, encoding: .utf8) { return .text(text) }
            return .binary
        default:
            return .binary
        }
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

    private func loadTimedText(api: APIClient, path: String, kind: TimedText.MediaKind) async {
        let result = await fileAccess.loadTimedText(api: api, path: path, kind: kind)
        guard isCurrentFile(path) else { return }
        timedTextLoadFinished = true
        timedText = result
    }

    private func makeTimedTextLoader(
        path: String,
        kind: TimedText.MediaKind
    ) -> (() async -> TimedText.LoadResult)? {
        guard let api = loadedApiClient ?? services.apiClient() else { return nil }
        let access = fileAccess
        return { await access.loadTimedText(api: api, path: path, kind: kind) }
    }

    private func isCurrentFile(_ requestedPath: String) -> Bool {
        !Task.isCancelled && currentFilePath == requestedPath
    }

    private func beginUSDZSafeLoading() {
        releaseLoadedUSDZHandle()
        content = .loading
    }

    private func releaseLoadedUSDZHandle() {
        guard case .usdz(let handle) = content else { return }
        content = .loading
        Task { await USDZLocalFileStore.shared.release(handle) }
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
        beginUSDZSafeLoading()
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
    private func navigateBack() {
        if let onBackNavigation {
            onBackNavigation()
            return
        }
        Router.finish(stackScreen)
    }
}

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
    static func pushReader(_ request: Request, navigator: ScreenNavigator) {
        navigator.push(viewer(request, chromeMode: .pushed))
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
                sessionStore: services.connection.sessionStore
            )
        )
        viewer.markdownViewportRestore = request.viewportRestore
        return viewer
    }
}
