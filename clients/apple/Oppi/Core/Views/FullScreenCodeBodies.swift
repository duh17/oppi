import SwiftUI
import UIKit
import WebKit


// MARK: - Code Body

private final class CodeLineNumberGutterView: UIView {
    struct Row: Equatable {
        let text: String
        let y: CGFloat
        let height: CGFloat
    }

    var font: UIFont = FullScreenCodeTypography.codeFont {
        didSet { setNeedsDisplay() }
    }

    var textColor: UIColor = .secondaryLabel {
        didSet { setNeedsDisplay() }
    }

    var rows: [Row] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard !rows.isEmpty else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]

        for row in rows {
            let rowRect = CGRect(x: 0, y: row.y, width: bounds.width, height: row.height)
            guard rowRect.intersects(rect) else { continue }
            (row.text as NSString).draw(
                with: rowRect,
                options: [.usesLineFragmentOrigin],
                attributes: attributes,
                context: nil
            )
        }
    }
}

final class NativeFullScreenCodeBody: UIView {
    private let scrollView = UIScrollView()
    private let contentContainer = UIView()
    private let gutterView = CodeLineNumberGutterView()
    private let separatorView = UIView()
    private let codeTextView = FullScreenReviewCommentTextView()
    private let content: String
    private let language: String?
    private let startLine: Int
    private let lineCount: Int
    private let palette: ThemePalette
    private let alwaysBounceVertical: Bool
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private var readerPreferences: FullScreenReaderPreferences
    private var gutterWidthConstraint: NSLayoutConstraint?
    private var contentContainerWidthConstraint: NSLayoutConstraint?
    private var highlightedSourceText: NSAttributedString?
    private var lastGutterLayoutSignature: GutterLayoutSignature?
    private var highlightTask: Task<Void, Never>?

    private struct GutterLayoutSignature: Equatable {
        let wrapsText: Bool
        let codeTextWidth: Int
        let fontPointSize: CGFloat
        let contentLength: Int
    }

    init(
        content: String,
        language: String?,
        startLine: Int,
        palette: ThemePalette,
        alwaysBounceVertical: Bool = true,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.code.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.content = content
        self.language = language
        self.startLine = startLine
        self.lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        self.palette = palette
        self.alwaysBounceVertical = alwaysBounceVertical
        self.readerPreferences = readerPreferences
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        super.init(frame: .zero)
        setup()
        loadHighlighting()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit { highlightTask?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.layoutIfNeeded()
        contentContainer.layoutIfNeeded()
        updateGutterForCurrentLayout()
    }

    private func setup() {
        backgroundColor = UIColor(palette.bgDark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = alwaysBounceVertical
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentContainer)

        // Gutter — draws line numbers at the exact TextKit fragment Y for each
        // logical source line, so soft-wrapped continuations stay unnumbered.
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.font = codeFont
        gutterView.textColor = UIColor(palette.comment)
        contentContainer.addSubview(gutterView)

        let (_, gutterWidth) = lineNumberInfo(
            lineCount: lineCount,
            startLine: startLine,
            font: codeFont
        )

        // Separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.2)
        contentContainer.addSubview(separatorView)

        // Code text
        codeTextView.translatesAutoresizingMaskIntoConstraints = false
        codeTextView.font = codeFont
        codeTextView.textColor = UIColor(palette.fg)
        codeTextView.backgroundColor = .clear
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isScrollEnabled = false
        codeTextView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        codeTextView.textContainer.lineFragmentPadding = 0
        applyWrapMode()
        codeTextView.text = content
        codeTextView.delegate = self
        codeTextView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
        contentContainer.addSubview(codeTextView)

        let gutterWidthConstraint = gutterView.widthAnchor.constraint(equalToConstant: gutterWidth)
        self.gutterWidthConstraint = gutterWidthConstraint

        let contentContainerWidthConstraint = contentContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        contentContainerWidthConstraint.priority = .required
        contentContainerWidthConstraint.isActive = readerPreferences.wrapsText
        self.contentContainerWidthConstraint = contentContainerWidthConstraint

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
            gutterView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            gutterWidthConstraint,

            separatorView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor, constant: 6),
            separatorView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: 1),

