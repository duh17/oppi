import SwiftUI
import UIKit

/// Full-screen content viewer for tool output (UIKit).
///
/// Supports code (with syntax highlighting), diff, and markdown modes.
/// Presented via ``FullScreenCodeView`` (UIViewControllerRepresentable wrapper)
/// from SwiftUI callers, and directly from UIKit timeline cells.
///
/// Supports two presentation modes:
/// - `.sheet`: standalone presentation with its own dismiss button (chevron.down).
///   Used by timeline full-screen and SwiftUI `.sheet`/`.fullScreenCover`.
/// - `.embedded(onDismiss:)`: embedded in a SwiftUI NavigationStack. Shows a
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
        /// Embedded inside a SwiftUI NavigationStack — chevron.backward + closure.
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
    private struct BodyInteractionState {
        let scrollOffsets: [CGPoint]
        let selections: [NSRange]
        let firstResponderTextViewIndex: Int?
        let mutableMarkdownViewportIntent: FullScreenMarkdownViewportIntent?
    }

    private struct NavigationPresentation: Equatable {
        let sourceToggleTitle: String?
        let readerFamily: FullScreenReaderContentFamily?

        init(_ presentation: Presentation) {
            sourceToggleTitle = presentation.sourceToggleTitle
            readerFamily = presentation.readerFamily
        }
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
    private var navigationActions: [FullScreenViewerNavigationAction]
    private var navigationActionPresentation: [FullScreenViewerNavigationAction.Presentation]
    private var showSource = false
    private var copyButton: UIBarButtonItem?
    private var floatingViewingOptionsButton: UIButton?
    private weak var viewingOptionsController: FullScreenViewingOptionsController?
    private weak var contentHostController: UIViewController?
    private var backSwipeDismissHandler: HorizontalBackSwipeGestureInstaller?
    private var installedBodyView: UIView?
    private var liveSourceBodyView: NativeFullScreenSourceBody?
    private var liveSourceMarkdownBodyView: NativeMutableFullScreenMarkdownBody?
    private var liveSourceHTMLBodyView: HTMLRenderView?
    private var liveSourceObserverCleanup: LiveSourceObserverCleanup?
    private var liveSourceCurrentSnapshot: SourceTraceStream.Snapshot?
    private var liveSourceMarkdownViewportIntent: FullScreenMarkdownViewportIntent?
    private var lastNavigationPresentation: NavigationPresentation?
    private var appliedThemeID: ThemeID?
    private var annotateButton: UIButton?
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
        navigationActions: [FullScreenViewerNavigationAction] = [],
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
        self.navigationActions = navigationActions
        self.pendingMarkdownViewportIntent = markdownViewportIntent
        self.onMarkdownViewportIntentChange = onMarkdownViewportIntentChange
        self.navigationActionPresentation = navigationActions.map(\.presentation)
        self.addToChatDestination = addToChatDestination
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Present the code viewer from the topmost view controller.
    /// Works from both UIKit and SwiftUI contexts without needing a
    /// responder-chain walk from a specific source view.
    static func present(
        content: FullScreenCodeContent,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
        reviewCommentSessionId: String? = nil,
        reviewCommentSourceLabel: String? = nil
    ) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        // A Markdown reader may open one focused rendered visual above itself.
        // Every other viewer remains terminal so repeated taps cannot grow an
        // unbounded modal stack.
        if let codeViewer = presenter as? FullScreenCodeViewController {
            guard codeViewer.allowsFocusedVisualPreview else { return }
        } else if isFocusedViewer(presenter) {
            return
        }

        let controller = FullScreenCodeViewController(
            content: content,
            reviewCommentSelectionContext: reviewCommentSelectionContext
                ?? ReviewCommentSelectionContext(
                    router: reviewCommentSelectionRouter,
                    sessionId: reviewCommentSessionId,
                    sourceLabel: reviewCommentSourceLabel
                ),
            addToChatDestination: capturedAddToChatDestination(from: presenter)
        )
        FullScreenViewerPresentationPolicy.configureLargePresentation(
            controller,
            traitCollection: presenter.traitCollection
        )
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID()
            .preferredColorScheme == .light ? .light : .dark
        presenter.present(controller, animated: true)
    }

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

    private var allowsFocusedVisualPreview: Bool {
        if case .markdown = currentSemanticContent() {
            return true
        }
        return false
    }

    private static func isFocusedViewer(_ controller: UIViewController) -> Bool {
        if controller is FullScreenImageViewController
            || controller is FullScreenImageDataPreviewViewController {
            return true
        }
        guard let navigation = controller as? UINavigationController else { return false }
        return navigation.viewControllers.contains {
            $0 is FullScreenCodeViewController
                || $0 is FullScreenImageViewController
                || $0 is FullScreenImageDataPreviewViewController
        }
    }

    deinit {
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
        view.backgroundColor = UIColor(palette.bgDark)
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

    /// Rebuild persistent UIKit content and chrome when SwiftUI's active theme
    /// changes. Full-screen bodies capture a palette at construction time, so
    /// merely invalidating the representable leaves code, markdown, diff,
    /// terminal, and rendered-document viewers in the previous appearance.
    func setNavigationActions(_ actions: [FullScreenViewerNavigationAction]) {
        let presentation = actions.map(\.presentation)
        guard presentation != navigationActionPresentation else { return }
        navigationActions = actions
        navigationActionPresentation = presentation
        lastNavigationPresentation = nil
        guard isViewLoaded, let viewController = contentHostController else { return }
        configureNavigation(on: viewController, palette: bodyThemeID.palette)
    }

    func applyThemeIfNeeded(_ themeID: ThemeID) {
        guard isViewLoaded, let viewController = contentHostController else {
            appliedThemeID = themeID
            return
        }
        guard appliedThemeID != themeID else { return }

        appliedThemeID = themeID
        let palette = themeID.palette
        overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        view.backgroundColor = UIColor(palette.bgDark)
        viewController.view.backgroundColor = UIColor(palette.bgDark)

        let interactionState = installedBodyView.map(captureInteractionState)
        clearLiveSourceBodyReferences()
        let presentation = makePresentation()
        let themedBody: UIView
        if case .liveSource(let initialSnapshot, _) = content {
            let snapshot = liveSourceCurrentSnapshot ?? initialSnapshot
            if !snapshot.isDone {
                themedBody = makeFreshLiveSourceStreamingBody(
                    snapshot: snapshot,
                    themeID: themeID
                )
            } else {
                themedBody = makeBodyView(
                    for: presentation.bodyContent,
                    themeID: themeID,
                    focusLineAnchor: false
                )
            }
        } else {
            themedBody = makeBodyView(
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

    private func captureInteractionState(in body: UIView) -> BodyInteractionState {
        let scrollViews = descendantViews(of: UIScrollView.self, in: body)
        let textViews = descendantViews(of: UITextView.self, in: body)
        return BodyInteractionState(
            scrollOffsets: scrollViews.map(\.contentOffset),
            selections: textViews.map(\.selectedRange),
            firstResponderTextViewIndex: textViews.firstIndex(where: \.isFirstResponder),
            mutableMarkdownViewportIntent: (body as? NativeMutableFullScreenMarkdownBody)?
                .currentViewportIntent()
        )
    }

    private func restoreInteractionState(
        _ state: BodyInteractionState,
        in body: UIView,
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
        if let intent = state.mutableMarkdownViewportIntent,
           let mutableMarkdown = body as? NativeMutableFullScreenMarkdownBody {
            mutableMarkdown.restoreMutableViewport(intent)
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
            if let intent = state.mutableMarkdownViewportIntent,
               let mutableMarkdown = body as? NativeMutableFullScreenMarkdownBody {
                mutableMarkdown.restoreMutableViewport(intent)
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
        let vc = UIViewController()
        vc.view.backgroundColor = UIColor(palette.bgDark)

        let dismissMode: FullScreenViewerNavigationChrome.DismissMode?
        let dismissAccessibilityIdentifier: String?
        switch presentationMode {
        case .sheet:
            dismissMode = .modal
            dismissAccessibilityIdentifier = "fullscreen-code.dismiss"
        case .embedded:
            dismissMode = .embedded
            dismissAccessibilityIdentifier = "fullscreen-code.back"
        case .contentOnly:
            dismissMode = nil
            dismissAccessibilityIdentifier = nil
        }
        if let dismissMode {
            vc.navigationItem.leftBarButtonItem = FullScreenViewerNavigationChrome.makeDismissButton(
                mode: dismissMode,
                target: self,
                action: #selector(doneTapped),
                palette: palette,
                accessibilityIdentifier: dismissAccessibilityIdentifier
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
                installBodyView(makeBodyView(for: presentation.bodyContent, themeID: bodyThemeID), on: viewController)
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
                makeBodyView(
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

    private func installBodyView(_ bodyView: UIView, on viewController: UIViewController) {
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
        if let htmlView = bodyView as? HTMLRenderView {
            htmlView.onRenderStateChange = { [weak self] in
                self?.updateAnnotateAvailability()
            }
        }
        restorePendingMarkdownViewportIfNeeded(in: bodyView)
        scheduleLineAnchorNotice()
        updateAnnotateAvailability()
    }

    private func currentMarkdownViewportIntent() -> FullScreenMarkdownViewportIntent? {
        // A remake can take one layout pass at offset 0 before the stored
        // restore write runs. That looks like `.top` and must not replace the
        // stored mid-document intent.
        if !hasSettledMarkdownViewportRestore {
            return nil
        }
        let intent: FullScreenMarkdownViewportIntent
        switch installedBodyView {
        case let body as NativeFullScreenMarkdownBody:
            intent = body.currentViewportIntent()
        case let body as NativeMutableFullScreenMarkdownBody:
            intent = body.currentViewportIntent()
        default:
            return nil
        }
        // Offset 0 before the first layout is indistinguishable from `.top`.
        if intent == .top, !hasLaidOutMarkdownViewport {
            return nil
        }
        return intent
    }

    private var hasSettledMarkdownViewportRestore: Bool {
        switch installedBodyView {
        case let body as NativeFullScreenMarkdownBody:
            return body.hasSettledMarkdownViewportRestore
        default:
            return true
        }
    }

    private var hasLaidOutMarkdownViewport: Bool {
        guard let body = installedBodyView else { return false }
        return descendantViews(of: UIScrollView.self, in: body).contains { scrollView in
            scrollView.bounds.height > 0 && scrollView.contentSize.height > 0
        }
    }

    private func restorePendingMarkdownViewportIfNeeded(in body: UIView) {
        guard let intent = pendingMarkdownViewportIntent else { return }
        switch body {
        case let body as NativeFullScreenMarkdownBody:
            pendingMarkdownViewportIntent = nil
            body.restoreViewportAfterMutableTransition(intent)
        case let body as NativeMutableFullScreenMarkdownBody:
            pendingMarkdownViewportIntent = nil
            body.restoreMutableViewport(intent)
        default:
            break
        }
    }

    private func scheduleLineAnchorNotice() {
        guard lineAnchor != nil, !lineAnchorNoticeDelivered else { return }
        DispatchQueue.main.async { [weak self] in
            self?.reportLineAnchorNoticeIfNeeded()
        }
    }

    private func reportLineAnchorNoticeIfNeeded() {
        guard let lineAnchor, !lineAnchorNoticeDelivered else { return }
        let resolution = lineAnchorResolution(for: currentSemanticContent(), anchor: lineAnchor)
        guard let message = resolution.message else { return }
        lineAnchorNoticeDelivered = true
        lineAnchorNotice?(message)
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func lineAnchorResolution(
        for content: FullScreenCodeContent,
        anchor: SourceLineAnchor?
    ) -> SourceLineAnchorResolution {
        guard let anchor else {
            return SourceLineAnchorResolution(
                requestedRange: 1...1,
                existingRange: nil,
                fileLineCount: 0,
                availableRange: nil
            )
        }
        let textAndFirstLine: (String, Int)
        switch content {
        case .code(let text, _, _, let startLine):
            textAndFirstLine = (text, startLine)
        case .plainText(let text, _),
             .markdown(let text, _, _),
             .html(let text, _),
             .latex(let text, _),
             .orgMode(let text, _),
             .mermaid(let text, _),
             .graphviz(let text, _),
             .thinking(let text, _),
             .terminal(let text, _, _):
            textAndFirstLine = (text, 1)
        case .diff(let document):
            textAndFirstLine = (document.reconstructedNewSideText, 1)
        case .liveSource(let snapshot, _):
            return lineAnchorResolution(for: semanticContent(for: snapshot), anchor: anchor)
        }
        return anchor.resolution(
            fileContent: textAndFirstLine.0,
            firstFileLine: textAndFirstLine.1
        )
    }

    private func configureNavigation(on viewController: UIViewController, palette: ThemePalette) {
        let presentation = makePresentation()
        let navigationPresentation = NavigationPresentation(presentation)
        if navigationPresentation == lastNavigationPresentation {
            configureFloatingViewingOptionsButton(
                on: viewController,
                presentation: presentation,
                palette: palette
            )
            configureFloatingAnnotateButton(on: viewController, palette: palette)
            updateAnnotateAvailability()
            return
        }

        lastNavigationPresentation = navigationPresentation
        // No titleView — immersive mode shows only floating glass pills.
        // See FullScreenViewerChrome.

        var rightItems = navigationActions.map(makeNavigationActionButton)

        let copy = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copyTapped)
        )
        copy.tintColor = UIColor(palette.fgDim)
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
            toggle.tintColor = UIColor(palette.blue)
            rightItems.append(toggle)
        }

        viewController.navigationItem.rightBarButtonItems = rightItems
        configureFloatingViewingOptionsButton(
            on: viewController,
            presentation: presentation,
            palette: palette
        )
        configureFloatingAnnotateButton(on: viewController, palette: palette)
        updateAnnotateAvailability()
    }

    private func makeNavigationActionButton(_ action: FullScreenViewerNavigationAction) -> UIBarButtonItem {
        let primaryAction = UIAction(
            title: action.title ?? "",
            image: action.systemImage.flatMap(UIImage.init(systemName:))
        ) { _ in
            Task { @MainActor in action.handler() }
        }
        let item = UIBarButtonItem(primaryAction: primaryAction)
        item.accessibilityIdentifier = "fullscreen-code.action.\(action.id)"
        item.accessibilityLabel = action.accessibilityLabel
        item.accessibilityValue = action.accessibilityValue
        item.isEnabled = action.isEnabled
        return item
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
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(
                    equalTo: viewController.view.safeAreaLayoutGuide.trailingAnchor,
                    constant: -FullScreenFloatingControlChrome.trailingPadding
                ),
                button.bottomAnchor.constraint(
                    equalTo: viewController.view.safeAreaLayoutGuide.bottomAnchor,
                    constant: -FullScreenFloatingControlChrome.bottomPadding
                ),
                button.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
                button.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
            ])
        }

        updateFloatingViewingOptionsButton(button, palette: palette, preferences: readerPreferences)
        viewController.view.bringSubviewToFront(button)
        viewingOptionsController?.apply(family: readerFamily, preferences: readerPreferences)
    }

    private func makeFloatingViewingOptionsButton(palette: ThemePalette) -> UIButton {
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
        button.accessibilityLabel = String(localized: "Viewing Options")
        button.accessibilityHint = String(localized: "Adjust text size, wrapping, and spacing")
        button.addTarget(self, action: #selector(showViewingOptions), for: .touchUpInside)
        return button
    }

    private func updateFloatingViewingOptionsButton(
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

    private func configureFloatingAnnotateButton(
        on viewController: UIViewController,
        palette: ThemePalette
    ) {
        guard canAnnotateRenderedContent else {
            annotateButton?.removeFromSuperview()
            annotateButton = nil
            return
        }

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
            button.addTarget(self, action: #selector(annotateRenderedViewTapped), for: .touchUpInside)
            annotateButton = button
            viewController.view.addSubview(button)
            FullScreenFloatingControlChrome.pinStandaloneButton(button, to: viewController.view, leading: true)
        }
        viewController.view.bringSubviewToFront(button)
    }

    private func makePresentation() -> Presentation {
        let semanticContent = currentSemanticContent()
        let bodyContent = bodyContent(for: semanticContent)
        let readerFamily = readerFamily(for: bodyContent)
        return Presentation(
            bodyContent: bodyContent,
            copyText: copyText(for: semanticContent),
            sourceToggleTitle: sourceToggleTitle(for: semanticContent),
            readerFamily: readerFamily,
            readerPreferences: readerFamily.map { FullScreenReaderPreferencesStore.shared.preferences(for: $0) }
        )
    }

    // MARK: - Body

    private func makeBodyView(
        for content: FullScreenCodeContent,
        themeID: ThemeID,
        focusLineAnchor: Bool = true
    ) -> UIView {
        let palette = themeID.palette
        switch content {
        case .code(let text, let language, let filePath, let startLine):
            return NativeFullScreenCodeBody(
                content: text,
                language: language,
                startLine: startLine,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: language
                ),
                lineAnchor: lineAnchor,
                focusLineAnchor: focusLineAnchor
            )
        case .plainText(let text, let filePath):
            return NativeFullScreenSourceBody(
                content: text,
                isStreaming: false,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenSource,
                    filePath: filePath
                ),
                lineAnchor: lineAnchor,
                focusLineAnchor: focusLineAnchor
            )
        case .diff(let document):
            return NativeFullScreenDiffBody(
                document: document,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenDiff,
                    filePath: document.filePath
                )
            )
        case .markdown(let text, let filePath, let wsContext):
            let body = NativeFullScreenMarkdownBody(
                content: text,
                themeID: themeID,
                palette: palette,
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenMarkdown,
                    filePath: filePath
                ),
                serverID: wsContext?.serverID,
                workspaceID: wsContext?.workspaceID,
                worktreeId: wsContext?.worktreeId,
                sessionID: wsContext?.sessionID,
                serverBaseURL: wsContext?.serverBaseURL,
                sourceFilePath: filePath,
                lineAnchor: lineAnchor,
                focusLineAnchor: focusLineAnchor,
                readerPreferences: readerPreferences(for: content),
                perfSurface: .fullScreenMarkdown,
                fetchWorkspaceFile: wsContext?.fetchWorkspaceFile,
                fetchSessionFile: wsContext?.fetchSessionFile,
                fetchHostFile: wsContext?.fetchHostFile,
                makeMarkdownVideoSource: wsContext?.makeMarkdownVideoSource,
                makeMarkdownAudioSource: wsContext?.makeMarkdownAudioSource,
                makeTimedTextSidecar: wsContext?.makeTimedTextSidecar,
                audioPlayer: wsContext?.audioPlayer
            )
            body.accessibilityIdentifier = "full-screen.markdown.body"
            return body
        case .html(let text, let filePath):
            let view = HTMLRenderView(
                htmlString: text,
                reviewCommentRouter: reviewCommentSelectionContext?.dispatcher,
                sourceContext: makeSourceContext(surface: .fullScreenSource, filePath: filePath)
            )
            view.backgroundColor = UIColor(palette.bgDark)
            view.applyReaderPreferences(readerPreferences(for: content))
            return view
        case .thinking(let text, let stream):
            let snapshot = stream?.snapshot
            let displayedText = snapshot?.text ?? text
            guard snapshot?.isDone == false else {
                return makeCompletedThinkingBody(text: displayedText, themeID: themeID)
            }
            return NativeFullScreenThinkingBody(
                content: displayedText,
                stream: stream,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenThinking,
                    fallbackSourceLabel: String(localized: "Thinking")
                ),
                onCompletion: { [weak self] body, finalText, viewportIntent in
                    self?.completeThinking(
                        body: body,
                        finalText: finalText,
                        viewportIntent: viewportIntent
                    )
                }
            )
        case .terminal(let text, let command, let stream):
            return NativeFullScreenTerminalBody(
                content: text,
                command: command,
                stream: stream,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenTerminal,
                    fallbackSourceLabel: command
                )
            )
        case .liveSource(let snapshot, _):
            return makeBodyView(
                for: bodyContent(for: snapshot),
                themeID: themeID,
                focusLineAnchor: focusLineAnchor
            )

        // Document renderers — use rendered views with source toggle
        case .latex(let text, let filePath):
            return NativeFullScreenRenderedDocumentBody(
                content: .latex(text),
                themeID: themeID,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "latex"
                )
            )
        case .orgMode(let text, let filePath):
            let body = NativeFullScreenMarkdownBody(
                content: text,
                sourceFormat: .orgMode,
                themeID: themeID,
                palette: palette,
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenMarkdown,
                    filePath: filePath,
                    languageHint: "org"
                ),
                sourceFilePath: filePath,
                readerPreferences: readerPreferences(for: content),
                perfSurface: .fullScreenMarkdown
            )
            body.accessibilityIdentifier = "full-screen.org-mode.body"
            return body
        case .mermaid(let text, let filePath):
            return NativeFullScreenRenderedDocumentBody(
                content: .mermaid(text),
                themeID: themeID,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "mermaid"
                )
            )
        case .graphviz(let text, let filePath):
            return NativeFullScreenCodeBody(
                content: text,
                language: "dot",
                startLine: 1,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "dot"
                ),
                lineAnchor: lineAnchor,
                focusLineAnchor: focusLineAnchor
            )
        }
    }

    private func makeCompletedThinkingBody(
        text: String,
        themeID: ThemeID
    ) -> NativeFullScreenMarkdownBody {
        NativeFullScreenMarkdownBody(
            content: text,
            themeID: themeID,
            palette: themeID.palette,
            reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
            reviewCommentSourceContext: makeSourceContext(
                surface: .fullScreenThinking,
                fallbackSourceLabel: String(localized: "Thinking")
            ),
            readerPreferences: readerPreferences(for: .thinking(content: text)),
            perfSurface: .fullScreenThinking
        )
    }

    private func completeThinking(
        body: NativeFullScreenThinkingBody,
        finalText: String,
        viewportIntent: FullScreenMarkdownViewportIntent
    ) {
        guard installedBodyView === body,
              !body.isViewportInteracting,
              case .thinking(_, let stream) = content,
              stream?.snapshot.isDone == true,
              let viewController = contentHostController else { return }

        let completedBody = makeCompletedThinkingBody(text: finalText, themeID: bodyThemeID)
        installBodyView(completedBody, on: viewController)
        completedBody.restoreViewportAfterMutableTransition(viewportIntent)
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
            readerPreferences: readerPreferences(for: .plainText(content: snapshot.text, filePath: snapshot.filePath)),
            reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
            reviewCommentSourceContext: makeSourceContext(
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
        workspaceContext: FullScreenCodeContent.WorkspaceContext?,
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
            reviewCommentSourceContext: makeSourceContext(
                surface: .fullScreenMarkdown,
                filePath: filePath
            ),
            serverID: workspaceContext?.serverID,
            workspaceID: workspaceContext?.workspaceID,
            worktreeId: workspaceContext?.worktreeId,
            sessionID: workspaceContext?.sessionID,
            serverBaseURL: workspaceContext?.serverBaseURL,
            sourceFilePath: filePath,
            readerPreferences: readerPreferences(for: .markdown(content: text, filePath: filePath, workspaceContext: workspaceContext)),
            perfSurface: .fullScreenMarkdown,
            fetchWorkspaceFile: workspaceContext?.fetchWorkspaceFile,
            fetchSessionFile: workspaceContext?.fetchSessionFile,
            fetchHostFile: workspaceContext?.fetchHostFile,
            makeMarkdownVideoSource: workspaceContext?.makeMarkdownVideoSource,
            makeMarkdownAudioSource: workspaceContext?.makeMarkdownAudioSource,
            makeTimedTextSidecar: workspaceContext?.makeTimedTextSidecar,
            audioPlayer: workspaceContext?.audioPlayer
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
            sourceContext: makeSourceContext(surface: .fullScreenSource, filePath: filePath)
        )
        view.backgroundColor = UIColor(palette.bgDark)
        view.applyReaderPreferences(readerPreferences(for: .html(content: text, filePath: filePath)))
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
    ) -> UIView {
        switch bodyContent(for: snapshot) {
        case .markdown(let text, let filePath, let workspaceContext):
            let body = makeLiveSourceMarkdownBody(
                text: text,
                filePath: filePath,
                workspaceContext: workspaceContext,
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
        case .markdown(let text, let filePath, let workspaceContext):
            liveSourceBodyView = nil
            liveSourceHTMLBodyView = nil
            if let body = liveSourceMarkdownBodyView, installedBodyView === body {
                body.update(
                    content: text,
                    isStreaming: true,
                    reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                    reviewCommentSourceContext: makeSourceContext(
                        surface: .fullScreenMarkdown,
                        filePath: filePath
                    ),
                    serverID: workspaceContext?.serverID,
                    workspaceID: workspaceContext?.workspaceID,
                    worktreeId: workspaceContext?.worktreeId,
                    sessionID: workspaceContext?.sessionID,
                    serverBaseURL: workspaceContext?.serverBaseURL,
                    sourceFilePath: filePath,
                    fetchWorkspaceFile: workspaceContext?.fetchWorkspaceFile,
                    fetchSessionFile: workspaceContext?.fetchSessionFile,
                    fetchHostFile: workspaceContext?.fetchHostFile,
                    makeMarkdownVideoSource: workspaceContext?.makeMarkdownVideoSource,
                    makeMarkdownAudioSource: workspaceContext?.makeMarkdownAudioSource,
            makeTimedTextSidecar: workspaceContext?.makeTimedTextSidecar,
                    audioPlayer: workspaceContext?.audioPlayer
                )
            } else {
                let body = makeLiveSourceMarkdownBody(
                    text: text,
                    filePath: filePath,
                    workspaceContext: workspaceContext,
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
            if case .markdown(let text, let filePath, let workspaceContext) = presentation.bodyContent,
               let body = liveSourceMarkdownBodyView,
               installedBodyView === body {
                // Flush final bytes and final source context through the shared
                // mutable engine, then let its viewport owner perform the
                // one-way immutable-reader swap.
                body.update(
                    content: text,
                    isStreaming: false,
                    reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                    reviewCommentSourceContext: makeSourceContext(
                        surface: .fullScreenMarkdown,
                        filePath: filePath
                    ),
                    serverID: workspaceContext?.serverID,
                    workspaceID: workspaceContext?.workspaceID,
                    worktreeId: workspaceContext?.worktreeId,
                    sessionID: workspaceContext?.sessionID,
                    serverBaseURL: workspaceContext?.serverBaseURL,
                    sourceFilePath: filePath,
                    fetchWorkspaceFile: workspaceContext?.fetchWorkspaceFile,
                    fetchSessionFile: workspaceContext?.fetchSessionFile,
                    fetchHostFile: workspaceContext?.fetchHostFile,
                    makeMarkdownVideoSource: workspaceContext?.makeMarkdownVideoSource,
                    makeMarkdownAudioSource: workspaceContext?.makeMarkdownAudioSource,
            makeTimedTextSidecar: workspaceContext?.makeTimedTextSidecar,
                    audioPlayer: workspaceContext?.audioPlayer
                )
                liveSourceMarkdownBodyView = nil
                liveSourceBodyView = nil
                liveSourceHTMLBodyView = nil
            } else {
                clearLiveSourceBodyReferences()
                installBodyView(makeBodyView(for: presentation.bodyContent, themeID: themeID), on: viewController)
            }
        } else {
            installOrUpdateLiveSourceStreamingBody(snapshot: snapshot, on: viewController, themeID: themeID)
        }

        configureNavigation(on: viewController, palette: palette)
    }

    private func currentSemanticContent() -> FullScreenCodeContent {
        switch content {
        case .liveSource(let snapshot, _):
            return semanticContent(for: liveSourceCurrentSnapshot ?? snapshot)
        default:
            return content
        }
    }

    private func semanticContent(for snapshot: SourceTraceStream.Snapshot) -> FullScreenCodeContent {
        if snapshot.isDone,
           let finalContent = snapshot.finalContent {
            return finalContent
        }
        if let streamingContent = snapshot.finalContent {
            return streamingSemanticContent(
                from: streamingContent,
                text: snapshot.text,
                fallbackFilePath: snapshot.filePath
            )
        }
        return .plainText(content: snapshot.text, filePath: snapshot.filePath)
    }

    private func streamingSemanticContent(
        from content: FullScreenCodeContent,
        text: String,
        fallbackFilePath: String?
    ) -> FullScreenCodeContent {
        switch content {
        case .markdown(_, let filePath, let workspaceContext):
            return .markdown(
                content: text,
                filePath: filePath ?? fallbackFilePath,
                workspaceContext: workspaceContext
            )
        case .html(_, let filePath):
            return .html(content: text, filePath: filePath ?? fallbackFilePath)
        default:
            return .plainText(content: text, filePath: fallbackFilePath)
        }
    }

    private func bodyContent(for snapshot: SourceTraceStream.Snapshot) -> FullScreenCodeContent {
        bodyContent(for: semanticContent(for: snapshot))
    }

    private func bodyContent(for content: FullScreenCodeContent) -> FullScreenCodeContent {
        if showSource {
            if case .markdown(let text, let filePath, _) = content {
                return .plainText(content: text, filePath: filePath)
            }
            if case .html(let text, let filePath) = content {
                return .code(content: text, language: "html", filePath: filePath, startLine: 1)
            }
            if case .diff(let document) = content,
               Self.isHTMLFilePath(document.filePath) {
                return .html(content: document.reconstructedNewSideText, filePath: document.filePath)
            }
            // Document types: toggle to source view
            if case .latex(let text, let filePath) = content {
                return .code(content: text, language: "latex", filePath: filePath, startLine: 1)
            }
            if case .orgMode(let text, let filePath) = content {
                return .code(content: text, language: "org", filePath: filePath, startLine: 1)
            }
            if case .mermaid(let text, let filePath) = content {
                return .code(content: text, language: "mermaid", filePath: filePath, startLine: 1)
            }
        }
        return content
    }

    private func sourceToggleTitle(for content: FullScreenCodeContent) -> String? {
        switch content {
        case .markdown:
            return showSource ? String(localized: "Reader") : String(localized: "Source")
        case .html:
            return showSource ? String(localized: "Preview") : String(localized: "Source")
        case .diff(let document):
            guard Self.isHTMLFilePath(document.filePath) else { return nil }
            return showSource ? String(localized: "Diff") : String(localized: "Render")
        case .latex, .orgMode, .mermaid:
            return showSource ? String(localized: "Rendered") : String(localized: "Source")
        default:
            return nil
        }
    }

    private func readerFamily(for content: FullScreenCodeContent) -> FullScreenReaderContentFamily? {
        switch content {
        case .markdown, .thinking:
            return .markdown
        case .code, .graphviz:
            return .code
        case .plainText:
            return .source
        case .diff:
            return .diff
        case .terminal:
            return .terminal
        case .html:
            return .html
        case .orgMode:
            return .markdown
        case .latex, .mermaid:
            return .renderedDocument
        case .liveSource(let snapshot, _):
            return readerFamily(for: bodyContent(for: snapshot))
        }
    }

    private func readerPreferences(for content: FullScreenCodeContent) -> FullScreenReaderPreferences {
        guard let family = readerFamily(for: content) else {
            return FullScreenReaderPreferences()
        }
        return FullScreenReaderPreferencesStore.shared.preferences(for: family)
    }

    // MARK: - HTML Diff Helpers

    private static func isHTMLFilePath(_ filePath: String?) -> Bool {
        guard let filePath else { return false }
        let ext = (filePath as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
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
        FullScreenCopyDestination.write(makePresentation().copyText)
        copyButton?.image = UIImage(systemName: "checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyButton?.image = UIImage(systemName: "doc.on.doc")
        }
    }

    @objc private func showViewingOptions() {
        let presentation = makePresentation()
        guard let family = presentation.readerFamily,
              let preferences = presentation.readerPreferences,
              let sourceButton = floatingViewingOptionsButton else { return }

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

        if traitCollection.horizontalSizeClass == .regular {
            options.modalPresentationStyle = .popover
            options.popoverPresentationController?.sourceView = sourceButton
            options.popoverPresentationController?.sourceRect = sourceButton.bounds
            options.popoverPresentationController?.permittedArrowDirections = [.down, .right]
        } else {
            options.modalPresentationStyle = .pageSheet
        }

        if let sheet = options.sheetPresentationController {
            let detentIdentifier = UISheetPresentationController.Detent.Identifier("viewing-options")
            sheet.detents = [
                .custom(identifier: detentIdentifier) { [weak options] _ in
                    options?.preferredSheetHeight ?? 280
                }
            ]
            sheet.selectedDetentIdentifier = detentIdentifier
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 24
        }

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
        applyReaderPreferences(
            family.defaultPreferences,
            bodyContent: presentation.bodyContent
        )
    }

    private func updateReaderPreferences(_ mutate: (inout FullScreenReaderPreferences) -> Void) {
        let presentation = makePresentation()
        guard let family = presentation.readerFamily,
              var preferences = presentation.readerPreferences else { return }

        mutate(&preferences)
        FullScreenReaderPreferencesStore.shared.setPreferences(preferences, for: family)
        let normalized = FullScreenReaderPreferencesStore.shared.preferences(for: family)
        applyReaderPreferences(normalized, bodyContent: presentation.bodyContent)
    }

    private func applyReaderPreferences(
        _ preferences: FullScreenReaderPreferences,
        bodyContent: FullScreenCodeContent
    ) {
        if let configurable = installedBodyView as? FullScreenReaderConfigurable {
            configurable.applyReaderPreferences(preferences)
        } else if let viewController = contentHostController {
            installBodyView(makeBodyView(for: bodyContent, themeID: bodyThemeID), on: viewController)
        }

        guard let viewController = contentHostController else { return }
        configureNavigation(on: viewController, palette: bodyThemeID.palette)

        let presentation = makePresentation()
        if let family = presentation.readerFamily,
           let latestPreferences = presentation.readerPreferences {
            viewingOptionsController?.apply(family: family, preferences: latestPreferences)
        }
    }

    private func copyText(for content: FullScreenCodeContent) -> String {
        switch content {
        case .code(let text, _, _, _):
            return text
        case .plainText(let text, _):
            return text
        case .diff(let document):
            return document.copyText
        case .markdown(let text, _, _):
            return text
        case .html(let text, _):
            return text
        case .thinking(let text, let stream):
            return stream?.snapshot.text ?? text
        case .terminal(let text, _, let stream):
            return ANSIParser.strip(stream?.snapshot.output ?? text)
        case .liveSource(let snapshot, _):
            return copyText(for: semanticContent(for: snapshot))
        case .latex(let text, _), .orgMode(let text, _),
             .mermaid(let text, _), .graphviz(let text, _):
            return text
        }
    }

    private func makeSourceContext(
        surface: ReviewCommentSurfaceKind,
        filePath: String? = nil,
        languageHint: String? = nil,
        fallbackSourceLabel: String? = nil
    ) -> ReviewCommentSourceContext? {
        guard let selectionContext = reviewCommentSelectionContext else { return nil }
        return selectionContext.sourceContextIgnoringSurfaceOverride(
            surface: surface,
            sourceLabel: selectionContext.sourceLabel ?? fallbackSourceLabel,
            filePath: filePath,
            languageHint: languageHint
        )
    }

    /// Bridge a review-comment router + source context into HTMLRenderView.
    private func makeHTMLReviewCommentHandler(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) -> ((String, UIViewController?) -> Void)? {
        guard let router, let sourceContext else { return nil }
        return { text, presentingViewController in
            router.dispatch(
                ReviewCommentSelectionRequest(
                    selectedText: text,
                    source: sourceContext
                ),
                presentingViewController: presentingViewController
            )
        }
    }

    private var canAnnotateRenderedHTML: Bool {
        installedBodyView is HTMLRenderView || liveSourceHTMLBodyView != nil
    }

    private var canAnnotateRenderedDiagram: Bool {
        !showSource && installedBodyView is NativeFullScreenRenderedDocumentBody
    }

    private var canAnnotateRenderedContent: Bool {
        canAnnotateRenderedHTML || canAnnotateRenderedDiagram
    }

    @objc private func annotateRenderedViewTapped() {
        guard isRenderedContentReady, !isSnapshotting else { return }
        isSnapshotting = true
        updateAnnotateAvailability()
        Task { @MainActor in
            defer {
                isSnapshotting = false
                updateAnnotateAvailability()
            }
            do {
                let image = try await snapshotRenderedContent()
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

    private var isHTMLRenderReady: Bool {
        ((installedBodyView as? HTMLRenderView) ?? liveSourceHTMLBodyView)?.isRenderReady == true
    }

    private var isRenderedContentReady: Bool {
        if canAnnotateRenderedHTML {
            return isHTMLRenderReady
        }
        return canAnnotateRenderedDiagram
    }

    private func updateAnnotateAvailability() {
        annotateButton?.isEnabled = isRenderedContentReady && !isSnapshotting
    }

    private func snapshotRenderedHTML() async throws -> UIImage {
        let renderView = (installedBodyView as? HTMLRenderView) ?? liveSourceHTMLBodyView
        guard let renderView else {
            throw PaperMarkupCanvasSession.SnapshotError.notReady
        }
        return try await renderView.snapshotRenderedImage()
    }

    private func snapshotRenderedContent() async throws -> UIImage {
        if canAnnotateRenderedHTML {
            return try await snapshotRenderedHTML()
        }
        guard let body = installedBodyView else {
            throw PaperMarkupCanvasSession.SnapshotError.notReady
        }
        body.layoutIfNeeded()
        let bounds = body.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            throw PaperMarkupCanvasSession.SnapshotError.notReady
        }
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            body.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - Share

    private func shareableContent() -> FileShareService.ShareableContent? {
        let content = currentSemanticContent()
        switch content {
        case .mermaid(let text, let filePath): return .mermaid(text, fileName: filePath)
        case .latex(let text, let filePath): return .latex(text, fileName: filePath)
        case .markdown(let text, let filePath, _): return .markdown(text, fileName: filePath)
        case .orgMode(let text, let filePath): return .orgMode(text, fileName: filePath)
        case .html(let text, let filePath): return .html(text, fileName: filePath)
        case .graphviz(let text, let filePath): return .code(text, language: "dot", fileName: filePath)
        case .code(let text, let lang, let filePath, _): return .code(text, language: lang, fileName: filePath)
        case .plainText(let text, let filePath): return .plainText(text, fileName: filePath)
        case .thinking(let text, let stream):
            return .plainText(stream?.snapshot.text ?? text)
        case .terminal(let text, _, let stream):
            return .plainText(stream?.snapshot.output ?? text)
        case .diff(let document):
            // Copy text is a unified patch, not the source file. Never keep
            // the original suffix (Foo.swift) or Save to Files can overwrite it.
            guard let path = document.filePath, !path.isEmpty else {
                return .plainText(document.copyText)
            }
            let diffName = FileShareService.exportFileName(
                originalFileName: path,
                genericBase: "diff",
                ext: "diff"
            )
            return .plainText(document.copyText, fileName: diffName)
        case .liveSource(let snapshot, _):
            return .plainText(snapshot.text, fileName: snapshot.filePath)
        }
    }

    @objc private func toggleSource() {
        guard makePresentation().sourceToggleTitle != nil,
              let viewController = contentHostController else {
            return
        }

        if let mutableMarkdown = installedBodyView as? NativeMutableFullScreenMarkdownBody {
            liveSourceMarkdownViewportIntent = mutableMarkdown.currentViewportIntent()
        }
        showSource.toggle()
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
        installBodyView(makeBodyView(for: presentation.bodyContent, themeID: themeID), on: viewController)
        configureNavigation(on: viewController, palette: palette)
    }
}

private final class FullScreenViewingOptionsController: UIHostingController<FullScreenViewingOptionsPanel> {
    private var family: FullScreenReaderContentFamily
    private var preferences: FullScreenReaderPreferences
    private let onTextScaleChanged: (CGFloat) -> Void
    private let onWrappingChanged: (Bool) -> Void
    private let onSpacingChanged: (FullScreenReaderSpacing) -> Void
    private let onReset: () -> Void

    var onDismiss: ((FullScreenViewingOptionsController) -> Void)?

    var preferredSheetHeight: CGFloat {
        var height: CGFloat = 238
        if family.supportsWrapping { height += 60 }
        if family.supportsSpacing { height += 82 }
        return height
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
        super.init(rootView: FullScreenViewingOptionsPanel(
            family: family,
            preferences: preferences,
            onTextScaleChanged: onTextScaleChanged,
            onWrappingChanged: onWrappingChanged,
            onSpacingChanged: onSpacingChanged,
            onReset: onReset
        ))
        preferredContentSize = CGSize(width: 340, height: preferredSheetHeight)
        sizingOptions = [.preferredContentSize]
    }

    @available(*, unavailable)
    @MainActor @preconcurrency
    required dynamic init?(coder aDecoder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
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
        preferredContentSize = CGSize(width: 340, height: preferredSheetHeight)
        rootView = makePanel()
    }

    private func makePanel() -> FullScreenViewingOptionsPanel {
        FullScreenViewingOptionsPanel(
            family: family,
            preferences: preferences,
            onTextScaleChanged: onTextScaleChanged,
            onWrappingChanged: onWrappingChanged,
            onSpacingChanged: onSpacingChanged,
            onReset: onReset
        )
    }
}

private struct FullScreenViewingOptionsPanel: View {
    let family: FullScreenReaderContentFamily
    let preferences: FullScreenReaderPreferences
    let onTextScaleChanged: (CGFloat) -> Void
    let onWrappingChanged: (Bool) -> Void
    let onSpacingChanged: (FullScreenReaderSpacing) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            textSizeControl

            if family.supportsWrapping {
                Divider().opacity(0.35)
                wrapControl
            }

            if family.supportsSpacing {
                Divider().opacity(0.35)
                spacingControl
            }

            resetButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(16)
        .tint(.themeCyan)
        .presentationBackground(.clear)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: FullScreenViewingOptionsSymbols.readerModeIconName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.themeFg)
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Viewing Options")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                Text("Reader controls")
                    .font(.caption)
                    .foregroundStyle(.themeFgDim)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var textSizeControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Text Size", systemImage: "textformat.size")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                Spacer()
                Text("\(Int(round(preferences.textScale * 100)))%")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.themeFgDim)
                    .accessibilityHidden(true)
            }

            Slider(
                value: textScaleBinding,
                in: Double(FullScreenReaderPreferences.minimumTextScale)...Double(FullScreenReaderPreferences.maximumTextScale),
                step: 0.05
            ) {
                Text("Text Size")
            } minimumValueLabel: {
                Image(systemName: "textformat.size.smaller")
            } maximumValueLabel: {
                Image(systemName: "textformat.size.larger")
            }
            .accessibilityValue("\(Int(round(preferences.textScale * 100))) percent")
        }
    }

    private var wrapControl: some View {
        Toggle(isOn: wrapBinding) {
            Label("Wrap Text", systemImage: CodeWrapControl.symbolName)
                .font(.subheadline)
                .foregroundStyle(.themeFg)
        }
        .toggleStyle(.switch)
    }

    private var spacingControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Spacing", systemImage: "line.3.horizontal.decrease")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)

            Picker("Spacing", selection: spacingBinding) {
                ForEach(FullScreenReaderSpacing.allCases, id: \.self) { spacing in
                    Text(spacing.displayName).tag(spacing)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var resetButton: some View {
        Button(action: onReset) {
            Label("Reset View", systemImage: "arrow.counterclockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
    }

    private var textScaleBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.textScale) },
            set: { onTextScaleChanged(CGFloat($0)) }
        )
    }

    private var wrapBinding: Binding<Bool> {
        Binding(
            get: { preferences.wrapsText },
            set: { onWrappingChanged($0) }
        )
    }

    private var spacingBinding: Binding<FullScreenReaderSpacing> {
        Binding(
            get: { preferences.spacing },
            set: { onSpacingChanged($0) }
        )
    }
}

private enum FullScreenViewingOptionsSymbols {
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
        navigationActions: [FullScreenViewerNavigationAction] = []
    ) -> FullScreenCodeViewController {
        FullScreenCodeViewController(
            content: content,
            presentationMode: presentationMode,
            reviewCommentSelectionContext: reviewCommentSelectionContext,
            lineAnchor: lineAnchor,
            lineAnchorNotice: lineAnchorNotice,
            navigationActions: navigationActions
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
