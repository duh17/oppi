import UIKit

/// The "this table continues" fade drawn over a markdown table card's trailing
/// edge while columns reach past it. It only draws: `NativeTableBlockView` feeds
/// it the scroll position, so it follows the scroll without touching the table's
/// layout, and every touch goes to the table underneath.
///
/// Nothing that can be read sits over the rows: a pill there hid the cut
/// column's label at the top and the last row's values at the bottom. What the
/// table holds past the edge is named in the bar under the rows (`TableShowAllBar`).
final class TableOverflowOverlayView: UIView {
    private let fadeView = TableTrailingFadeView()
    /// Whether the fade is showing.
    private(set) var isCueVisible = false

    /// The overlay sits exactly over the scroller, so its layout pass is the
    /// scroller's resize: the owner refreshes the cue from it.
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        fadeView.translatesAutoresizingMaskIntoConstraints = false
        fadeView.alpha = 0
        addSubview(fadeView)

        NSLayoutConstraint.activate([
            fadeView.topAnchor.constraint(equalTo: topAnchor),
            fadeView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fadeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fadeView.widthAnchor.constraint(equalToConstant: Self.fadeWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static let fadeWidth: CGFloat = 36

    private var appliedColor: UIColor?

    /// Called on every table apply, streaming ticks included: a color it already
    /// drew is skipped.
    func apply(palette: ThemePalette) {
        guard palette.ui.bgDark != appliedColor else { return }
        appliedColor = palette.ui.bgDark
        fadeView.apply(color: palette.ui.bgDark)
    }

    /// - Parameters:
    ///   - hiddenColumns: columns that reach past the visible right edge.
    ///   - canScrollRight: whether the table has more to scroll to on the right.
    func update(hiddenColumns: Int, canScrollRight: Bool) {
        let visible = canScrollRight && hiddenColumns > 0
        guard visible != isCueVisible else { return }
        isCueVisible = visible
        let changes = { self.fadeView.alpha = visible ? 1 : 0 }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: changes)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// Transparent-to-card gradient. Decorative: not an accessibility element.
private final class TableTrailingFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(color: UIColor) {
        guard let gradient = layer as? CAGradientLayer else { return }
        let resolved = color.resolvedColor(with: traitCollection)
        gradient.colors = [
            resolved.withAlphaComponent(0).cgColor,
            resolved.withAlphaComponent(0.92).cgColor,
        ]
    }
}

extension TableCopyFormat {
    /// The copy menu item for this format, the same in chat and in the viewer.
    var menuTitle: String {
        switch self {
        case .markdown: String(localized: "Copy as Markdown")
        case .tsv: String(localized: "Copy as TSV")
        }
    }

    var menuSymbol: String {
        switch self {
        case .markdown: "text.alignleft"
        case .tsv: "tablecells"
        }
    }
}

/// The bar at the foot of a table card that shows less than the whole table:
/// "Show all 30 rows" when it folded its long body, "Show all 4 columns" when
/// its columns are cut at the card's edge, "Show all 30 rows · 11 columns" for
/// both. A tap opens the table full screen; a long press offers the copy menu.
final class TableShowAllBar: UIView {
    /// Fixed so the bar adds the same height whatever the text size.
    static let height: CGFloat = 40

    private let button = UIButton(type: .system)
    private let divider = UIView()
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        divider.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "markdown.table.showAll"
        button.accessibilityTraits = .button
        button.accessibilityHint = String(localized: "Opens table full screen")
        button.addAction(UIAction { [weak self] _ in self?.onActivate?() }, for: .touchUpInside)
        addSubview(button)
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 0.5),
            button.topAnchor.constraint(equalTo: divider.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Long-press menu on the bar (the copy actions).
    func setMenu(_ menu: UIMenu?) {
        button.menu = menu
    }

    /// The bar's title: the rows when the body is folded, the columns when they
    /// are cut, or both.
    static func title(foldedRows: Int?, cutColumns: Int?) -> String {
        switch (foldedRows, cutColumns) {
        case let (rows?, columns?):
            String(localized: "Show all \(rows) rows") + " · " + String(localized: "\(columns) columns")
        case let (rows?, nil):
            String(localized: "Show all \(rows) rows")
        case let (nil, columns?):
            String(localized: "Show all \(columns) columns")
        case (nil, nil):
            ""
        }
    }

    private var applied: (title: String, color: UIColor)?

    func apply(title: String, palette: ThemePalette) {
        if let applied, applied.title == title, applied.color == palette.ui.blue { return }
        applied = (title, palette.ui.blue)
        divider.backgroundColor = palette.ui.comment.withAlphaComponent(0.25)
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = palette.ui.blue
        configuration.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        configuration.imagePadding = 6
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 11, weight: .semibold
        )
        var attributes = AttributeContainer()
        attributes.font = AppFont.scaledSystem(13, .medium, relativeTo: .footnote, maximumPointSize: 20)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        configuration.titleLineBreakMode = .byTruncatingTail
        button.configuration = configuration
        button.accessibilityLabel = title
    }
}

/// What a markdown table card wears besides its rows: the trailing fade over the
/// scroller and, when the card shows less than the whole table, the
/// `TableShowAllBar` under it.
///
/// `NativeTableBlockView` owns the rows and hands this the facts: how many rows
/// are shown of how many, whether its columns are cut at rest, and where the
/// scroller is. This installs the fade and the bar in the card, and keeps the
/// scroller's bottom edge on the bar while it shows. The fade is an overlay, so
/// it takes no layout; the bar adds `footerHeight`, which the table's measured
/// height includes.
@MainActor
final class TableChrome {
    private let card: UIView
    private let scrollView: UIScrollView
    private let overlay = TableOverflowOverlayView()
    private let footer = TableShowAllBar()
    private var scrollBottomToCard: NSLayoutConstraint?
    private var scrollBottomToFooter: NSLayoutConstraint?
    private let open: () -> Void
    private let copy: (TableCopyFormat) -> Void

    /// Columns that reach at most this far past the card's edge are its padding,
    /// not a column the reader is missing: the bar does not offer them.
    static let cutThreshold: CGFloat = 24

    /// Whether the bar shows.
    private(set) var showsFooter = false

    var footerHeight: CGFloat { showsFooter ? TableShowAllBar.height : 0 }

    init(card: UIView, scrollView: UIScrollView, open: @escaping () -> Void, copy: @escaping (TableCopyFormat) -> Void) {
        self.card = card
        self.scrollView = scrollView
        self.open = open
        self.copy = copy
    }

    /// Adds the overlay and the bar to the card and pins the scroller's bottom
    /// edge. Call once, after the scroller is in the card and pinned on its
    /// other three edges. `onScrollerResize` runs when the scroller changes size.
    func install(onScrollerResize: @escaping () -> Void) {
        overlay.onLayout = onScrollerResize
        card.addSubview(overlay)
        card.addSubview(footer)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.isHidden = true
        footer.onActivate = { [open] in open() }
        footer.setMenu(UIMenu(children: TableCopyFormat.allCases.map { format in
            UIAction(title: format.menuTitle, image: UIImage(systemName: format.menuSymbol)) { [copy] _ in
                copy(format)
            }
        }))
        let toCard = scrollView.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        scrollBottomToCard = toCard
        scrollBottomToFooter = scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor)
        NSLayoutConstraint.activate([
            toCard,
            overlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
    }

    /// Called on every table apply, streaming ticks included, and whenever the
    /// table is planned for a new width. `overflow` is how far the planned columns
    /// reach past the card at rest, never the scroll position, so the bar comes
    /// and goes with the plan and not while the rows scroll. Returns whether the
    /// bar appeared or went away, so the table can invalidate its height.
    func update(shownRows: Int, totalRows: Int, columns: Int, overflow: CGFloat, palette: ThemePalette) -> Bool {
        overlay.apply(palette: palette)
        let title = TableShowAllBar.title(
            foldedRows: totalRows > shownRows ? totalRows : nil,
            cutColumns: overflow > Self.cutThreshold ? columns : nil
        )
        let shows = !title.isEmpty
        if shows { footer.apply(title: title, palette: palette) }
        guard shows != showsFooter else { return false }
        showsFooter = shows
        footer.isHidden = !shows
        scrollBottomToCard?.isActive = !shows
        scrollBottomToFooter?.isActive = shows
        return true
    }

    /// Shows the fade while the content (`contentWidth`) reaches further right
    /// than the scroller shows, past `visibleMaxX`.
    func updateCue(visibleMaxX: CGFloat, contentWidth: CGFloat, trailingEdges: [CGFloat]) {
        guard visibleMaxX > 0 else { return }
        overlay.update(
            hiddenColumns: MarkdownTableColumnLayout.hiddenColumnCount(trailingEdges: trailingEdges, visibleMaxX: visibleMaxX),
            canScrollRight: contentWidth - visibleMaxX > 1
        )
    }
}
