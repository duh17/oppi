import UIKit

/// UIKit reader for review diffs: commit file diffs and the Changes review.
///
/// The whole diff stays a compact source/token index
/// (`DiffAttributedStringBuilder.ChunkIndex`). Each chunk of rows is styled,
/// laid out by TextKit, and measured off the main thread; its text view is
/// created as soon as that finishes, ahead of the viewport, so a chunk scrolling
/// in only gets added to its cell. Row tints are GPU layers behind the text, so
/// scrolling never repaints them on the CPU (they cost ~14 ms per
/// screen-sized tile when TextKit painted them).
///
/// Text size and wrapping follow the shared full-screen diff preferences
/// (`FullScreenReaderContentFamily.diff`) through the same Viewing Options
/// control as the full-screen readers.
final class DiffReaderView: UIView {
    private static let preparedChunkCacheLimit = 24
    private static let runwayChunkCount = 2
    /// Creating a UITextView costs ~0.35 us per character on the main thread
    /// (12 ms for 32 KB on the simulator); 8 KB keeps each one to a few ms.
    nonisolated private static let maxChunkUTF8Bytes = 8 * 1024
    private static let family = FullScreenReaderContentFamily.diff

    var reviewCommentSelectionContext: ReviewCommentSelectionContext?
    var sourceContext: ReviewCommentSourceContext?
    /// Floating controls the host already shows in the trailing bottom corner
    /// (the next-file button). Viewing Options stacks above them.
    var trailingAccessoryCount = 0 {
        didSet {
            guard trailingAccessoryCount != oldValue else { return }
            viewingOptionsBottomConstraint?.constant = -viewingOptionsBottomPadding
        }
    }
    private var viewingOptionsBottomConstraint: NSLayoutConstraint?
    private var viewingOptionsBottomPadding: CGFloat {
        FullScreenReviewCommentStashControl.bottomPadding(leadingAccessoryCount: trailingAccessoryCount)
    }

    private let layout = DiffChunkVirtualizedLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var emptyView: UIView?
    private let backSwipeCoordinator = HorizontalBackSwipeActionCoordinator()
    private let scrollSampler = DiffReaderScrollSampler()
    private lazy var viewingOptionsButton: UIButton = {
        let button = FullScreenViewingOptionsController.makeFloatingButton(palette: currentPalette)
        button.addTarget(self, action: #selector(showViewingOptions), for: .touchUpInside)
        return button
    }()
    private weak var viewingOptionsController: FullScreenViewingOptionsController?
    private var readerPreferences = FullScreenReaderPreferencesStore.shared.preferences(for: DiffReaderView.family)
    /// Width the current chunks wrapped to; a different width re-lays them out.
    private var preparedWrapWidth: CGFloat = 0

    private var hunks: [WorkspaceReviewDiffHunk]?
    private var filePath = ""
    private var emptyDescription = ""
    private var index: DiffAttributedStringBuilder.ChunkIndex?
    private var indexTask: Task<Void, Never>?
    private var preparedCache: [Int: DiffReaderPreparedChunk] = [:]
    private var preparedLRU: [Int] = []
    private var renderTasks: [Int: Task<Void, Never>] = [:]
    private var measuredHeights: [Int: CGFloat] = [:]
    private var measuredContentWidth: CGFloat = 0
    /// Bumped whenever the diff or theme changes; stale chunk work drops itself.
    private var generation = 0
    private var openStartedAt: CFTimeInterval = 0
    private var openMilliseconds: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        indexTask?.cancel()
        renderTasks.values.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    var backSwipeHostView: UIView { collectionView }

    func installBackSwipe(action: (@MainActor @Sendable () -> Void)?) {
        backSwipeCoordinator.install(action: action, on: collectionView)
    }

    /// Shows `hunks`. Re-sending the same diff is a no-op.
    func setDiff(
        hunks newHunks: [WorkspaceReviewDiffHunk],
        filePath newFilePath: String,
        emptyDescription newEmptyDescription: String = "This file has no textual changes to show."
    ) {
        guard newHunks != hunks || newFilePath != filePath else { return }
        hunks = newHunks
        filePath = newFilePath
        emptyDescription = newEmptyDescription
        rebuildIndex()
    }

    // MARK: - Setup

    private func setUp() {
        applyThemeColors()
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.alwaysBounceVertical = true
        collectionView.alwaysBounceHorizontal = true
        collectionView.showsVerticalScrollIndicator = true
        collectionView.showsHorizontalScrollIndicator = true
        collectionView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 20, right: 0)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(DiffReaderChunkCell.self, forCellWithReuseIdentifier: DiffReaderChunkCell.reuseIdentifier)
        addSubview(collectionView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        viewingOptionsButton.translatesAutoresizingMaskIntoConstraints = false
        viewingOptionsButton.isHidden = true
        addSubview(viewingOptionsButton)

        let viewingOptionsBottom = viewingOptionsButton.bottomAnchor.constraint(
            equalTo: safeAreaLayoutGuide.bottomAnchor,
            constant: -viewingOptionsBottomPadding
        )
        viewingOptionsBottomConstraint = viewingOptionsBottom
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            viewingOptionsButton.trailingAnchor.constraint(
                equalTo: safeAreaLayoutGuide.trailingAnchor,
                constant: -FullScreenFloatingControlChrome.trailingPadding
            ),
            viewingOptionsBottom,
            viewingOptionsButton.widthAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
            viewingOptionsButton.heightAnchor.constraint(equalToConstant: FullScreenFloatingControlChrome.controlSize),
        ])
        applyReaderScrolling()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: .oppiThemeDidChange,
            object: nil
        )
    }

    private var currentPalette: ThemePalette {
        ThemeRuntimeState.currentThemeID().palette
    }

    private func applyThemeColors() {
        let background = UIColor(currentPalette.bgDark)
        backgroundColor = background
        collectionView.backgroundColor = background
        FullScreenViewingOptionsController.updateFloatingButton(
            viewingOptionsButton,
            palette: currentPalette,
            preferences: readerPreferences
        )
    }

    /// Chunk text and tints carry theme colors; the index does not, so a theme
    /// change only re-styles chunks.
    @objc private func themeDidChange() {
        applyThemeColors()
        restyleChunks()
    }

    /// Drops prepared chunks and lays them out again with the current theme,
    /// text size, and wrap width. The index and scroll position stay.
    private func restyleChunks() {
        resetChunks()
        updateLayoutItemSizes()
        collectionView.reloadData()
        setNeedsLayout()
    }

    // MARK: - Viewing options

    @objc private func showViewingOptions() {
        if let open = viewingOptionsController {
            open.dismiss(animated: true)
            return
        }
        guard let presenter = nearestViewController() else { return }
        let options = FullScreenViewingOptionsController(
            family: Self.family,
            preferences: readerPreferences,
            onTextScaleChanged: { [weak self] scale in
                self?.updateReaderPreferences { $0.textScale = FullScreenReaderPreferences.clampedTextScale(scale) }
            },
            onWrappingChanged: { [weak self] wraps in
                self?.updateReaderPreferences { $0.wrapsText = wraps }
            },
            onSpacingChanged: { _ in },
            onReset: { [weak self] in
                FullScreenReaderPreferencesStore.shared.resetPreferences(for: Self.family)
                self?.applyReaderPreferences(Self.family.defaultPreferences)
            }
        )
        options.configurePresentation(
            barItem: nil,
            sourceButton: viewingOptionsButton,
            horizontalSizeClass: traitCollection.horizontalSizeClass
        )
        viewingOptionsController = options
        presenter.present(options, animated: true)
    }

    private func nearestViewController() -> UIViewController? {
        sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
    }

    private func updateReaderPreferences(_ mutate: (inout FullScreenReaderPreferences) -> Void) {
        var preferences = readerPreferences
        mutate(&preferences)
        FullScreenReaderPreferencesStore.shared.setPreferences(preferences, for: Self.family)
        applyReaderPreferences(FullScreenReaderPreferencesStore.shared.preferences(for: Self.family))
    }

    private func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard preferences != readerPreferences else { return }
        let wrapChanged = preferences.wrapsText != readerPreferences.wrapsText
        readerPreferences = preferences
        viewingOptionsController?.apply(family: Self.family, preferences: preferences)
        FullScreenViewingOptionsController.updateFloatingButton(
            viewingOptionsButton,
            palette: currentPalette,
            preferences: preferences
        )
        applyReaderScrolling()
        if wrapChanged {
            collectionView.setContentOffset(
                CGPoint(x: -collectionView.adjustedContentInset.left, y: collectionView.contentOffset.y),
                animated: false
            )
        }
        restyleChunks()
    }

    private func applyReaderScrolling() {
        let wraps = readerPreferences.wrapsText
        collectionView.alwaysBounceHorizontal = !wraps
        collectionView.showsHorizontalScrollIndicator = !wraps
    }

    // MARK: - Index

    private func rebuildIndex() {
        // Moving to another file in the Changes review swaps the diff in place.
        reportSession()
        indexTask?.cancel()
        index = nil
        resetChunks()
        layout.itemSizes = []
        measuredContentWidth = 0
        collectionView.reloadData()
        emptyView?.removeFromSuperview()
        emptyView = nil

        guard let hunks, !hunks.isEmpty else {
            spinner.stopAnimating()
            viewingOptionsButton.isHidden = true
            showEmptyState()
            return
        }
        viewingOptionsButton.isHidden = false
        bringSubviewToFront(viewingOptionsButton)

        spinner.startAnimating()
        openStartedAt = CACurrentMediaTime()
        openMilliseconds = nil
        let generation = generation
        let filePath = filePath
        indexTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) {
                DiffAttributedStringBuilder.buildChunkIndex(
                    hunks: hunks,
                    filePath: filePath,
                    options: .init(includeStats: false, includeGapSummary: true, paintsRowBackgrounds: true),
                    maxUTF8Bytes: Self.maxChunkUTF8Bytes
                )
            }.value
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            self.install(index)
        }
    }

    private func install(_ newIndex: DiffAttributedStringBuilder.ChunkIndex) {
        index = newIndex
        measuredContentWidth = estimatedUnwrappedWidth(for: newIndex)
        collectionView.setContentOffset(
            CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
            animated: false
        )
        updateLayoutItemSizes()
        collectionView.reloadData()
        setNeedsLayout()
    }

    private func resetChunks() {
        generation += 1
        renderTasks.values.forEach { $0.cancel() }
        renderTasks.removeAll()
        preparedCache.removeAll()
        preparedLRU.removeAll()
        measuredHeights.removeAll()
        if let index {
            measuredContentWidth = estimatedUnwrappedWidth(for: index)
        }
    }

    private func estimatedUnwrappedWidth(for index: DiffAttributedStringBuilder.ChunkIndex) -> CGFloat {
        let font = FullScreenCodeTypography.codeFont(for: readerPreferences)
        let glyphWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(index.widestUTF16ColumnCount) * max(1, glyphWidth)) + 20
    }

    private var estimatedLineHeight: CGFloat {
        FullScreenCodeTypography.codeFont(for: readerPreferences).lineHeight
    }

    private func showEmptyState() {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "checkmark.circle")
        configuration.text = "No Textual Changes"
        configuration.secondaryText = emptyDescription
        let view = UIContentUnavailableView(configuration: configuration)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        emptyView = view
    }

    // MARK: - Layout

    override func layoutSubviews() {
        if readerPreferences.wrapsText, index != nil, wrapWidth != preparedWrapWidth {
            preparedWrapWidth = wrapWidth
            resetChunks()
            collectionView.reloadData()
        }
        updateLayoutItemSizes()
        super.layoutSubviews()
        for cell in collectionView.visibleCells.compactMap({ $0 as? DiffReaderChunkCell }) {
            cell.rowFillWidth = contentWidth
        }
        prepareVisibleChunkRunway()
    }

    private var contentWidth: CGFloat {
        readerPreferences.wrapsText
            ? max(collectionView.bounds.width, 1)
            : max(measuredContentWidth, collectionView.bounds.width, 1)
    }

    private var wrapWidth: CGFloat {
        max(1, collectionView.bounds.width)
    }

    private func updateLayoutItemSizes() {
        guard let index else { return }
        let width = contentWidth
        let itemSizes = index.chunks.indices.map { chunkIndex in
            let height = measuredHeights[chunkIndex]
                ?? CGFloat(max(1, index.chunks[chunkIndex].renderedLineCount)) * estimatedLineHeight
            return CGSize(width: width, height: height)
        }
        guard itemSizes != layout.itemSizes else { return }
        layout.itemSizes = itemSizes
        layout.invalidateLayout()
    }

    // MARK: - Chunk preparation

    private func prepareVisibleChunkRunway() {
        guard let index, !index.chunks.isEmpty else { return }
        let visible = collectionView.indexPathsForVisibleItems.map(\.item)
        guard let first = visible.min(), let last = visible.max() else {
            scheduleRender(0)
            return
        }
        let lower = max(0, first - Self.runwayChunkCount)
        let upper = min(index.chunks.count - 1, last + Self.runwayChunkCount)
        for chunkIndex in lower...upper {
            scheduleRender(chunkIndex)
        }
    }

    private func scheduleRender(_ chunkIndex: Int) {
        guard let index,
              index.chunks.indices.contains(chunkIndex),
              preparedCache[chunkIndex] == nil,
              renderTasks[chunkIndex] == nil else { return }
        let chunk = index.chunks[chunkIndex]
        let generation = generation
        let preferences = readerPreferences
        let wrapWidth: CGFloat? = preferences.wrapsText ? wrapWidth : nil
        renderTasks[chunkIndex] = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                DiffReaderPreparedChunk.prepare(chunk, preferences: preferences, wrapWidth: wrapWidth)
            }.value
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            self.renderTasks[chunkIndex] = nil
            // Create the text view now, while the chunk is still ahead of the
            // viewport, so scrolling it in costs only an addSubview.
            prepared.makeTextView().delegate = self
            self.cache(prepared, at: chunkIndex)
            self.measuredHeights[chunkIndex] = prepared.size.height
            if !preferences.wrapsText {
                self.measuredContentWidth = max(self.measuredContentWidth, prepared.size.width)
            }
            self.updateLayoutItemSizes()
            if let cell = self.collectionView.cellForItem(at: IndexPath(item: chunkIndex, section: 0))
                as? DiffReaderChunkCell {
                self.attach(prepared, to: cell, chunkIndex: chunkIndex)
            }
        }
    }

    private func attach(_ prepared: DiffReaderPreparedChunk, to cell: DiffReaderChunkCell, chunkIndex: Int) {
        guard cell.representedChunkIndex == chunkIndex else { return }
        cell.show(prepared, delegate: self, rowFillWidth: contentWidth)
        if openMilliseconds == nil {
            openMilliseconds = (CACurrentMediaTime() - openStartedAt) * 1_000
            spinner.stopAnimating()
        }
    }

    private func cache(_ prepared: DiffReaderPreparedChunk, at chunkIndex: Int) {
        preparedCache[chunkIndex] = prepared
        preparedLRU.removeAll { $0 == chunkIndex }
        preparedLRU.append(chunkIndex)
        let visible = Set(collectionView.indexPathsForVisibleItems.map(\.item))
        while preparedCache.count > Self.preparedChunkCacheLimit,
              let candidate = preparedLRU.first(where: { !visible.contains($0) }) {
            // Keep its measured height: it stays valid until `resetChunks`, and
            // dropping it made the layout jump when scrolling back.
            preparedCache[candidate] = nil
            preparedLRU.removeAll { $0 == candidate }
        }
    }

    // MARK: - Telemetry

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        guard newWindow == nil else { return }
        scrollSampler.stop()
        reportSession()
    }

    /// One low-volume line per reader visit: how long the first chunk took and
    /// how scrolling went, so device smoothness is measurable from client logs.
    private func reportSession() {
        guard let index, let openMilliseconds else { return }
        var metadata = scrollSampler.metadata()
        metadata["openMs"] = String(Int(openMilliseconds.rounded()))
        metadata["lines"] = String(index.renderedLineCount)
        metadata["chunks"] = String(index.chunks.count)
        metadata["contentWidthPt"] = String(Int(contentWidth))
        ClientLog.info("DiffReader", "Diff reader session", metadata: metadata)
        scrollSampler.reset()
    }

    #if DEBUG
    struct Diagnostics {
        let chunkCount: Int
        let cachedChunkCount: Int
        let mountedChunkCount: Int
        let mountedUTF16Count: Int
        let totalUTF16Count: Int
        let indexRanOnMainThread: Bool
        let contentWidth: CGFloat
        let boundsWidth: CGFloat
    }

    /// Applies preferences without saving them to the shared store.
    func applyReaderPreferencesForTesting(_ preferences: FullScreenReaderPreferences) {
        applyReaderPreferences(preferences)
    }

    var contentHeightForTesting: CGFloat { collectionView.contentSize.height }

    func diagnosticsForTesting() -> Diagnostics? {
        guard let index else { return nil }
        let cells = collectionView.visibleCells.compactMap { $0 as? DiffReaderChunkCell }
        return Diagnostics(
            chunkCount: index.chunks.count,
            cachedChunkCount: preparedCache.count,
            mountedChunkCount: cells.filter { $0.textView != nil }.count,
            mountedUTF16Count: cells.reduce(into: 0) { $0 += $1.textView?.textStorage.length ?? 0 },
            totalUTF16Count: index.totalUTF16Count,
            indexRanOnMainThread: index.indexRanOnMainThread,
            contentWidth: collectionView.contentSize.width,
            boundsWidth: collectionView.bounds.width
        )
    }
    #endif
}

