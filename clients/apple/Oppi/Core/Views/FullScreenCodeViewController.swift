import Observation
import UIKit

/// Full-screen content viewer for tool output (UIKit).
///
/// Supports code (with syntax highlighting), diff, and markdown modes.
/// Presented directly from UIKit timeline cells.
///
/// Supports these presentation modes:
/// - `.sheet`: standalone presentation with its own dismiss button (chevron.down).
///   Used by timeline full-screen.
/// - `.embedded(onDismiss:)`: embedded in a pushed screen. Shows a
///   back button (chevron.backward) that calls the provided closure.
/// - `.pane(title:onDismiss:)`: the root of a trailing side pane. Shows the
///   file name and a Close X like the other panes.
/// - `.contentOnly`: embedded as pane content without internal navigation chrome.
///
/// Swipe behavior follows the visible chrome: modal down-chevron chrome uses a
/// downward dismissal swipe; embedded/content-only back uses a rightward swipe.

final class FullScreenCodeViewController: UIViewController {

    /// Controls how the viewer presents its dismiss affordance.
    enum PresentationMode {
        /// Standalone sheet/fullScreenCover — chevron.down + `dismiss(animated:)`.
        case sheet
        /// Embedded in a pushed screen — chevron.backward + closure.
        case embedded(onDismiss: @MainActor @Sendable () -> Void)
        /// The root of a trailing side pane, beside the chat: the title names
        /// the file, which is otherwise ambiguous there, and X closes the pane.
        case pane(title: String, onDismiss: @MainActor @Sendable () -> Void)
        /// Embedded pane content without a navigation bar or dismiss affordance.
        /// A parent can still provide a back-swipe action so content-only panes
        /// keep the app-wide right-swipe-back invariant without rendering chrome.
        case contentOnly(onBackSwipe: (@MainActor @Sendable () -> Void)? = nil)
    }

    private struct Presentation {
        let bodyContent: FullScreenCodeContent
        let copyText: String
        let sourceToggleTitle: String?
        let readerFamily: FullScreenReaderContentFamily?
        let readerPreferences: FullScreenReaderPreferences?
    }

    /// Interaction state owned by a palette-capturing UIKit body. Views are
    /// rebuilt for a theme change, so preserve equivalent descendant state by
    /// stable traversal order before replacing the hierarchy.
    /// Chrome identity that a text chunk does not change. Rebuilding bar
    /// items on every chunk drops the button the reader already has.
    private struct NavigationPresentation: Equatable {
        let sourceToggleTitle: String?
        let readerFamily: FullScreenReaderContentFamily?

        init(_ presentation: Presentation) {
            sourceToggleTitle = presentation.sourceToggleTitle
            readerFamily = presentation.readerFamily
        }
    }

    private struct BodyInteractionState {
        let scrollOffsets: [CGPoint]
        let selections: [NSRange]
        let firstResponderTextViewIndex: Int?
        let viewportIntent: FullScreenMarkdownViewportIntent?
    }

    private let content: FullScreenCodeContent
    private let presentationMode: PresentationMode
    private let reviewCommentSelectionContext: ReviewCommentSelectionContext?
    private var pendingMarkdownViewportIntent: FullScreenMarkdownViewportIntent?
    private let onMarkdownViewportIntentChange: ((FullScreenMarkdownViewportIntent) -> Void)?
    private let lineAnchor: SourceLineAnchor?
    /// The heading the reader opens at, until a restored reading position outranks it.
    private let headingAnchor: ReaderHeadingAnchor?
    /// Set when the reader's owner can save the document.
    private let taskEditing: ReaderTaskEditing?
    private let orgFolds: OrgFoldMemory?
    private let lineAnchorNotice: (@MainActor @Sendable (String) -> Void)?
    private var lineAnchorNoticeDelivered = false
    /// What the screen that owns this reader adds to its bar: the document's
    /// Edit, and the previous and next file. `hostMenu` joins the … menu.
    private var hostOffers: [ReaderBarAction: [UIBarButtonItem]]
    private var hostMenu: [UIMenuElement]
    /// The bar's layout over what the reader offers, and its … menu.
    private(set) lazy var readerBar: ReaderBar = {
        let bar = ReaderBar()
        bar.presenter = self
        bar.onLayoutChange = { [weak self] in
            guard let self, let host = contentHostController else { return }
            installRightBarItems(on: host, palette: bodyThemeID.palette)
        }
        return bar
    }()
    private var lastNavigationPresentation: NavigationPresentation?
    /// Back, embedded in a pushed screen, or the sheet's and pane's close.
    private var dismissItem: UIBarButtonItem?
    /// The main pane's sidebar button, drawn after Back in this reader's own
    /// bar while it reads in the main pane (`MainPaneSidebarItem`).
    private lazy var sidebarItem = UIBarButtonItem(
        image: UIImage(systemName: "sidebar.leading"),
        primaryAction: UIAction { [weak self] _ in self?.mainPaneSidebarItem?.toggle() }
    )
    private var showSource = false
    private var largeFileNote: LargeFileNoteView?
    private var completeRawText: String?
    private var rawSidecarTask: Task<Void, Never>?
    private var copyButton: UIBarButtonItem?
    /// The reader's Outline bar item, the popover's anchor (`FullScreenCodeViewController+ReaderNavigation`).
    var outlineBarItem: UIBarButtonItem?
    private weak var viewingOptionsController: FullScreenViewingOptionsController?
    private(set) weak var contentHostController: UIViewController?
    private var viewingOptionsBarItem: UIBarButtonItem?
    /// `.contentOnly` draws no bar: Find, Outline, Copy, the source toggle,
    /// and Viewing Options go to the embedding screen's bar instead
    /// (`onBarOffersChange`).
    private(set) var barOffers: [ReaderBarAction: [UIBarButtonItem]] = [:]
    /// Runs when `barOffers` change, so the embedding screen lays out its bar.
    var onBarOffersChange: (() -> Void)?
    private var annotateBarItem: UIBarButtonItem?
    private var stashBarItem: UIBarButtonItem?
    private var backSwipeDismissHandler: HorizontalBackSwipeGestureInstaller?
    private(set) var installedBodyView: (any ReaderBody)?
    /// The body's trailing edge, and the width it is held at during a live resize (`+LiveResize`).
    var bodyWidthEdges: (trailing: NSLayoutConstraint, held: NSLayoutConstraint?)?
    /// The installed body's one observation of its live trace.
    private var traceObservation: ReaderTraceToken?
    /// Where the rendered body was read before Source; a streaming source
    /// returns there when Source toggles back.
    private var sourceToggleViewportIntent: FullScreenMarkdownViewportIntent?
    private var appliedThemeID: ThemeID?
    private var annotateButton: UIButton?
    private var pickButton: UIButton?
    private var commentButton: UIButton?
    private var commentLeadingConstraint: NSLayoutConstraint?
    private var commentTopConstraint: NSLayoutConstraint?
    private var markupBottomConstraint: NSLayoutConstraint?
    private var pickBottomConstraint: NSLayoutConstraint?
    private let stashButton = ReviewCommentStashFloatingButton()
    private var isSnapshotting = false
    private let addToChatDestination: ComposerCanvasDestination?
    private(set) var didDismissAfterCanvasDeliveryForTesting = false

