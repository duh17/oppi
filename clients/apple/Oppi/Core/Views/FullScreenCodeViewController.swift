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

final class FullScreenCodeViewController: UIViewController {

    /// Controls how the viewer presents its dismiss affordance.
    enum PresentationMode {
        /// Standalone sheet/fullScreenCover — chevron.down + `dismiss(animated:)`.
        case sheet
        /// Embedded inside a SwiftUI NavigationStack — chevron.backward + closure.
        case embedded(onDismiss: @MainActor @Sendable () -> Void)
    }

    private struct Presentation {
        let bodyContent: FullScreenCodeContent
        let copyText: String
        let sourceToggleTitle: String?
        let readerFamily: FullScreenReaderContentFamily?
        let readerPreferences: FullScreenReaderPreferences?
    }

    private struct NavigationPresentation: Equatable {
        let sourceToggleTitle: String?
        let readerFamily: FullScreenReaderContentFamily?
        let readerPreferences: FullScreenReaderPreferences?

        init(_ presentation: Presentation) {
            sourceToggleTitle = presentation.sourceToggleTitle
            readerFamily = presentation.readerFamily
            readerPreferences = presentation.readerPreferences
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
    private let reviewCommentAnnotations: [ReviewCommentInlineAnnotation]
    private var showSource = false
    private var copyButton: UIBarButtonItem?
    private var viewingOptionsButton: UIBarButtonItem?
    private weak var contentHostController: UIViewController?
    private var installedBodyView: UIView?
    private var liveSourceBodyView: NativeFullScreenSourceBody?
    private var liveSourceMarkdownBodyView: NativeFullScreenMarkdownBody?
    private var liveSourceHTMLBodyView: HTMLRenderView?
    private var liveSourceObserverCleanup: LiveSourceObserverCleanup?
    private var liveSourceCurrentSnapshot: SourceTraceStream.Snapshot?
    private var lastNavigationPresentation: NavigationPresentation?

    init(
        content: FullScreenCodeContent,
        presentationMode: PresentationMode = .sheet,
        reviewCommentSelectionContext: ReviewCommentSelectionContext? = nil,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter? = nil,
        reviewCommentSessionId: String? = nil,
        reviewCommentSourceLabel: String? = nil,
        reviewCommentAnnotations: [ReviewCommentInlineAnnotation] = []
    ) {
        self.content = content
        self.presentationMode = presentationMode
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
            ?? ReviewCommentSelectionContext(
                router: reviewCommentSelectionRouter,
                sessionId: reviewCommentSessionId,
                sourceLabel: reviewCommentSourceLabel
            )
        self.reviewCommentAnnotations = reviewCommentAnnotations
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
        reviewCommentSourceLabel: String? = nil,
        reviewCommentAnnotations: [ReviewCommentInlineAnnotation] = []
    ) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        // Don't stack on top of an existing fullscreen viewer.
        if presenter is FullScreenCodeViewController
            || presenter is FullScreenImageViewController { return }

        let controller = FullScreenCodeViewController(
            content: content,
            reviewCommentSelectionContext: reviewCommentSelectionContext
                ?? ReviewCommentSelectionContext(
                    router: reviewCommentSelectionRouter,
                    sessionId: reviewCommentSessionId,
                    sourceLabel: reviewCommentSourceLabel
                ),
            reviewCommentAnnotations: reviewCommentAnnotations
        )
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        controller.overrideUserInterfaceStyle = ThemeRuntimeState.currentThemeID()
            .preferredColorScheme == .light ? .light : .dark
        presenter.present(controller, animated: true)
    }

