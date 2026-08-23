import SwiftUI
import UIKit
import WebKit

// MARK: - Code Body

private final class CodeLineNumberGutterView: UIView {
    struct Row: Equatable {
        let text: String
        let y: CGFloat
        let height: CGFloat
        let isHighlighted: Bool
        let showsHighlightMarker: Bool
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
            if row.isHighlighted && row.showsHighlightMarker {
                let markerRect = CGRect(
                    x: 1,
                    y: row.y + max(0, (row.height - font.lineHeight) / 2),
                    width: min(8, bounds.width),
                    height: font.lineHeight
                )
                let markerAttributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                ]
                ("▸" as NSString).draw(
                    with: markerRect,
                    options: [.usesLineFragmentOrigin],
                    attributes: markerAttributes,
                    context: nil
                )
            }
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
    private let lineAnchor: SourceLineAnchor?
    private let lineAnchorResolution: SourceLineAnchorResolution?
    private let alwaysBounceVertical: Bool
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private var readerPreferences: FullScreenReaderPreferences
    private var gutterWidthConstraint: NSLayoutConstraint?
    private var contentContainerWidthConstraint: NSLayoutConstraint?
    private var highlightedSourceText: NSAttributedString?
    private var lastGutterLayoutSignature: GutterLayoutSignature?
    private var highlightTask: Task<Void, Never>?
    private var lineAnchorFocusTask: Task<Void, Never>?
    private var lineAnchorFocusPending = false

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
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        lineAnchor: SourceLineAnchor? = nil,
        focusLineAnchor: Bool = true
    ) {
        let actualLineCount = SourceLineMetrics.count(content)
        let lineCount = max(1, actualLineCount)
        self.content = content
        self.language = language
        self.startLine = startLine
        self.lineCount = lineCount
        self.palette = palette
        self.lineAnchor = lineAnchor
        self.lineAnchorResolution = lineAnchor?.resolution(
            fileContent: content,
            firstFileLine: startLine
        )
        self.alwaysBounceVertical = alwaysBounceVertical
        self.readerPreferences = readerPreferences
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext?.withLineRange(
            startLine...(startLine + lineCount - 1)
        )
        self.lineAnchorFocusPending = lineAnchor != nil && focusLineAnchor
        super.init(frame: .zero)
        setup()
        loadHighlighting()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        highlightTask?.cancel()
        lineAnchorFocusTask?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.layoutIfNeeded()
        contentContainer.layoutIfNeeded()
        updateGutterForCurrentLayout()
        updateLineAnchorHighlight()
        scheduleLineAnchorFocusIfNeeded()
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

        let (_, baseGutterWidth) = lineNumberInfo(
            lineCount: lineCount,
            startLine: startLine,
            font: codeFont
        )
        let gutterWidth = baseGutterWidth + (lineAnchor == nil ? 0 : 10)

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
        if let lineAnchorResolution {
            codeTextView.accessibilityLabel = "Source code"
            codeTextView.accessibilityValue = lineAnchorResolution.accessibilityLabel
        }
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

        let (_, baseGutterWidth) = lineNumberInfo(
            lineCount: lineCount,
            startLine: startLine,
            font: font
        )
        gutterWidthConstraint?.constant = baseGutterWidth + (lineAnchor == nil ? 0 : 10)

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

    private func updateLineAnchorHighlight() {
        guard let resolution = lineAnchorResolution,
              let existingRange = resolution.existingRange else {
            codeTextView.setLineAnchorHighlight(
                rects: [],
                fillColor: UIColor(palette.blue).withAlphaComponent(0.08),
                strokeColor: UIColor(palette.blue).withAlphaComponent(0.75)
            )
            return
        }

        let layout = FullScreenLineAnchorLayout.layout(
            for: codeTextView,
            sourceLineRange: existingRange,
            startLine: startLine
        )
        codeTextView.setLineAnchorHighlight(
            rects: layout.visibleRects,
            firstRect: layout.firstVisibleRect,
            fillColor: UIColor(palette.blue).withAlphaComponent(0.08),
            strokeColor: UIColor(palette.blue).withAlphaComponent(0.75)
        )
    }

    private func scheduleLineAnchorFocusIfNeeded() {
        guard lineAnchorFocusPending, lineAnchorFocusTask == nil else { return }
        lineAnchorFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.lineAnchorFocusTask = nil
            guard self.scrollView.bounds.height > 0 else {
                self.lineAnchorFocusPending = true
                return
            }
            self.lineAnchorFocusPending = false
            self.scrollLineAnchorIntoUpperThird()
        }
    }

    private func scrollLineAnchorIntoUpperThird() {
        guard lineAnchorResolution != nil, scrollView.bounds.height > 0 else { return }
        scrollView.layoutIfNeeded()
        contentContainer.layoutIfNeeded()

        let targetY: CGFloat
        if let existingRange = lineAnchorResolution?.existingRange {
            let layout = FullScreenLineAnchorLayout.layout(
                for: codeTextView,
                sourceLineRange: existingRange,
                startLine: startLine
            )
            if let firstRect = layout.firstContentRect {
                let rectInContainer = firstRect.offsetBy(
                    dx: codeTextView.frame.minX,
                    dy: codeTextView.frame.minY
                )
                targetY = rectInContainer.minY - scrollView.bounds.height / 3
            } else {
                targetY = scrollView.contentSize.height
            }
        } else {
            targetY = scrollView.contentSize.height
        }

        let minimumY = -scrollView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height
                - scrollView.bounds.height
                + scrollView.adjustedContentInset.bottom
        )
        let clampedY = min(max(targetY, minimumY), maximumY)
        guard clampedY.isFinite else { return }
        scrollView.setContentOffset(
            CGPoint(x: scrollView.contentOffset.x, y: clampedY),
            animated: false
        )
        updateLineAnchorHighlight()
        if let resolution = lineAnchorResolution {
            UIAccessibility.post(
                notification: .layoutChanged,
                argument: codeTextView
            )
            codeTextView.accessibilityValue = resolution.accessibilityLabel
        }
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
        let lineRanges = SourceLineMetrics.logicalLineContentRanges(in: source)
        var rows: [CodeLineNumberGutterView.Row] = []
        rows.reserveCapacity(lineRanges.count)
        // The enclosure carries the continuous range; keep one gutter glyph at
        // its first existing line instead of repeating ▸ per row.
        let highlightMarkerLine = lineAnchorResolution?.existingRange?.lowerBound

        var fallbackY: CGFloat = 0
        for (offset, range) in lineRanges.enumerated() {
            let fragmentRect = firstLineFragmentRect(
                for: range,
                layoutManager: layoutManager,
                fallbackY: fallbackY
            )
            fallbackY = fragmentRect.maxY

            let sourceLine = startLine + offset
            rows.append(CodeLineNumberGutterView.Row(
                text: String(sourceLine),
                y: codeTextView.textContainerInset.top + fragmentRect.minY,
                height: max(codeFont.lineHeight, fragmentRect.height),
                isHighlighted: lineAnchorResolution?.existingRange?.contains(sourceLine) == true,
                showsHighlightMarker: sourceLine == highlightMarkerLine
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

#if DEBUG
    var debugLineAnchorRequestedRangeForTesting: ClosedRange<Int>? {
        lineAnchorResolution?.requestedRange
    }

    var debugLineAnchorExistingRangeForTesting: ClosedRange<Int>? {
        lineAnchorResolution?.existingRange
    }

    var debugLineAnchorHighlightRectCountForTesting: Int {
        codeTextView.debugLineAnchorHighlightRectCountForTesting
    }

    var debugLineAnchorFirstHighlightRectForTesting: CGRect? {
        codeTextView.debugLineAnchorFirstHighlightRectForTesting
    }

    var debugLineAnchorHighlightEnclosureRectForTesting: CGRect? {
        codeTextView.debugLineAnchorHighlightEnclosureRectForTesting
    }

    var debugLineAnchorHighlightHasVisibleGeometryForTesting: Bool {
        guard codeTextView.debugLineAnchorHighlightContainsFirstTargetForTesting,
              let rect = debugLineAnchorHighlightEnclosureRectForTesting,
              rect.width > 0,
              rect.height > 0 else {
            return false
        }
        let rectInBody = codeTextView.convert(rect, to: self)
        let viewportInBody = scrollView.convert(scrollView.bounds, to: self)
        return !rectInBody.intersection(viewportInBody).isEmpty
    }

    var debugLineAnchorGutterMarkerCountForTesting: Int {
        layoutIfNeeded()
        updateGutterForCurrentLayout()
        return gutterView.rows.filter(\.showsHighlightMarker).count
    }

    var debugLineAnchorScrollOffsetForTesting: CGPoint {
        scrollView.contentOffset
    }

    var debugLineAnchorViewportHeightForTesting: CGFloat {
        scrollView.bounds.height
    }

    var debugLineAnchorContentHeightForTesting: CGFloat {
        scrollView.contentSize.height
    }

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
        let hunks = WorkspaceReviewDiffHunkBuilder.buildHunks(from: lines, withWordSpans: true)
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
        applyDiffParagraphStyles(to: mutable, lineBreakMode: lineBreakMode)
        return mutable
    }

    private func applyDiffParagraphStyles(
        to attributedText: NSMutableAttributedString,
        lineBreakMode: NSLineBreakMode
    ) {
        let source = attributedText.string as NSString
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

            let paragraphRange = NSRange(location: location, length: max(0, lineEnd - location))
            guard paragraphRange.length > 0 else { break }

            let style = (attributedText.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineBreakMode = lineBreakMode
            if readerPreferences.wrapsText,
               let indent = Self.diffCodeColumnIndent(in: attributedText, lineStart: location, contentsEnd: contentsEnd) {
                style.firstLineHeadIndent = 0
                style.headIndent = indent
            } else {
                style.firstLineHeadIndent = 0
                style.headIndent = 0
            }
            attributedText.addAttribute(.paragraphStyle, value: style, range: paragraphRange)

            guard lineEnd > location else { break }
            location = lineEnd
        }
    }

    private static func diffCodeColumnIndent(
        in attributedText: NSAttributedString,
        lineStart: Int,
        contentsEnd: Int
    ) -> CGFloat? {
        guard contentsEnd > lineStart else { return nil }
        let contentsRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        var codeStart: Int?
        attributedText.enumerateAttribute(diffCodeColumnAttributeKey, in: contentsRange) { value, range, stop in
            guard value != nil else { return }
            codeStart = range.location
            stop.pointee = true
        }
        guard let codeStart, codeStart > lineStart else { return nil }

        let prefixRange = NSRange(location: lineStart, length: codeStart - lineStart)
        let measured = attributedText.attributedSubstring(from: prefixRange).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        )
        return ceil(measured.width)
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

#if DEBUG
extension NativeFullScreenDiffBody {
    struct DiffWrappingDiagnostics: Equatable {
        let wrapsText: Bool
        let textContainerLineBreakMode: NSLineBreakMode
        let paragraphLineBreakMode: NSLineBreakMode?
        let paragraphHeadIndent: CGFloat
        let expectedCodeColumnX: CGFloat
        let fragmentCount: Int
        let firstFragmentX: CGFloat
        let secondFragmentX: CGFloat?
    }

    func diffWrappingDiagnosticsForTesting() -> DiffWrappingDiagnostics? {
        layoutIfNeeded()
        diffTextView.layoutIfNeeded()
        diffTextView.layoutManager.ensureLayout(for: diffTextView.textContainer)

        let attributedText = diffTextView.attributedText ?? NSAttributedString()
        let source = attributedText.string as NSString
        var fallback: DiffWrappingDiagnostics?
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
            if let diagnostics = diffWrappingDiagnosticsForLine(
                attributedText: attributedText,
                lineStart: location,
                contentsEnd: contentsEnd
            ) {
                if diagnostics.fragmentCount >= 2 {
                    return diagnostics
                }
                if fallback == nil {
                    fallback = diagnostics
                }
            }
            guard lineEnd > location else { break }
            location = lineEnd
        }
        return fallback
    }

    private func diffWrappingDiagnosticsForLine(
        attributedText: NSAttributedString,
        lineStart: Int,
        contentsEnd: Int
    ) -> DiffWrappingDiagnostics? {
        guard contentsEnd > lineStart,
              let expectedIndent = Self.diffCodeColumnIndent(
                in: attributedText,
                lineStart: lineStart,
                contentsEnd: contentsEnd
              ) else { return nil }

        let contentsRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        let glyphRange = diffTextView.layoutManager.glyphRange(
            forCharacterRange: contentsRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        var fragmentXs: [CGFloat] = []
        diffTextView.layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            let intersection = NSIntersectionRange(glyphRange, lineGlyphRange)
            guard intersection.length > 0 else { return }
            fragmentXs.append(usedRect.minX)
        }
        guard let firstFragmentX = fragmentXs.first else { return nil }

        let paragraphStyle = attributedText.attribute(
            .paragraphStyle,
            at: lineStart,
            effectiveRange: nil
        ) as? NSParagraphStyle

        return DiffWrappingDiagnostics(
            wrapsText: readerPreferences.wrapsText,
            textContainerLineBreakMode: diffTextView.textContainer.lineBreakMode,
            paragraphLineBreakMode: paragraphStyle?.lineBreakMode,
            paragraphHeadIndent: paragraphStyle?.headIndent ?? 0,
            expectedCodeColumnX: expectedIndent,
            fragmentCount: fragmentXs.count,
            firstFragmentX: firstFragmentX,
            secondFragmentX: fragmentXs.dropFirst().first
        )
    }
}
#endif

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
    private var stackLeadingConstraint: NSLayoutConstraint?

    private lazy var segmentApplier = AssistantMarkdownSegmentApplier(
        stackView: stackView,
        textViewDelegate: self
    )

    private weak var textViewDelegate: (any UITextViewDelegate)?
    private var doubleTapActivation: (() -> Void)?
    /// Index last configured on this cell so reuse can park its segment views
    /// onto the reader host instead of destroying them.
    fileprivate var appliedItemIndex: Int?
    fileprivate var appliedSegmentID: MarkdownReaderSegmentID?
    fileprivate var parkHandler: ((FullScreenMarkdownSegmentCell) -> Void)?
    private(set) var isGeometryPresentationReady = true
    /// Guards against re-entrant self-sizing. UICollectionView calls
    /// `preferredLayoutAttributesFitting` inside its own layout pass; when the
    /// cell held a large streaming markdown segment, forcing a synchronous
    /// `layoutIfNeeded()` here re-entered that pass and recursed until the
    /// thread stack overflowed (MetricKit badAccess in the stack-guard page).
    private var isMeasuringLayout = false
    private var lastMeasuredAttributes: UICollectionViewLayoutAttributes?
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
        stackView.setContentHuggingPriority(.required, for: .vertical)
        stackView.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.addGestureRecognizer(doubleTapRecognizer)
        contentView.addSubview(stackView)
        let stackLeadingConstraint = stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        self.stackLeadingConstraint = stackLeadingConstraint
        NSLayoutConstraint.activate([
            stackLeadingConstraint,
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
    }

    override func prepareForReuse() {
        parkHandler?(self)
        super.prepareForReuse()
        appliedItemIndex = nil
        appliedSegmentID = nil
        parkHandler = nil
        setGeometryPresentationReady(true)
        textViewDelegate = nil
        doubleTapActivation = nil
        segmentApplier.clear()
    }

    fileprivate func yieldArrangedSegmentViews() -> [UIView] {
        let views = stackView.arrangedSubviews
        for view in views {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        return views
    }

    fileprivate func resetApplierAfterYield() {
        segmentApplier.clear()
    }

    fileprivate func installArrangedSegmentViews(_ views: [UIView]) {
        for existing in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(view)
            if let textView = view as? BaselineSafeTextView {
                textView.delegate = self
            }
            if let imageView = view as? NativeMarkdownImageView {
                imageView.activatePreparedDisplay()
            }
        }
        stackView.invalidateIntrinsicContentSize()
        contentView.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    fileprivate func observePreparedImageGeometry(_ handler: @escaping (CGFloat) -> Void) {
        segmentApplier.onImagePreparedGeometry = handler
        for view in stackView.arrangedSubviews {
            if let imageView = view as? NativeMarkdownImageView {
                imageView.onPreparedGeometry = handler
            }
        }
    }

    fileprivate func setGeometryPresentationReady(_ isReady: Bool) {
        guard isGeometryPresentationReady != isReady else { return }
        isGeometryPresentationReady = isReady
        contentView.alpha = isReady ? 1 : 0
        contentView.accessibilityElementsHidden = !isReady
    }

    fileprivate func bindReaderChrome(
        lineAnchorModeEnabled: Bool,
        textViewDelegate: any UITextViewDelegate,
        doubleTapActivation: (() -> Void)?,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    ) {
        // The source-line enclosure is painted by the reader's overlay. Keep
        // the arranged content at the ledger's canonical width instead of
        // consuming 28 points here after graphical artifacts were prepared.
        stackLeadingConstraint?.constant = 0
        _ = lineAnchorModeEnabled
        self.textViewDelegate = textViewDelegate
        self.doubleTapActivation = doubleTapActivation
        segmentApplier.fetchWorkspaceFile = fetchWorkspaceFile
        segmentApplier.fetchSessionFile = fetchSessionFile
    }

    func apply(
        segment: FlatSegment,
        config: AssistantMarkdownContentView.Configuration,
        sourceLineRange: ClosedRange<Int>?,
        lineAnchorModeEnabled: Bool,
        palette: ThemePalette,
        textViewDelegate: any UITextViewDelegate,
        doubleTapActivation: (() -> Void)?,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?,
        canonicalWidth: CGFloat? = nil,
        preparesImagesForDisplay: Bool = true
    ) {
        // Source-line chrome overlays the cell; arranged content always uses
        // the same canonical width used by the ledger and artifact renderers.
        stackLeadingConstraint?.constant = 0
        _ = lineAnchorModeEnabled
        self.textViewDelegate = textViewDelegate
        self.doubleTapActivation = doubleTapActivation
        segmentApplier.fetchWorkspaceFile = fetchWorkspaceFile
        segmentApplier.fetchSessionFile = fetchSessionFile
        segmentApplier.preparationWidth = canonicalWidth
        segmentApplier.preparesImagesForDisplay = preparesImagesForDisplay
        if let canonicalWidth {
            bounds.size.width = canonicalWidth
            contentView.bounds.size.width = canonicalWidth
            stackView.bounds.size.width = canonicalWidth
        }
        segmentApplier.apply(
            segments: [segment],
            config: config,
            sourceLineRanges: [sourceLineRange]
        )
        stackView.invalidateIntrinsicContentSize()
        contentView.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        // Break any residual self-sizing recursion: if UIKit re-enters while we
        // are already measuring, hand back the last result instead of forcing
        // another synchronous layout.
        if isMeasuringLayout {
            return lastMeasuredAttributes ?? super.preferredLayoutAttributesFitting(layoutAttributes)
        }
        isMeasuringLayout = true
        defer { isMeasuringLayout = false }

        let attributes = super.preferredLayoutAttributesFitting(layoutAttributes)
        let width = layoutAttributes.size.width
        if bounds.size.width != width {
            bounds.size.width = width
        }
        if contentView.bounds.size.width != width {
            contentView.bounds.size.width = width
        }

        // `systemLayoutSizeFitting` runs the Auto Layout solve internally, so we
        // do not need (and must not force) a `layoutIfNeeded()` pass here — that
        // was the re-entrancy trigger behind the streaming stack overflow.
        let targetSize = CGSize(
            width: width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let size = stackView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        attributes.size = CGSize(width: width, height: ceil(max(1, size.height)))
        lastMeasuredAttributes = attributes
        return attributes
    }

    fileprivate func measuredFittingHeight(width: CGFloat) -> CGFloat {
        let targetWidth = max(1, width)
        if bounds.size.width != targetWidth {
            bounds.size.width = targetWidth
        }
        if contentView.bounds.size.width != targetWidth {
            contentView.bounds.size.width = targetWidth
        }
        let targetSize = CGSize(
            width: targetWidth,
            height: UIView.layoutFittingCompressedSize.height
        )
        let size = stackView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return ceil(max(1, size.height))
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

/// Runs detached work while propagating cancellation from the awaiting parent task.
///
/// `Task.detached` does not inherit cancellation from the caller. Use this for
/// expensive full-screen renderer work so closing or replacing a reader cancels
/// the background build instead of letting stale parses pile up.
func withCancellableDetachedTask<Value: Sendable>(
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable () async -> Value?
) async -> Value? {
    let task = Task.detached(priority: priority, operation: operation)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

enum MarkdownReaderSourceFormat: Sendable {
    case markdown
    case orgMode
}

final class NativeFullScreenMarkdownBody: UIView, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
    private static let deferredInitialRenderByteThreshold = 200 * 1024
    private static let maxInitialSynchronousPreparationItems = 8
    private static let maxInitialSynchronousPreparationNs: UInt64 = 8_000_000
    // Give UIKit/XCUITest and real users a visible reader shell before the large
    // CommonMark pass starts for huge completed documents.
    private static let deferredInitialRenderDelayMs = 750

    private let collectionView: UICollectionView
    private let lineAnchorHighlightView = FullScreenLineAnchorHighlightOverlayView()
    /// Holds configured segment views after their cells are recycled so the
    /// document stays inspectable (and find-in-page complete) after a tail scroll.
    private let parkedSegmentHost: UIView = {
        let view = UIView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }()
    private var parkedSegmentViews: [MarkdownReaderSegmentID: [UIView]] = [:]
    private var itemHeights: [CGFloat] = []
    /// Heights captured by the currently installed compositional layout. The
    /// ledger may advance while interaction defers replacement, so tests and
    /// anchor math must not treat pending heights as active attributes.
    private var activeLayoutItemHeights: [CGFloat] = []
    private var heightLedger = MarkdownReaderHeightLedger()
    private var preparedCanonicalWidth: CGFloat?
    private var needsDocumentLayoutPreparation = false
    private var pendingDocumentAppendOnly = false
    private var pendingDocumentLayoutReason: MarkdownReaderLayoutReplacementReason = .document
    private var retainedSegmentIDsForNextLayout: Set<MarkdownReaderSegmentID> = []
    private var isConfiguringCell = false
    private var pendingHeightFlush = false
    private var heightFlushGeneration = 0
    private var needsLayoutReplaceAfterInteraction = false
    private var needsVisibleHeightRefreshAfterInteraction = false
    private var pendingLayoutReplaceAfterInteractionRetry = false
    private var isReplacingCollectionLayout = false
    #if DEBUG
    private var debugIsCollectionUserInteractingOverride: Bool?
    #endif
    /// After a snapshot rebuild, `reloadData` can land in a later layout pass.
    /// Ignore parked views until that pass applies the new segments.
    private var suppressParkedReinstall = false
    #if DEBUG
    private var debugAppliedItems: Set<Int> = []
    private var debugSegmentBuildNs: UInt64 = 0
    private var debugHeightEstimateNs: UInt64 = 0
    private var debugLayoutSetupNs: UInt64 = 0
    private var debugVisibleApplyNs: UInt64 = 0
    private var debugVisibleTextApplyNs: UInt64 = 0
    private var debugVisibleNonTextApplyNs: UInt64 = 0
    private var debugVisibleTextApplyCount = 0
    private var debugVisibleNonTextApplyCount = 0
    private var debugDeferredFitNs: UInt64 = 0
    private var debugLayoutReplaceCount = 0
    private var debugLayoutReplacementReasons: [MarkdownReaderLayoutReplacementReason] = []
    private var debugGeometryCommitCount = 0
    private var debugWillDisplayRenderAheadMissCount = 0
    private var debugVisibleHeightCorrectionDuringInteractionCount = 0
    private var debugOffsetWriteReasons: [MarkdownReaderOffsetWriteReason] = []
    private var debugIsPerformingDirectScroll = false
    private var debugIsInsideScrollCallback = false
    private var debugSynchronousScrollSettlementCount = 0
    private var debugMaxRenderAheadItemsPerSlice = 0
    private var debugInitialSynchronousPreparationItemCount = 0
    private var debugSourcePreparationRanOnMainThread: Bool?
    private var debugSourcePreparationDurationNs: UInt64 = 0
    private var debugAsyncMarkdownBuildRanOnMainThread: Bool?
    #endif
    private let segmentSource = AssistantMarkdownSegmentSource()
    private let stream: ThinkingTraceStream?
    private let sourceFormat: MarkdownReaderSourceFormat
    private let themeID: ThemeID
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?
    private var textSelectionEnabled: Bool
    private let serverID: String?
    private let workspaceID: String?
    private let sessionID: String?
    private let serverBaseURL: URL?
    private let sourceFilePath: String?
    private let lineAnchor: SourceLineAnchor?
    private let lineAnchorResolution: SourceLineAnchorResolution?
    private let fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)?
    private let fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)?
    private let maximumViewportHeight: CGFloat?
    private var intrinsicViewportContentHeight: CGFloat = 44
    private var readerPreferences: FullScreenReaderPreferences

    private let perfSurface: MarkdownStreamingPerf.Surface?

    private var sourcePreparationTask: Task<Void, Never>?
    private var deferredInitialRenderTask: Task<Void, Never>?
    private var asyncRenderTask: Task<Void, Never>?
    private var renderAheadTask: Task<Void, Never>?
    private var latestSnapshot: ThinkingTraceStream.Snapshot
    private var pendingInteractionSnapshot: ThinkingTraceStream.Snapshot?
    private var pendingReaderPreferences: FullScreenReaderPreferences?
    private var renderedSnapshot: ThinkingTraceStream.Snapshot?
    /// Configuration can change while the source snapshot stays byte-identical.
    /// Keep that independent from `renderedSnapshot` so append detection and
    /// interaction deferral retain the mounted document.
    private var needsSnapshotReconfiguration = false
    private var pendingReconfigurationLayoutReason: MarkdownReaderLayoutReplacementReason?
    private var renderedSegments: [FlatSegment] = []
    private var renderedSegmentLineRanges: [ClosedRange<Int>?] = []
    private var renderedSegmentIDs: [MarkdownReaderSegmentID] = []
    private var renderedSegmentRevisions: [Int] = []
    private var nextSegmentRevision = 0
    private var currentConfig: AssistantMarkdownContentView.Configuration?
    private var viewportDoubleTapActivation: (() -> Void)?
    private var streamObserverID: UUID?
    private var lineAnchorFocusTask: Task<Void, Never>?
    private var lineAnchorFocusPending = false

    private struct AsyncMarkdownBuild: Sendable {
        let build: FlatSegment.BuildResult
        let parseDurationNs: UInt64
        let buildDurationNs: UInt64
        let lineCount: Int
        let ranOnMainThread: Bool
    }

    private lazy var viewportOwner = MarkdownReaderViewportOwner(
        scrollView: collectionView,
        followsTail: !latestSnapshot.isDone,
        performLayout: { [weak self] in
            self?.layoutIfNeeded()
        }
    )

    init(
        content: String,
        stream: ThinkingTraceStream?,
        isStreaming: Bool = false,
        sourceFormat: MarkdownReaderSourceFormat = .markdown,
        themeID: ThemeID? = nil,
        palette: ThemePalette,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool = true,
        serverID: String? = nil,
        workspaceID: String? = nil,
        sessionID: String? = nil,
        serverBaseURL: URL? = nil,
        sourceFilePath: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        focusLineAnchor: Bool = true,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.markdown.defaultPreferences,
        perfSurface: MarkdownStreamingPerf.Surface? = nil,
        maximumViewportHeight: CGFloat? = nil,
        allowsVerticalBounce: Bool = true,
        allowsVerticalScrolling: Bool = true,
        fetchWorkspaceFile: ((_ workspaceID: String, _ path: String) async throws -> Data)? = nil,
        fetchSessionFile: ((_ workspaceID: String, _ sessionID: String, _ path: String) async throws -> Data)? = nil
    ) {
        self.stream = stream
        self.sourceFormat = sourceFormat
        self.themeID = themeID ?? ThemeRuntimeState.currentThemeID()
        self.perfSurface = perfSurface
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.textSelectionEnabled = textSelectionEnabled
        self.serverID = serverID
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.serverBaseURL = serverBaseURL
        self.sourceFilePath = sourceFilePath
        self.lineAnchor = lineAnchor
        let initialText = stream?.snapshot.text ?? content
        self.lineAnchorResolution = lineAnchor?.resolution(fileContent: initialText)
        self.readerPreferences = readerPreferences
        self.maximumViewportHeight = maximumViewportHeight
        self.fetchWorkspaceFile = fetchWorkspaceFile
        self.fetchSessionFile = fetchSessionFile
        self.lineAnchorFocusPending = lineAnchor != nil && focusLineAnchor
        let sourceSnapshot = stream?.snapshot
            ?? ThinkingTraceStream.Snapshot(text: content, isDone: !isStreaming)
        let initialSnapshot = sourceFormat == .markdown
            ? sourceSnapshot
            : ThinkingTraceStream.Snapshot(text: "", isDone: true)
        latestSnapshot = initialSnapshot
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: Self.makeCollectionLayout(
                spacing: readerPreferences.spacing.markdownStackSpacing,
                itemHeights: []
            )
        )

        super.init(frame: .zero)
        _ = viewportOwner
        #if DEBUG
        viewportOwner.onOffsetWrite = { [weak self] reason, _, _ in
            self?.debugOffsetWriteReasons.append(reason)
        }
        #endif

        backgroundColor = UIColor(palette.bgDark)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = UIColor(palette.bgDark)
        collectionView.alwaysBounceVertical = allowsVerticalBounce && allowsVerticalScrolling
        collectionView.bounces = allowsVerticalBounce && allowsVerticalScrolling
        collectionView.isScrollEnabled = allowsVerticalScrolling
        collectionView.showsVerticalScrollIndicator = allowsVerticalScrolling
        collectionView.keyboardDismissMode = .interactive
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.panGestureRecognizer.addTarget(
            self,
            action: #selector(handleCollectionPanStateChange(_:))
        )
        collectionView.register(
            FullScreenMarkdownSegmentCell.self,
            forCellWithReuseIdentifier: FullScreenMarkdownSegmentCell.reuseIdentifier
        )
        if let lineAnchorResolution {
            collectionView.accessibilityLabel = "Rendered Markdown"
            collectionView.accessibilityValue = lineAnchorResolution.accessibilityLabel
        }

        addSubview(collectionView)
        addSubview(parkedSegmentHost)

        lineAnchorHighlightView.translatesAutoresizingMaskIntoConstraints = false
        lineAnchorHighlightView.isUserInteractionEnabled = false
        lineAnchorHighlightView.isHidden = true
        lineAnchorHighlightView.backgroundColor = .clear
        lineAnchorHighlightView.isOpaque = false
        addSubview(lineAnchorHighlightView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            lineAnchorHighlightView.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            lineAnchorHighlightView.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            lineAnchorHighlightView.topAnchor.constraint(equalTo: collectionView.topAnchor),
            lineAnchorHighlightView.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
        ])

        if sourceFormat == .orgMode {
            installDeferredRenderPlaceholder(palette: palette)
            scheduleOrgModeSourcePreparation(source: sourceSnapshot.text)
        } else if Self.shouldDeferInitialRender(snapshot: initialSnapshot, stream: stream) {
            installDeferredRenderPlaceholder(palette: palette)
            scheduleDeferredInitialRender(snapshot: initialSnapshot)
        } else {
            render(snapshot: initialSnapshot)
        }

        guard let stream else { return }
        streamObserverID = stream.addObserver { [weak self] snapshot in
            self?.handleStreamUpdate(snapshot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        guard let maximumViewportHeight else { return super.intrinsicContentSize }
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: min(maximumViewportHeight, intrinsicViewportContentHeight)
        )
    }

    override var accessibilityIdentifier: String? {
        didSet {
            collectionView.accessibilityIdentifier = accessibilityIdentifier
        }
    }

    deinit {
        sourcePreparationTask?.cancel()
        deferredInitialRenderTask?.cancel()
        asyncRenderTask?.cancel()
        renderAheadTask?.cancel()
        lineAnchorFocusTask?.cancel()
        if let streamObserverID {
            let stream = stream
            Task { @MainActor in
                stream?.removeObserver(streamObserverID)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        suppressParkedReinstall = false
        if needsDocumentLayoutPreparation
            || preparedCanonicalWidth.map({ abs($0 - canonicalContentWidth) > 0.5 }) == true {
            prepareLazyDocumentLayout(
                appendOnly: pendingDocumentAppendOnly,
                layoutReason: pendingDocumentLayoutReason
            )
        }
        retryDeferredLayoutReplaceIfInteractionEnded()
        updateLineAnchorHighlight()
        scheduleLineAnchorFocusIfNeeded()
        viewportOwner.scheduleFollowTail()
    }

    private static func shouldDeferInitialRender(
        snapshot: ThinkingTraceStream.Snapshot,
        stream: ThinkingTraceStream?
    ) -> Bool {
        stream == nil
            && snapshot.isDone
            && snapshot.text.utf8.count >= deferredInitialRenderByteThreshold
    }

    private static func makeCollectionLayout(
        spacing: CGFloat,
        itemHeights: [CGFloat]
    ) -> UICollectionViewLayout {
        var cachedSection: NSCollectionLayoutSection?
        return UICollectionViewCompositionalLayout { _, _ in
            // Heights are fixed absolute values, so the section is identical
            // on every layout pass. Build the item group once.
            if let cachedSection { return cachedSection }
            let heights = itemHeights.isEmpty ? [CGFloat(44)] : itemHeights
            let items = heights.map { height in
                NSCollectionLayoutItem(
                    layoutSize: NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1.0),
                        heightDimension: .absolute(max(1, height))
                    )
                )
            }
            let totalHeight = heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1))
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .absolute(max(1, totalHeight))
                ),
                subitems: items
            )
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 10,
                leading: 12,
                bottom: 10,
                trailing: 12
            )
            cachedSection = section
            return section
        }
    }

    private func installDeferredRenderPlaceholder(palette: ThemePalette) {
        let label = UILabel()
        label.text = String(localized: "Preparing preview…")
        label.textColor = UIColor(palette.fgDim)
        label.font = AppFont.systemFeedback
        label.textAlignment = .center
        label.numberOfLines = 0
        collectionView.backgroundView = label
    }

    private struct PreparedOrgModeSource: Sendable {
        let markdown: String
        let ranOnMainThread: Bool
        let durationNs: UInt64
    }

    nonisolated private static func isMainThreadForDiagnostics() -> Bool {
        Thread.isMainThread
    }

    nonisolated private static func prepareOrgModeSource(_ source: String) -> PreparedOrgModeSource? {
        let started = DispatchTime.now().uptimeNanoseconds
        let ranOnMainThread = Thread.isMainThread
        guard let markdown = DocumentRenderPipeline.orgToMarkdown(
            source,
            cancellationCheck: { Task<Never, Never>.isCancelled }
        ) else { return nil }
        return PreparedOrgModeSource(
            markdown: markdown,
            ranOnMainThread: ranOnMainThread,
            durationNs: DispatchTime.now().uptimeNanoseconds - started
        )
    }

    private func scheduleOrgModeSourcePreparation(source: String) {
        sourcePreparationTask?.cancel()
        sourcePreparationTask = Task { @MainActor [weak self] in
            let prepared: PreparedOrgModeSource? = await withCancellableDetachedTask(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil }
                return Self.prepareOrgModeSource(source)
            }
            guard let self, let prepared, !Task.isCancelled else { return }
            self.sourcePreparationTask = nil
            #if DEBUG
            self.debugSourcePreparationRanOnMainThread = prepared.ranOnMainThread
            self.debugSourcePreparationDurationNs = prepared.durationNs
            #endif
            self.collectionView.backgroundView = nil
            self.update(content: prepared.markdown, isStreaming: false)
        }
    }

    private func scheduleDeferredInitialRender(snapshot: ThinkingTraceStream.Snapshot) {
        deferredInitialRenderTask?.cancel()
        deferredInitialRenderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.deferredInitialRenderDelayMs))
            guard let self, !Task.isCancelled else { return }
            self.deferredInitialRenderTask = nil
            self.render(snapshot: snapshot)
        }
    }

    private func handleStreamUpdate(_ snapshot: ThinkingTraceStream.Snapshot) {
        deferredInitialRenderTask?.cancel()
        deferredInitialRenderTask = nil
        asyncRenderTask?.cancel()
        asyncRenderTask = nil
        renderAheadTask?.cancel()
        renderAheadTask = nil
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
        sourcePreparationTask?.cancel()
        sourcePreparationTask = nil
        deferredInitialRenderTask?.cancel()
        deferredInitialRenderTask = nil
        asyncRenderTask?.cancel()
        asyncRenderTask = nil
        renderAheadTask?.cancel()
        renderAheadTask = nil
        let configurationChanged = self.reviewCommentSelectionRouter !== reviewCommentSelectionRouter
            || self.reviewCommentSourceContext != reviewCommentSourceContext
            || self.textSelectionEnabled != textSelectionEnabled
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.textSelectionEnabled = textSelectionEnabled
        if configurationChanged {
            needsSnapshotReconfiguration = true
            pendingReconfigurationLayoutReason = .document
        }
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
        // Completion makes this a static document immediately. Cancel the
        // policy flag before handling an unchanged snapshot so any tail-follow
        // block queued by the final streaming layout yields when it runs.
        if snapshot.isDone {
            viewportOwner.streamCompleted()
        }
        guard snapshot != renderedSnapshot || needsSnapshotReconfiguration else {
            viewportOwner.scheduleFollowTail()
            return
        }

        // Keep the complete old snapshot mounted while a touch or momentum owns
        // the viewport. Parking even one cell before this gate makes a stream
        // tick blank visible content until interaction ends.
        if isCollectionUserInteracting, renderedSnapshot != nil {
            pendingInteractionSnapshot = snapshot
            return
        }
        pendingInteractionSnapshot = nil
        let layoutReason = pendingReconfigurationLayoutReason ?? .document
        needsSnapshotReconfiguration = false
        pendingReconfigurationLayoutReason = nil

        let previousText = renderedSnapshot?.text
        let appendOnly = previousText.map { snapshot.text.hasPrefix($0) } ?? false
        let previousSegments = renderedSegments
        let previousSegmentIDs = renderedSegmentIDs
        let previousSegmentRevisions = renderedSegmentRevisions
        let anchorBeforeMutation = !viewportOwner.followsTail
            ? captureViewportAnchor()
            : nil
        parkAllVisibleSegmentViews()
        asyncRenderTask?.cancel()
        asyncRenderTask = nil
        renderedSnapshot = snapshot
        collectionView.backgroundView = nil
        let config = AssistantMarkdownContentView.Configuration.make(
            content: snapshot.text,
            isStreaming: !snapshot.isDone,
            themeID: themeID,
            textSelectionEnabled: textSelectionEnabled,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSourceContext: reviewCommentSourceContext,
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            serverBaseURL: serverBaseURL,
            sourceFilePath: sourceFilePath,
            lineAnchor: lineAnchor,
            readerPreferences: readerPreferences,
            perfSurface: perfSurface,
            // Static reader document: LaTeX/Mermaid must finish before cell
            // self-sizing, or their async resize invalidates the collection
            // layout without a viewport anchor and jumps the scroll position.
            renderingMode: .staticReader
        )

        let cycleStart = MarkdownStreamingPerf.timestampNs()
        currentConfig = config
        let shouldResolveFileLines = !config.isStreaming
            && (config.reviewCommentSourceContext?.filePath != nil || config.lineAnchor != nil)
        if shouldRenderLargeCompletedSnapshotAsync(config: config, shouldResolveFileLines: shouldResolveFileLines) {
            renderLargeCompletedSnapshotAsync(
                snapshot: snapshot,
                config: config,
                cycleStart: cycleStart,
                anchorOverride: anchorBeforeMutation,
                layoutReason: layoutReason
            )
            return
        }
        #if DEBUG
        let segmentBuildStart = MarkdownStreamingPerf.timestampNs()
        #endif
        let build = segmentSource.buildSegmentsWithSourceLineRanges(
            config,
            mergeAdjacentTextSegments: lineAnchor == nil
        )
        renderedSegments = build.segments
        renderedSegmentLineRanges = build.sourceLineRanges
        renderedSegmentIDs = build.identities
        renderedSegmentRevisions = contentRevisions(
            oldSegments: previousSegments,
            oldIDs: previousSegmentIDs,
            oldRevisions: previousSegmentRevisions,
            newSegments: renderedSegments,
            newIDs: renderedSegmentIDs
        )
        retainedSegmentIDsForNextLayout = appendOnly
            ? Self.unchangedPrefixIDs(
                oldSegments: previousSegments,
                oldIDs: previousSegmentIDs,
                newSegments: renderedSegments,
                newIDs: renderedSegmentIDs
            )
            : []
        #if DEBUG
        debugSegmentBuildNs = MarkdownStreamingPerf.timestampNs() - segmentBuildStart
        #endif
        prepareLazyDocumentLayout(
            appendOnly: appendOnly,
            anchorOverride: anchorBeforeMutation,
            layoutReason: layoutReason
        )

        if let surface = config.perfSurface {
            let elapsed = MarkdownStreamingPerf.timestampNs() - cycleStart
            MarkdownStreamingPerf.recordFullCycle(
                totalNs: elapsed,
                segmentCount: renderedSegments.count,
                isStreaming: config.isStreaming,
                surface: surface
            )
        }

        viewportOwner.scheduleFollowTail()
    }

    private func shouldRenderLargeCompletedSnapshotAsync(
        config: AssistantMarkdownContentView.Configuration,
        shouldResolveFileLines: Bool
    ) -> Bool {
        !config.isStreaming
            && (sourceFormat == .orgMode || !shouldResolveFileLines)
            && config.content.utf8.count >= Self.deferredInitialRenderByteThreshold
    }

    private func renderLargeCompletedSnapshotAsync(
        snapshot: ThinkingTraceStream.Snapshot,
        config: AssistantMarkdownContentView.Configuration,
        cycleStart: UInt64,
        anchorOverride: ViewportAnchor?,
        layoutReason: MarkdownReaderLayoutReplacementReason
    ) {
        installDeferredRenderPlaceholder(palette: themeID.palette)
        renderedSegments = []
        renderedSegmentLineRanges = []
        renderedSegmentIDs = []
        renderedSegmentRevisions = []
        resetParkedSegmentViews()
        collectionView.reloadData()
        collectionView.collectionViewLayout.invalidateLayout()

        let source = config.content
        let themeID = config.themeID
        let workspaceID = config.workspaceID
        let sessionID = config.sessionID
        let serverBaseURL = config.serverBaseURL
        let sourceDirectory = config.sourceDirectory
        asyncRenderTask = Task { @MainActor [weak self] in
            let build: AsyncMarkdownBuild? = await withCancellableDetachedTask(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil }
                let ranOnMainThread = Self.isMainThreadForDiagnostics()
                let parseStart = DispatchTime.now().uptimeNanoseconds
                let blocks = parseCommonMarkLocated(source)
                let parseEnd = DispatchTime.now().uptimeNanoseconds
                guard !Task.isCancelled else { return nil }
                let build = FlatSegment.buildWithSourceLineRanges(
                    from: blocks,
                    themeID: themeID,
                    workspaceID: workspaceID,
                    sessionID: sessionID,
                    serverBaseURL: serverBaseURL,
                    sourceDirectory: sourceDirectory,
                    mergeAdjacentTextSegments: true
                )
                let buildEnd = DispatchTime.now().uptimeNanoseconds
                guard !Task.isCancelled else { return nil }
                return AsyncMarkdownBuild(
                    build: build,
                    parseDurationNs: parseEnd - parseStart,
                    buildDurationNs: buildEnd - parseEnd,
                    lineCount: Self.countNewlines(source) + 1,
                    ranOnMainThread: ranOnMainThread
                )
            }

            guard let build, !Task.isCancelled else { return }
            guard let self, self.latestSnapshot == snapshot else { return }

            let segments = AssistantMarkdownSegmentSource.applyReaderPreferences(
                to: build.build.segments,
                config: config
            )
            self.asyncRenderTask = nil
            #if DEBUG
            self.debugAsyncMarkdownBuildRanOnMainThread = build.ranOnMainThread
            #endif
            self.collectionView.backgroundView = nil
            self.renderedSegments = segments
            self.renderedSegmentLineRanges = build.build.sourceLineRanges
            self.renderedSegmentIDs = FlatSegment.readerSegmentIDs(
                segments: segments,
                sourceLineRanges: build.build.sourceLineRanges
            )
            self.renderedSegmentRevisions = self.contentRevisions(
                oldSegments: [],
                oldIDs: [],
                oldRevisions: [],
                newSegments: segments,
                newIDs: self.renderedSegmentIDs
            )
            self.prepareLazyDocumentLayout(
                appendOnly: false,
                anchorOverride: anchorOverride,
                layoutReason: layoutReason
            )

            MarkdownStreamingPerf.record(
                parseDurationNs: build.parseDurationNs,
                buildDurationNs: build.buildDurationNs,
                lineCount: build.lineCount,
                isTailOnly: false,
                isStreaming: false
            )
            if let surface = config.perfSurface {
                MarkdownStreamingPerf.recordFullCycle(
                    totalNs: MarkdownStreamingPerf.timestampNs() - cycleStart,
                    segmentCount: segments.count,
                    isStreaming: false,
                    surface: surface
                )
            }

            self.viewportOwner.scheduleFollowTail()
        }
    }

    private func lineAnchorOverlaps(_ sourceLineRange: ClosedRange<Int>?) -> Bool {
        guard let sourceLineRange,
              let existingRange = lineAnchorResolution?.existingRange else { return false }
        return sourceLineRange.lowerBound <= existingRange.upperBound
            && existingRange.lowerBound <= sourceLineRange.upperBound
    }

    private func visibleLineAnchorTargetFrames() -> [CGRect] {
        collectionView.visibleCells.compactMap { cell -> CGRect? in
            guard let indexPath = collectionView.indexPath(for: cell),
                  renderedSegmentLineRanges.indices.contains(indexPath.item),
                  lineAnchorOverlaps(renderedSegmentLineRanges[indexPath.item]) else {
                return nil
            }
            return cell.convert(cell.bounds, to: lineAnchorHighlightView)
        }
    }

    private func visibleLineAnchorTargetEnclosure() -> CGRect? {
        let frames = visibleLineAnchorTargetFrames()
        guard let firstFrame = frames.first else { return nil }
        return frames.dropFirst().reduce(firstFrame) { partial, next in
            partial.union(next)
        }
    }

    private func updateLineAnchorHighlight() {
        guard lineAnchorResolution?.existingRange != nil else {
            lineAnchorHighlightView.isHidden = true
            lineAnchorHighlightView.rects = []
            return
        }

        guard let enclosure = visibleLineAnchorTargetEnclosure() else {
            lineAnchorHighlightView.isHidden = true
            lineAnchorHighlightView.rects = []
            return
        }

        lineAnchorHighlightView.isHidden = false
        lineAnchorHighlightView.fillColor = UIColor(themeID.palette.blue).withAlphaComponent(0.08)
        lineAnchorHighlightView.strokeColor = UIColor(themeID.palette.blue).withAlphaComponent(0.75)
        lineAnchorHighlightView.rects = [enclosure.insetBy(dx: 1, dy: 1).integral]
        bringSubviewToFront(lineAnchorHighlightView)
    }

    private func scheduleLineAnchorFocusIfNeeded() {
        guard lineAnchorFocusPending, lineAnchorFocusTask == nil else { return }
        lineAnchorFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.lineAnchorFocusTask = nil
            guard self.collectionView.bounds.height > 0 else {
                self.lineAnchorFocusPending = true
                return
            }
            self.lineAnchorFocusPending = false
            self.scrollLineAnchorIntoUpperThird()
        }
    }

    private func scrollLineAnchorIntoUpperThird() {
        guard lineAnchorResolution != nil, collectionView.bounds.height > 0 else { return }
        collectionView.layoutIfNeeded()

        let targetY: CGFloat
        if let existingRange = lineAnchorResolution?.existingRange,
           let index = renderedSegmentLineRanges.firstIndex(where: { sourceRange in
               guard let sourceRange else { return false }
               return sourceRange.lowerBound <= existingRange.upperBound
                   && existingRange.lowerBound <= sourceRange.upperBound
           }),
           let attributes = collectionView.collectionViewLayout.layoutAttributesForItem(
               at: IndexPath(item: index, section: 0)
           ) {
            targetY = attributes.frame.minY - collectionView.bounds.height / 3
        } else {
            targetY = collectionView.contentSize.height
        }

        let minimumY = -collectionView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        let clampedY = min(max(targetY, minimumY), maximumY)
        guard clampedY.isFinite else { return }
        viewportOwner.explicitFocus(at: clampedY)
        collectionView.layoutIfNeeded()
        updateLineAnchorHighlight()
        if let existingRange = lineAnchorResolution?.existingRange,
           let index = renderedSegmentLineRanges.firstIndex(where: { sourceRange in
               guard let sourceRange else { return false }
               return sourceRange.lowerBound <= existingRange.upperBound
                   && existingRange.lowerBound <= sourceRange.upperBound
           }),
           let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) {
            UIAccessibility.post(notification: .layoutChanged, argument: cell)
        } else {
            UIAccessibility.post(notification: .layoutChanged, argument: collectionView)
        }
    }

    private static func unchangedPrefixIDs(
        oldSegments: [FlatSegment],
        oldIDs: [MarkdownReaderSegmentID],
        newSegments: [FlatSegment],
        newIDs: [MarkdownReaderSegmentID]
    ) -> Set<MarkdownReaderSegmentID> {
        var result = Set<MarkdownReaderSegmentID>()
        let count = [oldSegments.count, oldIDs.count, newSegments.count, newIDs.count].min() ?? 0
        for index in 0..<count {
            guard oldIDs[index] == newIDs[index],
                  segmentsHaveEqualContent(oldSegments[index], newSegments[index]) else { break }
            result.insert(oldIDs[index])
        }
        return result
    }

    private func contentRevisions(
        oldSegments: [FlatSegment],
        oldIDs: [MarkdownReaderSegmentID],
        oldRevisions: [Int],
        newSegments: [FlatSegment],
        newIDs: [MarkdownReaderSegmentID]
    ) -> [Int] {
        var oldByID: [MarkdownReaderSegmentID: (segment: FlatSegment, revision: Int)] = [:]
        for index in oldIDs.indices where oldSegments.indices.contains(index)
            && oldRevisions.indices.contains(index) {
            oldByID[oldIDs[index]] = (oldSegments[index], oldRevisions[index])
        }
        return zip(newSegments, newIDs).map { segment, id in
            if let previous = oldByID[id],
               Self.segmentsHaveEqualContent(previous.segment, segment) {
                return previous.revision
            }
            nextSegmentRevision &+= 1
            return nextSegmentRevision
        }
    }

    private static func segmentsHaveEqualContent(_ lhs: FlatSegment, _ rhs: FlatSegment) -> Bool {
        switch (lhs, rhs) {
        case (.text(let lhs), .text(let rhs)):
            NSAttributedString(lhs).isEqual(to: NSAttributedString(rhs))
        case let (.codeBlock(lhsLanguage, lhsCode), .codeBlock(rhsLanguage, rhsCode)):
            lhsLanguage == rhsLanguage && lhsCode == rhsCode
        case let (.table(lhsHeaders, lhsRows), .table(rhsHeaders, rhsRows)):
            lhsHeaders == rhsHeaders && lhsRows == rhsRows
        case (.thematicBreak, .thematicBreak):
            true
        case let (.image(lhsAlt, lhsURL), .image(rhsAlt, rhsURL)):
            lhsAlt == rhsAlt && lhsURL == rhsURL
        case let (.mermaidDiagram(lhs), .mermaidDiagram(rhs)):
            lhs == rhs
        case let (.latexBlock(lhs), .latexBlock(rhs)):
            lhs == rhs
        default:
            false
        }
    }

    nonisolated private static func countNewlines(_ string: String) -> Int {
        var count = 0
        for byte in string.utf8 where byte == UInt8(ascii: "\n") {
            count += 1
        }
        return count
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
        cell.bindReaderChrome(
            lineAnchorModeEnabled: lineAnchor != nil,
            textViewDelegate: self,
            doubleTapActivation: viewportDoubleTapActivation,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile
        )
        cell.appliedItemIndex = indexPath.item
        cell.appliedSegmentID = renderedSegmentIDs.indices.contains(indexPath.item)
            ? renderedSegmentIDs[indexPath.item]
            : nil
        cell.parkHandler = { [weak self] cell in
            self?.parkSegmentViews(from: cell)
        }
        // Attach the height publisher before `apply` so a cached image cannot
        // `forceInvalidate` + `layoutIfNeeded` from inside `cellForItemAt`.
        wirePreparedImageGeometry(on: cell, item: indexPath.item)
        isConfiguringCell = true
        defer { isConfiguringCell = false }
        if !suppressParkedReinstall,
           renderedSegmentIDs.indices.contains(indexPath.item),
           let parked = takeParkedSegmentViews(id: renderedSegmentIDs[indexPath.item]) {
            cell.installArrangedSegmentViews(parked)
            wirePreparedImageGeometry(on: cell, item: indexPath.item)
        } else {
            #if DEBUG
            debugAppliedItems.insert(indexPath.item)
            let visibleApplyStart = MarkdownStreamingPerf.timestampNs()
            #endif
            cell.apply(
                segment: renderedSegments[indexPath.item],
                config: config,
                sourceLineRange: renderedSegmentLineRanges.indices.contains(indexPath.item) ? renderedSegmentLineRanges[indexPath.item] : nil,
                lineAnchorModeEnabled: lineAnchor != nil,
                palette: themeID.palette,
                textViewDelegate: self,
                doubleTapActivation: viewportDoubleTapActivation,
                fetchWorkspaceFile: fetchWorkspaceFile,
                fetchSessionFile: fetchSessionFile,
                canonicalWidth: preparedCanonicalWidth,
                preparesImagesForDisplay: true
            )
            #if DEBUG
            let visibleApplyDuration = MarkdownStreamingPerf.timestampNs() - visibleApplyStart
            debugVisibleApplyNs += visibleApplyDuration
            if case .text = renderedSegments[indexPath.item] {
                debugVisibleTextApplyNs += visibleApplyDuration
                debugVisibleTextApplyCount += 1
            } else {
                debugVisibleNonTextApplyNs += visibleApplyDuration
                debugVisibleNonTextApplyCount += 1
            }
            #endif
        }
        updateGeometryPresentation(on: cell, item: indexPath.item)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let cell = cell as? FullScreenMarkdownSegmentCell,
              itemHeights.indices.contains(indexPath.item) else { return }
        updateGeometryPresentation(on: cell, item: indexPath.item)
        if renderedSegmentIDs.indices.contains(indexPath.item),
           let canonicalWidth = preparedCanonicalWidth,
           heightLedger.finalHeight(
               for: renderedSegmentIDs[indexPath.item],
               canonicalWidth: canonicalWidth
           ) == nil,
           let config = currentConfig {
            #if DEBUG
            debugWillDisplayRenderAheadMissCount += 1
            #endif
            settleItemGeometry(
                indexPath.item,
                config: config,
                canonicalWidth: canonicalWidth
            )
            itemHeights = heightLedger.heights()
            let becameFinal = heightLedger.finalHeight(
                for: renderedSegmentIDs[indexPath.item],
                canonicalWidth: canonicalWidth
            ) != nil
            if becameFinal {
                // A miss is not settled by mutating the ledger alone: replace
                // the active compositional layout and compensate the anchor in
                // the same nonanimated transaction before revealing the cell.
                replaceCollectionLayout(
                    preserveViewport: true,
                    reason: .willDisplayMiss
                )
            }
            refreshGeometryPresentationForVisibleCells()
        }
        // Reconcile deterministic visible fitting without allowing a visible
        // correction while a touch owns the viewport.
        scheduleHeightFlush()
    }

    // Segment views are moved on real reuse only. UIKit can take a cell
    // offscreen and later re-display it for the same index path without asking
    // the data source again, so stripping that cell here would make it empty.
    // Internal images additionally keep a document-owned metadata/decode probe;
    // that probe is parked and can commit geometry while the display cell is
    // detached.
    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard renderedSegments.indices.contains(indexPath.item),
              case .image = renderedSegments[indexPath.item] else { return }
        let targetY = collectionView.collectionViewLayout.layoutAttributesForItem(
            at: indexPath
        )?.frame.maxY ?? (collectionView.contentOffset.y + collectionView.bounds.height)
        scheduleRenderAheadSlices(
            fromItem: indexPath.item,
            targetY: targetY,
            generation: heightFlushGeneration
        )
    }

    private func parkSegmentViews(from cell: FullScreenMarkdownSegmentCell) {
        guard !suppressParkedReinstall else { return }
        guard let id = cell.appliedSegmentID else { return }
        let views = cell.yieldArrangedSegmentViews()
        guard !views.isEmpty else { return }
        parkedSegmentViews[id]?.forEach { $0.removeFromSuperview() }
        parkedSegmentViews[id] = views
        let parkedWidth = preparedCanonicalWidth ?? canonicalContentWidth
        for view in views {
            // An unconstrained `translatesAutoresizingMaskIntoConstraints=false`
            // view collapses to its intrinsic width when moved off a stack. A
            // graphical child would observe that transient width and reraster
            // before reuse. Park it at the canonical reader width instead.
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            view.frame = CGRect(
                x: 0,
                y: 0,
                width: parkedWidth,
                height: max(1, view.bounds.height)
            )
            parkedSegmentHost.addSubview(view)
        }
        cell.appliedItemIndex = nil
        cell.appliedSegmentID = nil
    }

    private func parkAllVisibleSegmentViews() {
        for case let cell as FullScreenMarkdownSegmentCell in collectionView.visibleCells {
            parkSegmentViews(from: cell)
            cell.resetApplierAfterYield()
        }
    }

    private func takeParkedSegmentViews(id: MarkdownReaderSegmentID) -> [UIView]? {
        guard let views = parkedSegmentViews.removeValue(forKey: id) else { return nil }
        views.forEach { $0.removeFromSuperview() }
        return views
    }

    private func resetParkedSegmentViews() {
        parkedSegmentHost.subviews.forEach { $0.removeFromSuperview() }
        parkedSegmentViews.removeAll()
    }

    /// Install estimated geometry for the document, then synchronously settle a
    /// bounded initial runway. Views produced by runway sizing are parked and
    /// reused by the collection view, so preparation is not duplicate work.
    private func prepareLazyDocumentLayout(
        appendOnly: Bool,
        anchorOverride: ViewportAnchor? = nil,
        layoutReason: MarkdownReaderLayoutReplacementReason = .document
    ) {
        guard collectionView.bounds.width > 0 else {
            needsDocumentLayoutPreparation = true
            pendingDocumentAppendOnly = appendOnly
            pendingDocumentLayoutReason = layoutReason
            return
        }
        guard !isCollectionUserInteracting || preparedCanonicalWidth == nil else {
            needsDocumentLayoutPreparation = true
            pendingDocumentAppendOnly = appendOnly
            pendingDocumentLayoutReason = layoutReason
            return
        }

        let width = collectionView.bounds.width
        let canonicalWidth = max(1, width - 24)
        let widthChanged = preparedCanonicalWidth.map { abs($0 - canonicalWidth) > 0.5 } ?? false
        let canRetainPrefix = appendOnly && !widthChanged
        let anchor = anchorOverride ?? (canRetainPrefix && !viewportOwner.followsTail
            ? captureViewportAnchor()
            : nil)

        needsDocumentLayoutPreparation = false
        pendingDocumentAppendOnly = false
        pendingDocumentLayoutReason = .document
        preparedCanonicalWidth = canonicalWidth
        heightFlushGeneration &+= 1
        pendingHeightFlush = false
        needsLayoutReplaceAfterInteraction = false
        needsVisibleHeightRefreshAfterInteraction = false
        suppressParkedReinstall = false
        if !canRetainPrefix {
            resetParkedSegmentViews()
        } else {
            let validIDs = retainedSegmentIDsForNextLayout
            let staleIDs = parkedSegmentViews.keys.filter { !validIDs.contains($0) }
            for id in staleIDs {
                parkedSegmentViews.removeValue(forKey: id)?.forEach {
                    $0.removeFromSuperview()
                }
            }
        }
        #if DEBUG
        debugAppliedItems.removeAll()
        debugHeightEstimateNs = 0
        debugLayoutSetupNs = 0
        debugVisibleApplyNs = 0
        debugVisibleTextApplyNs = 0
        debugVisibleNonTextApplyNs = 0
        debugVisibleTextApplyCount = 0
        debugVisibleNonTextApplyCount = 0
        debugDeferredFitNs = 0
        #endif
        #if DEBUG
        let heightEstimateStart = MarkdownStreamingPerf.timestampNs()
        #endif
        let estimates = renderedSegments.map {
            Self.estimatedHeight(for: $0, containerWidth: width)
        }
        heightLedger.applyDocument(
            ids: renderedSegmentIDs,
            estimates: estimates,
            canonicalWidth: canonicalWidth,
            appendOnly: canRetainPrefix,
            retainingFinalIDs: retainedSegmentIDsForNextLayout,
            contentRevisions: renderedSegmentRevisions
        )
        itemHeights = heightLedger.heights()
        #if DEBUG
        debugHeightEstimateNs = MarkdownStreamingPerf.timestampNs() - heightEstimateStart
        #endif

        // Settle first paint plus a small immediate runway. The remaining two
        // viewports are prepared in short main-actor slices after the shell is
        // visible, avoiding a gallery-sized synchronous opening stall.
        let initialPreparedCount = settleRenderAhead(
            fromItem: 0,
            throughY: collectionView.bounds.height * 1.5,
            maxItems: Self.maxInitialSynchronousPreparationItems,
            timeBudgetNs: Self.maxInitialSynchronousPreparationNs
        )
        #if DEBUG
        debugInitialSynchronousPreparationItemCount = initialPreparedCount
        #endif
        itemHeights = heightLedger.heights()

        #if DEBUG
        let layoutSetupStart = MarkdownStreamingPerf.timestampNs()
        #endif
        activeLayoutItemHeights = itemHeights
        #if DEBUG
        if layoutReason != .document {
            debugLayoutReplaceCount += 1
            debugLayoutReplacementReasons.append(layoutReason)
        }
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            collectionView.setCollectionViewLayout(
                Self.makeCollectionLayout(
                    spacing: readerPreferences.spacing.markdownStackSpacing,
                    itemHeights: itemHeights
                ),
                animated: false
            )
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            if let anchor {
                restoreViewportAnchor(anchor)
                collectionView.layoutIfNeeded()
            }
        }
        CATransaction.commit()
        updateIntrinsicViewportContentHeight()
        #if DEBUG
        debugLayoutSetupNs = MarkdownStreamingPerf.timestampNs() - layoutSetupStart
        #endif
        scheduleInitialRenderAheadSlices(
            targetY: collectionView.bounds.height * 3,
            generation: heightFlushGeneration
        )
    }

    private func updateIntrinsicViewportContentHeight() {
        guard let maximumViewportHeight else { return }

        let spacing = readerPreferences.spacing.markdownStackSpacing
        var height = CGFloat(20) // Collection section top and bottom insets.
        for (index, itemHeight) in itemHeights.enumerated() {
            if index > 0 { height += spacing }
            height += itemHeight
            if height >= maximumViewportHeight {
                height = maximumViewportHeight
                break
            }
        }
        let nextHeight = min(maximumViewportHeight, max(1, ceil(height)))
        guard abs(nextHeight - intrinsicViewportContentHeight) > 0.5 else { return }
        intrinsicViewportContentHeight = nextHeight
        invalidateIntrinsicContentSize()
    }

    private func scheduleInitialRenderAheadSlices(targetY: CGFloat, generation: Int) {
        scheduleRenderAheadSlices(fromItem: 0, targetY: targetY, generation: generation)
    }

    /// Render-ahead never runs inside a scroll delegate callback. Each main-
    /// actor turn settles at most two items and stops after a four-millisecond
    /// budget, then yields so touch delivery and animation can interrupt it.
    private func scheduleRenderAheadSlices(
        fromItem startItem: Int,
        targetY: CGFloat,
        generation: Int
    ) {
        renderAheadTask?.cancel()
        renderAheadTask = Task { @MainActor [weak self] in
            guard let self,
                  self.heightFlushGeneration == generation,
                  let config = self.currentConfig,
                  let canonicalWidth = self.preparedCanonicalWidth else { return }

            let spacing = self.readerPreferences.spacing.markdownStackSpacing
            var item = max(0, startItem)
            var y = CGFloat(10)
            if item > 0 {
                y += self.itemHeights.prefix(item).reduce(0, +)
                    + spacing * CGFloat(item)
            }

            while item < self.renderedSegments.count, y <= targetY {
                guard !Task.isCancelled,
                      self.heightFlushGeneration == generation else { return }
                let sliceStart = MarkdownStreamingPerf.timestampNs()
                var preparedInSlice = 0
                while item < self.renderedSegments.count, y <= targetY {
                    guard !Task.isCancelled else { return }
                    if self.heightLedger.finalHeight(
                        for: self.renderedSegmentIDs[item],
                        canonicalWidth: canonicalWidth
                    ) == nil {
                        self.settleItemGeometry(
                            item,
                            config: config,
                            canonicalWidth: canonicalWidth
                        )
                        preparedInSlice += 1
                        #if DEBUG
                        self.debugMaxRenderAheadItemsPerSlice = max(
                            self.debugMaxRenderAheadItemsPerSlice,
                            preparedInSlice
                        )
                        #endif
                    }
                    let height = self.heightLedger.geometry(
                        for: self.renderedSegmentIDs[item]
                    )?.height ?? self.itemHeights[item]
                    y += height + spacing
                    item += 1
                    let elapsed = MarkdownStreamingPerf.timestampNs() - sliceStart
                    if preparedInSlice >= 2 || elapsed >= 4_000_000 {
                        break
                    }
                }

                let previousHeights = self.itemHeights
                self.itemHeights = self.heightLedger.heights()
                if previousHeights != self.itemHeights {
                    if self.isCollectionUserInteracting {
                        self.needsLayoutReplaceAfterInteraction = true
                    } else {
                        self.replaceCollectionLayout(
                            preserveViewport: true,
                            reason: .renderAhead
                        )
                    }
                }
                if item < self.renderedSegments.count, y <= targetY {
                    await Task.yield()
                }
            }
            if !Task.isCancelled {
                self.renderAheadTask = nil
            }
        }
    }

    @discardableResult
    private func settleRenderAhead(
        fromItem startItem: Int,
        throughY targetY: CGFloat,
        maxItems: Int = .max,
        timeBudgetNs: UInt64 = .max
    ) -> Int {
        guard let config = currentConfig,
              let canonicalWidth = preparedCanonicalWidth,
              canonicalWidth > 0 else { return 0 }
        let spacing = readerPreferences.spacing.markdownStackSpacing
        var y = CGFloat(10)
        if startItem > 0 {
            y += itemHeights.prefix(startItem).reduce(0, +)
                + spacing * CGFloat(startItem)
        }

        let started = MarkdownStreamingPerf.timestampNs()
        var preparedCount = 0
        var item = max(0, startItem)
        while item < renderedSegments.count,
              y <= targetY,
              preparedCount < maxItems,
              MarkdownStreamingPerf.timestampNs() - started < timeBudgetNs {
            if heightLedger.finalHeight(
                for: renderedSegmentIDs[item],
                canonicalWidth: canonicalWidth
            ) == nil {
                settleItemGeometry(item, config: config, canonicalWidth: canonicalWidth)
                itemHeights = heightLedger.heights()
                preparedCount += 1
            }
            y += itemHeights[item] + spacing
            item += 1
        }
        return preparedCount
    }

    private func settleItemGeometry(
        _ item: Int,
        config: AssistantMarkdownContentView.Configuration,
        canonicalWidth: CGFloat
    ) {
        guard renderedSegments.indices.contains(item),
              renderedSegmentIDs.indices.contains(item) else { return }
        #if DEBUG
        if debugIsInsideScrollCallback {
            debugSynchronousScrollSettlementCount += 1
        }
        #endif
        let id = renderedSegmentIDs[item]
        if heightLedger.finalHeight(for: id, canonicalWidth: canonicalWidth) != nil {
            // An image cell can leave the hierarchy without being dequeued for
            // reuse. Keep one parked loader so metadata/decode work remains
            // owned by the document and can still commit geometry above the
            // viewport. Other final kinds need no duplicate view.
            guard case .image = renderedSegments[item],
                  parkedSegmentViews[id] == nil else { return }
        }

        let cell = FullScreenMarkdownSegmentCell(
            frame: CGRect(x: 0, y: 0, width: canonicalWidth, height: 1)
        )
        cell.contentView.bounds.size.width = canonicalWidth
        cell.bindReaderChrome(
            lineAnchorModeEnabled: lineAnchor != nil,
            textViewDelegate: self,
            doubleTapActivation: viewportDoubleTapActivation,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile
        )
        cell.appliedItemIndex = item
        cell.appliedSegmentID = id
        wirePreparedImageGeometry(on: cell, item: item)
        isConfiguringCell = true
        cell.apply(
            segment: renderedSegments[item],
            config: config,
            sourceLineRange: renderedSegmentLineRanges.indices.contains(item)
                ? renderedSegmentLineRanges[item]
                : nil,
            lineAnchorModeEnabled: lineAnchor != nil,
            palette: themeID.palette,
            textViewDelegate: self,
            doubleTapActivation: viewportDoubleTapActivation,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile,
            canonicalWidth: canonicalWidth,
            preparesImagesForDisplay: false
        )
        isConfiguringCell = false
        let height = cell.measuredFittingHeight(width: canonicalWidth)
        guard let token = heightLedger.workToken(
            for: id,
            canonicalWidth: canonicalWidth
        ) else { return }
        let waitsForPreparedInternalGeometry: Bool
        if case .image(_, let url) = renderedSegments[item] {
            waitsForPreparedInternalGeometry = RemoteMarkdownImagePolicy.decision(for: url)
                == .internalImageURL
                && heightLedger.finalHeight(for: id, canonicalWidth: canonicalWidth) == nil
        } else {
            waitsForPreparedInternalGeometry = false
        }
        if !waitsForPreparedInternalGeometry {
            let commit = heightLedger.commitFinal(
                token: token,
                height: height,
                anchorID: captureViewportAnchorID()
            )
            #if DEBUG
            if commit.accepted { debugGeometryCommitCount += 1 }
            #endif
        }
        let views = cell.yieldArrangedSegmentViews()
        if !views.isEmpty {
            parkedSegmentViews[id]?.forEach { $0.removeFromSuperview() }
            parkedSegmentViews[id] = views
            views.forEach { parkedSegmentHost.addSubview($0) }
        }
        cell.resetApplierAfterYield()
        #if DEBUG
        debugAppliedItems.insert(item)
        #endif
    }

    private func scheduleRenderAheadForCurrentViewport() {
        guard !renderedSegments.isEmpty else { return }
        let targetY = collectionView.contentOffset.y + collectionView.bounds.height * 3
        let first = collectionView.indexPathsForVisibleItems.map(\.item).min() ?? 0
        scheduleRenderAheadSlices(
            fromItem: first,
            targetY: targetY,
            generation: heightFlushGeneration
        )
    }

    private static func estimatedHeight(for segment: FlatSegment, containerWidth: CGFloat) -> CGFloat {
        let contentWidth = max(1, containerWidth - 24)
        switch segment {
        case .text(let attributed):
            // First paint must not typeset every paragraph. Estimate wrapped
            // line count from character counts; the estimate only positions
            // items until the user scrolls to them.
            return ceil(estimatedTextHeight(String(attributed.characters), contentWidth: contentWidth, lineSpacing: 8))
        case .codeBlock(_, let code):
            // Monospace glyphs are wider than proportional text.
            return ceil(estimatedTextHeight(code, contentWidth: contentWidth, charWidth: 9.6, lineHeight: 16, lineSpacing: 56))
        case .table(let headers, let rows):
            let metrics = NativeTableBlockView.measureNaturalColumns(headers: headers, rows: rows)
            if MarkdownTableColumnLayout.needsGridMode(naturalWidths: metrics.columnWidths) {
                return CGFloat(max(headers.isEmpty ? 1 : 1, rows.count + 1)) * 56 + 16
            }
            let lineCount = CGFloat(1 + rows.count)
            return lineCount * 22 + 16
        case .thematicBreak:
            return 8
        case .image:
            return 180
        case .mermaidDiagram(let code):
            // Mermaid parsing is too expensive for first paint. Estimate
            // from diagram source lines; the background prefetch renders
            // the real raster before the user reaches the item.
            let lineCount = CGFloat(countNewlines(code) + 1)
            return min(400, max(120, lineCount * 24 + 44))
        case .latexBlock(let code):
            // TeX parsing plus CoreGraphics layout is too expensive for
            // first paint. Estimate from source lines; real rasters are
            // prefetched in the background before the user scrolls here.
            let lineCount = CGFloat(countNewlines(code) + 1)
            return min(400, max(44, lineCount * 28 + 24))
        }
    }

    /// Cheap wrapped-line estimate for first-paint sizing. Avoids full
    /// NSAttributedString typesetting per segment; ~9pt average glyph width
    /// overestimates slightly so cells never collapse to clipped heights.
    private static func estimatedTextHeight(
        _ text: String,
        contentWidth: CGFloat,
        charWidth: CGFloat = 9.0,
        lineHeight: CGFloat = 20,
        lineSpacing: CGFloat = 0
    ) -> CGFloat {
        guard !text.isEmpty else { return max(22, lineHeight + lineSpacing) }
        let width = max(1, contentWidth)
        var lines: CGFloat = 0
        var paragraphScalars: CGFloat = 0
        for scalar in text.unicodeScalars {
            if scalar.value == 10 {
                lines += max(1, (paragraphScalars * charWidth / width).rounded(.up))
                paragraphScalars = 0
            } else {
                paragraphScalars += 1
            }
        }
        lines += max(1, (paragraphScalars * charWidth / width).rounded(.up))
        return max(22, lines * lineHeight + lineSpacing)
    }

    private struct ViewportAnchor {
        let id: MarkdownReaderSegmentID
        let offsetInItem: CGFloat
    }

    private var canonicalContentWidth: CGFloat {
        max(1, collectionView.bounds.width - 24)
    }

    private func contentCellWidth(containerWidth: CGFloat? = nil) -> CGFloat {
        if let containerWidth { return max(1, containerWidth - 24) }
        return preparedCanonicalWidth ?? canonicalContentWidth
    }

    private var isCollectionUserInteracting: Bool {
        #if DEBUG
        if let debugIsCollectionUserInteractingOverride {
            return debugIsCollectionUserInteractingOverride
        }
        #endif
        let panState = collectionView.panGestureRecognizer.state
        return collectionView.isTracking
            || collectionView.isDragging
            || collectionView.isDecelerating
            || panState == .began
            || panState == .changed
    }

    private func wirePreparedImageGeometry(on cell: FullScreenMarkdownSegmentCell, item: Int) {
        guard renderedSegmentIDs.indices.contains(item),
              let canonicalWidth = preparedCanonicalWidth,
              let token = heightLedger.workToken(
                  for: renderedSegmentIDs[item],
                  canonicalWidth: canonicalWidth
              ) else { return }
        cell.observePreparedImageGeometry { [weak self] height in
            self?.updateReservedHeight(token: token, height: height)
        }
    }

    private func waitsForPreparedInternalGeometry(_ item: Int) -> Bool {
        guard renderedSegments.indices.contains(item),
              renderedSegmentIDs.indices.contains(item),
              let canonicalWidth = preparedCanonicalWidth,
              case .image(_, let url) = renderedSegments[item],
              RemoteMarkdownImagePolicy.decision(for: url) == .internalImageURL else {
            return false
        }
        return heightLedger.finalHeight(
            for: renderedSegmentIDs[item],
            canonicalWidth: canonicalWidth
        ) == nil
    }

    private func updateGeometryPresentation(
        on cell: FullScreenMarkdownSegmentCell,
        item: Int
    ) {
        guard renderedSegmentIDs.indices.contains(item),
              let canonicalWidth = preparedCanonicalWidth else {
            cell.setGeometryPresentationReady(false)
            return
        }
        let finalHeight = heightLedger.finalHeight(
            for: renderedSegmentIDs[item],
            canonicalWidth: canonicalWidth
        )
        let activeHeight = activeLayoutItemHeights.indices.contains(item)
            ? activeLayoutItemHeights[item]
            : nil
        let isReady: Bool
        if let finalHeight, let activeHeight {
            isReady = abs(activeHeight - finalHeight) <= 0.5
        } else {
            isReady = false
        }
        cell.setGeometryPresentationReady(isReady)
    }

    private func refreshGeometryPresentationForVisibleCells() {
        for case let cell as FullScreenMarkdownSegmentCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            updateGeometryPresentation(on: cell, item: indexPath.item)
        }
    }

    private func updateReservedHeight(
        token: MarkdownReaderHeightLedger.WorkToken,
        height: CGFloat
    ) {
        guard let item = renderedSegmentIDs.firstIndex(of: token.id),
              itemHeights.indices.contains(item),
              renderedSegmentRevisions.indices.contains(item),
              renderedSegmentRevisions[item] == token.contentRevision,
              let canonicalWidth = preparedCanonicalWidth,
              abs(canonicalWidth - token.canonicalWidth) <= 0.5 else { return }
        let next: CGFloat
        let visibleCell = collectionView.cellForItem(at: IndexPath(item: item, section: 0))
            as? FullScreenMarkdownSegmentCell
        if let visibleCell {
            let width = visibleCell.contentView.bounds.width > 0
                ? visibleCell.contentView.bounds.width
                : contentCellWidth()
            next = visibleCell.measuredFittingHeight(width: width)
        } else {
            next = ceil(max(1, height))
        }
        let heightChanged = abs(itemHeights[item] - next) > 0.5
        let wasFinal = heightLedger.finalHeight(
            for: token.id,
            canonicalWidth: canonicalWidth
        ) != nil
        guard heightChanged || !wasFinal else {
            refreshGeometryPresentationForVisibleCells()
            return
        }
        let commit = heightLedger.commitFinal(
            token: token,
            height: next,
            anchorID: captureViewportAnchorID()
        )
        guard commit.accepted else { return }
        #if DEBUG
        debugGeometryCommitCount += 1
        if heightChanged,
           let visibleCell,
           visibleCell.isGeometryPresentationReady,
           isCollectionUserInteracting {
            debugVisibleHeightCorrectionDuringInteractionCount += 1
        }
        #endif
        itemHeights = heightLedger.heights()
        if isCollectionUserInteracting {
            if heightChanged {
                needsLayoutReplaceAfterInteraction = true
                return
            }
            refreshGeometryPresentationForVisibleCells()
            return
        }
        if isConfiguringCell {
            if heightChanged {
                scheduleHeightFlush()
                return
            }
            refreshGeometryPresentationForVisibleCells()
            return
        }
        if heightChanged {
            replaceCollectionLayout(
                preserveViewport: true,
                reason: .preparedGeometry
            )
        } else {
            refreshGeometryPresentationForVisibleCells()
        }
    }

    private func scheduleHeightFlush() {
        guard !pendingHeightFlush else { return }
        pendingHeightFlush = true
        let generation = heightFlushGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.heightFlushGeneration == generation else { return }
            self.pendingHeightFlush = false
            guard !self.isCollectionUserInteracting else {
                self.needsVisibleHeightRefreshAfterInteraction = true
                return
            }
            guard self.refreshVisibleReservedHeights() else {
                self.refreshGeometryPresentationForVisibleCells()
                return
            }
            self.replaceCollectionLayout(
                preserveViewport: true,
                reason: .visibleReconciliation
            )
        }
    }

    @discardableResult
    private func refreshVisibleReservedHeights() -> Bool {
        var changed = false
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? FullScreenMarkdownSegmentCell,
                  itemHeights.indices.contains(indexPath.item) else { continue }
            if waitsForPreparedInternalGeometry(indexPath.item) {
                cell.setGeometryPresentationReady(false)
                continue
            }
            let width = cell.contentView.bounds.width > 0
                ? cell.contentView.bounds.width
                : contentCellWidth()
            #if DEBUG
            let fittingStart = MarkdownStreamingPerf.timestampNs()
            #endif
            let fitting = cell.measuredFittingHeight(width: width)
            #if DEBUG
            debugDeferredFitNs += MarkdownStreamingPerf.timestampNs() - fittingStart
            #endif
            guard abs(itemHeights[indexPath.item] - fitting) > 0.5,
                  renderedSegmentIDs.indices.contains(indexPath.item),
                  let canonicalWidth = preparedCanonicalWidth else { continue }
            guard let token = heightLedger.workToken(
                for: renderedSegmentIDs[indexPath.item],
                canonicalWidth: canonicalWidth
            ) else { continue }
            let commit = heightLedger.commitFinal(
                token: token,
                height: fitting,
                anchorID: captureViewportAnchorID()
            )
            if commit.accepted {
                #if DEBUG
                debugGeometryCommitCount += 1
                #endif
                itemHeights = heightLedger.heights()
                changed = true
            }
        }
        return changed
    }

    private func replaceCollectionLayout(
        preserveViewport: Bool,
        reason: MarkdownReaderLayoutReplacementReason
    ) {
        if isCollectionUserInteracting {
            needsLayoutReplaceAfterInteraction = true
            return
        }
        guard !isReplacingCollectionLayout else {
            needsLayoutReplaceAfterInteraction = true
            return
        }
        isReplacingCollectionLayout = true
        defer { isReplacingCollectionLayout = false }
        needsLayoutReplaceAfterInteraction = false
        #if DEBUG
        debugLayoutReplaceCount += 1
        debugLayoutReplacementReasons.append(reason)
        #endif
        let anchor = preserveViewport && !viewportOwner.followsTail
            ? captureViewportAnchor()
            : nil
        activeLayoutItemHeights = itemHeights
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            self.collectionView.setCollectionViewLayout(
                Self.makeCollectionLayout(
                    spacing: self.readerPreferences.spacing.markdownStackSpacing,
                    itemHeights: self.itemHeights
                ),
                animated: false
            )
            self.collectionView.layoutIfNeeded()
            if let anchor {
                self.restoreViewportAnchor(anchor)
                self.collectionView.layoutIfNeeded()
            }
            self.refreshGeometryPresentationForVisibleCells()
        }
        CATransaction.commit()
        updateIntrinsicViewportContentHeight()
        if viewportOwner.followsTail {
            viewportOwner.scheduleFollowTail()
        }
    }

    private func replaceCollectionLayoutIfNeededAfterInteraction() {
        guard needsLayoutReplaceAfterInteraction || needsVisibleHeightRefreshAfterInteraction,
              !pendingLayoutReplaceAfterInteractionRetry else { return }
        pendingLayoutReplaceAfterInteractionRetry = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLayoutReplaceAfterInteractionRetry = false
            guard !self.isCollectionUserInteracting else { return }
            let layoutWasAlreadyDirty = self.needsLayoutReplaceAfterInteraction
            let needsVisibleRefresh = self.needsVisibleHeightRefreshAfterInteraction
            self.needsVisibleHeightRefreshAfterInteraction = false
            let refreshedHeight = needsVisibleRefresh
                ? self.refreshVisibleReservedHeights()
                : false
            guard layoutWasAlreadyDirty || refreshedHeight else { return }
            self.replaceCollectionLayout(
                preserveViewport: true,
                reason: .interactionEnded
            )
        }
    }

    private func retryDeferredLayoutReplaceIfInteractionEnded() {
        guard !isCollectionUserInteracting else { return }
        applyPendingInteractionSnapshotIfNeeded()
        guard needsLayoutReplaceAfterInteraction || needsVisibleHeightRefreshAfterInteraction else { return }
        replaceCollectionLayoutIfNeededAfterInteraction()
    }

    private func applyPendingInteractionSnapshotIfNeeded() {
        guard !isCollectionUserInteracting else { return }
        if let pendingReaderPreferences {
            self.pendingReaderPreferences = nil
            readerPreferences = pendingReaderPreferences
            needsSnapshotReconfiguration = true
            pendingReconfigurationLayoutReason = .readerPreferences
        }
        let snapshot = pendingInteractionSnapshot
        pendingInteractionSnapshot = nil
        if let snapshot {
            render(snapshot: snapshot)
        } else if needsSnapshotReconfiguration {
            render(snapshot: latestSnapshot)
        }
    }

    private func captureViewportAnchor() -> ViewportAnchor? {
        let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        let first = collectionView.indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
            .first { indexPath in
                guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
                    return false
                }
                return frame.intersects(visibleRect)
            }
        guard let first,
              let frame = collectionView.layoutAttributesForItem(at: first)?.frame else {
            return nil
        }
        guard renderedSegmentIDs.indices.contains(first.item) else { return nil }
        return ViewportAnchor(
            id: renderedSegmentIDs[first.item],
            offsetInItem: collectionView.contentOffset.y - frame.minY
        )
    }

    private func captureViewportAnchorID() -> MarkdownReaderSegmentID? {
        captureViewportAnchor()?.id
    }

    private func restoreViewportAnchor(_ anchor: ViewportAnchor) {
        guard let item = renderedSegmentIDs.firstIndex(of: anchor.id),
              itemHeights.indices.contains(item) else { return }
        let spacing = readerPreferences.spacing.markdownStackSpacing
        var itemMinY = CGFloat(10)
        if item > 0 {
            let prior = itemHeights[0..<item].reduce(0, +)
            itemMinY += prior + spacing * CGFloat(item)
        }
        let contentHeight = CGFloat(10 + 10)
            + itemHeights.reduce(0, +)
            + spacing * CGFloat(max(0, itemHeights.count - 1))
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(
            minY,
            contentHeight
                - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        let y = min(max(itemMinY + anchor.offsetInItem, minY), maxY)
        guard y.isFinite else { return }
        viewportOwner.preserveAnchor(at: y)
    }

    private static func graphicalHeight<P: DocumentParser, R: GraphicalDocumentRenderer>(
        parser: P,
        renderer: R,
        text: String,
        fontSize: CGFloat,
        width: CGFloat,
        displayMode: RenderDisplayMode,
        cap: CGFloat
    ) -> CGFloat where P.Document == R.Document {
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: parser,
            renderer: renderer,
            text: text,
            config: RenderConfiguration(
                fontSize: fontSize,
                maxWidth: width,
                theme: ThemeRuntimeState.currentRenderTheme(),
                displayMode: displayMode
            )
        )
        let size = layout.size
        guard size.width > 0, size.height > 0 else { return 120 }
        let scale = min(1, width / size.width)
        return min(cap, max(44, ceil(size.height * scale)))
    }

    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let runwayItems = indexPaths
            .map(\.item)
            .filter { renderedSegments.indices.contains($0) }
            .sorted()
        guard let first = runwayItems.first else { return }
        let last = runwayItems.prefix(12).last ?? first
        let targetY = collectionView.collectionViewLayout.layoutAttributesForItem(
            at: IndexPath(item: last, section: 0)
        )?.frame.maxY ?? (collectionView.contentOffset.y + collectionView.bounds.height * 3)
        scheduleRenderAheadSlices(
            fromItem: first,
            targetY: targetY,
            generation: heightFlushGeneration
        )
    }

    private func beginViewportInteraction() {
        viewportOwner.touchDown()
        lineAnchorFocusTask?.cancel()
        lineAnchorFocusTask = nil
    }

    @objc private func handleCollectionPanStateChange(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            beginViewportInteraction()
        case .ended, .cancelled, .failed:
            // A tap can stop deceleration without either drag-end delegate
            // callback. Hop so UIKit clears `isTracking` before atomically
            // applying any snapshot deferred for the interaction.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isCollectionUserInteracting else { return }
                self.applyPendingInteractionSnapshotIfNeeded()
                self.replaceCollectionLayoutIfNeededAfterInteraction()
            }
        default:
            break
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        beginViewportInteraction()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        #if DEBUG
        debugIsInsideScrollCallback = true
        defer { debugIsInsideScrollCallback = false }
        #endif
        // A tap can stop deceleration without `scrollViewDidEndDecelerating`.
        // Queue the retry from the final scroll callback so `isTracking` gets
        // re-checked after the touch has cleared on the next main-queue turn.
        replaceCollectionLayoutIfNeededAfterInteraction()
        updateLineAnchorHighlight()
        #if DEBUG
        if !debugIsPerformingDirectScroll {
            scheduleRenderAheadForCurrentViewport()
        }
        #else
        scheduleRenderAheadForCurrentViewport()
        #endif
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            viewportOwner.interactionEnded(isStreaming: !latestSnapshot.isDone)
            applyPendingInteractionSnapshotIfNeeded()
            replaceCollectionLayoutIfNeededAfterInteraction()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        viewportOwner.interactionEnded(isStreaming: !latestSnapshot.isDone)
        applyPendingInteractionSnapshotIfNeeded()
        replaceCollectionLayoutIfNeededAfterInteraction()
    }
}

