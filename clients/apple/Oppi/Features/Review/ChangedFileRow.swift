import UIKit

/// A row-wide plain button around custom content (`.buttonStyle(.plain)`):
/// the content takes the whole row's tap, dims while pressed, and sizes the
/// button. A capsule rounds its ends at every height. The commit's file rows
/// and the git context bar's rows and pills.
@MainActor
final class PlainRowButton: UIButton {
    var isCapsule = false {
        didSet { setNeedsLayout() }
    }
    private weak var content: UIView?

    /// `content` pinned to the button's edges; `action` runs on a tap.
    convenience init(wrapping content: UIView, action: @escaping () -> Void) {
        self.init(frame: .zero)
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        self.content = content
        addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    override var isHighlighted: Bool {
        didSet { content?.alpha = isHighlighted ? 0.6 : 1 }
    }

    /// The content sizes the button; an empty button's own minimum size
    /// would pad every row.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard isCapsule else { return }
        layer.cornerCurve = .continuous
        layer.cornerRadius = bounds.height / 2
    }
}

/// A changed file's row, in the commit's file list and the git context bar:
/// the caller's leading views, the file-type icon, the path (middle
/// truncated), then badges around the line counts and a chevron.
@MainActor
enum ChangedFileRow {
    struct Fonts {
        let path: UIFont
        let count: UIFont
        let chevron: UIFont
    }

    /// The row and the words VoiceOver reads for it (path and counts).
    static func content(
        path: String,
        added: Int?,
        removed: Int?,
        leading: [UIView] = [],
        beforeCounts: [UIView] = [],
        afterCounts: [UIView] = [],
        showsChevron: Bool,
        fonts: Fonts,
        verticalInset: CGFloat,
        palette: ThemePalette
    ) -> (stack: UIStackView, labelParts: [String]) {
        let icon = FileIcon.forPath(path)
        let iconView = UIImageView(image: icon.uiImage(pointSize: 10, weight: .semibold))
        iconView.tintColor = UIColor(icon.tint.snapshotColor)
        iconView.contentMode = icon.isAssetImage ? .scaleAspectFit : .center
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
        let pathLabel = label(path.shortenedPath, font: fonts.path, color: UIColor(palette.fg))
        pathLabel.lineBreakMode = .byTruncatingMiddle
        // The path takes the row's free width; everything else hugs.
        pathLabel.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var items = leading + [iconView, pathLabel] + beforeCounts
        var labelParts = [path.shortenedPath]
        if let added, added > 0 {
            items.append(label("+\(added)", font: fonts.count, color: UIColor(palette.toolDiffAdded)))
            labelParts.append("+\(added)")
        }
        if let removed, removed > 0 {
            items.append(label("-\(removed)", font: fonts.count, color: UIColor(palette.toolDiffRemoved)))
            labelParts.append("-\(removed)")
        }
        items += afterCounts
        if showsChevron {
            items.append(chevron(font: fonts.chevron, palette: palette))
        }
        for item in items where item !== pathLabel {
            item.setContentHuggingPriority(.required, for: .horizontal)
            item.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let stack = UIStackView(arrangedSubviews: items)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        // Spacer(minLength: 4) between the path and what trails it.
        stack.setCustomSpacing(16, after: pathLabel)
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: verticalInset, leading: 12, bottom: verticalInset, trailing: 12
        )
        return (stack, labelParts)
    }

    /// The row's trailing disclosure chevron.
    static func chevron(font: UIFont, palette: ThemePalette) -> UIImageView {
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font)
        chevron.tintColor = UIColor(palette.comment).withAlphaComponent(0.5)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        return chevron
    }

    private static func label(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        return label
    }
}
