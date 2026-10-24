import UIKit

// Rows and chrome for `SessionOutlineViewController`. Colors come from the
// theme palette the controller passes in; fonts are Dynamic Type text styles.

enum SessionOutlineStyle {
    static func font(_ style: UIFont.TextStyle, bold: Bool = false, monospaced: Bool = false) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        if monospaced {
            return UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: bold ? .bold : .regular)
        }
        guard bold, let descriptor = base.fontDescriptor.withSymbolicTraits(.traitBold) else { return base }
        return UIFont(descriptor: descriptor, size: 0)
    }

    @MainActor
    static func hairline(_ view: UIView) -> CGFloat {
        1 / max(view.traitCollection.displayScale, 1)
    }
}

/// The one accessibility element of an outline row: a button whose label is
/// the row's text. VoiceOver activation runs the same owner action as a tap.
final class SessionOutlineRowElement: UIView {
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func accessibilityActivate() -> Bool {
        guard let onActivate, !accessibilityTraits.contains(.notEnabled) else { return false }
        onActivate()
        return true
    }
}

// MARK: - Timeline row

final class SessionOutlineEntryCell: UICollectionViewListCell {
    let row = SessionOutlineRowElement()
    let summaryLabel = UILabel()
    private let iconView = UIImageView()
    private let compactionBadge = InsetLabel.outlineBadge()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let timeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .center
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        summaryLabel.numberOfLines = 2
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [addedLabel, removedLabel, timeLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        compactionBadge.text = "Compaction"

        let diffStack = UIStackView(arrangedSubviews: [addedLabel, removedLabel])
        diffStack.spacing = 3
        let stack = UIStackView(arrangedSubviews: [iconView, summaryLabel, compactionBadge, diffStack, timeLabel])
        stack.axis = .horizontal
        stack.alignment = .top
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            iconView.widthAnchor.constraint(equalToConstant: 16),
        ])
        isAccessibilityElement = false
        accessibilityElements = [row]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ entry: OutlineEntry, palette: ThemePalette, onActivate: @escaping () -> Void) {
        iconView.image = UIImage(systemName: Self.iconName(for: entry))
        iconView.tintColor = Self.iconColor(for: entry, palette: palette)
        summaryLabel.attributedText = Self.summaryText(
            entry.summary,
            matchPositions: entry.matchPositions,
            color: Self.textColor(for: entry, palette: palette),
            highlight: UIColor(palette.yellow)
        )

        compactionBadge.isHidden = !entry.isCompaction
        compactionBadge.font = SessionOutlineStyle.font(.caption2, bold: true)
        compactionBadge.textColor = UIColor(palette.orange)
        compactionBadge.backgroundColor = UIColor(palette.orange.opacity(0.18))

        let stats = entry.diffStats
        addedLabel.isHidden = (stats?.added ?? 0) <= 0
        addedLabel.text = stats.map { "+\($0.added)" }
        addedLabel.font = SessionOutlineStyle.font(.caption2, bold: true, monospaced: true)
        addedLabel.textColor = UIColor(palette.toolDiffAdded)
        removedLabel.isHidden = (stats?.removed ?? 0) <= 0
        removedLabel.text = stats.map { "-\($0.removed)" }
        removedLabel.font = SessionOutlineStyle.font(.caption2, bold: true, monospaced: true)
        removedLabel.textColor = UIColor(palette.toolDiffRemoved)

        let time = entry.timestamp?.formatted(date: .omitted, time: .shortened)
        timeLabel.isHidden = time == nil
        timeLabel.text = time
        timeLabel.font = SessionOutlineStyle.font(.caption2)
        timeLabel.textColor = UIColor(palette.comment)

        row.accessibilityIdentifier = "chat.outline.row.\(entry.id)"
        row.accessibilityLabel = Self.accessibilityLabel(for: entry, time: time)
        row.onActivate = onActivate

        let pressed = UIColor(palette.bgHighlight)
        configurationUpdateHandler = { cell, state in
            var background = UIBackgroundConfiguration.listCell()
            background.backgroundColor = state.isHighlighted || state.isSelected ? pressed : .clear
            cell.backgroundConfiguration = background
        }
    }

    /// The summary with the current query's matches in bold yellow. Built
    /// from `matchPositions` every time a row is configured, so a reused or
    /// reconfigured row never keeps an earlier query's highlights.
    static func summaryText(
        _ summary: String,
        matchPositions: [Int],
        color: UIColor,
        highlight: UIColor
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(string: summary, attributes: [
            .font: SessionOutlineStyle.font(.caption1),
            .foregroundColor: color,
        ])
        let bold = SessionOutlineStyle.font(.caption1, bold: true)
        for range in OutlineHighlight.ranges(in: summary, scalarPositions: matchPositions) {
            text.addAttributes([.font: bold, .foregroundColor: highlight], range: range)
        }
        return text
    }

    private static func accessibilityLabel(for entry: OutlineEntry, time: String?) -> String {
        var parts = [entry.summary]
        if entry.isCompaction { parts.append("Compaction") }
        if let stats = entry.diffStats {
            if stats.added > 0 { parts.append("+\(stats.added)") }
            if stats.removed > 0 { parts.append("-\(stats.removed)") }
        }
        if let time { parts.append(time) }
        return parts.joined(separator: ", ")
    }

    private static func iconName(for entry: OutlineEntry) -> String {
        if entry.isCompaction {
            return "arrow.trianglehead.2.clockwise.rotate.90"
        }
        switch entry.kind {
        case .user: return "person.fill"
        case .assistant: return entry.isAudioClip ? "waveform" : "cpu"
        case .thinking: return "sparkle"
        case .tool: return entry.glyph ?? "wrench"
        case .system: return "info.circle"
        case .compaction: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .custom: return "info.circle.fill"
        case .error: return "exclamationmark.triangle"
        }
    }

    private static func iconColor(for entry: OutlineEntry, palette: ThemePalette) -> UIColor {
        if entry.isCompaction {
            return UIColor(palette.orange)
        }
        switch entry.kind {
        case .user: return UIColor(palette.blue)
        case .assistant, .thinking: return UIColor(palette.purple)
        case .tool: return UIColor(entry.isError ? palette.red : palette.cyan)
        case .system: return UIColor(palette.comment)
        case .compaction: return UIColor(palette.orange)
        case .custom: return UIColor(palette.blue)
        case .error: return UIColor(palette.red)
        }
    }

    private static func textColor(for entry: OutlineEntry, palette: ThemePalette) -> UIColor {
        if entry.isCompaction {
            return UIColor(palette.fg)
        }
        switch entry.kind {
        case .user, .compaction: return UIColor(palette.fg)
        case .assistant, .tool: return UIColor(palette.fgDim)
        default: return UIColor(palette.comment)
        }
    }
}