extension NativeFullScreenMarkdownBody: FullScreenReaderConfigurable {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != (pendingReaderPreferences ?? readerPreferences) else { return }
        if isCollectionUserInteracting {
            pendingReaderPreferences = preferences
            pendingInteractionSnapshot = latestSnapshot
            return
        }
        // If UIKit released ownership before the queued interaction-end turn,
        // this immediate request supersedes both deferred values.
        pendingReaderPreferences = nil
        pendingInteractionSnapshot = nil
        readerPreferences = preferences
        needsSnapshotReconfiguration = true
        pendingReconfigurationLayoutReason = .readerPreferences
        render(snapshot: latestSnapshot)
        setNeedsLayout()
    }
}

#if DEBUG
extension NativeFullScreenMarkdownBody {
    struct FirstPaintDiagnostics: Equatable {
        let segmentBuildUs: UInt64
        let heightEstimateUs: UInt64
        let layoutSetupUs: UInt64
        let visibleApplyUs: UInt64
        let visibleTextApplyUs: UInt64
        let visibleNonTextApplyUs: UInt64
        let visibleTextApplyCount: Int
        let visibleNonTextApplyCount: Int
        let deferredFitUs: UInt64
    }

    var debugFirstPaintDiagnosticsForTesting: FirstPaintDiagnostics {
        FirstPaintDiagnostics(
            segmentBuildUs: debugSegmentBuildNs / 1_000,
            heightEstimateUs: debugHeightEstimateNs / 1_000,
            layoutSetupUs: debugLayoutSetupNs / 1_000,
            visibleApplyUs: debugVisibleApplyNs / 1_000,
            visibleTextApplyUs: debugVisibleTextApplyNs / 1_000,
            visibleNonTextApplyUs: debugVisibleNonTextApplyNs / 1_000,
            visibleTextApplyCount: debugVisibleTextApplyCount,
            visibleNonTextApplyCount: debugVisibleNonTextApplyCount,
            deferredFitUs: debugDeferredFitNs / 1_000
        )
    }

