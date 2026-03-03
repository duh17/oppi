import SwiftUI
import UIKit

/// Full-screen content viewer for tool output (UIKit).
///
/// Supports code (with syntax highlighting), diff, and markdown modes.
/// Presented via ``FullScreenCodeView`` (UIViewControllerRepresentable wrapper)
/// from SwiftUI callers, and directly from UIKit timeline cells.
private enum FullScreenCodeTypography {
    static let codeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
}

final class FullScreenCodeViewController: UIViewController {
    private let content: FullScreenCodeContent
    private var showSource = false
    private var copied = false
    private var copyButton: UIBarButtonItem?
    private var sourceToggleButton: UIBarButtonItem?

    init(content: FullScreenCodeContent) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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

        // Toolbar setup
        let doneButton = UIBarButtonItem(
            image: UIImage(systemName: "chevron.down"),
            style: .plain,
            target: self,
            action: #selector(doneTapped)
        )
        doneButton.tintColor = UIColor(palette.cyan)
        vc.navigationItem.leftBarButtonItem = doneButton

        vc.navigationItem.titleView = makeTitleView(palette: palette)

        var rightItems: [UIBarButtonItem] = []
        let copy = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(copyTapped))
        copy.tintColor = UIColor(palette.fgDim)
        copyButton = copy
        rightItems.append(copy)

        switch content {
        case .markdown:
            let toggle = UIBarButtonItem(title: String(localized: "Source"), style: .plain, target: self, action: #selector(toggleSource))
            toggle.tintColor = UIColor(palette.blue)
            sourceToggleButton = toggle
            rightItems.append(toggle)
        default:
            break
        }
        vc.navigationItem.rightBarButtonItems = rightItems

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(palette.bgHighlight)
        appearance.titleTextAttributes = [.foregroundColor: UIColor(palette.fg)]
        vc.navigationItem.standardAppearance = appearance
        vc.navigationItem.scrollEdgeAppearance = appearance

        // Content
        let contentView = makeBodyView(palette: palette)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])

        return vc
    }

    // MARK: - Title

    private func makeTitleView(palette: ThemePalette) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 1

        switch content {
        case .code(_, let language, let filePath, _):
            if let path = filePath {
                let pathLabel = UILabel()
                pathLabel.text = path.shortenedPath
                pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                pathLabel.textColor = UIColor(palette.fg)
                pathLabel.lineBreakMode = .byTruncatingMiddle
                stack.addArrangedSubview(pathLabel)
            }
            let langLabel = UILabel()
            langLabel.text = language ?? "code"
            langLabel.font = .systemFont(ofSize: 11)
            langLabel.textColor = UIColor(palette.comment)
            stack.addArrangedSubview(langLabel)

        case .diff(_, _, let filePath, _):
            if let path = filePath {
                let pathLabel = UILabel()
                pathLabel.text = path.shortenedPath
                pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                pathLabel.textColor = UIColor(palette.fg)
                pathLabel.lineBreakMode = .byTruncatingMiddle
                stack.addArrangedSubview(pathLabel)
            }
            let typeLabel = UILabel()
            typeLabel.text = String(localized: "Diff")
            typeLabel.font = .systemFont(ofSize: 11)
            typeLabel.textColor = UIColor(palette.comment)
            stack.addArrangedSubview(typeLabel)

        case .markdown(_, let filePath):
            if let path = filePath {
                let pathLabel = UILabel()
                pathLabel.text = path.shortenedPath
                pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
                pathLabel.textColor = UIColor(palette.fg)
                pathLabel.lineBreakMode = .byTruncatingMiddle
                stack.addArrangedSubview(pathLabel)
            }
            let typeLabel = UILabel()
            typeLabel.text = String(localized: "Markdown")
            typeLabel.font = .systemFont(ofSize: 11)
            typeLabel.textColor = UIColor(palette.comment)
            stack.addArrangedSubview(typeLabel)

        case .thinking:
            let typeLabel = UILabel()
            typeLabel.text = String(localized: "Thinking")
            typeLabel.font = .systemFont(ofSize: 11)
            typeLabel.textColor = UIColor(palette.comment)
            stack.addArrangedSubview(typeLabel)

        case .terminal(_, let command, _):
            let typeLabel = UILabel()
            typeLabel.text = command == nil ? String(localized: "Terminal") : String(localized: "Terminal output")
            typeLabel.font = .systemFont(ofSize: 11)
            typeLabel.textColor = UIColor(palette.comment)
            stack.addArrangedSubview(typeLabel)
        }

        return stack
    }

    // MARK: - Body

    private func makeBodyView(palette: ThemePalette) -> UIView {
        switch content {
        case .code(let text, let language, _, let startLine):
            return NativeFullScreenCodeBody(content: text, language: language, startLine: startLine, palette: palette)
        case .diff(let oldText, let newText, let filePath, let precomputedLines):
            return NativeFullScreenDiffBody(oldText: oldText, newText: newText, filePath: filePath, precomputedLines: precomputedLines, palette: palette)
        case .markdown(let text, _):
            return NativeFullScreenMarkdownBody(content: text, palette: palette)
        case .thinking(let text, let stream):
            return NativeFullScreenThinkingBody(initialContent: text, stream: stream, palette: palette)
        case .terminal(let text, let command, let stream):
            return NativeFullScreenTerminalBody(content: text, command: command, stream: stream, palette: palette)
        }
    }

    // MARK: - Actions

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    @objc private func copyTapped() {
        let text: String
        switch content {
        case .code(let t, _, _, _): text = t
        case .diff(_, let newText, _, _): text = newText
        case .markdown(let t, _): text = t
        case .thinking(let t, let stream): text = stream?.snapshot.text ?? t
        case .terminal(let t, _, let stream): text = stream?.snapshot.output ?? t
        }
        UIPasteboard.general.string = text
        copyButton?.image = UIImage(systemName: "checkmark")
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyButton?.image = UIImage(systemName: "doc.on.doc")
            self?.copied = false
        }
    }

    @objc private func toggleSource() {
        guard case .markdown(let text, _) = content,
              let nav = children.first as? UINavigationController,
              let vc = nav.viewControllers.first else { return }

        showSource.toggle()
        let palette = ThemeRuntimeState.currentThemeID().palette
        sourceToggleButton?.title = showSource ? String(localized: "Reader") : String(localized: "Source")

        // Remove old content
        vc.view.subviews.filter { $0 is NativeFullScreenMarkdownBody || $0 is NativeFullScreenSourceBody }.forEach { $0.removeFromSuperview() }

        let body: UIView
        if showSource {
            body = NativeFullScreenSourceBody(content: text, palette: palette)
        } else {
            body = NativeFullScreenMarkdownBody(content: text, palette: palette)
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            body.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
    }
}

