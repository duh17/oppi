import SwiftUI
import UIKit

/// Expanded generic tool call, painted as a notebook cell rather than a
/// markdown note with fenced blocks.
///
/// The source (code, or the call's arguments) sits in an inset card. Nested calls and the result hang off a
/// rail underneath, the way a notebook attaches outputs to its cell. The row
/// header already shows status, glyph, duration, call count, and language, so
/// the cell repeats none of them. The view does not know tool names;
/// `NotebookCellPlan` already decided.
///
/// Inline, the cell is a preview: text is not selectable, so a double-tap
/// reaches the row and opens the reader, and long sections are trimmed so the
/// calls and output stay visible. The reader shows everything, selectable,
/// with review comments, and follows the code family's Viewing Options: text
/// scale for every label, and Wrap Text for the code and printed output.
///
/// This view does not scroll. The timeline owns vertical pans. The reader
/// wraps the cell in its own scroll view.
@MainActor
final class NotebookCellView: UIView, UITextViewDelegate {
    enum Mode {
        case inline
        case reader(ReaderSelection)
    }

    /// Review-comment sources for the reader. Nil contexts still select and copy.
    struct ReaderSelection {
        var router: ReviewCommentSelectionRouter?
        var code: ReviewCommentSourceContext?
        var output: ReviewCommentSourceContext?
        var markdown: ReviewCommentSourceContext?
    }

    /// Inline preview budgets. The row viewport caps the cell at 620 pt;
    /// trimming keeps a long script from hiding its calls and output.
    private enum InlineLimit {
        static let codeLines = 12
        static let codeCharacters = 2_400
        static let calls = 6
        static let outputLines = 10
        static let outputCharacters = 1_600
        /// Formatted documents are larger than stdout, but the row still
        /// clips at 620 pt. Parsing the whole document on the tap, then
        /// throwing the layout away, is the multi-second expansion.
        static let richLines = 40
        static let richCharacters = 6_000
    }

    private let mode: Mode
    private let contentStack = UIStackView()
    private let card = UIView()
    private let accent = UIView()
    private let cardStack = UIStackView()
    private let attachments = UIView()
    private let rail = UIView()
    private let attachmentStack = UIStackView()
    private let fadeMask = CAGradientLayer()
    private var appliedPlan: NotebookCellPlan?
    private var appliedTheme: ThemeID?
    private var appliedPressure = StreamingRenderPolicy.ResourcePressure.nominal
    /// Reader only. Inline cells keep the timeline's tool type and wrap.
    private var readerPreferences = FullScreenReaderContentFamily.code.defaultPreferences
    private var highlightTask: Task<Void, Never>?
    private var highlightGeneration = 0
    private var nextHighlightToken = 0
    private var fittedHeightByWidth: [Int: CGFloat] = [:]
    private var fittedWidthBucket: Int?

    #if DEBUG
    nonisolated(unsafe) static var deferredHighlightDelayForTesting: Duration?
    private(set) var debugDeferredHighlightCountForTesting = 0
    var debugHighlightPendingForTesting: Bool { highlightTask != nil }
    #endif

