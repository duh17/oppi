import UIKit

/// Draws a `MarkdownTableGridLayout` with Core Graphics and `NSAttributedString`
/// drawing. Immutable inputs are swapped under a lock, so a tiled layer can draw
/// from a background thread while the main thread appends rows.
final class MarkdownTableGridRenderer: NSObject, CALayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var layout: MarkdownTableGridLayout?

    func update(layout: MarkdownTableGridLayout?) {
        lock.lock()
        self.layout = layout
        lock.unlock()
    }

    /// The grid layer is never animated. A standalone layer cross-fades `contents`
    /// over 0.25s on every redisplay unless its delegate says otherwise.
    func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
        NSNull()
    }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        lock.lock()
        let layout = layout
        lock.unlock()
        guard let layout else { return }

        let clip = ctx.boundingBoxOfClipPath
        let rows = layout.rows(intersecting: clip.minY, clip.maxY)
        guard !rows.isEmpty else { return }

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let inset = MarkdownTableColumnLayout.horizontalContentInset
        for row in rows {
            let color: UIColor? = if row == 0 {
                layout.style.headerBackground
            } else if (row - 1) % 2 == 1 {
                layout.style.zebraBackground
            } else {
                nil
            }
            guard let color else { continue }
            color.setFill()
            ctx.fill(CGRect(
                x: inset,
                y: layout.rowOrigins[row],
                width: layout.gridWidth,
                height: layout.rowHeights[row]
            ))
        }

        let separator = CGRect(
            x: inset,
            y: layout.separatorOrigin,
            width: layout.gridWidth,
            height: layout.separatorHeight
        )
        if separator.intersects(clip) {
            layout.style.separator.setFill()
            ctx.fill(separator)
        }

        let columns = layout.columns(intersecting: clip.minX, clip.maxX)
        for row in rows {
            for column in columns {
                let frame = layout.cellFrame(row: row, column: column)
                layout.drawnCells[row][column].draw(
                    with: CGRect(
                        x: frame.minX,
                        y: frame.minY + MarkdownTableGridLayout.cellVerticalInset,
                        width: frame.width,
                        height: frame.height - MarkdownTableGridLayout.cellVerticalInset
                    ),
                    options: MarkdownTableGridLayout.cellDrawingOptions,
                    context: nil
                )
            }
        }
    }
}

/// A tiled layer whose tiles appear without a fade.
private final class MarkdownTableTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// One accessibility element per cell, read with its column header.
private final class MarkdownTableAccessibilityCell: UIAccessibilityElement, UIAccessibilityContainerDataTableCell {
    let row: Int
    let column: Int
    var links: [(text: String, url: URL)] = []
    var onOpenLink: ((URL) -> Void)?

    init(container: Any, row: Int, column: Int) {
        self.row = row
        self.column = column
        super.init(accessibilityContainer: container)
    }

    func accessibilityRowRange() -> NSRange { NSRange(location: row, length: 1) }
    func accessibilityColumnRange() -> NSRange { NSRange(location: column, length: 1) }

    override func accessibilityActivate() -> Bool {
        guard links.count == 1, let onOpenLink else { return false }
        onOpenLink(links[0].url)
        return true
    }
}

/// The whole wrap grid as one view.
///
/// Cells are drawn, not mounted, so a grid costs one text-measure pass instead
/// of a text view per cell. Small grids draw into a plain layer; a grid whose
/// backing store would be large draws into a tiled layer that only renders what
/// is on screen.
///
/// Cells that take touches (links, review-comment selection) mount one
/// `UITextView` over the cell being touched, in `hitTest`, so native link taps,
/// link menus, selection handles, and the edit menu behave as they did when every
/// cell was a text view. The text view paints the cell's own background opaque
/// and covers the drawn cell, so the drawn layer is never invalidated for a
/// touch: a redisplay swaps `contents` (or blanks whole 512pt tiles) and the
/// cells around the touch would flicker.
final class MarkdownTableGridView: UIView {
    /// Backing store above this area (in points squared) is tiled: a plain layer
    /// of 400k pt² is about 14 MB at 3x.
    static let plainBackingAreaLimit: CGFloat = 400_000