private func fullScreenAttributedCodeText(from attributed: NSAttributedString) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: attributed)
    let fullRange = NSRange(location: 0, length: mutable.length)
    mutable.addAttribute(.font, value: FullScreenCodeTypography.codeFont, range: fullRange)
    return mutable
}

// MARK: - Code Body

private final class NativeFullScreenCodeBody: UIView {
    private let scrollView = UIScrollView()
    private let gutterLabel = UILabel()
    private let separatorView = UIView()
    private let codeTextView = UITextView()
    private let content: String
    private let language: String?
    private let startLine: Int
    private let palette: ThemePalette
    private var highlightTask: Task<Void, Never>?

    init(content: String, language: String?, startLine: Int, palette: ThemePalette) {
        self.content = content
        self.language = language
        self.startLine = startLine
        self.palette = palette
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
        scrollView.alwaysBounceVertical = true
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
        codeTextView.isScrollEnabled = false
        codeTextView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        codeTextView.textContainer.lineFragmentPadding = 0
        codeTextView.textContainer.lineBreakMode = .byClipping
        codeTextView.textContainer.widthTracksTextView = false
        codeTextView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        codeTextView.text = content
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
            let highlighted = await Task.detached(priority: .userInitiated) {
                SyntaxHighlighter.highlight(text, language: syntaxLang)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.codeTextView.attributedText = fullScreenAttributedCodeText(
                    from: NSAttributedString(highlighted)
                )
            }
        }
    }
}

