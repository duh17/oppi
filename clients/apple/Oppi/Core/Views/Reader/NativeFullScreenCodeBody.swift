import UIKit

private final class CodeLineNumberGutterView: UIView {
    struct Row: Equatable {
        let text: String
        let y: CGFloat
        let height: CGFloat
        let isHighlighted: Bool
        let showsHighlightMarker: Bool
    }

    var font: UIFont = AppFont.monoMedium {
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

private struct FullScreenCodeChunk: Sendable {
    let sourceUTF16Range: Range<Int>
    let startLine: Int
    let text: String
    let lineContentRanges: [NSRange]
    let lineUTF16Lengths: [Int]
    let tokenRanges: [SyntaxTokenRange]

    var sourceLineRange: ClosedRange<Int> {
        startLine...(startLine + lineContentRanges.count - 1)
    }
}

private struct FullScreenCodeChunkIndex: Sendable {
    let chunks: [FullScreenCodeChunk]
    let sourceUTF16Count: Int
    let widestLineUTF16Count: Int
    let highlightMilliseconds: Double

    static func build(
        source: String,
        language: SyntaxLanguage,
        startLine: Int,
        maxLines: Int,
        maxUTF16: Int
    ) -> Self {
        precondition(maxLines > 0 && maxUTF16 > 0)
        let nsSource = source as NSString
        let lines = SourceLineMetrics.logicalLineContentRanges(in: nsSource)
        let highlightStart = DispatchTime.now().uptimeNanoseconds
        let tokens = language == .unknown
            ? []
            : TreeSitterHighlighter.resolvedTokenRanges(source, language: language)
        let highlightMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds &- highlightStart
        ) / 1_000_000

        var chunks: [FullScreenCodeChunk] = []
        chunks.reserveCapacity(max(1, lines.count / maxLines))
        var widestLine = 0
        var lineIndex = 0
        while lineIndex < lines.count {
            let firstLineIndex = lineIndex
            let chunkStart = lines[firstLineIndex].location
            var chunkEnd = chunkStart
            while lineIndex < lines.count, lineIndex - firstLineIndex < maxLines {
                let proposedEnd = lineIndex + 1 < lines.count
                    ? lines[lineIndex + 1].location
                    : nsSource.length
                if lineIndex > firstLineIndex, proposedEnd - chunkStart > maxUTF16 {
                    break
                }
                chunkEnd = proposedEnd
                lineIndex += 1
                if chunkEnd - chunkStart >= maxUTF16 { break }
            }
            if lineIndex == firstLineIndex {
                lineIndex += 1
                chunkEnd = lineIndex < lines.count ? lines[lineIndex].location : nsSource.length
            }

            let sourceRange = chunkStart..<chunkEnd
            let localLines = lines[firstLineIndex..<lineIndex].map { range in
                widestLine = max(widestLine, range.length)
                return NSRange(location: range.location - chunkStart, length: range.length)
            }
            let localTokens = tokens.compactMap { token -> SyntaxTokenRange? in
                let lower = max(token.location, sourceRange.lowerBound)
                let upper = min(token.location + token.length, sourceRange.upperBound)
                guard lower < upper else { return nil }
                return SyntaxTokenRange(
                    location: lower - sourceRange.lowerBound,
                    length: upper - lower,
                    kind: token.kind
                )
            }
            chunks.append(FullScreenCodeChunk(
                sourceUTF16Range: sourceRange,
                startLine: startLine + firstLineIndex,
                text: nsSource.substring(with: NSRange(
                    location: sourceRange.lowerBound,
                    length: sourceRange.count
                )),
                lineContentRanges: localLines,
                lineUTF16Lengths: localLines.map(\.length),
                tokenRanges: localTokens
            ))
        }

        return Self(
            chunks: chunks,
            sourceUTF16Count: nsSource.length,
            widestLineUTF16Count: widestLine,
            highlightMilliseconds: highlightMilliseconds
        )
    }
}

private final class FullScreenCodeChunkCell: UICollectionViewCell {
    static let reuseIdentifier = "FullScreenCodeChunkCell"