    init(mode: Mode = .inline) {
        self.mode = mode
        super.init(frame: .zero)
        accessibilityIdentifier = "tool.notebook.cell"
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: Self, previous: UITraitCollection) in
            guard previous.preferredContentSizeCategory
                != view.traitCollection.preferredContentSizeCategory else { return }
            view.fittedHeightByWidth.removeAll()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        highlightTask?.cancel()
    }

    private var isReader: Bool {
        if case .reader = mode { return true }
        return false
    }

    private var readerSelection: ReaderSelection? {
        if case .reader(let selection) = mode { return selection }
        return nil
    }

    /// Reader only: repaints with the new text scale and wrapping.
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard isReader, preferences != readerPreferences else { return }
        readerPreferences = preferences
        guard let plan = appliedPlan else { return }
        fittedHeightByWidth.removeAll()
        paint(plan, theme: appliedTheme ?? ThemeRuntimeState.currentThemeID(), sourceChanged: true)
        invalidateIntrinsicContentSize()
    }

    /// Returns whether the painted plan changed and the row should remeasure.
    @discardableResult
    func apply(
        _ plan: NotebookCellPlan,
        pressure: StreamingRenderPolicy.ResourcePressure = .nominal
    ) -> Bool {
        let theme = ThemeRuntimeState.currentThemeID()
        guard plan != appliedPlan || theme != appliedTheme || pressure != appliedPressure else { return false }
        let sourceChanged = plan.sources != appliedPlan?.sources
            || plan.inputIsCode != appliedPlan?.inputIsCode
            || plan.metadata != appliedPlan?.metadata
            || plan.failed != appliedPlan?.failed
            || theme != appliedTheme
        appliedPlan = plan
        appliedTheme = theme
        appliedPressure = pressure
        fittedHeightByWidth.removeAll()
        let startNs = ChatTimelinePerf.timestampNs()
        paint(plan, theme: theme, sourceChanged: sourceChanged)
        let outputBytes: Int = switch plan.output {
        case .none: 0
        case .stdout(let text), .rich(let text): text.utf8.count
        }
        ChatTimelinePerf.recordRenderStrategy(
            mode: "notebook.paint",
            durationMs: ChatTimelinePerf.elapsedMs(since: startNs),
            inputBytes: plan.sources.reduce(0) { $0 + $1.code.utf8.count } + outputBytes
        )
        return true
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width > 1 ? targetSize.width : max(1, bounds.width)
        let bucket = Int(width.rounded())
        // Expansion measures this cell from the row, the host, and the
        // collection. TextKit does not need to run on every one of those.
        // A rich body sizes from its own bounds and reports a 320 pt height
        // until laid out, so that first pass must not stick.
        let deferCache = hasUnsizedRichOutput
        if !deferCache, let cached = fittedHeightByWidth[bucket] {
            return CGSize(width: width, height: cached)
        }
        let fitted = contentStack.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = max(48, ceil(fitted.height))
        if !deferCache {
            fittedHeightByWidth[bucket] = height
        }
        return CGSize(width: width, height: height)
    }

    /// Rich output uses `intrinsicContentSize` at 320 pt while its bounds
    /// width is still 0. Caching that pass freezes the wrong row height.
    private var hasUnsizedRichOutput: Bool {
        guard case .rich = appliedPlan?.output else { return false }
        return markdownViews(in: self).contains { $0.bounds.width < 1 }
    }

    private func markdownViews(in root: UIView) -> [AssistantMarkdownContentView] {
        var found: [AssistantMarkdownContentView] = (root as? AssistantMarkdownContentView).map { [$0] } ?? []
        for subview in root.subviews {
            found.append(contentsOf: markdownViews(in: subview))
        }
        return found
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFade()
        let bucket = Int(bounds.width.rounded())
        if bounds.width > 1, fittedWidthBucket != bucket {
            fittedWidthBucket = bucket
            fittedHeightByWidth.removeAll()
        }
    }

    // MARK: - Build

    private func build() {
        clipsToBounds = true
        contentStack.axis = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.clipsToBounds = true
        accent.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(accent)

        cardStack.axis = .vertical
        cardStack.spacing = 6
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.layer.cornerRadius = 1
        attachments.addSubview(rail)
        attachmentStack.axis = .vertical
        attachmentStack.spacing = 12
        attachmentStack.translatesAutoresizingMaskIntoConstraints = false
        attachments.addSubview(attachmentStack)

        contentStack.addArrangedSubview(card)
        contentStack.addArrangedSubview(attachments)

        fadeMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]

        // The content never stretches and never squeezes. Taller than its
        // content, the cell leaves space below (the equality sits under label
        // hugging). Shorter, as in a capped timeline row, the cap breaks below
        // label compression resistance (750) and the cell clips. Unconstrained,
        // including the reader, the equality holds and the cell fits its content.
        let bottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .fittingSizeLevel
        let cap = contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        cap.priority = UILayoutPriority(749)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            bottom,
            cap,
            accent.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            accent.topAnchor.constraint(equalTo: card.topAnchor),
            accent.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            accent.widthAnchor.constraint(equalToConstant: 3),
            cardStack.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 10),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            // The rail continues the card's accent edge down through the outputs.
            rail.leadingAnchor.constraint(equalTo: attachments.leadingAnchor, constant: 0.5),
            rail.widthAnchor.constraint(equalToConstant: 2),
            rail.topAnchor.constraint(equalTo: attachments.topAnchor),
            rail.bottomAnchor.constraint(equalTo: attachments.bottomAnchor),
            attachmentStack.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: 11),
            attachmentStack.trailingAnchor.constraint(equalTo: attachments.trailingAnchor, constant: -2),
            attachmentStack.topAnchor.constraint(equalTo: attachments.topAnchor, constant: 2),
            attachmentStack.bottomAnchor.constraint(equalTo: attachments.bottomAnchor, constant: -2),
        ])
    }

    // MARK: - Paint

    private func paint(_ plan: NotebookCellPlan, theme: ThemeID, sourceChanged: Bool) {
        let palette = theme.palette
        card.backgroundColor = UIColor(palette.bgDark)
        card.layer.borderColor = UIColor(palette.mdCodeBlockBorder).cgColor
        accent.backgroundColor = UIColor(plan.failed ? palette.red : palette.blue)
        rail.backgroundColor = UIColor((plan.failed ? palette.red : palette.comment).opacity(0.3))
        let kind = plan.inputIsCode ? "Code cell" : "Tool call"
        accessibilityLabel = plan.running ? "\(kind), running" : (plan.failed ? "\(kind), failed" : kind)
        card.isHidden = plan.sources.isEmpty && plan.metadata.isEmpty

        if sourceChanged || cardStack.arrangedSubviews.isEmpty {
            cancelDeferredHighlight()
            rebuildSource(plan, palette: palette, theme: theme)
        }
        rebuildAttachments(plan, palette: palette, theme: theme)
        setNeedsLayout()
    }

    private func rebuildSource(_ plan: NotebookCellPlan, palette: ThemePalette, theme: ThemeID) {
        cardStack.arrangedSubviews.forEach {
            cardStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        var deferredHighlights: [NotebookDeferredHighlight] = []
        for source in plan.sources {
            if let label = source.label {
                cardStack.addArrangedSubview(sectionCaption(label, color: palette.comment))
            }
            // Leading lines stay so review-comment line numbers match the source.
            var code = Substring(source.code)
            while code.last?.isNewline == true { code = code.dropLast() }
            let shown = isReader
                ? Trimmed(text: String(code), hiddenLines: 0)
                : Trimmed(String(code), lines: InlineLimit.codeLines, characters: InlineLimit.codeCharacters)
            let view = textView()
            view.accessibilityIdentifier = "tool.notebook.code"
            if let deferred = paintCode(
                shown.text, language: source.syntaxLanguage, into: view, palette: palette, theme: theme
            ) {
                deferredHighlights.append(deferred)
            }
            cardStack.addArrangedSubview(lineLayout(view))
            if shown.hiddenLines > 0 {
                cardStack.addArrangedSubview(moreLabel(lines: shown.hiddenLines, palette: palette))
            }
        }
        if !plan.metadata.isEmpty {
            let meta = UILabel()
            meta.font = scaled(ToolFont.small)
            meta.textColor = UIColor(palette.fgDim)
            meta.numberOfLines = isReader ? 0 : 2
            meta.text = plan.metadata.joined(separator: "\n")
            cardStack.setCustomSpacing(10, after: cardStack.arrangedSubviews.last ?? meta)
            cardStack.addArrangedSubview(meta)
        }
        scheduleDeferredHighlights(deferredHighlights)
    }

    /// Paints plain text immediately. Returns a highlight to run after the
    /// tap when the code row's own policy would not color this on the main
    /// thread. A long shell argument, the usual notebook source, is one line
    /// well past that threshold.
    private func paintCode(
        _ code: String,
        language: SyntaxLanguage,
        into view: UITextView,
        palette: ThemePalette,
        theme: ThemeID
    ) -> NotebookDeferredHighlight? {
        let font = codeFont
        view.font = font
        view.textColor = UIColor(palette.fg)
        view.tag = 0
        guard shouldHighlight(code) else {
            view.attributedText = nil
            view.text = code
            return nil
        }
        let profile = StreamingRenderPolicy.ContentProfile.from(text: code)
        let tier = StreamingRenderPolicy.tier(
            isStreaming: false,
            contentKind: .code(language: ToolRowCodeRenderStrategy.languageCategory(for: language)),
            byteCount: profile.byteCount,
            lineCount: profile.lineCount,
            maxLineByteCount: profile.maxLineByteCount,
            pressure: appliedPressure,
            consumer: .explicit
        )
        if tier == .full {
            view.attributedText = highlighted(code, language: language, theme: theme, font: font)
            return nil
        }
        view.attributedText = nil
        view.text = code
        guard tier == .deferred else { return nil }
        let signature = Self.highlightSignature(code: code, language: language, theme: theme, font: font)
        if let cached = ToolRowRenderCache.get(signature: signature) {
            view.attributedText = cached
            return nil
        }
        nextHighlightToken += 1
        view.tag = nextHighlightToken
        return NotebookDeferredHighlight(
            token: nextHighlightToken, code: code, language: language, theme: theme, signature: signature
        )
    }

    private func highlighted(
        _ code: String,
        language: SyntaxLanguage,
        theme: ThemeID,
        font: UIFont
    ) -> NSAttributedString {
        let highlighted = NSMutableAttributedString(
            attributedString: SyntaxHighlighter.highlight(code, language: language, themeID: theme)
        )
        highlighted.addAttribute(
            .font, value: font, range: NSRange(location: 0, length: highlighted.length)
        )
        return highlighted
    }

    private func scheduleDeferredHighlights(_ snippets: [NotebookDeferredHighlight]) {
        cancelDeferredHighlight()
        guard !snippets.isEmpty else { return }
        highlightGeneration += 1
        let generation = highlightGeneration
        let expectedTokens = Set(snippets.map(\.token))
        highlightTask = Task.detached(priority: .utility) { [weak self] in
            #if DEBUG
            if let delay = Self.deferredHighlightDelayForTesting {
                try? await Task.sleep(for: delay)
            }
            #endif
            guard !Task.isCancelled else { return }
            let start = ContinuousClock.now
            let painted = snippets.map { snippet in
                NotebookDeferredHighlightResult(
                    token: snippet.token,
                    colored: SyntaxHighlighter.highlight(
                        snippet.code, language: snippet.language, themeID: snippet.theme
                    ),
                    signature: snippet.signature
                )
            }
            let durationMs = Int((ContinuousClock.now - start) / .milliseconds(1))
            let inputBytes = snippets.reduce(0) { $0 + $1.code.utf8.count }
            await MainActor.run { [weak self] in
                guard let self, self.highlightGeneration == generation else { return }
                let font = self.codeFont
                for result in painted {
                    let withFont = NSMutableAttributedString(attributedString: result.colored)
                    withFont.addAttribute(
                        .font, value: font, range: NSRange(location: 0, length: withFont.length)
                    )
                    ToolRowRenderCache.set(signature: result.signature, attributed: withFont)
                    self.installDeferredHighlight(withFont, token: result.token, expectedTokens: expectedTokens)
                }
                ChatTimelinePerf.recordRenderStrategy(
                    mode: "notebook.deferred.highlight",
                    durationMs: durationMs,
                    inputBytes: inputBytes,
                    language: snippets.first?.language.displayName
                )
                #if DEBUG
                self.debugDeferredHighlightCountForTesting += 1
                #endif
                if self.highlightGeneration == generation {
                    self.highlightTask = nil
                }
            }
        }
    }

    private func installDeferredHighlight(
        _ colored: NSAttributedString,
        token: Int,
        expectedTokens: Set<Int>
    ) {
        guard expectedTokens.contains(token) else { return }
        for case let view as UITextView in textViews(in: cardStack) where view.tag == token {
            view.attributedText = colored
        }
    }

    private func cancelDeferredHighlight() {
        // Bump so an in-flight task cannot install onto the next paint.
        highlightGeneration += 1
        highlightTask?.cancel()
        highlightTask = nil
    }

    private func textViews(in root: UIView) -> [UITextView] {
        var found: [UITextView] = (root as? UITextView).map { [$0] } ?? []
        for subview in root.subviews {
            found.append(contentsOf: textViews(in: subview))
        }
        return found
    }

    /// The cached highlight carries its font, so the reader's text scale is
    /// part of the key.
    private static func highlightSignature(
        code: String,
        language: SyntaxLanguage,
        theme: ThemeID,
        font: UIFont
    ) -> Int {
        var hasher = Hasher()
        hasher.combine("notebook")
        hasher.combine(code)
        hasher.combine(language)
        hasher.combine(theme)
        hasher.combine(font.fontName)
        hasher.combine(font.pointSize)
        return hasher.finalize()
    }

    private func shouldHighlight(_ code: String) -> Bool {
        code.utf8.count <= 16 * 1024 && code.split(separator: "\n", omittingEmptySubsequences: false).count <= 400
    }

    private func rebuildAttachments(_ plan: NotebookCellPlan, palette: ThemePalette, theme: ThemeID) {
        attachmentStack.arrangedSubviews.forEach {
            attachmentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        attachments.isHidden = !plan.hasOutputWell

        if !plan.calls.isEmpty || plan.omittedCalls > 0 || plan.callsIncomplete {
            attachmentStack.addArrangedSubview(callsSection(plan, palette: palette))
        }
        if let output = outputSection(plan, palette: palette, theme: theme) {
            attachmentStack.addArrangedSubview(output)
        } else if plan.running && plan.calls.isEmpty {
            attachmentStack.addArrangedSubview(caption("Running…", color: palette.fgDim))
        }
        if let note = plan.availabilityNote {
            attachmentStack.addArrangedSubview(caption(note, color: palette.comment))
        }
    }

    private func callsSection(_ plan: NotebookCellPlan, palette: ThemePalette) -> UIView {
        let section = sectionStack()
        section.addArrangedSubview(sectionCaption("CALLS", color: palette.comment))
        let shown = isReader ? plan.calls[...] : plan.calls.prefix(InlineLimit.calls)
        for call in shown {
            section.addArrangedSubview(callRow(call, palette: palette))
        }
        let hidden = plan.calls.count - shown.count + plan.omittedCalls
        if hidden > 0 {
            section.addArrangedSubview(caption("+\(hidden) more \(hidden == 1 ? "call" : "calls")", color: palette.fgDim))
        }
        if plan.callsIncomplete {
            section.addArrangedSubview(caption(NestedToolCalls.incompleteNote, color: palette.fgDim))
        }
        return section
    }

    private func outputSection(_ plan: NotebookCellPlan, palette: ThemePalette, theme: ThemeID) -> UIView? {
        let body: UIView
        var hiddenLines = 0
        switch plan.output {
        case .none:
            return nil
        case .stdout(let text):
            let shown = isReader
                ? Trimmed(text: text, hiddenLines: 0)
                : Trimmed(text, lines: InlineLimit.outputLines, characters: InlineLimit.outputCharacters)
            hiddenLines = shown.hiddenLines
            let view = textView()
            view.accessibilityIdentifier = "tool.notebook.output"
            view.font = codeFont
            view.textColor = UIColor(palette.toolOutput)
            view.text = shown.text
            body = lineLayout(view)
        case .rich(let markdown):
            // The reader keeps the formatted document. Inline, a long JSON
            // result was parsed and laid out in full, then the 620 pt cap
            // threw that layout away. The row already fades a clipped cell;
            // a caption after this body would sit past that cap.
            let shown = isReader
                ? Trimmed(text: markdown, hiddenLines: 0)
                : Trimmed(markdown, lines: InlineLimit.richLines, characters: InlineLimit.richCharacters)
            let view = AssistantMarkdownContentView()
            view.accessibilityIdentifier = "tool.notebook.output"
            view.apply(configuration: .make(
                content: shown.text,
                isStreaming: plan.running,
                themeID: theme,
                textSelectionEnabled: isReader,
                reviewCommentSelectionRouter: readerSelection?.router,
                reviewCommentSourceContext: readerSelection?.markdown,
                readerPreferences: isReader ? readerPreferences : nil
            ))
            body = view
        }
        let section = sectionStack()
        section.addArrangedSubview(sectionCaption(
            plan.failed ? "OUTPUT · ERROR" : "OUTPUT",
            color: plan.failed ? palette.red : palette.comment
        ))
        section.addArrangedSubview(body)
        if hiddenLines > 0 {
            section.addArrangedSubview(moreLabel(lines: hiddenLines, palette: palette))
        }
        return section
    }

    private func callRow(_ call: NotebookCellPlan.Call, palette: ThemePalette) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 6
        row.accessibilityIdentifier = "tool.notebook.call"

        let lineHeight = codeFont.lineHeight
        let icon = UIImageView(image: UIImage(systemName: statusSymbol(call.status))?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        ))
        icon.tintColor = UIColor(statusColor(call.status, palette: palette))
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: lineHeight),
        ])
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.isAccessibilityElement = false

        // Name and arguments share one label so they wrap together in the
        // reader and truncate together inline.
        let text = NSMutableAttributedString(string: call.name, attributes: [
            .font: scaled(ToolFont.title),
            .foregroundColor: UIColor(palette.fg),
        ])
        if let arguments = call.arguments {
            text.append(NSAttributedString(string: "  " + arguments, attributes: [
                .font: codeFont,
                .foregroundColor: UIColor(palette.fgDim),
            ]))
        }
        let label = UILabel()
        label.attributedText = text
        label.numberOfLines = isReader ? 0 : 1
        label.lineBreakMode = isReader ? .byWordWrapping : .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = UIStackView(arrangedSubviews: [label])
        column.axis = .vertical
        column.spacing = 2
        if let error = call.error {
            let errorLabel = UILabel()
            errorLabel.font = scaled(ToolFont.small)
            errorLabel.textColor = UIColor(palette.red)
            errorLabel.numberOfLines = isReader ? 0 : 2
            errorLabel.text = error
            column.addArrangedSubview(errorLabel)
        }
        row.addArrangedSubview(icon)
        row.addArrangedSubview(column)
        if let duration = call.duration {
            let time = UILabel()
            time.font = scaled(ToolFont.small)
            time.textColor = UIColor(palette.comment)
            time.text = duration
            time.setContentHuggingPriority(.required, for: .horizontal)
            time.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(time)
        }
        row.isAccessibilityElement = true
        row.accessibilityLabel = [call.name, call.arguments, call.status, call.duration, call.error]
            .compactMap { $0 }.joined(separator: ", ")
        return row
    }

    // MARK: - Pieces

    /// Code and printed output. The reader scales it with Viewing Options.
    private var codeFont: UIFont { scaled(ToolFont.regular) }

    private func scaled(_ font: UIFont) -> UIFont {
        isReader ? FullScreenCodeTypography.scaledFont(font, scale: readerPreferences.textScale) : font
    }

    /// Unwrapped reader text scrolls sideways in its own block, so the calls
    /// and formatted output beside it stay at the readable width.
    private func lineLayout(_ view: UITextView) -> UIView {
        guard isReader, !readerPreferences.wrapsText else { return view }
        return NotebookUnwrappedTextScroller(view)
    }

    private func textView() -> UITextView {
        // A plain selectable text view still begins its pan when scrolling is
        // off and blocks the timeline. BaselineSafeTextView refuses that pan.
        let view = BaselineSafeTextView()
        view.isEditable = false
        // Inline text must not select: a double-tap belongs to the row and
        // opens the reader. The reader selects and comments.
        view.isSelectable = isReader
        view.delegate = isReader ? self : nil
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byCharWrapping
        view.textContainer.widthTracksTextView = true
        view.font = codeFont
        // Match the cell cap (749 beats nothing at 750). Required resistance
        // fought the row's required viewport height on every expansion measure.
        view.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    private func sectionStack() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }

    private func sectionCaption(_ text: String, color: Color) -> UILabel {
        let label = UILabel()
        label.attributedText = NSAttributedString(string: text, attributes: [
            .font: scaled(ToolFont.smallBold),
            .foregroundColor: UIColor(color),
            .kern: 1.2,
        ])
        label.accessibilityTraits = .header
        return label
    }

    private func moreLabel(lines: Int, palette: ThemePalette) -> UILabel {
        caption("+\(lines) more \(lines == 1 ? "line" : "lines")", color: palette.comment)
    }

    private func caption(_ text: String, color: Color) -> UILabel {
        let label = UILabel()
        label.font = scaled(ToolFont.small)
        label.textColor = UIColor(color)
        label.numberOfLines = 0
        label.text = text
        return label
    }

    private func statusSymbol(_ status: String) -> String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "error": return "xmark.circle.fill"
        case "running": return "circle.dotted"
        default: return "minus.circle.fill"
        }
    }

    private func statusColor(_ status: String, palette: ThemePalette) -> Color {
        switch status {
        case "ok": return palette.green
        case "error": return palette.red
        case "running": return palette.blue
        default: return palette.fgDim
        }
    }

    /// Inline, a cell taller than the capped row fades out instead of ending
    /// on a sliced line. The mask is alpha-only, so it suits any background.
    private func updateFade() {
        let clipped = !isReader && contentStack.frame.maxY > bounds.height + 1 && bounds.height > 64
        guard clipped else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let fade: CGFloat = 36
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = bounds
        fadeMask.locations = [0, NSNumber(value: Double((bounds.height - fade) / bounds.height)), 1]
        CATransaction.commit()
        if layer.mask !== fadeMask { layer.mask = fadeMask }
    }

    // MARK: - UITextViewDelegate

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        let action = MarkdownLinkInteractionSupport.classify(url, workspaceID: nil)
        guard case .webLink = action else { return defaultAction }
        return MarkdownLinkInteractionSupport.primaryAction(for: action, defaultAction: defaultAction)
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let selection = readerSelection else { return nil }
        let context = textView.accessibilityIdentifier == "tool.notebook.code" ? selection.code : selection.output
        return ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: selection.router,
            sourceContext: context
        )
    }
}