    private var bodyThemeID: ThemeID {
        appliedThemeID ?? ThemeRuntimeState.currentThemeID()
    }

    init(
        content: FullScreenCodeContent,
        presentationMode: PresentationMode = .sheet,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
        reviewCommentSessionId: String? = nil,
        reviewCommentSourceLabel: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        lineAnchorNotice: (@MainActor @Sendable (String) -> Void)? = nil,
        headingAnchor: ReaderHeadingAnchor? = nil,
        hostOffers: [ReaderBarAction: [UIBarButtonItem]] = [:],
        hostMenu: [UIMenuElement] = [],
        markdownViewportIntent: FullScreenMarkdownViewportIntent? = nil,
        onMarkdownViewportIntentChange: ((FullScreenMarkdownViewportIntent) -> Void)? = nil,
        taskEditing: ReaderTaskEditing? = nil,
        orgFolds: OrgFoldMemory? = nil,
        addToChatDestination: ComposerCanvasDestination? = nil
    ) {
        self.content = content
        // A file too large to format opens on its plain text (`opensPlain`).
        self.showSource = content.opensPlain
        self.taskEditing = taskEditing
        self.orgFolds = orgFolds
        self.presentationMode = presentationMode
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
            ?? ReviewCommentSelectionContext(
                router: reviewCommentSelectionRouter,
                sessionId: reviewCommentSessionId,
                sourceLabel: reviewCommentSourceLabel
            )
        self.lineAnchor = lineAnchor
        self.headingAnchor = headingAnchor
        self.lineAnchorNotice = lineAnchorNotice
        self.hostOffers = hostOffers
        self.hostMenu = hostMenu
        self.pendingMarkdownViewportIntent = markdownViewportIntent
        self.onMarkdownViewportIntentChange = onMarkdownViewportIntentChange
        self.addToChatDestination = addToChatDestination
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Capture origin at present time. Nested viewers inherit the parent
    /// viewer's destination, including nil, so later chats cannot steal it.
    static func capturedAddToChatDestination(
        from presenter: UIViewController
    ) -> ComposerCanvasDestination? {
        if let code = presenter as? FullScreenCodeViewController {
            return code.addToChatDestination
        }
        if let navigation = presenter as? UINavigationController,
           let code = navigation.viewControllers.compactMap({ $0 as? FullScreenCodeViewController }).last {
            return code.addToChatDestination
        }
        return ComposerCanvasDestinationResolver.resolve(from: presenter)
    }

    var allowsFocusedVisualPreview: Bool {
        if case .markdown = content.readingContent {
            return true
        }
        return false
    }

    deinit {
        rawSidecarTask?.cancel()
        NotificationCenter.default.removeObserver(self, name: .oppiThemeDidChange, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard let intent = currentMarkdownViewportIntent() else { return }
        // Unlaid-out remakes and remakes whose stored restore has not settled
        // return nil above. A settled, laid-out reader at the title records
        // `.top` and replaces a stored mid-document restore.
        onMarkdownViewportIntentChange?(intent)
    }

    /// A parent that mounts a new reader in place of this one (after a task
    /// control saves) removes it with no appearance change, so the reading
    /// position is reported here too.
    override func willMove(toParent parent: UIViewController?) {
        if parent == nil, let intent = currentMarkdownViewportIntent() {
            onMarkdownViewportIntentChange?(intent)
        }
        super.willMove(toParent: parent)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChangeNotification),
            name: .oppiThemeDidChange,
            object: nil
        )
        observeVoiceOverStatusChanges()

        let themeID = appliedThemeID ?? ThemeRuntimeState.currentThemeID()
        appliedThemeID = themeID
        let palette = themeID.palette
        view.backgroundColor = palette.ui.bgDark
        setupBackSwipeDismissIfNeeded()

        let nav = UINavigationController(rootViewController: makeContentController())
        if case .contentOnly = presentationMode {
            nav.setNavigationBarHidden(true, animated: false)
        }
        // Disable internal interactive pop — this nav only has one root VC.
        // Prevents conflict with the hosting SwiftUI navigation's swipe-back
        // when in embedded mode.
        nav.interactivePopGestureRecognizer?.isEnabled = false
        nav.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(nav)
        view.addSubview(nav.view)
        NSLayoutConstraint.activate([
            nav.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nav.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            nav.view.topAnchor.constraint(equalTo: view.topAnchor),
            nav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        nav.didMove(toParent: self)
    }

    @objc private func handleThemeChangeNotification(_: Notification) {
        applyThemeIfNeeded(ThemeRuntimeState.currentThemeID())
    }

    /// The owning screen's bar items (`hostOffers`) and … menu items.
    func setHostBar(offers: [ReaderBarAction: [UIBarButtonItem]], menu: [UIMenuElement]) {
        let sameOffers = offers.count == hostOffers.count && offers.allSatisfy { action, items in
            hostOffers[action].map { $0.elementsEqual(items, by: ===) } ?? false
        }
        guard !sameOffers || !menu.elementsEqual(hostMenu, by: ===) else { return }
        hostOffers = offers
        hostMenu = menu
        lastNavigationPresentation = nil
        guard isViewLoaded, let viewController = contentHostController else { return }
        configureNavigation(on: viewController, palette: bodyThemeID.palette)
    }

    /// Rebuild persistent UIKit content and chrome when SwiftUI's active theme
    /// changes. Full-screen bodies capture a palette at construction time, so
    /// merely invalidating the representable leaves code, markdown, diff,
    /// terminal, and rendered-document viewers in the previous appearance.
    func applyThemeIfNeeded(_ themeID: ThemeID) {
        guard isViewLoaded, let viewController = contentHostController else {
            appliedThemeID = themeID
            return
        }
        guard appliedThemeID != themeID else { return }

        appliedThemeID = themeID
        let palette = themeID.palette
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = palette.ui.bgDark
        viewController.view.backgroundColor = palette.ui.bgDark

        let interactionState = installedBodyView.map(captureInteractionState)
        let themedBody = installBody(on: viewController, focusLineAnchor: false)
        if let interactionState {
            restoreInteractionState(interactionState, in: themedBody, host: viewController.view)
        }

        // Force navigation items to be rebuilt because their tint colors are
        // also captured UIKit values rather than dynamic SwiftUI styles.
        lastNavigationPresentation = nil
        configureNavigation(on: viewController, palette: palette)
    }

    private func captureInteractionState(in body: any ReaderBody) -> BodyInteractionState {
        let scrollViews = descendantViews(of: UIScrollView.self, in: body)
        let textViews = descendantViews(of: UITextView.self, in: body)
        return BodyInteractionState(
            scrollOffsets: scrollViews.map(\.contentOffset),
            selections: textViews.map(\.selectedRange),
            firstResponderTextViewIndex: textViews.firstIndex(where: \.isFirstResponder),
            viewportIntent: body.viewportIntent
        )
    }

    private func restoreInteractionState(
        _ state: BodyInteractionState,
        in body: any ReaderBody,
        host: UIView
    ) {
        host.setNeedsLayout()
        host.layoutIfNeeded()

        let scrollViews = descendantViews(of: UIScrollView.self, in: body)
        for (scrollView, offset) in zip(scrollViews, state.scrollOffsets) {
            scrollView.setContentOffset(offset, animated: false)
        }

        let textViews = descendantViews(of: UITextView.self, in: body)
        for (textView, selection) in zip(textViews, state.selections) {
            let textLength = (textView.attributedText?.length) ?? (textView.text as NSString?)?.length ?? 0
            let location = min(selection.location, textLength)
            let length = min(selection.length, max(0, textLength - location))
            textView.selectedRange = NSRange(location: location, length: length)
        }
        if let index = state.firstResponderTextViewIndex,
           textViews.indices.contains(index) {
            textViews[index].becomeFirstResponder()
        }
        if let intent = state.viewportIntent {
            body.restoreViewport(intent)
        }

        // Some bodies complete TextKit/WebKit layout on the next run-loop turn.
        // Reapply to the same new body without retaining the retired hierarchy.
        DispatchQueue.main.async { [weak body, weak host] in
            guard let body, let host else { return }
            host.layoutIfNeeded()
            let deferredScrollViews = self.descendantViews(of: UIScrollView.self, in: body)
            for (scrollView, offset) in zip(deferredScrollViews, state.scrollOffsets) {
                scrollView.setContentOffset(offset, animated: false)
            }
            if let intent = state.viewportIntent {
                body.restoreViewport(intent)
            }
        }
    }

    private func descendantViews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var matches: [T] = []
        if let match = root as? T {
            matches.append(match)
        }
        for child in root.subviews {
            matches.append(contentsOf: descendantViews(of: type, in: child))
        }
        return matches
    }

    private func setupBackSwipeDismissIfNeeded() {
        let handler: HorizontalBackSwipeGestureInstaller?
        switch presentationMode {
        case .contentOnly(let onBackSwipe):
            guard let onBackSwipe else { return }
            handler = HorizontalBackSwipeGestureInstaller { onBackSwipe() }
        case .sheet:
            handler = HorizontalBackSwipeGestureInstaller(
                onBack: { [weak self] in
                    self?.doneTapped()
                },
                direction: FullScreenViewerNavigationChrome.DismissMode.modal.gestureDirection
            )
        case .embedded, .pane:
            handler = HorizontalBackSwipeGestureInstaller(
                onBack: { [weak self] in
                    self?.doneTapped()
                },
                direction: FullScreenViewerNavigationChrome.DismissMode.embedded.gestureDirection
            )
        }
        handler?.install(on: view)
        backSwipeDismissHandler = handler
    }

    private func makeContentController() -> UIViewController {
        let palette = bodyThemeID.palette
        let vc = FullScreenContentHostController()
        vc.onVerticalBarEdgeChange = { [weak self] in
            guard let self, let host = self.contentHostController else { return }
            self.installRightBarItems(on: host, palette: self.bodyThemeID.palette)
        }
        vc.view.backgroundColor = palette.ui.bgDark

        let dismissMode: FullScreenViewerNavigationChrome.DismissMode?
        switch presentationMode {
        case .sheet:
            dismissMode = .modal
        case .embedded:
            dismissMode = .embedded
        case .pane(let title, _):
            dismissMode = .pane
            vc.navigationItem.title = title
        case .contentOnly:
            dismissMode = nil
        }
        if let dismissMode {
            dismissItem = FullScreenViewerNavigationChrome.makeDismissButton(
                mode: dismissMode,
                target: self,
                action: #selector(doneTapped),
                palette: palette,
                // One id for the leave control in every presentation mode.
                accessibilityIdentifier: "fullScreen.code.close"
            )
            vc.navigationItem.leftBarButtonItem = dismissItem
        }

        contentHostController = vc

        // No custom UINavigationBarAppearance — iOS 26 Liquid Glass renders
        // bar items as floating glass pills. See FullScreenViewerChrome.

        installInitialBody(on: vc)
        configureNavigation(on: vc, palette: palette)

        return vc
    }

    private func installInitialBody(on viewController: UIViewController) {
        installBody(on: viewController, focusLineAnchor: shouldFocusLineAnchorWhileRestoring)
    }

    /// A captured mid-document viewport wins over the original wiki line
    /// anchor when the same markdown file is rebuilt after a linked-file push.
    private var shouldFocusLineAnchorWhileRestoring: Bool {
        switch pendingMarkdownViewportIntent {
        case nil, .top:
            return true
        case .tail, .detached:
            return false
        }
    }

    private func installBodyView(_ bodyView: any ReaderBody, on viewController: UIViewController) {
        installedBodyView?.removeFromSuperview()
        installedBodyView = bodyView
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        viewController.view.addSubview(bodyView)
        // A body that takes the whole page fades the reader's own controls; it
        // draws its own chrome, so it knows when reading should be alone on
        // screen. A rebuilt body starts with them shown.
        setImmersiveChromeHidden(false, animated: false)
        bodyView.onImmersiveChromeChange = { [weak self] hidden in
            self?.setImmersiveChromeHidden(hidden, animated: true)
        }
        // A body on its own paper paints the chrome over it in that paper.
        contentSurface = bodyView.contentSurface
        bodyView.onContentSurfaceChange = { [weak self] surface in self?.setContentSurface(surface) }
        bodyView.onOutlineChange = { [weak self] in
            guard let self, let host = self.contentHostController else { return }
            self.installRightBarItems(on: host, palette: self.bodyThemeID.palette)
        }
        applyContentSurface()
        // The new body draws its own chrome, so the reader's starts shown until
        // that body says otherwise.
        // Top pinned to view edge (not safe area) so content scrolls behind
        // the navigation bar's Liquid Glass pills. See FullScreenViewerChrome.
        let bodyTrailing = bodyView.trailingAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.trailingAnchor)
        bodyWidthEdges = (bodyTrailing, nil)
        NSLayoutConstraint.activate([
            bodyView.leadingAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.leadingAnchor),
            bodyTrailing,
            bodyView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            bodyView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
        ])
        if let annotateButton {
            viewController.view.bringSubviewToFront(annotateButton)
        }
        if let pickButton {
            viewController.view.bringSubviewToFront(pickButton)
        }
        if let commentButton {
            viewController.view.bringSubviewToFront(commentButton)
        }
        if let picker = bodyView.picker {
            picker.usesExternalPickControls = true
            // Also fires when a page's render state changes, which is when
            // Annotate can start snapshotting it.
            picker.onPickStateChange = { [weak self] _, _ in
                self?.updateAnnotateAvailability()
            }
            picker.onSelectionGeometryChange = { [weak self] in
                self?.updateContextualCommentPosition()
            }
        }
        stashButton.bringToFront()
        updateLargeFileNote(on: viewController)
        restorePendingMarkdownViewportIfNeeded(in: bodyView)
        scheduleLineAnchorNotice()
        updateAnnotateAvailability()
        updateBodyBottomInset()
    }

    private func currentMarkdownViewportIntent() -> FullScreenMarkdownViewportIntent? {
        // A remake can take one layout pass at offset 0 before the stored
        // restore write runs. That looks like `.top` and must not replace the
        // stored mid-document intent.
        // The body answers nil until then.
        guard let intent = installedBodyView?.viewportIntent else { return nil }
        // Offset 0 before the first layout is indistinguishable from `.top`.
        if intent == .top, !hasLaidOutMarkdownViewport {
            return nil
        }
        return intent
    }

    private var hasLaidOutMarkdownViewport: Bool {
        guard let body = installedBodyView else { return false }
        return descendantViews(of: UIScrollView.self, in: body).contains { scrollView in
            scrollView.bounds.height > 0 && scrollView.contentSize.height > 0
        }
    }

    private func restorePendingMarkdownViewportIfNeeded(in body: any ReaderBody) {
        guard let intent = pendingMarkdownViewportIntent,
              body.restoreViewport(intent) else { return }
        pendingMarkdownViewportIntent = nil
    }

    private func scheduleLineAnchorNotice() {
        guard lineAnchor != nil, !lineAnchorNoticeDelivered else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reportLineAnchorNoticeIfNeeded()
        }
    }

    private func reportLineAnchorNoticeIfNeeded() {
        guard let lineAnchor, !lineAnchorNoticeDelivered else { return }
        let resolution = content.lineAnchorResolution(for: lineAnchor)
        guard let message = resolution.message else { return }
        lineAnchorNoticeDelivered = true
        lineAnchorNotice?(message)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func configureNavigation(on viewController: UIViewController, palette: ThemePalette) {
        let presentation = makePresentation()
        // No titleView — immersive mode shows only floating glass pills.
        // See FullScreenViewerChrome.
        configureFloatingAnnotateButton(on: viewController, palette: palette)
        configureFloatingStashButton(on: viewController, palette: palette)
        updateAnnotateAvailability()

        let navigationPresentation = NavigationPresentation(presentation)
        defer { updateViewingOptions(presentation: presentation) }
        guard navigationPresentation != lastNavigationPresentation else {
            // A chunk can recreate a floating control. Keep it off the rail
            // without replacing the bar items the reader already has.
            syncFloatingControlVisibility(on: viewController)
            return
        }
        lastNavigationPresentation = navigationPresentation
        installRightBarItems(on: viewController, palette: palette)
        // A control built after the body asked for the page alone stays out of the way.
        setImmersiveChromeHidden(isImmersiveChromeHidden, animated: false)
        applyContentSurface()
        updateBodyBottomInset()
    }

    private func syncFloatingControlVisibility(on viewController: UIViewController) {
        let sideRail = SystemVerticalBar.isActive(viewController)
        annotateButton?.isHidden = sideRail
        stashButton.isHidden = sideRail
        updateBodyBottomInset()
    }

    /// The body scrolls its last line above the floating controls left in the
    /// bottom corners: Annotate (leading) and Pick (trailing). Viewing Options
    /// and the host's previous and next file are bar items (`ReaderBar`).
    private func updateBodyBottomInset() {
        func shown(_ control: UIView?) -> Int { control?.superview != nil && control?.isHidden == false ? 1 : 0 }
        let rows = max(shown(annotateButton), shown(pickButton))
        let chrome = FullScreenFloatingControlChrome.self
        let inset = rows == 0 ? 0 : chrome.bottomPadding
            + CGFloat(rows) * chrome.controlSize
            + CGFloat(rows - 1) * chrome.stackSpacing
            + chrome.stackSpacing
        installedBodyView?.setBottomContentInset(inset)
    }

    /// True while a body asked for the reader's controls to be out of the way. A
    /// book read as pages does: the page is the only thing on screen until a tap
    /// in the middle of it brings the controls back.
    private(set) var isImmersiveChromeHidden = false

    /// Fades the bar items and the floating pills together. The bar keeps its
    /// place, so the content keeps the safe area it laid out with; VoiceOver
    /// keeps the controls, because a control that cannot be found is a reader
    /// that cannot be left.
    func setImmersiveChromeHidden(_ hidden: Bool, animated: Bool) {
        let next = ReaderChromeVisibility.isHidden(
            wantsHidden: hidden,
            voiceOverRunning: UIAccessibility.isVoiceOverRunning
        )
        let changed = next != isImmersiveChromeHidden
        isImmersiveChromeHidden = next
        // The set of controls changes as the reader builds them (the bar appears
        // after its host), so every call writes the state to all of them; only a
        // change earns the fade.
        let views = immersiveChromeViews
        for view in views {
            view.isUserInteractionEnabled = !next
            view.accessibilityElementsHidden = next
        }
        // Controls are rebuilt as the reader changes, so the newest are inked again.
        applyContentSurface()
        guard changed, animated, !UIAccessibility.isReduceMotionEnabled else {
            for view in views { view.alpha = next ? 0 : 1 }
            return
        }
        UIView.animate(withDuration: 0.22) {
            for view in views { view.alpha = next ? 0 : 1 }
        }
    }

    /// The paper the installed body draws on, when it is not the app's reader
    /// background; the reader paints the chrome it floats over it in that paper.
    private var contentSurface: ReaderContentSurface?

    private func setContentSurface(_ surface: ReaderContentSurface?) {
        guard surface != contentSurface else { return }
        contentSurface = surface
        applyContentSurface()
    }

    /// A body with no paper of its own leaves the app theme's chrome as installed.
    private var chromeCarriesContentSurface = false

    private func applyContentSurface() {
        guard contentSurface != nil || chromeCarriesContentSurface else { return }
        chromeCarriesContentSurface = contentSurface != nil
        let item = contentHostController?.navigationItem
        ReaderChromeSurfacePainter.paint(
            contentSurface,
            palette: bodyThemeID.palette,
            buttons: [annotateButton, pickButton, commentButton, stashButton.button],
            bar: contentHostController?.navigationController?.navigationBar,
            items: (item?.leftBarButtonItems ?? []) + (item?.rightBarButtonItems ?? [])
                + [item?.leftBarButtonItem, item?.rightBarButtonItem].compactMap { $0 }
        )
    }

    /// What the reader draws over the content: the bar it installed and its
    /// floating controls.
    private var immersiveChromeViews: [UIView] {
        var views: [UIView] = []
        if let bar = contentHostController?.navigationController?.navigationBar {
            views.append(bar)
        }
        for control in [annotateButton, pickButton, commentButton, stashButton.button] {
            if let control { views.append(control) }
        }
        return views
    }

    /// Sole writer of the content host's right bar items and … menu: what the
    /// reader offers, laid out by the person's Reader Bar (`ReaderBar`).
    /// Persistent viewer controls join the side rail when the system says the
    /// bar is vertical.
    private func installRightBarItems(on viewController: UIViewController, palette: ThemePalette) {
        let presentation = makePresentation()
        let sideRail = SystemVerticalBar.isActive(viewController)
        var offers = makeReaderNavigationItems(palette: palette).merging(hostOffers) { own, _ in own }

        let copyImage = UIImage(systemName: "doc.on.doc")
        // A table copies as TSV or Markdown, so Copy asks which.
        let copy = installedBodyView?.makeCopyMenu { [weak self] in self?.finishCopy($0) }
            .map { UIBarButtonItem(image: copyImage, menu: $0) }
            ?? UIBarButtonItem(image: copyImage, style: .plain, target: self, action: #selector(copyTapped))
        // Titled, so a … menu that holds Copy names it.
        copy.title = ReaderBarAction.copy.label
        copy.tintColor = palette.ui.fgDim
        copy.accessibilityIdentifier = "fullscreen-code.copy"
        copyButton = copy
        offers[.copy] = [copy]
        // The host's Share sends the file it read, which outranks the reader's text.
        if offers[.share] == nil, let shareable = shareableContent() {
            offers[.share] = [FullScreenViewerNavigationChrome.makeShareButton(for: shareable, from: self, palette: palette)]
        }

        if presentation.sourceToggleTitle != nil, let sourceTitle = content.sourceToggleTitle(showingSource: false) {
            offers[.sourceToggle] = [makeSourceToggle(title: sourceTitle, palette: palette)]
        }

        viewingOptionsBarItem = nil
        annotateBarItem = nil
        stashBarItem = nil
        if presentation.readerFamily != nil {
            let item = railItem(
                symbol: FullScreenViewingOptionsSymbols.readerModeIconName,
                title: String(localized: "Viewing Options"),
                action: #selector(showViewingOptions)
            )
            item.accessibilityIdentifier = "fullscreen.viewingOptions.button"
            item.accessibilityHint = String(localized: "Adjust text size, wrapping, and spacing")
            item.tintColor = palette.ui.fgDim
            viewingOptionsBarItem = item
            offers[.viewingOptions] = [item]
        }
        if sideRail {
            if annotateButton != nil {
                let item = railItem(
                    symbol: PaperMarkupCanvasSession.AnnotateAction.systemImage,
                    title: PaperMarkupCanvasSession.AnnotateAction.title,
                    action: #selector(annotateRenderedViewTapped)
                )
                item.isEnabled = annotateButton?.isEnabled ?? false
                annotateBarItem = item
                offers[.annotate] = [item]
            }
            if let floatingStash = stashButton.button {
                let item = railItem(
                    symbol: FullScreenReviewCommentStashControl.systemImage,
                    title: FullScreenReviewCommentStashControl.accessibilityLabel,
                    action: #selector(stashButtonTapped)
                )
                item.badge = .count(stashButton.count)
                item.accessibilityValue = floatingStash.accessibilityValue
                stashBarItem = item
                offers[.stash] = [item]
            }
        }

        syncFloatingControlVisibility(on: viewController)
        if case .contentOnly = presentationMode {
            // The embedding screen's bar shows these, in its own tint; an item
            // is in one bar only, so the hidden one here stays empty.
            let exported = offers.filter { [.find, .outline, .copy, .sourceToggle, .viewingOptions].contains($0.key) }
            exported.values.joined().forEach { $0.tintColor = nil }
            barOffers = exported
            onBarOffersChange?()
            return
        }
        readerBar.update(offers: offers, documentActions: hostMenu)
        viewController.navigationItem.rightBarButtonItems = readerBar.trailingItems
        viewController.navigationItem.additionalOverflowItems = readerBar.overflow
        // New items carry the app palette's tints; a body on paper wants its ink.
        applyContentSurface()
    }

    /// The source toggle: an icon like the bar's other buttons, so they stay
    /// one glass group (a text button starts a group of its own), titled with
    /// the view it shows ("Source", "Raw", or an HTML diff's "Render") and
    /// selected while it shows it. In a … menu it is the same toggle with a
    /// checkmark, so its title reads the same either way.
    private func makeSourceToggle(title: String, palette: ThemePalette) -> UIBarButtonItem {
        let image = UIImage(systemName: title == String(localized: "Render") ? "text.page" : "curlybraces")
        let toggle = UIBarButtonItem(image: image, style: .plain, target: self, action: #selector(toggleSource))
        toggle.title = title
        toggle.isSelected = showSource
        toggle.accessibilityIdentifier = "fileViewer.sourceToggle"
        toggle.tintColor = palette.ui.fgDim
        let menuToggle = UIAction(title: title, image: image, state: showSource ? .on : .off) { [weak self] _ in
            self?.toggleSource()
        }
        menuToggle.accessibilityIdentifier = "fileViewer.sourceToggle"
        toggle.menuRepresentation = menuToggle
        return toggle
    }

    /// Viewing Options is a reader bar item (`installRightBarItems`); this
    /// keeps its spoken value and an open panel on the current preferences.
    private func updateViewingOptions(presentation: Presentation) {
        guard let readerFamily = presentation.readerFamily,
              let readerPreferences = presentation.readerPreferences else {
            viewingOptionsController?.dismiss(animated: true)
            return
        }
        viewingOptionsBarItem?.accessibilityValue = FullScreenViewingOptionsController.accessibilityValue(for: readerPreferences)
        viewingOptionsController?.apply(family: readerFamily, preferences: readerPreferences)
    }

    private func configureFloatingAnnotateButton(
        on viewController: UIViewController,
        palette: ThemePalette
    ) {
        guard let availability = installedBodyView?.annotateAvailability,
              availability != .unavailable else {
            annotateButton?.removeFromSuperview()
            pickButton?.removeFromSuperview()
            commentButton?.removeFromSuperview()
            annotateButton = nil
            pickButton = nil
            commentButton = nil
            commentLeadingConstraint = nil
            commentTopConstraint = nil
            markupBottomConstraint = nil
            pickBottomConstraint = nil
            return
        }

        let usesPickControls = installedBodyView?.picker != nil
        let button: UIButton
        if let existing = annotateButton {
            button = existing
            FullScreenFloatingControlChrome.updateStandaloneButton(button, palette: palette)
        } else {
            button = FullScreenFloatingControlChrome.makeStandaloneButton(
                systemImage: PaperMarkupCanvasSession.AnnotateAction.systemImage,
                accessibilityLabel: PaperMarkupCanvasSession.AnnotateAction.title,
                accessibilityIdentifier: PaperMarkupCanvasSession.AnnotateAction.htmlViewerIdentifier,
                palette: palette
            )
            annotateButton = button
            viewController.view.addSubview(button)
            button.addTarget(self, action: #selector(annotateRenderedViewTapped), for: .touchUpInside)
            markupBottomConstraint = FullScreenFloatingControlChrome.pinStandaloneButton(
                button, to: viewController.view, leading: true
            )
        }
        markupBottomConstraint?.constant = -markupBottomPadding
        if usesPickControls {
            let pick: UIButton
            if let existing = pickButton {
                pick = existing
                FullScreenFloatingControlChrome.updateStandaloneButton(pick, palette: palette)
            } else {
                pick = FullScreenFloatingControlChrome.makeStandaloneButton(
                    systemImage: "cursorarrow.rays",
                    accessibilityLabel: "Pick",
                    accessibilityIdentifier: "fullscreen-code.pick.menu",
                    palette: palette
                )
                pickButton = pick
                viewController.view.addSubview(pick)
                pick.translatesAutoresizingMaskIntoConstraints = false
                let bottom = pick.bottomAnchor.constraint(
                    equalTo: viewController.view.safeAreaLayoutGuide.bottomAnchor,
                    constant: -pickControlsBottomPadding
                )
                pickBottomConstraint = bottom
                NSLayoutConstraint.activate([
                    pick.trailingAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.trailingAnchor,
                                                  constant: -FullScreenFloatingControlChrome.trailingPadding),
                    bottom,
                    pick.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
                    pick.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
                ])
            }
            pickBottomConstraint?.constant = -pickControlsBottomPadding
            if commentButton == nil {
                let comment = FullScreenFloatingControlChrome.makeStandaloneButton(
                    systemImage: "text.bubble", accessibilityLabel: "Comment",
                    accessibilityIdentifier: "fullscreen-code.pick.comment", palette: palette
                )
                comment.addTarget(self, action: #selector(commentOnPickedTarget), for: .touchUpInside)
                commentButton = comment
                viewController.view.addSubview(comment)
                comment.translatesAutoresizingMaskIntoConstraints = false
                let leading = comment.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor)
                let top = comment.topAnchor.constraint(equalTo: viewController.view.topAnchor)
                commentLeadingConstraint = leading
                commentTopConstraint = top
                NSLayoutConstraint.activate([
                    leading, top,
                    comment.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
                    comment.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
                ])
            } else if let commentButton {
                FullScreenFloatingControlChrome.updateStandaloneButton(commentButton, palette: palette)
            }
            updatePickControls()
        }
        viewController.view.bringSubviewToFront(button)
        if let pickButton { viewController.view.bringSubviewToFront(pickButton) }
        if let commentButton { viewController.view.bringSubviewToFront(commentButton) }
    }

    private var pickControlsBottomPadding: CGFloat {
        FullScreenReviewCommentStashControl.bottomPadding(leadingAccessoryCount: 0)
    }

    private func updatePickControls() {
        guard let button = pickButton, let picker = installedBodyView?.picker else { return }
        commentButton?.isHidden = !picker.hasSelection
        updateContextualCommentPosition()
        let actions = picker.pickMenuActions()
        button.isEnabled = !actions.isEmpty
        button.menu = UIMenu(children: actions)
        button.showsMenuAsPrimaryAction = true
    }

    private func updateContextualCommentPosition() {
        guard let commentButton, let host = contentHostController?.view else { return }
        let target = installedBodyView?.picker?.selectedTargetRect(in: host)
        let controls = [pickButton, annotateButton].compactMap { control -> CGRect? in
            guard let control, !control.isHidden else { return nil }
            return control.convert(control.bounds, to: host)
        } + [stashButton.frame(in: host)].compactMap { $0 }
        guard let target,
              let origin = FullScreenPickCommentPlacement.origin(
                for: target, in: host.safeAreaLayoutGuide.layoutFrame, avoiding: controls,
                size: FullScreenFloatingControlChrome.controlSize
              ) else {
            commentButton.isHidden = true
            return
        }
        commentLeadingConstraint?.constant = origin.x
        commentTopConstraint?.constant = origin.y
        commentButton.isHidden = false
    }

    @objc private func commentOnPickedTarget() {
        installedBodyView?.picker?.commentOnSelection()
    }

    private var reviewCommentStash: (any ReviewCommentStashHandling)? {
        reviewCommentSelectionContext?.dispatcher.stash
    }

    /// UIKit tracks the count the stash button reads here and re-runs this when
    /// it changes, which also refreshes the rail item.
    override func updateProperties() {
        super.updateProperties()
        if case .embedded = presentationMode, let host = contentHostController {
            showMainPaneSidebar(on: host)
        }
        guard reviewCommentStash != nil, isViewLoaded, let host = contentHostController else { return }
        configureFloatingStashButton(on: host, palette: bodyThemeID.palette)
        installRightBarItems(on: host, palette: bodyThemeID.palette)
    }

    /// The bar is this reader's, so the stack's sidebar button is drawn again
    /// here; the stack asks for this pass when it changes the button.
    private func showMainPaneSidebar(on host: UIViewController) {
        let sidebar = mainPaneSidebarItem
        sidebarItem.title = sidebar?.title
        sidebarItem.accessibilityIdentifier = sidebar?.accessibilityIdentifier
        sidebarItem.tintColor = dismissItem?.tintColor
        let leading = [dismissItem, sidebar.map { _ in sidebarItem }].compactMap(\.self)
        let item = host.navigationItem
        guard !item.leadingItemGroups.flatMap(\.barButtonItems).elementsEqual(leading, by: ===) else { return }
        // Each in its own glass, as in the stack's bar.
        item.leadingItemGroups = leading.map { UIBarButtonItemGroup(barButtonItems: [$0], representativeItem: nil) }
    }

    private func configureFloatingStashButton(
        on viewController: UIViewController,
        palette: ThemePalette
    ) {
        stashButton.update(
            on: viewController.view,
            presenter: self,
            stash: reviewCommentStash,
            leadingAccessoryCount: stashLeadingAccessoryCount,
            palette: palette
        )
        if let annotateButton {
            viewController.view.bringSubviewToFront(annotateButton)
        }
        viewController.view.layoutIfNeeded()
        updateContextualCommentPosition()
    }

    private var markupBottomPadding: CGFloat {
        FullScreenReviewCommentStashControl.bottomPadding(leadingAccessoryCount: 0)
    }

    /// The stash sits above Annotate.
    private var stashLeadingAccessoryCount: Int {
        annotateButton?.superview != nil ? 1 : 0
    }

    @objc private func stashButtonTapped() {
        stashButton.openSheet()
    }

    private func makePresentation() -> Presentation {
        let bodyContent = content.bodyContent(showingSource: showSource, completeRaw: completeRawText)
        let readerFamily = bodyContent.readerFamily
        return Presentation(
            bodyContent: bodyContent,
            copyText: content.copyText(showingSource: showSource, completeRaw: completeRawText),
            sourceToggleTitle: content.sourceToggleTitle(showingSource: showSource),
            readerFamily: readerFamily,
            readerPreferences: readerFamily.map { FullScreenReaderPreferencesStore.shared.preferences(for: $0) }
        )
    }

    // MARK: - Body

    private func bodyContext(themeID: ThemeID, focusLineAnchor: Bool) -> ReaderBodyContext {
        ReaderBodyContext(
            themeID: themeID,
            selection: reviewCommentSelectionContext,
            lineAnchor: lineAnchor,
            focusLineAnchor: focusLineAnchor,
            headingAnchor: focusLineAnchor ? headingAnchor : nil,
            headingNotice: lineAnchorNotice,
            taskEditing: taskEditing,
            orgFolds: orgFolds,
            adoptTrace: { [weak self] observation in
                self?.traceObservation = observation
            },
            rebuild: { [weak self] body, intent in
                self?.rebuildBody(replacing: body, at: intent)
            },
            refreshChrome: { [weak self] body in
                guard let self, self.installedBodyView === body, let host = self.contentHostController else { return }
                self.configureNavigation(on: host, palette: self.bodyThemeID.palette)
            }
        )
    }

    /// Builds and installs the body for the current presentation. The body a
    /// live trace feeds takes over the reader's one observation of it.
    @discardableResult
    private func installBody(on viewController: UIViewController, focusLineAnchor: Bool = true) -> any ReaderBody {
        traceObservation?.cancel()
        traceObservation = nil
        let body = makePresentation().bodyContent.makeFullScreenBody(
            bodyContext(themeID: bodyThemeID, focusLineAnchor: focusLineAnchor)
        )
        installBodyView(body, on: viewController)
        return body
    }

    /// A live body's trace outgrew it (finished, or changed kind): the content
    /// now reads as a different body, which opens where the old one was read.
    private func rebuildBody(replacing body: any ReaderBody, at intent: FullScreenMarkdownViewportIntent?) {
        guard installedBodyView === body, let viewController = contentHostController else { return }
        let rebuilt = installBody(on: viewController)
        if let intent {
            rebuilt.restoreViewport(intent)
        }
        configureNavigation(on: viewController, palette: bodyThemeID.palette)
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        switch presentationMode {
        case .sheet:
            dismiss(animated: true)
        case .embedded(let onDismiss), .pane(_, let onDismiss):
            onDismiss()
        case .contentOnly(let onBackSwipe):
            onBackSwipe?()
        }
    }

    @objc private func copyTapped() {
        if let live = installedBodyView?.liveCopyText {
            finishCopy(live)
            return
        }
        if let terminal = installedBodyView as? NativeFullScreenTerminalBody {
            // Small settled readers keep instant Copy; complete-sidecar and
            // virtualized copies do their materialization off the UI executor.
            if let text = terminal.immediateCopyText {
                finishCopy(text)
                return
            }
            Task { @MainActor [weak self] in
                guard let text = await terminal.resolvedCopyText(), !Task.isCancelled else { return }
                self?.finishCopy(text)
            }
        } else {
            finishCopy(makePresentation().copyText)
        }
    }

    private func finishCopy(_ text: String) {
        FullScreenCopyDestination.write(text)
        copyButton?.image = UIImage(systemName: "checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyButton?.image = UIImage(systemName: "doc.on.doc")
        }
    }

    @objc private func showViewingOptions() {
        let presentation = makePresentation()
        guard let family = presentation.readerFamily,
              let preferences = presentation.readerPreferences,
              viewingOptionsBarItem != nil else { return }

        if let existing = viewingOptionsController {
            existing.dismiss(animated: true)
            viewingOptionsController = nil
            return
        }

        let options = FullScreenViewingOptionsController(
            family: family,
            preferences: preferences,
            onTextScaleChanged: { [weak self] scale in
                self?.setReaderTextScale(scale)
            },
            onWrappingChanged: { [weak self] wraps in
                self?.setReaderWrapping(wraps)
            },
            onSpacingChanged: { [weak self] spacing in
                self?.setReaderSpacing(spacing)
            },
            onReset: { [weak self] in
                self?.resetReaderPreferences()
            }
        )
        options.onDismiss = { [weak self] dismissed in
            if self?.viewingOptionsController === dismissed {
                self?.viewingOptionsController = nil
            }
        }
        viewingOptionsController = options

        // Turned off, the item runs from the … menu and has no place to point
        // at, so the options open as a sheet.
        let onBar: Bool = if case .contentOnly = presentationMode {
            // The embedding screen, or a screen over it, shows the exported item.
            sequence(first: self as UIViewController, next: \.parent).contains { screen in
                screen.navigationItem.rightBarButtonItems?.contains { $0 === viewingOptionsBarItem } == true
            }
        } else {
            readerBar.trailingItems.contains { $0 === viewingOptionsBarItem }
        }
        options.configurePresentation(barItem: onBar ? viewingOptionsBarItem : nil)
        present(options, animated: true)
    }

    private func setReaderTextScale(_ scale: CGFloat) {
        updateReaderPreferences { preferences in
            preferences.textScale = FullScreenReaderPreferences.clampedTextScale(scale)
        }
    }

    private func setReaderWrapping(_ wraps: Bool) {
        updateReaderPreferences { preferences in
            preferences.wrapsText = wraps
        }
    }

    private func setReaderSpacing(_ spacing: FullScreenReaderSpacing) {
        updateReaderPreferences { preferences in
            preferences.spacing = spacing
        }
    }

    private func resetReaderPreferences() {
        let presentation = makePresentation()
        guard let family = presentation.readerFamily else { return }
        FullScreenReaderPreferencesStore.shared.resetPreferences(for: family)
        applyReaderPreferences(family.defaultPreferences)
    }

    private func updateReaderPreferences(_ mutate: (inout FullScreenReaderPreferences) -> Void) {
        let presentation = makePresentation()
        guard let family = presentation.readerFamily,
              var preferences = presentation.readerPreferences else { return }

        mutate(&preferences)
        FullScreenReaderPreferencesStore.shared.setPreferences(preferences, for: family)
        let normalized = FullScreenReaderPreferencesStore.shared.preferences(for: family)
        applyReaderPreferences(normalized)
    }

    private func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        installedBodyView?.applyReaderPreferences(preferences)

        guard let viewController = contentHostController else { return }
        configureNavigation(on: viewController, palette: bodyThemeID.palette)

        let presentation = makePresentation()
        if let family = presentation.readerFamily,
           let latestPreferences = presentation.readerPreferences {
            viewingOptionsController?.apply(family: family, preferences: latestPreferences)
        }
    }

    @objc private func annotateRenderedViewTapped() {
        guard let body = installedBodyView, body.annotateAvailability == .ready, !isSnapshotting else { return }
        isSnapshotting = true
        updateAnnotateAvailability()
        Task { @MainActor [self] in
            defer {
                isSnapshotting = false
                updateAnnotateAvailability()
            }
            do {
                let image = try await body.renderedSnapshot()
                PaperMarkupCanvasHostController.present(
                    background: .image(PaperMarkupCanvasSession.copiedImage(from: image)),
                    from: self,
                    destination: addToChatDestination,
                    onDeliveryAccepted: { [weak self] in
                        self?.handleAnnotateDeliveryAccepted()
                    }
                )
            } catch {
                presentPaperMarkupSnapshotFailure(error)
            }
        }
    }

    private func handleAnnotateDeliveryAccepted() {
        didDismissAfterCanvasDeliveryForTesting = true
        presentingViewController?.dismiss(animated: true)
    }

    private func updateAnnotateAvailability() {
        let enabled = installedBodyView?.annotateAvailability == .ready && !isSnapshotting
        annotateButton?.isEnabled = enabled
        annotateBarItem?.isEnabled = enabled
        updatePickControls()
    }

    // MARK: - Share

    private func shareableContent() -> FileShareService.ShareableContent? {
        content.shareableContent(showingSource: showSource, completeRaw: completeRawText)
    }

    private func loadRawSidecarIfNeeded() {
        guard rawSidecarTask == nil, completeRawText == nil,
              case .markdown(_, _, _, let rawText, let source) = content.readingContent,
              rawText != nil, let source,
              let inputPrefix = source.rawDocumentPrefix else { return }
        // Publish complete Raw only after every byte arrives. Missing windows,
        // cancellation and stopped-session 404s retain the explicit preview.
        rawSidecarTask = Task { [weak self] in
            defer { self?.rawSidecarTask = nil }
            do {
                guard let first = try await source.loadFirst() else { return }
                var output = first.text
                var offset = first.endByteOffset
                let total = first.totalBytes
                while offset < total {
                    guard !Task.isCancelled,
                          let next = try await source.loadNext(offset),
                          next.endByteOffset > offset, next.totalBytes == total else { return }
                    output += next.text
                    offset = next.endByteOffset
                }
                guard !Task.isCancelled, output.utf8.count == total else { return }
                self?.completeRawText = inputPrefix + output
                guard let self, self.showSource, let host = self.contentHostController else { return }
                self.installBody(on: host)
            } catch {
                // The preview remains the honest fallback if the sidecar is gone.
            }
        }
    }

    /// While a large file shows as plain text, a note at the bottom says so
    /// and formats it on a tap, as the bar's toggle does.
    private func updateLargeFileNote(on viewController: UIViewController) {
        guard content.opensPlain, showSource, let action = content.sourceToggleTitle(showingSource: true) else {
            largeFileNote?.removeFromSuperview()
            largeFileNote = nil
            return
        }
        guard largeFileNote?.superview !== viewController.view else { return }
        let note = LargeFileNoteView(
            message: String(localized: "Large file, shown as plain text."),
            action: action,
            palette: bodyThemeID.palette
        ) { [weak self] in self?.toggleSource() }
        note.translatesAutoresizingMaskIntoConstraints = false
        viewController.view.addSubview(note)
        let guide = viewController.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            note.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            // Clear of the floating Annotate and comment stash at the corners.
            note.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 68),
            note.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -68),
        ])
        largeFileNote = note
    }

    @objc private func toggleSource() {
        guard makePresentation().sourceToggleTitle != nil,
              let viewController = contentHostController else {
            return
        }

        if let intent = installedBodyView?.viewportIntent {
            sourceToggleViewportIntent = intent
        }
        showSource.toggle()
        if showSource { loadRawSidecarIfNeeded() }
        let body = installBody(on: viewController)
        if content.isStreamingSource, let intent = sourceToggleViewportIntent {
            body.restoreViewport(intent)
        }
        configureNavigation(on: viewController, palette: bodyThemeID.palette)
    }
}

