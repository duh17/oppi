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

    private final class LiveSourceObserverCleanup: @unchecked Sendable {
        private let cancelImpl: @MainActor @Sendable () -> Void

        init(cancelImpl: @escaping @MainActor @Sendable () -> Void) {
            self.cancelImpl = cancelImpl
        }

        func cancel() {
            Task { @MainActor in
                cancelImpl()
            }
        }
    }

    private let content: FullScreenCodeContent
    private let presentationMode: PresentationMode
    private let reviewCommentSelectionContext: ReviewCommentSelectionContext?
    private var pendingMarkdownViewportIntent: FullScreenMarkdownViewportIntent?
    private let onMarkdownViewportIntentChange: ((FullScreenMarkdownViewportIntent) -> Void)?
    private let lineAnchor: SourceLineAnchor?
    private let lineAnchorNotice: (@MainActor @Sendable (String) -> Void)?
    private var lineAnchorNoticeDelivered = false
    private var editItems: [UIBarButtonItem]
    private var lastEditItems: [UIBarButtonItem] = []
    private var lastNavigationPresentation: NavigationPresentation?
    private var showSource = false
    private var completeRawText: String?
    private var rawSidecarTask: Task<Void, Never>?
    private var copyButton: UIBarButtonItem?
    private var floatingViewingOptionsButton: UIButton?
    private weak var viewingOptionsController: FullScreenViewingOptionsController?
    private weak var contentHostController: UIViewController?
    private var viewingOptionsBarItem: UIBarButtonItem?
    private var annotateBarItem: UIBarButtonItem?
    private var stashBarItem: UIBarButtonItem?
    private var backSwipeDismissHandler: HorizontalBackSwipeGestureInstaller?
    private var installedBodyView: (any ReaderBody)?
    private var liveSourceBodyView: NativeFullScreenSourceBody?
    private var liveSourceMarkdownBodyView: NativeMutableFullScreenMarkdownBody?
    private var liveSourceHTMLBodyView: HTMLRenderView?
    private var liveSourceObserverCleanup: LiveSourceObserverCleanup?
    private var liveSourceCurrentSnapshot: SourceTraceStream.Snapshot?
    private var liveSourceMarkdownViewportIntent: FullScreenMarkdownViewportIntent?
    private var appliedThemeID: ThemeID?
    private var annotateButton: UIButton?
    private var pickButton: UIButton?
    private var commentButton: UIButton?
    private var commentLeadingConstraint: NSLayoutConstraint?
    private var commentTopConstraint: NSLayoutConstraint?
    private var markupBottomConstraint: NSLayoutConstraint?
    private var pickBottomConstraint: NSLayoutConstraint?
    private var stashButton: UIButton?
    private var stashBadgeLabel: UILabel?
    private var stashBottomConstraint: NSLayoutConstraint?
    private var leadingFloatingAccessoryCount = 0
    private var trailingFloatingAccessoryCount = 0
    private var viewingOptionsBottomConstraint: NSLayoutConstraint?
    private var lastPresentedStashCount = 0
    private weak var presentedStashSheet: UIViewController?
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
        editItems: [UIBarButtonItem] = [],
        markdownViewportIntent: FullScreenMarkdownViewportIntent? = nil,
        onMarkdownViewportIntentChange: ((FullScreenMarkdownViewportIntent) -> Void)? = nil,
        addToChatDestination: ComposerCanvasDestination? = nil
    ) {
        self.content = content
        self.presentationMode = presentationMode
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
            ?? ReviewCommentSelectionContext(
                router: reviewCommentSelectionRouter,
                sessionId: reviewCommentSessionId,
                sourceLabel: reviewCommentSourceLabel
            )
        self.lineAnchor = lineAnchor
        self.lineAnchorNotice = lineAnchorNotice
        self.editItems = editItems
        self.lastEditItems = editItems
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
        if case .markdown = currentSemanticContent() {
            return true
        }
        return false
    }

    deinit {
        rawSidecarTask?.cancel()
        liveSourceObserverCleanup?.cancel()
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

    override func viewDidLoad() {
        super.viewDidLoad()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChangeNotification),
            name: .oppiThemeDidChange,
            object: nil
        )

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

    /// The document's edit entry owns these: a pencil, or the "…" that holds
    /// Edit with Session. The reader shows them left of its own controls.
    func setEditBarItems(_ items: [UIBarButtonItem]) {
        guard !items.elementsEqual(lastEditItems, by: ===) else { return }
        editItems = items
        lastEditItems = items
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
        clearLiveSourceBodyReferences()
        let presentation = makePresentation()
        let themedBody: any ReaderBody
        if case .liveSource(let initialSnapshot, _) = content,
           !(liveSourceCurrentSnapshot ?? initialSnapshot).isDone {
            themedBody = makeFreshLiveSourceStreamingBody(
                snapshot: liveSourceCurrentSnapshot ?? initialSnapshot,
                themeID: themeID
            )
        } else {
            themedBody = makeBody(
                for: presentation.bodyContent,
                themeID: themeID,
                focusLineAnchor: false
            )
        }
        installBodyView(themedBody, on: viewController)
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
        case .embedded:
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
        case .contentOnly:
            dismissMode = nil
        }
        if let dismissMode {
            vc.navigationItem.leftBarButtonItem = FullScreenViewerNavigationChrome.makeDismissButton(
                mode: dismissMode,
                target: self,
                action: #selector(doneTapped),
                palette: palette,
                // One id for the leave control in every presentation mode.
                accessibilityIdentifier: "fullScreen.code.close"
            )
        }

        contentHostController = vc

        // No custom UINavigationBarAppearance — iOS 26 Liquid Glass renders
        // bar items as floating glass pills. See FullScreenViewerChrome.

        installInitialBody(on: vc)
        configureNavigation(on: vc, palette: palette)

        return vc
    }

    private func installInitialBody(on viewController: UIViewController) {
        switch content {
        case .liveSource(let snapshot, let stream):
            liveSourceCurrentSnapshot = snapshot
            if snapshot.isDone {
                let presentation = makePresentation()
                installBodyView(makeBody(for: presentation.bodyContent, themeID: bodyThemeID), on: viewController)
            } else {
                installOrUpdateLiveSourceStreamingBody(snapshot: snapshot, on: viewController, themeID: bodyThemeID)
            }
            let observerID = stream.addObserver(deliverImmediately: false) { [weak self] snapshot in
                self?.handleLiveSourceUpdate(snapshot)
            }
            liveSourceObserverCleanup = LiveSourceObserverCleanup {
                stream.removeObserver(observerID)
            }

        default:
            let presentation = makePresentation()
            installBodyView(
                makeBody(
                    for: presentation.bodyContent,
                    themeID: bodyThemeID,
                    focusLineAnchor: shouldFocusLineAnchorWhileRestoring
                ),
                on: viewController
            )
        }
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
        // Top pinned to view edge (not safe area) so content scrolls behind
        // the navigation bar's Liquid Glass pills. See FullScreenViewerChrome.
        NSLayoutConstraint.activate([
            bodyView.leadingAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: viewController.view.safeAreaLayoutGuide.trailingAnchor),
            bodyView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
            bodyView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
        ])
        if let floatingViewingOptionsButton {
            viewController.view.bringSubviewToFront(floatingViewingOptionsButton)
        }
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
        if let stashButton {
            viewController.view.bringSubviewToFront(stashButton)
        }
        if let stashBadgeLabel {
            viewController.view.bringSubviewToFront(stashBadgeLabel)
        }
        restorePendingMarkdownViewportIfNeeded(in: bodyView)
        scheduleLineAnchorNotice()
        updateAnnotateAvailability()
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
        let resolution = currentSemanticContent().lineAnchorResolution(for: lineAnchor)
        guard let message = resolution.message else { return }
        lineAnchorNoticeDelivered = true
        lineAnchorNotice?(message)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func configureNavigation(on viewController: UIViewController, palette: ThemePalette) {
        let presentation = makePresentation()
        // No titleView — immersive mode shows only floating glass pills.
        // See FullScreenViewerChrome.
        configureFloatingViewingOptionsButton(
            on: viewController,
            presentation: presentation,
            palette: palette
        )
        configureFloatingAnnotateButton(on: viewController, palette: palette)
        configureFloatingStashButton(on: viewController, palette: palette)
        updateAnnotateAvailability()

        let navigationPresentation = NavigationPresentation(presentation)
        guard navigationPresentation != lastNavigationPresentation else {
            // A chunk can recreate a floating control. Keep it off the rail
            // without replacing the bar items the reader already has.
            syncFloatingControlVisibility(on: viewController)
            return
        }
        lastNavigationPresentation = navigationPresentation
        installRightBarItems(on: viewController, palette: palette)
    }

    private func syncFloatingControlVisibility(on viewController: UIViewController) {
        let sideRail = SystemVerticalBar.isActive(viewController)
        floatingViewingOptionsButton?.isHidden = sideRail
        annotateButton?.isHidden = sideRail
        stashButton?.isHidden = sideRail
        stashBadgeLabel?.isHidden = sideRail
    }

    /// Sole writer of the content host's right bar items. Persistent viewer
    /// controls join the side rail when the system says the bar is vertical.
    private func installRightBarItems(on viewController: UIViewController, palette: ThemePalette) {
        let presentation = makePresentation()
        let sideRail = SystemVerticalBar.isActive(viewController)
        var rightItems = editItems

        let copy = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copyTapped)
        )
        copy.tintColor = palette.ui.fgDim
        copy.accessibilityIdentifier = "fullscreen-code.copy"
        copyButton = copy
        rightItems.append(copy)

        if let shareable = shareableContent() {
            rightItems.append(
                FullScreenViewerNavigationChrome.makeShareButton(for: shareable, palette: palette)
            )
        }

        if let toggleTitle = presentation.sourceToggleTitle {
            let toggle = UIBarButtonItem(
                title: toggleTitle,
                style: .plain,
                target: self,
                action: #selector(toggleSource)
            )
            if sideRail {
                toggle.image = UIImage(systemName: Self.sourceToggleSymbol(for: toggleTitle))
            }
            toggle.accessibilityIdentifier = "fullscreen-code.source-toggle"
            toggle.tintColor = palette.ui.blue
            rightItems.append(toggle)
        }

        viewingOptionsBarItem = nil
        annotateBarItem = nil
        stashBarItem = nil
        if sideRail {
            if floatingViewingOptionsButton != nil {
                let item = railItem(
                    symbol: FullScreenViewingOptionsSymbols.readerModeIconName,
                    title: String(localized: "Viewing Options"),
                    action: #selector(showViewingOptions)
                )
                viewingOptionsBarItem = item
                rightItems.append(item)
            }
            if annotateButton != nil {
                let item = railItem(
                    symbol: PaperMarkupCanvasSession.AnnotateAction.systemImage,
                    title: PaperMarkupCanvasSession.AnnotateAction.title,
                    action: #selector(annotateRenderedViewTapped)
                )
                item.isEnabled = annotateButton?.isEnabled ?? false
                annotateBarItem = item
                rightItems.append(item)
            }
            if stashButton != nil {
                let item = railItem(
                    symbol: FullScreenReviewCommentStashControl.systemImage,
                    title: FullScreenReviewCommentStashControl.accessibilityLabel,
                    action: #selector(stashButtonTapped)
                )
                let count = reviewCommentStash?.stagedCount ?? 0
                if count > 0 {
                    item.badge = .count(count)
                }
                item.accessibilityValue = stashButton?.accessibilityValue
                stashBarItem = item
                rightItems.append(item)
            }
        }

        syncFloatingControlVisibility(on: viewController)
        viewController.navigationItem.rightBarButtonItems = rightItems
    }

    private func railItem(symbol: String, title: String, action: Selector) -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: symbol),
            style: .plain,
            target: self,
            action: action
        )
        item.title = title
        item.accessibilityLabel = title
        if #available(iOS 27.0, *) {
            item.visibilityPriority = .high
        }
        return item
    }

    /// The title is the mode the control switches to. The symbol matches that mode.
    private static func sourceToggleSymbol(for title: String) -> String {
        if title == String(localized: "Source") || title == String(localized: "Raw") {
            return "curlybraces"
        }
        if title == String(localized: "Table") {
            return "tablecells"
        }
        return "text.page"
    }

    private func configureFloatingViewingOptionsButton(
        on viewController: UIViewController,
        presentation: Presentation,
        palette: ThemePalette
    ) {
        guard let readerFamily = presentation.readerFamily,
              let readerPreferences = presentation.readerPreferences else {
            floatingViewingOptionsButton?.removeFromSuperview()
            floatingViewingOptionsButton = nil
            viewingOptionsBottomConstraint = nil
            viewingOptionsController?.dismiss(animated: true)
            return
        }

        let button: UIButton
        if let existing = floatingViewingOptionsButton {
            button = existing
        } else {
            button = makeFloatingViewingOptionsButton(palette: palette)
            floatingViewingOptionsButton = button
            viewController.view.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            let bottom = button.bottomAnchor.constraint(
                equalTo: viewController.view.safeAreaLayoutGuide.bottomAnchor,
                constant: -viewingOptionsBottomPadding
            )
            viewingOptionsBottomConstraint = bottom
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(
                    equalTo: viewController.view.safeAreaLayoutGuide.trailingAnchor,
                    constant: -FullScreenFloatingControlChrome.trailingPadding
                ),
                bottom,
                button.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
                button.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
            ])
        }
        viewingOptionsBottomConstraint?.constant = -viewingOptionsBottomPadding

        updateFloatingViewingOptionsButton(button, palette: palette, preferences: readerPreferences)
        viewController.view.bringSubviewToFront(button)
        viewingOptionsController?.apply(family: readerFamily, preferences: readerPreferences)
    }

    private func makeFloatingViewingOptionsButton(palette: ThemePalette) -> UIButton {
        let button = FullScreenViewingOptionsController.makeFloatingButton(palette: palette)
        button.addTarget(self, action: #selector(showViewingOptions), for: .touchUpInside)
        return button
    }

    private func updateFloatingViewingOptionsButton(
        _ button: UIButton,
        palette: ThemePalette,
        preferences: FullScreenReaderPreferences
    ) {
        FullScreenViewingOptionsController.updateFloatingButton(button, palette: palette, preferences: preferences)
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
        let viewingOptionsVisible = floatingViewingOptionsButton?.isHidden == false
        return FullScreenReviewCommentStashControl.bottomPadding(
            leadingAccessoryCount: trailingFloatingAccessoryCount + (viewingOptionsVisible ? 1 : 0)
        )
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
        let controls = [pickButton, annotateButton, stashButton, stashBadgeLabel].compactMap { control -> CGRect? in
            guard let control, !control.isHidden else { return nil }
            return control.convert(control.bounds, to: host)
        }
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

    /// UIKit tracks the stash reads here and re-runs this when the staged comments
    /// change. Reads go through the concrete `@Observable` controller; the
    /// `ReviewCommentStashHandling` existential alone is not observable.
    override func updateProperties() {
        super.updateProperties()
        guard let comments = reviewCommentStash as? ChatReviewCommentsController else { return }
        _ = comments.stagedCount
        _ = comments.stagedComments
        guard isViewLoaded, let host = contentHostController else { return }
        configureFloatingStashButton(on: host, palette: bodyThemeID.palette)
        installRightBarItems(on: host, palette: bodyThemeID.palette)
    }

    private func configureFloatingStashButton(
        on viewController: UIViewController,
        palette: ThemePalette
    ) {
        let count = reviewCommentStash?.stagedCount ?? 0
        guard count > 0 else {
            stashBadgeLabel?.removeFromSuperview()
            stashButton?.removeFromSuperview()
            stashButton = nil
            stashBadgeLabel = nil
            stashBottomConstraint = nil
            lastPresentedStashCount = 0
            updateContextualCommentPosition()
            return
        }

        let isNew = stashButton == nil
        let countIncreased = !isNew && count > lastPresentedStashCount
        let button: UIButton
        if let existing = stashButton {
            button = existing
            FullScreenFloatingControlChrome.updateStandaloneButton(button, palette: palette)
            updateStashBadge(count: count, palette: palette)
            updateStashBottomConstraint(on: viewController.view)
        } else {
            button = FullScreenFloatingControlChrome.makeStandaloneButton(
                systemImage: FullScreenReviewCommentStashControl.systemImage,
                accessibilityLabel: FullScreenReviewCommentStashControl.accessibilityLabel,
                accessibilityIdentifier: FullScreenReviewCommentStashControl.accessibilityIdentifier,
                palette: palette
            )
            button.clipsToBounds = false
            button.isAccessibilityElement = true
            button.accessibilityTraits = .button
            button.addTarget(self, action: #selector(stashButtonTapped), for: .touchUpInside)
            stashButton = button
            viewController.view.addSubview(button)
            pinStashButton(button, to: viewController.view)
            installStashBadge(on: viewController.view, button: button, palette: palette)
            updateStashBadge(count: count, palette: palette)
        }

        button.accessibilityValue = FullScreenReviewCommentStashControl.accessibilityValue(for: count)
        viewController.view.bringSubviewToFront(button)
        if let stashBadgeLabel {
            viewController.view.bringSubviewToFront(stashBadgeLabel)
        }
        if let annotateButton {
            viewController.view.bringSubviewToFront(annotateButton)
        }
        playStashMotionIfNeeded(on: button, isNew: isNew, countIncreased: countIncreased)
        lastPresentedStashCount = count
        viewController.view.layoutIfNeeded()
        updateContextualCommentPosition()
    }

    private func pinStashButton(_ button: UIButton, to view: UIView) {
        button.translatesAutoresizingMaskIntoConstraints = false
        let bottom = button.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -stashBottomPadding
        )
        stashBottomConstraint = bottom
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: FullScreenFloatingControlChrome.leadingPadding
            ),
            bottom,
            button.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
            button.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
        ])
    }

    private var markupBottomPadding: CGFloat {
        FullScreenReviewCommentStashControl.bottomPadding(
            leadingAccessoryCount: leadingFloatingAccessoryCount
        )
    }

    private var stashBottomPadding: CGFloat {
        var accessoryCount = leadingFloatingAccessoryCount
        if annotateButton?.superview != nil {
            accessoryCount += 1
        }
        return FullScreenReviewCommentStashControl.bottomPadding(
            leadingAccessoryCount: accessoryCount
        )
    }

    func setLeadingFloatingAccessoryCount(_ count: Int) {
        let normalized = max(0, count)
        guard leadingFloatingAccessoryCount != normalized else { return }
        leadingFloatingAccessoryCount = normalized
        guard isViewLoaded, let host = contentHostController else { return }
        markupBottomConstraint?.constant = -markupBottomPadding
        updateStashBottomConstraint(on: host.view)
    }

    private var viewingOptionsBottomPadding: CGFloat {
        FullScreenReviewCommentStashControl.bottomPadding(
            leadingAccessoryCount: trailingFloatingAccessoryCount
        )
    }

    func setTrailingFloatingAccessoryCount(_ count: Int) {
        let normalized = max(0, count)
        guard trailingFloatingAccessoryCount != normalized else { return }
        trailingFloatingAccessoryCount = normalized
        guard isViewLoaded else { return }
        viewingOptionsBottomConstraint?.constant = -viewingOptionsBottomPadding
        pickBottomConstraint?.constant = -pickControlsBottomPadding
        (contentHostController?.view ?? view).layoutIfNeeded()
    }

    private func updateStashBottomConstraint(on view: UIView) {
        stashBottomConstraint?.constant = -stashBottomPadding
        view.layoutIfNeeded()
        updateContextualCommentPosition()
    }

    private func installStashBadge(on host: UIView, button: UIButton, palette: ThemePalette) {
        let badge = UILabel()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 9
        badge.layer.masksToBounds = true
        badge.isAccessibilityElement = false
        badge.accessibilityElementsHidden = true
        badge.isUserInteractionEnabled = false
        host.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: button.topAnchor, constant: -2),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        stashBadgeLabel = badge
        updateStashBadge(count: reviewCommentStash?.stagedCount ?? 0, palette: palette)
    }

    private func updateStashBadge(count: Int, palette: ThemePalette) {
        guard let badge = stashBadgeLabel else { return }
        badge.text = count > 99 ? "99+" : "\(count)"
        badge.textColor = palette.ui.bgDark
        badge.backgroundColor = palette.ui.cyan
        let horizontalPadding: CGFloat = count >= 10 ? 6 : 5
        badge.layoutMargins = UIEdgeInsets(
            top: 0,
            left: horizontalPadding,
            bottom: 0,
            right: horizontalPadding
        )
    }

    private func playStashMotionIfNeeded(on button: UIButton, isNew: Bool, countIncreased: Bool) {
        guard isNew || countIncreased else { return }
        button.layer.removeAllAnimations()
        if FullScreenReviewCommentStashControl.prefersReducedMotion {
            button.transform = .identity
            return
        }

        let duration = FullScreenReviewCommentStashControl.appearanceDuration
        if isNew {
            button.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
            UIView.animate(
                withDuration: duration,
                delay: 0,
                usingSpringWithDamping: 0.72,
                initialSpringVelocity: 0.9,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                button.transform = .identity
            }
        } else {
            UIView.animate(
                withDuration: duration / 2,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
            ) {
                button.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            } completion: { _ in
                UIView.animate(
                    withDuration: duration / 2,
                    delay: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn]
                ) {
                    button.transform = .identity
                }
            }
        }
    }

    @objc private func stashButtonTapped() {
        presentReviewCommentStashSheet()
    }

    /// The router presents from the window's front-most controller, which is
    /// not this viewer when it is embedded, so the sheet is tracked by its own
    /// presentation rather than by `presentedViewController`.
    private var openStashSheet: UIViewController? {
        guard let sheet = presentedStashSheet, sheet.presentingViewController != nil else { return nil }
        return sheet
    }

    private func presentReviewCommentStashSheet() {
        guard let stash = reviewCommentStash else { return }
        openStashSheet?.dismiss(animated: false)
        // The sheet reads the stash itself, so edits and removals show while it is up.
        let sheet = ReviewCommentStashViewController(stash: stash, onClose: { [weak self] in
            self?.dismissReviewCommentStashSheet()
        })
        Router.present(
            sheet,
            presentation: .pageSheet.inNavigation(),
            from: self
        )
        presentedStashSheet = sheet
    }

    private func dismissReviewCommentStashSheet() {
        if let open = openStashSheet {
            Router.finish(open)
        }
        presentedStashSheet = nil
    }

    private func makePresentation() -> Presentation {
        let semanticContent = currentSemanticContent()
        let bodyContent = bodyContent(for: semanticContent)
        let readerFamily = bodyContent.readerFamily
        return Presentation(
            bodyContent: bodyContent,
            copyText: semanticContent.copyText(showingSource: showSource, completeRaw: completeRawText),
            sourceToggleTitle: semanticContent.sourceToggleTitle(showingSource: showSource),
            readerFamily: readerFamily,
            readerPreferences: readerFamily.map { FullScreenReaderPreferencesStore.shared.preferences(for: $0) }
        )
    }

    // MARK: - Body

    private func bodyContext(themeID: ThemeID, focusLineAnchor: Bool = true) -> ReaderBodyContext {
        ReaderBodyContext(
            themeID: themeID,
            selection: reviewCommentSelectionContext,
            lineAnchor: lineAnchor,
            focusLineAnchor: focusLineAnchor,
            completeThinking: { [weak self] body, finalText, viewportIntent in
                self?.completeThinking(body: body, finalText: finalText, viewportIntent: viewportIntent)
            }
        )
    }

    private func makeBody(
        for content: FullScreenCodeContent,
        themeID: ThemeID,
        focusLineAnchor: Bool = true
    ) -> any ReaderBody {
        content.makeFullScreenBody(bodyContext(themeID: themeID, focusLineAnchor: focusLineAnchor))
    }

    /// The thinking body has already waited for the person to stop scrolling.
    private func completeThinking(
        body: any ReaderBody,
        finalText: String,
        viewportIntent: FullScreenMarkdownViewportIntent
    ) {
        guard installedBodyView === body,
              case .thinking(_, let stream) = content,
              stream?.snapshot.isDone == true,
              let viewController = contentHostController else { return }

        let completedBody = makeBody(for: .thinking(content: finalText), themeID: bodyThemeID)
        installBodyView(completedBody, on: viewController)
        completedBody.restoreViewport(viewportIntent)
        configureNavigation(on: viewController, palette: bodyThemeID.palette)
    }

    private func makeLiveSourceBody(
        snapshot: SourceTraceStream.Snapshot,
        palette: ThemePalette
    ) -> NativeFullScreenSourceBody {
        let body = NativeFullScreenSourceBody(
            content: snapshot.text,
            isStreaming: !snapshot.isDone,
            palette: palette,
            readerPreferences: FullScreenCodeContent.plainText(content: snapshot.text, filePath: snapshot.filePath).readerPreferences,
            reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
            reviewCommentSourceContext: bodyContext(themeID: bodyThemeID).sourceContext(
                surface: .fullScreenSource,
                filePath: snapshot.filePath
            )
        )
        liveSourceBodyView = body
        return body
    }

    private func makeLiveSourceMarkdownBody(
        text: String,
        filePath: String?,
        resourceAccess: MarkdownResourceAccess,
        isStreaming: Bool,
        themeID: ThemeID
    ) -> NativeMutableFullScreenMarkdownBody {
        let palette = themeID.palette
        return NativeMutableFullScreenMarkdownBody(
            content: text,
            isStreaming: isStreaming,
            themeID: themeID,
            palette: palette,
            reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
            reviewCommentSourceContext: bodyContext(themeID: themeID).sourceContext(
                surface: .fullScreenMarkdown,
                filePath: filePath
            ),
            resourceAccess: resourceAccess,
            sourceFilePath: filePath,
            readerPreferences: FullScreenCodeContent.markdown(content: text, filePath: filePath, resourceAccess: resourceAccess).readerPreferences,
            perfSurface: .fullScreenMarkdown
        )
    }

    private func makeLiveSourceHTMLBody(
        text: String,
        filePath: String?,
        themeID: ThemeID
    ) -> HTMLRenderView {
        let palette = themeID.palette
        let view = HTMLRenderView(
            htmlString: text,
            reviewCommentRouter: reviewCommentSelectionContext?.dispatcher,
            sourceContext: bodyContext(themeID: themeID).sourceContext(surface: .fullScreenSource, filePath: filePath)
        )
        view.backgroundColor = palette.ui.bgDark
        view.applyReaderPreferences(FullScreenCodeContent.html(content: text, filePath: filePath).readerPreferences)
        return view
    }

    private func clearLiveSourceBodyReferences() {
        liveSourceBodyView = nil
        liveSourceMarkdownBodyView = nil
        liveSourceHTMLBodyView = nil
    }

    private func makeFreshLiveSourceStreamingBody(
        snapshot: SourceTraceStream.Snapshot,
        themeID: ThemeID
    ) -> any ReaderBody {
        switch bodyContent(for: snapshot) {
        case .markdown(let text, let filePath, let resourceAccess, _, _):
            let body = makeLiveSourceMarkdownBody(
                text: text,
                filePath: filePath,
                resourceAccess: resourceAccess,
                isStreaming: true,
                themeID: themeID
            )
            liveSourceMarkdownBodyView = body
            return body
        case .html(let text, let filePath):
            let body = makeLiveSourceHTMLBody(text: text, filePath: filePath, themeID: themeID)
            liveSourceHTMLBodyView = body
            return body
        default:
            return makeLiveSourceBody(snapshot: snapshot, palette: themeID.palette)
        }
    }

    private func installOrUpdateLiveSourceStreamingBody(
        snapshot: SourceTraceStream.Snapshot,
        on viewController: UIViewController,
        themeID: ThemeID
    ) {
        let palette = themeID.palette
        switch bodyContent(for: snapshot) {
        case .markdown(let text, let filePath, let resourceAccess, _, _):
            liveSourceBodyView = nil
            liveSourceHTMLBodyView = nil
            if let body = liveSourceMarkdownBodyView, installedBodyView === body {
                body.update(
                    content: text,
                    isStreaming: true,
                    reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                    reviewCommentSourceContext: bodyContext(themeID: themeID).sourceContext(
                        surface: .fullScreenMarkdown,
                        filePath: filePath
                    ),
                    resourceAccess: resourceAccess,
                    sourceFilePath: filePath
                )
            } else {
                let body = makeLiveSourceMarkdownBody(
                    text: text,
                    filePath: filePath,
                    resourceAccess: resourceAccess,
                    isStreaming: true,
                    themeID: themeID
                )
                liveSourceMarkdownBodyView = body
                installBodyView(body, on: viewController)
                if let intent = liveSourceMarkdownViewportIntent {
                    body.restoreMutableViewport(intent)
                }
            }

        case .html(let text, let filePath):
            liveSourceBodyView = nil
            liveSourceMarkdownBodyView = nil
            if let body = liveSourceHTMLBodyView, installedBodyView === body {
                body.load(text)
            } else {
                let body = makeLiveSourceHTMLBody(text: text, filePath: filePath, themeID: themeID)
                liveSourceHTMLBodyView = body
                installBodyView(body, on: viewController)
            }

        default:
            liveSourceMarkdownBodyView = nil
            liveSourceHTMLBodyView = nil
            if let body = liveSourceBodyView, installedBodyView === body {
                body.update(content: snapshot.text, isStreaming: true)
            } else {
                installBodyView(makeLiveSourceBody(snapshot: snapshot, palette: palette), on: viewController)
            }
        }
    }

    private func handleLiveSourceUpdate(_ snapshot: SourceTraceStream.Snapshot) {
        liveSourceCurrentSnapshot = snapshot
        guard let viewController = contentHostController else { return }

        let themeID = bodyThemeID
        let palette = themeID.palette
        if snapshot.isDone {
            let presentation = makePresentation()
            if case .markdown(let text, let filePath, let resourceAccess, _, _) = presentation.bodyContent,
               let body = liveSourceMarkdownBodyView,
               installedBodyView === body {
                // Flush final bytes and final source context through the shared
                // mutable engine, then let its viewport owner perform the
                // one-way immutable-reader swap.
                body.update(
                    content: text,
                    isStreaming: false,
                    reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                    reviewCommentSourceContext: bodyContext(themeID: themeID).sourceContext(
                        surface: .fullScreenMarkdown,
                        filePath: filePath
                    ),
                    resourceAccess: resourceAccess,
                    sourceFilePath: filePath
                )
                liveSourceMarkdownBodyView = nil
                liveSourceBodyView = nil
                liveSourceHTMLBodyView = nil
            } else {
                clearLiveSourceBodyReferences()
                installBodyView(makeBody(for: presentation.bodyContent, themeID: themeID), on: viewController)
            }
        } else {
            installOrUpdateLiveSourceStreamingBody(snapshot: snapshot, on: viewController, themeID: themeID)
        }

        configureNavigation(on: viewController, palette: palette)
    }

    private func currentSemanticContent() -> FullScreenCodeContent {
        switch content {
        case .liveSource(let snapshot, _):
            return (liveSourceCurrentSnapshot ?? snapshot).readerContent
        default:
            return content
        }
    }

    private func bodyContent(for snapshot: SourceTraceStream.Snapshot) -> FullScreenCodeContent {
        bodyContent(for: snapshot.readerContent)
    }

    private func bodyContent(for content: FullScreenCodeContent) -> FullScreenCodeContent {
        guard showSource else { return content }
        return content.sourceContent(completeRaw: completeRawText) ?? content
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        switch presentationMode {
        case .sheet:
            dismiss(animated: true)
        case .embedded(let onDismiss):
            onDismiss()
        case .contentOnly(let onBackSwipe):
            onBackSwipe?()
        }
    }

    @objc private func copyTapped() {
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
              floatingViewingOptionsButton != nil || viewingOptionsBarItem != nil else { return }

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

        options.configurePresentation(
            barItem: viewingOptionsBarItem,
            sourceButton: floatingViewingOptionsButton,
            horizontalSizeClass: traitCollection.horizontalSizeClass
        )
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
        currentSemanticContent().shareableContent(showingSource: showSource, completeRaw: completeRawText)
    }

    private func loadRawSidecarIfNeeded() {
        guard rawSidecarTask == nil, completeRawText == nil,
              case .markdown(_, _, _, let rawText, let source) = currentSemanticContent(),
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
                self.installBodyView(self.makeBody(for: self.makePresentation().bodyContent, themeID: self.bodyThemeID), on: host)
            } catch {
                // The preview remains the honest fallback if the sidecar is gone.
            }
        }
    }

    @objc private func toggleSource() {
        guard makePresentation().sourceToggleTitle != nil,
              let viewController = contentHostController else {
            return
        }

        if let intent = installedBodyView?.viewportIntent {
            liveSourceMarkdownViewportIntent = intent
        }
        showSource.toggle()
        if showSource { loadRawSidecarIfNeeded() }
        let themeID = bodyThemeID
        let palette = themeID.palette
        if case .liveSource(let initialSnapshot, _) = content {
            let snapshot = liveSourceCurrentSnapshot ?? initialSnapshot
            if !snapshot.isDone {
                installOrUpdateLiveSourceStreamingBody(snapshot: snapshot, on: viewController, themeID: themeID)
                configureNavigation(on: viewController, palette: palette)
                return
            }
        }

        let presentation = makePresentation()
        installBodyView(makeBody(for: presentation.bodyContent, themeID: themeID), on: viewController)
        configureNavigation(on: viewController, palette: palette)
    }
}

