import UIKit

@MainActor
final class AssistantMarkdownSegmentApplier {
    private let stackView: UIStackView
    private weak var textViewDelegate: (any UITextViewDelegate)?

    /// Segment types currently rendered — used for structural diff.
    private var renderedSegmentSignatures: [SegmentSignature] = []
    /// References to text views in the stack for in-place content updates.
    private var textViews: [Int: BaselineSafeTextView] = [:]
    /// References to code block views for in-place updates.
    private var codeBlockViews: [Int: NativeCodeBlockView] = [:]
    /// References to table views for in-place updates during streaming.
    private var tableViews: [Int: NativeTableBlockView] = [:]
    /// References to image views for in-place updates.
    private var imageViews: [Int: NativeMarkdownImageView] = [:]
    private var highlightTasks: [Int: Task<Void, Never>] = [:]

    /// Smooth character reveal for the actively streaming text segment.
    private let textRevealer = StreamingTextRevealer()
    /// Character count of the last text segment after the most recent reveal cycle.
    /// Used to compute the "new characters" delta on the next flush.
    private var lastStreamingTextCharCount: Int = 0

    /// Closure for fetching workspace files (for inline markdown images).
    /// Injected by the owning view chain, wrapping `APIClient` at the site
    /// where it's available so view-layer files stay decoupled from `APIClient`.
    var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?

    init(stackView: UIStackView, textViewDelegate: any UITextViewDelegate) {
        self.stackView = stackView
        self.textViewDelegate = textViewDelegate
    }

    func clear() {
        textRevealer.reset()
        lastStreamingTextCharCount = 0

        for task in highlightTasks.values {
            task.cancel()
        }
        highlightTasks.removeAll()

        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        textViews.removeAll()
        codeBlockViews.removeAll()
        tableViews.removeAll()
        imageViews.removeAll()
        renderedSegmentSignatures = []
    }

    func apply(
        segments: [FlatSegment],
        config: AssistantMarkdownContentView.Configuration
    ) {
        // When streaming stops, finish any in-progress reveal instantly.
        if !config.isStreaming {
            textRevealer.finishImmediately()
            lastStreamingTextCharCount = 0
        }

        let signatures = segments.map(SegmentSignature.init)

        if signatures == renderedSegmentSignatures {
            updateInPlace(segments: segments, config: config)
        } else {
            // Structural change resets reveal state.
            textRevealer.reset()
            lastStreamingTextCharCount = 0
            rebuild(segments: segments, signatures: signatures, config: config)
        }
    }

    private func rebuild(
        segments: [FlatSegment],
        signatures: [SegmentSignature],
        config: AssistantMarkdownContentView.Configuration
    ) {
        clear()

        let palette = config.themeID.palette
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let attributed):
                let textView = makeTextView(palette: palette)
                textView.isSelectable = config.textSelectionEnabled
                textView.attributedText = Self.normalizedAttributedText(
                    from: attributed,
                    palette: palette
                )
                stackView.addArrangedSubview(textView)
                textViews[index] = textView

            case .codeBlock(let language, let code):
                let codeView = NativeCodeBlockView()
                let isOpen = config.isStreaming
                    && index == segments.count - 1
                    && AssistantMarkdownSegmentSource.hasUnclosedCodeFence(config.content)
                codeView.configureSelectedTextPi(
                    router: config.selectedTextPiRouter,
                    sourceContext: assistantCodeBlockSourceContext(language: language, config: config)
                )
                codeView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
                stackView.addArrangedSubview(codeView)
                codeBlockViews[index] = codeView
                if !isOpen {
                    scheduleHighlight(index: index, language: language, code: code)
                }

            case .table(let headers, let rows):
                let tableView = NativeTableBlockView()
                tableView.configureSelectedTextPi(
                    router: config.selectedTextPiRouter,
                    sourceContext: assistantTableSourceContext(config: config)
                )
                tableView.apply(headers: headers, rows: rows, palette: palette)
                stackView.addArrangedSubview(tableView)
                tableViews[index] = tableView

            case .thematicBreak:
                stackView.addArrangedSubview(makeThematicBreak(palette: palette))

