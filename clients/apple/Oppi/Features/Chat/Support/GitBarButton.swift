import UIKit

/// The Git logo with the changed-file count at its top trailing corner: the
/// chat top bar's Git button and the workspace screen's, one look in both
/// bars. The count is plain text in the bar's foreground color, no fill: the
/// bar's glass draws its content's colors monochrome, so a colored capsule
/// reads as an empty grey dot.
///
/// The logo stays where every bar icon sits (centered in its slot: the chat
/// bar's 36 pt side, or `systemItemSlot` among system items). The count starts just past the logo and grows away from it; a count wider
/// than the room beside the logo ("99+") widens the button by the difference,
/// so it pushes the next button over instead of running into it.
@MainActor
final class GitBarButton: UIButton {
    /// A chat bar button's side.
    static let side: CGFloat = 36
    /// The slot among a system bar's symbol items. The system spaces its own
    /// items' symbols about 59 pt apart and keeps them about 15 pt in from the
    /// glass group's edge, but places a custom view flush, at its fitting
    /// size. About 11 pt either side of the logo puts it on the same pitch
    /// (measured on iOS 27.1 iPhone).
    static let systemItemSlot: CGFloat = 42

    private let textStyle: UIFont.TextStyle
    /// The button's width without a badge, the logo centered in it.
    private let slot: CGFloat
    private let badge = InsetLabel(insets: .zero, capsule: false)
    private lazy var badgeLeading = badge.leadingAnchor.constraint(equalTo: leadingAnchor)
    private lazy var width = widthAnchor.constraint(equalToConstant: slot)

    init(textStyle: UIFont.TextStyle, slot: CGFloat = GitBarButton.side, action: @escaping () -> Void) {
        self.textStyle = textStyle
        self.slot = slot
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.image = GitLogoImage.image(textStyle: textStyle)
        configuration.contentInsets = .zero
        self.configuration = configuration
        addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        translatesAutoresizingMaskIntoConstraints = false

        badge.font = UIFont.scaled(.caption2, .semibold, monospacedDigits: true)
        badge.textAlignment = .center
        badge.isHidden = true
        badge.isUserInteractionEnabled = false
        badge.isAccessibilityElement = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: Self.side),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            badgeLeading,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows `changedFiles` (none at 0, "99+" past 99) in `color`, with the
    /// logo at the current text size.
    func apply(changedFiles: Int, color: UIColor) {
        configuration?.image = GitLogoImage.image(textStyle: textStyle)
        badge.isHidden = changedFiles <= 0
        badge.text = changedFiles > 99 ? "99+" : "\(changedFiles)"
        badge.textColor = color
        layOutBadge()
    }

    private func layOutBadge() {
        let logoWidth = configuration?.image?.size.width ?? 20
        let badgeStart = slot / 2 + logoWidth / 2
        let badgeWidth = badge.isHidden ? 0 : ceil(badge.intrinsicContentSize.width)
        let extra = max(0, badgeStart + badgeWidth - slot)
        badgeLeading.constant = badgeStart
        width.constant = slot + extra
        // The slot is content insets, not only the width: a system bar sizes
        // a custom view to its fitting size and drops the width constraint.
        let pad = max(0, (slot - logoWidth) / 2)
        let insets = NSDirectionalEdgeInsets(top: 0, leading: pad, bottom: 0, trailing: pad + extra)
        if configuration?.contentInsets != insets {
            configuration?.contentInsets = insets
        }
    }
}