/// Content host so a vertical-bar trait change rebuilds the one bar-item list.
private final class FullScreenContentHostController: UIViewController {
    var onVerticalBarEdgeChange: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        SystemVerticalBar.observeEdgeChanges(of: self) { $0.onVerticalBarEdgeChange?() }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The bar edge is unset until this host is in the window. Trait
        // registration does not replay the value already present.
        onVerticalBarEdgeChange?()
    }
}

#if DEBUG
extension FullScreenCodeViewController {
    static func makeHarnessController(
        content: FullScreenCodeContent,
        presentationMode: PresentationMode = .sheet,
        reviewCommentSelectionContext: ReviewCommentSelectionContext?,
        lineAnchor: SourceLineAnchor? = nil,
        lineAnchorNotice: (@MainActor @Sendable (String) -> Void)? = nil,
        hostOffers: [ReaderBarAction: [UIBarButtonItem]] = [:],
        hostMenu: [UIMenuElement] = []
    ) -> FullScreenCodeViewController {
        FullScreenCodeViewController(
            content: content,
            presentationMode: presentationMode,
            reviewCommentSelectionContext: reviewCommentSelectionContext,
            lineAnchor: lineAnchor,
            lineAnchorNotice: lineAnchorNotice,
            hostOffers: hostOffers,
            hostMenu: hostMenu
        )
    }