// MARK: - Diff Body

private final class NativeFullScreenDiffBody: UIView {
    private let statsBar = UIView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    init(oldText: String, newText: String, filePath: String?, precomputedLines: [DiffLine]?, palette: ThemePalette) {
        super.init(frame: .zero)
        backgroundColor = UIColor(palette.bgDark)

        let lines = precomputedLines ?? DiffEngine.compute(old: oldText, new: newText)
        let stats = DiffEngine.stats(lines)
        let language: SyntaxLanguage
        if let path = filePath {
            let ext = (path as NSString).pathExtension
            language = ext.isEmpty ? .unknown : SyntaxLanguage.detect(ext)
        } else {
            language = .unknown
        }

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

        // Scroll view with diff rows
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.backgroundColor = UIColor(palette.bgDark)

        contentStack.axis = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

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

            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
        ])

        buildDiffRows(lines: lines, language: language, palette: palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func buildDiffRows(lines: [DiffLine], language: SyntaxLanguage, palette: ThemePalette) {
        var oldNumber = 1
        var newNumber = 1

        let themeID = ThemeRuntimeState.currentThemeID()

        for line in lines {
            let oldNum: Int?
            let newNum: Int?

            switch line.kind {
            case .context:
                oldNum = oldNumber; newNum = newNumber
                oldNumber += 1; newNumber += 1
            case .removed:
                oldNum = oldNumber; newNum = nil
                oldNumber += 1
            case .added:
                oldNum = nil; newNum = newNumber
                newNumber += 1
            }

            let row = DiffRowView(
                line: line,
                oldLineNumber: oldNum,
                newLineNumber: newNum,
                language: language,
                palette: palette,
                themeID: themeID
            )
            row.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(row)
        }
    }
}

private final class DiffRowView: UIView {
    init(line: DiffLine, oldLineNumber: Int?, newLineNumber: Int?, language: SyntaxLanguage, palette: ThemePalette, themeID: ThemeID) {
        super.init(frame: .zero)

        let accentBar = UIView()
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        let accentColor: UIColor
        let textColor: UIColor
        let bgColor: UIColor

        switch line.kind {
        case .added:
            accentColor = UIColor(palette.toolDiffAdded)
            textColor = UIColor(palette.fg)
            bgColor = UIColor(palette.toolDiffAdded.opacity(0.15))
        case .removed:
            accentColor = UIColor(palette.toolDiffRemoved)
            textColor = UIColor(palette.fg)
            bgColor = UIColor(palette.toolDiffRemoved.opacity(0.15))
        case .context:
            accentColor = .clear
            textColor = UIColor(palette.toolDiffContext)
            bgColor = .clear
        }

        accentBar.backgroundColor = accentColor
        backgroundColor = bgColor

        let prefixLabel = UILabel()
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        prefixLabel.text = line.kind.prefix
        prefixLabel.textAlignment = .center
        prefixLabel.textColor = accentColor == .clear ? UIColor(palette.comment) : accentColor

        let oldNumLabel = UILabel()
        oldNumLabel.translatesAutoresizingMaskIntoConstraints = false
        oldNumLabel.font = FullScreenCodeTypography.codeFont
        oldNumLabel.text = oldLineNumber.map(String.init) ?? ""
        oldNumLabel.textAlignment = .right
        oldNumLabel.textColor = UIColor(palette.comment)

        let newNumLabel = UILabel()
        newNumLabel.translatesAutoresizingMaskIntoConstraints = false
        newNumLabel.font = FullScreenCodeTypography.codeFont
        newNumLabel.text = newLineNumber.map(String.init) ?? ""
        newNumLabel.textAlignment = .right
        newNumLabel.textColor = UIColor(palette.comment)

        let codeLabel = UILabel()
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.font = FullScreenCodeTypography.codeFont
        codeLabel.numberOfLines = 1
        codeLabel.lineBreakMode = .byClipping

        if language != .unknown, line.kind == .context {
            codeLabel.attributedText = fullScreenAttributedCodeText(
                from: NSAttributedString(SyntaxHighlighter.highlightLine(line.text, language: language))
            )
        } else {
            codeLabel.text = line.text
            codeLabel.textColor = textColor
        }

        addSubview(accentBar)
        addSubview(prefixLabel)
        addSubview(oldNumLabel)
        addSubview(newNumLabel)
        addSubview(codeLabel)

        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),