    let renderer = MarkdownTableGridRenderer()
    private(set) var layout: MarkdownTableGridLayout?
    private var contentLayer: CALayer?
    private(set) var isTiled = false

    /// Mount a text view on touched cells. Off, the grid is a picture.
    var isInteractive = false {
        didSet {
            if !isInteractive { deactivateCell() }
        }
    }

    weak var cellTextViewDelegate: UITextViewDelegate?
    var linkTextColor: UIColor = .link
    /// Opens a link from a VoiceOver activation.
    var onOpenLink: ((URL, UIView) -> Void)?

    private(set) var activeCell: (row: Int, column: Int)?
    private(set) var activeTextView: BaselineSafeTextView?
    private var accessibilityCells: [MarkdownTableAccessibilityCell]?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Layout

    func setLayout(_ layout: MarkdownTableGridLayout) {
        deactivateCell()
        self.layout = layout
        accessibilityCells = nil
        renderer.update(layout: layout)
        let wantsTiles = layout.contentWidth * layout.contentHeight > Self.plainBackingAreaLimit
        if contentLayer == nil || wantsTiles != isTiled {
            installContentLayer(tiled: wantsTiles)
        }
        setNeedsLayout()
        contentLayer?.setNeedsDisplay()
    }

    /// Drops the grid and its backing store; the table switched to clip mode.
    func clear() {
        deactivateCell()
        layout = nil
        accessibilityCells = nil
        renderer.update(layout: nil)
        contentLayer?.removeFromSuperlayer()
        contentLayer = nil
        isTiled = false
    }

    private var displayScale: CGFloat { max(traitCollection.displayScale, 1) }

    private func installContentLayer(tiled: Bool) {
        contentLayer?.removeFromSuperlayer()
        let layer: CALayer
        if tiled {
            let tiledLayer = MarkdownTableTiledLayer()
            tiledLayer.levelsOfDetail = 1
            tiledLayer.levelsOfDetailBias = 0
            layer = tiledLayer
        } else {
            layer = CALayer()
        }
        layer.delegate = renderer
        layer.isOpaque = false
        layer.needsDisplayOnBoundsChange = false
        isTiled = tiled
        contentLayer = layer
        self.layer.addSublayer(layer)
        configureContentsScale()
    }

    private func configureContentsScale() {
        guard let contentLayer else { return }
        contentLayer.contentsScale = displayScale
        if let tiled = contentLayer as? CATiledLayer {
            let side = 512 * displayScale
            tiled.tileSize = CGSize(width: side, height: side)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let contentLayer else { return }
        if contentLayer.bounds.size != bounds.size {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            contentLayer.frame = bounds
            CATransaction.commit()
            // New area has no content yet.
            contentLayer.setNeedsDisplay()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            deactivateCell()
        } else if let contentLayer, contentLayer.contentsScale != displayScale {
            configureContentsScale()
            contentLayer.setNeedsDisplay()
        }
    }

    // MARK: Touched cells

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Only a finger on the screen mounts: UIKit also hit-tests with no event,
        // and a touch that lands on a scroll in progress stops it, it does not tap.
        guard hit === self,
              isInteractive,
              event?.type == .touches,
              !isInScrollInProgress,
              let layout,
              let cell = layout.cell(at: point)
        else { return hit }
        activateCell(row: cell.row, column: cell.column)
        // The mounted text view now covers the point.
        return super.hitTest(point, with: event)
    }

    private var isInScrollInProgress: Bool {
        var view = superview
        while let current = view {
            if let scroll = current as? UIScrollView, scroll.isDragging || scroll.isDecelerating { return true }
            view = current.superview
        }
        return false
    }