    deinit {
        liveSourceObserverCleanup?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let palette = ThemeRuntimeState.currentThemeID().palette
        view.backgroundColor = UIColor(palette.bgDark)

        let nav = UINavigationController(rootViewController: makeContentController())
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

    private func makeContentController() -> UIViewController {
        let palette = ThemeRuntimeState.currentThemeID().palette
        let vc = UIViewController()
        vc.view.backgroundColor = UIColor(palette.bgDark)

        let doneIcon: String
        switch presentationMode {
        case .sheet:
            doneIcon = "chevron.down"
        case .embedded:
            doneIcon = "chevron.backward"
        }
        let doneButton = UIBarButtonItem(
            image: UIImage(systemName: doneIcon),
            style: .plain,
            target: self,
            action: #selector(doneTapped)
        )
        doneButton.tintColor = UIColor(palette.cyan)
        vc.navigationItem.leftBarButtonItem = doneButton

        contentHostController = vc

        // No custom UINavigationBarAppearance — iOS 26 Liquid Glass renders
        // bar items as floating glass pills. See FullScreenViewerChrome.

        installInitialBody(on: vc, palette: palette)
        configureNavigation(on: vc, palette: palette)

        return vc
    }

    private func installInitialBody(on viewController: UIViewController, palette: ThemePalette) {
        switch content {
        case .liveSource(let snapshot, let stream):
            liveSourceCurrentSnapshot = snapshot
            if snapshot.isDone {
                let presentation = makePresentation()
                installBodyView(makeBodyView(for: presentation.bodyContent, palette: palette), on: viewController)
            } else {
                installOrUpdateLiveSourceStreamingBody(snapshot: snapshot, on: viewController, palette: palette)
            }
            let observerID = stream.addObserver(deliverImmediately: false) { [weak self] snapshot in
                self?.handleLiveSourceUpdate(snapshot)
            }
            liveSourceObserverCleanup = LiveSourceObserverCleanup {
                stream.removeObserver(observerID)
            }

        default:
            let presentation = makePresentation()
            installBodyView(makeBodyView(for: presentation.bodyContent, palette: palette), on: viewController)
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
    }

    private func configureNavigation(on viewController: UIViewController, palette: ThemePalette) {
        let presentation = makePresentation()
        let navigationPresentation = NavigationPresentation(presentation)
        guard navigationPresentation != lastNavigationPresentation else {
            return
        }

        lastNavigationPresentation = navigationPresentation
        // No titleView — immersive mode shows only floating glass pills.
        // See FullScreenViewerChrome.

        var rightItems: [UIBarButtonItem] = []
        viewingOptionsButton = nil

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
                FileSharePresenter.makeShareBarButtonItem(
                    for: shareable,
                    tintColor: UIColor(palette.fgDim)
                )
            )
        }

        if let readerFamily = presentation.readerFamily,
           let readerPreferences = presentation.readerPreferences {
            let options = UIBarButtonItem(
                image: UIImage(systemName: "textformat"),
                style: .plain,
                target: nil,
                action: nil
            )
            options.tintColor = UIColor(palette.fgDim)
            options.accessibilityLabel = String(localized: "Viewing Options")
            options.menu = makeViewingOptionsMenu(
                family: readerFamily,
                preferences: readerPreferences
            )
            viewingOptionsButton = options
            rightItems.append(options)
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

    private func makeBodyView(for content: FullScreenCodeContent, palette: ThemePalette) -> UIView {
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
                reviewCommentAnnotations: reviewCommentAnnotations
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
                reviewCommentAnnotations: reviewCommentAnnotations
            )
        case .diff(let oldText, let newText, let filePath, let precomputedLines):
            return NativeFullScreenDiffBody(
                oldText: oldText,
                newText: newText,
                filePath: filePath,
                precomputedLines: precomputedLines,
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenDiff,
                    filePath: filePath
                ),
                reviewCommentAnnotations: reviewCommentAnnotations
            )
        case .markdown(let text, let filePath, let wsContext):
            let body = NativeFullScreenMarkdownBody(
                content: text,
                stream: nil,
                palette: palette,
                plainTextFallbackThreshold: nil,
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenMarkdown,
                    filePath: filePath
                ),
                reviewCommentAnnotations: reviewCommentAnnotations,
                workspaceID: wsContext?.workspaceID,
                sessionID: wsContext?.sessionID,
                serverBaseURL: wsContext?.serverBaseURL,
                sourceFilePath: filePath,
                readerPreferences: readerPreferences(for: content),
                perfSurface: .fullScreenMarkdown,
                fetchWorkspaceFile: wsContext?.fetchWorkspaceFile,
                fetchSessionFile: wsContext?.fetchSessionFile
            )
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
            return NativeFullScreenMarkdownBody(
                content: text,
                stream: stream,
                palette: palette,
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenThinking,
                    fallbackSourceLabel: String(localized: "Thinking")
                ),
                reviewCommentAnnotations: reviewCommentAnnotations,
                readerPreferences: readerPreferences(for: content),
                perfSurface: .fullScreenThinking
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
                ),
                reviewCommentAnnotations: reviewCommentAnnotations
            )
        case .liveSource(let snapshot, _):
            return makeBodyView(for: bodyContent(for: snapshot), palette: palette)

        // Document renderers — use rendered views with source toggle
        case .latex(let text, let filePath):
            return NativeFullScreenRenderedDocumentBody(
                content: .latex(text),
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
            return NativeFullScreenRenderedDocumentBody(
                content: .orgMode(text),
                palette: palette,
                readerPreferences: readerPreferences(for: content),
                reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
                reviewCommentSourceContext: makeSourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "org"
                )
            )
        case .mermaid(let text, let filePath):
            return NativeFullScreenRenderedDocumentBody(
                content: .mermaid(text),
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
                reviewCommentAnnotations: reviewCommentAnnotations
            )
        }
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
            ),
            reviewCommentAnnotations: reviewCommentAnnotations
        )
        liveSourceBodyView = body
        return body
    }

    private func makeLiveSourceMarkdownBody(
        text: String,
        filePath: String?,
        workspaceContext: FullScreenCodeContent.WorkspaceContext?,
        isStreaming: Bool,
        palette: ThemePalette
    ) -> NativeFullScreenMarkdownBody {
        NativeFullScreenMarkdownBody(
            content: text,
            stream: nil,
            isStreaming: isStreaming,
            palette: palette,
            plainTextFallbackThreshold: nil,
            reviewCommentSelectionRouter: reviewCommentSelectionContext?.dispatcher,
            reviewCommentSourceContext: makeSourceContext(
                surface: .fullScreenMarkdown,
                filePath: filePath
            ),
            reviewCommentAnnotations: reviewCommentAnnotations,
            workspaceID: workspaceContext?.workspaceID,
            sessionID: workspaceContext?.sessionID,
            serverBaseURL: workspaceContext?.serverBaseURL,
            sourceFilePath: filePath,
            readerPreferences: readerPreferences(for: .markdown(content: text, filePath: filePath, workspaceContext: workspaceContext)),
            perfSurface: .fullScreenMarkdown,
            fetchWorkspaceFile: workspaceContext?.fetchWorkspaceFile,
            fetchSessionFile: workspaceContext?.fetchSessionFile
        )
    }

    private func makeLiveSourceHTMLBody(
        text: String,
        filePath: String?,
        palette: ThemePalette
    ) -> HTMLRenderView {
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

    private func installOrUpdateLiveSourceStreamingBody(
        snapshot: SourceTraceStream.Snapshot,
        on viewController: UIViewController,
        palette: ThemePalette
    ) {
        switch bodyContent(for: snapshot) {
        case .markdown(let text, let filePath, let workspaceContext):
            liveSourceBodyView = nil
            liveSourceHTMLBodyView = nil
            if let body = liveSourceMarkdownBodyView, installedBodyView === body {
                body.update(content: text, isStreaming: true)
            } else {
                let body = makeLiveSourceMarkdownBody(
                    text: text,
                    filePath: filePath,
                    workspaceContext: workspaceContext,
                    isStreaming: true,
                    palette: palette
                )
                liveSourceMarkdownBodyView = body
                installBodyView(body, on: viewController)
            }

        case .html(let text, let filePath):
            liveSourceBodyView = nil
            liveSourceMarkdownBodyView = nil
            if let body = liveSourceHTMLBodyView, installedBodyView === body {
                body.load(text)
            } else {
                let body = makeLiveSourceHTMLBody(text: text, filePath: filePath, palette: palette)
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

        let palette = ThemeRuntimeState.currentThemeID().palette
        if snapshot.isDone {
            clearLiveSourceBodyReferences()
            let presentation = makePresentation()
            installBodyView(makeBodyView(for: presentation.bodyContent, palette: palette), on: viewController)
        } else {
            installOrUpdateLiveSourceStreamingBody(snapshot: snapshot, on: viewController, palette: palette)
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
            if case .diff(_, _, let filePath, let precomputedLines) = content,
               Self.isHTMLFilePath(filePath),
               let lines = precomputedLines {
                let fullNewText = lines
                    .filter { $0.kind != .removed }
                    .map(\.text)
                    .joined(separator: "\n")
                return .html(content: fullNewText, filePath: filePath)
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
        case .diff(_, _, let filePath, let precomputedLines):
            guard Self.isHTMLFilePath(filePath), precomputedLines != nil else { return nil }
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
        case .latex, .orgMode, .mermaid:
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

    private func makeViewingOptionsMenu(
        family: FullScreenReaderContentFamily,
        preferences: FullScreenReaderPreferences
    ) -> UIMenu {
        var children: [UIMenuElement] = []

        let smaller = UIAction(
            title: String(localized: "Smaller Text"),
            image: UIImage(systemName: "textformat.size.smaller")
        ) { [weak self] _ in
            self?.adjustReaderTextSize(by: -1)
        }
        if !preferences.textSize.canDecrease {
            smaller.attributes = [.disabled]
        }

        let larger = UIAction(
            title: String(localized: "Larger Text"),
            image: UIImage(systemName: "textformat.size.larger")
        ) { [weak self] _ in
            self?.adjustReaderTextSize(by: 1)
        }
        if !preferences.textSize.canIncrease {
            larger.attributes = [.disabled]
        }

        children.append(UIMenu(
            title: "",
            options: .displayInline,
            children: [smaller, larger]
        ))

        if family.supportsWrapping {
            let wrap = UIAction(
                title: preferences.wrapsText
                    ? String(localized: "Unwrap Text")
                    : String(localized: "Wrap Text"),
                image: UIImage(systemName: "text.alignleft"),
                state: preferences.wrapsText ? .on : .off
            ) { [weak self] _ in
                self?.setReaderWrapping(!preferences.wrapsText)
            }
            children.append(UIMenu(
                title: "",
                options: .displayInline,
                children: [wrap]
            ))
        }

        if family.supportsSpacing {
            let spacingActions = FullScreenReaderSpacing.allCases.map { spacing in
                UIAction(
                    title: spacing.displayName,
                    state: preferences.spacing == spacing ? .on : .off
                ) { [weak self] _ in
                    self?.setReaderSpacing(spacing)
                }
            }
            children.append(UIMenu(
                title: String(localized: "Spacing"),
                image: UIImage(systemName: "line.3.horizontal.decrease"),
                children: spacingActions
            ))
        }

        let reset = UIAction(
            title: String(localized: "Reset View"),
            image: UIImage(systemName: "arrow.counterclockwise")
        ) { [weak self] _ in
            self?.resetReaderPreferences()
        }
        children.append(UIMenu(
            title: "",
            options: .displayInline,
            children: [reset]
        ))

        return UIMenu(title: String(localized: "Viewing Options"), children: children)
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
        }
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = makePresentation().copyText
        copyButton?.image = UIImage(systemName: "checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyButton?.image = UIImage(systemName: "doc.on.doc")
        }
    }

    private func adjustReaderTextSize(by delta: Int) {
        updateReaderPreferences { preferences in
            preferences.textSize = preferences.textSize.adjusted(by: delta)
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
        applyReaderPreferences(preferences, bodyContent: presentation.bodyContent)
    }

    private func applyReaderPreferences(
        _ preferences: FullScreenReaderPreferences,
        bodyContent: FullScreenCodeContent
    ) {
        if let configurable = installedBodyView as? FullScreenReaderConfigurable {
            configurable.applyReaderPreferences(preferences)
        } else if let viewController = contentHostController {
            let palette = ThemeRuntimeState.currentThemeID().palette
            installBodyView(makeBodyView(for: bodyContent, palette: palette), on: viewController)
        }

        guard let viewController = contentHostController else { return }
        let palette = ThemeRuntimeState.currentThemeID().palette
        configureNavigation(on: viewController, palette: palette)
    }

    private func copyText(for content: FullScreenCodeContent) -> String {
        switch content {
        case .code(let text, _, _, _):
            return text
        case .plainText(let text, _):
            return text
        case .diff(_, let newText, _, _):
            return newText
        case .markdown(let text, _, _):
            return text
        case .html(let text, _):
            return text
        case .thinking(let text, let stream):
            return stream?.snapshot.text ?? text
        case .terminal(let text, _, let stream):
            return stream?.snapshot.output ?? text
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

    // MARK: - Share

    private func shareableContent() -> FileShareService.ShareableContent? {
        let content = currentSemanticContent()
        switch content {
        case .mermaid(let text, _): return .mermaid(text)
        case .latex(let text, _): return .latex(text)
        case .markdown(let text, _, _): return .markdown(text)
        case .orgMode(let text, _): return .orgMode(text)
        case .html(let text, _): return .html(text)
        case .graphviz(let text, _): return .code(text, language: "dot")
        case .code(let text, let lang, _, _): return .code(text, language: lang)
        case .plainText(let text, _): return .plainText(text)
        case .thinking(let text, let stream):
            return .plainText(stream?.snapshot.text ?? text)
        case .terminal(let text, _, let stream):
            return .plainText(stream?.snapshot.output ?? text)
        case .diff(_, let newText, _, _): return .plainText(newText)
        case .liveSource(let snapshot, _):
            return .plainText(snapshot.text)
        }
    }

    @objc private func toggleSource() {
        guard makePresentation().sourceToggleTitle != nil,
              let viewController = contentHostController else {
            return
        }

        showSource.toggle()
        let palette = ThemeRuntimeState.currentThemeID().palette
        if case .liveSource(let initialSnapshot, _) = content {
            let snapshot = liveSourceCurrentSnapshot ?? initialSnapshot
            if !snapshot.isDone {
                installOrUpdateLiveSourceStreamingBody(snapshot: snapshot, on: viewController, palette: palette)
                configureNavigation(on: viewController, palette: palette)
                return
            }
        }

        let presentation = makePresentation()
        installBodyView(makeBodyView(for: presentation.bodyContent, palette: palette), on: viewController)
        configureNavigation(on: viewController, palette: palette)
    }
}

#if DEBUG
extension FullScreenCodeViewController {
    var viewingOptionsMenuForTesting: UIMenu? {
        viewingOptionsButton?.menu
    }

    func setReaderWrappingForTesting(_ wraps: Bool) {
        setReaderWrapping(wraps)
    }
}
#endif
