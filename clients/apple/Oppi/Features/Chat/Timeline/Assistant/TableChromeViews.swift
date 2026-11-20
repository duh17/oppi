import UIKit

/// How a markdown table card shows less than its table, in each direction.
///
/// Rows fold behind the bar under the card: "Show 5 more rows". Columns that
/// run past the trailing edge are named on that edge, where the rows scroll to
/// them: a fade and a "+3 ›" chip. A card can need neither, either, or both.
/// `TableChrome` resolves this on every apply and every sideways scroll.
struct TableOverflow: Equatable {
    /// Rows the card does not draw; nil when it draws every row.
    var moreRows: Int?
    /// Columns that start at or past the trailing edge's fade, wholly unseen;
    /// nil when no column reaches past the edge. Zero when the only one cut is
    /// partly in view: the chip then shows its chevron alone.
    var moreColumns: Int?

    /// How wide the fade over the trailing edge is.
    static let fadeWidth: CGFloat = 36

    /// - Parameters:
    ///   - shownRows: rows drawn in the card.
    ///   - totalRows: rows in the table.
    ///   - trailingEdges: the right edge of each column, in scroller content coordinates.
    ///   - visibleMaxX: the right edge of what the scroller shows, in the same coordinates.
    ///   - contentWidth: how wide the scroller's content is.
    static func resolve(
        shownRows: Int,
        totalRows: Int,
        trailingEdges: [CGFloat],
        visibleMaxX: CGFloat,
        contentWidth: CGFloat
    ) -> Self {
        let moreRows = totalRows > shownRows ? totalRows - shownRows : nil
        // The table's own padding past the edge is not a column.
        let cut = contentWidth - visibleMaxX > 1 && trailingEdges.contains { $0 > visibleMaxX + 1 }
        guard cut else { return Self(moreRows: moreRows, moreColumns: nil) }
        // A column starts where the one before it ends; one starting under the
        // fade shows nothing readable.
        let fadeStart = visibleMaxX - fadeWidth
        let unseen = trailingEdges.dropLast().filter { $0 >= fadeStart }.count
        return Self(moreRows: moreRows, moreColumns: unseen)
    }
}

/// What sits over a markdown table card's trailing edge while columns run past
/// it: a fade, and the chip that names them and opens the table full screen.
/// `TableChrome` feeds it the scroll position, so it follows the scroll without
/// touching the table's layout. Every touch but the chip's goes to the table
/// underneath.
///
/// The chip sits on the header row, the row that names columns. It stays
/// inside the fade, whose text is already unreadable: a wider pill once hid the
/// label of the column it said was cut.
final class TableOverflowOverlayView: UIView {
    private let fadeView = TableTrailingFadeView()
    /// "+3 ›": opens the table full screen.
    let moreColumnsButton = TableMoreColumnsButton()
    private lazy var buttonCenterY = moreColumnsButton.centerYAnchor.constraint(equalTo: topAnchor)
    /// Whether the fade is showing.
    private(set) var isCueVisible = false
    /// Whether the chip shows with the fade: off on the full-screen viewer,
    /// which already shows the whole table.
    var offersViewer = true

    /// The overlay sits exactly over the scroller, so its layout pass is the
    /// scroller's resize: the owner refreshes the cue from it.
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = false
        fadeView.translatesAutoresizingMaskIntoConstraints = false
        fadeView.alpha = 0
        fadeView.isUserInteractionEnabled = false
        moreColumnsButton.translatesAutoresizingMaskIntoConstraints = false
        moreColumnsButton.alpha = 0
        moreColumnsButton.isHidden = true
        addSubview(fadeView)
        addSubview(moreColumnsButton)

