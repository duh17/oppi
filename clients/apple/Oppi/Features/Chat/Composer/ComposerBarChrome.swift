import UIKit

/// Snapshot of theme colors for UIKit composer chrome. Built from `ThemePalette`
/// on the SwiftUI seam so this file stays SwiftUI-free.
struct ComposerThemeColors {
    var bg: UIColor
    var bgDark: UIColor
    var bgHighlight: UIColor
    var fg: UIColor
    var fgDim: UIColor
    var comment: UIColor
    var blue: UIColor
    var cyan: UIColor
    var green: UIColor
    var orange: UIColor
    var purple: UIColor
    var red: UIColor
    var yellow: UIColor
    var scrim: UIColor
    var elevatedFill: UIColor
    var elevatedStroke: UIColor
    var floatingFill: UIColor
}

enum ComposerAttachmentButtonPlacement {
    case leading
    case trailing
}

/// Elevated composer capsule: glass + themed fill + hairline, 20pt continuous corners.
final class ComposerThemedPanelView: UIView {
    var cornerRadius: CGFloat = 20 {
        didSet { applyShape() }
    }

    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let fillView = UIView()
    let contentView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        glassView.clipsToBounds = true
        fillView.clipsToBounds = true
        contentView.backgroundColor = .clear
        addSubview(glassView)
        addSubview(fillView)
        addSubview(contentView)
        for view in [glassView, fillView, contentView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        applyShape()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(colors: ComposerThemeColors) {
        fillView.backgroundColor = colors.elevatedFill
        layer.borderColor = colors.elevatedStroke.cgColor
        layer.borderWidth = 0.5
    }

    /// Hide the UIKit glass when SwiftUI draws the capsule around the bar plus
    /// host-provided action pills (pills cannot overlay this view and still receive taps).
    func setChromeVisible(_ visible: Bool) {
        glassView.isHidden = !visible
        fillView.isHidden = !visible
        layer.borderWidth = visible ? 0.5 : 0
        clipsToBounds = visible
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyShape()
    }

    private func applyShape() {
        let radius = cornerRadius
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        clipsToBounds = true
        for view in [glassView, fillView, contentView] {
            view.layer.cornerRadius = radius
            view.layer.cornerCurve = .continuous
            view.clipsToBounds = true
        }
    }
}

/// Circle send / stop / ignore control with a 44pt hit target and press fade.
final class ComposerCircleActionButton: UIButton {
    var visualDiameter: CGFloat = ComposerInputMetrics.controlDiameter {
        didSet { invalidateIntrinsicContentSize() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configurationUpdateHandler = { [weak self] button in
            guard let self else { return }
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        CGSize(width: visualDiameter, height: visualDiameter)
    }

    func apply(
        systemImage: String,
        fill: UIColor,
        stroke: UIColor,
        foreground: UIColor,
        showsProgress: Bool,
        diameter: CGFloat = ComposerInputMetrics.controlDiameter,
        font: UIImage.SymbolWeight = .semibold
    ) {
        visualDiameter = diameter
        var config = UIButton.Configuration.plain()
        config.background.backgroundColor = fill
        config.background.strokeColor = stroke
        config.background.strokeWidth = 1
        config.background.cornerRadius = diameter / 2
        config.cornerStyle = .capsule
        config.baseForegroundColor = foreground
        config.contentInsets = .zero
        if showsProgress {
            config.image = nil
            config.showsActivityIndicator = true
        } else {
            config.showsActivityIndicator = false
            config.image = UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: diameter * 0.38, weight: font)
            )
        }
        configuration = config
        invalidateIntrinsicContentSize()
    }
}

/// Glass capsule used for attach and busy-mode, with a 44pt minimum hit region.
final class ComposerGlassPillButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        if configuration?.title == nil, configuration?.image != nil {
            return CGSize(width: 36, height: 23)
        }
        return super.intrinsicContentSize
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(
            dx: min(0, (bounds.width - 44) / 2),
            dy: min(0, (bounds.height - 44) / 2)
        ).contains(point)
    }

    func apply(
        title: String?,
        systemImage: String?,
        colors: ComposerThemeColors,
        chevron: Bool = false,
        symbolPointSize: CGFloat = 13,
        weight: UIImage.SymbolWeight = .semibold
    ) {
        var config = UIButton.Configuration.glass()
        config.cornerStyle = .capsule
        config.baseForegroundColor = colors.fg
        let vertical: CGFloat = title == nil ? 6 : 8
        config.contentInsets = NSDirectionalEdgeInsets(top: vertical, leading: 12, bottom: vertical, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)
            return outgoing
        }
        if let title {
            config.title = title
        }
        if let systemImage {
            config.image = UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: symbolPointSize, weight: weight)
            )
            if title != nil {
                config.imagePadding = 5
            }
        }
        if chevron {
            config.imagePlacement = .trailing
            config.image = UIImage(
                systemName: "chevron.up.chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            )
            config.imagePadding = 5
        }
        config.background.backgroundColor = colors.floatingFill
        configuration = config
        invalidateIntrinsicContentSize()
    }
}