    var installedBodyViewForTesting: UIView? {
        installedBodyView
    }

    var lineAnchorNoticeDeliveredForTesting: Bool {
        lineAnchorNoticeDelivered
    }

    var floatingAnnotateButtonForTesting: UIButton? {
        annotateButton
    }

    var floatingPickButtonForTesting: UIButton? { pickButton }

    var floatingPickCommentButtonForTesting: UIButton? { commentButton }

    var floatingPickButtonFrameForTesting: CGRect? {
        guard let button = pickButton,
              let superview = button.superview else { return nil }
        superview.layoutIfNeeded()
        return view.convert(button.frame, from: superview)
    }

    var floatingStashButtonForTesting: UIButton? {
        stashButton.button
    }

    var floatingStashButtonFrameForTesting: CGRect? {
        guard let button = stashButton.button,
              let superview = button.superview else { return nil }
        superview.layoutIfNeeded()
        return view.convert(button.frame, from: superview)
    }

    var floatingAnnotateButtonFrameForTesting: CGRect? {
        guard let button = annotateButton,
              let superview = button.superview else { return nil }
        superview.layoutIfNeeded()
        return view.convert(button.frame, from: superview)
    }

    func makeViewingOptionsControllerForTesting() -> UIViewController? {
        let presentation = makePresentation()
        guard let family = presentation.readerFamily,
              let preferences = presentation.readerPreferences else { return nil }
        let controller = FullScreenViewingOptionsController(
            family: family,
            preferences: preferences,
            onTextScaleChanged: { [weak self] scale in
                self?.setReaderTextScale(scale)
            },
            onWrappingChanged: { [weak self] wraps in
                self?.setReaderWrapping(wraps)
            },
            onSpacingChanged: { [weak self] spacing in
                self?.setReaderSpacing(spacing)
            },
            onReset: { [weak self] in
                self?.resetReaderPreferences()
            }
        )
        controller.loadViewIfNeeded()
        return controller
    }

