import UIKit

// The views one `blocks` tree is drawn with: a tap region, a row or a stack, and one view per
// primitive kind. `ExtensionSurfaceBlockRenderer.swift` decides which view a node gets and what it
// says; these own how it is laid out and painted.

// MARK: - Tap regions

/// A region a node offers as one tap target: the whole area answers, and assistive activation runs
/// the same host action as a touch. Without an action it is a plain container, so the controls
/// inside it stay elements of their own.
class BlocksTapControl: UIControl {
    private var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addTarget(self, action: #selector(dimForPress), for: [.touchDown, .touchDragEnter])
        addTarget(self, action: #selector(resetPress), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Make this region a button, or a plain container when `tap` is nil. A region whose action is
    /// waiting, or whose node is published disabled, sends nothing and says so — by touch and by
    /// assistive activation alike — and dims, because a control nobody may use looks that way.
    func applyTap(
        _ tap: (() -> Void)?,
        label: String?,
        identifier: String?,
        hint: String?,
        enabled: Bool = true,
        selected: Bool = false
    ) {
        onTap = tap
        isEnabled = enabled
        alpha = enabled ? 1 : 0.55
        accessibilityIdentifier = identifier
        isAccessibilityElement = tap != nil
        // A control's own state is what UIKit reads its traits from; the trait alone would be
        // dropped, because a `UIControl` that is not selected is not selected.
        self.isSelected = selected
        guard tap != nil else {
            accessibilityLabel = nil
            accessibilityHint = nil
            // A region nobody can tap is still — or is not — the active item of a set, and that
            // state is the surface's, not the tap's.
            accessibilityTraits = selected ? .selected : .none
            return
        }
        accessibilityLabel = label
        accessibilityHint = hint
        var traits: UIAccessibilityTraits = .button
        if !enabled { traits.insert(.notEnabled) }
        if selected { traits.insert(.selected) }
        accessibilityTraits = traits
    }

    @objc private func dimForPress() {
        guard onTap != nil, isEnabled else { return }
        alpha = 0.6
    }

    @objc private func resetPress() {
        alpha = isEnabled ? 1 : 0.55
    }

    @objc func handleTap() {
        guard isEnabled else { return }
        onTap?()
    }

    override func accessibilityActivate() -> Bool {
        guard let onTap, isEnabled else { return false }
        onTap()
        return true
    }
}

// MARK: - Layout

/// A row or a stack: the host's stack view, with the tree's spacing and alignment.
///
/// A row becomes a column when its children cannot share one line at the width it is given, or at
/// an accessibility text size, so a headline and its badge never squeeze each other off the edge.
/// `align` decides where a packed group sits: `leading` starts it at the leading edge and lets the
/// text take the spare width, `center` and `trailing` move the whole group, and `spread` pushes the
/// children to both edges.
final class BlocksLayoutView: BlocksTapControl, BlocksColumnFillable {
    private let stack = UIStackView()
    private var stackLeading: NSLayoutConstraint?
    private var stackTrailing: NSLayoutConstraint?
    private var stackCenter: NSLayoutConstraint?
    private var stackTop: NSLayoutConstraint?
    private var stackBottom: NSLayoutConstraint?
    /// The inset a selected region gives its children, so the capsule has air around the words it
    /// marks instead of hugging them.
    private static let selectionInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    private var paintsSelection = false
    private var columnFill: [(UIView, NSLayoutConstraint)] = []
    private var childWidths: [(UIView, NSLayoutConstraint)] = []
    private var align: String?
    private var isRow = true
    private var inline = false
    private var measuredWidth: CGFloat = 0
    /// The axis and alignment the constraints were last set for: a layout pass changes them only
    /// when the answer changed, so measuring never churns constraints.
    private var appliedVertical: Bool?
    private var appliedAlign: String?
    private var appliedRowAlignment: UIStackView.Alignment?

    /// Whether this view currently lays its children out vertically, which a row does when its
    /// children cannot share one line.
    fileprivate var laysOutVertically: Bool { appliedVertical ?? !isRow }

    /// Whether one of this row's children is itself a column: then the children share their first
    /// line, so an icon beside a stack of controls sits with the first control instead of floating
    /// halfway down the stack.
    private var containsColumn: Bool {
        stack.arrangedSubviews.contains { ($0 as? BlocksLayoutView)?.laysOutVertically == true }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor)
        let trailing = stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        let center = stack.centerXAnchor.constraint(equalTo: centerXAnchor)
        let top = stack.topAnchor.constraint(equalTo: topAnchor)
        let bottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        stackLeading = leading
        stackTrailing = trailing
        stackCenter = center
        stackTop = top
        stackBottom = bottom
        NSLayoutConstraint.activate([
            top,
            bottom,
            leading,
            center,
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        children: [UIView],
        node: ExtensionUISurfaceNode,
        action: ExtensionUISurfaceNodeAction?,
        spacing: CGFloat,
        align: String?,
        isRow: Bool,
        inline: Bool,
        selected: Bool,
        disabled: Bool,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        self.isRow = isRow
        self.inline = inline
        self.align = align
        stack.spacing = spacing
        self.paintsSelection = selected
        ExtensionSurfaceBlockMetrics.paintSelection(paintsSelection, on: self, palette: environment.palette)
        let inset = selected ? Self.selectionInset : .zero
        stackTop?.constant = inset.top
        stackBottom?.constant = -inset.bottom
        stackLeading?.constant = inset.left
        stackTrailing?.constant = -inset.right
        for view in stack.arrangedSubviews where !children.contains(where: { $0 === view }) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in children.enumerated() {
            if stack.arrangedSubviews.indices.contains(index), stack.arrangedSubviews[index] === view {
                continue
            }
            stack.insertArrangedSubview(view, at: index)
        }
        for entry in columnFill { entry.1.isActive = false }
        for entry in childWidths { entry.1.isActive = false }
        // Whatever a child's own hugging says, it never draws outside the stack that holds it: a
        // long badge or a wide table wraps or shrinks rather than escaping the card.
        childWidths = children.map { view in
            (view, view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor))
        }
        columnFill = children.compactMap { view in
            guard let fillable = view as? BlocksColumnFillable, fillable.fillsColumn else { return nil }
            return (view, view.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        appliedVertical = nil
        applyLayout()
        applyTap(
            action.flatMap { environment.tap(for: node, action: $0) },
            label: node.base?.accessibility?.label ?? ExtensionSurfaceBlockWords.words(of: node),
            identifier: environment.identifier(for: node),
            hint: node.base?.accessibility?.hint,
            enabled: !disabled && (action.map { !environment.isDisabled($0, nodeId: node.id) } ?? true),
            selected: paintsSelection
        )
        for entry in childWidths { entry.1.isActive = true }
    }

    private func applyLayout() {
        let vertical = !isRow || (!inline && shouldStack)
        let rowAlignment: UIStackView.Alignment = containsColumn ? .top : .center
        guard appliedVertical != vertical || appliedAlign != align || appliedRowAlignment != rowAlignment
        else { return }
        appliedVertical = vertical
        appliedAlign = align
        appliedRowAlignment = rowAlignment
        stack.axis = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : rowAlignment
        stack.distribution = .fill
        guard !vertical else {
            stackLeading?.isActive = true
            stackTrailing?.isActive = true
            stackCenter?.isActive = false
            for entry in columnFill { entry.1.isActive = true }
            return
        }
        for entry in columnFill { entry.1.isActive = false }
        switch align {
        case "center":
            stackLeading?.isActive = false
            stackTrailing?.isActive = false
            stackCenter?.isActive = true
        case "trailing":
            stackLeading?.isActive = false
            stackTrailing?.isActive = true
            stackCenter?.isActive = false
        case "spread":
            stackLeading?.isActive = true
            stackTrailing?.isActive = true
            stackCenter?.isActive = false
            stack.distribution = .equalSpacing
        default:
            stackLeading?.isActive = true
            stackTrailing?.isActive = true
            stackCenter?.isActive = false
        }
    }

    /// Whether a row's children cannot share one line at the width it is given.
    private var shouldStack: Bool {
        guard isRow else { return false }
        guard !traitCollection.preferredContentSizeCategory.isAccessibilityCategory else { return true }
        let available = bounds.width > 0 ? bounds.width : measuredWidth
        guard available > 0 else { return false }
        let spacing = stack.spacing * CGFloat(max(0, stack.arrangedSubviews.count - 1))
        let natural = stack.arrangedSubviews.reduce(CGFloat.zero) { total, view in
            guard !view.isHidden else { return total }
            return total + view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        }
        return natural + spacing > available + 0.5
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0, abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
        }
        applyLayout()
        if paintsSelection { layer.cornerRadius = ExtensionSurfaceBlockMetrics.selectionRadius(bounds) }
        for case let block as any ExtensionNativeBlockRendering in stack.arrangedSubviews {
            block.adoptLayoutWidth(stack.bounds.width)
        }
    }
}

// MARK: - Text and badge

/// A text node: the host's type ramp, a palette tone, and — when it offers one — the node's tap.
final class BlocksTextView: BlocksTapControl, BlocksColumnFillable {
    private let label = UILabel()
    private var insets = [(NSLayoutConstraint, CGFloat)]()
    private var paintsSelection = false
    /// The air a chip gives its words: enough beside a capsule's own round ends that the words do
    /// not look like they spill into them.
    private static let chipHorizontalInset: CGFloat = 12
    private static let chipVerticalInset: CGFloat = 5

    /// A sentence takes the column, so its words wrap. A selected chip is the active item of a set:
    /// it keeps its own width and sits beside its siblings instead of over them.
    var fillsColumn: Bool { !paintsSelection }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let top = label.topAnchor.constraint(equalTo: topAnchor)
        let bottom = label.bottomAnchor.constraint(equalTo: bottomAnchor)
        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor)
        let trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor)
        insets = [
            (top, Self.chipVerticalInset),
            (bottom, Self.chipVerticalInset),
            (leading, Self.chipHorizontalInset),
            (trailing, Self.chipHorizontalInset),
        ]
        NSLayoutConstraint.activate([top, bottom, leading, trailing])
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        text node: ExtensionUISurfaceTextNode,
        node surfaceNode: ExtensionUISurfaceNode,
        action: ExtensionUISurfaceNodeAction?,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        label.text = node.text
        label.font = ExtensionSurfaceBlockMetrics.font(node.style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ExtensionSurfaceBlockMetrics.textColor(node.tone, environment.palette)
        // A pill gives one line; a card body never truncates the extension's words.
        label.numberOfLines = environment.inline ? 1 : 0
        label.lineBreakMode = environment.inline ? .byTruncatingTail : .byWordWrapping
        paintsSelection = node.selected == true
        // A chip is its own capsule: the row may not squeeze it under its words, whatever the
        // sentence beside it wants. Plain text gives way instead, so the words wrap.
        setContentHuggingPriority(paintsSelection ? .required : .defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(
            paintsSelection ? .required : (environment.inline ? .defaultLow : .defaultHigh),
            for: .horizontal
        )
        ExtensionSurfaceBlockMetrics.paintSelection(paintsSelection, on: self, palette: environment.palette)
        for (constraint, constant) in insets {
            constraint.constant = paintsSelection ? constant : 0
        }
        applyTap(
            action.flatMap { environment.tap(for: surfaceNode, action: $0) },
            label: node.base.accessibility?.label ?? node.text,
            identifier: environment.identifier(for: surfaceNode),
            hint: node.base.accessibility?.hint,
            enabled: node.disabled != true
                && (action.map { !environment.isDisabled($0, nodeId: surfaceNode.id) } ?? true),
            selected: paintsSelection
        )
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if paintsSelection { layer.cornerRadius = ExtensionSurfaceBlockMetrics.selectionRadius(bounds) }
    }

    /// In a pill the text takes whatever the pill leaves, up to one line's own width.
    ///
    /// A selected chip is the one text node with a width of its own: its words plus the capsule's
    /// air. Without one the row would give a plain view whatever space it had, and the fill would
    /// run under the chip beside it. A sentence keeps no width, so it wraps in the column instead.
    override var intrinsicContentSize: CGSize {
        if paintsSelection, let text = label.text, !text.isEmpty {
            let width = ExtensionSurfaceBlockMetrics.inlineTextMaxWidth
            let needed = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(
                width: min(ceil(needed.width), width) + Self.chipHorizontalInset * 2,
                height: needed.height + Self.chipVerticalInset * 2
            )
        }
        guard label.numberOfLines == 1, let text = label.text, !text.isEmpty else {
            return super.intrinsicContentSize
        }
        let width = ExtensionSurfaceBlockMetrics.inlineTextMaxWidth
        let needed = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(ceil(needed.width), width), height: needed.height)
    }
}

/// A badge: a capsule in the tone's colour, with the extension's words inside it. Its words wrap
/// rather than run past the card, so a long badge at an accessibility size grows taller instead.
final class BlocksBadgeView: BlocksTapControl {
    private let label = UILabel()
    private let icon = UIImageView()
    private let content = UIStackView()
    private var paintsSelection = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The server's symbol sits before the words, so both share the capsule's one line.
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 3
        content.addArrangedSubview(icon)
        content.addArrangedSubview(label)
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        badge node: ExtensionUISurfaceBadgeNode,
        node surfaceNode: ExtensionUISurfaceNode,
        action: ExtensionUISurfaceNodeAction?,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        let palette = environment.palette
        let tone = ExtensionSurfaceTone(raw: node.tone)
        let color = tone.color(palette)
        let words = tone == .neutral ? palette.ui.fg : color
        label.text = node.text
        label.font = ExtensionNativeBlockStyle.font(.caption2, weight: .semibold)
        label.textColor = words
        icon.image = node.icon.flatMap { name in
            UIImage.scaledSymbol(name, style: .caption2, weight: .semibold, color: words)
        }
        icon.isHidden = icon.image == nil
        paintsSelection = node.selected == true
        // A selection is the host's own mark, so it paints over the tone the badge arrived with.
        if paintsSelection {
            ExtensionSurfaceBlockMetrics.paintSelection(paintsSelection, on: self, palette: palette)
        } else {
            backgroundColor = color.withAlphaComponent(tone == .neutral ? 0.10 : 0.16)
            layer.borderWidth = 0
        }
        layer.cornerCurve = .continuous
        applyTap(
            action.flatMap { environment.tap(for: surfaceNode, action: $0) },
            label: node.base.accessibility?.label ?? node.text,
            identifier: environment.identifier(for: surfaceNode),
            hint: node.base.accessibility?.hint,
            enabled: node.disabled != true
                && (action.map { !environment.isDisabled($0, nodeId: surfaceNode.id) } ?? true),
            selected: paintsSelection
        )
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

/// An icon: an SF Symbol the server allow-lists. A name this build cannot draw leaves the gap
/// empty rather than failing the node.
final class BlocksIconView: UIView {
    private let image = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        NSLayoutConstraint.activate([
            image.topAnchor.constraint(equalTo: topAnchor),
            image.bottomAnchor.constraint(equalTo: bottomAnchor),
            image.leadingAnchor.constraint(equalTo: leadingAnchor),
            image.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        icon node: ExtensionUISurfaceIconNode,
        node surfaceNode: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        let color = ExtensionSurfaceBlockMetrics.textColor(node.tone, environment.palette)
        image.image = UIImage.scaledSymbol(
            node.name,
            style: environment.inline ? .caption1 : .body,
            weight: .semibold,
            color: color
        )
        image.isHidden = image.image == nil
        let label = node.base.accessibility?.label
        isAccessibilityElement = label != nil
        accessibilityLabel = label
        accessibilityValue = node.base.accessibility?.value
        accessibilityIdentifier = environment.identifier(for: surfaceNode)
        accessibilityTraits = .image
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        image.isHidden ? .zero : image.intrinsicContentSize
    }
}

// MARK: - Group

/// A titled region the tree folds away. The host owns the disclosure control: the published
/// `collapsed` decides what a reader first sees, and after that the person's own choice stands
/// until the surface publishes a different one. Nothing here sends an action — folding a region is
/// the reader's business, not the extension's.
final class BlocksGroupView: UIView, BlocksColumnFillable {
    private let disclosure = UIButton(type: .system)
    private let content = UIStackView()
    private var publishedCollapsed: Bool?
    /// What the reader last saw: the chevron follows it, and so does what VoiceOver reads.
    private var isExpanded = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.contentHorizontalAlignment = .leading
        disclosure.addTarget(self, action: #selector(toggleCollapsed), for: .touchUpInside)
        content.axis = .vertical
        content.alignment = .fill
        content.spacing = 8
        let column = UIStackView(arrangedSubviews: [disclosure, content])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        title: String,
        collapsed: Bool?,
        children: [UIView],
        node: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        let palette = environment.palette
        let identifier = environment.identifier(for: node)
        accessibilityIdentifier = identifier
        // A region the extension publishes a new state for follows it; the same state again leaves
        // the reader where they left themselves.
        if publishedCollapsed != collapsed {
            publishedCollapsed = collapsed
            isExpanded = !(collapsed ?? false)
        }
        disclosure.setTitle(title, for: .normal)
        disclosure.setTitleColor(palette.ui.comment, for: .normal)
        disclosure.titleLabel?.font = ExtensionNativeBlockStyle.font(.caption1, weight: .semibold)
        disclosure.titleLabel?.adjustsFontForContentSizeCategory = true
        disclosure.tintColor = palette.ui.comment
        disclosure.semanticContentAttribute = .forceLeftToRight
        disclosure.imageEdgeInsets = UIEdgeInsets(top: 0, left: -2, bottom: 0, right: 2)
        disclosure.accessibilityIdentifier = identifier.map { "\($0).disclosure" }
        disclosure.accessibilityLabel = title
        disclosure.accessibilityValue = isExpanded
            ? String(localized: "Expanded")
            : String(localized: "Collapsed")
        disclosure.accessibilityTraits = .button

        for view in content.arrangedSubviews where !children.contains(where: { $0 === view }) {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in children.enumerated() {
            if content.arrangedSubviews.indices.contains(index), content.arrangedSubviews[index] === view {
                continue
            }
            content.insertArrangedSubview(view, at: index)
        }
        // A collapsed region keeps its children built — a patch may change them — but takes them
        // off screen and out of the accessibility tree.
        content.isHidden = !isExpanded
        disclosure.setImage(chevron(), for: .normal)
    }

    @objc private func toggleCollapsed() {
        isExpanded.toggle()
        content.isHidden = !isExpanded
        disclosure.setImage(chevron(), for: .normal)
        disclosure.accessibilityValue = isExpanded
            ? String(localized: "Expanded")
            : String(localized: "Collapsed")
    }

    private func chevron() -> UIImage? {
        UIImage(
            systemName: isExpanded ? "chevron.down" : "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
    }
}

// MARK: - Progress

/// A progress ring: the one shape the host's bar cannot answer, for a value kept at the end of a
/// row or inside a pill, with the node's words beside it the way the bar paints its label. A value
/// draws its arc; no value draws a dashed arc where the bar shows a spinner.
final class BlocksProgressRingView: UIView {
    private let glyph = BlocksProgressRingGlyph()
    private let label = ExtensionNativeBlockStyle.label(.caption1)
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        // The ring's own element speaks these words, so the label is paint, not a second stop.
        label.isAccessibilityElement = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(glyph)
        row.addArrangedSubview(label)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        progress node: ExtensionUISurfaceProgressNode,
        node surfaceNode: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        // A ring with a tone paints it; with none it is the host's accent, like the bar's fill.
        let palette = environment.palette
        let tone = ExtensionSurfaceTone(raw: node.tone)
        let arc = tone == .neutral ? palette.ui.cyan : tone.color(palette)
        let normalized = ExtensionNativeBlockPresentation.normalizedProgress(node.value)
        glyph.apply(
            track: tone == .neutral
                ? palette.ui.fg.withAlphaComponent(0.14)
                : arc.withAlphaComponent(0.18),
            arc: arc,
            fraction: normalized
        )
        let words = node.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        label.text = (words?.isEmpty == false) ? words : nil
        label.textColor = palette.ui.fg
        label.isHidden = label.text == nil
        accessibilityLabel = node.base.accessibility?.label ?? node.label ?? String(localized: "Progress")
        accessibilityValue = node.base.accessibility?.value
            ?? normalized.map(ExtensionNativeBlockPresentation.percentText)
            ?? String(localized: "In progress")
        accessibilityIdentifier = environment.identifier(for: surfaceNode)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        row.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }
}

/// The ring itself: a track and an arc, sized by its container.
private final class BlocksProgressRingGlyph: UIView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for shape in [track, arc] as [CAShapeLayer] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 2.5
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(track trackColor: UIColor, arc arcColor: UIColor, fraction: Double?) {
        track.strokeColor = trackColor.cgColor
        arc.strokeColor = arcColor.cgColor
        if let fraction {
            arc.lineDashPattern = nil
            arc.strokeEnd = CGFloat(fraction)
        } else {
            arc.lineDashPattern = [2, 3]
            arc.strokeEnd = 1
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: (side - arc.lineWidth) / 2,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            clockwise: true
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track, arc] as [CAShapeLayer] {
            shape.path = path.cgPath
            shape.frame = bounds
        }
        CATransaction.commit()
    }
}

// MARK: - Key/value

/// Facts as two columns: one row per pair, reused across applies so a patch rewrites words rather
/// than rebuilding rows, and every value starts where the widest key ends so the pairs line up.
final class BlocksKeyValueView: UIView, BlocksColumnFillable {
    private let stack = UIStackView()
    private var rows: [BlocksKeyValueRow] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        pairs: [ExtensionUISurfaceNodeKeyValuePair],
        node: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        let palette = environment.palette
        // One type step between the columns: the key is a weighted line of the value's own size,
        // not a smaller caption, so a fact reads as one pair instead of two kinds of text.
        let keyFont = ExtensionNativeBlockStyle.font(.subheadline, weight: .semibold)
        let keyWidth = pairs.reduce(CGFloat.zero) { widest, pair in
            max(widest, ceil((pair.key as NSString).size(withAttributes: [.font: keyFont]).width))
        }
        while rows.count < pairs.count {
            let row = BlocksKeyValueRow()
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        for (index, row) in rows.enumerated() {
            guard index < pairs.count else {
                row.isHidden = true
                continue
            }
            let pair = pairs[index]
            row.isHidden = false
            row.apply(
                pair: pair,
                keyFont: keyFont,
                keyWidth: keyWidth,
                palette: palette
            )
        }
        accessibilityIdentifier = environment.identifier(for: node)
    }
}

/// One key and its value: the key takes the shared column width, the value wraps in what is left.
private final class BlocksKeyValueRow: UIStackView {
    private let key = ExtensionNativeBlockStyle.label(.subheadline, weight: .semibold)
    private let value = ExtensionNativeBlockStyle.label(.body)
    private let keyWidth: NSLayoutConstraint
    /// The share of the row the key column may take. A key is any length the wire allows, and the
    /// widest one sets the column every row shares, so an unbounded column pushes the values out
    /// past the card's edge, where nothing clips them.
    private lazy var keyCap = self.key.widthAnchor.constraint(
        lessThanOrEqualTo: self.widthAnchor,
        multiplier: 0.45
    )
    private var sharedKeyWidth: CGFloat = 0