            codeTextView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor),
            codeTextView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            codeTextView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            codeTextView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
    }

    private var codeFont: UIFont {
        FullScreenCodeTypography.codeFont(for: readerPreferences)
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
                self?.highlightedSourceText = wrapper.value
                self?.codeTextView.setAttributedTextPreservingSelection(fullScreenAttributedCodeText(
                    from: wrapper.value,
                    font: self?.codeFont ?? FullScreenCodeTypography.codeFont
                ))
                self?.invalidateGutterLayout()
            }
        }
    }

    private func applyTextSize() {
        let font = codeFont
        gutterView.font = font
        codeTextView.font = font

        let (_, gutterWidth) = lineNumberInfo(
            lineCount: lineCount,
            startLine: startLine,
            font: font
        )
        gutterWidthConstraint?.constant = gutterWidth

        if let attributedText = highlightedSourceText ?? codeTextView.attributedText,
           attributedText.length > 0 {
            codeTextView.setAttributedTextPreservingSelection(fullScreenAttributedCodeText(
                from: attributedText,
                font: font
            ))
        }
        invalidateGutterLayout()
    }

    private func applyWrapMode() {
        let wraps = readerPreferences.wrapsText
        codeTextView.textContainer.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        codeTextView.textContainer.widthTracksTextView = wraps
        codeTextView.textContainer.size = wraps
            ? .zero
            : CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.alwaysBounceHorizontal = !wraps
        scrollView.showsHorizontalScrollIndicator = !wraps
        contentContainerWidthConstraint?.isActive = wraps
        if wraps {
            scrollView.contentOffset.x = -scrollView.adjustedContentInset.left
        }
        invalidateGutterLayout()
    }

    private func invalidateGutterLayout() {
        lastGutterLayoutSignature = nil
        setNeedsLayout()
    }

    private func updateGutterForCurrentLayout() {
        guard codeTextView.bounds.width > 0 else { return }

        let signature = GutterLayoutSignature(
            wrapsText: readerPreferences.wrapsText,
            codeTextWidth: Int(codeTextView.bounds.width.rounded(.toNearestOrAwayFromZero)),
            fontPointSize: codeFont.pointSize,
            contentLength: (content as NSString).length
        )
        guard signature != lastGutterLayoutSignature else { return }
        lastGutterLayoutSignature = signature

        gutterView.font = codeFont
        gutterView.textColor = UIColor(palette.comment)
        gutterView.rows = lineNumberRowsForCurrentLayout()
    }

    private func prepareCodeTextContainerForCurrentWidth() {
        let insets = codeTextView.textContainerInset
        let textContainerWidth = max(1, codeTextView.bounds.width - insets.left - insets.right)
        codeTextView.textContainer.size = readerPreferences.wrapsText
            ? CGSize(width: textContainerWidth, height: CGFloat.greatestFiniteMagnitude)
            : CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    private func lineNumberRowsForCurrentLayout() -> [CodeLineNumberGutterView.Row] {
        prepareCodeTextContainerForCurrentWidth()

        let layoutManager = codeTextView.layoutManager
        layoutManager.ensureLayout(for: codeTextView.textContainer)

        let source = content as NSString
        let lineRanges = logicalLineContentRanges(in: source)
        var rows: [CodeLineNumberGutterView.Row] = []
        rows.reserveCapacity(lineRanges.count)

        var fallbackY: CGFloat = 0
        for (offset, range) in lineRanges.enumerated() {
            let fragmentRect = firstLineFragmentRect(
                for: range,
                layoutManager: layoutManager,
                fallbackY: fallbackY
            )
            fallbackY = fragmentRect.maxY

            rows.append(CodeLineNumberGutterView.Row(
                text: String(startLine + offset),
                y: codeTextView.textContainerInset.top + fragmentRect.minY,
                height: max(codeFont.lineHeight, fragmentRect.height)
            ))
        }

        return rows
    }

    private func firstLineFragmentRect(
        for characterRange: NSRange,
        layoutManager: NSLayoutManager,
        fallbackY: CGFloat
    ) -> CGRect {
        if characterRange.length > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            if glyphRange.length > 0 {
                return layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
            }
        }

        let textLength = codeTextView.textStorage.length
        if textLength > 0, characterRange.location < textLength {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterRange.location)
            if glyphIndex < layoutManager.numberOfGlyphs {
                return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            }
        }

        return CGRect(
            x: 0,
            y: fallbackY,
            width: codeTextView.textContainer.size.width,
            height: codeFont.lineHeight
        )
    }

    private func logicalLineContentRanges(in source: NSString) -> [NSRange] {
        guard source.length > 0 else { return [NSRange(location: 0, length: 0)] }

        var ranges: [NSRange] = []
        var location = 0
        while location < source.length {
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                nil,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            ranges.append(NSRange(location: location, length: max(0, contentsEnd - location)))
            guard lineEnd > location else { break }
            location = lineEnd
        }

        if source.length > 0, Self.isNewline(source.character(at: source.length - 1)) {
            ranges.append(NSRange(location: source.length, length: 0))
        }

        return ranges
    }

    private static func isNewline(_ value: unichar) -> Bool {
        value == 10 || value == 13
    }

#if DEBUG
    struct CodeGutterAlignmentDiagnostics: Equatable {
        let rowCount: Int
        let maxRowDelta: CGFloat
        let firstLogicalLineGap: CGFloat
        let lineHeight: CGFloat
    }

    func codeGutterAlignmentDiagnosticsForTesting() -> CodeGutterAlignmentDiagnostics {
        layoutIfNeeded()
        updateGutterForCurrentLayout()

        let drawnRows = gutterView.rows
        let expectedRows = lineNumberRowsForCurrentLayout()
        let maxRowDelta = zip(drawnRows, expectedRows)
            .map { abs($0.y - $1.y) }
            .max() ?? 0
        let firstLogicalLineGap: CGFloat
        if drawnRows.count >= 2 {
            firstLogicalLineGap = drawnRows[1].y - drawnRows[0].y
        } else {
            firstLogicalLineGap = 0
        }

        return CodeGutterAlignmentDiagnostics(
            rowCount: drawnRows.count,
            maxRowDelta: maxRowDelta,
            firstLogicalLineGap: firstLogicalLineGap,
            lineHeight: codeFont.lineHeight
        )
    }