    var debugRenderedSegmentCountForTesting: Int { renderedSegments.count }
    var debugIsSourcePreparationPendingForTesting: Bool { sourcePreparationTask != nil }
    var debugSourcePreparationRanOnMainThreadForTesting: Bool? {
        debugSourcePreparationRanOnMainThread
    }
    var debugSourcePreparationDurationUsForTesting: UInt64 {
        debugSourcePreparationDurationNs / 1_000
    }
    var debugAsyncMarkdownBuildRanOnMainThreadForTesting: Bool? {
        debugAsyncMarkdownBuildRanOnMainThread
    }

    func debugWaitForDocumentPreparationForTesting() async {
        await sourcePreparationTask?.value
        await asyncRenderTask?.value
        await renderAheadTask?.value
    }
    var debugAppliedItemCountForTesting: Int { debugAppliedItems.count }
    var debugLayoutReplaceCountForTesting: Int { debugLayoutReplaceCount }
    var debugLayoutReplacementReasonsForTesting: [MarkdownReaderLayoutReplacementReason] {
        debugLayoutReplacementReasons
    }
    var debugAppliedSegmentKindsForTesting: [String] {
        debugAppliedItems.sorted().compactMap { item in
            guard renderedSegments.indices.contains(item) else { return nil }
            return switch renderedSegments[item] {
            case .text: "text"
            case .codeBlock: "code"
            case .table: "table"
            case .thematicBreak: "break"
            case .image: "image"
            case .mermaidDiagram: "mermaid"
            case .latexBlock: "latex"
            }
        }
    }
    var debugRenderedSegmentsForTesting: [FlatSegment] { renderedSegments }
    var debugRenderedSegmentIDsForTesting: [MarkdownReaderSegmentID] { renderedSegmentIDs }
    var debugRenderedSegmentRevisionsForTesting: [Int] { renderedSegmentRevisions }
    var debugRenderedSourceTextForTesting: String? { renderedSnapshot?.text }
    var debugHasPendingInteractionSnapshotForTesting: Bool {
        pendingInteractionSnapshot != nil
    }
    var debugCanonicalContentWidthForTesting: CGFloat? { preparedCanonicalWidth }
    var debugGeometryCommitCountForTesting: Int { debugGeometryCommitCount }
    var debugWillDisplayRenderAheadMissCountForTesting: Int { debugWillDisplayRenderAheadMissCount }
    var debugSynchronousScrollSettlementCountForTesting: Int {
        debugSynchronousScrollSettlementCount
    }
    var debugMaxRenderAheadItemsPerSliceForTesting: Int {
        debugMaxRenderAheadItemsPerSlice
    }
    var debugInitialSynchronousPreparationItemCountForTesting: Int {
        debugInitialSynchronousPreparationItemCount
    }
    var debugIsRenderAheadActiveForTesting: Bool { renderAheadTask != nil }
    var debugVisibleHeightCorrectionDuringInteractionCountForTesting: Int {
        debugVisibleHeightCorrectionDuringInteractionCount
    }
    var debugOffsetWriteReasonsForTesting: [MarkdownReaderOffsetWriteReason] {
        debugOffsetWriteReasons
    }
    func debugResetOffsetWriteReasonsForTesting() {
        debugOffsetWriteReasons.removeAll()
    }
    func debugQueueAutomaticViewportWritesForTesting(focusY: CGFloat) {
        viewportOwner.scheduleFollowTail()
        viewportOwner.scheduleExplicitFocus { focusY }
    }
    func debugHandleTouchDownForTesting() {
        beginViewportInteraction()
    }
    var debugVisibleCellCountForTesting: Int { collectionView.visibleCells.count }
    var debugParkedHostForTesting: UIView { parkedSegmentHost }
    var debugNeedsLayoutReplaceAfterInteractionForTesting: Bool {
        needsLayoutReplaceAfterInteraction
    }