/// Full-screen notebook reader. The cell does not scroll; this wrapper does,
/// the same shape as the LaTeX body: bounce so a short cell still gets
/// safe-area insets, default inset adjustment, no tail policy.
@MainActor
final class NotebookReaderBody: UIScrollView, FullScreenReaderConfigurable {
    private let cell: NotebookCellView

    init(
        plan: NotebookCellPlan,
        selection: NotebookCellView.ReaderSelection,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences
    ) {
        cell = NotebookCellView(mode: .reader(selection))
        super.init(frame: .zero)
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = true
        backgroundColor = UIColor(palette.bg)
        accessibilityIdentifier = "fullscreen-notebook.scroll"
        cell.applyReaderPreferences(readerPreferences)
        cell.apply(plan)
        cell.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cell)
        // Readable margins. The width tracks the screen; unwrapped code and
        // output scroll sideways inside the cell.
        let inset: CGFloat = 16
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: inset),
            cell.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -inset),
            cell.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: 12),
            cell.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -32),
            cell.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor, constant: -2 * inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        cell.applyReaderPreferences(preferences)
    }
}

/// One unwrapped reader block. The text view is at least its natural line
/// width, so it never wraps, and at least the block width, so a short block
/// still fills it. Only this block scrolls sideways; vertical pans fall
/// through to the reader.
private final class NotebookUnwrappedTextScroller: UIScrollView {
    init(_ textView: UITextView) {
        super.init(frame: .zero)
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        accessibilityIdentifier = "tool.notebook.unwrapped"
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)

