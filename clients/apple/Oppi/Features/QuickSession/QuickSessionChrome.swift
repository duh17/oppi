import UIKit

// UIKit pieces of Quick Session's chrome: the destination pills above the
// composer, the icon they and the pickers show, and the launch error panel.

extension UIFont {
    /// The text style's font at `weight`, scaled for Dynamic Type.
    static func quickSessionFont(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        let base = preferredFont(forTextStyle: style)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }
}

/// An SF Symbol at a text style's size and weight, in `color`.
@MainActor
func quickSessionSymbol(
    _ name: String,
    style: UIFont.TextStyle,
    weight: UIImage.SymbolWeight,
    color: UIColor
) -> UIImage? {
    let configuration = UIImage.SymbolConfiguration(
        font: UIFont.preferredFont(forTextStyle: style),
        scale: .default
    ).applying(UIImage.SymbolConfiguration(weight: weight))
    return UIImage(systemName: name, withConfiguration: configuration)?
        .withTintColor(color, renderingMode: .alwaysOriginal)
}

// MARK: - Icon

/// A saved workspace or Agent icon (`IconChoiceView` in UIKit): an SF Symbol in
/// the theme blue, an emoji, or a Genmoji the server stores, which loads
/// through the server's icon cache and shows the default symbol until it
/// arrives. A sandbox workspace adds the lock mark (`WorkspaceRuntimeIcon`).
/// Also the Pi mark, and plain symbols for the other pills.
@MainActor
final class QuickSessionIconView: UIView {
    enum Content: Equatable {
        case choice(IconChoice?, purpose: Purpose, sandbox: Bool)
        case piAvatar
        case symbol(String, color: UIColor, style: UIFont.TextStyle, weight: UIImage.SymbolWeight)

        enum Purpose: Equatable {
            case agent
            case workspace

            var defaultSymbolName: String {
                switch self {
                case .agent: "person.crop.circle"
                case .workspace: "square.grid.2x2"
                }
            }
        }
    }

    private let size: CGFloat
    private let frameSize: CGFloat
    private let imageView = UIImageView()
    private let textLabel = UILabel()
    private let sandboxMark = UIImageView()
    private var content: Content?
    private var colors = ComposerThemeColors.placeholder
    private weak var assetCache: IconAssetCache?
    private var loadTask: Task<Void, Never>?
    private var loadedAssetId: String?

    init(size: CGFloat, frameSize: CGFloat) {
        self.size = size
        self.frameSize = frameSize
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        imageView.contentMode = .center
        textLabel.textAlignment = .center
        sandboxMark.contentMode = .center
        for view in [imageView, textLabel] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        let markSize = max(11, frameSize * 0.34)
        sandboxMark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sandboxMark)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: frameSize),
            heightAnchor.constraint(equalToConstant: frameSize),
            sandboxMark.widthAnchor.constraint(equalToConstant: markSize),
            sandboxMark.heightAnchor.constraint(equalToConstant: markSize),
            sandboxMark.trailingAnchor.constraint(equalTo: trailingAnchor, constant: frameSize * 0.05),
            sandboxMark.bottomAnchor.constraint(equalTo: bottomAnchor, constant: frameSize * 0.05),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The size the icon's content takes in its frame, following Dynamic Type
    /// the way `IconChoiceView` does.
    private var contentSize: CGFloat {
        AgentIconSizingPolicy.contentSize(
            baseSize: size,
            scaledSize: UIFontMetrics(forTextStyle: .body).scaledValue(for: size),
            frameSize: frameSize
        )
    }

    func apply(_ content: Content, colors: ComposerThemeColors, assetCache: IconAssetCache? = nil) {
        let changed = content != self.content || assetCache !== self.assetCache
        self.content = content
        self.colors = colors
        self.assetCache = assetCache
        render()
        if changed { loadGenmojiIfNeeded() }
    }

    private func render() {
        guard let content else { return }
        textLabel.isHidden = true
        imageView.isHidden = false
        imageView.contentMode = .center
        sandboxMark.isHidden = true
        switch content {
        case .piAvatar:
            imageView.contentMode = .scaleAspectFit
            imageView.image = PiAvatarRenderer.render(size: frameSize * 2)
        case .symbol(let name, let color, let style, let weight):
            imageView.image = quickSessionSymbol(name, style: style, weight: weight, color: color)
        case .choice(let choice, let purpose, let sandbox):
            sandboxMark.isHidden = !sandbox
            if sandbox { sandboxMark.image = sandboxImage() }
            switch AgentIconContent.resolve(choice) {
            case .symbol(let name):
                imageView.image = symbol(name)
            case .text(let emoji):
                imageView.isHidden = true
                textLabel.isHidden = false
                textLabel.text = emoji
                textLabel.font = .systemFont(ofSize: contentSize)
            case .genmoji(let assetId, _):
                if loadedAssetId == assetId, let image = imageView.image, image.isSymbolImage == false {
                    imageView.contentMode = .scaleAspectFit
                } else {
                    imageView.image = symbol(purpose.defaultSymbolName)
                }
            case .fallback:
                imageView.image = symbol(purpose.defaultSymbolName)
            }
        }
    }

    private func symbol(_ name: String) -> UIImage? {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: contentSize)
        )?.withTintColor(colors.blue, renderingMode: .alwaysOriginal)
    }

    private func loadGenmojiIfNeeded() {
        loadTask?.cancel()
        loadTask = nil
        guard case .choice(let choice, _, _) = content,
              case .genmoji(let assetId, _) = AgentIconContent.resolve(choice),
              let assetCache else {
            loadedAssetId = nil
            return
        }
        guard loadedAssetId != assetId else { return }
        loadedAssetId = nil
        let renderSize = contentSize * 2
        loadTask = Task { [weak self] in
            guard let image = try? await assetCache.image(assetId: assetId, size: renderSize),
                  !Task.isCancelled, let self else { return }
            self.loadedAssetId = assetId
            self.imageView.contentMode = .scaleAspectFit
            self.imageView.image = image
        }
    }

    private func sandboxImage() -> UIImage {
        let markSize = max(11, frameSize * 0.34)
        let colors = colors
        return UIGraphicsImageRenderer(size: CGSize(width: markSize, height: markSize)).image { _ in
            let rect = CGRect(x: 0, y: 0, width: markSize, height: markSize)
            colors.orange.setFill()
            UIBezierPath(ovalIn: rect).fill()
            colors.bg.setStroke()
            let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            let lock = UIImage(
                systemName: "lock.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: markSize * 0.52, weight: .bold)
            )?.withTintColor(colors.bg, renderingMode: .alwaysOriginal)
            let lockSize = lock?.size ?? .zero
            lock?.draw(at: CGPoint(x: (markSize - lockSize.width) / 2, y: (markSize - lockSize.height) / 2))
        }
    }
}

