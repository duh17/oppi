import UIKit

// UIKit pieces of Quick Session's chrome: the destination pills above the
// composer (their icons are `IconChoiceUIView`) and the launch error panel.

// MARK: - Pill

/// A glass capsule above (or, at accessibility text sizes, below) the
/// composer: an icon, a caption title, and a trailing chevron or close mark.
/// The capsule is 21 pt tall and centered in a 44 pt button, which is the
/// touch target. A `UIButton`, so touch, VoiceOver, and Full Keyboard Access
/// all send its primary action.
@MainActor
final class QuickSessionPillButton: UIButton {
    struct Content {
        var icon: IconChoiceUIView.Content?
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
    private let iconView: IconChoiceUIView
    private let captionLabel = UILabel()
    private let detailLabel = UILabel()
    private let trailingView = UIImageView()

    /// `iconFrame` is the icon's square; a symbol-only pill keeps its glyph's own size.
    init(iconSize: CGFloat = 12, iconFrame: CGFloat = 16, minimumWidth: CGFloat = 0) {
        iconView = IconChoiceUIView(size: iconSize, frameSize: iconFrame)
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
        captionLabel.font = UIFont.scaled(.caption2, .semibold)
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = UIFont.scaled(.caption2, .semibold)
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
            trailingView.image = UIImage.scaledSymbol(
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
        iconView.image = UIImage.scaledSymbol("exclamationmark.triangle.fill", style: .caption1, weight: .regular, color: colors.red)
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
