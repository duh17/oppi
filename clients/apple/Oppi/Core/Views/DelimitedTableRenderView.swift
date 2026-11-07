import UIKit

/// Read-only CSV/TSV grid. Cells are clipped to the parser bounds; source bytes stay elsewhere.
///
/// The grid lays out only the cells in view and pins the header row while it
/// scrolls. In the full-screen viewer a tap opens a cell's whole text.
final class DelimitedTableRenderView: UIView, UICollectionViewDataSource, UICollectionViewDelegate, ReaderBody {
    private let plan: DelimitedTableViewerPlan
    private let themeID: ThemeID
    private let summaryLabel = UILabel()
    private let layout = DelimitedTableGridLayout()
    private let collectionView: UICollectionView
    private let emptyLabel = UILabel()
    /// Covers the strip between the grid's top edge and its pinned header (the
    /// floating bars' inset), so rows scrolled past the header do not show above it.
    private let headerBackdrop = UIView()
    private var palette: ThemePalette
    private var textScale: CGFloat = 1

    /// A tap on a cell opens its full text. Set only where the grid owns taps:
    /// the full-screen viewer. Inline in a tool row, a tap opens that viewer.
    var allowsCellDetail = false

    init(plan: DelimitedTableViewerPlan, palette: ThemePalette? = nil) {
        self.plan = plan
        self.themeID = ThemeRuntimeState.currentThemeID()
        self.palette = palette ?? ThemeRuntimeState.currentPalette()
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        configure()
        reloadMetrics()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The displayed table as copied text.
    func copyText(_ format: TableCopyFormat) -> String { plan.table.copyText(format) }

    /// Copy as TSV or Markdown, for the viewer's Copy button. `didCopy` gets the
    /// text; the viewer puts it on the pasteboard and flashes its confirmation.
    func makeCopyMenu(didCopy: @escaping (String) -> Void) -> UIMenu {
        // The parser may have dropped rows, columns, or characters: say so.
        let table = plan.table
        let partial = table.truncatedRows || table.truncatedColumns || table.truncatedCells
        let subtitle = partial ? String(localized: "Only the part shown") : nil
        return UIMenu(children: TableCopyFormat.allCases.map { format in
            UIAction(title: format.menuTitle, subtitle: subtitle, image: UIImage(systemName: format.menuSymbol)) { [weak self] _ in
                guard let self else { return }
                didCopy(copyText(format))
            }
        })
    }

    func displays(_ other: DelimitedTableViewerPlan) -> Bool {
        plan == other && themeID == ThemeRuntimeState.currentThemeID()
    }

    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        let nextScale = CGFloat(preferences.textScale)
        guard abs(nextScale - textScale) > 0.001 else { return }
        textScale = nextScale
        reloadMetrics()
        collectionView.reloadData()
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width > 0 ? targetSize.width : bounds.width
        return CGSize(width: max(1, width), height: fittedContentHeight(forWidth: width))
    }

    private func fittedContentHeight(forWidth width: CGFloat) -> CGFloat {
        var height: CGFloat = 0
        if plan.truncationSummary != nil {
            let summaryWidth = max(1, width - 24)
            height += 8
            height += ceil(summaryLabel.sizeThatFits(
                CGSize(width: summaryWidth, height: .greatestFiniteMagnitude)
            ).height)
            height += 4
        }
        if plan.table.displayedRowCount == 0 {
            height += 48
        } else {
            height += layout.headerHeight + CGFloat(plan.table.displayedRowCount - 1) * layout.rowHeight
        }
        return max(1, ceil(height))
    }