extension DiffReaderView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        index?.chunks.count ?? 0
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: DiffReaderChunkCell.reuseIdentifier,
            for: indexPath
        ) as? DiffReaderChunkCell else { return UICollectionViewCell() }
        cell.representedChunkIndex = indexPath.item
        if let prepared = preparedCache[indexPath.item] {
            attach(prepared, to: cell, chunkIndex: indexPath.item)
        } else {
            scheduleRender(indexPath.item)
        }
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        prepareVisibleChunkRunway()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollSampler.start()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollSampler.stop() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollSampler.stop()
    }
}

extension DiffReaderView: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        ReviewCommentSelectionEditMenuSupport.buildMenu(
            textView: textView,
            range: range,
            suggestedActions: suggestedActions,
            router: reviewCommentSelectionContext?.dispatcher,
            sourceContext: sourceContext
        )
    }
}

// MARK: - Prepared chunk

/// One chunk of rows, styled and laid out off the main thread. The text view
/// is created on the main thread on first display and moves between cells
/// with the chunk, so scrolling back never lays out again.
final class DiffReaderPreparedChunk: @unchecked Sendable {
    enum RowKind {
        case added, removed, header
    }

    /// One laid-out row that gets a tint.
    struct Row {
        let kind: RowKind
        let minY: CGFloat
        let height: CGFloat
        /// The row's text: the text-extent tint covers this span. A wrapped
        /// continuation starts past the gutter, as TextKit drew it before.
        let textMinX: CGFloat
        let textMaxX: CGFloat
    }