            prefixLabel.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor),
            prefixLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            prefixLabel.widthAnchor.constraint(equalToConstant: 18),

            oldNumLabel.leadingAnchor.constraint(equalTo: prefixLabel.trailingAnchor),
            oldNumLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            oldNumLabel.widthAnchor.constraint(equalToConstant: 44),

            newNumLabel.leadingAnchor.constraint(equalTo: oldNumLabel.trailingAnchor),
            newNumLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            newNumLabel.widthAnchor.constraint(equalToConstant: 44),

            codeLabel.leadingAnchor.constraint(equalTo: newNumLabel.trailingAnchor, constant: 8),
            codeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            codeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class TailFollowScrollCoordinator {
    private let scrollView: UIScrollView
    private let nearBottomThreshold: CGFloat
    private let performLayout: () -> Void

    private(set) var isApplyingProgrammaticScroll = false
    var shouldAutoFollowTail: Bool
    private var pendingAutoFollowScroll = false

    init(
        scrollView: UIScrollView,
        shouldAutoFollowTail: Bool,
        nearBottomThreshold: CGFloat = 28,
        performLayout: @escaping () -> Void
    ) {
        self.scrollView = scrollView
        self.shouldAutoFollowTail = shouldAutoFollowTail
        self.nearBottomThreshold = nearBottomThreshold
        self.performLayout = performLayout
    }

    func onLayoutPass() {
        scheduleAutoFollowToBottomIfNeeded()
    }

    func scheduleAutoFollowToBottomIfNeeded() {
        guard shouldAutoFollowTail else { return }
        guard !pendingAutoFollowScroll else { return }
        pendingAutoFollowScroll = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingAutoFollowScroll = false
            self.scrollToBottomIfNeeded()
        }
    }

    func handleWillBeginDragging() {
        if !isNearBottom() {
            shouldAutoFollowTail = false
        }
    }

    func handleDidScroll(isUserDriven: Bool, isStreaming: Bool) {
        guard !isApplyingProgrammaticScroll else { return }
        guard isUserDriven else { return }

        if isNearBottom() {
            shouldAutoFollowTail = isStreaming
        } else {
            shouldAutoFollowTail = false
        }
    }

    func handleDidEndDragging(willDecelerate: Bool, isStreaming: Bool) {
        guard !willDecelerate else { return }
        if isNearBottom() {
            shouldAutoFollowTail = isStreaming
        }
    }

    func handleDidEndDecelerating(isStreaming: Bool) {
        if isNearBottom() {
            shouldAutoFollowTail = isStreaming
        }
    }

    private func scrollToBottomIfNeeded() {
        guard scrollView.bounds.height > 0 else { return }

        performLayout()

        let targetY = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        guard targetY.isFinite else { return }
        guard abs(scrollView.contentOffset.y - targetY) > 0.5 else { return }

        isApplyingProgrammaticScroll = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        CATransaction.commit()
        isApplyingProgrammaticScroll = false
    }

    private func isNearBottom() -> Bool {
        distanceFromBottom() <= nearBottomThreshold
    }

    private func distanceFromBottom() -> CGFloat {
        let viewportHeight = scrollView.bounds.height
            - scrollView.adjustedContentInset.top
            - scrollView.adjustedContentInset.bottom
        guard viewportHeight > 0 else { return .greatestFiniteMagnitude }

        let visibleBottom = scrollView.contentOffset.y
            + scrollView.adjustedContentInset.top
            + viewportHeight

        return scrollView.contentSize.height - visibleBottom
    }
}

