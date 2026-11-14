import UIKit

/// The composer action row's pop-up control at regular width (`ComposerAction.Chrome.popUp`):
/// a body-size title, an icon, and the system's pop-up indicator on a standard gray capsule.
/// Not the caption-size glass pill the chat's row draws.
///
/// The row can run out of room, so a button has three displays, chosen by
/// `ComposerPopUpFit` from the measured width: the full title, the icon alone
/// (only a button that is `collapsible`), and a title cut short to a width.
@MainActor
final class ComposerPopUpButton: UIButton {
    enum Display: Equatable {
        case full
        case iconOnly
        case truncated
    }

    /// The visible capsule's height; the hit band is 44 pt (`ComposerHitTarget`).
    static let height: CGFloat = 40
    /// A truncated title keeps at least this much beside the icon: a few
    /// letters, never a single one.
    private static let minimumTitleWidth: CGFloat = 56

    private(set) var display = Display.full
    /// True while this button's menu is up, so a hardware Esc goes to the
    /// menu and not to the screen's own Esc (`ComposerBarController.keepsEscapeKey`).
    private(set) var isMenuOpen = false
    private var title = ""
    private var icon: UIImage?
    private var tint = UIColor.label
    private var fillColor = UIColor.clear
    private var collapsible = false
    private var truncatedWidth: CGFloat?
    private var widthCap: NSLayoutConstraint?
    /// The widths `fitItem` measured for the current content. `apply` clears
    /// it; a Dynamic Type change re-runs `apply`.
    private var measuredFit: ComposerPopUpFit.Item?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isPointerInteractionEnabled = true
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        ComposerHitTarget.contains(point, in: bounds)
    }

    /// `collapsible` lets the button give up its title for the icon alone.
    func apply(
        title: String,
        icon: UIImage?,
        tint: UIColor,
        fill: UIColor,
        collapsible: Bool,
        hasMenu: Bool
    ) {
        self.title = title
        self.icon = icon
        self.tint = tint
        fillColor = fill
        self.collapsible = collapsible && icon != nil
        showsMenuAsPrimaryAction = hasMenu
        measuredFit = nil
        refresh()
    }

    /// What `ComposerPopUpFit` needs: the widths of each display. Measured
    /// once per content, not on every layout pass that asks.
    var fitItem: ComposerPopUpFit.Item {
        if let measuredFit { return measuredFit }
        let full = width(for: configuration(for: .full))
        let iconOnly = width(for: configuration(for: .iconOnly))
        let item = ComposerPopUpFit.Item(
            full: full,
            iconOnly: collapsible ? iconOnly : nil,
            minimum: min(full, iconOnly + Self.minimumTitleWidth)
        )
        measuredFit = item
        return item
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        isMenuOpen = true
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        isMenuOpen = false
    }

    func setDisplay(_ result: ComposerPopUpFit.Result) {
        guard display != result.display || truncatedWidth != (result.display == .truncated ? result.width : nil) else {
            return
        }
        display = result.display
        // An icon alone has no title left to give: past every control's floor
        // (a busy row in a 375 pt pane), the squeeze must cut a title, never
        // the icon into its indicator.
        setContentCompressionResistancePriority(display == .iconOnly ? .defaultHigh : .defaultLow, for: .horizontal)
        truncatedWidth = result.display == .truncated ? result.width : nil
        widthCap?.isActive = false
        widthCap = nil
        if let truncatedWidth {
            let cap = widthAnchor.constraint(lessThanOrEqualToConstant: truncatedWidth)
            cap.isActive = true
            widthCap = cap
        }
        refresh()
    }

    private func refresh() {
        configuration = configuration(for: display)
        invalidateIntrinsicContentSize()
    }

    /// The standard gray capsule the row's controls share (the "+" attach
    /// button too, `ComposerGlassPillButton.applyPopUpStyle`).
    static func baseConfiguration(tint: UIColor, fill: UIColor) -> UIButton.Configuration {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.baseForegroundColor = tint
        config.background.backgroundColor = fill
        return config
    }

    static func fill(for colors: ComposerThemeColors) -> UIColor {
        colors.bgHighlight.withAlphaComponent(0.6)
    }

    private func configuration(for display: Display) -> UIButton.Configuration {
        var config = Self.baseConfiguration(tint: tint, fill: fillColor)
        config.indicator = .popup
        config.indicatorColorTransformer = UIConfigurationColorTransformer { _ in .secondaryLabel }
        config.image = icon
        config.imagePadding = 6
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        if display == .iconOnly {
            config.title = nil
        } else {
            config.title = title
            config.titleLineBreakMode = .byTruncatingTail
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFont.preferredFont(forTextStyle: .body)
                return outgoing
            }
        }
        return config
    }

    /// The width a configuration needs: measured on a scratch button, which
    /// has the system's own metrics for the indicator and insets.
    private func width(for config: UIButton.Configuration) -> CGFloat {
        let scratch = UIButton(configuration: config)
        scratch.showsMenuAsPrimaryAction = showsMenuAsPrimaryAction
        let size = scratch.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return ceil(max(size.width, Self.height))
    }
}

/// Which display each pop-up control in a crowded action row takes. Pure, so
/// the order is checked without a layout pass.
///
/// `items` come in the order they give up room: the first loses its title for
/// its icon (if it has one) before the next is touched; a control with no icon
/// stage is cut short instead, down to its `minimum`. The order for Quick
/// Session's row is thinking (icon only), then the Agent's name, then the
/// model (each cut short).
enum ComposerPopUpFit {
    struct Item: Equatable {
        var full: CGFloat
        /// Nil when the control keeps its title.
        var iconOnly: CGFloat?
        var minimum: CGFloat
    }

    struct Result: Equatable {
        var display: ComposerPopUpButton.Display
        var width: CGFloat
    }

    static func resolve(_ items: [Item], available: CGFloat, spacing: CGFloat) -> [Result] {
        var results = items.map { Result(display: .full, width: $0.full) }
        let gaps = spacing * CGFloat(max(items.count - 1, 0))
        func total() -> CGFloat { results.reduce(gaps) { $0 + $1.width } }

        for (index, item) in items.enumerated() {
            guard total() > available else { break }
            if let iconOnly = item.iconOnly {
                results[index] = Result(display: .iconOnly, width: iconOnly)
            } else if item.minimum < item.full {
                let others = total() - item.full
                results[index] = Result(display: .truncated, width: min(item.full, max(item.minimum, available - others)))
            }
        }
        return results
    }
}