#endif

}

extension NativeFullScreenCodeBody: FullScreenReaderConfigurable {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        applyTextSize()
        applyWrapMode()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

extension NativeFullScreenCodeBody: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? FullScreenReviewCommentTextView)?.reviewCommentSelectionDidChange()
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenReviewCommentMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

// MARK: - Diff Body

final class NativeFullScreenDiffBody: UIView {
    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let statsLabel = UILabel()
    private let scrollView = UIScrollView()
    private let diffTextView = FullScreenReviewCommentTextView()
    private let progressView = UIActivityIndicatorView(style: .medium)
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private var readerPreferences: FullScreenReaderPreferences
    private var widthConstraint: NSLayoutConstraint?
    private var unwrappedContentWidth: CGFloat = 1
    private var builtDiffText: NSAttributedString?
    private var buildTask: Task<Void, Never>?

    private struct BuiltDiff: @unchecked Sendable {
        let text: NSAttributedString
        let width: CGFloat
        let added: Int
        let removed: Int
    }

    init(
        oldText: String,
        newText: String,
        filePath: String?,
        precomputedLines: [DiffLine]?,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.diff.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.readerPreferences = readerPreferences

        super.init(frame: .zero)
        backgroundColor = UIColor(palette.bgDark)

        let fileName = filePath.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let relativePath = filePath.flatMap { path -> String? in
            guard let fileName else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            return parent == path || parent.isEmpty || parent == "/" ? fileName : parent
        }

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = UIColor(palette.bgDark)
        addSubview(headerView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = AppFont.systemFeedbackMedium
        titleLabel.textColor = UIColor(palette.fg)
        titleLabel.text = fileName ?? String(localized: "Changes")
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = AppFont.systemSmall
        subtitleLabel.textColor = UIColor(palette.fgDim)
        subtitleLabel.text = relativePath ?? String(localized: "Review changes")
        subtitleLabel.numberOfLines = 1

        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        statsLabel.font = AppFont.systemFeedback
        statsLabel.textColor = UIColor(palette.fgDim)
        statsLabel.textAlignment = .right
        statsLabel.text = String(localized: "Loading…")

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .fill

        let headerStack = UIStackView(arrangedSubviews: [textStack, statsLabel])
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 12
        headerView.addSubview(headerStack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.backgroundColor = UIColor(palette.bgDark)
        addSubview(scrollView)

        diffTextView.translatesAutoresizingMaskIntoConstraints = false
        diffTextView.font = codeFont
        diffTextView.textColor = UIColor(palette.fg)
        diffTextView.backgroundColor = .clear
        diffTextView.isEditable = false
        diffTextView.isSelectable = true
        diffTextView.isScrollEnabled = false
        diffTextView.textContainerInset = UIEdgeInsets(top: 6, left: 12, bottom: 16, right: 12)
        diffTextView.textContainer.lineFragmentPadding = 0
        diffTextView.textContainer.lineBreakMode = readerPreferences.wrapsText ? .byCharWrapping : .byClipping
        diffTextView.textContainer.widthTracksTextView = false
        diffTextView.textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffTextView.delegate = self
        diffTextView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )

        let widthConstraint = diffTextView.widthAnchor.constraint(equalToConstant: 1)
        self.widthConstraint = widthConstraint

        scrollView.addSubview(diffTextView)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.color = UIColor(palette.fgDim)
        progressView.startAnimating()
        addSubview(progressView)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),

            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -10),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            diffTextView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            diffTextView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            diffTextView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            diffTextView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            widthConstraint,
            diffTextView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
            progressView.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        diffTextView.text = Self.initialSelectableText(
            newText: newText,
            precomputedLines: precomputedLines
        )
        applyWrapMode()
        let displayPath = filePath ?? "diff.txt"
        buildTask = Task { [weak self] in
            let oldText = oldText
            let newText = newText
            let precomputedLines = precomputedLines
            let result = await Task.detached(priority: .userInitiated) {
                let lines = precomputedLines ?? DiffEngine.compute(old: oldText, new: newText)
                return Self.buildDiff(lines: lines, displayPath: displayPath)
            }.value

            guard !Task.isCancelled else { return }
            self?.applyBuiltDiff(result)
        }
    }

    deinit {
        buildTask?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyWrapMode()
    }

    private var codeFont: UIFont {
        FullScreenCodeTypography.codeFont(for: readerPreferences)
    }

    private static func initialSelectableText(
        newText: String,
        precomputedLines: [DiffLine]?
    ) -> String {
        guard let precomputedLines else { return newText }
        return DiffEngine.formatUnified(precomputedLines)
    }

    nonisolated private static func buildDiff(lines: [DiffLine], displayPath: String) -> BuiltDiff {
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: false)
        let build = DiffAttributedStringBuilder.buildResult(
            hunks: hunks,
            filePath: displayPath,
            options: .init(includeStats: true, includeGapSummary: true)
        )
        let measured = build.attributedText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        let addedCount = lines.reduce(into: 0) { total, line in
            if line.kind == .added { total += 1 }
        }
        let removedCount = lines.reduce(into: 0) { total, line in
            if line.kind == .removed { total += 1 }
        }
        return BuiltDiff(
            text: build.attributedText,
            width: ceil(measured.width) + 24,
            added: addedCount,
            removed: removedCount
        )
    }

    private func applyBuiltDiff(_ result: BuiltDiff) {
        builtDiffText = result.text
        let styledText = styledDiffText(result.text)
        diffTextView.setAttributedTextPreservingSelection(styledText)
        unwrappedContentWidth = max(result.width, measuredWidth(of: styledText))
        applyWrapMode()
        statsLabel.text = "\(result.added > 0 ? "+\(result.added)" : "0")  \(result.removed > 0 ? "-\(result.removed)" : "0")"
        progressView.stopAnimating()
        progressView.removeFromSuperview()
        setNeedsLayout()
    }



    private func applyTextSize() {
        diffTextView.font = codeFont
        if let attributedText = builtDiffText ?? diffTextView.attributedText,
           attributedText.length > 0 {
            let styledText = styledDiffText(attributedText)
            diffTextView.setAttributedTextPreservingSelection(styledText)
            unwrappedContentWidth = measuredWidth(of: styledText)
        }
        applyWrapMode()
    }

    private func applyWrapMode() {
        let wraps = readerPreferences.wrapsText
        diffTextView.textContainer.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        diffTextView.textContainer.widthTracksTextView = wraps
        diffTextView.textContainer.size = wraps
            ? .zero
            : CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.alwaysBounceHorizontal = !wraps
        scrollView.showsHorizontalScrollIndicator = !wraps
        widthConstraint?.constant = wraps ? max(1, scrollView.bounds.width) : max(1, unwrappedContentWidth)
        if wraps {
            scrollView.contentOffset.x = -scrollView.adjustedContentInset.left
        }
    }

    private func styledDiffText(_ attributedText: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let lineBreakMode: NSLineBreakMode = readerPreferences.wrapsText ? .byCharWrapping : .byClipping
        attributedText.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let font = (value as? UIFont) ?? FullScreenCodeTypography.codeFont
            mutable.addAttribute(
                .font,
                value: FullScreenCodeTypography.scaledFont(font, scale: readerPreferences.textScale),
                range: range
            )
        }
        attributedText.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.lineBreakMode = lineBreakMode
            mutable.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return mutable
    }

    private func measuredWidth(of attributedText: NSAttributedString) -> CGFloat {
        let measured = attributedText.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        return ceil(measured.width) + 24
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}

