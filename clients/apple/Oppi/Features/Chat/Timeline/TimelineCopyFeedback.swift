import UIKit

/// Shared copy + feedback behavior for timeline row interactions.
enum TimelineCopyFeedback {
    static func copy(
        _ text: String,
        feedbackView: UIView?,
        trimWhitespaceAndNewlines: Bool = false
    ) {
        let value: String
        if trimWhitespaceAndNewlines {
            value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            value = text
        }

        guard !value.isEmpty else { return }

        UIPasteboard.general.string = value

        let feedback = UIImpactFeedbackGenerator(style: .light)
        feedback.impactOccurred(intensity: 0.8)

        guard let feedbackView else { return }

        UIView.animate(
            withDuration: 0.08,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseOut]
        ) {
            feedbackView.alpha = 0.78
        } completion: { _ in
            UIView.animate(
                withDuration: 0.12,
                delay: 0,
                options: [.allowUserInteraction, .curveEaseOut]
            ) {
                feedbackView.alpha = 1
            }
        }
    }
}