    let size: CGSize
    let rows: [Row]
    private let storage: NSTextStorage
    private let container: NSTextContainer
    private var textView: UITextView?

    private init(storage: NSTextStorage, container: NSTextContainer, size: CGSize, rows: [Row]) {
        self.storage = storage
        self.container = container
        self.size = size
        self.rows = rows
    }

    /// Off the main thread: attributed text, TextKit layout, measurement, and
    /// tint rows. The TextKit objects are confined to this call until the main
    /// thread takes them over in `makeTextView`. A non-nil `wrapWidth` wraps
    /// rows to that width.
    nonisolated static func prepare(
        _ chunk: DiffAttributedStringBuilder.ChunkIndex.Chunk,
        preferences: FullScreenReaderPreferences,
        wrapWidth: CGFloat?
    ) -> DiffReaderPreparedChunk {
        let styled = FullScreenDiffTextStyle.styled(
            DiffAttributedStringBuilder.buildChunk(chunk),
            preferences: preferences
        )
        let storage = NSTextStorage(attributedString: styled)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(
            width: wrapWidth ?? CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        container.lineBreakMode = wrapWidth == nil ? .byClipping : .byCharWrapping
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var rows: [Row] = []
        storage.enumerateAttribute(
            diffLineKindAttributeKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            let kind: RowKind
            switch value as? String {
            case "added": kind = .added
            case "removed": kind = .removed
            case "header": kind = .header
            default: return
            }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, usedRect, _, _, _ in
                rows.append(Row(
                    kind: kind,
                    minY: rect.minY,
                    height: rect.height,
                    textMinX: usedRect.minX,
                    textMaxX: usedRect.maxX
                ))
            }
        }

        let used = layoutManager.usedRect(for: container)
        // A chunk ends in a newline, so TextKit adds an empty line fragment
        // after it. Counting it left a blank row between chunks.
        let textHeight = layoutManager.extraLineFragmentTextContainer == nil
            ? used.maxY
            : layoutManager.extraLineFragmentRect.minY
        return DiffReaderPreparedChunk(
            storage: storage,
            container: container,
            size: CGSize(
                width: wrapWidth ?? ceil(used.width) + 20,
                // Exact, not rounded up: chunks stack edge to edge, and rounding
                // left a hairline between the row tints of adjacent chunks.
                height: max(
                    FullScreenCodeTypography.codeFont(for: preferences).lineHeight,
                    textHeight
                )
            ),
            rows: rows
        )
    }