extension NativeFullScreenDiffBody: FullScreenReaderConfigurable {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        applyTextSize()
        setNeedsLayout()
    }
}

extension NativeFullScreenDiffBody: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? FullScreenReviewCommentTextView)?.reviewCommentSelectionDidChange()
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenReviewCommentMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

// MARK: - Terminal Body

final class NativeFullScreenTerminalBody: UIView, UIScrollViewDelegate {
    // ~4ms at measured 26 MB/s throughput, safely within 16ms frame budget
    private static let maxSynchronousANSIBytes = 128 * 1024
    private static let maxEstimatedOutputWidth: CGFloat = 120_000

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let commandView = FullScreenReviewCommentTextView()
    private let outputView = FullScreenReviewCommentTextView()
    private let palette: ThemePalette
    private let stream: TerminalTraceStream?
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private var readerPreferences: FullScreenReaderPreferences

    private var latestSnapshot: TerminalTraceStream.Snapshot
    private var renderedSnapshot: TerminalTraceStream.Snapshot?
    private var renderedOutputText = ""
    private var renderedOutputAttributedBase: NSAttributedString?
    private var stackWidthConstraint: NSLayoutConstraint?

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
        outputWrapped: Bool? = nil,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.terminal.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.palette = palette
        self.stream = stream
        var preferences = readerPreferences
        if let outputWrapped {
            preferences.wrapsText = outputWrapped
        }
        self.readerPreferences = preferences
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext

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
        updateWrappingLayout()
        tailFollowCoordinator.onLayoutPass()
    }

    private func setup() {
        backgroundColor = UIColor(palette.bgDark)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.isDirectionalLockEnabled = true
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
        commandView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )

        outputView.translatesAutoresizingMaskIntoConstraints = false
        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.isScrollEnabled = false
        outputView.backgroundColor = .clear
        outputView.textContainerInset = UIEdgeInsets(top: 4, left: 6, bottom: 14, right: 6)
        outputView.textContainer.lineFragmentPadding = 0
        outputView.font = codeFont
        outputView.textColor = UIColor(palette.fg)
        outputView.delegate = self
        outputView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
        applyOutputWrapMode()

        addSubview(scrollView)
        scrollView.addSubview(stack)

        stack.addArrangedSubview(commandView)
        stack.addArrangedSubview(outputView)

        let stackWidth = stack.widthAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.widthAnchor,
            constant: -20
        )
        stackWidthConstraint = stackWidth

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackWidth,
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
            let attributedOutput = ANSIParser.attributedString(
                from: content, baseForeground: .themeFg
            )
            renderedOutputAttributedBase = attributedOutput
            outputView.attributedText = attributedOutput
            applyOutputFont()
            renderedOutputText = outputView.attributedText?.string ?? ""
            updateWrappingLayout()
            return
        }

        outputView.attributedText = nil
        renderedOutputAttributedBase = nil
        outputView.font = codeFont
        let stripped = ANSIParser.strip(content)
        outputView.text = stripped
        renderedOutputText = stripped
        updateWrappingLayout()

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
                self?.renderedOutputAttributedBase = wrapper.value
                self?.outputView.attributedText = wrapper.value
                self?.applyOutputFont()
                self?.renderedOutputText = wrapper.value.string
                self?.updateWrappingLayout()
                self?.tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
            }
        }
    }

    func setOutputWrapped(_ wrapped: Bool) {
        guard readerPreferences.wrapsText != wrapped else { return }
        readerPreferences.wrapsText = wrapped
        applyOutputWrapMode()
        setNeedsLayout()
        layoutIfNeeded()
    }

    private var codeFont: UIFont {
        FullScreenCodeTypography.codeFont(for: readerPreferences)
    }

    private func applyOutputWrapMode() {
        let wraps = readerPreferences.wrapsText
        outputView.textContainer.lineBreakMode = wraps ? .byCharWrapping : .byClipping
        scrollView.alwaysBounceHorizontal = !wraps
        scrollView.showsHorizontalScrollIndicator = !wraps
        if wraps {
            scrollView.contentOffset.x = -scrollView.adjustedContentInset.left
        }
        updateWrappingLayout()
    }

    private func applyOutputFont() {
        outputView.font = codeFont
        guard let attributedText = renderedOutputAttributedBase ?? outputView.attributedText,
              attributedText.length > 0 else { return }
        outputView.attributedText = fullScreenAttributedCodeText(
            from: attributedText,
            font: codeFont
        )
    }

    private func updateWrappingLayout() {
        let viewportWidth = max(1, scrollView.bounds.width)
        let minimumWidth = max(0, viewportWidth - 20)
        let targetWidth = readerPreferences.wrapsText
            ? minimumWidth
            : max(minimumWidth, estimatedUnwrappedOutputWidth())
        stackWidthConstraint?.constant = targetWidth - viewportWidth
    }

    private func estimatedUnwrappedOutputWidth() -> CGFloat {
        let columns = Self.widestLineColumnCount(in: renderedOutputText)
        let sampleWidth = ("M" as NSString).size(
            withAttributes: [.font: codeFont]
        ).width
        let textWidth = CGFloat(columns) * max(1, sampleWidth)
        let insetWidth = outputView.textContainerInset.left + outputView.textContainerInset.right + 12
        return min(Self.maxEstimatedOutputWidth, ceil(textWidth + insetWidth))
    }

    private static func widestLineColumnCount(in text: String) -> Int {
        var widest = 0
        var current = 0
        for character in text {
            if character == "\n" {
                widest = max(widest, current)
                current = 0
            } else if character == "\t" {
                current += 4
            } else {
                current += 1
            }
        }
        return max(widest, current)
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

extension NativeFullScreenTerminalBody: FullScreenReaderConfigurable {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        let textSizeChanged = preferences.textScale != readerPreferences.textScale
        readerPreferences = preferences
        if textSizeChanged {
            applyOutputFont()
        }
        applyOutputWrapMode()
        setNeedsLayout()
    }
}