/// Model / thinking / agent / workspace pill. Matches the SwiftUI `PillLabel`
/// (caption2, 11pt icon, trailing chevron) with a 44pt hit target.
final class ComposerToolbarPillButton: UIButton {
    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let stack = UIStackView()
    private let iconView = UIImageView()
    private let captionLabel = UILabel()
    private let chevronView = UIImageView()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits.insert(.button)
        glassView.clipsToBounds = true
        glassView.isUserInteractionEnabled = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.isUserInteractionEnabled = false
        iconView.contentMode = .scaleAspectFit
        captionLabel.font = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .medium
        )
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chevronConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        chevronView.image = UIImage(systemName: "chevron.down", withConfiguration: chevronConfig)
        chevronView.contentMode = .scaleAspectFit
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(captionLabel)
        stack.addArrangedSubview(chevronView)
        addSubview(glassView)
        addSubview(stack)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let iconW = iconView.widthAnchor.constraint(equalToConstant: 11)
        let iconH = iconView.heightAnchor.constraint(equalToConstant: 11)
        iconWidthConstraint = iconW
        iconHeightConstraint = iconH
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            iconW,
            iconH,
            chevronView.widthAnchor.constraint(equalToConstant: 9),
            chevronView.heightAnchor.constraint(equalToConstant: 11),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 17),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        glassView.layer.cornerRadius = bounds.height / 2
        glassView.layer.cornerCurve = .continuous
    }

    override var isHighlighted: Bool {
        didSet { alpha = isEnabled ? (isHighlighted ? 0.82 : 1) : 0.45 }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? (isHighlighted ? 0.82 : 1) : 0.45 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(
            dx: min(0, (bounds.width - 44) / 2),
            dy: min(0, (bounds.height - 44) / 2)
        ).contains(point)
    }

    func apply(
        title: String,
        icon: UIImage?,
        tint: UIColor,
        showsChevron: Bool,
        colors: ComposerThemeColors
    ) {
        captionLabel.text = title
        captionLabel.textColor = tint
        chevronView.tintColor = tint
        chevronView.isHidden = !showsChevron
        iconView.image = icon
        iconView.tintColor = tint
        iconView.isHidden = icon == nil
        iconWidthConstraint?.constant = icon == nil ? 0 : 11
        iconHeightConstraint?.constant = icon == nil ? 0 : 11
        glassView.backgroundColor = colors.floatingFill.withAlphaComponent(0.001)
    }
}

/// Review-comment template chip.
final class ComposerActionChipButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(title: String, systemImage: String?, colors: ComposerThemeColors) {
        var config = UIButton.Configuration.plain()
        config.cornerStyle = .capsule
        config.baseForegroundColor = colors.fg
        config.background.backgroundColor = colors.bgHighlight.withAlphaComponent(0.85)
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.title = title
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return outgoing
        }
        if let systemImage {
            config.image = UIImage(
                systemName: systemImage,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            )
            config.imagePadding = 6
        }
        configuration = config
    }
}