    func setReaderWrappingForTesting(_ wraps: Bool) {
        setReaderWrapping(wraps)
    }

    func setReaderTextScaleForTesting(_ scale: CGFloat) {
        setReaderTextScale(scale)
    }

    func toggleSourceForTesting() {
        toggleSource()
    }

    var presentationCopyTextForTesting: String {
        makePresentation().copyText
    }

    var presentationBodyContentForTesting: FullScreenCodeContent {
        makePresentation().bodyContent
    }

    var annotateSourceForTesting: PaperMarkupCanvasSession.AnnotateSource {
        PaperMarkupCanvasSession.annotateSource(for: .html)
    }

    func makeAnnotateHostForTesting() -> PaperMarkupCanvasHostController {
        PaperMarkupCanvasHostController.makeFullScreenController(
            background: .blank,
            destination: addToChatDestination,
            onDeliveryAccepted: { [weak self] in
                self?.handleAnnotateDeliveryAccepted()
            }
        )
    }

    var isShowingSnapshotProgressForTesting: Bool { isSnapshotting }

    func markRenderReadyForTesting() {
        (installedBodyView as? HTMLRenderView)?.markRenderReadyForTesting()
        updateAnnotateAvailability()
    }

    var shareableContentForTesting: FileShareService.ShareableContent? {
        shareableContent()
    }
}
#endif