extension NativeFullScreenTerminalBody: UITextViewDelegate {
    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? FullScreenReviewCommentTextView)?.reviewCommentSelectionDidChange()
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenReviewCommentMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

private final class FullScreenMarkdownSegmentCell: UICollectionViewCell, UITextViewDelegate, UIGestureRecognizerDelegate {
    static let reuseIdentifier = "FullScreenMarkdownSegmentCell"

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var segmentApplier = AssistantMarkdownSegmentApplier(
        stackView: stackView,
        textViewDelegate: self
    )

    private weak var textViewDelegate: (any UITextViewDelegate)?
    private var doubleTapActivation: (() -> Void)?
    private lazy var doubleTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        recognizer.numberOfTapsRequired = 2
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
        contentView.addGestureRecognizer(doubleTapRecognizer)
        contentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        textViewDelegate = nil
        doubleTapActivation = nil
        segmentApplier.clear()
    }

    func apply(
        segment: FlatSegment,
        config: AssistantMarkdownContentView.Configuration,
        textViewDelegate: any UITextViewDelegate,
        doubleTapActivation: (() -> Void)?,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    ) {
        self.textViewDelegate = textViewDelegate
        self.doubleTapActivation = doubleTapActivation
        segmentApplier.fetchWorkspaceFile = fetchWorkspaceFile
        segmentApplier.fetchSessionFile = fetchSessionFile
        segmentApplier.apply(segments: [segment], config: config)
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        bounds.size.width = layoutAttributes.size.width
        contentView.bounds.size.width = layoutAttributes.size.width
        setNeedsLayout()
        layoutIfNeeded()

        let targetSize = CGSize(
            width: layoutAttributes.size.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let size = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        attributes.size = CGSize(width: layoutAttributes.size.width, height: ceil(size.height))
        return attributes
    }

    @objc private func handleDoubleTap() {
        doubleTapActivation?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === doubleTapRecognizer
            || otherGestureRecognizer === doubleTapRecognizer
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        textViewDelegate?.textView?(
            textView,
            editMenuForTextIn: range,
            suggestedActions: suggestedActions
        )
    }

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        textViewDelegate?.textView?(
            textView,
            primaryActionFor: textItem,
            defaultAction: defaultAction
        ) ?? defaultAction
    }

    func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        textViewDelegate?.textView?(
            textView,
            menuConfigurationFor: textItem,
            defaultMenu: defaultMenu
        ) ?? UITextItem.MenuConfiguration(menu: defaultMenu)
    }
}

