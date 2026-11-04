import UIKit

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
        contentView.clipsToBounds = true
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
        segmentApplier.releaseVideoViewOwnership()
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
            if let videoView = view as? NativeMarkdownVideoView {
                videoView.setPlaybackVisible(true)
            }
        }
        stackView.invalidateIntrinsicContentSize()
        contentView.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    fileprivate func setVideoPlaybackVisible(_ visible: Bool) {
        for view in stackView.arrangedSubviews {
            (view as? NativeMarkdownVideoView)?.setPlaybackVisible(visible)
        }
    }

    fileprivate func observePreparedImageGeometry(_ handler: @escaping (CGFloat) -> Void) {
        segmentApplier.onImagePreparedGeometry = handler
        segmentApplier.onVideoPreparedGeometry = handler
        for view in stackView.arrangedSubviews {
            if let imageView = view as? NativeMarkdownImageView {
                imageView.onPreparedGeometry = handler
            }
            if let videoView = view as? NativeMarkdownVideoView {
                videoView.onPreparedGeometry = handler
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
        doubleTapActivation: (() -> Void)?
    ) {
        // The source-line enclosure is painted by the reader's overlay. Keep
        // the arranged content at the ledger's canonical width instead of
        // consuming 28 points here after graphical artifacts were prepared.
        stackLeadingConstraint?.constant = 0
        _ = lineAnchorModeEnabled
        self.textViewDelegate = textViewDelegate
        self.doubleTapActivation = doubleTapActivation
    }

    func apply(
        segment: FlatSegment,
        config: AssistantMarkdownContentView.Configuration,
        sourceLineRange: ClosedRange<Int>?,
        lineAnchorModeEnabled: Bool,
        palette: ThemePalette,
        textViewDelegate: any UITextViewDelegate,
        doubleTapActivation: (() -> Void)?,
        canonicalWidth: CGFloat? = nil,
        preparesImagesForDisplay: Bool = true
    ) {
        // Source-line chrome overlays the cell; arranged content always uses
        // the same canonical width used by the ledger and artifact renderers.
        stackLeadingConstraint?.constant = 0
        _ = lineAnchorModeEnabled
        self.textViewDelegate = textViewDelegate
        self.doubleTapActivation = doubleTapActivation
        segmentApplier.preparationWidth = canonicalWidth
        segmentApplier.preparesImagesForDisplay = preparesImagesForDisplay
        segmentApplier.videoPlaybackVisible = preparesImagesForDisplay
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
    /// Completed documents at least this large render after a visible shell, not inline.
    static let defaultDeferredInitialRenderByteThreshold = 200 * 1024
    private let deferredInitialRenderByteThreshold: Int
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
    private var pendingDocumentLayoutReason: MarkdownReaderLayoutReplacementReason = .document
    private var isConfiguringCell = false
    private var pendingHeightFlush = false
    private var pendingForcedItemRemeasure = false
    private weak var pendingForcedItemRemeasureSourceView: UIView?
    private var pendingForcedItemRemeasureToken: MarkdownReaderHeightLedger.WorkToken?
    private var heightFlushGeneration = 0
    /// A collected height change owes the collection a layout replacement, but
    /// not during the pass that collected it: a swap from inside `willDisplay`
    /// strands the cells that pass prepared. The height flush honours the flag.
    private var needsLayoutReplaceAfterInteraction = false
    private var needsVisibleHeightRefreshAfterInteraction = false
    private var pendingLayoutReplaceAfterInteractionRetry = false
    private var isReplacingCollectionLayout = false
    #if DEBUG
    private var debugIsCollectionUserInteractingOverride: Bool?
    #endif
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
    /// Offset or anchor writes while a gesture owns the viewport.
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
    private let sourceFormat: MarkdownReaderSourceFormat
    /// False when each top-level block keeps its own segment: a book chapter
    /// merges into one text view otherwise, which is expensive to lay out and
    /// leaves no block to restore a reading position to.
    private let mergesAdjacentTextSegments: Bool
    private let themeID: ThemeID
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?
    private var textSelectionEnabled: Bool
    /// Bound at construction. The reader never re-derives identity, and its
    /// providers are the ones its owner supplied for this document.
    private let resourceAccess: MarkdownResourceAccess
    private let sourceFilePath: String?
    private let lineAnchor: SourceLineAnchor?
    private let lineAnchorResolution: SourceLineAnchorResolution?
    private let maximumViewportHeight: CGFloat?
    /// A reader that cannot scroll (the inline tool viewport) shows only the top
    /// of its document, and the full document opens in the full-screen reader.
    /// Its owner names the tallest the viewport can ever be, and the reader
    /// lays out each text segment only that far down. The owner sizes the
    /// viewport after the first layout, so the ceiling is used instead of the
    /// height the reader happens to have then. A hand-off that restores the
    /// tail or a mid-document position needs the whole text, so that intent
    /// turns the trim off.
    private let visibleHeightCeiling: CGFloat?
    private var trimsTextToViewport: Bool
    /// The document's text segments as built, while `renderedSegments` holds
    /// them trimmed. Nil when nothing is trimmed.
    private var untrimmedSegments: [FlatSegment]?
    private var intrinsicViewportContentHeight: CGFloat = 44
    private var readerPreferences: FullScreenReaderPreferences
    /// Book typography for this document, when its owner is a book reader.
    /// Nil keeps the app's chat metrics.
    private var bookAppearance: BookReaderAppearance?

    private let perfSurface: MarkdownStreamingPerf.Surface?

    private var sourcePreparationTask: Task<Void, Never>?
    private var deferredInitialRenderTask: Task<Void, Never>?
    private var asyncRenderTask: Task<Void, Never>?
    private var renderAheadTask: Task<Void, Never>?
    private var scheduledRenderAheadFirstVisibleItem: Int?
    private var latestSnapshot: ThinkingSnapshot
    private var pendingReaderPreferences: FullScreenReaderPreferences?
    private var renderedSnapshot: ThinkingSnapshot?
    /// Configuration can change while the source snapshot stays byte-identical.
    /// Keep that independent from `renderedSnapshot` so append detection and
    /// interaction deferral retain the mounted document.
    private var needsSnapshotReconfiguration = false
    private var pendingReconfigurationLayoutReason: MarkdownReaderLayoutReplacementReason?
    private var renderedSegments: [FlatSegment] = []
    private var renderedSegmentLineRanges: [ClosedRange<Int>?] = []
    private var renderedSegmentIDs: [MarkdownReaderSegmentID] = []
    private var currentConfig: AssistantMarkdownContentView.Configuration?
    private var viewportDoubleTapActivation: (() -> Void)?
    private var lineAnchorFocusTask: Task<Void, Never>?
    private var lineAnchorFocusPending = false
    private var pendingMutableTransitionViewportIntent: FullScreenMarkdownViewportIntent?
    /// False from `restoreViewportAfterMutableTransition` until the async
    /// explicit-focus write runs, or the user takes the viewport. Offset 0
    /// before that write is not a settled `.top`.
    private var markdownViewportRestoreSettled = true

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
        sourceFormat: MarkdownReaderSourceFormat = .markdown,
        themeID: ThemeID? = nil,
        palette: ThemePalette,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?,
        textSelectionEnabled: Bool = true,
        resourceAccess: MarkdownResourceAccess = .empty,
        sourceFilePath: String? = nil,
        lineAnchor: SourceLineAnchor? = nil,
        focusLineAnchor: Bool = true,
        readerPreferences: FullScreenReaderPreferences = FullScreenReaderContentFamily.markdown.defaultPreferences,
        bookAppearance: BookReaderAppearance? = nil,
        perfSurface: MarkdownStreamingPerf.Surface? = nil,
        maximumViewportHeight: CGFloat? = nil,
        allowsVerticalBounce: Bool = true,
        allowsVerticalScrolling: Bool = true,
        visibleHeightCeiling: CGFloat? = nil,
        deferredInitialRenderByteThreshold: Int = NativeFullScreenMarkdownBody.defaultDeferredInitialRenderByteThreshold,
        mergeAdjacentTextSegments: Bool = true
    ) {
        self.sourceFormat = sourceFormat
        self.mergesAdjacentTextSegments = mergeAdjacentTextSegments
        self.deferredInitialRenderByteThreshold = deferredInitialRenderByteThreshold
        self.themeID = themeID ?? ThemeRuntimeState.currentThemeID()
        self.perfSurface = perfSurface
        self.reviewCommentSelectionRouter = reviewCommentSelectionRouter
        self.reviewCommentSourceContext = reviewCommentSourceContext
        self.textSelectionEnabled = textSelectionEnabled
        self.resourceAccess = resourceAccess
        self.sourceFilePath = sourceFilePath
        self.lineAnchor = lineAnchor
        let initialText = content
        self.lineAnchorResolution = lineAnchor?.resolution(fileContent: initialText)
        self.readerPreferences = readerPreferences
        self.bookAppearance = bookAppearance
        self.maximumViewportHeight = maximumViewportHeight
        self.visibleHeightCeiling = allowsVerticalScrolling ? nil : visibleHeightCeiling
        self.trimsTextToViewport = !allowsVerticalScrolling && visibleHeightCeiling != nil
        self.lineAnchorFocusPending = lineAnchor != nil && focusLineAnchor
        let initialSnapshot = sourceFormat == .markdown
            ? ThinkingSnapshot(text: content, isDone: true)
            : ThinkingSnapshot(text: "", isDone: true)
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
            guard let self else { return }
            self.debugOffsetWriteReasons.append(reason)
            if self.isCollectionUserInteracting {
                self.debugVisibleHeightCorrectionDuringInteractionCount += 1
            }
        }
        #endif

        backgroundColor = bookAppearance?.backgroundColor(in: palette) ?? palette.ui.bgDark

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = bookAppearance?.backgroundColor(in: palette) ?? palette.ui.bgDark
        collectionView.alwaysBounceVertical = allowsVerticalBounce && allowsVerticalScrolling
        collectionView.bounces = allowsVerticalBounce && allowsVerticalScrolling
        collectionView.isScrollEnabled = allowsVerticalScrolling
        collectionView.showsVerticalScrollIndicator = allowsVerticalScrolling
        if !allowsVerticalScrolling {
            // Inline expanded tool rows nest this reader inside a rounded card.
            // Default iOS 26 edge overlays escape that clip and cover the border.
            collectionView.contentInsetAdjustmentBehavior = .never
            collectionView.topEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
            collectionView.leftEdgeEffect.isHidden = true
            collectionView.rightEdgeEffect.isHidden = true
        }
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
            scheduleOrgModeSourcePreparation(source: content)
        } else if shouldDeferInitialRender(snapshot: initialSnapshot) {
            installDeferredRenderPlaceholder(palette: palette)
            scheduleDeferredInitialRender(snapshot: initialSnapshot)
        } else {
            render(snapshot: initialSnapshot)
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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if needsDocumentLayoutPreparation
            || preparedCanonicalWidth.map({ abs($0 - canonicalContentWidth) > 0.5 }) == true {
            prepareLazyDocumentLayout(layoutReason: pendingDocumentLayoutReason)
        }
        retryDeferredLayoutReplaceIfInteractionEnded()
        updateLineAnchorHighlight()
        scheduleLineAnchorFocusIfNeeded()
        applyPendingMutableTransitionViewportIntentIfReady()
        viewportOwner.scheduleFollowTail()
    }

    private func shouldDeferInitialRender(
        snapshot: ThinkingSnapshot
    ) -> Bool {
        snapshot.text.utf8.count >= deferredInitialRenderByteThreshold
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
        label.textColor = palette.ui.fgDim
        label.font = AppFont.systemFeedback
        label.adjustsFontForContentSizeCategory = true
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
            self.applyPreparedDocument(prepared.markdown)
        }
    }

    private func scheduleDeferredInitialRender(snapshot: ThinkingSnapshot) {
        deferredInitialRenderTask?.cancel()
        deferredInitialRenderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.deferredInitialRenderDelayMs))
            guard let self, !Task.isCancelled else { return }
            self.deferredInitialRenderTask = nil
            self.render(snapshot: snapshot)
        }
    }

    private func applyPreparedDocument(_ content: String) {
        deferredInitialRenderTask?.cancel()
        deferredInitialRenderTask = nil
        asyncRenderTask?.cancel()
        asyncRenderTask = nil
        renderAheadTask?.cancel()
        renderAheadTask = nil
        let snapshot = ThinkingSnapshot(text: content, isDone: true)
        latestSnapshot = snapshot
        render(snapshot: snapshot)
    }

    /// Restore the broad reading intent captured by the mutable one-scroll-view
    /// host. The immutable reader owns the actual offset write so it can clamp
    /// against its final render-ahead geometry without animation.
    func restoreViewportAfterMutableTransition(_ intent: FullScreenMarkdownViewportIntent) {
        if trimsTextToViewport, intent != .top {
            trimsTextToViewport = false
            if untrimmedSegments != nil {
                needsDocumentLayoutPreparation = true
            }
        }
        pendingMutableTransitionViewportIntent = intent
        markdownViewportRestoreSettled = false
        setNeedsLayout()
        applyPendingMutableTransitionViewportIntentIfReady()
    }

    /// False from a restore request until its offset write lands, so
    /// `viewportIntent` never reads the unrestored offset 0 as `.top`.
    private var hasSettledMarkdownViewportRestore: Bool {
        markdownViewportRestoreSettled
    }

    private func applyPendingMutableTransitionViewportIntentIfReady() {
        guard let intent = pendingMutableTransitionViewportIntent,
              deferredInitialRenderTask == nil,
              asyncRenderTask == nil,
              !needsDocumentLayoutPreparation,
              latestSnapshot.text.isEmpty || !renderedSegments.isEmpty else { return }
        pendingMutableTransitionViewportIntent = nil
        viewportOwner.scheduleExplicitFocus { [weak self] in
            guard let self else { return nil }
            self.layoutIfNeeded()
            self.collectionView.layoutIfNeeded()
            self.markdownViewportRestoreSettled = true
            return self.offsetY(forMutableTransition: intent)
        }
        // `scheduleExplicitFocus` no-ops when a gesture already owns the
        // viewport. The user's offset is then the settled position.
        if viewportOwner.isInteracting {
            markdownViewportRestoreSettled = true
        }
    }

    private func offsetY(
        forMutableTransition intent: FullScreenMarkdownViewportIntent
    ) -> CGFloat {
        let minimumY = -collectionView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        switch intent {
        case .top:
            return minimumY
        case .tail:
            return maximumY
        case .detached(let anchor):
            let rawY = offsetY(for: anchor) ?? anchor.absoluteOffset
            return min(max(rawY, minimumY), maximumY)
        }
    }

    private func offsetY(for anchor: FullScreenMarkdownViewportAnchor) -> CGFloat? {
        guard let segmentID = resolvedSegmentID(for: anchor),
              let item = renderedSegmentIDs.firstIndex(of: segmentID),
              itemHeights.indices.contains(item) else { return nil }
        let spacing = readerPreferences.spacing.markdownStackSpacing
        var itemMinY = CGFloat(10)
        if item > 0 {
            let prior = itemHeights[0..<item].reduce(0, +)
            itemMinY += prior + spacing * CGFloat(item)
        }
        return itemMinY + anchor.offsetInItem
    }

    private func resolvedSegmentID(
        for anchor: FullScreenMarkdownViewportAnchor
    ) -> MarkdownReaderSegmentID? {
        guard let segmentID = anchor.segmentID else { return nil }
        if renderedSegmentIDs.contains(segmentID) { return segmentID }
        return renderedSegmentIDs.first {
            $0.kind == segmentID.kind && $0.sourceStartLine == segmentID.sourceStartLine
        }
    }

    private func render(snapshot: ThinkingSnapshot) {
        guard snapshot != renderedSnapshot || needsSnapshotReconfiguration else {
            viewportOwner.scheduleFollowTail()
            return
        }

        // Keep the complete old snapshot mounted while a touch or momentum owns
        // the viewport. Parking even one cell before this gate blanks visible
        // content until interaction ends.
        if isCollectionUserInteracting, renderedSnapshot != nil {
            needsSnapshotReconfiguration = true
            return
        }
        let layoutReason = pendingReconfigurationLayoutReason ?? .document
        needsSnapshotReconfiguration = false
        pendingReconfigurationLayoutReason = nil

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
            resourceAccess: resourceAccess,
            sourceFilePath: sourceFilePath,
            lineAnchor: lineAnchor,
            readerPreferences: readerPreferences,
            bookAppearance: bookAppearance,
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
            mergeAdjacentTextSegments: mergesAdjacentTextSegments && lineAnchor == nil
        )
        renderedSegments = build.segments
        untrimmedSegments = nil
        renderedSegmentLineRanges = build.sourceLineRanges
        renderedSegmentIDs = build.identities
        #if DEBUG
        debugSegmentBuildNs = MarkdownStreamingPerf.timestampNs() - segmentBuildStart
        #endif
        prepareLazyDocumentLayout(
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
            && config.content.utf8.count >= deferredInitialRenderByteThreshold
    }

    private func renderLargeCompletedSnapshotAsync(
        snapshot: ThinkingSnapshot,
        config: AssistantMarkdownContentView.Configuration,
        cycleStart: UInt64,
        anchorOverride: ViewportAnchor?,
        layoutReason: MarkdownReaderLayoutReplacementReason
    ) {
        installDeferredRenderPlaceholder(palette: themeID.palette)
        renderedSegments = []
        untrimmedSegments = nil
        renderedSegmentLineRanges = []
        renderedSegmentIDs = []
        resetParkedSegmentViews()
        collectionView.reloadData()
        collectionView.collectionViewLayout.invalidateLayout()

        let source = config.content
        let themeID = config.themeID
        // `Identity` is `Sendable` data, so the detached build captures the same bound
        // source (including the checkout) that every synchronous path reads.
        let identity = config.resourceAccess.identity
        let sourceDirectory = config.sourceDirectory
        let mergesAdjacentTextSegments = mergesAdjacentTextSegments
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
                    serverID: identity.serverID,
                    workspaceID: identity.workspaceID,
                    sessionID: identity.sessionID,
                    serverBaseURL: identity.serverBaseURL,
                    sourceDirectory: sourceDirectory,
                    worktreeId: identity.worktreeId,
                    mergeAdjacentTextSegments: mergesAdjacentTextSegments
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
            self.untrimmedSegments = nil
            self.renderedSegmentLineRanges = build.build.sourceLineRanges
            self.renderedSegmentIDs = FlatSegment.readerSegmentIDs(
                segments: segments,
                sourceLineRanges: build.build.sourceLineRanges
            )
            self.prepareLazyDocumentLayout(
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

            self.applyPendingMutableTransitionViewportIntentIfReady()
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
        lineAnchorHighlightView.fillColor = themeID.palette.ui.blue.withAlphaComponent(0.08)
        lineAnchorHighlightView.strokeColor = themeID.palette.ui.blue.withAlphaComponent(0.75)
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
            doubleTapActivation: viewportDoubleTapActivation
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
        if renderedSegmentIDs.indices.contains(indexPath.item),
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
           ) == nil {
            #if DEBUG
            debugWillDisplayRenderAheadMissCount += 1
            #endif
            if !waitsForPreparedInternalGeometry(indexPath.item),
               let token = heightLedger.workToken(
                   for: renderedSegmentIDs[indexPath.item],
                   canonicalWidth: canonicalWidth
               ) {
                let width = cell.contentView.bounds.width > 0
                    ? cell.contentView.bounds.width
                    : canonicalWidth
                let commit = heightLedger.commitFinal(
                    token: token,
                    height: cell.measuredFittingHeight(width: width),
                    anchorID: captureViewportAnchorID()
                )
                if commit.accepted {
                    #if DEBUG
                    debugGeometryCommitCount += 1
                    #endif
                    itemHeights = heightLedger.heights()
                    // Swapping here would de-index the very cells this pass
                    // prepared; they would keep drawing at their old size.
                    needsLayoutReplaceAfterInteraction = true
                    scheduleHeightFlush()
                }
            }
            refreshGeometryPresentationForVisibleCells()
        }
        cell.setVideoPlaybackVisible(true)
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
        if let cell = cell as? FullScreenMarkdownSegmentCell {
            cell.setVideoPlaybackVisible(false)
        }
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
        guard let id = cell.appliedSegmentID else { return }
        let views = cell.yieldArrangedSegmentViews()
        guard !views.isEmpty else { return }
        discardParkedVideoViews(parkedSegmentViews[id] ?? [])
        parkedSegmentViews[id] = views
        let parkedWidth = preparedCanonicalWidth ?? canonicalContentWidth
        for view in views {
            (view as? NativeMarkdownVideoView)?.setPlaybackVisible(false)
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
        discardParkedVideoViews(parkedSegmentHost.subviews)
        parkedSegmentViews.removeAll()
    }

    private func discardParkedVideoViews(_ views: [UIView]) {
        for view in views {
            (view as? NativeMarkdownVideoView)?.prepareForRemoval()
            (view as? NativeMarkdownUSDZView)?.prepareForRemoval()
            view.removeFromSuperview()
        }
    }

    /// Install estimated geometry for the document, then synchronously settle a
    /// bounded initial runway. Views produced by runway sizing are parked and
    /// reused by the collection view, so preparation is not duplicate work.
    private func prepareLazyDocumentLayout(
        anchorOverride: ViewportAnchor? = nil,
        layoutReason: MarkdownReaderLayoutReplacementReason = .document
    ) {
        guard collectionView.bounds.width > 0 else {
            needsDocumentLayoutPreparation = true
            pendingDocumentLayoutReason = layoutReason
            return
        }
        guard !isCollectionUserInteracting || preparedCanonicalWidth == nil else {
            needsDocumentLayoutPreparation = true
            pendingDocumentLayoutReason = layoutReason
            return
        }

        let width = collectionView.bounds.width
        let canonicalWidth = max(1, width - 24)
        let anchor = anchorOverride ?? (!viewportOwner.followsTail ? captureViewportAnchor() : nil)

        needsDocumentLayoutPreparation = false
        pendingDocumentLayoutReason = .document
        preparedCanonicalWidth = canonicalWidth
        heightFlushGeneration &+= 1
        pendingHeightFlush = false
        scheduledRenderAheadFirstVisibleItem = nil
        needsLayoutReplaceAfterInteraction = false
        needsVisibleHeightRefreshAfterInteraction = false
        resetParkedSegmentViews()
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
        applyViewportTextTrim(width: width, canonicalWidth: canonicalWidth)
        let estimates = renderedSegments.map {
            Self.estimatedHeight(for: $0, containerWidth: width)
        }
        heightLedger.applyDocument(
            ids: renderedSegmentIDs,
            estimates: estimates,
            canonicalWidth: canonicalWidth
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
            timeBudgetNs: Self.maxInitialSynchronousPreparationNs,
            visibleThroughY: collectionView.bounds.height
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

    /// Points `renderedSegments` at the trimmed (or, once the trim is off, the
    /// full) text of the document. The segment list, line ranges, and IDs keep
    /// their shape: only the text inside a text segment gets shorter.
    private func applyViewportTextTrim(width: CGFloat, canonicalWidth: CGFloat) {
        guard trimsTextToViewport else {
            if let untrimmedSegments {
                renderedSegments = untrimmedSegments
                self.untrimmedSegments = nil
            }
            return
        }
        guard let viewportHeight = visibleHeightCeiling, let config = currentConfig else { return }
        let source = untrimmedSegments ?? renderedSegments
        var trimmed = source
        var didTrim = false
        for (item, segment) in source.enumerated() {
            guard case .text(let text) = segment,
                  let shorter = Self.viewportTrimmedText(
                      text,
                      viewportHeight: viewportHeight,
                      estimatedHeight: Self.estimatedHeight(for: segment, containerWidth: width),
                      measure: { [self] candidate in
                          measuredHeight(
                              of: .text(candidate),
                              item: item,
                              config: config,
                              canonicalWidth: canonicalWidth
                          )
                      }
                  ) else { continue }
            trimmed[item] = .text(shorter)
            didTrim = true
        }
        if didTrim {
            untrimmedSegments = source
            renderedSegments = trimmed
        }
    }

    /// The leading paragraphs of `text` whose laid-out height reaches
    /// `viewportHeight`, or nil when the text is short enough to keep whole.
    /// The first cut is proportional to the character-count estimate; the
    /// candidate is then measured, and the prefix grows until it fills the
    /// viewport. Text layout is top-down, so the visible part of a prefix is
    /// the same as the visible part of the whole.
    static func viewportTrimmedText(
        _ text: AttributedString,
        viewportHeight: CGFloat,
        estimatedHeight: CGFloat,
        measure: (AttributedString) -> CGFloat
    ) -> AttributedString? {
        let firstCutHeight = viewportHeight * 1.5
        guard estimatedHeight > firstCutHeight else { return nil }
        let characters = text.characters
        let total = characters.count
        var take = max(1, Int(Double(total) * Double(firstCutHeight / estimatedHeight)))
        while take < total {
            var cut = characters.index(characters.startIndex, offsetBy: take)
            // End on a paragraph boundary so the cut never splits a line the
            // viewport could show.
            while cut < characters.endIndex, characters[cut] != "\n" {
                cut = characters.index(after: cut)
            }
            if cut < characters.endIndex {
                cut = characters.index(after: cut)
            }
            guard cut < characters.endIndex else { return nil }
            let candidate = AttributedString(text[text.startIndex..<cut])
            if measure(candidate) >= viewportHeight {
                return candidate
            }
            take *= 2
        }
        return nil
    }

    private func measuredHeight(
        of segment: FlatSegment,
        item: Int,
        config: AssistantMarkdownContentView.Configuration,
        canonicalWidth: CGFloat
    ) -> CGFloat {
        let cell = FullScreenMarkdownSegmentCell(
            frame: CGRect(x: 0, y: 0, width: canonicalWidth, height: 1)
        )
        cell.contentView.bounds.size.width = canonicalWidth
        cell.bindReaderChrome(
            lineAnchorModeEnabled: lineAnchor != nil,
            textViewDelegate: self,
            doubleTapActivation: viewportDoubleTapActivation
        )
        cell.apply(
            segment: segment,
            config: config,
            sourceLineRange: renderedSegmentLineRanges.indices.contains(item)
                ? renderedSegmentLineRanges[item]
                : nil,
            lineAnchorModeEnabled: lineAnchor != nil,
            palette: themeID.palette,
            textViewDelegate: self,
            doubleTapActivation: viewportDoubleTapActivation,
            canonicalWidth: canonicalWidth,
            preparesImagesForDisplay: false
        )
        return cell.measuredFittingHeight(width: canonicalWidth)
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
        timeBudgetNs: UInt64 = .max,
        visibleThroughY: CGFloat = 0
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
              // The time budget bounds the runway below the first paint. An item
              // that starts inside the visible viewport is settled whatever the
              // clock says: leaving it to `willDisplay` repeats the same fit
              // inside the collection's layout pass and then replaces the layout.
              y <= visibleThroughY
                || MarkdownStreamingPerf.timestampNs() - started < timeBudgetNs {
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
            doubleTapActivation: viewportDoubleTapActivation
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
            discardParkedVideoViews(parkedSegmentViews[id] ?? [])
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
        let first = collectionView.indexPathsForVisibleItems.map(\.item).min() ?? 0
        guard scheduledRenderAheadFirstVisibleItem != first else { return }
        scheduledRenderAheadFirstVisibleItem = first
        scheduleRenderAheadSlices(
            fromItem: first,
            targetY: collectionView.contentOffset.y + collectionView.bounds.height * 3,
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
        case .video:
            return MarkdownInlineVideoLayout.reservedHeight(forWidth: contentWidth)
        case .audio:
            return MarkdownInlineAudioLayout.reservedHeight(forWidth: contentWidth)
        case .usdz:
            return MarkdownInlineUSDZLayout.reservedHeight(forWidth: contentWidth)
        case .mermaidDiagram(let code):
            // Mermaid parsing is too expensive for first paint. Estimate
            // from diagram source lines; the background prefetch renders
            // the real raster before the user reaches the item.
            let lineCount = CGFloat(countNewlines(code) + 1)
            return min(400, max(120, lineCount * 24 + 44))
        case .geoJSONMap:
            return 220
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
        // Hide only when this cell's own content geometry is unknowable.
        // A pending layout-height mismatch must not blank a visible cell.
        cell.setGeometryPresentationReady(!waitsForPreparedInternalGeometry(item))
    }

    private func refreshGeometryPresentationForVisibleCells() {
        for case let cell as FullScreenMarkdownSegmentCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            updateGeometryPresentation(on: cell, item: indexPath.item)
        }
    }

    /// Item-scoped wrap remasure for the full-screen reader. Absolute
    /// compositional heights ignore `invalidateLayout()`, so wrap/pretty-JSON
    /// growth has to commit through the ledger and replace the layout.
    func scheduleForcedItemRemeasure(from sourceView: UIView) {
        guard let cell = enclosingSegmentCell(from: sourceView),
              let id = cell.appliedSegmentID,
              let canonicalWidth = preparedCanonicalWidth,
              let token = heightLedger.workToken(
                  for: id,
                  canonicalWidth: canonicalWidth
              ) else { return }
        pendingForcedItemRemeasureSourceView = sourceView
        pendingForcedItemRemeasureToken = token
        guard !pendingForcedItemRemeasure else { return }
        pendingForcedItemRemeasure = true
        DispatchQueue.main.async { [weak self] in
            self?.performPendingForcedItemRemeasure()
        }
    }

    private func enclosingSegmentCell(from sourceView: UIView) -> FullScreenMarkdownSegmentCell? {
        var view: UIView? = sourceView
        while let current = view, current !== collectionView {
            if let cell = current as? FullScreenMarkdownSegmentCell {
                return cell
            }
            view = current.superview
        }
        return nil
    }

    private func performPendingForcedItemRemeasure() {
        if isConfiguringCell {
            DispatchQueue.main.async { [weak self] in
                self?.performPendingForcedItemRemeasure()
            }
            return
        }

        pendingForcedItemRemeasure = false
        let sourceView = pendingForcedItemRemeasureSourceView
        let token = pendingForcedItemRemeasureToken
        pendingForcedItemRemeasureSourceView = nil
        pendingForcedItemRemeasureToken = nil

        guard let token,
              token.generation == heightLedger.generation,
              let canonicalWidth = preparedCanonicalWidth,
              abs(canonicalWidth - token.canonicalWidth) <= 0.5,
              let sourceView,
              let cell = enclosingSegmentCell(from: sourceView),
              cell.appliedSegmentID == token.id,
              let item = renderedSegmentIDs.firstIndex(of: token.id),
              itemHeights.indices.contains(item) else { return }

        let next = cell.measuredFittingHeight(width: canonicalWidth)
        guard abs(itemHeights[item] - next) > 0.5 else { return }

        let commit = heightLedger.commitFinal(
            token: token,
            height: next,
            anchorID: captureViewportAnchorID()
        )
        guard commit.accepted else { return }
        #if DEBUG
        debugGeometryCommitCount += 1
        #endif
        itemHeights = heightLedger.heights()
        replaceCollectionLayout(
            preserveViewport: true,
            reason: .visibleReconciliation
        )
    }

    private func updateReservedHeight(
        token: MarkdownReaderHeightLedger.WorkToken,
        height: CGFloat
    ) {
        guard let item = renderedSegmentIDs.firstIndex(of: token.id),
              itemHeights.indices.contains(item),
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
        // What the person is looking at now. The flush restores this row rather
        // than re-reading the viewport, which intermediate swaps have moved.
        let queuedAnchor = captureViewportAnchor()
        let queuedAnchorOffset = collectionView.contentOffset.y
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.heightFlushGeneration == generation else { return }
            self.pendingHeightFlush = false
            guard !self.isCollectionUserInteracting else {
                self.needsVisibleHeightRefreshAfterInteraction = true
                return
            }
            // A height the display pass committed is already in the ledger, so the
            // refresh can report no change; the flag still owes the swap.
            let refreshedHeight = self.refreshVisibleReservedHeights()
            let anchor = abs(self.collectionView.contentOffset.y - queuedAnchorOffset) <= 0.5 ? queuedAnchor : nil
            guard self.needsLayoutReplaceAfterInteraction || refreshedHeight else {
                self.refreshGeometryPresentationForVisibleCells()
                return
            }
            self.replaceCollectionLayout(
                preserveViewport: true,
                reason: .visibleReconciliation,
                anchor: anchor
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
        reason: MarkdownReaderLayoutReplacementReason,
        anchor deferredAnchor: ViewportAnchor? = nil
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
            ? (deferredAnchor ?? captureViewportAnchor())
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
        if needsSnapshotReconfiguration {
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

    /// Capture the current reader position for a temporary navigation push.
    /// The segment anchor keeps the same paragraph visible when the reader is
    /// rebuilt; the absolute offset remains a safe fallback during partial
    /// render settlement.
    func currentViewportIntent() -> FullScreenMarkdownViewportIntent {
        let visibleAnchor = captureViewportAnchor().map {
            FullScreenMarkdownViewportAnchor(
                segmentID: $0.id,
                offsetInItem: $0.offsetInItem,
                absoluteOffset: collectionView.contentOffset.y
            )
        }
        return .capturing(
            scrollView: collectionView,
            followsTail: viewportOwner.followsTail,
            visibleAnchor: visibleAnchor
        )
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
        markdownViewportRestoreSettled = true
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

extension NativeFullScreenMarkdownBody: ReaderBody {
    var viewportIntent: FullScreenMarkdownViewportIntent? {
        hasSettledMarkdownViewportRestore ? currentViewportIntent() : nil
    }

    func restoreViewport(_ intent: FullScreenMarkdownViewportIntent) -> Bool {
        restoreViewportAfterMutableTransition(intent)
        return true
    }

    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != (pendingReaderPreferences ?? readerPreferences) else { return }
        if isCollectionUserInteracting {
            pendingReaderPreferences = preferences
            return
        }
        // If UIKit released ownership before the queued interaction-end turn,
        // this immediate request supersedes both deferred values.
        pendingReaderPreferences = nil
        readerPreferences = preferences
        needsSnapshotReconfiguration = true
        pendingReconfigurationLayoutReason = .readerPreferences
        render(snapshot: latestSnapshot)
        setNeedsLayout()
    }

    /// Room below the last line for chrome that floats over the end of the
    /// document, measured by the owner that draws that chrome.
    func setBottomContentInset(_ inset: CGFloat) {
        let inset = max(0, inset)
        guard abs(collectionView.contentInset.bottom - inset) > 0.5 else { return }
        collectionView.contentInset.bottom = inset
    }

    /// Book typography is part of what a text segment bakes in, so a change
    /// re-renders the document the same way a new text size does.
    func applyBookAppearance(_ appearance: BookReaderAppearance?) {
        guard appearance != bookAppearance else { return }
        bookAppearance = appearance
        let paper = appearance?.backgroundColor(in: themeID.palette) ?? themeID.palette.ui.bgDark
        backgroundColor = paper
        collectionView.backgroundColor = paper
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

    /// True while one of the reader's deferred layout passes is queued or
    /// running: the async document build (`sourcePreparationTask`,
    /// `asyncRenderTask`, `deferredInitialRenderTask`), a render-ahead slice,
    /// the `willDisplay` visible-height flush, a forced item remeasure, a
    /// pending document layout, and the layout replace or height refresh that
    /// interaction deferred.
    ///
    /// Not covered, because none of them runs on the stress suite's paths: the
    /// line-anchor focus task, the pan-end main-queue hop, the viewport owner's
    /// follow-tail and explicit-focus hops, and async block or image work
    /// (Mermaid, LaTeX, images) until it schedules one of the passes above. A
    /// test that depends on those waits on its own condition.
    var debugHasDeferredReaderWorkForTesting: Bool {
        sourcePreparationTask != nil
            || deferredInitialRenderTask != nil
            || asyncRenderTask != nil
            || renderAheadTask != nil
            || pendingHeightFlush
            || pendingForcedItemRemeasure
            || pendingLayoutReplaceAfterInteractionRetry
            || needsDocumentLayoutPreparation
            || needsLayoutReplaceAfterInteraction
            || needsVisibleHeightRefreshAfterInteraction
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
            case .video: "video"
            case .audio: "audio"
            case .usdz: "usdz"
            case .mermaidDiagram: "mermaid"
            case .geoJSONMap: "geojson"
            case .latexBlock: "latex"
            }
        }
    }
    var debugRenderedSegmentsForTesting: [FlatSegment] { renderedSegments }
    var debugRenderedSegmentIDsForTesting: [MarkdownReaderSegmentID] { renderedSegmentIDs }
    var debugRenderedSourceTextForTesting: String? { renderedSnapshot?.text }
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
    /// Counts viewport offset or anchor writes during an in-progress gesture.
    var debugVisibleHeightCorrectionDuringInteractionCountForTesting: Int {
        debugVisibleHeightCorrectionDuringInteractionCount
    }
    var debugOffsetWriteReasonsForTesting: [MarkdownReaderOffsetWriteReason] {
        debugOffsetWriteReasons
    }
    func debugResetOffsetWriteReasonsForTesting() {
        debugOffsetWriteReasons.removeAll()
        debugVisibleHeightCorrectionDuringInteractionCount = 0
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
            doubleTapActivation: viewportDoubleTapActivation
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
    func linkRequest(for url: URL) -> AppOpenRequest? {
        let identity = resourceAccess.identity
        return MarkdownLinkInteractionSupport.classify(
            url,
            serverID: identity.serverID,
            workspaceID: identity.workspaceID,
            sessionID: identity.sessionID,
            routesFileReferencesThroughSession: identity.routesFileReferencesThroughSession,
            workspaceRuntime: identity.workspaceRuntime
        )
    }

    func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
        guard case let .link(url) = textItem.content else {
            return UITextItem.MenuConfiguration(menu: defaultMenu)
        }

        let request = linkRequest(for: url)
        return MarkdownLinkInteractionSupport.menuConfiguration(
            for: request,
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

        return primaryAction(for: url, from: textView, defaultAction: defaultAction)
    }

    func primaryAction(for url: URL, from textView: UITextView, defaultAction: UIAction) -> UIAction? {
        let request = linkRequest(for: url)
        if ChatReaderLinkIntercept.canHandle(from: textView) {
            return UIAction { [weak textView] _ in
                guard let textView else { return }
                guard !ChatReaderLinkIntercept.handle(request, from: textView) else { return }
                guard let request else {
                    defaultAction.performWithSender(nil, target: nil)
                    return
                }
                AppRootEnvironment.near(textView)?.opener.open(request)
            }
        }
        return MarkdownLinkInteractionSupport.primaryAction(
            for: request,
            from: textView,
            defaultAction: defaultAction
        )
    }
}