    let textView = FullScreenReviewCommentTextView()
    private let gutterView = CodeLineNumberGutterView()
    private let separatorView = UIView()
    private var gutterWidthConstraint: NSLayoutConstraint?
    private var chunk: FullScreenCodeChunk?
    private var lineAnchorResolution: SourceLineAnchorResolution?
    private var palette = ThemeID.dark.palette
    private var lastLayoutWidth: CGFloat = -1
    var onLayoutGutterMeasured: ((Double) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        contentView.addSubview(gutterView)
        contentView.addSubview(separatorView)
        contentView.addSubview(textView)
        let gutterWidthConstraint = gutterView.widthAnchor.constraint(equalToConstant: 44)
        self.gutterWidthConstraint = gutterWidthConstraint
        NSLayoutConstraint.activate([
            gutterView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            gutterView.topAnchor.constraint(equalTo: contentView.topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            gutterWidthConstraint,
            separatorView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor, constant: 6),
            separatorView.topAnchor.constraint(equalTo: contentView.topAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.widthAnchor.constraint(equalToConstant: 1),
            textView.leadingAnchor.constraint(equalTo: separatorView.trailingAnchor),
            textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: contentView.topAnchor),
            textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        chunk: FullScreenCodeChunk,
        attributedText: NSAttributedString?,
        font: UIFont,
        gutterWidth: CGFloat,
        wrapsText: Bool,
        palette: ThemePalette,
        lineAnchorResolution: SourceLineAnchorResolution?
    ) {
        self.chunk = chunk
        self.palette = palette
        self.lineAnchorResolution = lineAnchorResolution
        gutterView.font = font
        gutterView.textColor = palette.ui.comment
        gutterWidthConstraint?.constant = gutterWidth
        separatorView.backgroundColor = palette.ui.comment.withAlphaComponent(0.2)
        textView.font = font
        textView.textColor = palette.ui.fg
        textView.textContainer.lineBreakMode = wrapsText ? .byCharWrapping : .byClipping
        textView.textContainer.widthTracksTextView = wrapsText
        textView.attributedText = attributedText
        lastLayoutWidth = -1
        setNeedsLayout()
    }

    func installAttributedText(_ attributedText: NSAttributedString) {
        textView.setAttributedTextPreservingSelection(attributedText)
        lastLayoutWidth = -1
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let chunk, textView.bounds.width > 0,
              lastLayoutWidth != textView.bounds.width else { return }
        lastLayoutWidth = textView.bounds.width
        let start = DispatchTime.now().uptimeNanoseconds
        let insets = textView.textContainerInset
        textView.textContainer.size = CGSize(
            width: textView.textContainer.widthTracksTextView
                ? max(1, textView.bounds.width - insets.left - insets.right)
                : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        var rows: [CodeLineNumberGutterView.Row] = []
        rows.reserveCapacity(chunk.lineContentRanges.count)
        let highlightMarkerLine = lineAnchorResolution?.existingRange?.lowerBound
        var fallbackY: CGFloat = 0
        for (offset, range) in chunk.lineContentRanges.enumerated() {
            let fragmentRect: CGRect
            if range.length > 0 {
                let glyphRange = textView.layoutManager.glyphRange(
                    forCharacterRange: range,
                    actualCharacterRange: nil
                )
                fragmentRect = glyphRange.length > 0
                    ? textView.layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
                    : CGRect(x: 0, y: fallbackY, width: textView.textContainer.size.width, height: gutterView.font.lineHeight)
            } else {
                fragmentRect = CGRect(x: 0, y: fallbackY, width: textView.textContainer.size.width, height: gutterView.font.lineHeight)
            }
            fallbackY = fragmentRect.maxY
            let sourceLine = chunk.startLine + offset
            rows.append(CodeLineNumberGutterView.Row(
                text: String(sourceLine),
                y: insets.top + fragmentRect.minY,
                height: max(gutterView.font.lineHeight, fragmentRect.height),
                isHighlighted: lineAnchorResolution?.existingRange?.contains(sourceLine) == true,
                showsHighlightMarker: sourceLine == highlightMarkerLine
            ))
        }
        gutterView.rows = rows
        updateLineAnchorHighlight(chunk: chunk)
        onLayoutGutterMeasured?(Double(
            DispatchTime.now().uptimeNanoseconds &- start
        ) / 1_000_000)
    }

    private func lineAnchorLayout(
        for chunk: FullScreenCodeChunk
    ) -> FullScreenLineAnchorLayoutResult? {
        guard let anchored = lineAnchorResolution?.existingRange,
              anchored.overlaps(chunk.sourceLineRange) else { return nil }
        let localRange = ClosedRange(uncheckedBounds: (
            lower: max(anchored.lowerBound, chunk.sourceLineRange.lowerBound),
            upper: min(anchored.upperBound, chunk.sourceLineRange.upperBound)
        ))
        return FullScreenLineAnchorLayout.layout(
            for: textView,
            sourceLineRange: localRange,
            startLine: chunk.startLine
        )
    }

    private func updateLineAnchorHighlight(chunk: FullScreenCodeChunk) {
        guard let layout = lineAnchorLayout(for: chunk) else {
            textView.setLineAnchorHighlight(
                rects: [],
                fillColor: palette.ui.blue.withAlphaComponent(0.08),
                strokeColor: palette.ui.blue.withAlphaComponent(0.75)
            )
            return
        }
        textView.setLineAnchorHighlight(
            rects: layout.visibleRects,
            firstRect: layout.firstVisibleRect,
            fillColor: palette.ui.blue.withAlphaComponent(0.08),
            strokeColor: palette.ui.blue.withAlphaComponent(0.75)
        )
    }

    func lineAnchorFirstContentRectInCell() -> CGRect? {
        guard let chunk,
              let rect = lineAnchorLayout(for: chunk)?.firstContentRect else { return nil }
        return textView.convert(rect, to: self)
    }

    #if DEBUG
    var debugLineAnchorHighlightRectCount: Int {
        textView.debugLineAnchorHighlightRectCountForTesting
    }

    var debugLineAnchorFirstHighlightRect: CGRect? {
        guard let rect = textView.debugLineAnchorFirstHighlightRectForTesting else { return nil }
        return textView.convert(rect, to: self)
    }

    var debugLineAnchorContainsFirstTarget: Bool {
        textView.debugLineAnchorHighlightContainsFirstTargetForTesting
    }

    var debugLineAnchorGutterMarkerCount: Int {
        gutterView.rows.filter(\.showsHighlightMarker).count
    }
    #endif

    override func prepareForReuse() {
        super.prepareForReuse()
        chunk = nil
        textView.attributedText = nil
        textView.text = nil
        textView.delegate = nil
        textView.reviewCommentSourceLineRangeResolver = nil
        gutterView.rows = []
        onLayoutGutterMeasured = nil
        lastLayoutWidth = -1
    }
}

/// Generate line number string and compute gutter width.
func lineNumberInfo(lineCount: Int, startLine: Int, font: UIFont? = nil) -> (numbers: String, width: CGFloat) {
    let endLine = startLine + lineCount - 1
    let numbers = (startLine...endLine).map(String.init).joined(separator: "\n")
    let digits = max(String(endLine).count, 2)
    let fixedWidth = CGFloat(digits) * 7.5
    let width: CGFloat
    if let font {
        let sample = String(repeating: "8", count: digits) as NSString
        let measuredWidth = sample.size(withAttributes: [.font: font]).width
        width = max(fixedWidth, ceil(measuredWidth) + 2)
    } else {
        width = fixedWidth
    }
    return (numbers, width)
}

final class NativeFullScreenCodeBody: UIView, UIScrollViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private static let virtualizationThresholdBytes = 128 * 1024
    private static let virtualizedChunkLineLimit = 160
    private static let virtualizedChunkUTF16Limit = 32 * 1024
    private static let attributedChunkCacheLimit = 14
    private static let maxEstimatedCodeWidth: CGFloat = 120_000

    nonisolated private static func isMainThreadForDiagnostics() -> Bool {
        Thread.isMainThread
    }

    private let scrollView = UIScrollView()
    private let contentContainer = UIView()
    private let gutterView = CodeLineNumberGutterView()
    private let separatorView = UIView()
    private let codeTextView = FullScreenReviewCommentTextView()
    private let virtualizedLayout = UICollectionViewFlowLayout()
    private lazy var virtualizedCollectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: virtualizedLayout
    )
    private let content: String
    private let language: String?
    private let startLine: Int
    private let lineCount: Int
    private var palette: ThemePalette
    private var highlightThemeID: ThemeID
    private let lineAnchor: SourceLineAnchor?
    private let lineAnchorResolution: SourceLineAnchorResolution?
    private let alwaysBounceVertical: Bool
    private let usesVirtualizedRendering: Bool
    private let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private let reviewCommentSourceContext: ReviewCommentSourceContext?
    private var readerPreferences: FullScreenReaderPreferences
    private var appliedThemeID: ThemeID?
    private var gutterWidthConstraint: NSLayoutConstraint?
    private var contentContainerWidthConstraint: NSLayoutConstraint?
    private var highlightedSourceText: NSAttributedString?
    private var lastGutterLayoutSignature: GutterLayoutSignature?
    private var highlightTask: Task<Void, Never>?
    private var lineAnchorFocusTask: Task<Void, Never>?
    private var lineAnchorFocusPending = false
    private var virtualizedIndex: FullScreenCodeChunkIndex?
    private var virtualizedGeneration = 0
    private var attributedChunkCache: [Int: NSAttributedString] = [:]
    private var attributedChunkLRU: [Int] = []
    private var chunkRenderTasks: [Int: Task<Void, Never>] = [:]
    private var lastVirtualizedLayoutSize: CGSize = .zero
    #if DEBUG
    nonisolated(unsafe) static var highlightDelayForTesting: Duration?
    private(set) var debugHighlightWorkCountForTesting = 0
    private var debugHighlightMilliseconds: Double = 0
    private var debugAttributedInstallMilliseconds: Double = 0
    private var debugLayoutGutterMilliseconds: Double = 0
    private var debugIndexRanOnMainThread: Bool?
    #endif

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
        themeID: ThemeID = ThemeRuntimeState.currentThemeID(),
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
        self.highlightThemeID = themeID
        self.appliedThemeID = themeID
        self.lineAnchor = lineAnchor
        self.lineAnchorResolution = lineAnchor?.resolution(
            fileContent: content,
            firstFileLine: startLine
        )
        self.alwaysBounceVertical = alwaysBounceVertical
        self.usesVirtualizedRendering = content.utf8.count > Self.virtualizationThresholdBytes
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
        chunkRenderTasks.values.forEach { $0.cancel() }
        lineAnchorFocusTask?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if usesVirtualizedRendering {
            if virtualizedCollectionView.bounds.size != lastVirtualizedLayoutSize {
                lastVirtualizedLayoutSize = virtualizedCollectionView.bounds.size
                virtualizedLayout.invalidateLayout()
            }
            scheduleLineAnchorFocusIfNeeded()
            return
        }
        scrollView.layoutIfNeeded()
        contentContainer.layoutIfNeeded()
        updateGutterForCurrentLayout()
        updateLineAnchorHighlight()
        scheduleLineAnchorFocusIfNeeded()
    }