final class NativeFullScreenMarkdownBody: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    private let collectionView: UICollectionView
    private let segmentSource = AssistantMarkdownSegmentSource()
    private let stream: ThinkingTraceStream?
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?
    private var textSelectionEnabled: Bool
    private let workspaceID: String?
    private let sessionID: String?
    private let serverBaseURL: URL?
    private let sourceFilePath: String?
    private let fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    private let fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    private var readerPreferences: FullScreenReaderPreferences

    private let perfSurface: MarkdownStreamingPerf.Surface?

    private var latestSnapshot: ThinkingTraceStream.Snapshot
    private var renderedSnapshot: ThinkingTraceStream.Snapshot?
    private var renderedSegments: [FlatSegment] = []
    private var currentConfig: AssistantMarkdownContentView.Configuration?
    private var viewportDoubleTapActivation: (() -> Void)?
    private var streamObserverID: UUID?

    private lazy var tailFollowCoordinator = TailFollowScrollCoordinator(
        scrollView: collectionView,
        shouldAutoFollowTail: false,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    init(
        content: String,
        stream: ThinkingTraceStream?,
        isStreaming: Bool = false,
        palette: ThemePalette,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool = true,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceFilePath: String? = nil,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.markdown.defaultPreferences,
        perfSurface: MarkdownStreamingPerf.Surface? = nil,
        allowsVerticalBounce: Bool = true,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? = nil,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)? = nil
    ) {
        self.stream = stream
        self.perfSurface = perfSurface
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.textSelectionEnabled = textSelectionEnabled
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.serverBaseURL = serverBaseURL
        self.sourceFilePath = sourceFilePath
        self.readerPreferences = readerPreferences
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        let initialSnapshot = stream?.snapshot
            ?? ThinkingTraceStream.Snapshot(text: content, isDone: !isStreaming)
        latestSnapshot = initialSnapshot
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: Self.makeCollectionLayout(
                spacing: readerPreferences.spacing.markdownStackSpacing
            )
        )

        super.init(frame: .zero)
        tailFollowCoordinator.shouldAutoFollowTail = !initialSnapshot.isDone

        backgroundColor = UIColor(palette.bgDark)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = UIColor(palette.bgDark)
        collectionView.alwaysBounceVertical = allowsVerticalBounce
        collectionView.bounces = allowsVerticalBounce
        collectionView.showsVerticalScrollIndicator = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            FullScreenMarkdownSegmentCell.self,
            forCellWithReuseIdentifier: FullScreenMarkdownSegmentCell.reuseIdentifier
        )

        addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        render(snapshot: initialSnapshot)

        guard let stream else { return }
        streamObserverID = stream.addObserver { [weak self] snapshot in
            self?.handleStreamUpdate(snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var accessibilityIdentifier: String? {
        didSet {
            collectionView.accessibilityIdentifier = accessibilityIdentifier
        }
    }

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

    private static func makeCollectionLayout(spacing: CGFloat) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .estimated(44)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 10,
                leading: 12,
                bottom: 10,
                trailing: 12
            )
            return section
        }
    }

    private func handleStreamUpdate(_ snapshot: ThinkingTraceStream.Snapshot) {
        latestSnapshot = snapshot
        render(snapshot: snapshot)
    }

    func update(
        content: String,
        isStreaming: Bool,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool
    ) {
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.textSelectionEnabled = textSelectionEnabled
        renderedSnapshot = nil
        let snapshot = ThinkingTraceStream.Snapshot(text: content, isDone: !isStreaming)
        latestSnapshot = snapshot
        render(snapshot: snapshot)
    }

    func update(content: String, isStreaming: Bool) {
        update(
            content: content,
            isStreaming: isStreaming,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSourceContext: reviewCommentSourceContext,
            textSelectionEnabled: textSelectionEnabled
        )
    }

    func installViewportGestureRecognizer(_ gesture: UIGestureRecognizer) {
        collectionView.addGestureRecognizer(gesture)
    }

    func setViewportDoubleTapActivation(_ activation: (() -> Void)?) {
        viewportDoubleTapActivation = activation
    }

    private func render(snapshot: ThinkingTraceStream.Snapshot) {
        guard snapshot != renderedSnapshot else {
            tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
            return
        }

        renderedSnapshot = snapshot
        let config = AssistantMarkdownContentView.Configuration.make(
            content: snapshot.text,
            isStreaming: !snapshot.isDone,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: textSelectionEnabled,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSourceContext: reviewCommentSourceContext,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceFilePath: sourceFilePath,
            readerPreferences: readerPreferences,
            perfSurface: perfSurface
        )

        let cycleStart = MarkdownStreamingPerf.timestampNs()
        currentConfig = config
        renderedSegments = segmentSource.buildSegments(
            config,
            mergeAdjacentTextSegments: false
        )
        collectionView.reloadData()
        collectionView.collectionViewLayout.invalidateLayout()

        if let surface = config.perfSurface {
            let elapsed = MarkdownStreamingPerf.timestampNs() - cycleStart
            MarkdownStreamingPerf.recordFullCycle(
                totalNs: elapsed,
                segmentCount: renderedSegments.count,
                isStreaming: config.isStreaming,
                surface: surface
            )
        }

        tailFollowCoordinator.scheduleAutoFollowToBottomIfNeeded()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        renderedSegments.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: FullScreenMarkdownSegmentCell.reuseIdentifier,
            for: indexPath
        )
        guard let cell = cell as? FullScreenMarkdownSegmentCell,
              let config = currentConfig,
              renderedSegments.indices.contains(indexPath.item) else {
            return cell
        }
        cell.apply(
            segment: renderedSegments[indexPath.item],
            config: config,
            textViewDelegate: self,
            doubleTapActivation: viewportDoubleTapActivation,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile
        )
        return cell
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