// MARK: - Pill

/// A glass capsule above (or, at accessibility text sizes, below) the
/// composer: an icon, a caption title, and a trailing chevron or close mark.
/// The capsule is 21 pt tall and centered in a 44 pt button, which is the
/// touch target. A `UIButton`, so touch, VoiceOver, and Full Keyboard Access
/// all send its primary action.
@MainActor
final class QuickSessionPillButton: UIButton {
    struct Content {
        var icon: QuickSessionIconView.Content?
        var iconAssetCache: IconAssetCache?
        var title: String?
        var titleColor: UIColor
        var detail: String?
        var trailingSymbol: String?
        var trailingColor: UIColor?
        /// A fill under the glass (the Incognito pill while on).
        var fill: UIColor?
    }

    private let capsule = UIView()
    private let glassView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let fillView = UIView()
    private let stack = UIStackView()
    private let iconView: QuickSessionIconView
    private let captionLabel = UILabel()
    private let detailLabel = UILabel()
    private let trailingView = UIImageView()

    /// `iconFrame` is the icon's square; a symbol-only pill keeps its glyph's own size.
    init(iconSize: CGFloat = 12, iconFrame: CGFloat = 16, minimumWidth: CGFloat = 0) {
        iconView = QuickSessionIconView(size: iconSize, frameSize: iconFrame)
        super.init(frame: .zero)
        capsule.isUserInteractionEnabled = false
        capsule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capsule)
        for view in [fillView, glassView] as [UIView] {
            view.isUserInteractionEnabled = false
            view.clipsToBounds = true
            view.translatesAutoresizingMaskIntoConstraints = false
            capsule.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: capsule.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: capsule.trailingAnchor),
                view.topAnchor.constraint(equalTo: capsule.topAnchor),
                view.bottomAnchor.constraint(equalTo: capsule.bottomAnchor),
            ])
        }
        captionLabel.font = .quickSessionFont(.caption2, weight: .semibold)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .quickSessionFont(.caption2, weight: .semibold)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        trailingView.contentMode = .center
        trailingView.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [iconView, captionLabel, detailLabel, trailingView] as [UIView] {
            stack.addArrangedSubview(view)
        }
        capsule.addSubview(stack)
        // The control is the capsule's size, at least 44 pt tall and
        // `minimumWidth` wide, with the capsule centered in it.
        let restingHeight = heightAnchor.constraint(equalToConstant: ComposerInputMetrics.controlDiameter)
        restingHeight.priority = .defaultLow
        let fitsCapsule = widthAnchor.constraint(equalTo: capsule.widthAnchor)
        fitsCapsule.priority = .defaultLow
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: ComposerInputMetrics.controlDiameter),
            restingHeight,
            widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth),
            fitsCapsule,
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
            capsule.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -2),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 17),
        ])
    }

    /// How strongly the title keeps its width when the row runs out of room.
    /// The workspace pill keeps its name; the others truncate first.
    func setTitleCompressionResistance(_ priority: UILayoutPriority) {
        captionLabel.setContentCompressionResistancePriority(priority, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Sized by the capsule's constraints, not the empty button's title.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = capsule.bounds.height / 2
        for view in [fillView, glassView] as [UIView] {
            view.layer.cornerRadius = radius
            view.layer.cornerCurve = .continuous
        }
    }

    /// False for a pill whose tap does nothing (the fixed Classic engine), so
    /// a press does not suggest it will.
    var dimsWhenPressed = true {
        didSet { updateAlpha() }
    }

    override var isHighlighted: Bool {
        didSet { updateAlpha() }
    }

    override var isEnabled: Bool {
        didSet { updateAlpha() }
    }

    private func updateAlpha() {
        alpha = isEnabled ? (isHighlighted && dimsWhenPressed ? 0.82 : 1) : 0.45
    }

    func apply(_ content: Content, colors: ComposerThemeColors) {
        if let icon = content.icon {
            iconView.isHidden = false
            iconView.apply(icon, colors: colors, assetCache: content.iconAssetCache)
        } else {
            iconView.isHidden = true
        }
        captionLabel.text = content.title
        captionLabel.textColor = content.titleColor
        captionLabel.isHidden = content.title == nil
        detailLabel.text = content.detail
        detailLabel.textColor = content.titleColor
        detailLabel.isHidden = content.detail == nil
        if let symbol = content.trailingSymbol {
            trailingView.isHidden = false
            trailingView.image = quickSessionSymbol(
                symbol,
                style: .caption2,
                weight: .semibold,
                color: content.trailingColor ?? colors.comment
            )
        } else {
            trailingView.isHidden = true
        }
        fillView.backgroundColor = content.fill ?? .clear
    }
}