extension InsetLabel {
    /// A capsule badge (Compaction, the model picker's current pill).
    static func outlineBadge() -> InsetLabel {
        InsetLabel(insets: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6), capsule: true)
    }
}

// MARK: - Tree row

final class SessionOutlineTreeCell: UICollectionViewListCell {
    struct State {
        let displayNode: SessionTreeDisplayNode
        let isCollapsible: Bool
        let isCollapsed: Bool
        let isDisabled: Bool
        let isLoading: Bool
    }

    let row = SessionOutlineRowElement()
    let toggleButton = UIButton(type: .system)
    private let connector = SessionOutlineTreeConnectorView()
    private let textLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        textLabel.numberOfLines = 2
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.hidesWhenStopped = true
        toggleButton.setContentHuggingPriority(.required, for: .horizontal)
        toggleButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(textStyle: .caption2).applying(UIImage.SymbolConfiguration(weight: .semibold)),
            forImageIn: .normal
        )
        toggleButton.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .primaryActionTriggered)

        let rowStack = UIStackView(arrangedSubviews: [textLabel, spinner])
        rowStack.alignment = .top
        rowStack.spacing = 6
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: row.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            rowStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            rowStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
        ])

        let stack = UIStackView(arrangedSubviews: [toggleButton, row])
        stack.alignment = .top
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        connector.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(connector)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            // Full height, so connectors run unbroken from row to row.
            connector.topAnchor.constraint(equalTo: contentView.topAnchor),
            connector.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            connector.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: connector.trailingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
        ])
        isAccessibilityElement = false
        accessibilityElements = [toggleButton, row]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        _ state: State,
        palette: ThemePalette,
        onActivate: @escaping () -> Void,
        onToggle: @escaping () -> Void
    ) {
        let node = state.displayNode.node
        connector.displayNode = state.displayNode
        connector.lineColor = UIColor(palette.comment.opacity(0.38))

        toggleButton.isHidden = !state.isCollapsible
        toggleButton.isEnabled = !state.isDisabled
        toggleButton.setImage(UIImage(systemName: state.isCollapsed ? "plus.square" : "minus.square"), for: .normal)
        toggleButton.tintColor = UIColor(palette.comment)
        toggleButton.accessibilityLabel = state.isCollapsed ? "Expand branch" : "Collapse branch"
        // A reused cell must not keep a hidden toggle in VoiceOver or its
        // previous node's identifier.
        toggleButton.accessibilityIdentifier = state.isCollapsible ? "tree-toggle-\(node.id)" : nil
        accessibilityElements = state.isCollapsible ? [toggleButton, row] : [row]
        self.onToggle = state.isCollapsible ? onToggle : nil

        let text = Self.rowText(node, palette: palette)
        textLabel.attributedText = text
        if state.isLoading {
            spinner.color = UIColor(palette.blue)
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }

        row.accessibilityIdentifier = "chat.outline.tree.row.\(node.id)"
        row.accessibilityLabel = text.string
        row.accessibilityValue = state.isLoading ? "Navigating" : nil
        row.accessibilityTraits = state.isDisabled ? [.button, .notEnabled] : .button
        row.onActivate = onActivate

        let pressed = UIColor(palette.bgHighlight)
        configurationUpdateHandler = { cell, cellState in
            var background = UIBackgroundConfiguration.listCell()
            background.backgroundColor = cellState.isHighlighted || cellState.isSelected ? pressed : .clear
            cell.backgroundConfiguration = background
        }
    }

    /// Leaf-path dot, label, role prefix, and preview as one wrapping text.
    private static func rowText(_ node: SessionTreeNodeSnapshot, palette: ThemePalette) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func append(_ string: String, font: UIFont, color: UIColor) {
            if text.length > 0 {
                text.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            text.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        if node.isLeafPath {
            append("•", font: SessionOutlineStyle.font(.caption1, bold: true), color: UIColor(palette.orange))
        }
        if let label = SessionOutlineTree.displayLabel(for: node) {
            append("[\(label)]", font: SessionOutlineStyle.font(.caption2, monospaced: true), color: UIColor(palette.orange))
        }
        let prefix = SessionOutlineTree.rolePrefix(for: node)
        if !prefix.isEmpty {
            append(prefix, font: SessionOutlineStyle.font(.caption1, bold: true), color: roleColor(for: node, palette: palette))
        }
        let primary = SessionOutlineTree.primaryText(for: node)
        if !primary.isEmpty {
            append(primary, font: SessionOutlineStyle.font(.caption1), color: UIColor(palette.fg))
        }
        return text
    }

    private static func roleColor(for node: SessionTreeNodeSnapshot, palette: ThemePalette) -> UIColor {
        if node.type == "message" {
            switch node.role {
            case "user": return UIColor(palette.blue)
            case "assistant": return UIColor(palette.purple)
            default: return UIColor(palette.comment)
            }
        }
        switch node.type {
        case "branch_summary": return UIColor(palette.blue)
        case "compaction": return UIColor(palette.orange)
        default: return UIColor(palette.comment)
        }
    }
}

