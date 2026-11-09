import UIKit

/// UIKit pieces every transient notice shares with `NoticeDismissTimer`: the
/// Dismiss control and the touch-hold that pauses the timer.
enum NoticeChrome {
    /// A 44 pt close button labelled "Dismiss". The caller sets the scoped
    /// accessibility identifier and the tint.
    @MainActor
    static func dismissButton(identifier: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        )
        configuration.contentInsets = .zero
        let button = UIButton(type: .system)
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = "Dismiss"
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return button
    }
}

/// Reports touch down and up on a notice without taking the touch from its
/// buttons, so the owner can pause the auto-dismiss timer while it is held.
@MainActor
final class NoticeTouchHold: NSObject, UIGestureRecognizerDelegate {
    private let onChange: (Bool) -> Void

    init(view: UIView, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init()
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(changed(_:)))
        hold.minimumPressDuration = 0
        hold.cancelsTouchesInView = false
        hold.delegate = self
        view.addGestureRecognizer(hold)
    }

    @objc private func changed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: onChange(true)
        case .ended, .cancelled, .failed: onChange(false)
        default: break
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