        NSLayoutConstraint.activate([
            fadeView.topAnchor.constraint(equalTo: topAnchor),
            fadeView.bottomAnchor.constraint(equalTo: bottomAnchor),
            fadeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fadeView.widthAnchor.constraint(equalToConstant: TableOverflow.fadeWidth),
            moreColumnsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            buttonCenterY,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var appliedColor: UIColor?

    /// Called on every table apply, streaming ticks included: a palette it
    /// already drew is skipped.
    func apply(palette: ThemePalette) {
        moreColumnsButton.apply(palette: palette)
        guard palette.ui.bgDark != appliedColor else { return }
        appliedColor = palette.ui.bgDark
        fadeView.apply(color: palette.ui.bgDark)
    }

    /// - Parameters:
    ///   - moreColumns: the columns past the edge (`TableOverflow.moreColumns`).
    ///   - totalColumns: every column, for the chip's spoken label.
    ///   - headerCenter: the header row's vertical middle, from the scroller's top.
    func update(moreColumns: Int?, totalColumns: Int, headerCenter: CGFloat) {
        buttonCenterY.constant = headerCenter
        if let moreColumns { moreColumnsButton.show(more: moreColumns, of: totalColumns) }
        let visible = moreColumns != nil
        guard visible != isCueVisible else { return }
        isCueVisible = visible
        let showsButton = visible && offersViewer
        if showsButton { moreColumnsButton.isHidden = false }
        let changes = {
            self.fadeView.alpha = visible ? 1 : 0
            self.moreColumnsButton.alpha = showsButton ? 1 : 0
        }
        let settle: (Bool) -> Void = { _ in
            // Hidden, not only transparent, so VoiceOver and touches skip it.
            self.moreColumnsButton.isHidden = !(self.isCueVisible && self.offersViewer)
        }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            settle(true)
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: changes, completion: settle)
    }

    /// Only the chip takes touches; the rows under the fade keep scrolling and
    /// selecting.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !moreColumnsButton.isHidden, moreColumnsButton.alpha > 0 else { return false }
        return moreColumnsButton.point(inside: convert(point, to: moreColumnsButton), with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

/// The chip on a table card's trailing edge: "+3 ›" when three columns are
/// unseen, "›" when only a partly shown one is cut. VoiceOver reads "Show all
/// 5 columns". A tap opens the table full screen.
final class TableMoreColumnsButton: UIButton {
    private var count: Int?
    private var palette: ThemePalette?

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "markdown.table.moreColumns"
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Opens table full screen")
        // Its text follows Dynamic Type; the chip grows with it.
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (button: Self, _: UITraitCollection) in
            button.setNeedsUpdateConfiguration()
        }
        configurationUpdateHandler = { [weak self] button in
            guard let self, let palette else { return }
            button.configuration = Self.configuration(count: count, palette: palette)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(palette: ThemePalette) {
        guard self.palette?.uiCache !== palette.uiCache else { return }
        self.palette = palette
        setNeedsUpdateConfiguration()
    }

    func show(more: Int, of total: Int) {
        accessibilityLabel = String(localized: "Show all \(total) columns")
        let count = more > 0 ? more : nil
        guard count != self.count else { return }
        self.count = count
        setNeedsUpdateConfiguration()
    }

    private static func configuration(count: Int?, palette: ThemePalette) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.plain()
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = palette.ui.blue
        configuration.background.backgroundColor = palette.ui.bgHighlight
        configuration.background.strokeColor = palette.ui.mdCodeBlockBorder.withAlphaComponent(0.5)
        configuration.background.strokeWidth = 1
        let font = AppFont.scaledSystem(13, .semibold, relativeTo: .footnote, maximumPointSize: 20)
        configuration.image = UIImage(systemName: "chevron.right")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: font, scale: .small)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 2
        if let count {
            var attributes = AttributeContainer()
            attributes.font = font
            configuration.attributedTitle = AttributedString(count.formatted(.number.sign(strategy: .always())), attributes: attributes)
        }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: count == nil ? 6 : 8, bottom: 3, trailing: 6)
        return configuration
    }

    /// The chip draws smaller than a finger: its touch area is at least 44pt
    /// each way.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let dx = min(0, bounds.width - 44) / 2
        let dy = min(0, bounds.height - 44) / 2
        return bounds.insetBy(dx: dx, dy: dy).contains(point)
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

/// The bar at the foot of a table card that folded its long body: "Show 10
/// more rows". A tap opens the table full screen; a long press offers the copy
/// menu. Columns past the edge never put a bar here: the chip on the edge
/// names them.
final class TableMoreRowsBar: UIView {
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