/// Trailing review-comment cancel control.
final class ComposerActionCancelButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        configurationUpdateHandler = { button in
            button.alpha = button.isEnabled ? (button.isHighlighted ? 0.82 : 1) : 0.45
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(colors: ComposerThemeColors) {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = colors.fgDim
        config.background.backgroundColor = colors.bgHighlight.withAlphaComponent(0.85)
        config.background.cornerRadius = 16
        config.contentInsets = .zero
        config.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        )
        configuration = config
        accessibilityLabel = "Cancel comment"
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 32, height: 32) }
}

enum ComposerColorContrast {
    static func contrastingForeground(on fill: UIColor, candidates: [UIColor]) -> UIColor {
        let fillLum = relativeLuminance(of: fill)
        return candidates.max { lhs, rhs in
            contrastRatio(relativeLuminance(of: lhs), fillLum)
                < contrastRatio(relativeLuminance(of: rhs), fillLum)
        } ?? candidates[0]
    }

    static func foreground(for fill: UIColor, fg: UIColor, bg: UIColor) -> UIColor {
        contrastingForeground(on: fill, candidates: [fg, bg])
    }

    private static func contrastRatio(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(of color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}

extension UIFont {
    fileprivate func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

/// Horizontal strip of pending image tiles and file pills.
final class ComposerAttachmentStripView: UIView {
    var onAnnotate: ((PendingAttachment) -> Void)?
    var onRemove: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var colors = ComposerThemeColors.placeholder
    private var allowsMutation = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentTileSize),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentTileSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        attachments: [PendingAttachment],
        colors: ComposerThemeColors,
        allowsMutation: Bool
    ) {
        self.colors = colors
        self.allowsMutation = allowsMutation
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for attachment in attachments {
            stack.addArrangedSubview(makeTile(for: attachment))
        }
        isHidden = attachments.isEmpty
    }

    private func makeTile(for attachment: PendingAttachment) -> UIView {
        if attachment.source == .image, let thumbnail = attachment.thumbnail {
            return makeImageTile(attachment: attachment, thumbnail: thumbnail)
        }
        return makeFilePill(name: attachment.displayName, id: attachment.id)
    }

    private func makeImageTile(attachment: PendingAttachment, thumbnail: UIImage) -> UIView {
        let tile = UIView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: ComposerShared.attachmentTileSize),
            tile.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentTileSize),
        ])
        tile.accessibilityIdentifier = "chat.attachment.image.\(attachment.id)"

        let imageButton = UIButton(type: .custom)
        imageButton.setImage(thumbnail, for: .normal)
        imageButton.imageView?.contentMode = .scaleAspectFill
        imageButton.clipsToBounds = true
        imageButton.layer.cornerRadius = 8
        imageButton.layer.cornerCurve = .continuous
        imageButton.layer.borderWidth = 1
        imageButton.layer.borderColor = colors.comment.withAlphaComponent(0.3).cgColor
        imageButton.isEnabled = allowsMutation
        imageButton.accessibilityLabel = "Annotate photo"
        imageButton.accessibilityIdentifier = "chat.attachment.image.annotate.\(attachment.id)"
        imageButton.addAction(UIAction { [weak self] _ in
            self?.onAnnotate?(attachment)
        }, for: .touchUpInside)
        imageButton.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(imageButton)
        NSLayoutConstraint.activate([
            imageButton.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            imageButton.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            imageButton.widthAnchor.constraint(equalToConstant: ComposerShared.attachmentThumbnailSize),
            imageButton.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentThumbnailSize),
        ])

        if allowsMutation {
            let remove = UIButton(type: .system)
            let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            remove.setImage(
                UIImage(systemName: "xmark.circle.fill", withConfiguration: config)?
                    .withRenderingMode(.alwaysOriginal)
                    .withTintColor(colors.fg, renderingMode: .alwaysOriginal),
                for: .normal
            )
            // Palette rendering: glyph on scrim, matching SwiftUI `.palette`.
            remove.setImage(Self.removeImage(fg: colors.fg, scrim: colors.scrim), for: .normal)
            remove.accessibilityLabel = "Remove photo"
            remove.addAction(UIAction { [weak self] _ in
                self?.onRemove?(attachment.id)
            }, for: .touchUpInside)
            remove.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(remove)
            NSLayoutConstraint.activate([
                remove.widthAnchor.constraint(equalToConstant: ComposerShared.attachmentRemoveHitSize),
                remove.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentRemoveHitSize),
                remove.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8),
                remove.topAnchor.constraint(equalTo: tile.topAnchor, constant: -8),
            ])
        }
        return tile
    }

    private func makeFilePill(name: String, id: String) -> UIView {
        let pill = ComposerAttachmentFilePillView()
        pill.apply(name: name, colors: colors, onRemove: allowsMutation ? { [weak self] in
            self?.onRemove?(id)
        } : nil)
        pill.accessibilityIdentifier = "chat.attachment.file.\(id)"
        return pill
    }

    private static func removeImage(fg: UIColor, scrim: UIColor) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: [fg, scrim]))
        return UIImage(systemName: "xmark.circle.fill", withConfiguration: config) ?? UIImage()
    }
}