/// Branch gutters and the elbow into this row (`SessionTreeDisplayLayout`).
final class SessionOutlineTreeConnectorView: UIView {
    static let levelWidth: CGFloat = 18

    var displayNode: SessionTreeDisplayNode? {
        didSet {
            widthConstraint.constant = displayNode.map(Self.width(for:)) ?? 6
            setNeedsDisplay()
        }
    }
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 6)
    var lineColor: UIColor = .separator {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
        widthConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    static func width(for node: SessionTreeDisplayNode) -> CGFloat {
        guard node.displayDepth > 0 else { return node.connectorDisplayed ? levelWidth : 6 }
        return CGFloat(node.displayDepth) * levelWidth + 2
    }

    private static func xPosition(for level: Int) -> CGFloat {
        CGFloat(level) * levelWidth + levelWidth * 0.22
    }

    override func draw(_ rect: CGRect) {
        guard let displayNode else { return }
        let height = bounds.height
        let centerY = height * 0.5
        let path = UIBezierPath()
        for gutter in displayNode.gutters where gutter.show {
            let x = Self.xPosition(for: gutter.position)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: height))
        }
        if displayNode.connectorDisplayed {
            let branchX = Self.xPosition(for: max(0, displayNode.displayDepth - 1))
            path.move(to: CGPoint(x: branchX, y: 0))
            path.addLine(to: CGPoint(x: branchX, y: displayNode.isLast ? centerY : height))
            path.move(to: CGPoint(x: branchX, y: centerY))
            path.addLine(to: CGPoint(x: branchX + Self.levelWidth * 0.55, y: centerY))
        }
        path.lineWidth = 1
        path.lineCapStyle = .round
        lineColor.setStroke()
        path.stroke()
    }
}