    func debugSetCollectionUserInteractingForTesting(_ isInteracting: Bool?) {
        debugIsCollectionUserInteractingOverride = isInteracting
        if isInteracting == true {
            viewportOwner.interactionBegan()
        } else if isInteracting == false {
            viewportOwner.interactionEnded(isStreaming: !latestSnapshot.isDone)
        }
    }

    func debugScrollItemIntoViewForTesting(_ item: Int) {
        guard renderedSegments.indices.contains(item) else { return }
        renderAheadTask?.cancel()
        renderAheadTask = nil
        debugIsPerformingDirectScroll = true
        defer { debugIsPerformingDirectScroll = false }
        if let config = currentConfig, let canonicalWidth = preparedCanonicalWidth {
            let previousHeights = itemHeights
            let lower = max(0, item - 8)
            let upper = min(renderedSegments.count, item + 9)
            for runwayItem in lower..<upper {
                settleItemGeometry(
                    runwayItem,
                    config: config,
                    canonicalWidth: canonicalWidth
                )
            }
            itemHeights = heightLedger.heights()
            if itemHeights != previousHeights {
                replaceCollectionLayout(
                    preserveViewport: true,
                    reason: .testing
                )
            }
        }
        guard activeLayoutItemHeights.indices.contains(item) else { return }
        let spacing = readerPreferences.spacing.markdownStackSpacing
        var itemMinY = CGFloat(10)
        if item > 0 {
            itemMinY += activeLayoutItemHeights[..<item].reduce(0, +)
                + spacing * CGFloat(item)
        }
        let itemMidY = itemMinY + activeLayoutItemHeights[item] / 2
        let minimumY = -collectionView.adjustedContentInset.top
        let activeContentHeight = CGFloat(20)
            + activeLayoutItemHeights.reduce(0, +)
            + spacing * CGFloat(max(0, activeLayoutItemHeights.count - 1))
        let maximumY = max(
            minimumY,
            activeContentHeight - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        collectionView.setContentOffset(
            CGPoint(
                x: collectionView.contentOffset.x,
                y: min(max(itemMidY - collectionView.bounds.height / 2, minimumY), maximumY)
            ),
            animated: false
        )
        collectionView.layoutIfNeeded()
    }

    func debugReservedHeightForTesting(_ item: Int) -> CGFloat? {
        guard itemHeights.indices.contains(item) else { return nil }
        return itemHeights[item]
    }

    func debugForceRenderAheadMissForTesting(item: Int, estimate: CGFloat) {
        guard renderedSegmentIDs.indices.contains(item) else { return }
        heightLedger.setEstimatedHeight(estimate, for: renderedSegmentIDs[item])
        itemHeights = heightLedger.heights()
        replaceCollectionLayout(
            preserveViewport: true,
            reason: .testing
        )
    }

    func debugIsItemPresentedForTesting(_ item: Int) -> Bool {
        guard let cell = collectionView.cellForItem(
            at: IndexPath(item: item, section: 0)
        ) as? FullScreenMarkdownSegmentCell else { return false }
        return cell.isGeometryPresentationReady && cell.contentView.alpha > 0.99
    }

    func debugHasFinalGeometryForTesting(_ item: Int) -> Bool {
        guard renderedSegmentIDs.indices.contains(item),
              let canonicalWidth = preparedCanonicalWidth else { return false }
        return heightLedger.finalHeight(
            for: renderedSegmentIDs[item],
            canonicalWidth: canonicalWidth
        ) != nil
    }

    func debugParkedViewCountForTesting(id: MarkdownReaderSegmentID) -> Int {
        parkedSegmentViews[id]?.count ?? 0
    }

    func debugEvictGraphicalArtifactForTesting(_ item: Int) {
        guard renderedSegmentIDs.indices.contains(item) else { return }
        let id = renderedSegmentIDs[item]
        parkedSegmentViews.removeValue(forKey: id)?.forEach { $0.removeFromSuperview() }
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
    }

    func debugFittingHeightForTesting(_ item: Int) -> CGFloat? {
        let indexPath = IndexPath(item: item, section: 0)
        if let cell = collectionView.cellForItem(at: indexPath) as? FullScreenMarkdownSegmentCell {
            let width = cell.contentView.bounds.width > 0
                ? cell.contentView.bounds.width
                : max(1, collectionView.bounds.width - 24)
            return cell.measuredFittingHeight(width: width)
        }
        guard renderedSegments.indices.contains(item),
              let config = currentConfig,
              let canonicalWidth = preparedCanonicalWidth else { return nil }
        let measuringCell = FullScreenMarkdownSegmentCell(
            frame: CGRect(x: 0, y: 0, width: canonicalWidth, height: 1)
        )
        measuringCell.bindReaderChrome(
            lineAnchorModeEnabled: lineAnchor != nil,
            textViewDelegate: self,
            doubleTapActivation: viewportDoubleTapActivation,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile
        )
        measuringCell.apply(
            segment: renderedSegments[item],
            config: config,
            sourceLineRange: renderedSegmentLineRanges.indices.contains(item)
                ? renderedSegmentLineRanges[item]
                : nil,
            lineAnchorModeEnabled: lineAnchor != nil,
            palette: themeID.palette,
            textViewDelegate: self,
            doubleTapActivation: viewportDoubleTapActivation,
            fetchWorkspaceFile: fetchWorkspaceFile,
            fetchSessionFile: fetchSessionFile,
            canonicalWidth: canonicalWidth,
            preparesImagesForDisplay: false
        )
        return measuringCell.measuredFittingHeight(width: canonicalWidth)
    }

    func debugVisibleAnchorForTesting() -> (item: Int, screenY: CGFloat)? {
        let visibleRect = CGRect(origin: collectionView.contentOffset, size: collectionView.bounds.size)
        let first = collectionView.indexPathsForVisibleItems
            .sorted { $0.item < $1.item }
            .first { indexPath in
                guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
                    return false
                }
                return frame.intersects(visibleRect)
            }
        guard let first,
              let frame = collectionView.layoutAttributesForItem(at: first)?.frame else {
            return nil
        }
        return (first.item, frame.minY - collectionView.contentOffset.y)
    }
    var debugSourceTextForTesting: String { latestSnapshot.text }
    var debugLineAnchorRequestedRangeForTesting: ClosedRange<Int>? {
        lineAnchorResolution?.requestedRange
    }
    var debugLineAnchorExistingRangeForTesting: ClosedRange<Int>? {
        lineAnchorResolution?.existingRange
    }
    var debugLineAnchorHighlightedSegmentCountForTesting: Int {
        renderedSegmentLineRanges.reduce(into: 0) { count, sourceRange in
            guard let sourceRange, lineAnchorOverlaps(sourceRange) else { return }
            count += 1
        }
    }
    var debugLineAnchorVisibleHighlightedCellCountForTesting: Int {
        collectionView.visibleCells.reduce(into: 0) { count, cell in
            guard let indexPath = collectionView.indexPath(for: cell),
                  renderedSegmentLineRanges.indices.contains(indexPath.item),
                  lineAnchorOverlaps(renderedSegmentLineRanges[indexPath.item]) else {
                return
            }
            count += 1
        }
    }

