import SwiftUI
import UIKit
import WebKit

// MARK: - HTML Body

/// Full-screen HTML renderer using WKWebView.
///
/// Same security posture as `HTMLWebView`: ephemeral data store,
/// no bridge injection, external links open in Safari.
final class NativeFullScreenHTMLBody: UIView, WKNavigationDelegate {
    private let webView: PiWKWebView
    private let htmlString: String

    init(
        htmlString: String,
        palette: ThemePalette,
        selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
        selectedTextSourceContext: SelectedTextSourceContext? = nil
    ) {
        self.htmlString = htmlString

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all

        let wv = PiWKWebView(frame: .zero, configuration: config)
        wv.isInspectable = false
        wv.allowsBackForwardNavigationGestures = false
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.configurePiRouter(selectedTextPiRouter, sourceContext: selectedTextSourceContext)
        self.webView = wv

        super.init(frame: .zero)
        backgroundColor = UIColor(palette.bgDark)

        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        webView.loadHTMLString(htmlString, baseURL: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - WKNavigationDelegate

    /// Block all navigation except the initial load. External links open in Safari.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .other {
            decisionHandler(.allow)
            return
        }
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    /// Block popups — open in Safari instead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            UIApplication.shared.open(url)
        }
        return nil
    }

    /// Recover from content process crashes.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.loadHTMLString(htmlString, baseURL: nil)
    }
}

// MARK: - Code Body

final class NativeFullScreenCodeBody: UIView {
    private let scrollView = UIScrollView()
    private let gutterView = UITextView()
    private let separatorView = UIView()
    private let codeTextView = UITextView()
    private let content: String
    private let language: String?
    private let startLine: Int
    private let palette: ThemePalette
    private let alwaysBounceVertical: Bool
    private let selectedTextPiRouter: SelectedTextPiActionRouter?
    private let selectedTextSourceContext: SelectedTextSourceContext?
    private var highlightTask: Task<Void, Never>?

    init(
        content: String,
        language: String?,
        startLine: Int,
        palette: ThemePalette,
        alwaysBounceVertical: Bool = true,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?
    ) {
        self.content = content
        self.language = language
        self.startLine = startLine
        self.palette = palette
        self.alwaysBounceVertical = alwaysBounceVertical
        self.selectedTextPiRouter = selectedTextPiRouter
        self.selectedTextSourceContext = selectedTextSourceContext
        super.init(frame: .zero)
        setup()
        loadHighlighting()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { highlightTask?.cancel() }

    private func setup() {
        backgroundColor = UIColor(palette.bgDark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = alwaysBounceVertical
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)

        let contentContainer = UIView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentContainer)

        // Gutter — uses UITextView (not UILabel) so line heights match codeTextView exactly.
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.font = FullScreenCodeTypography.codeFont
        gutterView.textColor = UIColor(palette.comment)
        gutterView.textAlignment = .right
        gutterView.isEditable = false
        gutterView.isSelectable = false
        gutterView.isScrollEnabled = false
        gutterView.backgroundColor = .clear
        gutterView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        gutterView.textContainer.lineFragmentPadding = 0
        contentContainer.addSubview(gutterView)

        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let (numbers, gutterWidth) = lineNumberInfo(lineCount: lineCount, startLine: startLine)
        gutterView.text = numbers

        // Separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.2)
        contentContainer.addSubview(separatorView)

        // Code text
        codeTextView.translatesAutoresizingMaskIntoConstraints = false
        codeTextView.font = FullScreenCodeTypography.codeFont
        codeTextView.textColor = UIColor(palette.fg)
        codeTextView.backgroundColor = .clear
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isScrollEnabled = false
        codeTextView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        codeTextView.textContainer.lineFragmentPadding = 0
        codeTextView.textContainer.lineBreakMode = .byClipping
        codeTextView.textContainer.widthTracksTextView = false
        codeTextView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeTextView.text = content
        codeTextView.delegate = self
        contentContainer.addSubview(codeTextView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            gutterView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 6),
            gutterView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: gutterWidth),