    private func setup() {
        backgroundColor = palette.ui.bgDark

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = alwaysBounceVertical
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)

        virtualizedLayout.minimumLineSpacing = 0
        virtualizedLayout.minimumInteritemSpacing = 0
        virtualizedLayout.scrollDirection = .vertical
        virtualizedCollectionView.translatesAutoresizingMaskIntoConstraints = false
        virtualizedCollectionView.backgroundColor = palette.ui.bgDark
        virtualizedCollectionView.alwaysBounceVertical = alwaysBounceVertical
        virtualizedCollectionView.showsVerticalScrollIndicator = true
        virtualizedCollectionView.dataSource = self
        virtualizedCollectionView.delegate = self
        virtualizedCollectionView.isHidden = !usesVirtualizedRendering
        virtualizedCollectionView.register(
            FullScreenCodeChunkCell.self,
            forCellWithReuseIdentifier: FullScreenCodeChunkCell.reuseIdentifier
        )
        addSubview(virtualizedCollectionView)
        scrollView.isHidden = usesVirtualizedRendering

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentContainer)

        // Gutter — draws line numbers at the exact TextKit fragment Y for each
        // logical source line, so soft-wrapped continuations stay unnumbered.
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        gutterView.font = codeFont
        gutterView.textColor = palette.ui.comment
        contentContainer.addSubview(gutterView)