/// Content host so a vertical-bar trait change rebuilds the one bar-item list.
private final class FullScreenContentHostController: UIViewController {
    var onVerticalBarEdgeChange: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        if #available(iOS 27.1, *) {
            registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) { (host: Self, _) in
                host.onVerticalBarEdgeChange?()
            }
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // The bar edge is unset until this host is in the window. Trait
        // registration does not replay the value already present.
        onVerticalBarEdgeChange?()
    }
}

/// Text size, wrapping, and spacing for full-screen readers. Shared by
/// `FullScreenCodeViewController` and the review diff reader (`DiffReaderView`).
///
/// A UIKit controller that owns the popover or sheet: a glass panel with a
/// text-size slider, a wrap switch and a spacing control where the content
/// family supports them, and Reset View. It reads the theme from
/// `ThemeRuntimeState`, so it needs no app root.
final class FullScreenViewingOptionsController: UIViewController {
    private static let panelWidth: CGFloat = 340
    private static let outerMargin: CGFloat = 16
    private static let innerPadding: CGFloat = 20
    /// The slider moves in 5% steps.
    static let textScaleStep: CGFloat = 0.05

    private var family: FullScreenReaderContentFamily
    private var preferences: FullScreenReaderPreferences
    private let onTextScaleChanged: (CGFloat) -> Void
    private let onWrappingChanged: (Bool) -> Void
    private let onSpacingChanged: (FullScreenReaderSpacing) -> Void
    private let onReset: () -> Void