    private func configure() {
        backgroundColor = palette.ui.bgDark
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(DelimitedTableCell.self, forCellWithReuseIdentifier: DelimitedTableCell.reuseID)
        collectionView.alwaysBounceVertical = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.accessibilityIdentifier = "delimited-table.grid"
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryLabel.textColor = palette.ui.comment
        summaryLabel.numberOfLines = 0
        summaryLabel.text = plan.truncationSummary
        summaryLabel.isHidden = plan.truncationSummary == nil
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .preferredFont(forTextStyle: .caption1)
        emptyLabel.textColor = palette.ui.comment
        emptyLabel.text = "Empty table"
        emptyLabel.isHidden = plan.table.displayedRowCount > 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        headerBackdrop.backgroundColor = palette.ui.bgDark
        headerBackdrop.isUserInteractionEnabled = false

        addSubview(summaryLabel)
        addSubview(collectionView)
        addSubview(headerBackdrop)
        addSubview(emptyLabel)

        let summaryVisible = plan.truncationSummary != nil
        let collectionTop = summaryVisible
            ? collectionView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 4)
            : collectionView.topAnchor.constraint(equalTo: topAnchor)

        NSLayoutConstraint.activate([
            summaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            collectionTop,
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: collectionView.topAnchor, constant: 16),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let grid = collectionView.frame
        headerBackdrop.frame = CGRect(
            x: grid.minX,
            y: grid.minY,
            width: grid.width,
            height: max(0, collectionView.adjustedContentInset.top)
        )
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    private func reloadMetrics() {
        let font = cellFont(isHeader: false)
        layout.columnWidths = measuredColumnWidths(font: font)
        layout.rowHeight = ceil(font.lineHeight + 14)
        layout.headerHeight = ceil(cellFont(isHeader: true).lineHeight + 16)
        layout.invalidateLayout()
    }

    private func cellFont(isHeader: Bool) -> UIFont {
        let size = 13 * textScale
        let base = UIFont.monospacedSystemFont(ofSize: size, weight: isHeader ? .semibold : .regular)
        return UIFontMetrics(forTextStyle: .caption1).scaledFont(for: base)
    }

    private func measuredColumnWidths(font: UIFont) -> [CGFloat] {
        let columns = plan.table.columnCount
        guard columns > 0 else { return [] }
        let minWidth: CGFloat = 72
        let maxWidth: CGFloat = 240
        var widths = Array(repeating: minWidth, count: columns)
        let sampleRows = [plan.table.headers] + Array(plan.table.rows.prefix(40))
        for row in sampleRows {
            for (index, cell) in row.enumerated() where index < columns {
                let width = (cell as NSString).size(withAttributes: [.font: font]).width + 20
                widths[index] = min(maxWidth, max(widths[index], ceil(width)))
            }
        }
        return widths
    }

    private struct CellContent {
        let text: String
        let isHeader: Bool
        let header: String
        let row: Int
    }

    private func cellContent(at item: Int) -> CellContent {
        let columns = max(plan.table.columnCount, 1)
        let row = item / columns
        let column = item % columns
        let header = plan.table.headers.indices.contains(column) ? plan.table.headers[column] : ""
        if row == 0 {
            return CellContent(text: header, isHeader: true, header: header, row: 0)
        }
        let body = plan.table.rows[row - 1]
        let text = body.indices.contains(column) ? body[column] : ""
        return CellContent(text: text, isHeader: false, header: header, row: row)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        plan.table.displayedRowCount * plan.table.columnCount
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: DelimitedTableCell.reuseID,
            for: indexPath
        ) as? DelimitedTableCell else {
            return UICollectionViewCell()
        }
        let item = cellContent(at: indexPath.item)
        cell.apply(
            text: item.text,
            isHeader: item.isHeader,
            palette: palette,
            font: cellFont(isHeader: item.isHeader)
        )
        let title = columnTitle(of: item, at: indexPath)
        if item.isHeader {
            cell.accessibilityLabel = title
            cell.accessibilityTraits = .header
        } else {
            cell.accessibilityLabel = "\(title), row \(item.row), \(item.text)"
            cell.accessibilityTraits = allowsCellDetail ? .button : .staticText
        }
        return cell
    }

    /// The column's header, or "Column N" for a column without one.
    private func columnTitle(of item: CellContent, at indexPath: IndexPath) -> String {
        guard item.header.isEmpty else { return item.header }
        return String(localized: "Column \(indexPath.item % max(plan.table.columnCount, 1) + 1)")
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard allowsCellDetail else { return false }
        return !cellContent(at: indexPath.item).text.isEmpty
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard allowsCellDetail else { return }
        let item = cellContent(at: indexPath.item)
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) {
            responder = current.next
        }
        guard let presenter = responder as? UIViewController else { return }
        presenter.present(TableCellDetailViewController.makeNavigationController(
            title: columnTitle(of: item, at: indexPath),
            text: item.text,
            palette: palette
        ), animated: true)
    }
}