    var debugLineAnchorVisibleHighlightEnclosureCountForTesting: Int {
        guard !lineAnchorHighlightView.isHidden,
              !lineAnchorHighlightView.rects.isEmpty else { return 0 }
        return lineAnchorHighlightView.rects.contains { rect in
            !rect.intersection(lineAnchorHighlightView.bounds).isEmpty
        } ? 1 : 0
    }

    var debugLineAnchorVisibleHighlightAlignedWithTargetForTesting: Bool {
        guard let highlightRect = lineAnchorHighlightView.rects.first,
              let targetRect = visibleLineAnchorTargetEnclosure(),
              highlightRect.width > 0,
              highlightRect.height > 0,
              !highlightRect.intersection(lineAnchorHighlightView.bounds).isEmpty else {
            return false
        }

        let expectedRect = targetRect.insetBy(dx: 1, dy: 1).integral
        return abs(highlightRect.minX - expectedRect.minX) <= 1
            && abs(highlightRect.minY - expectedRect.minY) <= 1
            && abs(highlightRect.maxX - expectedRect.maxX) <= 1
            && abs(highlightRect.maxY - expectedRect.maxY) <= 1
    }

    var debugLineAnchorVisibleHighlightGeometryCountForTesting: Int {
        guard debugLineAnchorVisibleHighlightEnclosureCountForTesting == 1,
              debugLineAnchorVisibleHighlightAreaForTesting > 0,
              debugLineAnchorVisibleHighlightAlignedWithTargetForTesting else {
            return 0
        }
        return 1
    }

