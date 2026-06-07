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

final class FullScreenCodeViewController: UIViewController {

    /// Controls how the viewer presents its dismiss affordance.
    enum PresentationMode {
        /// Standalone sheet/fullScreenCover — chevron.down + `dismiss(animated:)`.
        case sheet
        /// Embedded inside a SwiftUI NavigationStack — chevron.backward + closure.
        case embedded(onDismiss: @MainActor @Sendable () -> Void)
        /// Embedded pane content without a navigation bar or dismiss affordance.
        case contentOnly
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
    private var showSource = false
    private var copyButton: UIBarButtonItem?
    private var floatingViewingOptionsButton: UIButton?
    private weak var viewingOptionsController: FullScreenViewingOptionsController?
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
        reviewCommentSourceLabel: String? = nil
    ) {
        self.content = content
        self.presentationMode = presentationMode
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
            ?? ReviewCommentSelectionContext(
                router: reviewCommentSelectionRouter,
                sessionId: reviewCommentSessionId,
                sourceLabel: reviewCommentSourceLabel
            )
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
                )
        )
        FullScreenViewerPresentationPolicy.configureLargePresentation(
            controller,
            traitCollection: presenter.traitCollection
        )
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

    private func makeContentController() -> UIViewController {
        let palette = ThemeRuntimeState.currentThemeID().palette
        let vc = UIViewController()
        vc.view.backgroundColor = UIColor(palette.bgDark)

        let doneIcon: String?
        switch presentationMode {
        case .sheet:
            doneIcon = "chevron.down"
        case .embedded:
            doneIcon = "chevron.backward"
        case .contentOnly:
            doneIcon = nil
        }
        if let doneIcon {
            let doneButton = UIBarButtonItem(
                image: UIImage(systemName: doneIcon),
                style: .plain,
                target: self,
                action: #selector(doneTapped)
            )
            doneButton.tintColor = UIColor(palette.cyan)
            vc.navigationItem.leftBarButtonItem = doneButton
        }

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
        if let floatingViewingOptionsButton {
            viewController.view.bringSubviewToFront(floatingViewingOptionsButton)
        }
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
            return
        }

        lastNavigationPresentation = navigationPresentation
        // No titleView — immersive mode shows only floating glass pills.
        // See FullScreenViewerChrome.

        var rightItems: [UIBarButtonItem] = []

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
                    constant: -16
                ),
                button.bottomAnchor.constraint(
                    equalTo: viewController.view.safeAreaLayoutGuide.bottomAnchor,
                    constant: -16
                ),
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])
        }

        updateFloatingViewingOptionsButton(button, palette: palette, preferences: readerPreferences)
        viewController.view.bringSubviewToFront(button)
        viewingOptionsController?.apply(family: readerFamily, preferences: readerPreferences)
    }

    private func makeFloatingViewingOptionsButton(palette: ThemePalette) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: FullScreenViewingOptionsSymbols.readerModeIconName)
        config.preferredSymbolConfigurationForImage = .init(pointSize: 20, weight: .semibold)
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        config.background.visualEffect = UIBlurEffect(style: .systemThinMaterial)
        config.background.strokeColor = UIColor(palette.comment).withAlphaComponent(0.35)
        config.background.strokeWidth = 1
        config.cornerStyle = .capsule
        config.baseForegroundColor = UIColor(palette.fg)

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
        config.baseForegroundColor = UIColor(palette.fg)
        config.background.strokeColor = UIColor(palette.comment).withAlphaComponent(0.35)
        button.configuration = config
        button.accessibilityValue = String(
            localized: "Text size \(Int(round(preferences.textScale * 100))) percent"
        )
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
                )
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
                )
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
                )
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
                )
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
                )
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
        case .contentOnly:
            break
        }
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = makePresentation().copyText
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
            let palette = ThemeRuntimeState.currentThemeID().palette
            installBodyView(makeBodyView(for: bodyContent, palette: palette), on: viewController)
        }

        guard let viewController = contentHostController else { return }
        let palette = ThemeRuntimeState.currentThemeID().palette
        configureNavigation(on: viewController, palette: palette)

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
            Label("Wrap Text", systemImage: "text.alignleft")
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
        reviewCommentSelectionContext: ReviewCommentSelectionContext?
    ) -> FullScreenCodeViewController {
        FullScreenCodeViewController(
            content: content,
            reviewCommentSelectionContext: reviewCommentSelectionContext
        )
    }

    var hasFloatingViewingOptionsButtonForTesting: Bool {
        floatingViewingOptionsButton != nil
    }

    var floatingViewingOptionsButtonFrameForTesting: CGRect? {
        guard let button = floatingViewingOptionsButton,
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
}
#endif
