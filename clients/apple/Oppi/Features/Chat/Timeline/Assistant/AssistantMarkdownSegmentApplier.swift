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

    /// Cached NSAttributedString for the streaming tail segment. Maintained
    /// incrementally (append-only) to avoid O(total) NSAttributedString conversion
    /// on every streaming tick.
    private var cachedStreamingTailNS: NSMutableAttributedString?

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
        cachedStreamingTailNS = nil

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
            cachedStreamingTailNS = nil
        }

        let signatures = segments.map(SegmentSignature.init)

        if signatures == renderedSegmentSignatures {
            updateInPlace(segments: segments, config: config)
        } else if config.isStreaming {
            // Streaming structural change: find the common prefix of segment
            // signatures and reuse existing views. Only rebuild the tail that
            // changed (e.g., a code block appeared at the end). This avoids
            // destroying and recreating expensive text views for the prefix.
            incrementalRebuild(
                segments: segments,
                signatures: signatures,
                config: config
            )
        } else {
            // Non-streaming structural change: full rebuild.
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
                textView.attributedText = NSAttributedString(attributed)
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

    /// Streaming-aware structural rebuild that reuses views for unchanged
    /// prefix segments. When segments go from [.text] to [.text, .codeBlock],
    /// the existing text view is kept and only the code block view is created.
    /// This avoids the cost of destroying and recreating expensive UITextViews.
    private func incrementalRebuild(
        segments: [FlatSegment],
        signatures: [SegmentSignature],
        config: AssistantMarkdownContentView.Configuration
    ) {
        let oldSigs = renderedSegmentSignatures
        let palette = config.themeID.palette

        // Find the common prefix length.
        var commonPrefix = 0
        let minLen = min(oldSigs.count, signatures.count)
        while commonPrefix < minLen && oldSigs[commonPrefix] == signatures[commonPrefix] {
            commonPrefix += 1
        }

        // If no common prefix, fall back to full rebuild.
        guard commonPrefix > 0 else {
            textRevealer.reset()
            lastStreamingTextCharCount = 0
            rebuild(segments: segments, signatures: signatures, config: config)
            return
        }

        // Prefix views are already configured from the previous apply cycle.
        // During streaming, prefix segments are frozen by the incremental
        // parser — their content doesn't change. Only the last text segment
        // (which is the growing tail) needs updating, and it's always at or
        // beyond the common prefix boundary. Skip prefix updates entirely
        // to avoid expensive textView.attributedText re-assignments.
        //
        // Note: this is safe because incrementalRebuild is only called during
        // streaming (non-streaming structural changes use full rebuild).

        // Remove extra views beyond the common prefix.
        while stackView.arrangedSubviews.count > commonPrefix {
            guard let view = stackView.arrangedSubviews.last else { break }
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Remove stale references for indices >= commonPrefix.
        for index in commonPrefix ..< max(oldSigs.count, signatures.count) {
            textViews.removeValue(forKey: index)
            codeBlockViews.removeValue(forKey: index)
            tableViews.removeValue(forKey: index)
            imageViews.removeValue(forKey: index)
            highlightTasks[index]?.cancel()
            highlightTasks.removeValue(forKey: index)
        }

        // Build and append new tail views.
        for index in commonPrefix ..< segments.count {
            switch segments[index] {
            case .text(let attributed):
                let textView = makeTextView(palette: palette)
                textView.isSelectable = config.textSelectionEnabled
                textView.attributedText = NSAttributedString(attributed)
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

        // Reset reveal state on structural change — new segments start fresh.
        textRevealer.reset()
        lastStreamingTextCharCount = 0
        cachedStreamingTailNS = nil

        // Track character count for the new last text segment.
        let lastTextIndex = segments.lastIndex(where: { if case .text = $0 { return true } else { return false } })
        if let lastIdx = lastTextIndex, let tv = textViews[lastIdx] {
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
            // During streaming, only the last text segment grows. All other
            // segments are frozen by the incremental parser. Skip them to
            // avoid expensive attributedText re-assignments and code block
            // reconfigurations.
            let isStreamingTail = config.isStreaming && index == lastTextIndex

            switch segment {
            case .text(let attributed):
                if let textView = textViews[index] {
                    if !config.isStreaming || isStreamingTail {
                        // Skip isSelectable during streaming when unchanged — UITextView
                        // does internal state work on assignment even if value is identical.
                        if !config.isStreaming || textView.isSelectable != config.textSelectionEnabled {
                            textView.isSelectable = config.textSelectionEnabled
                        }

                        if isStreamingTail {
                            // Disable data detectors during streaming to avoid O(n) text
                            // scanning on every textStorage change. Data detection runs
                            // against the ENTIRE text content on each modification, which
                            // is increasingly expensive as the response grows. Detectors
                            // are re-enabled when streaming ends (next non-streaming apply).
                            if textView.dataDetectorTypes != [] {
                                textView.dataDetectorTypes = []
                            }
                            // Streaming fast path: avoid full O(total) NSAttributedString
                            // conversion on every tick. Build the full conversion only on
                            // the first tick or when text shrinks; on subsequent ticks,
                            // convert only the delta and extend the cached version.
                            let oldLength = textView.textStorage.length

                            if let cached = cachedStreamingTailNS, cached.length == oldLength {
                                // Incremental path: convert only the delta
                                let fullNS = NSAttributedString(attributed)
                                let newLength = fullNS.length

                                if newLength > oldLength {
                                    // Verify the rendered plain text prefix is unchanged.
                                    // CommonMark re-parsing can change earlier character
                                    // positions when inline syntax closes (e.g. **bold**,
                                    // `code`, [link](url)). When this happens, the delta
                                    // from position oldLength in the new string doesn't
                                    // match what's in the textStorage, producing garbled
                                    // output. Fall back to full replacement in that case.
                                    let prefixValid = fullNS.string.hasPrefix(cached.string)

                                    if prefixValid {
                                        let delta = fullNS.attributedSubstring(
                                            from: NSRange(location: oldLength, length: newLength - oldLength)
                                        )
                                        textView.textStorage.beginEditing()
                                        textView.textStorage.append(delta)
                                        textView.textStorage.endEditing()
                                        cached.append(delta)
                                        refreshTextViewLayoutAfterContentChange(textView)

                                        let previousCount = lastStreamingTextCharCount
                                        lastStreamingTextCharCount = cached.length
                                        if cached.length > previousCount {
                                            textRevealer.reveal(
                                                in: textView,
                                                normalizedText: cached,
                                                previousVisibleCount: previousCount
                                            )
                                        }
                                    } else {
                                        // Markdown structure changed — full replacement.
                                        textView.attributedText = fullNS
                                        refreshTextViewLayoutAfterContentChange(textView)
                                        cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullNS)
                                        textRevealer.reset()
                                        lastStreamingTextCharCount = fullNS.length
                                    }
                                } else if newLength != oldLength {
                                    textView.attributedText = fullNS
                                    refreshTextViewLayoutAfterContentChange(textView)
                                    cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullNS)
                                    textRevealer.reset()
                                    lastStreamingTextCharCount = fullNS.length
                                }
                                // else: same length — no change, skip
                            } else {
                                // First tick or cache mismatch — full initialization
                                let fullNS = NSAttributedString(attributed)
                                textView.attributedText = fullNS
                                refreshTextViewLayoutAfterContentChange(textView)
                                cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullNS)
                                lastStreamingTextCharCount = fullNS.length
                            }
                        } else {
                            // Non-streaming: re-enable data detectors if they were disabled
                            // during streaming, then do full replacement.
                            if textView.dataDetectorTypes != [.link] {
                                textView.dataDetectorTypes = [.link]
                            }
                            let attrText = NSAttributedString(attributed)
                            textView.attributedText = attrText
                            refreshTextViewLayoutAfterContentChange(textView)
                        }
                    }
                }

            case .codeBlock(let language, let code):
                if let codeView = codeBlockViews[index] {
                    let isOpen = config.isStreaming
                        && index == segments.count - 1
                        && AssistantMarkdownSegmentSource.hasUnclosedCodeFence(config.content)
                    if !config.isStreaming || isOpen {
                        codeView.configureSelectedTextPi(
                            router: config.selectedTextPiRouter,
                            sourceContext: assistantCodeBlockSourceContext(language: language, config: config)
                        )
                        codeView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
                        if !isOpen && highlightTasks[index] == nil {
                            scheduleHighlight(index: index, language: language, code: code)
                        }
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
        textView.font = AppFont.messageBody
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

    private func refreshTextViewLayoutAfterContentChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        textView.setNeedsLayout()
        stackView.setNeedsLayout()
        stackView.superview?.setNeedsLayout()
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
        hr.backgroundColor = UIColor(palette.mdHr).withAlphaComponent(0.6)
        hr.translatesAutoresizingMaskIntoConstraints = false
        hr.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return hr
    }

    private func scheduleHighlight(index: Int, language: String?, code: String) {
        guard let langStr = language,
              SyntaxLanguage.detect(langStr) != .unknown else { return }

        let lang = SyntaxLanguage.detect(langStr)
        highlightTasks[index]?.cancel()
        highlightTasks[index] = Task { [weak self] in
            let wrapper = await Task.detached(priority: .userInitiated) {
                SendableNSAttributedString(SyntaxHighlighter.highlight(code, language: lang))
            }.value
            guard !Task.isCancelled else { return }
            self?.codeBlockViews[index]?.applyHighlightedCode(wrapper.value)
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
