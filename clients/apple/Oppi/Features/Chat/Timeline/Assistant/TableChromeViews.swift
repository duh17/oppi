import UIKit

/// The "this table continues" cue drawn over a markdown table card: a fade on
/// the trailing edge and a pill that counts the columns past it. It only draws.
/// `NativeTableBlockView` owns what it means and feeds it the scroll position, so
/// the cue changes as the table scrolls without touching the table's layout.
///
/// The overlay hit-tests only the pill; the table underneath keeps every touch.
final class TableOverflowOverlayView: UIView {
    private let fadeView = TableTrailingFadeView()
    private let pill = UIButton(type: .system)
    /// Whether the fade and pill are showing.
    private(set) var isCueVisible = false

    /// Tapping the pill opens the full-screen table viewer.
    var onActivate: (() -> Void)?
    /// The overlay sits exactly over the scroller, so its layout pass is the
    /// scroller's resize: the owner refreshes the cue from it.
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        fadeView.translatesAutoresizingMaskIntoConstraints = false
        fadeView.isUserInteractionEnabled = false
        fadeView.alpha = 0
        addSubview(fadeView)

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.accessibilityIdentifier = "markdown.table.moreColumns"
        pill.accessibilityTraits = .button
        pill.accessibilityHint = String(localized: "Opens table full screen")
        pill.alpha = 0
        pill.isHidden = true
        pill.addAction(UIAction { [weak self] _ in self?.onActivate?() }, for: .touchUpInside)
        addSubview(pill)

        NSLayoutConstraint.activate([
            fadeView.topAnchor.constraint(equalTo: topAnchor),
            fadeView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fadeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fadeView.widthAnchor.constraint(equalToConstant: Self.fadeWidth),

            // Bottom corner: at the top it would cover the header row, the one
            // label that says what the cut column is.
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static let fadeWidth: CGFloat = 36

    /// Long-press menu on the pill (the copy actions).
    func setMenu(_ menu: UIMenu?) {
        pill.menu = menu
    }

    private var appliedColors: [UIColor] = []

    /// Called on every table apply, streaming ticks included: a palette it already
    /// drew is skipped, so a tick does not rebuild the pill.
    func apply(palette: ThemePalette) {
        let colors = [palette.ui.bgDark, palette.ui.bgHighlight, palette.ui.fg, palette.ui.comment]
        guard colors != appliedColors else { return }
        appliedColors = colors
        fadeView.apply(color: palette.ui.bgDark)
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = palette.ui.fg
        configuration.image = UIImage(systemName: "arrow.right")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 10, weight: .semibold
        )
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 9, bottom: 4, trailing: 9)
        configuration.background.backgroundColor = palette.ui.bgHighlight.withAlphaComponent(0.94)
        configuration.background.strokeColor = palette.ui.comment.withAlphaComponent(0.35)
        configuration.background.strokeWidth = 1
        configuration.cornerStyle = .capsule
        pill.configuration = configuration
        // The title lives on the configuration; rebuild it with the current count.
        applyTitle()
    }

    private var hiddenColumns = 0

    /// - Parameters:
    ///   - hiddenColumns: columns that reach past the visible right edge.
    ///   - canScrollRight: whether the table has more to scroll to on the right.
    func update(hiddenColumns: Int, canScrollRight: Bool) {
        let visible = canScrollRight && hiddenColumns > 0
        if hiddenColumns != self.hiddenColumns {
            self.hiddenColumns = hiddenColumns
            applyTitle()
        }
        setCue(visible: visible)
    }

    private func applyTitle() {
        guard hiddenColumns > 0, var configuration = pill.configuration else { return }
        let title = String(localized: "\(hiddenColumns) more columns")
        var attributes = AttributeContainer()
        attributes.font = AppFont.scaledSystem(11, .semibold, relativeTo: .caption2, maximumPointSize: 18)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        pill.configuration = configuration
        pill.accessibilityLabel = title
    }

