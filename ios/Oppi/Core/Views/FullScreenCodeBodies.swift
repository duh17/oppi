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

    init(
        htmlString: String,
        palette: ThemePalette,
        selectedTextPiRouter: SelectedTextPiActionRouter? = nil,
        selectedTextSourceContext: SelectedTextSourceContext? = nil
    ) {
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
}

// MARK: - Code Body

final class NativeFullScreenCodeBody: UIView {
    private let scrollView = UIScrollView()
    private let gutterLabel = UILabel()
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

        // Gutter
        gutterLabel.translatesAutoresizingMaskIntoConstraints = false
        gutterLabel.font = FullScreenCodeTypography.codeFont
        gutterLabel.textColor = UIColor(palette.comment)
        gutterLabel.textAlignment = .right
        gutterLabel.numberOfLines = 0
        contentContainer.addSubview(gutterLabel)

        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        let (numbers, gutterWidth) = lineNumberInfo(lineCount: lineCount, startLine: startLine)
        gutterLabel.text = numbers

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

            gutterLabel.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 6),
            gutterLabel.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 8),
            gutterLabel.widthAnchor.constraint(equalToConstant: gutterWidth),

            separatorView.leadingAnchor.constraint(equalTo: gutterLabel.trailingAnchor, constant: 6),
            separatorView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: 1),

            codeTextView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor),
            codeTextView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            codeTextView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            codeTextView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),

            // Ensure gutter matches code height
            gutterLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor, constant: -8),
            codeTextView.bottomAnchor.constraint(greaterThanOrEqualTo: gutterLabel.bottomAnchor, constant: 8),
        ])
    }

    private func loadHighlighting() {
        guard let lang = language, !lang.isEmpty else { return }
        let syntaxLang = SyntaxLanguage.detect(lang)
        guard syntaxLang != .unknown else { return }

        let text = content
        highlightTask = Task { [weak self] in
            // AttributedString is Sendable; NSAttributedString is not.
            // Convert at the boundary — still O(n), much cheaper than the old O(n^2) build.
            let sendable = await Task.detached(priority: .userInitiated) {
                let highlighted = SyntaxHighlighter.highlight(text, language: syntaxLang)
                // SyntaxHighlighter caps highlighting at maxLines for performance.
                // Append the unhighlighted remainder so full-screen shows all content.
                let highlightedStr = highlighted.string
                guard highlightedStr.count < text.count else {
                    return AttributedString(highlighted)
                }
                let mutable = NSMutableAttributedString(attributedString: highlighted)
                let splitIndex = text.index(text.startIndex, offsetBy: highlightedStr.count)
                let remainder = String(text[splitIndex...])
                let baseAttrs: [NSAttributedString.Key: Any] = highlighted.length > 0
                    ? highlighted.attributes(at: 0, effectiveRange: nil)
                    : [:]
                mutable.append(NSAttributedString(string: remainder, attributes: baseAttrs))
                return AttributedString(mutable)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.codeTextView.attributedText = fullScreenAttributedCodeText(
                    from: NSAttributedString(sendable)
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
    private let statsBar = UIView()
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
        let stats = DiffEngine.stats(lines)

        // Stats bar
        let statsStack = UIStackView()
        statsStack.axis = .horizontal
        statsStack.spacing = 12
        statsStack.translatesAutoresizingMaskIntoConstraints = false

        if stats.added > 0 {
            let addedLabel = UILabel()
            addedLabel.text = "+\(stats.added)"
            addedLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
            addedLabel.textColor = UIColor(palette.green)
            statsStack.addArrangedSubview(addedLabel)
        }
        if stats.removed > 0 {
            let removedLabel = UILabel()
            removedLabel.text = "-\(stats.removed)"
            removedLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
            removedLabel.textColor = UIColor(palette.red)
            statsStack.addArrangedSubview(removedLabel)
        }
        let countLabel = UILabel()
        countLabel.text = "\(lines.count) lines"
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = UIColor(palette.comment)
        statsStack.addArrangedSubview(countLabel)
        statsStack.addArrangedSubview(UIView()) // spacer

        statsBar.translatesAutoresizingMaskIntoConstraints = false
        statsBar.backgroundColor = UIColor(palette.bgHighlight)
        statsBar.addSubview(statsStack)

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
        let diffText = DiffAttributedStringBuilder.build(hunks: hunks, filePath: filePath ?? "diff.txt")
        diffTextView.attributedText = diffText

        let measured = diffText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let widthConstraint = diffTextView.widthAnchor.constraint(equalToConstant: ceil(measured.width) + 24)

        scrollView.addSubview(diffTextView)
        addSubview(statsBar)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            statsBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statsBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statsBar.topAnchor.constraint(equalTo: topAnchor),

            statsStack.leadingAnchor.constraint(equalTo: statsBar.leadingAnchor, constant: 12),
            statsStack.trailingAnchor.constraint(equalTo: statsBar.trailingAnchor, constant: -12),
            statsStack.topAnchor.constraint(equalTo: statsBar.topAnchor, constant: 6),
            statsStack.bottomAnchor.constraint(equalTo: statsBar.bottomAnchor, constant: -6),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: statsBar.bottomAnchor),
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
            // AttributedString is Sendable; NSAttributedString is not.
            let sendable = await Task.detached(priority: .userInitiated) {
                AttributedString(ANSIParser.attributedString(from: source, baseForeground: .themeFg))
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.outputView.attributedText = NSAttributedString(sendable)
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
            selectedTextSourceContext: selectedTextSourceContext
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
