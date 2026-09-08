import UIKit

/// Read-only CSV/TSV grid. Cells are clipped to the parser bounds; source bytes stay elsewhere.
final class DelimitedTableRenderView: UIView, UICollectionViewDataSource, FullScreenReaderConfigurable {
    private let plan: DelimitedTableViewerPlan
    private let themeID: ThemeID
    private let summaryLabel = UILabel()
    private let layout = DelimitedTableGridLayout()
    private let collectionView: UICollectionView
    private let emptyLabel = UILabel()
    private var palette: ThemePalette
    private var textScale: CGFloat = 1

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
        backgroundColor = UIColor(palette.bgDark)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.register(DelimitedTableCell.self, forCellWithReuseIdentifier: DelimitedTableCell.reuseID)
        collectionView.alwaysBounceVertical = false
        collectionView.alwaysBounceHorizontal = true
        collectionView.accessibilityIdentifier = "delimited-table.grid"
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .preferredFont(forTextStyle: .caption1)
        summaryLabel.textColor = UIColor(palette.comment)
        summaryLabel.numberOfLines = 0
        summaryLabel.text = plan.truncationSummary
        summaryLabel.isHidden = plan.truncationSummary == nil
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .preferredFont(forTextStyle: .caption1)
        emptyLabel.textColor = UIColor(palette.comment)
        emptyLabel.text = "Empty table"
        emptyLabel.isHidden = plan.table.displayedRowCount > 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(summaryLabel)
        addSubview(collectionView)
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
        let columnTitle = item.header.isEmpty ? "Column \(indexPath.item % max(plan.table.columnCount, 1) + 1)" : item.header
        if item.isHeader {
            cell.accessibilityLabel = columnTitle
        } else {
            cell.accessibilityLabel = "\(columnTitle), row \(item.row), \(item.text)"
        }
        return cell
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
        label.textColor = UIColor(isHeader ? palette.fg : palette.fgDim)
        contentView.backgroundColor = UIColor(isHeader ? palette.bgHighlight : palette.bgDark)
        divider.backgroundColor = UIColor(palette.comment).withAlphaComponent(0.25)
    }
}

private final class DelimitedTableGridLayout: UICollectionViewLayout {
    var columnWidths: [CGFloat] = []
    var rowHeight: CGFloat = 30
    var headerHeight: CGFloat = 34

    private var attributes: [UICollectionViewLayoutAttributes] = []
    private var cachedSize: CGSize = .zero

    override var collectionViewContentSize: CGSize { cachedSize }

    override func prepare() {
        guard let collectionView else { return }
        let columns = columnWidths.count
        let itemCount = collectionView.numberOfItems(inSection: 0)
        guard columns > 0, itemCount > 0 else {
            attributes = []
            cachedSize = .zero
            return
        }

        var xOffsets: [CGFloat] = []
        var x: CGFloat = 0
        xOffsets.reserveCapacity(columns)
        for width in columnWidths {
            xOffsets.append(x)
            x += width
        }

        var nextAttributes: [UICollectionViewLayoutAttributes] = []
        nextAttributes.reserveCapacity(itemCount)
        for item in 0..<itemCount {
            let row = item / columns
            let column = item % columns
            let indexPath = IndexPath(item: item, section: 0)
            let attribute = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            let height = row == 0 ? headerHeight : rowHeight
            let y = row == 0 ? 0 : headerHeight + CGFloat(row - 1) * rowHeight
            attribute.frame = CGRect(x: xOffsets[column], y: y, width: columnWidths[column], height: height)
            nextAttributes.append(attribute)
        }
        attributes = nextAttributes
        let rowCount = itemCount / columns
        let height = headerHeight + CGFloat(max(0, rowCount - 1)) * rowHeight
        cachedSize = CGSize(width: x, height: height)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        attributes.filter { $0.frame.intersects(rect) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard attributes.indices.contains(indexPath.item) else { return nil }
        return attributes[indexPath.item]
    }
}