        let text = textView.attributedText ?? NSAttributedString()
        let natural = text.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        // Slack keeps a rounding difference from wrapping the widest line.
        let lineWidth = ceil(natural.width) + 2
        let fill = textView.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor)
        fill.priority = .defaultLow
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            textView.widthAnchor.constraint(greaterThanOrEqualTo: frameLayoutGuide.widthAnchor),
            textView.widthAnchor.constraint(greaterThanOrEqualToConstant: lineWidth),
            fill,
            frameLayoutGuide.heightAnchor.constraint(equalTo: contentLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

/// Leading slice of a long text for the inline preview.
private struct Trimmed {
    var text: String
    var hiddenLines: Int

    init(text: String, hiddenLines: Int) {
        self.text = text
        self.hiddenLines = hiddenLines
    }

    /// Keeps at most `lines` lines and `characters` characters. A line cut
    /// mid-way ends in an ellipsis; whole hidden lines are counted.
    init(_ source: String, lines: Int, characters: Int) {
        let body = source.trimmingCharacters(in: .newlines)
        let all = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard all.count > lines || body.count > characters else {
            self.init(text: body, hiddenLines: 0)
            return
        }
        var kept = all.prefix(lines).joined(separator: "\n")
        var keptLines = min(lines, all.count)
        var cut = false
        if kept.count > characters {
            kept = String(kept.prefix(characters))
            keptLines = kept.split(separator: "\n", omittingEmptySubsequences: false).count
            cut = true
        }
        self.init(text: cut ? kept + "…" : kept, hiddenLines: all.count - keptLines)
    }
}

/// Highlight work that must not run on the expansion tap. Token identifies
/// the text view; a later paint uses a new token so a finished task cannot
/// color a recycled cell.
private struct NotebookDeferredHighlight: Sendable {
    var token: Int
    var code: String
    var language: SyntaxLanguage
    var theme: ThemeID
    var signature: Int
}

private struct NotebookDeferredHighlightResult: @unchecked Sendable {
    var token: Int
    var colored: NSAttributedString
    var signature: Int
}
