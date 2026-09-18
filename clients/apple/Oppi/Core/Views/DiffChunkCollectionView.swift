import SwiftUI
import UIKit

/// TextKit background painter shared by the small-document and chunked paths.
final class DiffBackgroundLayoutManager: NSLayoutManager {
    nonisolated(unsafe) var viewportWidth: CGFloat = 0
    nonisolated(unsafe) var measuredContentWidth: CGFloat = 0

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }

        let fillWidth = max(measuredContentWidth, viewportWidth)
        let addedBackground = UIColor(Color.themeDiffAdded.opacity(0.10))
        let removedBackground = UIColor(Color.themeDiffRemoved.opacity(0.08))
        let headerBackground = UIColor(Color.themeBgHighlight)
        let addedBar = UIColor(Color.themeDiffAdded)
        let removedBar = UIColor(Color.themeDiffRemoved)

        storage.enumerateAttribute(
            diffLineKindAttributeKey,
            in: NSRange(location: 0, length: storage.length)
        ) { value, attributeRange, _ in
            guard let kind = value as? String else { return }
            let background: UIColor
            let bar: UIColor?
            switch kind {
            case "added": background = addedBackground; bar = addedBar
            case "removed": background = removedBackground; bar = removedBar
            case "header": background = headerBackground; bar = nil
            default: return
            }

            let glyphRange = self.glyphRange(
                forCharacterRange: attributeRange,
                actualCharacterRange: nil
            )
            self.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                var fillRect = rect
                fillRect.origin.x = origin.x
                fillRect.origin.y += origin.y
                fillRect.size.width = fillWidth
                background.setFill()
                UIRectFillUsingBlendMode(fillRect, .normal)
                if let bar {
                    var barRect = fillRect
                    barRect.size.width = 2.5
                    bar.setFill()
                    UIRectFillUsingBlendMode(barRect, .normal)
                }
            }
        }
    }
}

/// Vertical chunk layout that retains each item's unwrapped width instead of
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
            let attributes = UICollectionViewLayoutAttributes(
                forCellWith: IndexPath(item: index, section: 0)
            )
            attributes.frame = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height
            width = max(width, size.width)
            return attributes
        }
        cachedContentSize = CGSize(width: width, height: y)
    }

    override var collectionViewContentSize: CGSize { cachedContentSize }

    override func layoutAttributesForElements(
        in rect: CGRect
    ) -> [UICollectionViewLayoutAttributes]? {
        cachedAttributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        cachedAttributes.indices.contains(indexPath.item)
            ? cachedAttributes[indexPath.item]
            : nil
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        collectionView?.bounds.size != newBounds.size
    }
}

/// Reusable JIT painter for a pre-indexed unified diff. It owns only visible
/// TextKit documents plus a small render runway; the complete diff remains as
/// source/token metadata in `DiffAttributedStringBuilder.ChunkIndex`.
final class DiffChunkCollectionView: UIView {
    private static let attributedChunkCacheLimit = 14
    private static let runwayChunkCount = 2

    private final class ChunkCell: UICollectionViewCell {
        static let reuseIdentifier = "DiffChunkCollectionView.ChunkCell"

        let layoutManager: DiffBackgroundLayoutManager
        let textView: UITextView
        var representedChunkIndex: Int?

        override init(frame: CGRect) {
            let storage = NSTextStorage()
            let layoutManager = DiffBackgroundLayoutManager()
            let container = NSTextContainer()
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byClipping
            container.widthTracksTextView = false
            container.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            self.layoutManager = layoutManager
            self.textView = UITextView(frame: .zero, textContainer: container)
            super.init(frame: frame)

            backgroundColor = .clear
            contentView.backgroundColor = .clear
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.isEditable = false
            textView.isSelectable = true
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.textContainerInset = .zero
            contentView.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                textView.topAnchor.constraint(equalTo: contentView.topAnchor),
                textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func prepareForReuse() {
            super.prepareForReuse()
            representedChunkIndex = nil
            textView.delegate = nil
            textView.attributedText = nil
            layoutManager.measuredContentWidth = 0
        }
    }

    private struct PreparedChunk: @unchecked Sendable {
        let attributedText: NSAttributedString
        let measuredWidth: CGFloat
        let measuredHeight: CGFloat
        let buildMilliseconds: Double
    }

    private let layout = DiffChunkVirtualizedLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var index: DiffAttributedStringBuilder.ChunkIndex
    private var reviewCommentSelectionContext: ReviewCommentSelectionContext?
    private var sourceContext: ReviewCommentSourceContext?
    private var preparedCache: [Int: PreparedChunk] = [:]
    private var preparedLRU: [Int] = []
    private var renderTasks: [Int: Task<Void, Never>] = [:]
    private var measuredHeights: [Int: CGFloat] = [:]
    private var measuredContentWidth: CGFloat = 0
    private var generation = 0
    private var totalLayoutInstallMilliseconds = 0.0
    private var installedChunkCount = 0

    var backSwipeHostView: UIView { collectionView }

    init(
        index: DiffAttributedStringBuilder.ChunkIndex,
        backgroundColor: UIColor,
        reviewCommentSelectionContext: ReviewCommentSelectionContext?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        self.index = index
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
        self.sourceContext = sourceContext
        super.init(frame: .zero)
        setup(backgroundColor: backgroundColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        renderTasks.values.forEach { $0.cancel() }
    }

    override func layoutSubviews() {
        let minimumWidth = max(1, bounds.width)
        if measuredContentWidth == 0 {
            let glyphWidth = ("M" as NSString).size(withAttributes: [.font: AppFont.monoMedium]).width
            measuredContentWidth = max(
                minimumWidth,
                ceil(CGFloat(index.widestUTF16ColumnCount) * max(1, glyphWidth)) + 20
            )
        } else {
            measuredContentWidth = max(measuredContentWidth, minimumWidth)
        }
        updateLayoutItemSizes(viewportWidth: minimumWidth)
        super.layoutSubviews()
        for cell in collectionView.visibleCells.compactMap({ $0 as? ChunkCell }) {
            cell.layoutManager.viewportWidth = collectionView.bounds.width
            cell.layoutManager.measuredContentWidth = measuredContentWidth
        }
        prepareVisibleChunkRunway()
    }

    func update(
        index newIndex: DiffAttributedStringBuilder.ChunkIndex,
        backgroundColor: UIColor,
        reviewCommentSelectionContext: ReviewCommentSelectionContext?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        self.reviewCommentSelectionContext = reviewCommentSelectionContext
        self.sourceContext = sourceContext
        self.backgroundColor = backgroundColor
        collectionView.backgroundColor = backgroundColor
        guard newIndex.id != index.id else { return }

        generation += 1
        renderTasks.values.forEach { $0.cancel() }
        renderTasks.removeAll()
        preparedCache.removeAll()
        preparedLRU.removeAll()
        measuredHeights.removeAll()
        measuredContentWidth = 0
        totalLayoutInstallMilliseconds = 0
        installedChunkCount = 0
        index = newIndex
        layout.itemSizes = []
        collectionView.setContentOffset(.zero, animated: false)
        collectionView.reloadData()
        layout.invalidateLayout()
        setNeedsLayout()
    }

    private func setup(backgroundColor: UIColor) {
        self.backgroundColor = backgroundColor
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = backgroundColor
        collectionView.alwaysBounceVertical = true
        collectionView.alwaysBounceHorizontal = true
        collectionView.showsVerticalScrollIndicator = true
        collectionView.showsHorizontalScrollIndicator = true
        collectionView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 20, right: 0)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ChunkCell.self, forCellWithReuseIdentifier: ChunkCell.reuseIdentifier)
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func scheduleRender(_ chunkIndex: Int) {
        guard index.chunks.indices.contains(chunkIndex),
              preparedCache[chunkIndex] == nil,
              renderTasks[chunkIndex] == nil else { return }
        let chunk = index.chunks[chunkIndex]
        let currentGeneration = generation
        renderTasks[chunkIndex] = Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                let start = CACurrentMediaTime()
                let attributed = DiffAttributedStringBuilder.buildChunk(chunk)
                let measured = attributed.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                )
                return PreparedChunk(
                    attributedText: attributed,
                    measuredWidth: ceil(measured.width) + 20,
                    measuredHeight: max(AppFont.monoMedium.lineHeight, ceil(measured.height)),
                    buildMilliseconds: (CACurrentMediaTime() - start) * 1_000
                )
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, currentGeneration == self.generation else { return }
                self.renderTasks[chunkIndex] = nil
                self.cache(prepared, at: chunkIndex)
                self.measuredHeights[chunkIndex] = prepared.measuredHeight
                self.measuredContentWidth = max(self.measuredContentWidth, prepared.measuredWidth)
                self.updateLayoutItemSizes(viewportWidth: max(1, self.collectionView.bounds.width))
                if let cell = self.collectionView.cellForItem(
                    at: IndexPath(item: chunkIndex, section: 0)
                ) as? ChunkCell {
                    self.install(prepared, in: cell, chunkIndex: chunkIndex)
                }
            }
        }
    }

    private func install(_ prepared: PreparedChunk, in cell: ChunkCell, chunkIndex: Int) {
        guard cell.representedChunkIndex == chunkIndex else { return }
        let started = CACurrentMediaTime()
        cell.textView.attributedText = prepared.attributedText
        cell.layoutManager.viewportWidth = collectionView.bounds.width
        cell.layoutManager.measuredContentWidth = measuredContentWidth
        if let container = cell.layoutManager.textContainers.first {
            cell.layoutManager.ensureLayout(for: container)
        }
        totalLayoutInstallMilliseconds += (CACurrentMediaTime() - started) * 1_000
        installedChunkCount += 1
    }

    private func cache(_ prepared: PreparedChunk, at chunkIndex: Int) {
        preparedCache[chunkIndex] = prepared
        preparedLRU.removeAll { $0 == chunkIndex }
        preparedLRU.append(chunkIndex)
        let visible = Set(collectionView.indexPathsForVisibleItems.map(\.item))
        while preparedCache.count > Self.attributedChunkCacheLimit,
              let candidate = preparedLRU.first(where: { !visible.contains($0) }) {
            preparedCache[candidate] = nil
            measuredHeights[candidate] = nil
            preparedLRU.removeAll { $0 == candidate }
        }
    }

    private func updateLayoutItemSizes(viewportWidth: CGFloat) {
        let width = max(viewportWidth, measuredContentWidth)
        let itemSizes = index.chunks.indices.map { chunkIndex in
            let chunk = index.chunks[chunkIndex]
            let height = measuredHeights[chunkIndex]
                ?? CGFloat(max(1, chunk.renderedLineCount)) * AppFont.monoMedium.lineHeight
            return CGSize(width: width, height: height)
        }
        guard itemSizes != layout.itemSizes else { return }
        layout.itemSizes = itemSizes
        layout.invalidateLayout()
    }

    private func prepareVisibleChunkRunway() {
        let visible = collectionView.indexPathsForVisibleItems.map(\.item)
        guard let first = visible.min(), let last = visible.max(), !index.chunks.isEmpty else { return }
        let lower = max(0, first - Self.runwayChunkCount)
        let upper = min(index.chunks.count - 1, last + Self.runwayChunkCount)
        for chunkIndex in lower...upper {
            scheduleRender(chunkIndex)
        }
    }

    #if DEBUG
    struct VirtualizationDiagnostics {
        let totalUTF16Count: Int
        let chunkCount: Int
        let cachedChunkCount: Int
        let mountedChunkCount: Int
        let mountedUTF16Count: Int
        let indexRanOnMainThread: Bool
        let meanLayoutInstallMilliseconds: Double
        let maxCachedBuildMilliseconds: Double
        let collectionContentWidth: CGFloat
        let collectionBoundsWidth: CGFloat
    }

    func virtualizationDiagnosticsForTesting() -> VirtualizationDiagnostics? {
        guard !index.chunks.isEmpty else { return nil }
        let cells = collectionView.visibleCells.compactMap { $0 as? ChunkCell }
        return VirtualizationDiagnostics(
            totalUTF16Count: index.totalUTF16Count,
            chunkCount: index.chunks.count,
            cachedChunkCount: preparedCache.count,
            mountedChunkCount: cells.count,
            mountedUTF16Count: cells.reduce(into: 0) { $0 += $1.textView.textStorage.length },
            indexRanOnMainThread: index.indexRanOnMainThread,
            meanLayoutInstallMilliseconds: installedChunkCount == 0
                ? 0
                : totalLayoutInstallMilliseconds / Double(installedChunkCount),
            maxCachedBuildMilliseconds: preparedCache.values.map(\.buildMilliseconds).max() ?? 0,
            collectionContentWidth: collectionView.contentSize.width,
            collectionBoundsWidth: collectionView.bounds.width
        )
    }
    #endif
}

extension DiffChunkCollectionView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        index.chunks.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: ChunkCell.reuseIdentifier,
            for: indexPath
        ) as? ChunkCell else { return UICollectionViewCell() }
        cell.representedChunkIndex = indexPath.item
        cell.textView.delegate = self
        cell.layoutManager.viewportWidth = collectionView.bounds.width
        cell.layoutManager.measuredContentWidth = measuredContentWidth
        if let prepared = preparedCache[indexPath.item] {
            install(prepared, in: cell, chunkIndex: indexPath.item)
        } else {
            cell.textView.attributedText = nil
            scheduleRender(indexPath.item)
        }
        return cell
    }


    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        prepareVisibleChunkRunway()
    }
}

extension DiffChunkCollectionView: UITextViewDelegate {
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