            case .image(let alt, let url):
                let imageView = NativeMarkdownImageView()
                imageView.apply(url: url, alt: alt, fetchWorkspaceFile: fetchWorkspaceFile)
                stackView.addArrangedSubview(imageView)
                imageViews[index] = imageView
            }
        }

        renderedSegmentSignatures = signatures

        // Track initial character count for the streaming text revealer.
        if config.isStreaming, let lastIdx = segments.lastIndex(where: {
            if case .text = $0 { return true } else { return false }
        }), let tv = textViews[lastIdx] {
            lastStreamingTextCharCount = tv.attributedText?.length ?? 0
        }
    }

    private func updateInPlace(
        segments: [FlatSegment],
        config: AssistantMarkdownContentView.Configuration
    ) {
        let palette = config.themeID.palette
        let lastTextIndex = segments.lastIndex(where: { if case .text = $0 { return true } else { return false } })

        for (index, segment) in segments.enumerated() {
            switch segment {
            case .text(let attributed):
                if let textView = textViews[index] {
                    textView.isSelectable = config.textSelectionEnabled
                    let normalized = Self.normalizedAttributedText(
                        from: attributed,
                        palette: palette
                    )
                    textView.attributedText = normalized

                    // Smooth reveal for the last (actively growing) text segment during streaming.
                    if config.isStreaming, index == lastTextIndex {
                        let previousCount = lastStreamingTextCharCount
                        let currentCount = normalized.length
                        if currentCount > previousCount {
                            textRevealer.reveal(
                                in: textView,
                                normalizedText: normalized,
                                previousVisibleCount: previousCount
                            )
                        }
                        lastStreamingTextCharCount = currentCount
                    }
                }

            case .codeBlock(let language, let code):
                if let codeView = codeBlockViews[index] {
                    let isOpen = config.isStreaming
                        && index == segments.count - 1
                        && AssistantMarkdownSegmentSource.hasUnclosedCodeFence(config.content)
                    codeView.configureSelectedTextPi(
                        router: config.selectedTextPiRouter,
                        sourceContext: assistantCodeBlockSourceContext(language: language, config: config)
                    )
                    codeView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
                    if !isOpen && highlightTasks[index] == nil {
                        scheduleHighlight(index: index, language: language, code: code)
                    }
                }

            case .table(let headers, let rows):
                if let tableView = tableViews[index] {
                    tableView.configureSelectedTextPi(
                        router: config.selectedTextPiRouter,
                        sourceContext: assistantTableSourceContext(config: config)
                    )
                    tableView.apply(headers: headers, rows: rows, palette: palette)
                }

            case .thematicBreak:
                break

            case .image(let alt, let url):
                // Image views manage their own load lifecycle — nothing to diff in-place.
                if let imageView = imageViews[index] {
                    imageView.apply(url: url, alt: alt, fetchWorkspaceFile: fetchWorkspaceFile)
                }
            }
        }
    }

    private func makeTextView(palette: ThemePalette) -> BaselineSafeTextView {
        let textView = BaselineSafeTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.alwaysBounceVertical = false
        textView.alwaysBounceHorizontal = false
        textView.bounces = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.dataDetectorTypes = [.link]
        textView.textColor = UIColor(palette.fg)
        textView.font = .preferredFont(forTextStyle: .body)
        textView.tintColor = UIColor(palette.blue)
        textView.linkTextAttributes = [
            .foregroundColor: UIColor(palette.blue),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = textViewDelegate
        return textView
    }

    private func assistantCodeBlockSourceContext(
        language: String?,
        config: AssistantMarkdownContentView.Configuration
    ) -> SelectedTextSourceContext? {
        guard let base = config.selectedTextSourceContext else { return nil }
        return SelectedTextSourceContext(
            sessionId: base.sessionId,
            surface: .assistantCodeBlock,
            sourceLabel: base.sourceLabel,
            filePath: base.filePath,
            lineRange: base.lineRange,
            languageHint: language
        )
    }

    private func assistantTableSourceContext(
        config: AssistantMarkdownContentView.Configuration
    ) -> SelectedTextSourceContext? {
        guard let base = config.selectedTextSourceContext else { return nil }
        return SelectedTextSourceContext(
            sessionId: base.sessionId,
            surface: .assistantTable,
            sourceLabel: base.sourceLabel,
            filePath: base.filePath,
            lineRange: base.lineRange,
            languageHint: base.languageHint
        )
    }

    private func makeThematicBreak(palette: ThemePalette) -> UIView {
        let hr = UIView()
        hr.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.4)
        hr.translatesAutoresizingMaskIntoConstraints = false
        hr.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return hr
    }

    private static func normalizedAttributedText(
        from attributed: AttributedString,
        palette: ThemePalette
    ) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
        let fullRange = NSRange(location: 0, length: mutable.length)
        guard fullRange.length > 0 else { return mutable }

        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        let baseColor = UIColor(palette.fg)
        let baseLuminance = perceivedLuminance(of: baseColor)
        let shouldCorrectDarkText = baseLuminance > 0.55

        mutable.enumerateAttributes(in: fullRange) { attributes, range, _ in
            var updates: [NSAttributedString.Key: Any] = [:]

            if attributes[.font] == nil {
                updates[.font] = baseFont
            }

            if let color = attributes[.foregroundColor] as? UIColor {
                if shouldCorrectDarkText && perceivedLuminance(of: color) < 0.2 {
                    updates[.foregroundColor] = baseColor
                }
            } else {
                updates[.foregroundColor] = baseColor
            }

            if !updates.isEmpty {
                mutable.addAttributes(updates, range: range)
            }
        }

        return mutable
    }

    private static func perceivedLuminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
            var white: CGFloat = 0
            guard color.getWhite(&white, alpha: &a) else { return 0 }
            return white
        }
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func scheduleHighlight(index: Int, language: String?, code: String) {
        guard let langStr = language,
              SyntaxLanguage.detect(langStr) != .unknown else { return }

        let lang = SyntaxLanguage.detect(langStr)
        highlightTasks[index]?.cancel()
        highlightTasks[index] = Task { [weak self] in
            let sendable = await Task.detached(priority: .userInitiated) {
                AttributedString(SyntaxHighlighter.highlight(code, language: lang))
            }.value
            guard !Task.isCancelled else { return }
            self?.codeBlockViews[index]?.applyHighlightedCode(NSAttributedString(sendable))
        }
    }
}

private enum SegmentSignature: Equatable {
    case text
    case codeBlock
    case table
    case thematicBreak
    case image(url: URL)

    init(_ segment: FlatSegment) {
        switch segment {
        case .text:
            self = .text
        case .codeBlock:
            self = .codeBlock
        case .table:
            self = .table
        case .thematicBreak:
            self = .thematicBreak
        case .image(_, let url):
            self = .image(url: url)
        }
    }
}
