import UIKit

/// Quick Session's destination bar at regular width, above the composer: three
/// Liquid Glass groups of 44 pt controls with body-size labels.
///
///     Where: workspace, worktree   Who: Agent   How: Durable, Incognito
///
/// The controls are `QuickSessionPillButton`s in their `.bar` style. They stay
/// plain buttons that present the same popovers as the compact pills do, so
/// every accessibility identifier, picker, and state the pills have is kept.
/// Model and thinking are not here: they sit at the composer's bottom right,
/// as on iPhone.
///
/// A group is a glass capsule of its own, so it needs no help to read as one
/// control; a group with no visible control hides itself (`refreshGroups`).
///
/// The bar never scrolls or overflows. When the width runs out, a title gives
/// up room in this order, by its label's compression resistance:
///
/// 1. the reason after a fixed Classic engine,
/// 2. the Agent's name,
/// 3. the worktree's name,
/// 4. the workspace's name, last.
///
/// Each title keeps at least `minimumTitleWidth`, so a name never shrinks to a
/// single letter. (The composer's own row follows the same idea for model and
/// thinking: `ComposerPopUpFit`.)
@MainActor
final class QuickSessionWideBar: UIView {
    static let minimumTitleWidth: CGFloat = 44

    let workspace = QuickSessionPillButton(style: .bar)
    let worktree = QuickSessionPillButton(style: .bar)
    let agent = QuickSessionPillButton(style: .bar)
    let engine = QuickSessionPillButton(style: .bar)
    let incognito = QuickSessionPillButton(style: .bar, minimumWidth: ComposerInputMetrics.controlDiameter)

    private let whereGroup = QuickSessionBarGroup()
    private let whoGroup = QuickSessionBarGroup()
    private let howGroup = QuickSessionBarGroup()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Longest-lived title last: a lower resistance gives up room first.
        engine.setDetailCompressionResistance(UILayoutPriority(251))
        agent.setTitleCompressionResistance(UILayoutPriority(252))
        worktree.setTitleCompressionResistance(UILayoutPriority(253))
        workspace.setTitleCompressionResistance(UILayoutPriority(254))
        for button in [workspace, worktree, agent] {
            button.setMinimumTitleWidth(Self.minimumTitleWidth)
        }

        whereGroup.setButtons([workspace, worktree])
        whoGroup.setButtons([agent])
        howGroup.setButtons([engine, incognito])

        let firstGap = UIView()
        let secondGap = UIView()
        for gap in [firstGap, secondGap] {
            gap.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
            gap.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
        }

        row.axis = .horizontal
        row.alignment = .center
        row.addArrangedSubview(whereGroup)
        row.addArrangedSubview(firstGap)
        row.addArrangedSubview(whoGroup)
        row.addArrangedSubview(secondGap)
        row.addArrangedSubview(howGroup)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            // The Who group sits midway between the other two (the gaps share a superview now).
            firstGap.widthAnchor.constraint(equalTo: secondGap.widthAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Hides a group whose controls are all hidden (no worktree and no
    /// engine or incognito choice leaves only Where and Who).
    func refreshGroups() {
        for group in [whereGroup, whoGroup, howGroup] { group.refreshVisibility() }
    }
}

/// One Liquid Glass capsule holding a row of bar buttons.
@MainActor
private final class QuickSessionBarGroup: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.layer.cornerRadius = glass.bounds.height / 2
        glass.layer.cornerCurve = .continuous
    }

    func setButtons(_ buttons: [UIView]) {
        for button in buttons { stack.addArrangedSubview(button) }
    }

    func refreshVisibility() {
        setHiddenIfChanged(stack.arrangedSubviews.allSatisfy(\.isHidden))
    }
}