    var debugLineAnchorVisibleHighlightAreaForTesting: CGFloat {
        guard !lineAnchorHighlightView.isHidden else { return .zero }
        return lineAnchorHighlightView.rects.reduce(into: CGFloat.zero) { area, rect in
            let visibleRect = rect.intersection(lineAnchorHighlightView.bounds)
            guard !visibleRect.isEmpty else { return }
            area += visibleRect.width * visibleRect.height
        }
    }

    var debugLineAnchorVisibleHighlightOverlaysFrontmostForTesting: Bool {
        guard debugLineAnchorVisibleHighlightEnclosureCountForTesting > 0,
              let overlayIndex = subviews.firstIndex(where: { $0 === lineAnchorHighlightView }),
              let collectionIndex = subviews.firstIndex(where: { $0 === collectionView }) else {
            return false
        }
        return overlayIndex > collectionIndex
    }

    var debugLineAnchorScrollOffsetForTesting: CGPoint {
        collectionView.contentOffset
    }
    var debugLineAnchorViewportHeightForTesting: CGFloat {
        collectionView.bounds.height
    }
    var debugLineAnchorFirstTargetFrameForTesting: CGRect? {
        guard let existingRange = lineAnchorResolution?.existingRange,
              let index = renderedSegmentLineRanges.firstIndex(where: { sourceRange in
                  guard let sourceRange else { return false }
                  return sourceRange.lowerBound <= existingRange.upperBound
                      && existingRange.lowerBound <= sourceRange.upperBound
              }) else { return nil }
        return collectionView.collectionViewLayout.layoutAttributesForItem(
            at: IndexPath(item: index, section: 0)
        )?.frame
    }