        let (_, baseGutterWidth) = lineNumberInfo(
            lineCount: lineCount,
            startLine: startLine,
            font: codeFont
        )
        let gutterWidth = baseGutterWidth + (lineAnchor == nil ? 0 : 10)

        // Separator
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = palette.ui.comment.withAlphaComponent(0.2)
        contentContainer.addSubview(separatorView)

        // Code text
        codeTextView.translatesAutoresizingMaskIntoConstraints = false
        codeTextView.font = codeFont
        codeTextView.textColor = palette.ui.fg
        codeTextView.backgroundColor = .clear
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isScrollEnabled = false
        codeTextView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        codeTextView.textContainer.lineFragmentPadding = 0
        applyWrapMode()
        if !usesVirtualizedRendering {
            codeTextView.text = content
        }
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

            virtualizedCollectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            virtualizedCollectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            virtualizedCollectionView.topAnchor.constraint(equalTo: topAnchor),
            virtualizedCollectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

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

    func applyPalette(_ newPalette: ThemePalette, themeID: ThemeID = ThemeRuntimeState.currentThemeID()) {
        guard themeID != appliedThemeID else { return }
        appliedThemeID = themeID
        highlightThemeID = themeID
        palette = newPalette
        backgroundColor = palette.ui.bgDark
        scrollView.backgroundColor = palette.ui.bgDark
        gutterView.textColor = palette.ui.comment
        separatorView.backgroundColor = palette.ui.comment.withAlphaComponent(0.2)
        virtualizedCollectionView.backgroundColor = palette.ui.bgDark
        if usesVirtualizedRendering {
            resetVirtualizedAttributedChunks()
            virtualizedCollectionView.reloadData()
            prepareVisibleChunkRunway()
        } else {
            if highlightedSourceText == nil {
                codeTextView.textColor = palette.ui.fg
            }
            highlightTask?.cancel()
            loadHighlighting()
            invalidateGutterLayout()
        }
    }