    init() {
        keyWidth = key.widthAnchor.constraint(equalToConstant: 0)
        // Priorities are a ladder: the value settles at its own size (250), the key hugs its words
        // (750), the shared column wins over that hugging (999), and `keyCap` wins over the column.
        keyWidth.priority = UILayoutPriority(999)
        super.init(frame: .zero)
        // A key is a label, not prose: it stays on one line and the tail truncates, and the pair's
        // accessibility label keeps the whole of it.
        key.numberOfLines = 1
        key.lineBreakMode = .byTruncatingTail
        key.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addArrangedSubview(key)
        addArrangedSubview(value)
        applyStacking()
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func apply(
        pair: ExtensionUISurfaceNodeKeyValuePair,
        keyFont: UIFont,
        keyWidth: CGFloat,
        palette: ThemePalette
    ) {
        sharedKeyWidth = keyWidth
        key.text = pair.key
        key.font = keyFont
        key.textColor = palette.ui.comment
        value.text = pair.value
        value.textColor = ExtensionSurfaceBlockMetrics.textColor(pair.tone, palette)
        accessibilityLabel = "\(pair.key), \(pair.value)"
        applyStacking()
    }

    /// Side by side while the key column leaves the value room to wrap; at an accessibility size the
    /// pair stacks, because a column wide enough for the longest key would leave the value nothing.
    private func applyStacking() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        axis = stacked ? .vertical : .horizontal
        // A vertical stack has no baseline to align to; the key then sits above its value.
        alignment = stacked ? .leading : .firstBaseline
        spacing = stacked ? 2 : 12
        keyWidth.constant = sharedKeyWidth
        keyWidth.isActive = !stacked
        keyCap.isActive = !stacked
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            applyStacking()
        }
    }
}

// MARK: - Table

/// A table node: the dataTable's grid and its row controls, so a row's actions live on a context
/// menu and its own menu button, and activation runs the row's first action. The node id names the
/// grid; each row extends it, exactly as a `dataTable` row does.
final class BlocksTableView: UIView, BlocksColumnFillable {
    private let headerRow = ExtensionSurfaceTableHeaderRow()
    private let rows = UIStackView()
    private var rowViews: [String: ExtensionSurfaceTableRowView] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        rows.axis = .vertical
        rows.alignment = .fill
        rows.spacing = 2
        let column = UIStackView(arrangedSubviews: [headerRow, rows])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        table node: ExtensionUISurfaceTableNode,
        node surfaceNode: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        // A wire table names its columns by title; the grid keys a cell by column id, so the
        // column's position is its id. Nothing about a title is identity.
        let columns = node.columns.enumerated().map { index, title in
            ExtensionUISurfaceColumn(id: String(index), title: title, kind: nil)
        }
        headerRow.apply(columns: columns, sort: nil, palette: environment.palette)

