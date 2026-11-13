import UIKit

/// A Markdown table opened full screen: its cells, and the workspace its file
/// links resolve in. Copy and Share take the table from here, every row.
struct MarkdownTableDocument {
    let headers: [[MarkdownInline]]
    let rows: [[[MarkdownInline]]]
    /// The source's delimiter-row alignments, kept for the table and its Markdown.
    var alignments: [MarkdownTableAlignment?] = []
    var serverID: String?
    var workspaceID: String?

    var columnCount: Int { max(headers.count, rows.first?.count ?? 0) }

    /// The whole table as copied text: Markdown keeps inline syntax, TSV is plain cells.
    func text(_ format: TableCopyFormat) -> String {
        switch format {
        case .markdown:
            return MarkdownBlockSerializer.serialize([.table(headers: headers, rows: rows, alignments: alignments)])
        case .tsv:
            return TableTextFormat.tsv(
                headers: headers.map { plainText(from: $0) },
                rows: rows.map { $0.map { plainText(from: $0) } }
            )
        }
    }
}

/// The full-screen reader's body for a Markdown table: the chat's own table view
/// (`NativeTableBlockView`) with every row and the reader's width to fit in, at
/// the reader's text size, under a caption that counts what it holds.
///
/// The table starts a short gap below the bar and scrolls vertically even when
/// it fits, so UIKit gives it the bar's inset (see `FullScreenViewerChrome`).
/// Once its header row scrolls under the bar, a copy of it holds there.
final class MarkdownTableReaderBody: UIView, ReaderBody, UIScrollViewDelegate {
    private let document: MarkdownTableDocument
    private let palette: ThemePalette
    private let scrollView = UIScrollView()
    private let table = NativeTableBlockView()
    private let caption = UILabel()
    private let pinnedHeader = PinnedTableHeaderView()
    private var textScale: CGFloat

    /// Room above the table, below the bar.
    static let topGap: CGFloat = 14
    static let horizontalMargin: CGFloat = 16