    var debugLineAnchorFirstVisibleTargetMidYForTesting: CGFloat? {
        guard let frame = debugLineAnchorFirstTargetFrameForTesting else { return nil }
        return frame.midY - collectionView.contentOffset.y
    }

    func debugLayoutVisibleMarkdownCellsForTesting() {
        layoutIfNeeded()
        collectionView.layoutIfNeeded()
        updateLineAnchorHighlight()
    }
}
#endif

extension NativeFullScreenMarkdownBody: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        guard case let .link(url) = textItem.content else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        let action = MarkdownLinkInteractionSupport.classify(
            url,
            serverID: currentConfig?.serverID,
            workspaceID: currentConfig?.workspaceID
        )
        return MarkdownLinkInteractionSupport.menuConfiguration(
            for: action,
            defaultMenu: defaultMenu,
            textView: textView
        ) { normalizedURL, sourceView in
            FileSharePresenter.share(normalizedURL, sourceView: sourceView)
        }
    }

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

        let action = MarkdownLinkInteractionSupport.classify(
            url,
            serverID: currentConfig?.serverID,
            workspaceID: currentConfig?.workspaceID
        )
        return MarkdownLinkInteractionSupport.primaryAction(
            for: action,
            defaultAction: defaultAction
        )
    }
}

// MARK: - Source Body