// MARK: - Error panel

/// A launch that cannot go ahead: the reason, and the recovery it offers
/// (choose a compatible workspace, or edit the Agent).
@MainActor
final class QuickSessionErrorPanel: UIView {
    var onChooseWorkspace: (() -> Void)?
    var onOpenAgents: (() -> Void)?

    private let iconView = UIImageView()
    private let messageLabel = UILabel()
    private let chooseWorkspaceButton = UIButton(configuration: .bordered())
    private let openAgentsButton = UIButton(configuration: .bordered())

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        messageLabel.font = .preferredFont(forTextStyle: .caption1)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        let messageRow = UIStackView(arrangedSubviews: [iconView, messageLabel])
        messageRow.axis = .horizontal
        messageRow.alignment = .firstBaseline
        messageRow.spacing = 6
        messageRow.isAccessibilityElement = true
        messageRow.accessibilityTraits = .staticText

        chooseWorkspaceButton.configuration?.title = "Choose Compatible Workspace"
        chooseWorkspaceButton.addAction(UIAction { [weak self] _ in self?.onChooseWorkspace?() }, for: .primaryActionTriggered)
        openAgentsButton.configuration?.title = "Open Agents"
        openAgentsButton.addAction(UIAction { [weak self] _ in self?.onOpenAgents?() }, for: .primaryActionTriggered)
        for button in [chooseWorkspaceButton, openAgentsButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        let stack = UIStackView(arrangedSubviews: [messageRow, chooseWorkspaceButton, openAgentsButton])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        message: String,
        offersChooseWorkspace: Bool,
        offersOpenAgents: Bool,
        colors: ComposerThemeColors
    ) {
        backgroundColor = colors.red.withAlphaComponent(0.08)
        iconView.image = quickSessionSymbol("exclamationmark.triangle.fill", style: .caption1, weight: .regular, color: colors.red)
        messageLabel.text = message
        messageLabel.textColor = colors.red
        messageLabel.superview?.accessibilityLabel = message
        chooseWorkspaceButton.setHiddenIfChanged(!offersChooseWorkspace)
        openAgentsButton.setHiddenIfChanged(!offersOpenAgents)
        for button in [chooseWorkspaceButton, openAgentsButton] {
            button.configuration?.baseForegroundColor = colors.blue
        }
    }
}
