import UIKit

/// Brief confirmation ("Session ID Copied") that floats at the top of the
/// window the action ran in, and fades out on its own. VoiceOver hears it as
/// an announcement.
@MainActor
enum TransientConfirmationPill {
    private static let tag = 0x0991_C0DE

    /// Shows `message` in the window of `view`, the control that ran it.
    static func show(_ message: String, systemImage: String = "checkmark.circle.fill", in view: UIView) {
        UIAccessibility.post(notification: .announcement, argument: message)
        guard let window = view.window else { return }
        window.viewWithTag(tag)?.removeFromSuperview()

        let pill = UIView()
        pill.tag = tag
        pill.isUserInteractionEnabled = false
        pill.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
        pill.layer.cornerRadius = 18
        pill.layer.cornerCurve = .continuous
        pill.layer.shadowColor = UIColor.black.cgColor
        pill.layer.shadowOpacity = 0.18
        pill.layer.shadowRadius = 10
        pill.layer.shadowOffset = CGSize(width: 0, height: 3)
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.accessibilityElementsHidden = true

        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.tintColor = .systemGreen
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .label
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)
        window.addSubview(pill)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8),
            pill.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            pill.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])

        pill.alpha = 0
        UIView.animate(withDuration: 0.2) { pill.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 1.4, options: [.beginFromCurrentState]) {
            pill.alpha = 0
        } completion: { _ in
            pill.removeFromSuperview()
        }
    }
}