final class NativeFullScreenSourceBody: UIView, UITextViewDelegate {
    private let textView = FullScreenReviewCommentTextView()
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private let palette: ThemePalette
    private let lineAnchor: SourceLineAnchor?
    private let lineAnchorResolution: SourceLineAnchorResolution?
    private var readerPreferences: FullScreenReaderPreferences
    private var isStreaming: Bool
    private var lineAnchorFocusTask: Task<Void, Never>?
    private var lineAnchorFocusPending = false

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
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        lineAnchor: SourceLineAnchor? = nil,
        focusLineAnchor: Bool = true
    ) {
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.palette = palette
        self.lineAnchor = lineAnchor
        self.lineAnchorResolution = lineAnchor?.resolution(fileContent: content)
        self.readerPreferences = readerPreferences
        self.isStreaming = isStreaming
        self.lineAnchorFocusPending = lineAnchor != nil && focusLineAnchor
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
        if let lineAnchorResolution {
            textView.accessibilityLabel = "Source text"
            textView.accessibilityValue = lineAnchorResolution.accessibilityLabel
        }
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

    deinit {
        lineAnchorFocusTask?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyWrapMode()
        updateLineAnchorHighlight()
        scheduleLineAnchorFocusIfNeeded()
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
        // TextKit rects are expressed in the text view's content coordinates.
        // Recompute the overlay here so a user scroll moves the enclosure with
        // the source instead of leaving it at the pre-scroll position. This
        // only repaints geometry; focus and content offset remain untouched.
        updateLineAnchorHighlight()
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

    private func updateLineAnchorHighlight() {
        guard let existingRange = lineAnchorResolution?.existingRange else {
            textView.setLineAnchorHighlight(
                rects: [],
                fillColor: UIColor.systemBlue.withAlphaComponent(0.08),
                strokeColor: UIColor.systemBlue.withAlphaComponent(0.75)
            )
            return
        }

        let layout = FullScreenLineAnchorLayout.layout(
            for: textView,
            sourceLineRange: existingRange,
            startLine: 1
        )
        textView.setLineAnchorHighlight(
            rects: layout.visibleRects,
            firstRect: layout.firstVisibleRect,
            fillColor: UIColor(palette.blue).withAlphaComponent(0.08),
            strokeColor: UIColor(palette.blue).withAlphaComponent(0.75)
        )
    }

    private func scheduleLineAnchorFocusIfNeeded() {
        guard lineAnchorFocusPending, lineAnchorFocusTask == nil else { return }
        lineAnchorFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.lineAnchorFocusTask = nil
            guard self.textView.bounds.height > 0 else {
                self.lineAnchorFocusPending = true
                return
            }
            self.lineAnchorFocusPending = false
            self.scrollLineAnchorIntoUpperThird()
        }
    }

    private func scrollLineAnchorIntoUpperThird() {
        guard lineAnchorResolution != nil, textView.bounds.height > 0 else { return }
        textView.layoutIfNeeded()

        let targetY: CGFloat
        if let existingRange = lineAnchorResolution?.existingRange,
           let firstRect = FullScreenLineAnchorLayout.layout(
               for: textView,
               sourceLineRange: existingRange,
               startLine: 1
           ).firstContentRect {
            targetY = firstRect.minY - textView.bounds.height / 3
        } else {
            targetY = textView.contentSize.height
        }

        let minimumY = -textView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            textView.contentSize.height
                - textView.bounds.height
                + textView.adjustedContentInset.bottom
        )
        let clampedY = min(max(targetY, minimumY), maximumY)
        guard clampedY.isFinite else { return }
        textView.setContentOffset(
            CGPoint(x: textView.contentOffset.x, y: clampedY),
            animated: false
        )
        updateLineAnchorHighlight()
        UIAccessibility.post(notification: .layoutChanged, argument: textView)
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

#if DEBUG
extension NativeFullScreenSourceBody {
    var debugLineAnchorRequestedRangeForTesting: ClosedRange<Int>? {
        lineAnchorResolution?.requestedRange
    }

    var debugLineAnchorExistingRangeForTesting: ClosedRange<Int>? {
        lineAnchorResolution?.existingRange
    }

    var debugLineAnchorHighlightRectCountForTesting: Int {
        textView.debugLineAnchorHighlightRectCountForTesting
    }

    var debugLineAnchorFirstHighlightRectForTesting: CGRect? {
        textView.debugLineAnchorFirstHighlightRectForTesting
    }

    var debugLineAnchorHighlightEnclosureRectForTesting: CGRect? {
        textView.debugLineAnchorHighlightEnclosureRectForTesting
    }

    var debugLineAnchorVisibleHighlightGeometryForTesting: Bool {
        textView.debugLineAnchorHighlightHasVisibleGeometryForTesting
    }

    var debugLineAnchorVisibleHighlightAlignedWithTargetForTesting: Bool {
        textView.debugLineAnchorHighlightContainsFirstTargetForTesting
    }

    var debugLineAnchorScrollOffsetForTesting: CGPoint {
        textView.contentOffset
    }
}
#endif

// MARK: - Rendered Document Body (LaTeX, Mermaid)

/// Fullscreen body for single-canvas rendered document types. Org documents use
/// ``NativeFullScreenMarkdownBody`` so their multi-block content is virtualized.
final class NativeFullScreenRenderedDocumentBody: UIView, UIScrollViewDelegate {

    enum DocumentContent {
        case latex(String)
        case mermaid(String)
    }

    private struct LatexView {
        let view: UIView
        let isGraphical: Bool
    }

    private let scrollView = UIScrollView()
    private let readerPreferences: FullScreenReaderPreferences
    private let themeID: ThemeID
    private var latexZoomContentView: UIView?

    init(
        content: DocumentContent,
        themeID: ThemeID? = nil,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.renderedDocument.defaultPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.readerPreferences = readerPreferences
        self.themeID = themeID ?? ThemeRuntimeState.currentThemeID()
        super.init(frame: .zero)
        backgroundColor = UIColor(palette.bgDark)

        switch content {
        case .mermaid(let text):
            // ZoomableGraphicalView has its own scroll + zoom — embed directly
            let zoomable = makeZoomableGraphicalView(
                parser: MermaidParser(), renderer: MermaidRenderer(),
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
            // LaTeX uses the outer scroll view.
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.alwaysBounceVertical = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.backgroundColor = UIColor(palette.bgDark)
            addSubview(scrollView)

            let contentView: UIView
            let allowsHorizontalOverflow: Bool
            let enablesGraphicalZoom: Bool
            switch content {
            case .latex(let text):
                let latex = makeLatexView(text: text)
                contentView = latex.view
                allowsHorizontalOverflow = true
                enablesGraphicalZoom = latex.isGraphical
                scrollView.accessibilityIdentifier = "fullscreen-latex.scroll"
                scrollView.accessibilityLabel = "Full-screen formula"
            case .mermaid:
                fatalError("Handled above")
            }

            scrollView.alwaysBounceHorizontal = allowsHorizontalOverflow
            contentView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(contentView)

            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

                contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
                contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
                contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
                contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -12),
            ])

            let viewportWidth = scrollView.frameLayoutGuide.widthAnchor.constraint(
                equalTo: contentView.widthAnchor,
                constant: 28
            )
            if allowsHorizontalOverflow {
                // LaTeX keeps its natural width. The content guide grows beyond
                // the viewport when needed, creating real two-axis overflow.
                contentView.widthAnchor.constraint(
                    greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor,
                    constant: -28
                ).isActive = true
            } else {
                // Text-based Org rendering still needs a viewport width reference.
                viewportWidth.isActive = true
            }

            if enablesGraphicalZoom {
                latexZoomContentView = contentView
                scrollView.minimumZoomScale = 1
                scrollView.maximumZoomScale = 4
                scrollView.bouncesZoom = true
                scrollView.delegate = self
                DoubleTapZoom.install(
                    on: scrollView,
                    target: self,
                    action: #selector(handleLatexDoubleTap(_:))
                )
                updateLatexAccessibilityValue()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func handleLatexDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let latexZoomContentView else { return }
        DoubleTapZoom.toggle(
            in: scrollView,
            tapInContent: gesture.location(in: latexZoomContentView),
            fitScale: scrollView.minimumZoomScale
        )
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        latexZoomContentView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateLatexAccessibilityValue()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateLatexAccessibilityValue()
    }

    private func updateLatexAccessibilityValue() {
        guard latexZoomContentView != nil else { return }
        let zoomPercent = Int((scrollView.zoomScale * 100).rounded())
        let horizontalOffset = max(
            0,
            scrollView.contentOffset.x + scrollView.adjustedContentInset.left
        )
        scrollView.accessibilityValue = "Zoom \(zoomPercent) percent, horizontal offset \(Int(horizontalOffset.rounded())) points"
    }

    private func makeLatexView(text: String) -> LatexView {
        let config = RenderConfiguration(
            fontSize: UIFont.preferredFont(forTextStyle: .title1).pointSize * readerPreferences.textScale,
            maxWidth: 800,
            theme: themeID.palette.renderTheme,
            displayMode: .document
        )
        let multiLayout = DocumentRenderPipeline.layoutLatexExpressions(text: text, config: config)
        if let source = multiLayout.exactSourceFallback {
            return LatexView(
                view: DocumentRenderPipeline.makeLatexSourceFallbackView(
                    source: source,
                    palette: themeID.palette
                ),
                isGraphical: false
            )
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = multiLayout.spacing
        stack.alignment = .leading
        stack.widthAnchor.constraint(
            greaterThanOrEqualToConstant: max(multiLayout.totalSize.width, 1)
        ).isActive = true

        for (expr, source) in zip(multiLayout.expressions, multiLayout.sources) {
            let drawView = GraphicalRendererUIView()
            drawView.configure(
                size: expr.size,
                draw: expr.draw,
                accessibilityLabel: FlatSegment.formulaAccessibilityLabel(for: source)
            )
            drawView.translatesAutoresizingMaskIntoConstraints = false
            drawView.widthAnchor.constraint(equalToConstant: max(expr.size.width, 1)).isActive = true
            drawView.heightAnchor.constraint(equalToConstant: max(expr.size.height, 1)).isActive = true
            stack.addArrangedSubview(drawView)
        }

        return LatexView(view: stack, isGraphical: true)
    }

    private func makeZoomableGraphicalView<P: DocumentParser, R: GraphicalDocumentRenderer>(
        parser: P, renderer: R, text: String, fontSize: CGFloat
    ) -> UIView where P.Document == R.Document {
        let config = RenderConfiguration(
            fontSize: fontSize,
            maxWidth: 800,
            theme: themeID.palette.renderTheme,
            displayMode: .document
        )
        let layout = DocumentRenderPipeline.layoutGraphical(
            parser: parser, renderer: renderer, text: text, config: config
        )
        return ZoomableGraphicalView(size: layout.size, draw: layout.draw)
    }
}

#if DEBUG
extension NativeFullScreenRenderedDocumentBody {
    func debugToggleLatexZoomForTesting(at pointInContent: CGPoint) {
        guard let latexZoomContentView else { return }
        DoubleTapZoom.toggle(
            in: scrollView,
            tapInContent: pointInContent,
            fitScale: scrollView.minimumZoomScale,
            animated: false
        )
    }
}
#endif
