import UIKit

/// Quick Session's destination bar at regular width, above the composer: two
/// Liquid Glass groups of 44 pt controls with body-size labels, one at each end.
///
///     Where: workspace, worktree                How: Durable, Incognito
///
/// The controls are `QuickSessionPillButton`s in their `.bar` style. They stay
/// plain buttons that present the same popovers as the compact pills do, so
/// every accessibility identifier, picker, and state the pills have is kept.
/// Who runs the launch (Agent, model, thinking) is not here: it sits at the
/// composer's bottom right.
///
/// A group is a glass capsule of its own, so it needs no help to read as one
/// control; a group with no visible control hides itself (`refreshGroups`).
///
/// The bar never scrolls or overflows. When the width runs out, a title gives
/// up room in this order, by its label's compression resistance:
///
/// 1. the reason after a fixed Classic engine,
/// 2. the worktree's name,
/// 3. the workspace's name, last.
///
/// Each name keeps at least `minimumTitleWidth`, so it never shrinks to a
/// single letter. (The composer's row follows the same idea for Agent, model,
/// and thinking: `ComposerPopUpFit`.)
@MainActor
final class QuickSessionWideBar: UIView {
    static let minimumTitleWidth: CGFloat = 44

    let workspace = QuickSessionPillButton(style: .bar)
    let worktree = QuickSessionPillButton(style: .bar)
    let engine = QuickSessionPillButton(style: .bar)
    let incognito = QuickSessionPillButton(style: .bar, minimumWidth: ComposerInputMetrics.controlDiameter)

    private let whereGroup = QuickSessionBarGroup()
    private let howGroup = QuickSessionBarGroup()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Longest-lived title last: a lower resistance gives up room first.
        // "Classic" itself is one short fixed word and outlasts every name.
        engine.setDetailCompressionResistance(UILayoutPriority(251))
        engine.setTitleCompressionResistance(UILayoutPriority(255))
        worktree.setTitleCompressionResistance(UILayoutPriority(252))
        workspace.setTitleCompressionResistance(UILayoutPriority(253))
        for button in [workspace, worktree] {
            button.setMinimumTitleWidth(Self.minimumTitleWidth)
        }

        whereGroup.setButtons([workspace, worktree])
        howGroup.setButtons([engine, incognito])

        let gap = UIView()
        gap.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
        gap.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true

        row.axis = .horizontal
        row.alignment = .center
        row.addArrangedSubview(whereGroup)
        row.addArrangedSubview(gap)
        row.addArrangedSubview(howGroup)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Hides a group whose controls are all hidden (no engine or incognito
    /// choice leaves only Where).
    func refreshGroups() {
        for group in [whereGroup, howGroup] { group.refreshVisibility() }
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