extension NativeFullScreenMarkdownBody: FullScreenReaderConfigurable {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        collectionView.setCollectionViewLayout(
            Self.makeCollectionLayout(spacing: preferences.spacing.markdownStackSpacing),
            animated: false
        )
        renderedSnapshot = nil
        render(snapshot: latestSnapshot)
        setNeedsLayout()
    }
}

#if DEBUG
extension NativeFullScreenMarkdownBody {
    var debugRenderedSegmentCountForTesting: Int { renderedSegments.count }
    var debugVisibleCellCountForTesting: Int { collectionView.visibleCells.count }

    func debugLayoutVisibleMarkdownCellsForTesting() {
        collectionView.layoutIfNeeded()
    }
}
#endif

extension NativeFullScreenMarkdownBody: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard let config = currentConfig else { return nil }
        return ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: config.reviewCommentSelectionRouter,
            sourceContext: config.reviewCommentSourceContext
        )
    }

    func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
    ) -> UIAction? {
        guard case let .link(url) = textItem.content else {
            return defaultAction
        }

        switch classifyLink(url) {
        case .deepLink(let normalizedURL):
            return UIAction { _ in
                NotificationCenter.default.post(name: .inviteDeepLinkTapped, object: normalizedURL)
            }
        case .webLink(let normalizedURL):
            return UIAction { _ in
                NotificationCenter.default.post(name: .webLinkTapped, object: normalizedURL)
            }
        case .fileLink(let payload):
            return UIAction { _ in
                NotificationCenter.default.post(name: .fileLinkTapped, object: payload)
            }
        case .systemDefault:
            return defaultAction
        }
    }

    func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        guard case let .link(url) = textItem.content else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        switch classifyLink(url) {
        case .webLink(let normalizedURL):
            let copyAction = UIAction(
                title: "Copy Link",
                image: UIImage(systemName: "doc.on.doc")
            ) { _ in
                UIPasteboard.general.string = normalizedURL.absoluteString
            }

            let openAction = UIAction(
                title: AppPreferences.Browser.linkOpeningMode.openActionTitle,
                image: UIImage(systemName: "safari")
            ) { _ in
                NotificationCenter.default.post(name: .webLinkTapped, object: normalizedURL)
            }

            let shareAction = UIAction(
                title: "Share...",
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak textView] _ in
                guard let textView else { return }
                let activityVC = UIActivityViewController(
                    activityItems: [normalizedURL],
                    applicationActivities: nil
                )
                activityVC.popoverPresentationController?.sourceView = textView
                textView.window?.rootViewController?
                    .presentedViewController?.present(activityVC, animated: true)
                    ?? textView.window?.rootViewController?.present(activityVC, animated: true)
            }

            return UITextItem.MenuConfiguration(menu: UIMenu(children: [openAction, copyAction, shareAction]))

        case .fileLink, .deepLink, .systemDefault:
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }
    }

    private func classifyLink(_ url: URL) -> LinkAction {
        let normalizedURL = AssistantMarkdownContentView.normalizedInteractionURL(url)
        guard let scheme = normalizedURL.scheme?.lowercased() else {
            return .systemDefault
        }
        if scheme == "oppi" {
            return .deepLink(normalizedURL)
        }
        if scheme == "http" || scheme == "https" {
            return .webLink(normalizedURL)
        }
        if scheme == WorkspaceWikiLinkURL.scheme,
           let payload = workspaceWikiLinkPayload(for: normalizedURL) {
            return .fileLink(payload)
        }
        if scheme == "file",
           let payload = fileLinkPayload(for: normalizedURL) {
            return .fileLink(payload)
        }
        return .systemDefault
    }

    private func workspaceWikiLinkPayload(for url: URL) -> FileLinkPayload? {
        guard let parsed = WorkspaceWikiLinkURL.parse(url),
              let config = currentConfig,
              parsed.workspaceID == config.workspaceID else {
            return nil
        }

        return FileLinkPayload(
            workspaceID: parsed.workspaceID,
            filePath: parsed.filePath,
            originalURL: url
        )
    }

    private func fileLinkPayload(for url: URL) -> FileLinkPayload? {
        guard url.isFileURL,
              let config = currentConfig,
              let workspaceID = config.workspaceID,
              !workspaceID.isEmpty else {
            return nil
        }

        let filePath = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filePath.isEmpty else { return nil }

        return FileLinkPayload(
            workspaceID: workspaceID,
            filePath: filePath,
            originalURL: url
        )
    }
}