private final class DelimitedTableCell: UICollectionViewCell {
    static let reuseID = "delimited-table-cell"
    private let label = UILabel()
    private let divider = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1
        divider.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        contentView.addSubview(divider)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            divider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(text: String, isHeader: Bool, palette: ThemePalette, font: UIFont) {
        label.text = text
        label.font = font
        label.textColor = isHeader ? palette.fg : palette.fgDim
        contentView.backgroundColor = isHeader ? palette.bgHighlight : palette.bgDark
        divider.backgroundColor = palette.ui.comment.withAlphaComponent(0.25)
    }
}

/// Row-major grid: item `row * columns + column`, row 0 the header. Attributes are
/// computed for the visible rows and columns only, so scrolling a 500-row table
/// costs the cells on screen. The header row stays at the top of the viewport.
private final class DelimitedTableGridLayout: UICollectionViewLayout {
    var columnWidths: [CGFloat] = []
    var rowHeight: CGFloat = 30
    var headerHeight: CGFloat = 34

    private var xOffsets: [CGFloat] = []
    private var rowCount = 0
    private var cachedSize: CGSize = .zero

    override var collectionViewContentSize: CGSize { cachedSize }

    override func prepare() {
        guard let collectionView else { return }
        let columns = columnWidths.count
        let itemCount = collectionView.numberOfItems(inSection: 0)
        guard columns > 0, itemCount > 0 else {
            xOffsets = []
            rowCount = 0
            cachedSize = .zero
            return
        }
        var x: CGFloat = 0
        xOffsets = columnWidths.map { width in
            defer { x += width }
            return x
        }
        rowCount = itemCount / columns
        cachedSize = CGSize(
            width: x,
            height: headerHeight + CGFloat(max(0, rowCount - 1)) * rowHeight
        )
    }

    /// The pinned header follows the vertical scroll; nothing else depends on it.
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.origin.y != collectionView.bounds.origin.y
            || newBounds.size != collectionView.bounds.size
    }

    /// Top of the viewport below any bar, where the header row sits.
    private var pinnedHeaderY: CGFloat {
        guard let collectionView else { return 0 }
        return max(0, collectionView.contentOffset.y + collectionView.adjustedContentInset.top)
    }

    private func attributes(row: Int, column: Int) -> UICollectionViewLayoutAttributes {
        let attribute = UICollectionViewLayoutAttributes(
            forCellWith: IndexPath(item: row * columnWidths.count + column, section: 0)
        )
        if row == 0 {
            attribute.frame = CGRect(x: xOffsets[column], y: pinnedHeaderY, width: columnWidths[column], height: headerHeight)
            attribute.zIndex = 1
        } else {
            attribute.frame = CGRect(
                x: xOffsets[column],
                y: headerHeight + CGFloat(row - 1) * rowHeight,
                width: columnWidths[column],
                height: rowHeight
            )
        }
        return attribute
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !xOffsets.isEmpty, rowCount > 0 else { return [] }
        let columns = (0 ..< xOffsets.count).filter {
            xOffsets[$0] < rect.maxX && xOffsets[$0] + columnWidths[$0] > rect.minX
        }
        guard !columns.isEmpty else { return [] }

        var result = columns.map { attributes(row: 0, column: $0) }
        if rowCount > 1, rect.maxY > headerHeight {
            let first = max(1, 1 + Int(floor((rect.minY - headerHeight) / rowHeight)))
            let last = min(rowCount - 1, 1 + Int(floor((rect.maxY - headerHeight) / rowHeight)))
            if first <= last {
                for row in first ... last {
                    for column in columns {
                        result.append(attributes(row: row, column: column))
                    }
                }
            }
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let columns = columnWidths.count
        guard columns > 0, indexPath.item >= 0, indexPath.item / columns < rowCount else { return nil }
        return attributes(row: indexPath.item / columns, column: indexPath.item % columns)
    }
}