            separatorView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor, constant: 6),
            separatorView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: 1),

            codeTextView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor),
            codeTextView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            codeTextView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            codeTextView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),

            // Ensure gutter matches code height
            gutterView.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor),
            codeTextView.bottomAnchor.constraint(greaterThanOrEqualTo: gutterView.bottomAnchor),
        ])
    }

    private func loadHighlighting() {
        guard let lang = language, !lang.isEmpty else { return }
        let syntaxLang = SyntaxLanguage.detect(lang)
        guard syntaxLang != .unknown else { return }

        let text = content
        highlightTask = Task { [weak self] in
            // Use SendableNSAttributedString to avoid the lossy
            // NSAttributedString → AttributedString → NSAttributedString round-trip
            // that can corrupt UIKit's internal NSMutableRLEArray. (APPLE-IOS-1Y)
            let wrapper = await Task.detached(priority: .userInitiated) {
                SendableNSAttributedString(
                    FullScreenCodeHighlighter.buildHighlightedText(text, language: syntaxLang)
                )
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.codeTextView.attributedText = fullScreenAttributedCodeText(
                    from: wrapper.value
                )
            }
        }
    }
}

extension NativeFullScreenCodeBody: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenSelectedTextMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selectedTextPiRouter,
            sourceContext: selectedTextSourceContext
        )
    }
}

// MARK: - Diff Body

final class NativeFullScreenDiffBody: UIView {
    private let scrollView = UIScrollView()
    private let diffTextView = UITextView()
    private let selectedTextPiRouter: SelectedTextPiActionRouter?
    private let selectedTextSourceContext: SelectedTextSourceContext?

    init(
        oldText: String,
        newText: String,
        filePath: String?,
        precomputedLines: [DiffLine]?,
        palette: ThemePalette,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?
    ) {
        self.selectedTextPiRouter = selectedTextPiRouter
        self.selectedTextSourceContext = selectedTextSourceContext
        super.init(frame: .zero)
        backgroundColor = UIColor(palette.bgDark)

        let lines = precomputedLines ?? DiffEngine.compute(old: oldText, new: newText)

        // Scroll view with selectable diff text.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.backgroundColor = UIColor(palette.bgDark)

        diffTextView.translatesAutoresizingMaskIntoConstraints = false
        diffTextView.font = FullScreenCodeTypography.codeFont
        diffTextView.textColor = UIColor(palette.fg)
        diffTextView.backgroundColor = .clear
        diffTextView.isEditable = false
        diffTextView.isSelectable = true
        diffTextView.isScrollEnabled = false
        diffTextView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 14, right: 12)
        diffTextView.textContainer.lineFragmentPadding = 0
        diffTextView.textContainer.lineBreakMode = .byClipping
        diffTextView.textContainer.widthTracksTextView = false
        diffTextView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffTextView.delegate = self
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
        let diffText = DiffAttributedStringBuilder.build(hunks: hunks, filePath: filePath ?? "diff.txt", includeStats: true)
        diffTextView.attributedText = diffText

        let measured = diffText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let widthConstraint = diffTextView.widthAnchor.constraint(equalToConstant: ceil(measured.width) + 24)

        scrollView.addSubview(diffTextView)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            diffTextView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            diffTextView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            diffTextView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            diffTextView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            widthConstraint,
            diffTextView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

extension NativeFullScreenDiffBody: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenSelectedTextMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selectedTextPiRouter,
            sourceContext: selectedTextSourceContext
        )
    }
}

// MARK: - Terminal Body

final class NativeFullScreenTerminalBody: UIView, UIScrollViewDelegate {
    private static let maxSynchronousANSIBytes = 64 * 1024

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let commandView = UITextView()
    private let outputView = UITextView()
    private let palette: ThemePalette
    private let stream: TerminalTraceStream?
    private let selectedTextPiRouter: SelectedTextPiActionRouter?
    private let selectedTextSourceContext: SelectedTextSourceContext?

    private var latestSnapshot: TerminalTraceStream.Snapshot
    private var renderedSnapshot: TerminalTraceStream.Snapshot?

