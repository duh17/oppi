import SwiftUI
import UIKit

/// Full-screen content viewer for tool output (UIKit).
///
/// Supports code (with syntax highlighting), diff, and markdown modes.
/// Presented via ``FullScreenCodeView`` (UIViewControllerRepresentable wrapper)
/// from SwiftUI callers, and directly from UIKit timeline cells.

final class FullScreenCodeViewController: UIViewController {
    private struct Presentation {
        let bodyContent: FullScreenCodeContent
        let copyText: String
        let sourceToggleTitle: String?
    }

    private struct NavigationPresentation: Equatable {
        let sourceToggleTitle: String?

        init(_ presentation: Presentation) {
            sourceToggleTitle = presentation.sourceToggleTitle
        }
    }

    private let content: FullScreenCodeContent
    private let selectedTextPiRouter: SelectedTextPiActionRouter?
    private let selectedTextSessionId: String?
    private let selectedTextSourceLabel: String?
    private var showSource = false
    private var copyButton: UIBarButtonItem?
    private weak var contentHostController: UIViewController?
    private var installedBodyView: UIView?
    private var liveSourceBodyView: NativeFullScreenSourceBody?
    private var liveSourceObserverID: UUID?
    private var liveSourceCurrentSnapshot: SourceTraceStream.Snapshot?
    private var lastNavigationPresentation: NavigationPresentation?