// MARK: - Source Body

final class NativeFullScreenSourceBody: UIView, UITextViewDelegate {
    private let textView = FullScreenReviewCommentTextView()
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private var readerPreferences: FullScreenReaderPreferences
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
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.source.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.readerPreferences = readerPreferences
        self.isStreaming = isStreaming
        super.init(frame: .zero)

        backgroundColor = UIColor(palette.bgDark)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = codeFont
        textView.textColor = UIColor(palette.fg)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        textView.delegate = self
        textView.text = content
        textView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
        applyWrapMode()
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
        applyWrapMode()
        tailFollowCoordinator.onLayoutPass()
    }

    private var codeFont: UIFont {
        FullScreenCodeTypography.codeFont(for: readerPreferences)
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



    private func applyTextSize() {
        textView.font = codeFont
    }

    private func applyWrapMode() {
        let wraps = readerPreferences.wrapsText
        textView.textContainer.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        textView.textContainer.widthTracksTextView = wraps
        textView.textContainer.size = wraps
            ? CGSize(width: max(1, textView.bounds.width), height: CGFloat.greatestFiniteMagnitude)
            : CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.alwaysBounceHorizontal = !wraps
        textView.showsHorizontalScrollIndicator = !wraps
        if wraps {
            textView.contentOffset.x = -textView.adjustedContentInset.left
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        (textView as? FullScreenReviewCommentTextView)?.reviewCommentSelectionDidChange()
    }

    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        buildFullScreenReviewCommentMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
    }
}

extension NativeFullScreenSourceBody: FullScreenReaderConfigurable {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        readerPreferences = preferences
        applyTextSize()
        applyWrapMode()
        textView.invalidateIntrinsicContentSize()
        setNeedsLayout()
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
    private let readerPreferences: FullScreenReaderPreferences

    init(
        content: DocumentContent,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.renderedDocument.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.readerPreferences = readerPreferences
        super.init(frame: .zero)
        backgroundColor = UIColor(palette.bgDark)

        switch content {
        case .mermaid(let text):
            // ZoomableGraphicalView has its own scroll + zoom — embed directly
            let zoomable = makeZoomableGraphicalView(
                parser: MermaidParser(), renderer: MermaidFlowchartRenderer(),
                text: text, fontSize: 14 * readerPreferences.textScale
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
                // Pin content width to the scroll view's visible frame width minus
                // horizontal padding (14 * 2 = 28). Without this, text-based content
                // views (e.g. AssistantMarkdownContentView for org mode) have no width
                // reference inside the scroll view's content layout guide and collapse
                // to their intrinsic content width.
                contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -28),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func makeLatexView(text: String) -> UIView {
        let config = RenderConfiguration(
            fontSize: 20 * readerPreferences.textScale,
            maxWidth: 800,
            theme: ThemeRuntimeState.currentRenderTheme(),
            displayMode: .document
        )
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
        mdView.apply(configuration: .make(
            content: markdownText,
            isStreaming: false,
            themeID: ThemeRuntimeState.currentThemeID(),
            textSelectionEnabled: true,
            readerPreferences: readerPreferences
        ))
        return mdView
    }

    private func makeZoomableGraphicalView<P: DocumentParser, R: GraphicalDocumentRenderer>(
        parser: P, renderer: R, text: String, fontSize: CGFloat
    ) -> UIView where P.Document == R.Document {
        let config = RenderConfiguration(
            fontSize: fontSize,
            maxWidth: 800,
            theme: ThemeRuntimeState.currentRenderTheme(),
            displayMode: .document
        )
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: parser, renderer: renderer, text: text, config: config
        )
        return ZoomableGraphicalView(size: layout.size, draw: layout.draw)
    }
}