    private lazy var tailFollowCoordinator = TailFollowScrollCoordinator(
        scrollView: scrollView,
        shouldAutoFollowTail: false,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    private var renderTask: Task<Void, Never>?
    private var streamObserverID: UUID?

    init(
        content: String,
        command: String?,
        stream: TerminalTraceStream?,
        palette: ThemePalette,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?
    ) {
        self.palette = palette
        self.stream = stream
        self.selectedTextPiRouter = selectedTextPiRouter
        self.selectedTextSourceContext = selectedTextSourceContext

        let initialSnapshot = stream?.snapshot
            ?? TerminalTraceStream.Snapshot(output: content, command: command, isDone: true)
        latestSnapshot = initialSnapshot

        super.init(frame: .zero)
        tailFollowCoordinator.shouldAutoFollowTail = !initialSnapshot.isDone
        setup()
        render(snapshot: initialSnapshot)

        streamObserverID = stream?.addObserver { [weak self] snapshot in
            self?.handleStreamUpdate(snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        renderTask?.cancel()
        if let streamObserverID {
            let stream = stream
            Task { @MainActor in
                stream?.removeObserver(streamObserverID)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tailFollowCoordinator.onLayoutPass()
    }

    private func setup() {
        backgroundColor = UIColor(palette.bgDark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.delegate = self

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill

        commandView.translatesAutoresizingMaskIntoConstraints = false
        commandView.isEditable = false
        commandView.isSelectable = true
        commandView.isScrollEnabled = false
        commandView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        commandView.textContainer.lineFragmentPadding = 0
        commandView.backgroundColor = UIColor(palette.bgHighlight)
        commandView.layer.cornerRadius = 8
        commandView.delegate = self

        outputView.translatesAutoresizingMaskIntoConstraints = false
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.isScrollEnabled = false
        outputView.backgroundColor = .clear
        outputView.textContainerInset = UIEdgeInsets(top: 4, left: 6, bottom: 14, right: 6)
        outputView.textContainer.lineFragmentPadding = 0
        outputView.font = FullScreenCodeTypography.codeFont
        outputView.textColor = UIColor(palette.fg)
        outputView.delegate = self

        addSubview(scrollView)
        scrollView.addSubview(stack)

        stack.addArrangedSubview(commandView)
        stack.addArrangedSubview(outputView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -20),
        ])
    }

    private func handleStreamUpdate(_ snapshot: TerminalTraceStream.Snapshot) {
        latestSnapshot = snapshot
        render(snapshot: snapshot)
    }

    private func render(snapshot: TerminalTraceStream.Snapshot) {
        guard snapshot != renderedSnapshot else {
            tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
            return
        }

        renderedSnapshot = snapshot

        if let command = snapshot.command,
           !command.isEmpty {
            commandView.isHidden = false
            commandView.attributedText = ToolRowTextRenderer.bashCommandHighlighted(command)
        } else {
            commandView.isHidden = true
            commandView.attributedText = nil
            commandView.text = nil
        }

        renderTerminalOutput(snapshot.output, isStreaming: !snapshot.isDone)
        tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
    }

    private func renderTerminalOutput(_ content: String, isStreaming: Bool) {
        renderTask?.cancel()
        renderTask = nil

        if content.utf8.count <= Self.maxSynchronousANSIBytes {
            outputView.attributedText = ANSIParser.attributedString(
                from: content, baseForeground: .themeFg
            )
            return
        }

        outputView.attributedText = nil
        outputView.text = ANSIParser.strip(content)

        // Large streaming payloads stay in plain mode while streaming to avoid
        // launching expensive full-text ANSI parses on every chunk.
        guard !isStreaming else { return }

        let source = content
        renderTask = Task { [weak self] in
            // Use SendableNSAttributedString to avoid the lossy
            // AttributedString round-trip. (APPLE-IOS-1Y)
            let wrapper = await Task.detached(priority: .userInitiated) {
                SendableNSAttributedString(
                    ANSIParser.attributedString(from: source, baseForeground: .themeFg)
                )
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.outputView.attributedText = wrapper.value
                self?.tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
            }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleWillBeginDragging()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleDidScroll(
            isUserDriven: scrollView.isDragging || scrollView.isDecelerating,
            isStreaming: !latestSnapshot.isDone
        )
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        tailFollowCoordinator.handleDidEndDragging(
            willDecelerate: decelerate,
            isStreaming: !latestSnapshot.isDone
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleDidEndDecelerating(isStreaming: !latestSnapshot.isDone)
    }
}

extension NativeFullScreenTerminalBody: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenSelectedTextMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selectedTextPiRouter,
            sourceContext: selectedTextSourceContext
        )
    }
}

final class NativeFullScreenMarkdownBody: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let markdownView = AssistantMarkdownContentView()
    private let markdownWidthConstraint: NSLayoutConstraint
    private let stream: ThinkingTraceStream?
    private let plainTextFallbackThreshold: Int?
    private let selectedTextPiRouter: SelectedTextPiActionRouter?
    private let selectedTextSourceContext: SelectedTextSourceContext?

    private var latestSnapshot: ThinkingTraceStream.Snapshot
    private var renderedSnapshot: ThinkingTraceStream.Snapshot?
    private var streamObserverID: UUID?

    private lazy var tailFollowCoordinator = TailFollowScrollCoordinator(
        scrollView: scrollView,
        shouldAutoFollowTail: false,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    init(
        content: String,
        stream: ThinkingTraceStream?,
        palette: ThemePalette,
        plainTextFallbackThreshold: Int? = AssistantMarkdownContentView.Configuration.defaultPlainTextFallbackThreshold,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?
    ) {
        self.stream = stream
        self.plainTextFallbackThreshold = plainTextFallbackThreshold
        self.selectedTextPiRouter = selectedTextPiRouter
        self.selectedTextSourceContext = selectedTextSourceContext
        let initialSnapshot = stream?.snapshot
            ?? ThinkingTraceStream.Snapshot(text: content, isDone: true)
        latestSnapshot = initialSnapshot

        markdownWidthConstraint = markdownView.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -24
        )

        super.init(frame: .zero)
        tailFollowCoordinator.shouldAutoFollowTail = !initialSnapshot.isDone

        backgroundColor = UIColor(palette.bgDark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = UIColor(palette.bgDark)
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.delegate = self

        markdownView.translatesAutoresizingMaskIntoConstraints = false
        markdownView.backgroundColor = .clear

        addSubview(scrollView)
        scrollView.addSubview(markdownView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            markdownView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 12),
            markdownView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -12),
            markdownView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            markdownView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            markdownWidthConstraint,
        ])

        render(snapshot: initialSnapshot)

        streamObserverID = stream?.addObserver { [weak self] snapshot in
            self?.handleStreamUpdate(snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let streamObserverID {
            let stream = stream
            Task { @MainActor in
                stream?.removeObserver(streamObserverID)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tailFollowCoordinator.onLayoutPass()
    }

    private func handleStreamUpdate(_ snapshot: ThinkingTraceStream.Snapshot) {
        latestSnapshot = snapshot
        render(snapshot: snapshot)
    }

    private func render(snapshot: ThinkingTraceStream.Snapshot) {
        guard snapshot != renderedSnapshot else {
            tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
            return
        }

        renderedSnapshot = snapshot
        markdownView.apply(configuration: .init(
            content: snapshot.text,
            isStreaming: !snapshot.isDone,
            themeID: ThemeRuntimeState.currentThemeID(),
            plainTextFallbackThreshold: plainTextFallbackThreshold,
            selectedTextPiRouter: selectedTextPiRouter,
            selectedTextSourceContext: selectedTextSourceContext,
            perfSurface: .fullScreenThinking
        ))

        tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleWillBeginDragging()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleDidScroll(
            isUserDriven: scrollView.isDragging || scrollView.isDecelerating,
            isStreaming: !latestSnapshot.isDone
        )
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        tailFollowCoordinator.handleDidEndDragging(
            willDecelerate: decelerate,
            isStreaming: !latestSnapshot.isDone
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleDidEndDecelerating(isStreaming: !latestSnapshot.isDone)
    }
}

// MARK: - Source Body

final class NativeFullScreenSourceBody: UIView, UITextViewDelegate {
    private let textView = UITextView()
    private let selectedTextPiRouter: SelectedTextPiActionRouter?
    private let selectedTextSourceContext: SelectedTextSourceContext?
    private var isStreaming: Bool

    private lazy var tailFollowCoordinator = TailFollowScrollCoordinator(
        scrollView: textView,
        shouldAutoFollowTail: isStreaming,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    init(
        content: String,
        isStreaming: Bool,
        palette: ThemePalette,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?
    ) {
        self.selectedTextPiRouter = selectedTextPiRouter
        self.selectedTextSourceContext = selectedTextSourceContext
        self.isStreaming = isStreaming
        super.init(frame: .zero)

        backgroundColor = UIColor(palette.bgDark)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = FullScreenCodeTypography.codeFont
        textView.textColor = UIColor(palette.fg)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        textView.delegate = self
        textView.text = content
        addSubview(textView)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        tailFollowCoordinator.onLayoutPass()
    }

    func update(content: String, isStreaming: Bool) {
        let textDidChange = textView.text != content
        let streamingDidChange = self.isStreaming != isStreaming

        guard textDidChange || streamingDidChange else {
            tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
            return
        }

        self.isStreaming = isStreaming
        textView.text = content
        if !isStreaming {
            tailFollowCoordinator.shouldAutoFollowTail = false
        }
        tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleWillBeginDragging()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleDidScroll(
            isUserDriven: scrollView.isDragging || scrollView.isDecelerating,
            isStreaming: isStreaming
        )
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        tailFollowCoordinator.handleDidEndDragging(
            willDecelerate: decelerate,
            isStreaming: isStreaming
        )
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        tailFollowCoordinator.handleDidEndDecelerating(isStreaming: isStreaming)
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenSelectedTextMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selectedTextPiRouter,
            sourceContext: selectedTextSourceContext
        )
    }
}

// MARK: - Rendered Document Body (Org, LaTeX, Mermaid)

/// Fullscreen body for rendered document types. Hosts either a UITextView
/// (attributed string renderers like Org Mode) or a custom drawing view
/// (Core Graphics renderers like LaTeX, Mermaid) inside a scroll view.
final class NativeFullScreenRenderedDocumentBody: UIView {

    enum DocumentContent {
        case orgMode(String)
        case latex(String)
        case mermaid(String)
    }

    private let scrollView = UIScrollView()

    init(
        content: DocumentContent,
        palette: ThemePalette,
        selectedTextPiRouter: SelectedTextPiActionRouter?,
        selectedTextSourceContext: SelectedTextSourceContext?
    ) {
        super.init(frame: .zero)
        backgroundColor = UIColor(palette.bgDark)

        switch content {
        case .mermaid(let text):
            // ZoomableGraphicalView has its own scroll + zoom — embed directly
            let zoomable = makeZoomableGraphicalView(
                parser: MermaidParser(), renderer: MermaidFlowchartRenderer(),
                text: text, fontSize: 14
            )
            zoomable.translatesAutoresizingMaskIntoConstraints = false
            addSubview(zoomable)
            NSLayoutConstraint.activate([
                zoomable.leadingAnchor.constraint(equalTo: leadingAnchor),
                zoomable.trailingAnchor.constraint(equalTo: trailingAnchor),
                zoomable.topAnchor.constraint(equalTo: topAnchor),
                zoomable.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

        default:
            // Org/LaTeX use the outer scroll view
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.alwaysBounceVertical = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.backgroundColor = UIColor(palette.bgDark)
            addSubview(scrollView)

            let contentView: UIView
            switch content {
            case .orgMode(let text):
                contentView = makeOrgView(text: text)
            case .latex(let text):
                contentView = makeLatexView(text: text)
            case .mermaid:
                fatalError("Handled above")
            }

            contentView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(contentView)

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

                contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
                contentView.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
                contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
                contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func makeLatexView(text: String) -> UIView {
        let config = RenderConfiguration(fontSize: 20, maxWidth: 800, theme: .fallback, displayMode: .document)
        let multiLayout = DocumentRenderPipeline.layoutLatexExpressions(text: text, config: config)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = multiLayout.spacing
        stack.alignment = .leading

        for expr in multiLayout.expressions {
            let drawView = GraphicalRendererUIView()
            drawView.configure(size: expr.size, draw: expr.draw)
            drawView.translatesAutoresizingMaskIntoConstraints = false
            drawView.widthAnchor.constraint(equalToConstant: max(expr.size.width, 1)).isActive = true
            drawView.heightAnchor.constraint(equalToConstant: max(expr.size.height, 1)).isActive = true
            stack.addArrangedSubview(drawView)
        }

        return stack
    }

    private func makeOrgView(text: String) -> UIView {
        let markdownText = DocumentRenderPipeline.orgToMarkdown(text)

        let mdView = AssistantMarkdownContentView()
        mdView.backgroundColor = .clear
        mdView.apply(configuration: .init(
            content: markdownText,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: true,
            plainTextFallbackThreshold: nil
        ))
        return mdView
    }

    private func makeZoomableGraphicalView<P: DocumentParser, R: GraphicalDocumentRenderer>(
        parser: P, renderer: R, text: String, fontSize: CGFloat
    ) -> UIView where P.Document == R.Document {
        let config = RenderConfiguration(fontSize: fontSize, maxWidth: 800, theme: .fallback, displayMode: .document)
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: parser, renderer: renderer, text: text, config: config
        )
        return ZoomableGraphicalView(size: layout.size, draw: layout.draw)
    }
}