    init(
        document: MarkdownTableDocument,
        palette: ThemePalette,
        readerPreferences: FullScreenReaderPreferences,
        reviewCommentSelectionRouter: ReviewCommentSelectionRouter?,
        reviewCommentSourceContext: ReviewCommentSourceContext?
    ) {
        self.document = document
        self.palette = palette
        textScale = readerPreferences.textScale
        super.init(frame: .zero)
        accessibilityIdentifier = "fullScreen.markdownTable.body"
        backgroundColor = palette.ui.bgDark

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "fullScreen.markdownTable.scroll"
        scrollView.delegate = self
        addSubview(scrollView)
        addSubview(pinnedHeader)

        table.surface = .viewer
        table.fontScale = textScale
        table.translatesAutoresizingMaskIntoConstraints = false
        table.configureResourceReferenceScope(serverID: document.serverID, workspaceID: document.workspaceID)
        table.configureReviewCommentSelection(
            router: reviewCommentSelectionRouter,
            sourceContext: reviewCommentSourceContext
        )
        table.onGridChange = { [weak self] in self?.refreshPinnedHeader() }
        table.onHorizontalScroll = { [weak self] in self?.placePinnedHeader() }
        scrollView.addSubview(table)

        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.font = AppFont.scaledSystem(13, .regular, relativeTo: .footnote, maximumPointSize: 22)
        caption.textColor = palette.ui.comment
        caption.adjustsFontForContentSizeCategory = true
        caption.numberOfLines = 0
        caption.text = Self.caption(columns: document.columnCount, rows: document.rows.count)
        caption.accessibilityIdentifier = "fullScreen.markdownTable.caption"
        scrollView.addSubview(caption)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            table.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.topGap),
            table.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Self.horizontalMargin),
            table.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Self.horizontalMargin),

            caption.topAnchor.constraint(equalTo: table.bottomAnchor, constant: 8),
            caption.leadingAnchor.constraint(equalTo: table.card.leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: frame.trailingAnchor, constant: -Self.horizontalMargin),
            caption.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            content.widthAnchor.constraint(equalTo: frame.widthAnchor),
        ])

        table.apply(headers: document.headers, rows: document.rows, alignments: document.alignments, palette: palette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// "4 columns · 3 rows".
    static func caption(columns: Int, rows: Int) -> String {
        String(localized: "\(columns) columns") + " · " + String(localized: "\(rows) rows")
    }

    // MARK: ReaderBody

    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences) {
        guard abs(preferences.textScale - textScale) > 0.001 else { return }
        textScale = preferences.textScale
        table.fontScale = textScale
        table.apply(headers: document.headers, rows: document.rows, alignments: document.alignments, palette: palette)
    }

    func makeCopyMenu(didCopy: @escaping (String) -> Void) -> UIMenu? {
        let document = document
        return UIMenu(children: TableCopyFormat.allCases.map { format in
            UIAction(title: format.menuTitle, image: UIImage(systemName: format.menuSymbol)) { _ in
                didCopy(document.text(format))
            }
        })
    }

    func setBottomContentInset(_ inset: CGFloat) {
        scrollView.contentInset.bottom = inset
    }

    // MARK: Pinned header

    override func layoutSubviews() {
        super.layoutSubviews()
        placePinnedHeader()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        placePinnedHeader()
    }

    private func refreshPinnedHeader() {
        pinnedHeader.update(layout: table.headerRowLayout, background: palette.ui.bgDark)
        placePinnedHeader()
    }

    /// Holds the header copy at the top of the visible rows while the real header
    /// is above it, until the table's last rows reach it, as a list's section
    /// header goes. The copy's backing reaches up to the screen's top, so rows
    /// scrolled past the header never show between it and the bar.
    private func placePinnedHeader() {
        let height = pinnedHeader.pinnedHeight
        let card = table.card.convert(table.card.bounds, to: self)
        let top = scrollView.adjustedContentInset.top
        guard height > 0, card.minY < top, card.maxY - height > top else {
            pinnedHeader.isHidden = true
            return
        }
        pinnedHeader.isHidden = false
        pinnedHeader.frame = CGRect(x: card.minX, y: 0, width: card.width, height: top + height)
        pinnedHeader.setHorizontalOffset(table.horizontalOffset)
    }

    #if DEBUG
    var debugPinnedHeaderForTesting: UIView { pinnedHeader }
    var debugScrollViewForTesting: UIScrollView { scrollView }
    #endif
}

/// A copy of the table's header row held under the reader's bar once the real
/// one scrolls past it, on an opaque backing that covers the rows above it up
/// to the screen's top. It follows the rows' sideways scroll and takes no touches,
/// so they reach the rows underneath. VoiceOver skips it: it reads the header
/// cells of the table itself.
private final class PinnedTableHeaderView: UIView {
    private let grid = MarkdownTableGridView()
    private var layout: MarkdownTableGridLayout?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        isHidden = true
        addSubview(grid)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The copy's height: the padding above the header row, the row, and its rule.
    var pinnedHeight: CGFloat {
        guard let layout else { return 0 }
        return layout.separatorOrigin + layout.separatorHeight
    }

    func update(layout: MarkdownTableGridLayout?, background: UIColor) {
        self.layout = layout
        backgroundColor = background
        guard let layout else {
            grid.clear()
            return
        }
        grid.setLayout(layout)
        grid.frame.size = CGSize(width: layout.contentWidth, height: layout.contentHeight)
        setNeedsLayout()
    }

    /// The header row sits at the bottom of the view; above it is backing.
    override func layoutSubviews() {
        super.layoutSubviews()
        grid.frame.origin.y = bounds.height - pinnedHeight
    }

    func setHorizontalOffset(_ offset: CGFloat) {
        grid.frame.origin.x = -offset
    }
}