    var onDismiss: ((FullScreenViewingOptionsController) -> Void)?

    private let scrollView = UIScrollView()
    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let contentStack = UIStackView()

    private let headerIcon = UIImageView()
    private let headerGlass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let headerTitle = UILabel()
    private let headerSubtitle = UILabel()
    private let header = UIStackView()

    private let textSizeIcon = UIImageView()
    private let textSizeTitle = UILabel()
    private let textSizeValue = UILabel()
    private let textSizeSlider = TextScaleSlider()
    private let textSizeGroup = UIStackView()
    /// The title row and the percent: side by side, stacked at accessibility sizes.
    private let textSizeTop = UIStackView()

    private let wrapDivider = UIView()
    private let wrapIcon = UIImageView()
    private let wrapTitle = UILabel()
    private let wrapSwitch = UISwitch()
    private let wrapRow = UIStackView()

    private let spacingDivider = UIView()
    private let spacingIcon = UIImageView()
    private let spacingTitle = UILabel()
    private let spacingControl = UISegmentedControl(
        items: FullScreenReaderSpacing.allCases.map(\.displayName)
    )
    private let spacingGroup = UIStackView()

    private let resetButton = UIButton(configuration: .bordered())

    /// The sheet detent: the panel at its natural height, at the sheet's width.
    var preferredSheetHeight: CGFloat {
        fittingHeight(forWidth: view.bounds.width > 0 ? view.bounds.width : Self.panelWidth)
    }