    func activateCell(row: Int, column: Int) {
        if let activeCell, activeCell.row == row, activeCell.column == column { return }
        deactivateCell()
        guard let layout, row < layout.cells.count, column < layout.columnWidths.count else { return }
        let text = layout.cells[row][column]
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let textView = BaselineSafeTextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        // Opaque, the color the grid shows under the cell, so it covers the drawn
        // text without the grid redrawing.
        textView.backgroundColor = layout.style.cellBackground(row: row)
        textView.textContainerInset = UIEdgeInsets(
            top: MarkdownTableGridLayout.cellVerticalInset,
            left: 0,
            bottom: MarkdownTableGridLayout.cellVerticalInset,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = false
        textView.textContainer.size = CGSize(
            width: max(1, layout.columnWidths[column]),
            height: .greatestFiniteMagnitude
        )
        textView.delegate = cellTextViewDelegate
        // Underlines live on the link runs so file links can omit them.
        textView.linkTextAttributes = [.foregroundColor: linkTextColor]
        textView.attributedText = text
        textView.frame = layout.cellFrame(row: row, column: column)
        addSubview(textView)
        // The touch that mounted the text view is its first. A text view finds
        // the link under a touch in laid-out text; one laid out on the next
        // pass lets the first tap on a link fall through.
        textView.layoutIfNeeded()

        activeCell = (row, column)
        activeTextView = textView
    }

    func deactivateCell() {
        guard let textView = activeTextView else { return }
        textView.removeFromSuperview()
        activeTextView = nil
        activeCell = nil
    }

    // MARK: Accessibility

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var accessibilityContainerType: UIAccessibilityContainerType {
        get { .dataTable }
        set {}
    }

    override var accessibilityElements: [Any]? {
        get { cellElements() }
        set {}
    }

    private func cellElements() -> [MarkdownTableAccessibilityCell] {
        if let accessibilityCells { return accessibilityCells }
        guard let layout else { return [] }
        var elements: [MarkdownTableAccessibilityCell] = []
        elements.reserveCapacity(layout.cells.count * layout.columnWidths.count)
        for row in layout.cells.indices {
            for column in layout.columnWidths.indices {
                let text = layout.cells[row][column]
                let element = MarkdownTableAccessibilityCell(container: self, row: row, column: column)
                element.accessibilityLabel = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
                element.accessibilityFrameInContainerSpace = layout.cellFrame(row: row, column: column)
                var traits: UIAccessibilityTraits = row == 0 ? .header : .staticText
                var links: [(text: String, url: URL)] = []
                text.enumerateAttribute(
                    .link,
                    in: NSRange(location: 0, length: text.length)
                ) { value, range, _ in
                    guard let url = value as? URL else { return }
                    links.append(((text.string as NSString).substring(with: range), url))
                }
                if !links.isEmpty {
                    traits.insert(.link)
                    element.links = links
                    element.onOpenLink = { [weak self] url in
                        guard let self else { return }
                        onOpenLink?(url, self)
                    }
                    if links.count > 1 {
                        element.accessibilityCustomActions = links.map { link in
                            UIAccessibilityCustomAction(name: link.text) { [weak self] _ in
                                guard let self else { return false }
                                onOpenLink?(link.url, self)
                                return true
                            }
                        }
                    }
                }
                element.accessibilityTraits = traits
                elements.append(element)
            }
        }
        accessibilityCells = elements
        return elements
    }
}

extension MarkdownTableGridView: UIAccessibilityContainerDataTable {
    func accessibilityDataTableCellElement(
        forRow row: Int,
        column: Int
    ) -> UIAccessibilityContainerDataTableCell? {
        guard let layout, row >= 0, row < layout.cells.count,
              column >= 0, column < layout.columnWidths.count
        else { return nil }
        let elements = cellElements()
        return elements[row * layout.columnWidths.count + column]
    }

    func accessibilityRowCount() -> Int { layout?.cells.count ?? 0 }

    func accessibilityColumnCount() -> Int { layout?.columnWidths.count ?? 0 }

    func accessibilityHeaderElements(forColumn column: Int) -> [any UIAccessibilityContainerDataTableCell]? {
        guard let layout, column >= 0, column < layout.columnWidths.count else { return nil }
        return [cellElements()[column]]
    }
}