final class ComposerFilePillStripView: UIView {
    var onRemove: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var colors = ComposerThemeColors.placeholder

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(pointers: [PendingFileReference], colors: ComposerThemeColors) {
        self.colors = colors
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for file in pointers {
            let pill = ComposerRepoFilePillView()
            pill.apply(file: file, colors: colors, onRemove: { [weak self] in
                self?.onRemove?(file.id)
            })
            stack.addArrangedSubview(pill)
        }
        isHidden = pointers.isEmpty
    }
}

final class ComposerRepoFilePillView: UIView {
    private let prefixLabel = UILabel()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let removeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        prefixLabel.font = UIFont.preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        nameLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.contentMode = .scaleAspectFit
        let xConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        removeButton.setImage(UIImage(systemName: "xmark", withConfiguration: xConfig), for: .normal)
        removeButton.accessibilityLabel = "Remove file"

        let stack = UIStackView(arrangedSubviews: [prefixLabel, iconView, nameLabel, removeButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            removeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            removeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(file: PendingFileReference, colors: ComposerThemeColors, onRemove: @escaping () -> Void) {
        let accent: UIColor
        switch file.kind {
        case .reviewFile: accent = colors.cyan
        case .workspaceFile: accent = colors.purple
        case .gitCommit: accent = colors.orange
        }
        prefixLabel.text = file.displayPrefix ?? {
            switch file.kind {
            case .reviewFile: return "Review"
            case .workspaceFile: return "Repo"
            case .gitCommit: return "Commit"
            }
        }()
        prefixLabel.textColor = accent
        nameLabel.text = file.displayName
        nameLabel.textColor = colors.fg
        let icon: FileIcon
        switch file.kind {
        case .gitCommit:
            icon = FileIcon(symbolName: "arrow.triangle.branch", tint: .orange)
        case .workspaceFile, .reviewFile:
            icon = file.isDirectory
                ? FileIcon(symbolName: "folder.fill", tint: .yellow)
                : FileIcon.forPath(file.path)
        }
        iconView.image = icon.uiImage(pointSize: 9, weight: .medium)
        removeButton.tintColor = colors.comment
        removeButton.removeTarget(nil, action: nil, for: .allEvents)
        removeButton.addAction(UIAction { _ in onRemove() }, for: .touchUpInside)
        backgroundColor = accent.withAlphaComponent(0.10)
        layer.borderColor = accent.withAlphaComponent(0.18).cgColor
    }
}

final class ComposerAttachmentFilePillView: UIView {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let removeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        nameLabel.lineBreakMode = .byTruncatingTail
        iconView.contentMode = .scaleAspectFit
        let xConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        removeButton.setImage(UIImage(systemName: "xmark", withConfiguration: xConfig), for: .normal)
        removeButton.accessibilityLabel = "Remove file"
        let stack = UIStackView(arrangedSubviews: [iconView, nameLabel, removeButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            removeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            removeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(name: String, colors: ComposerThemeColors, onRemove: (() -> Void)?) {
        nameLabel.text = name
        nameLabel.textColor = colors.fg
        iconView.image = FileIcon.forPath(name).uiImage(pointSize: 9, weight: .medium)
        removeButton.tintColor = colors.comment
        removeButton.isHidden = onRemove == nil
        removeButton.removeTarget(nil, action: nil, for: .allEvents)
        if let onRemove {
            removeButton.addAction(UIAction { _ in onRemove() }, for: .touchUpInside)
        }
        backgroundColor = colors.comment.withAlphaComponent(0.1)
    }
}

final class ComposerDictationFailureView: UIView {
    var onRetry: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "composer.dictationFailure"
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.text = "Dictation stopped"
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        messageLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.accessibilityIdentifier = "composer.dictationFailure.message"
        var retryConfig = UIButton.Configuration.plain()
        retryConfig.title = "Retry dictation"
        retryConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            return outgoing
        }
        retryConfig.contentInsets = .zero
        retryButton.configuration = retryConfig
        retryButton.accessibilityIdentifier = "composer.dictationFailure.retry"
        retryButton.accessibilityLabel = "Retry dictation"
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(bounds.width - 24, 280)
        titleLabel.preferredMaxLayoutWidth = width
        messageLabel.preferredMaxLayoutWidth = width
    }

    func apply(message: String, colors: ComposerThemeColors) {
        messageLabel.text = message
        titleLabel.textColor = colors.fg
        messageLabel.textColor = colors.fg
        retryButton.configuration?.baseForegroundColor = colors.fg
        backgroundColor = colors.bgDark
        titleLabel.preferredMaxLayoutWidth = 320
        messageLabel.preferredMaxLayoutWidth = 320
        isHidden = false
        invalidateIntrinsicContentSize()
    }
}

final class ComposerSendProgressView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let checkView = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        checkView.contentMode = .scaleAspectFit
        label.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
            weight: .regular
        )
        label.accessibilityIdentifier = "chat.sendProgress"
        let stack = UIStackView(arrangedSubviews: [spinner, checkView, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 12),
            checkView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(text: String?, isSending: Bool, colors: ComposerThemeColors) {
        guard let text else {
            isHidden = true
            spinner.stopAnimating()
            return
        }
        isHidden = false
        label.text = text
        label.textColor = colors.comment
        spinner.color = colors.comment
        if isSending {
            spinner.startAnimating()
            checkView.isHidden = true
            spinner.isHidden = false
        } else {
            spinner.stopAnimating()
            spinner.isHidden = true
            checkView.isHidden = false
            let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            checkView.image = UIImage(systemName: "checkmark.circle", withConfiguration: config)
            checkView.tintColor = colors.comment
        }
    }
}

final class ComposerForceStopButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel?.font = UIFont.preferredFont(forTextStyle: .caption1)
        contentHorizontalAlignment = .leading
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(isInFlight: Bool, colors: ComposerThemeColors) {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = colors.red
        config.contentInsets = .zero
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.preferredFont(forTextStyle: .caption1)
            return outgoing
        }
        if isInFlight {
            config.title = "Stopping…"
            config.showsActivityIndicator = true
        } else {
            config.title = "Force Stop Session"
            config.showsActivityIndicator = false
        }
        configuration = config
        isEnabled = !isInFlight
    }
}

extension ComposerThemeColors {
    /// Used only before the first theme apply; never shown as a designed look.
    static var placeholder: ComposerThemeColors {
        let gray = UIColor.gray
        return ComposerThemeColors(
            bg: gray,
            bgDark: gray,
            bgHighlight: gray,
            fg: .label,
            fgDim: .secondaryLabel,
            comment: .tertiaryLabel,
            blue: .systemBlue,
            cyan: .systemCyan,
            green: .systemGreen,
            orange: .systemOrange,
            purple: .systemPurple,
            red: .systemRed,
            yellow: .systemYellow,
            scrim: gray,
            elevatedFill: gray,
            elevatedStroke: gray,
            floatingFill: gray
        )
    }
}