    init(
        family: FullScreenReaderContentFamily,
        preferences: FullScreenReaderPreferences,
        onTextScaleChanged: @escaping (CGFloat) -> Void,
        onWrappingChanged: @escaping (Bool) -> Void,
        onSpacingChanged: @escaping (FullScreenReaderSpacing) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.family = family
        self.preferences = preferences
        self.onTextScaleChanged = onTextScaleChanged
        self.onWrappingChanged = onWrappingChanged
        self.onSpacingChanged = onSpacingChanged
        self.onReset = onReset
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) { nil }

    // MARK: - Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.accessibilityIdentifier = "fullscreen.viewingOptions"

        glassView.cornerConfiguration = .corners(radius: 28)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glassView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        glassView.contentView.addSubview(scrollView)

        configureControls()
        buildContent()
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let margin = Self.outerMargin
        let padding = Self.innerPadding
        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            glassView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            glassView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            glassView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -margin),
            scrollView.topAnchor.constraint(equalTo: glassView.contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: glassView.contentView.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: padding),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -padding),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: padding),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -padding),
            scrollView.contentLayoutGuide.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: -padding),
            scrollView.contentLayoutGuide.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: padding),
        ])
        preferredContentSize = CGSize(width: Self.panelWidth, height: fittingHeight(forWidth: Self.panelWidth))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A popover takes its size from here; a larger text size grows it.
        let height = fittingHeight(forWidth: Self.panelWidth)
        if preferredContentSize.height != height || preferredContentSize.width != Self.panelWidth {
            preferredContentSize = CGSize(width: Self.panelWidth, height: height)
        }
        scrollView.isScrollEnabled = scrollView.contentSize.height > scrollView.bounds.height + 0.5
    }

    /// The panel's height at `width`: the stack at its natural height inside
    /// the glass padding, the outer margin, and the bottom safe area (a
    /// sheet's home indicator).
    private func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let stackWidth = width - 2 * (Self.outerMargin + Self.innerPadding)
        let stackHeight = contentStack.systemLayoutSizeFitting(
            CGSize(width: stackWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        return ceil(stackHeight + 2 * (Self.innerPadding + Self.outerMargin) + view.safeAreaInsets.bottom)
    }

    private func configureControls() {
        for label in [headerTitle, headerSubtitle, textSizeTitle, textSizeValue, wrapTitle, spacingTitle] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        textSizeValue.numberOfLines = 1
        textSizeValue.setContentCompressionResistancePriority(.required, for: .horizontal)
        textSizeValue.setContentHuggingPriority(.required, for: .horizontal)
        textSizeValue.isAccessibilityElement = false
        for icon in [headerIcon, textSizeIcon, wrapIcon, spacingIcon] {
            icon.isAccessibilityElement = false
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        headerTitle.text = String(localized: "Viewing Options")
        headerSubtitle.text = String(localized: "Reader controls")
        headerIcon.contentMode = .center
        headerGlass.cornerConfiguration = .capsule()
        headerGlass.contentView.addSubview(headerIcon)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerGlass.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerGlass.widthAnchor.constraint(equalToConstant: 34),
            headerGlass.heightAnchor.constraint(equalToConstant: 34),
            headerIcon.centerXAnchor.constraint(equalTo: headerGlass.contentView.centerXAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: headerGlass.contentView.centerYAnchor),
        ])
        // One element: the title and its subtitle read together.
        header.isAccessibilityElement = true
        header.accessibilityLabel = "\(String(localized: "Viewing Options")), \(String(localized: "Reader controls"))"
        header.accessibilityTraits = .header
        header.accessibilityIdentifier = "fullscreen.viewingOptions.header"

        textSizeTitle.text = String(localized: "Text Size")
        textSizeSlider.minimumValue = Float(FullScreenReaderPreferences.minimumTextScale)
        textSizeSlider.maximumValue = Float(FullScreenReaderPreferences.maximumTextScale)
        textSizeSlider.step = Float(Self.textScaleStep)
        textSizeSlider.minimumValueImage = UIImage(systemName: "textformat.size.smaller")
        textSizeSlider.maximumValueImage = UIImage(systemName: "textformat.size.larger")
        textSizeSlider.accessibilityLabel = String(localized: "Text Size")
        textSizeSlider.accessibilityIdentifier = "fullscreen.viewingOptions.textSize"
        textSizeSlider.addAction(UIAction { [weak self] action in
            guard let self, let slider = action.sender as? UISlider else { return }
            let scale = Self.snappedTextScale(CGFloat(slider.value))
            slider.value = Float(scale)
            // A drag crosses many raw values inside one 5% step; the owner
            // saves and re-applies only when the step changes.
            guard scale != preferences.textScale else { return }
            preferences.textScale = scale
            setNeedsUpdateProperties()
            onTextScaleChanged(scale)
        }, for: .valueChanged)

        wrapTitle.text = String(localized: "Wrap Text")
        wrapSwitch.accessibilityLabel = String(localized: "Wrap Text")
        wrapSwitch.accessibilityIdentifier = "fullscreen.viewingOptions.wrap"
        wrapSwitch.setContentHuggingPriority(.required, for: .horizontal)
        wrapSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        wrapSwitch.addAction(UIAction { [weak self] action in
            guard let self, let toggle = action.sender as? UISwitch else { return }
            onWrappingChanged(toggle.isOn)
        }, for: .valueChanged)

        spacingTitle.text = String(localized: "Spacing")
        spacingControl.accessibilityLabel = String(localized: "Spacing")
        spacingControl.accessibilityIdentifier = "fullscreen.viewingOptions.spacing"
        spacingControl.addAction(UIAction { [weak self] action in
            guard let self, let control = action.sender as? UISegmentedControl,
                  FullScreenReaderSpacing.allCases.indices.contains(control.selectedSegmentIndex) else { return }
            onSpacingChanged(FullScreenReaderSpacing.allCases[control.selectedSegmentIndex])
        }, for: .valueChanged)

        var reset = UIButton.Configuration.bordered()
        reset.cornerStyle = .capsule
        reset.title = String(localized: "Reset View")
        reset.image = UIImage(systemName: "arrow.counterclockwise")
        reset.imagePadding = 6
        resetButton.configuration = reset
        resetButton.accessibilityIdentifier = "fullscreen.viewingOptions.reset"
        resetButton.addAction(UIAction { [weak self] _ in self?.onReset() }, for: .primaryActionTriggered)
    }

    private func buildContent() {
        contentStack.axis = .vertical
        contentStack.spacing = 18

        let headerText = UIStackView(arrangedSubviews: [headerTitle, headerSubtitle])
        headerText.axis = .vertical
        headerText.spacing = 2
        header.addArrangedSubview(headerGlass)
        header.addArrangedSubview(headerText)
        header.axis = .horizontal
        header.spacing = 12
        header.alignment = .center

        let textSizeTitleRow = UIStackView(arrangedSubviews: [textSizeIcon, textSizeTitle])
        textSizeTitleRow.axis = .horizontal
        textSizeTitleRow.spacing = 6
        textSizeTitleRow.alignment = .center
        textSizeTitleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textSizeTop.addArrangedSubview(textSizeTitleRow)
        textSizeTop.addArrangedSubview(textSizeValue)
        textSizeTop.spacing = 12
        textSizeGroup.addArrangedSubview(textSizeTop)
        textSizeGroup.addArrangedSubview(textSizeSlider)
        textSizeGroup.axis = .vertical
        textSizeGroup.spacing = 10

        wrapRow.addArrangedSubview(wrapIcon)
        wrapRow.addArrangedSubview(wrapTitle)
        wrapRow.addArrangedSubview(wrapSwitch)
        wrapRow.axis = .horizontal
        wrapRow.spacing = 6
        wrapRow.alignment = .center
        wrapRow.setCustomSpacing(12, after: wrapTitle)

        let spacingTop = UIStackView(arrangedSubviews: [spacingIcon, spacingTitle])
        spacingTop.axis = .horizontal
        spacingTop.spacing = 6
        spacingTop.alignment = .center
        spacingGroup.addArrangedSubview(spacingTop)
        spacingGroup.addArrangedSubview(spacingControl)
        spacingGroup.axis = .vertical
        spacingGroup.spacing = 10

        for divider in [wrapDivider, spacingDivider] {
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.heightAnchor.constraint(equalToConstant: 1 / max(1, traitCollection.displayScale)).isActive = true
            divider.isAccessibilityElement = false
        }

        for arranged in [header, textSizeGroup, wrapDivider, wrapRow, spacingDivider, spacingGroup, resetButton] {
            contentStack.addArrangedSubview(arranged)
        }
    }

    // MARK: - State

    override func updateProperties() {
        super.updateProperties()
        // Beside the title, the percent squeezes it to a letter per line at
        // accessibility sizes; under it, both read in full.
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        textSizeTop.axis = stacked ? .vertical : .horizontal
        textSizeTop.alignment = stacked ? .leading : .center
        let fg = UIColor.themeFg
        let dim = UIColor.themeFgDim
        let cyan = UIColor.themeCyan

        view.tintColor = cyan
        headerIcon.image = .scaledSymbol(FullScreenViewingOptionsSymbols.readerModeIconName, style: .title3, weight: .semibold, color: fg)
        headerTitle.font = .scaled(.headline)
        headerTitle.textColor = fg
        headerSubtitle.font = .scaled(.caption1)
        headerSubtitle.textColor = dim

        textSizeIcon.image = .scaledSymbol("textformat.size", style: .subheadline, weight: .semibold, color: fg)
        textSizeTitle.font = .scaled(.subheadline, .semibold)
        textSizeTitle.textColor = fg
        textSizeValue.font = .scaled(.subheadline, .medium, monospacedDigits: true)
        textSizeValue.textColor = dim
        let percent = Int(round(preferences.textScale * 100))
        textSizeValue.text = "\(percent)%"
        textSizeSlider.accessibilityValue = String(localized: "\(percent) percent")
        if !textSizeSlider.isTracking, CGFloat(textSizeSlider.value) != preferences.textScale {
            textSizeSlider.value = Float(preferences.textScale)
        }

        wrapIcon.image = .scaledSymbol(CodeWrapControl.symbolName, style: .subheadline, color: fg)
        wrapTitle.font = .scaled(.subheadline)
        wrapTitle.textColor = fg
        wrapSwitch.onTintColor = cyan
        if wrapSwitch.isOn != preferences.wrapsText {
            wrapSwitch.setOn(preferences.wrapsText, animated: false)
        }

        spacingIcon.image = .scaledSymbol("line.3.horizontal.decrease", style: .subheadline, weight: .semibold, color: fg)
        spacingTitle.font = .scaled(.subheadline, .semibold)
        spacingTitle.textColor = fg
        if let index = FullScreenReaderSpacing.allCases.firstIndex(of: preferences.spacing),
           spacingControl.selectedSegmentIndex != index {
            spacingControl.selectedSegmentIndex = index
        }

        for divider in [wrapDivider, spacingDivider] {
            divider.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
        }
        wrapDivider.isHidden = !family.supportsWrapping
        wrapRow.isHidden = !family.supportsWrapping
        spacingDivider.isHidden = !family.supportsSpacing
        spacingGroup.isHidden = !family.supportsSpacing

        var reset = resetButton.configuration ?? .bordered()
        reset.baseForegroundColor = cyan
        reset.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.scaled(.subheadline)
            return outgoing
        }
        resetButton.configuration = reset
    }

    /// `value` on the slider's 5% grid, inside the reader's text-scale range.
    static func snappedTextScale(_ value: CGFloat) -> CGFloat {
        FullScreenReaderPreferences.clampedTextScale((value / textScaleStep).rounded() * textScaleStep)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismiss?(self)
        }
    }

    func apply(family: FullScreenReaderContentFamily, preferences: FullScreenReaderPreferences) {
        guard self.family != family || self.preferences != preferences else { return }
        self.family = family
        self.preferences = preferences
        setNeedsUpdateProperties()
        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    /// A popover from a rail bar item, or from the floating button in regular
    /// width; otherwise a sheet sized to the panel.
    func configurePresentation(
        barItem: UIBarButtonItem?,
        sourceButton: UIView?,
        horizontalSizeClass: UIUserInterfaceSizeClass
    ) {
        if let barItem {
            modalPresentationStyle = .popover
            popoverPresentationController?.barButtonItem = barItem
        } else if horizontalSizeClass == .regular, let sourceButton {
            modalPresentationStyle = .popover
            popoverPresentationController?.sourceView = sourceButton
            popoverPresentationController?.sourceRect = sourceButton.bounds
            popoverPresentationController?.permittedArrowDirections = [.down, .right]
        } else {
            modalPresentationStyle = .pageSheet
        }

        if let sheet = sheetPresentationController {
            let detentIdentifier = UISheetPresentationController.Detent.Identifier("viewing-options")
            sheet.detents = [
                .custom(identifier: detentIdentifier) { [weak self] context in
                    min(self?.preferredSheetHeight ?? 280, context.maximumDetentValue)
                }
            ]
            sheet.selectedDetentIdentifier = detentIdentifier
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }
    }

    /// The floating glass Viewing Options button. Callers add the target.
    static func makeFloatingButton(palette: ThemePalette) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: FullScreenViewingOptionsSymbols.readerModeIconName)
        config.preferredSymbolConfigurationForImage = .init(
            pointSize: FullScreenFloatingControlChrome.symbolPointSize,
            weight: .semibold
        )
        let contentPadding = FullScreenFloatingControlChrome.standaloneContentPadding
        config.contentInsets = NSDirectionalEdgeInsets(
            top: contentPadding,
            leading: contentPadding,
            bottom: contentPadding,
            trailing: contentPadding
        )
        FullScreenFloatingControlChrome.applyGlassBackground(to: &config, palette: palette)

        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = "fullscreen.viewingOptions.button"
        button.accessibilityLabel = String(localized: "Viewing Options")
        button.accessibilityHint = String(localized: "Adjust text size, wrapping, and spacing")
        return button
    }

    static func updateFloatingButton(
        _ button: UIButton,
        palette: ThemePalette,
        preferences: FullScreenReaderPreferences
    ) {
        var config = button.configuration ?? .plain()
        FullScreenFloatingControlChrome.applyGlassBackground(to: &config, palette: palette)
        button.configuration = config
        button.accessibilityValue = String(
            localized: "Text size \(Int(round(preferences.textScale * 100))) percent"
        )
    }
}

