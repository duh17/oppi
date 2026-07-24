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
    /// References to mermaid diagram views for in-place updates.
    private var mermaidViews: [Int: NativeMermaidBlockView] = [:]
    /// References to LaTeX block views for in-place updates.
    private var latexViews: [Int: NativeLatexBlockView] = [:]
    private var highlightTasks: [Int: Task<Void, Never>] = [:]
    private var sourceLineRanges: [ClosedRange<Int>?] = []

    /// Cached NSAttributedString for the streaming tail segment. Maintained
    /// incrementally (append-only) to avoid O(total) NSAttributedString conversion
    /// on every streaming tick.
    private var cachedStreamingTailNS: NSMutableAttributedString?
    /// Plain-text mirror of `cachedStreamingTailNS` for prefix validation.
    /// Reading `NSMutableAttributedString.string` rebuilds a Swift string; keep
    /// the append-only plain text beside the attributed cache instead.
    private var cachedStreamingTailPlain: NSMutableString?
    /// Full raw markdown content that produced the cached streaming tail.
    /// Used only to detect append-only prose deltas that cannot close inline
    /// markdown syntax and therefore do not need rendered-prefix validation.
    private var cachedStreamingSourceContent: String?

    /// Closure for fetching workspace files (for inline markdown images).
    /// Injected by the owning view chain, wrapping `APIClient` at the site
    /// where it's available so view-layer files stay decoupled from `APIClient`.
    var fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?

    /// Closure for fetching files from the active session working directory.
    var fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?

    /// Avatar hang geometry from the assistant row. Applied after each rebuild
    /// so the first text segment clears the badge and later content is full width.
    private var leadingHangClearance: CGFloat = 0
    private var leadingHangHeight: CGFloat = 0
    /// Avoid reassigning exclusion paths on every streaming tick — that forces a
    /// full TextKit relayout of the growing prose tail.
    private weak var hungTextView: BaselineSafeTextView?
    private var appliedHangClearance: CGFloat = -1
    private var appliedHangHeight: CGFloat = -1
    private var appliedHangUsesTopMargin = false

    init(stackView: UIStackView, textViewDelegate: any UITextViewDelegate) {
        self.stackView = stackView
        self.textViewDelegate = textViewDelegate
    }

    func clear() {
        cachedStreamingTailNS = nil
        cachedStreamingTailPlain = nil
        cachedStreamingSourceContent = nil

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
        mermaidViews.removeAll()
        latexViews.removeAll()
        renderedSegmentSignatures = []
        stackView.isLayoutMarginsRelativeArrangement = false
        stackView.layoutMargins = .zero
        hungTextView = nil
        appliedHangClearance = -1
        appliedHangHeight = -1
        appliedHangUsesTopMargin = false
    }

    /// Hang content under the assistant avatar.
    ///
    /// - First segment is prose: exclusion path reserves the badge column for
    ///   the first line(s) only; later lines wrap under the avatar.
    /// - First segment is a block (table/code/…): push the block below the
    ///   badge with top layout margin so it can use full width without overlap.
    ///
    /// Idempotent when geometry and the hung text view are unchanged so streaming
    /// ticks do not force a full TextKit relayout of the growing tail.
    func applyLeadingHang(clearance: CGFloat, height: CGFloat) {
        let nextClearance = max(0, clearance)
        let nextHeight = max(0, height)
        leadingHangClearance = nextClearance
        leadingHangHeight = nextHeight

        let firstText = textViews[0]
        let wantsTopMargin = firstText == nil && !renderedSegmentSignatures.isEmpty && nextClearance > 0 && nextHeight > 0

        if firstText === hungTextView,
           appliedHangClearance == nextClearance,
           appliedHangHeight == nextHeight,
           appliedHangUsesTopMargin == wantsTopMargin {
            return
        }

        if let previous = hungTextView, previous !== firstText {
            previous.textContainer.exclusionPaths = []
        }

        guard nextClearance > 0, nextHeight > 0 else {
            firstText?.textContainer.exclusionPaths = []
            stackView.isLayoutMarginsRelativeArrangement = false
            stackView.layoutMargins = .zero
            hungTextView = nil
            appliedHangClearance = 0
            appliedHangHeight = 0
            appliedHangUsesTopMargin = false
            return
        }

        if let firstText {
            stackView.isLayoutMarginsRelativeArrangement = false
            stackView.layoutMargins = .zero
            let exclusion = CGRect(
                x: 0,
                y: 0,
                width: nextClearance,
                height: nextHeight
            )
            firstText.textContainer.exclusionPaths = [UIBezierPath(rect: exclusion)]
            firstText.invalidateIntrinsicContentSize()
            firstText.setNeedsLayout()
            hungTextView = firstText
            appliedHangClearance = nextClearance
            appliedHangHeight = nextHeight
            appliedHangUsesTopMargin = false
            return
        }

        // Non-text first segment: drop the block below the avatar band.
        if wantsTopMargin {
            stackView.isLayoutMarginsRelativeArrangement = true
            stackView.layoutMargins = UIEdgeInsets(
                top: nextHeight,
                left: 0,
                bottom: 0,
                right: 0
            )
        } else {
            stackView.isLayoutMarginsRelativeArrangement = false
            stackView.layoutMargins = .zero
        }
        hungTextView = nil
        appliedHangClearance = nextClearance
        appliedHangHeight = nextHeight
        appliedHangUsesTopMargin = wantsTopMargin
    }

    func apply(
        segments: [FlatSegment],
        config: AssistantMarkdownContentView.Configuration,
        sourceLineRanges: [ClosedRange<Int>?] = []
    ) {
        self.sourceLineRanges = sourceLineRanges
        if !config.isStreaming {
            cachedStreamingTailNS = nil
            cachedStreamingTailPlain = nil
            cachedStreamingSourceContent = nil
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
            rebuild(segments: segments, signatures: signatures, config: config)
        }
    }

    private func rebuild(
        segments: [FlatSegment],
        signatures: [SegmentSignature],
        config: AssistantMarkdownContentView.Configuration
    ) {
        clear()

        appendSegmentViews(segments: segments, in: segments.indices, config: config)
        renderedSegmentSignatures = signatures

        // Seed the incremental cache for the streaming tail.
        if config.isStreaming, let lastIdx = segments.lastIndex(where: {
            if case .text = $0 { return true } else { return false }
        }), let tv = textViews[lastIdx] {
            let fullText = tv.attributedText ?? NSAttributedString()
            cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullText)
            cachedStreamingTailPlain = NSMutableString(string: fullText.string)
            cachedStreamingSourceContent = config.content
        }
    }

    private func appendSegmentViews(
        segments: [FlatSegment],
        in indices: Range<Array<FlatSegment>.Index>,
        config: AssistantMarkdownContentView.Configuration
    ) {
        let palette = config.themeID.palette
        for index in indices {
            appendSegmentView(
                segments[index],
                at: index,
                segmentCount: segments.count,
                config: config,
                palette: palette
            )
        }
    }

    private func appendSegmentView(
        _ segment: FlatSegment,
        at index: Int,
        segmentCount: Int,
        config: AssistantMarkdownContentView.Configuration,
        palette: ThemePalette
    ) {
        switch segment {
        case .text(let attributed):
            let textView = makeTextView(palette: palette)
            textView.isSelectable = config.textSelectionEnabled
            textView.attributedText = NSAttributedString(attributed)
            configureSourceLineResolver(textView, sourceLineRange: sourceLineRange(at: index))
            stackView.addArrangedSubview(textView)
            textViews[index] = textView

        case .codeBlock(let language, let code):
            let codeView = NativeCodeBlockView()
            let isOpen = isOpenStreamingCodeFence(at: index, segmentCount: segmentCount, config: config)
            codeView.configureReviewCommentSelection(
                router: config.reviewCommentSelectionRouter,
                sourceContext: assistantCodeBlockSourceContext(
                    language: language,
                    config: config,
                    lineRange: sourceLineRange(at: index)
                )
            )
            codeView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
            stackView.addArrangedSubview(codeView)
            codeBlockViews[index] = codeView
            if !isOpen {
                applyHighlight(index: index, language: language, code: code, mode: config.renderingMode)
            }

        case .table(let headers, let rows):
            let tableView = NativeTableBlockView()
            tableView.configureReviewCommentSelection(
                router: config.reviewCommentSelectionRouter,
                sourceContext: assistantTableSourceContext(
                    config: config,
                    lineRange: sourceLineRange(at: index)
                )
            )
            tableView.apply(headers: headers, rows: rows, palette: palette)
            stackView.addArrangedSubview(tableView)
            tableViews[index] = tableView

        case .thematicBreak:
            stackView.addArrangedSubview(makeThematicBreak(palette: palette))

        case .image(let alt, let url):
            let imageView = NativeMarkdownImageView()
            imageView.apply(
                url: url,
                alt: alt,
                fetchWorkspaceFile: fetchWorkspaceFile,
                fetchSessionFile: fetchSessionFile,
                renderingMode: config.renderingMode
            )
            stackView.addArrangedSubview(imageView)
            imageViews[index] = imageView

        case .mermaidDiagram(let code):
            let mermaidView = NativeMermaidBlockView()
            let isOpen = isOpenStreamingCodeFence(at: index, segmentCount: segmentCount, config: config)
            mermaidView.configureReviewCommentSelection(
                router: config.reviewCommentSelectionRouter,
                sourceContext: assistantCodeBlockSourceContext(
                    language: "mermaid",
                    config: config,
                    lineRange: sourceLineRange(at: index)
                )
            )
            if isOpen {
                mermaidView.applyAsCode(language: "mermaid", code: code, palette: palette, isOpen: true)
            } else {
                config.renderingMode == .export ? mermaidView.applyAsDiagramSync(code: code, palette: palette) : mermaidView.applyAsDiagram(code: code, palette: palette)
            }
            stackView.addArrangedSubview(mermaidView)
            mermaidViews[index] = mermaidView

        case .latexBlock(let code):
            let latexView = NativeLatexBlockView()
            let isOpen = isOpenStreamingCodeFence(at: index, segmentCount: segmentCount, config: config)
            latexView.configureReviewCommentSelection(
                router: config.reviewCommentSelectionRouter,
                sourceContext: assistantCodeBlockSourceContext(
                    language: "latex",
                    config: config,
                    lineRange: sourceLineRange(at: index)
                )
            )
            if isOpen {
                latexView.applyAsCode(language: "latex", code: code, palette: palette, isOpen: true)
            } else {
                config.renderingMode == .export ? latexView.applyAsFormulaSync(code: code, palette: palette) : latexView.applyAsFormula(code: code, palette: palette)
            }
            stackView.addArrangedSubview(latexView)
            latexViews[index] = latexView
        }
    }

    private func isOpenStreamingCodeFence(
        at index: Int,
        segmentCount: Int,
        config: AssistantMarkdownContentView.Configuration
    ) -> Bool {
        config.isStreaming
            && index == segmentCount - 1
            && AssistantMarkdownSegmentSource.hasUnclosedCodeFence(config.content)
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

        // Find the common prefix length.
        var commonPrefix = 0
        let minLen = min(oldSigs.count, signatures.count)
        while commonPrefix < minLen && oldSigs[commonPrefix] == signatures[commonPrefix] {
            commonPrefix += 1
        }

        // If no common prefix, fall back to full rebuild.
        guard commonPrefix > 0 else {
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
            mermaidViews.removeValue(forKey: index)
            latexViews.removeValue(forKey: index)
            highlightTasks[index]?.cancel()
            highlightTasks.removeValue(forKey: index)
        }

        // Build and append new tail views.
        appendSegmentViews(segments: segments, in: commonPrefix ..< segments.count, config: config)

        renderedSegmentSignatures = signatures

        // Reset incremental cache on structural change.
        cachedStreamingTailNS = nil
        cachedStreamingTailPlain = nil
        cachedStreamingSourceContent = nil

        // Seed the incremental cache for the rebuilt tail.
        let lastTextIndex = segments.lastIndex(where: { if case .text = $0 { return true } else { return false } })
        if let lastIdx = lastTextIndex, let tv = textViews[lastIdx] {
            let fullText = tv.attributedText ?? NSAttributedString()
            cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullText)
            cachedStreamingTailPlain = NSMutableString(string: fullText.string)
            cachedStreamingSourceContent = config.content
        }

        ToolTimelineRowPresentationHelpers.invalidateEnclosingStreamingHeightCache(startingAt: stackView)
    }

    private func updateInPlace(
        segments: [FlatSegment],
        config: AssistantMarkdownContentView.Configuration
    ) {
        let lastTextIndex = segments.lastIndex(where: { if case .text = $0 { return true } else { return false } })

        if config.isStreaming,
           let lastTextIndex,
           lastTextIndex == segments.count - 1,
           case .text(let attributed) = segments[lastTextIndex],
           let textView = textViews[lastTextIndex] {
            configureSourceLineResolver(textView, sourceLineRange: sourceLineRange(at: lastTextIndex))
            updateStreamingTextTail(attributed, in: textView, config: config)
            return
        }

        let palette = config.themeID.palette

        for (index, segment) in segments.enumerated() {
            // During streaming, only the last text segment grows. All other
            // segments are frozen by the incremental parser. Skip them to
            // avoid expensive attributedText re-assignments and code block
            // reconfigurations.
            let isStreamingTail = config.isStreaming && index == lastTextIndex

            switch segment {
            case .text(let attributed):
                if let textView = textViews[index] {
                    configureSourceLineResolver(textView, sourceLineRange: sourceLineRange(at: index))
                    if !config.isStreaming || isStreamingTail {
                        // Skip isSelectable during streaming when unchanged — UITextView
                        // does internal state work on assignment even if value is identical.
                        if !config.isStreaming || textView.isSelectable != config.textSelectionEnabled {
                            textView.isSelectable = config.textSelectionEnabled
                        }

                        if isStreamingTail {
                            updateStreamingTextTail(attributed, in: textView, config: config)
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
                        codeView.configureReviewCommentSelection(
                            router: config.reviewCommentSelectionRouter,
                            sourceContext: assistantCodeBlockSourceContext(
                                language: language,
                                config: config,
                                lineRange: sourceLineRange(at: index)
                            )
                        )
                        codeView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
                        if isOpen {
                            ToolTimelineRowPresentationHelpers.invalidateEnclosingStreamingHeightCache(startingAt: codeView)
                        }
                        if !isOpen && highlightTasks[index] == nil {
                            applyHighlight(index: index, language: language, code: code, mode: config.renderingMode)
                        }
                    }
                }

            case .table(let headers, let rows):
                if let tableView = tableViews[index] {
                    tableView.configureReviewCommentSelection(
                        router: config.reviewCommentSelectionRouter,
                        sourceContext: assistantTableSourceContext(
                            config: config,
                            lineRange: sourceLineRange(at: index)
                        )
                    )
                    tableView.apply(headers: headers, rows: rows, palette: palette)
                }

            case .thematicBreak:
                break

            case .image(let alt, let url):
                // Image views manage their own load lifecycle — nothing to diff in-place.
                if let imageView = imageViews[index] {
                    imageView.apply(
                        url: url,
                        alt: alt,
                        fetchWorkspaceFile: fetchWorkspaceFile,
                        fetchSessionFile: fetchSessionFile,
                        renderingMode: config.renderingMode
                    )
                }

            case .mermaidDiagram(let code):
                if let mermaidView = mermaidViews[index] {
                    let isOpen = config.isStreaming
                        && index == segments.count - 1
                        && AssistantMarkdownSegmentSource.hasUnclosedCodeFence(config.content)
                    mermaidView.configureReviewCommentSelection(
                        router: config.reviewCommentSelectionRouter,
                        sourceContext: assistantCodeBlockSourceContext(
                            language: "mermaid",
                            config: config,
                            lineRange: sourceLineRange(at: index)
                        )
                    )
                    if isOpen {
                        mermaidView.applyAsCode(language: "mermaid", code: code, palette: palette, isOpen: true)
                        ToolTimelineRowPresentationHelpers.invalidateEnclosingStreamingHeightCache(startingAt: mermaidView)
                    } else {
                        config.renderingMode == .export ? mermaidView.applyAsDiagramSync(code: code, palette: palette) : mermaidView.applyAsDiagram(code: code, palette: palette)
                    }
                }

            case .latexBlock(let code):
                if let latexView = latexViews[index] {
                    let isOpen = config.isStreaming
                        && index == segments.count - 1
                        && AssistantMarkdownSegmentSource.hasUnclosedCodeFence(config.content)
                    latexView.configureReviewCommentSelection(
                        router: config.reviewCommentSelectionRouter,
                        sourceContext: assistantCodeBlockSourceContext(
                            language: "latex",
                            config: config,
                            lineRange: sourceLineRange(at: index)
                        )
                    )
                    if isOpen {
                        latexView.applyAsCode(language: "latex", code: code, palette: palette, isOpen: true)
                        ToolTimelineRowPresentationHelpers.invalidateEnclosingStreamingHeightCache(startingAt: latexView)
                    } else {
                        config.renderingMode == .export ? latexView.applyAsFormulaSync(code: code, palette: palette) : latexView.applyAsFormula(code: code, palette: palette)
                    }
                }
            }
        }
    }


    private func updateStreamingTextTail(
        _ attributed: AttributedString,
        in textView: BaselineSafeTextView,
        config: AssistantMarkdownContentView.Configuration
    ) {
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

        if let cached = cachedStreamingTailNS,
           let cachedPlain = cachedStreamingTailPlain,
           cached.length == oldLength {
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
                let prefixValid = Self.isMarkdownNeutralAppend(
                    previousContent: cachedStreamingSourceContent,
                    currentContent: config.content
                ) || fullNS.string.hasPrefix(cachedPlain as String)

                if prefixValid {
                    let delta = fullNS.attributedSubstring(
                        from: NSRange(location: oldLength, length: newLength - oldLength)
                    )
                    textView.textStorage.beginEditing()
                    textView.textStorage.append(delta)
                    textView.textStorage.endEditing()
                    cached.append(delta)
                    cachedPlain.append(delta.string)
                    cachedStreamingSourceContent = config.content
                    refreshTextViewLayoutAfterContentChange(textView)
                } else {
                    // Markdown structure changed — full replacement.
                    let fullPlain = fullNS.string
                    textView.attributedText = fullNS
                    refreshTextViewLayoutAfterContentChange(textView)
                    cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullNS)
                    cachedStreamingTailPlain = NSMutableString(string: fullPlain)
                    cachedStreamingSourceContent = config.content
                }
            } else if newLength != oldLength {
                let fullPlain = fullNS.string
                textView.attributedText = fullNS
                refreshTextViewLayoutAfterContentChange(textView)
                cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullNS)
                cachedStreamingTailPlain = NSMutableString(string: fullPlain)
                cachedStreamingSourceContent = config.content
            } else if !fullNS.isEqual(cached) {
                // Same rendered length but different content/attributes —
                // markdown structure changed without changing character count
                // (for example, inline markers closed while new characters
                // arrived in the same tick). Fall back to full replacement.
                let fullPlain = fullNS.string
                textView.attributedText = fullNS
                refreshTextViewLayoutAfterContentChange(textView)
                cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullNS)
                cachedStreamingTailPlain = NSMutableString(string: fullPlain)
                cachedStreamingSourceContent = config.content
            }
            // else: same length and same attributed content — truly no change, skip
        } else {
            // First tick or cache mismatch — full initialization
            let fullNS = NSAttributedString(attributed)
            textView.attributedText = fullNS
            refreshTextViewLayoutAfterContentChange(textView)
            cachedStreamingTailNS = NSMutableAttributedString(attributedString: fullNS)
            cachedStreamingTailPlain = NSMutableString(string: fullNS.string)
            cachedStreamingSourceContent = config.content
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

    private static func isMarkdownNeutralAppend(
        previousContent: String?,
        currentContent: String
    ) -> Bool {
        guard let previousContent else { return false }

        let previousBytes = previousContent.utf8
        let currentBytes = currentContent.utf8
        guard currentBytes.count > previousBytes.count,
              currentBytes.starts(with: previousBytes) else {
            return false
        }

        for byte in currentBytes.dropFirst(previousBytes.count) {
            switch byte {
            case 33, 38, 40, 41, 42, 60, 62, 91, 92, 93, 95, 96, 124, 126:
                return false
            default:
                continue
            }
        }
        return true
    }

    private func sourceLineRange(at index: Int) -> ClosedRange<Int>? {
        sourceLineRanges.indices.contains(index) ? sourceLineRanges[index] : nil
    }

    private func configureSourceLineResolver(
        _ textView: BaselineSafeTextView,
        sourceLineRange: ClosedRange<Int>?
    ) {
        textView.reviewCommentSourceLineRangeResolver = { [weak textView] range in
            guard let sourceLineRange else { return nil }
            guard let textView else { return sourceLineRange }
            let text = textView.attributedText?.string ?? textView.text ?? ""
            guard let localRange = ReviewCommentSelectionEditMenuSupport.textLineRange(in: text, range: range) else {
                return sourceLineRange
            }
            return ReviewCommentSelectionEditMenuSupport.offsetLineRange(localRange, from: sourceLineRange)
        }
    }

    private func nestedBlockSurface(
        base: ReviewCommentSourceContext,
        fallback: ReviewCommentSurfaceKind
    ) -> ReviewCommentSurfaceKind {
        // Full-screen and expanded readers decide inline composer behavior from
        // their surface. Keep that surface for nested blocks rendered by the
        // shared markdown renderer; timeline markdown keeps block-specific tags.
        base.surface.usesInlineCommentWidget ? base.surface : fallback
    }

    private func assistantCodeBlockSourceContext(
        language: String?,
        config: AssistantMarkdownContentView.Configuration,
        lineRange: ClosedRange<Int>?
    ) -> ReviewCommentSourceContext? {
        guard let base = config.reviewCommentSourceContext else { return nil }
        let surface = nestedBlockSurface(base: base, fallback: .assistantCodeBlock)
        return ReviewCommentSourceContext(
            sessionId: base.sessionId,
            surface: surface,
            sourceLabel: base.sourceLabel,
            filePath: base.filePath,
            lineRange: lineRange ?? base.lineRange,
            languageHint: language,
            timelineItemId: base.timelineItemId
        )
    }

    private func assistantTableSourceContext(
        config: AssistantMarkdownContentView.Configuration,
        lineRange: ClosedRange<Int>?
    ) -> ReviewCommentSourceContext? {
        guard let base = config.reviewCommentSourceContext else { return nil }
        let surface = nestedBlockSurface(base: base, fallback: .assistantTable)
        return ReviewCommentSourceContext(
            sessionId: base.sessionId,
            surface: surface,
            sourceLabel: base.sourceLabel,
            filePath: base.filePath,
            lineRange: lineRange ?? base.lineRange,
            languageHint: base.languageHint,
            timelineItemId: base.timelineItemId
        )
    }


    private func makeThematicBreak(palette: ThemePalette) -> UIView {
        let hr = UIView()
        hr.backgroundColor = UIColor(palette.mdHr).withAlphaComponent(0.6)
        hr.translatesAutoresizingMaskIntoConstraints = false
        hr.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return hr
    }

    private func applyHighlight(index: Int, language: String?, code: String, mode: ContentRenderingMode) {
        guard let langStr = language,
              SyntaxLanguage.detect(langStr) != .unknown else { return }

        let lang = SyntaxLanguage.detect(langStr)

        switch mode {
        case .export:
            // Synchronous — highlight on the current thread so the snapshot
            // captures colored syntax, not plain text.
            let highlighted = SyntaxHighlighter.highlight(code, language: lang)
            codeBlockViews[index]?.applyHighlightedCode(highlighted)

        case .live:
            // Async — dispatch to background thread to avoid scroll jank.
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
}

private enum SegmentSignature: Equatable {
    case text
    case codeBlock
    case table
    case thematicBreak
    case image(url: URL)
    case mermaidDiagram
    case latexBlock

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
        case .mermaidDiagram:
            self = .mermaidDiagram
        case .latexBlock:
            self = .latexBlock
        }
    }
}