    static func title(moreRows: Int) -> String {
        String(localized: "Show \(moreRows) more rows")
    }

    private var applied: (title: String, color: UIColor)?

    func apply(title: String, palette: ThemePalette) {
        if let applied, applied.title == title, applied.color == palette.ui.blue { return }
        applied = (title, palette.ui.blue)
        divider.backgroundColor = palette.ui.comment.withAlphaComponent(0.25)
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = palette.ui.blue
        configuration.image = UIImage(systemName: "chevron.down")
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

/// What a markdown table card wears besides its rows, for both ways it can show
/// less than its table (`TableOverflow`): the fade and chip over the scroller's
/// trailing edge while columns run past it, and the `TableMoreRowsBar` under
/// the rows while they are folded.
///
/// `NativeTableBlockView` owns the rows and hands this the facts: how many rows
/// are shown of how many, and where the scroller is. This installs the overlay
/// and the bar in the card, and keeps the scroller's bottom edge on the bar
/// while it shows. The overlay takes no layout; the bar adds `footerHeight`,
/// which the table's measured height includes. Columns never change the
/// height, so a sideways scroll never moves the chat.
@MainActor
final class TableChrome {
    private let card: UIView
    private let scrollView: UIScrollView
    private let overlay = TableOverflowOverlayView()
    private let footer = TableMoreRowsBar()
    private var scrollBottomToCard: NSLayoutConstraint?
    private var scrollBottomToFooter: NSLayoutConstraint?
    private let open: () -> Void
    private let copy: (TableCopyFormat) -> Void
    /// The facts the last apply and the last scroll reported.
    private var rows = (shown: 0, total: 0)
    private var columns = (trailingEdges: [CGFloat](), visibleMaxX: CGFloat(0), contentWidth: CGFloat(0))

    /// Whether the bar shows.
    private(set) var showsFooter = false

    var footerHeight: CGFloat { showsFooter ? TableMoreRowsBar.height : 0 }

    /// Whether the chip on the trailing edge opens the viewer. Off on the
    /// viewer itself; the fade still shows there.
    var offersViewer: Bool {
        get { overlay.offersViewer }
        set { overlay.offersViewer = newValue }
    }

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
        overlay.moreColumnsButton.addAction(UIAction { [open] _ in open() }, for: .touchUpInside)
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

    /// Called on every table apply, streaming ticks included. Returns whether
    /// the bar appeared or went away, so the table can invalidate its height.
    func update(shownRows: Int, totalRows: Int, palette: ThemePalette) -> Bool {
        overlay.apply(palette: palette)
        rows = (shownRows, totalRows)
        let moreRows = resolve().moreRows
        if let moreRows { footer.apply(title: TableMoreRowsBar.title(moreRows: moreRows), palette: palette) }
        let shows = moreRows != nil
        guard shows != showsFooter else { return false }
        showsFooter = shows
        footer.isHidden = !shows
        scrollBottomToCard?.isActive = !shows
        scrollBottomToFooter?.isActive = shows
        return true
    }

    /// Shows the fade and the chip while columns reach past `visibleMaxX`, the
    /// right edge of what the scroller shows. Runs on every sideways scroll.
    func updateCue(visibleMaxX: CGFloat, contentWidth: CGFloat, trailingEdges: [CGFloat], headerCenter: CGFloat) {
        guard visibleMaxX > 0 else { return }
        columns = (trailingEdges, visibleMaxX, contentWidth)
        overlay.update(moreColumns: resolve().moreColumns, totalColumns: trailingEdges.count, headerCenter: headerCenter)
    }

    private func resolve() -> TableOverflow {
        TableOverflow.resolve(
            shownRows: rows.shown,
            totalRows: rows.total,
            trailingEdges: columns.trailingEdges,
            visibleMaxX: columns.visibleMaxX,
            contentWidth: columns.contentWidth
        )
    }
}