/// A slider whose VoiceOver increment and decrement use its own step
/// (UIKit's default is 10% of the range).
private final class TextScaleSlider: UISlider {
    var step: Float = 0.05

    override func accessibilityIncrement() { nudge(step) }
    override func accessibilityDecrement() { nudge(-step) }

    private func nudge(_ delta: Float) {
        value = min(maximumValue, max(minimumValue, value + delta))
        sendActions(for: .valueChanged)
    }
}

enum FullScreenViewingOptionsSymbols {
    static var readerModeIconName: String {
        if UIImage(systemName: "text.page") != nil {
            return "text.page"
        }
        return "doc.text"
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
        editItems: [UIBarButtonItem] = []
    ) -> FullScreenCodeViewController {
        FullScreenCodeViewController(
            content: content,
            presentationMode: presentationMode,
            reviewCommentSelectionContext: reviewCommentSelectionContext,
            lineAnchor: lineAnchor,
            lineAnchorNotice: lineAnchorNotice,
            editItems: editItems
        )
    }

    var hasFloatingViewingOptionsButtonForTesting: Bool {
        floatingViewingOptionsButton != nil
    }

    var installedBodyViewForTesting: UIView? {
        installedBodyView
    }

    var lineAnchorNoticeDeliveredForTesting: Bool {
        lineAnchorNoticeDelivered
    }

    var floatingViewingOptionsButtonFrameForTesting: CGRect? {
        guard let button = floatingViewingOptionsButton,
              let superview = button.superview else { return nil }
        superview.layoutIfNeeded()
        return view.convert(button.frame, from: superview)
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
        stashButton
    }

    var floatingStashButtonFrameForTesting: CGRect? {
        guard let button = stashButton,
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
        liveSourceHTMLBodyView?.markRenderReadyForTesting()
        updateAnnotateAvailability()
    }

    var shareableContentForTesting: FileShareService.ShareableContent? {
        shareableContent()
    }
}
#endif