// MARK: - Chrome

/// Filter chips, an optional spinner, and the row count.
final class SessionOutlineFilterBar: UIView {
    var onSelect: ((Int) -> Void)?

    private let chipStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let countLabel = UILabel()
    private var chips: [UIButton] = []

    init(titles: [String]) {
        super.init(frame: .zero)
        chipStack.spacing = 8
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(chipStack)
        for (index, title) in titles.enumerated() {
            let chip = UIButton(configuration: .plain())
            chip.configuration?.title = title
            chip.configuration?.cornerStyle = .capsule
            chip.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
            chip.configuration?.titleLineBreakMode = .byClipping
            chip.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = SessionOutlineStyle.font(.caption1, bold: true)
                return attributes
            }
            chip.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .primaryActionTriggered)
            chips.append(chip)
            chipStack.addArrangedSubview(chip)
        }
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        countLabel.font = SessionOutlineStyle.font(.caption2)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [scroll, spinner, countLabel])
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chipStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 1),
            chipStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -1),
            chipStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            chipStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            scroll.frameLayoutGuide.heightAnchor.constraint(equalTo: chipStack.heightAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(selected: Int, isLoading: Bool, count: Int, palette: ThemePalette) {
        for (index, chip) in chips.enumerated() {
            let isSelected = index == selected
            chip.configuration?.background.backgroundColor = UIColor(isSelected ? palette.blue : palette.bgHighlight)
            chip.configuration?.baseForegroundColor = UIColor(
                isSelected ? ThemeColorContrast.foreground(for: palette.blue) : palette.fgDim
            )
            chip.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
        if isLoading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        countLabel.text = "\(count) items"
        countLabel.textColor = UIColor(palette.comment)
    }
}

/// An orange warning card (outline or tree errors).
final class SessionOutlineBannerView: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
    private let label = UILabel()
    private let card = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = SessionOutlineStyle.font(.caption1)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.spacing = 8
        stack.alignment = .top
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows `message`, or hides the banner for nil or blank text.
    func show(_ message: String?, palette: ThemePalette) {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        isHidden = text.isEmpty
        label.text = message
        label.textColor = UIColor(palette.fg)
        icon.tintColor = UIColor(palette.orange)
        card.backgroundColor = UIColor(palette.orange.opacity(0.12))
        card.layer.borderColor = UIColor(palette.orange.opacity(0.35)).cgColor
    }
}