    private func loadHighlighting() {
        let syntaxLang = language.flatMap { $0.isEmpty ? nil : SyntaxLanguage.detect($0) } ?? .unknown
        if usesVirtualizedRendering {
            loadVirtualizedIndex(language: syntaxLang)
            return
        }
        guard syntaxLang != .unknown else { return }

        let text = content
        let themeID = highlightThemeID
        #if DEBUG
        debugHighlightWorkCountForTesting += 1
        #endif
        highlightTask = Task { [weak self] in
            #if DEBUG
            if let delay = Self.highlightDelayForTesting {
                try? await Task.sleep(for: delay)
            }
            #endif
            guard !Task.isCancelled else { return }
            // Use SendableNSAttributedString to avoid the lossy
            // NSAttributedString → AttributedString → NSAttributedString round-trip
            // that can corrupt UIKit's internal NSMutableRLEArray. (APPLE-IOS-1Y)
            let highlighted = await Task.detached(priority: .userInitiated) {
                let start = DispatchTime.now().uptimeNanoseconds
                let wrapper = SendableNSAttributedString(
                    SyntaxHighlighter.highlight(
                        text,
                        language: syntaxLang,
                        themeID: themeID
                    )
                )
                let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                return (wrapper, Double(elapsed) / 1_000_000)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.highlightThemeID == themeID else { return }
                let installStart = DispatchTime.now().uptimeNanoseconds
                self.highlightedSourceText = highlighted.0.value
                self.codeTextView.setAttributedTextPreservingSelection(fullScreenAttributedCodeText(
                    from: highlighted.0.value,
                    font: self.codeFont
                ))
                #if DEBUG
                self.debugHighlightMilliseconds = highlighted.1
                self.debugAttributedInstallMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds &- installStart
                ) / 1_000_000
                #endif
                self.invalidateGutterLayout()
            }
        }
    }

    private func loadVirtualizedIndex(language: SyntaxLanguage) {
        virtualizedGeneration += 1
        let generation = virtualizedGeneration
        let source = content
        let firstLine = startLine
        let chunkLineLimit = Self.virtualizedChunkLineLimit
        let chunkUTF16Limit = Self.virtualizedChunkUTF16Limit
        resetVirtualizedAttributedChunks()
        virtualizedIndex = nil
        virtualizedCollectionView.reloadData()
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            guard let built = await withCancellableDetachedTask(
                priority: .userInitiated,
                operation: {
                    let indexRanOnMainThread = Self.isMainThreadForDiagnostics()
                    let index = FullScreenCodeChunkIndex.build(
                        source: source,
                        language: language,
                        startLine: firstLine,
                        maxLines: chunkLineLimit,
                        maxUTF16: chunkUTF16Limit
                    )
                    return (index, indexRanOnMainThread)
                }
            ), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, generation == self.virtualizedGeneration else { return }
                self.virtualizedIndex = built.0
                #if DEBUG
                self.debugHighlightMilliseconds = built.0.highlightMilliseconds
                self.debugIndexRanOnMainThread = built.1
                #endif
                self.virtualizedCollectionView.reloadData()
                self.virtualizedLayout.invalidateLayout()
                self.virtualizedCollectionView.layoutIfNeeded()
                self.prepareVisibleChunkRunway()
                self.focusVirtualizedLineAnchorIfNeeded()
            }
        }
    }

    private func resetVirtualizedAttributedChunks() {
        chunkRenderTasks.values.forEach { $0.cancel() }
        chunkRenderTasks.removeAll()
        attributedChunkCache.removeAll()
        attributedChunkLRU.removeAll()
    }

    private func applyTextSize() {
        let font = codeFont
        if usesVirtualizedRendering {
            resetVirtualizedAttributedChunks()
            virtualizedCollectionView.reloadData()
            virtualizedLayout.invalidateLayout()
            prepareVisibleChunkRunway()
            return
        }
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
        if usesVirtualizedRendering {
            virtualizedCollectionView.alwaysBounceHorizontal = !wraps
            virtualizedCollectionView.showsHorizontalScrollIndicator = !wraps
            if wraps {
                virtualizedCollectionView.contentOffset.x = -virtualizedCollectionView.adjustedContentInset.left
            }
            for cell in virtualizedCollectionView.visibleCells.compactMap({ $0 as? FullScreenCodeChunkCell }) {
                cell.textView.textContainer.lineBreakMode = wraps ? .byCharWrapping : .byClipping
            }
            virtualizedLayout.invalidateLayout()
            return
        }
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

        let layoutStart = DispatchTime.now().uptimeNanoseconds
        gutterView.font = codeFont
        gutterView.textColor = palette.ui.comment
        gutterView.rows = lineNumberRowsForCurrentLayout()
        #if DEBUG
        debugLayoutGutterMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds &- layoutStart
        ) / 1_000_000
        #endif
    }

    private func updateLineAnchorHighlight() {
        guard let resolution = lineAnchorResolution,
              let existingRange = resolution.existingRange else {
            codeTextView.setLineAnchorHighlight(
                rects: [],
                fillColor: palette.ui.blue.withAlphaComponent(0.08),
                strokeColor: palette.ui.blue.withAlphaComponent(0.75)
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
            fillColor: palette.ui.blue.withAlphaComponent(0.08),
            strokeColor: palette.ui.blue.withAlphaComponent(0.75)
        )
    }

    private func scheduleLineAnchorFocusIfNeeded() {
        guard lineAnchorFocusPending, lineAnchorFocusTask == nil else { return }
        lineAnchorFocusTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.lineAnchorFocusTask = nil
            if self.usesVirtualizedRendering {
                self.focusVirtualizedLineAnchorIfNeeded()
                return
            }
            guard self.scrollView.bounds.height > 0 else {
                self.lineAnchorFocusPending = true
                return
            }
            self.lineAnchorFocusPending = false
            self.scrollLineAnchorIntoUpperThird()
        }
    }

    private func focusVirtualizedLineAnchorIfNeeded() {
        guard lineAnchorFocusPending,
              let resolution = lineAnchorResolution,
              let index = virtualizedIndex,
              !index.chunks.isEmpty,
              virtualizedCollectionView.bounds.height > 0 else { return }
        let targetLine = resolution.existingRange?.lowerBound
            ?? index.chunks.last?.sourceLineRange.upperBound
            ?? startLine
        let chunkIndex = index.chunks.firstIndex { $0.sourceLineRange.contains(targetLine) }
            ?? index.chunks.index(before: index.chunks.endIndex)
        let indexPath = IndexPath(item: chunkIndex, section: 0)
        virtualizedCollectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        virtualizedCollectionView.layoutIfNeeded()
        prepareVisibleChunkRunway()

        guard let existingRange = resolution.existingRange else {
            let minimumY = -virtualizedCollectionView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                virtualizedCollectionView.contentSize.height
                    - virtualizedCollectionView.bounds.height
                    + virtualizedCollectionView.adjustedContentInset.bottom
            )
            virtualizedCollectionView.setContentOffset(
                CGPoint(x: virtualizedCollectionView.contentOffset.x, y: maximumY),
                animated: false
            )
            lineAnchorFocusPending = false
            return
        }
        guard existingRange.contains(targetLine),
              let cell = virtualizedCollectionView.cellForItem(at: indexPath) as? FullScreenCodeChunkCell,
              let firstRect = cell.lineAnchorFirstContentRectInCell() else {
            return
        }

        let rectInCollection = cell.convert(firstRect, to: virtualizedCollectionView)
        let minimumY = -virtualizedCollectionView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            virtualizedCollectionView.contentSize.height
                - virtualizedCollectionView.bounds.height
                + virtualizedCollectionView.adjustedContentInset.bottom
        )
        let targetY = rectInCollection.minY - virtualizedCollectionView.bounds.height / 3
        let clampedY = min(max(targetY, minimumY), maximumY)
        guard clampedY.isFinite else { return }
        virtualizedCollectionView.setContentOffset(
            CGPoint(x: virtualizedCollectionView.contentOffset.x, y: clampedY),
            animated: false
        )
        lineAnchorFocusPending = false
        UIAccessibility.post(notification: .layoutChanged, argument: cell.textView)
        cell.textView.accessibilityLabel = "Source code"
        cell.textView.accessibilityValue = resolution.accessibilityLabel
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

    private var currentGutterWidth: CGFloat {
        let (_, baseWidth) = lineNumberInfo(
            lineCount: lineCount,
            startLine: startLine,
            font: codeFont
        )
        return baseWidth + (lineAnchor == nil ? 0 : 10)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        virtualizedIndex?.chunks.count ?? 0
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: FullScreenCodeChunkCell.reuseIdentifier,
            for: indexPath
        ) as? FullScreenCodeChunkCell,
              let index = virtualizedIndex,
              index.chunks.indices.contains(indexPath.item) else {
            return UICollectionViewCell()
        }
        let chunk = index.chunks[indexPath.item]
        cell.textView.delegate = self
        cell.textView.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
        cell.textView.reviewCommentSourceLineRangeResolver = { [weak textView = cell.textView] range in
            guard let textView,
                  let local = ReviewCommentSelectionEditMenuSupport.textLineRange(
                    in: textView.textStorage.string,
                    range: range
                  ) else { return nil }
            return (chunk.startLine + local.lowerBound - 1)...(chunk.startLine + local.upperBound - 1)
        }
        cell.onLayoutGutterMeasured = { [weak self] milliseconds in
            #if DEBUG
            self?.debugLayoutGutterMilliseconds += milliseconds
            #endif
        }
        let installStart = DispatchTime.now().uptimeNanoseconds
        cell.configure(
            chunk: chunk,
            attributedText: attributedChunkCache[indexPath.item],
            font: codeFont,
            gutterWidth: currentGutterWidth,
            wrapsText: readerPreferences.wrapsText,
            palette: palette,
            lineAnchorResolution: lineAnchorResolution
        )
        #if DEBUG
        debugAttributedInstallMilliseconds += Double(
            DispatchTime.now().uptimeNanoseconds &- installStart
        ) / 1_000_000
        #endif
        scheduleChunkRender(indexPath.item)
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let viewportWidth = max(1, collectionView.bounds.width)
        let width = readerPreferences.wrapsText
            ? viewportWidth
            : max(viewportWidth, estimatedUnwrappedCodeWidth())
        guard let index = virtualizedIndex,
              index.chunks.indices.contains(indexPath.item) else {
            return CGSize(width: width, height: codeFont.lineHeight + 16)
        }
        let chunk = index.chunks[indexPath.item]
        let visualLines: Int
        if readerPreferences.wrapsText {
            let glyphWidth = max(1, ("M" as NSString).size(withAttributes: [.font: codeFont]).width)
            let textWidth = max(1, viewportWidth - currentGutterWidth - 25)
            let columns = max(1, Int(textWidth / glyphWidth))
            visualLines = chunk.lineUTF16Lengths.reduce(into: 0) { count, lineLength in
                count += max(1, (lineLength + columns - 1) / columns)
            }
        } else {
            visualLines = max(1, chunk.lineUTF16Lengths.count)
        }
        return CGSize(width: width, height: CGFloat(visualLines) * codeFont.lineHeight + 16)
    }

    private func estimatedUnwrappedCodeWidth() -> CGFloat {
        let columns = virtualizedIndex?.widestLineUTF16Count ?? 0
        let glyphWidth = max(1, ("M" as NSString).size(withAttributes: [.font: codeFont]).width)
        return min(
            Self.maxEstimatedCodeWidth,
            ceil(CGFloat(columns) * glyphWidth + currentGutterWidth + 25)
        )
    }

    private func prepareVisibleChunkRunway() {
        guard usesVirtualizedRendering else { return }
        let visible = virtualizedCollectionView.indexPathsForVisibleItems.map(\.item)
        guard let first = visible.min(), let last = visible.max(),
              let index = virtualizedIndex, !index.chunks.isEmpty else { return }
        for chunkIndex in max(0, first - 2)...min(index.chunks.count - 1, last + 2) {
            scheduleChunkRender(chunkIndex)
        }
    }

    private func scheduleChunkRender(_ chunkIndex: Int) {
        guard attributedChunkCache[chunkIndex] == nil,
              chunkRenderTasks[chunkIndex] == nil,
              let index = virtualizedIndex,
              index.chunks.indices.contains(chunkIndex) else { return }
        let chunk = index.chunks[chunkIndex]
        let generation = virtualizedGeneration
        let themeID = highlightThemeID
        chunkRenderTasks[chunkIndex] = Task { [weak self] in
            guard let wrapper = await withCancellableDetachedTask(
                priority: .userInitiated,
                operation: {
                    let attributed = NSMutableAttributedString(
                        string: chunk.text,
                        attributes: [.foregroundColor: themeID.palette.ui.syntaxVariable]
                    )
                    for token in chunk.tokenRanges where token.kind != .variable {
                        guard let color = SyntaxHighlighter.color(for: token.kind, themeID: themeID) else {
                            continue
                        }
                        let range = NSRange(location: token.location, length: token.length)
                        guard NSMaxRange(range) <= attributed.length else { continue }
                        attributed.addAttribute(.foregroundColor, value: color, range: range)
                    }
                    return SendableNSAttributedString(attributed)
                }
            ), !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      generation == self.virtualizedGeneration,
                      themeID == self.highlightThemeID else { return }
                self.chunkRenderTasks[chunkIndex] = nil
                let attributed = fullScreenAttributedCodeText(
                    from: wrapper.value,
                    font: self.codeFont
                )
                self.cacheAttributedChunk(attributed, at: chunkIndex)
                if let cell = self.virtualizedCollectionView.cellForItem(
                    at: IndexPath(item: chunkIndex, section: 0)
                ) as? FullScreenCodeChunkCell {
                    let installStart = DispatchTime.now().uptimeNanoseconds
                    cell.installAttributedText(attributed)
                    cell.layoutIfNeeded()
                    self.focusVirtualizedLineAnchorIfNeeded()
                    #if DEBUG
                    self.debugAttributedInstallMilliseconds += Double(
                        DispatchTime.now().uptimeNanoseconds &- installStart
                    ) / 1_000_000
                    #endif
                }
            }
        }
    }

    private func cacheAttributedChunk(_ attributed: NSAttributedString, at index: Int) {
        attributedChunkCache[index] = attributed
        attributedChunkLRU.removeAll { $0 == index }
        attributedChunkLRU.append(index)
        let visible = Set(virtualizedCollectionView.indexPathsForVisibleItems.map(\.item))
        while attributedChunkCache.count > Self.attributedChunkCacheLimit,
              let candidate = attributedChunkLRU.first(where: { !visible.contains($0) }) {
            attributedChunkCache[candidate] = nil
            attributedChunkLRU.removeAll { $0 == candidate }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === virtualizedCollectionView else { return }
        prepareVisibleChunkRunway()
    }

#if DEBUG
    var debugLineAnchorExistingRangeForTesting: ClosedRange<Int>? {
        lineAnchorResolution?.existingRange
    }

    var debugLineAnchorHighlightRectCountForTesting: Int {
        if usesVirtualizedRendering {
            return virtualizedCollectionView.visibleCells
                .compactMap { $0 as? FullScreenCodeChunkCell }
                .reduce(into: 0) { $0 += $1.debugLineAnchorHighlightRectCount }
        }
        return codeTextView.debugLineAnchorHighlightRectCountForTesting
    }

    var debugLineAnchorFirstHighlightRectForTesting: CGRect? {
        if usesVirtualizedRendering {
            for cell in virtualizedCollectionView.visibleCells.compactMap({ $0 as? FullScreenCodeChunkCell }) {
                if let rect = cell.debugLineAnchorFirstHighlightRect {
                    return cell.convert(rect, to: virtualizedCollectionView)
                }
            }
            return nil
        }
        return codeTextView.debugLineAnchorFirstHighlightRectForTesting
    }

    var debugLineAnchorHighlightEnclosureRectForTesting: CGRect? {
        codeTextView.debugLineAnchorHighlightEnclosureRectForTesting
    }

    var debugLineAnchorHighlightHasVisibleGeometryForTesting: Bool {
        if usesVirtualizedRendering {
            for cell in virtualizedCollectionView.visibleCells.compactMap({ $0 as? FullScreenCodeChunkCell }) {
                guard cell.debugLineAnchorContainsFirstTarget,
                      let rect = cell.debugLineAnchorFirstHighlightRect else { continue }
                let rectInCollection = cell.convert(rect, to: virtualizedCollectionView)
                if rectInCollection.intersects(virtualizedCollectionView.bounds) {
                    return true
                }
            }
            return false
        }
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
        if usesVirtualizedRendering {
            return virtualizedCollectionView.visibleCells
                .compactMap { $0 as? FullScreenCodeChunkCell }
                .reduce(into: 0) { $0 += $1.debugLineAnchorGutterMarkerCount }
        }
        updateGutterForCurrentLayout()
        return gutterView.rows.filter(\.showsHighlightMarker).count
    }

    var debugLineAnchorScrollOffsetForTesting: CGPoint {
        usesVirtualizedRendering ? virtualizedCollectionView.contentOffset : scrollView.contentOffset
    }

    var debugLineAnchorViewportHeightForTesting: CGFloat {
        usesVirtualizedRendering ? virtualizedCollectionView.bounds.height : scrollView.bounds.height
    }

    var debugLineAnchorContentHeightForTesting: CGFloat {
        usesVirtualizedRendering ? virtualizedCollectionView.contentSize.height : scrollView.contentSize.height
    }

    struct PerformanceDiagnostics {
        let highlightMilliseconds: Double
        let attributedInstallMilliseconds: Double
        let layoutGutterMilliseconds: Double
        let retainedSourceUTF16Count: Int
        let totalChunkCount: Int
        let cachedChunkCount: Int
        let mountedUTF16Count: Int
        let mountedChunkCount: Int
        let indexRanOnMainThread: Bool?
    }

    func performanceDiagnosticsForTesting() -> PerformanceDiagnostics {
        if usesVirtualizedRendering {
            let cells = virtualizedCollectionView.visibleCells.compactMap {
                $0 as? FullScreenCodeChunkCell
            }
            return PerformanceDiagnostics(
                highlightMilliseconds: debugHighlightMilliseconds,
                attributedInstallMilliseconds: debugAttributedInstallMilliseconds,
                layoutGutterMilliseconds: debugLayoutGutterMilliseconds,
                retainedSourceUTF16Count: virtualizedIndex?.sourceUTF16Count ?? (content as NSString).length,
                totalChunkCount: virtualizedIndex?.chunks.count ?? 0,
                cachedChunkCount: attributedChunkCache.count,
                mountedUTF16Count: cells.reduce(into: 0) { $0 += $1.textView.textStorage.length },
                mountedChunkCount: cells.count,
                indexRanOnMainThread: debugIndexRanOnMainThread
            )
        }
        return PerformanceDiagnostics(
            highlightMilliseconds: debugHighlightMilliseconds,
            attributedInstallMilliseconds: debugAttributedInstallMilliseconds,
            layoutGutterMilliseconds: debugLayoutGutterMilliseconds,
            retainedSourceUTF16Count: (content as NSString).length,
            totalChunkCount: codeTextView.textStorage.length == 0 ? 0 : 1,
            cachedChunkCount: codeTextView.textStorage.length == 0 ? 0 : 1,
            mountedUTF16Count: codeTextView.textStorage.length,
            mountedChunkCount: codeTextView.textStorage.length == 0 ? 0 : 1,
            indexRanOnMainThread: nil
        )
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

extension NativeFullScreenCodeBody: ReaderBody {
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