    init(
        content: FullScreenCodeContent,
        selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
        selectedTextSessionId: String? = nil,
        selectedTextSourceLabel: String? = nil
    ) {
        self.content = content
        self.selectedTextPiRouter = selectedTextPiRouter
        self.selectedTextSessionId = selectedTextSessionId
        self.selectedTextSourceLabel = selectedTextSourceLabel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let liveSourceObserverID,
           case .liveSource(_, let stream) = content {
            Task { @MainActor in
                stream.removeObserver(liveSourceObserverID)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let palette = ThemeRuntimeState.currentThemeID().palette
        view.backgroundColor = UIColor(palette.bgDark)

        let nav = UINavigationController(rootViewController: makeContentController())
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

        let doneButton = UIBarButtonItem(
            image: UIImage(systemName: "chevron.down"),
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
            let body = makeLiveSourceBody(snapshot: snapshot, palette: palette)
            installBodyView(body, on: viewController)
            liveSourceObserverID = stream.addObserver(deliverImmediately: false) { [weak self] snapshot in
                self?.handleLiveSourceUpdate(snapshot)
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
        let copy = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copyTapped)
        )
        copy.tintColor = UIColor(palette.fgDim)
        copyButton = copy
        rightItems.append(copy)

        // Share button — tap for default, long-press for format picker
        if let shareable = shareableContent() {
            let formats = FileShareService.availableFormats(for: shareable)
            let shareButton = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"),
                primaryAction: UIAction { [weak self] _ in
                    self?.shareDefaultFormat()
                },
                menu: formats.count > 1 ? makeShareMenu(formats: formats) : nil
            )
            shareButton.tintColor = UIColor(palette.fgDim)
            rightItems.append(shareButton)
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
        return Presentation(
            bodyContent: bodyContent(for: semanticContent),
            copyText: copyText(for: semanticContent),
            sourceToggleTitle: sourceToggleTitle(for: semanticContent)
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
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
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
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
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
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
                    surface: .fullScreenDiff,
                    filePath: filePath
                )
            )
        case .markdown(let text, let filePath):
            return NativeFullScreenMarkdownBody(
                content: text,
                stream: nil,
                palette: palette,
                plainTextFallbackThreshold: nil,
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
                    surface: .fullScreenMarkdown,
                    filePath: filePath
                )
            )
        case .html(let text, let filePath):
            return NativeFullScreenHTMLBody(
                htmlString: text,
                palette: palette,
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
                    surface: .fullScreenSource,
                    filePath: filePath
                )
            )
        case .thinking(let text, let stream):
            return NativeFullScreenMarkdownBody(
                content: text,
                stream: stream,
                palette: palette,
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
                    surface: .fullScreenThinking,
                    fallbackSourceLabel: String(localized: "Thinking")
                )
            )
        case .terminal(let text, let command, let stream):
            return NativeFullScreenTerminalBody(
                content: text,
                command: command,
                stream: stream,
                palette: palette,
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
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
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "latex"
                )
            )
        case .orgMode(let text, let filePath):
            return NativeFullScreenRenderedDocumentBody(
                content: .orgMode(text),
                palette: palette,
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
                    surface: .fullScreenCode,
                    filePath: filePath,
                    languageHint: "org"
                )
            )
        case .mermaid(let text, let filePath):
            return NativeFullScreenRenderedDocumentBody(
                content: .mermaid(text),
                palette: palette,
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
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
                selectedTextPiRouter: selectedTextPiRouter,
                selectedTextSourceContext: makeSourceContext(
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
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSourceContext: makeSourceContext(
                surface: .fullScreenSource,
                filePath: snapshot.filePath
            )
        )
        liveSourceBodyView = body
        return body
    }

    private func handleLiveSourceUpdate(_ snapshot: SourceTraceStream.Snapshot) {
        liveSourceCurrentSnapshot = snapshot
        guard let viewController = contentHostController else { return }

        let palette = ThemeRuntimeState.currentThemeID().palette
        if snapshot.isDone {
            liveSourceBodyView = nil
            let presentation = makePresentation()
            installBodyView(makeBodyView(for: presentation.bodyContent, palette: palette), on: viewController)
        } else if let liveSourceBodyView {
            liveSourceBodyView.update(content: snapshot.text, isStreaming: true)
        } else {
            installBodyView(makeLiveSourceBody(snapshot: snapshot, palette: palette), on: viewController)
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
        return .plainText(content: snapshot.text, filePath: snapshot.filePath)
    }

    private func bodyContent(for snapshot: SourceTraceStream.Snapshot) -> FullScreenCodeContent {
        bodyContent(for: semanticContent(for: snapshot))
    }

    private func bodyContent(for content: FullScreenCodeContent) -> FullScreenCodeContent {
        if showSource {
            if case .markdown(let text, let filePath) = content {
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

    // MARK: - HTML Diff Helpers

    private static func isHTMLFilePath(_ filePath: String?) -> Bool {
        guard let filePath else { return false }
        let ext = (filePath as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = makePresentation().copyText
        copyButton?.image = UIImage(systemName: "checkmark")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyButton?.image = UIImage(systemName: "doc.on.doc")
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
        case .markdown(let text, _):
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
        surface: SelectedTextSurfaceKind,
        filePath: String? = nil,
        languageHint: String? = nil,
        fallbackSourceLabel: String? = nil
    ) -> SelectedTextSourceContext? {
        guard let sessionId = selectedTextSessionId else { return nil }
        return SelectedTextSourceContext(
            sessionId: sessionId,
            surface: surface,
            sourceLabel: selectedTextSourceLabel ?? fallbackSourceLabel,
            filePath: filePath,
            languageHint: languageHint
        )
    }

    // MARK: - Share

    private func shareableContent() -> FileShareService.ShareableContent? {
        let content = currentSemanticContent()
        switch content {
        case .mermaid(let text, _): return .mermaid(text)
        case .latex(let text, _): return .latex(text)
        case .markdown(let text, _): return .markdown(text)
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

    private func shareDefaultFormat() {
        guard let shareable = shareableContent() else { return }
        Task {
            let item = await FileShareService.renderDefault(shareable)
            presentShareSheet(item: item)
        }
    }

    private func share(format: FileShareService.ExportFormat) {
        guard let shareable = shareableContent() else { return }
        Task {
            let item = await FileShareService.render(shareable, as: format)
            presentShareSheet(item: item)
        }
    }

    private func presentShareSheet(item: FileShareService.ShareItem) {
        let vc = UIActivityViewController(
            activityItems: item.activityItems,
            applicationActivities: nil
        )
        vc.completionWithItemsHandler = { _, _, _, _ in
            FileShareService.cleanupTempFiles()
        }
        if let popover = vc.popoverPresentationController,
           let barItems = contentHostController?.navigationItem.rightBarButtonItems {
            popover.barButtonItem = barItems.first(where: {
                $0.image == UIImage(systemName: "square.and.arrow.up")
            })
        }
        present(vc, animated: true)
    }

    private func makeShareMenu(formats: [FileShareService.ExportFormat]) -> UIMenu {
        let actions = formats.map { format in
            let (title, icon) = formatDisplayInfo(format)
            return UIAction(title: title, image: UIImage(systemName: icon)) { [weak self] _ in
                self?.share(format: format)
            }
        }
        return UIMenu(children: actions)
    }

    private func formatDisplayInfo(_ format: FileShareService.ExportFormat) -> (String, String) {
        switch format {
        case .image: return ("Share as Image", "photo")
        case .pdf: return ("Share as PDF", "doc.richtext")
        case .source: return ("Share Source", "doc.text")
        }
    }

    @objc private func toggleSource() {
        guard makePresentation().sourceToggleTitle != nil,
              let viewController = contentHostController else {
            return
        }

        showSource.toggle()
        let palette = ThemeRuntimeState.currentThemeID().palette
        let presentation = makePresentation()
        installBodyView(makeBodyView(for: presentation.bodyContent, palette: palette), on: viewController)
        configureNavigation(on: viewController, palette: palette)
    }
}
