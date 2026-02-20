import UIKit

/// Pure-UIKit full-screen content viewer for tool output.
///
/// Replaces the SwiftUI ``FullScreenCodeView`` in the chat timeline path.
/// Supports code (with syntax highlighting), diff, and markdown modes.
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
        let doneButton = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(doneTapped))
        doneButton.tintColor = UIColor(palette.cyan)
        vc.navigationItem.leftBarButtonItem = doneButton

        vc.navigationItem.titleView = makeTitleView(palette: palette)

        var rightItems: [UIBarButtonItem] = []
        let copy = UIBarButtonItem(image: UIImage(systemName: "doc.on.doc"), style: .plain, target: self, action: #selector(copyTapped))
        copy.tintColor = UIColor(palette.fgDim)
        copyButton = copy
        rightItems.append(copy)

        if case .markdown = content {
            let toggle = UIBarButtonItem(title: "Source", style: .plain, target: self, action: #selector(toggleSource))
            toggle.tintColor = UIColor(palette.blue)
            sourceToggleButton = toggle
            rightItems.append(toggle)
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
            typeLabel.text = "Diff"
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
            typeLabel.text = "Markdown"
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
        sourceToggleButton?.title = showSource ? "Reader" : "Source"

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
        gutterLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
        codeTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
                self?.codeTextView.attributedText = NSAttributedString(highlighted)
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
        oldNumLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        oldNumLabel.text = oldLineNumber.map(String.init) ?? ""
        oldNumLabel.textAlignment = .right
        oldNumLabel.textColor = UIColor(palette.comment)

        let newNumLabel = UILabel()
        newNumLabel.translatesAutoresizingMaskIntoConstraints = false
        newNumLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        newNumLabel.text = newLineNumber.map(String.init) ?? ""
        newNumLabel.textAlignment = .right
        newNumLabel.textColor = UIColor(palette.comment)

        let codeLabel = UILabel()
        codeLabel.translatesAutoresizingMaskIntoConstraints = false
        codeLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        codeLabel.numberOfLines = 1
        codeLabel.lineBreakMode = .byClipping

        if language != .unknown, line.kind == .context {
            codeLabel.attributedText = NSAttributedString(SyntaxHighlighter.highlightLine(line.text, language: language))
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
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
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