    private func setCue(visible: Bool) {
        guard visible != isCueVisible else { return }
        isCueVisible = visible
        if visible { pill.isHidden = false }
        let changes = {
            self.pill.alpha = visible ? 1 : 0
            self.fadeView.alpha = visible ? 1 : 0
        }
        let finish: (Bool) -> Void = { _ in
            if !self.isCueVisible { self.pill.isHidden = true }
        }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            finish(true)
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: changes, completion: finish)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === fadeView ? nil : hit
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

/// "Show all N rows" bar at the foot of a table card that folded its long body.
final class TableFoldFooterView: UIView {
    /// Fixed so folding adds the same height whatever the text size.
    static let height: CGFloat = 40

    private let button = UIButton(type: .system)
    private let divider = UIView()
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        divider.translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "markdown.table.showAll"
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

    private var applied: (rows: Int, color: UIColor)?

    func apply(totalRows: Int, palette: ThemePalette) {
        if let applied, applied.rows == totalRows, applied.color == palette.ui.blue { return }
        applied = (totalRows, palette.ui.blue)
        divider.backgroundColor = palette.ui.comment.withAlphaComponent(0.25)
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = palette.ui.blue
        configuration.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right")
        configuration.imagePadding = 6
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 11, weight: .semibold
        )
        let title = String(localized: "Show all \(totalRows) rows")
        var attributes = AttributeContainer()
        attributes.font = AppFont.scaledSystem(13, .medium, relativeTo: .footnote, maximumPointSize: 20)
        configuration.attributedTitle = AttributedString(title, attributes: attributes)
        button.configuration = configuration
        button.accessibilityLabel = title
        button.accessibilityHint = String(localized: "Opens table full screen")
    }
}

/// What a markdown table card wears besides its rows: the overflow cue over the
/// scroller and, for a folded table, the "Show all N rows" bar under it.
///
/// `NativeTableBlockView` owns the rows and hands this the facts: how many rows
/// are shown of how many, and where the scroller is. This installs the cue and
/// the bar in the card, and keeps the scroller's bottom edge on the bar while it
/// shows. The cue is an overlay, so it takes no layout; the bar adds
/// `footerHeight`, which the table's measured height includes.
@MainActor
final class TableChrome {
    private let card: UIView
    private let scrollView: UIScrollView
    private let overlay = TableOverflowOverlayView()
    private let footer = TableFoldFooterView()
    private var scrollBottomToCard: NSLayoutConstraint?
    private var scrollBottomToFooter: NSLayoutConstraint?
    private let open: () -> Void
    private let copy: (TableCopyFormat) -> Void

    /// Whether the bar shows (the table drew fewer rows than it has).
    private(set) var isFolded = false

    var footerHeight: CGFloat { isFolded ? TableFoldFooterView.height : 0 }

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
        overlay.onActivate = { [open] in open() }
        footer.onActivate = { [open] in open() }
        overlay.setMenu(UIMenu(children: TableCopyFormat.allCases.map { format in
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

    /// Called on every table apply, streaming ticks included. Returns whether the
    /// bar appeared or went away, so the table can invalidate its height.
    func update(shownRows: Int, totalRows: Int, palette: ThemePalette) -> Bool {
        overlay.apply(palette: palette)
        let folded = totalRows > shownRows
        if folded { footer.apply(totalRows: totalRows, palette: palette) }
        guard folded != isFolded else { return false }
        isFolded = folded
        footer.isHidden = !folded
        scrollBottomToCard?.isActive = !folded
        scrollBottomToFooter?.isActive = folded
        return true
    }

    /// Shows the fade and the count of columns past `visibleMaxX` while the
    /// content (`contentWidth`) reaches further right than the scroller shows.
    func updateCue(visibleMaxX: CGFloat, contentWidth: CGFloat, trailingEdges: [CGFloat]) {
        guard visibleMaxX > 0 else { return }
        overlay.update(
            hiddenColumns: MarkdownTableColumnLayout.hiddenColumnCount(trailingEdges: trailingEdges, visibleMaxX: visibleMaxX),
            canScrollRight: contentWidth - visibleMaxX > 1
        )
    }
}