// MARK: - Terminal Body

private final class NativeFullScreenTerminalBody: UIView, UIScrollViewDelegate {
    private static let maxSynchronousANSIBytes = 64 * 1024

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let commandView = UITextView()
    private let outputView = UITextView()
    private let palette: ThemePalette
    private let stream: TerminalTraceStream?

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

    init(content: String, command: String?, stream: TerminalTraceStream?, palette: ThemePalette) {
        self.palette = palette
        self.stream = stream

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
        commandView.isScrollEnabled = false
        commandView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        commandView.textContainer.lineFragmentPadding = 0
        commandView.backgroundColor = UIColor(palette.bgHighlight)
        commandView.layer.cornerRadius = 8

        outputView.translatesAutoresizingMaskIntoConstraints = false
        outputView.isEditable = false
        outputView.isScrollEnabled = false
        outputView.backgroundColor = .clear
        outputView.textContainerInset = UIEdgeInsets(top: 4, left: 6, bottom: 14, right: 6)
        outputView.textContainer.lineFragmentPadding = 0
        outputView.font = FullScreenCodeTypography.codeFont
        outputView.textColor = UIColor(palette.fg)

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
            commandView.attributedText = ToolRowTextRenderer.shellHighlighted(command)
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
            outputView.attributedText = NSAttributedString(
                ANSIParser.attributedString(from: content, baseForeground: .themeFg)
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
            let attributed = await Task.detached(priority: .userInitiated) {
                ANSIParser.attributedString(from: source, baseForeground: .themeFg)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.outputView.attributedText = NSAttributedString(attributed)
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

private final class NativeFullScreenThinkingBody: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let markdownView = AssistantMarkdownContentView()
    private let markdownWidthConstraint: NSLayoutConstraint

    private var latestSnapshot: ThinkingTraceStream.Snapshot
    private var renderedSnapshot: ThinkingTraceStream.Snapshot?

    private lazy var tailFollowCoordinator = TailFollowScrollCoordinator(
        scrollView: scrollView,
        shouldAutoFollowTail: false,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    init(initialContent: String, stream: ThinkingTraceStream?, palette: ThemePalette) {
        let initialSnapshot = stream?.snapshot
            ?? ThinkingTraceStream.Snapshot(text: initialContent, isDone: true)
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

        stream?.addObserver { [weak self] snapshot in
            self?.handleStreamUpdate(snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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
            themeID: ThemeRuntimeState.currentThemeID()
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

// MARK: - Markdown Body

private final class NativeFullScreenMarkdownBody: UIView {
    private let scrollView = UIScrollView()
    private let markdownView = AssistantMarkdownContentView()
    private let markdownWidthConstraint: NSLayoutConstraint

    init(content: String, palette: ThemePalette) {
        markdownWidthConstraint = markdownView.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -24
        )

        super.init(frame: .zero)

        backgroundColor = UIColor(palette.bgDark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = UIColor(palette.bgDark)
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true

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

        markdownView.apply(configuration: .init(
            content: content,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID()
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

// MARK: - Source Body

private final class NativeFullScreenSourceBody: UIView {
    init(content: String, palette: ThemePalette) {
        super.init(frame: .zero)

        backgroundColor = UIColor(palette.bgDark)

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = FullScreenCodeTypography.codeFont
        textView.textColor = UIColor(palette.fg)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
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
}