        let grid = environment.identifier(for: surfaceNode) ?? environment.identifierRoot
        var kept: [String: ExtensionSurfaceTableRowView] = [:]
        var ordered: [UIView] = []
        for (index, row) in node.rows.enumerated() {
            let rowId = row.id ?? String(index)
            guard kept[rowId] == nil else { continue }
            let view = rowViews[rowId] ?? ExtensionSurfaceTableRowView()
            let cells = Dictionary(
                uniqueKeysWithValues: row.cells.enumerated().map { (String($0.offset), $0.element) }
            )
            view.apply(
                row: ExtensionUISurfaceRow(id: rowId, cells: cells, actions: row.actions?.map(\.id)),
                columns: columns,
                selected: false,
                definitions: environment.context.surface.actions,
                pending: environment.wait(nodeId: surfaceNode.id),
                palette: environment.palette,
                identifier: ExtensionSurfaceIdentity.element(root: grid, key: rowId),
                onAction: { actionId in
                    guard let action = row.actions?.first(where: { $0.id == actionId }) else { return }
                    environment.rowTap(for: surfaceNode, rowId: rowId, action: action)?()
                }
            )
            kept[rowId] = view
            ordered.append(view)
        }
        for view in rows.arrangedSubviews where !ordered.contains(where: { $0 === view }) {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in ordered.enumerated() {
            rows.insertArrangedSubview(view, at: index)
        }
        rowViews = kept
        accessibilityIdentifier = grid
        isAccessibilityElement = false
    }
}