    @MainActor
    func makeTextView() -> UITextView {
        if let textView { return textView }
        let textView = UITextView(frame: CGRect(origin: .zero, size: size), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        self.textView = textView
        return textView
    }
}

// MARK: - Cell

private final class DiffReaderChunkCell: UICollectionViewCell {
    static let reuseIdentifier = "DiffReaderView.ChunkCell"

    var representedChunkIndex: Int?
    private(set) var textView: UITextView?
    private let tintView = DiffReaderRowTintView()

    var rowFillWidth: CGFloat = 0 {
        didSet {
            guard rowFillWidth != oldValue else { return }
            tintView.rowFillWidth = rowFillWidth
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.addSubview(tintView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ prepared: DiffReaderPreparedChunk, delegate: UITextViewDelegate, rowFillWidth: CGFloat) {
        let textView = prepared.makeTextView()
        if self.textView !== textView {
            self.textView?.removeFromSuperview()
            self.textView = textView
            contentView.addSubview(textView)
        }
        textView.delegate = delegate
        textView.frame = CGRect(origin: .zero, size: prepared.size)
        self.rowFillWidth = rowFillWidth
        tintView.show(prepared.rows, rowFillWidth: rowFillWidth)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tintView.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedChunkIndex = nil
        // The text view belongs to its prepared chunk; only drop it if it is
        // still ours (another cell may already show that chunk).
        if textView?.superview === contentView {
            textView?.removeFromSuperview()
        }
        textView = nil
        tintView.show([], rowFillWidth: rowFillWidth)
    }
}

/// Row tints as plain layers, composited on the GPU behind the text. Layers,
/// bottom to top: full-width row tint, text-extent tint, change bar. Same hue,
/// so the stack matches the colors TextKit used to paint (see
/// `DiffAttributedStringBuilder.PainterColors`).
private final class DiffReaderRowTintView: UIView {
    private var rows: [DiffReaderPreparedChunk.Row] = []
    private var rowLayers: [CALayer] = []
    var rowFillWidth: CGFloat = 0 {
        didSet { layoutRowLayers() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ newRows: [DiffReaderPreparedChunk.Row], rowFillWidth newWidth: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rowLayers.forEach { $0.removeFromSuperlayer() }
        rowLayers.removeAll(keepingCapacity: true)
        rows = newRows
        let colors = DiffAttributedStringBuilder.painterColors()
        for row in newRows {
            switch row.kind {
            case .added:
                addRowLayers(row: colors.addedRow, text: colors.addedText, bar: colors.addedBar)
            case .removed:
                addRowLayers(row: colors.removedRow, text: colors.removedText, bar: colors.removedBar)
            case .header:
                addRowLayers(row: colors.header, text: nil, bar: nil)
            }
        }
        CATransaction.commit()
        rowFillWidth = newWidth
        layoutRowLayers()
    }

    private func addRowLayers(row: UIColor, text: UIColor?, bar: UIColor?) {
        for color in [row, text, bar] {
            let layer = CALayer()
            layer.backgroundColor = color?.cgColor
            layer.isHidden = color == nil
            self.layer.addSublayer(layer)
            rowLayers.append(layer)
        }
    }

    private func layoutRowLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (rowIndex, row) in rows.enumerated() {
            let base = rowIndex * 3
            guard base + 2 < rowLayers.count else { break }
            rowLayers[base].frame = CGRect(x: 0, y: row.minY, width: rowFillWidth, height: row.height)
            rowLayers[base + 1].frame = CGRect(
                x: row.textMinX,
                y: row.minY,
                width: max(0, row.textMaxX - row.textMinX),
                height: row.height
            )
            rowLayers[base + 2].frame = CGRect(x: 0, y: row.minY, width: 2.5, height: row.height)
        }
        CATransaction.commit()
    }
}

// MARK: - Layout

/// Vertical chunk layout that keeps each item's unwrapped width instead of
/// clamping collection content width to the viewport like flow layout does.
private final class DiffChunkVirtualizedLayout: UICollectionViewLayout {
    var itemSizes: [CGSize] = []

    private var cachedAttributes: [UICollectionViewLayoutAttributes] = []
    private var cachedContentSize: CGSize = .zero

    override func prepare() {
        super.prepare()
        var y: CGFloat = 0
        var width = collectionView?.bounds.width ?? 0
        cachedAttributes = itemSizes.enumerated().map { index, size in
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attributes.frame = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height
            width = max(width, size.width)
            return attributes
        }
        cachedContentSize = CGSize(width: width, height: y)
    }

    override var collectionViewContentSize: CGSize { cachedContentSize }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        cachedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        cachedAttributes.indices.contains(indexPath.item) ? cachedAttributes[indexPath.item] : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }
}

// MARK: - Scroll smoothness

/// Counts frames and hitches while the user scrolls the reader. A frame that
/// lands more than half a frame late is a hitch; `hitchMs` sums the lateness.
@MainActor
private final class DiffReaderScrollSampler: NSObject {
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var frames = 0
    private var hitches = 0
    private var hitchMilliseconds = 0.0
    private var scrollMilliseconds = 0.0
    private var worstFrameMilliseconds = 0.0

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func reset() {
        frames = 0
        hitches = 0
        hitchMilliseconds = 0
        scrollMilliseconds = 0
        worstFrameMilliseconds = 0
    }

    func metadata() -> [String: String] {
        [
            "scrollFrames": String(frames),
            "hitches": String(hitches),
            "hitchMsPerSecond": scrollMilliseconds > 0
                ? String(format: "%.1f", hitchMilliseconds / (scrollMilliseconds / 1_000))
                : "0",
            "worstFrameMs": String(format: "%.1f", worstFrameMilliseconds),
        ]
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }
        let interval = (link.timestamp - lastTimestamp) * 1_000
        let expected = max(1, (link.targetTimestamp - link.timestamp) * 1_000)
        frames += 1
        scrollMilliseconds += interval
        worstFrameMilliseconds = max(worstFrameMilliseconds, interval)
        if interval > expected * 1.5 {
            hitches += 1
            hitchMilliseconds += interval - expected
        }
    }
}
