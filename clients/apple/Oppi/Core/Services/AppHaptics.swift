import UIKit

/// Small, optional haptics for direct user actions.
///
/// Keep these sparse and causal: one short transient that matches a visible
/// change. Apple guidance favors standard feedback generators for ordinary UI,
/// with custom Core Haptics reserved for richer app/game moments.
enum AppHaptics {
    /// A light, short tap for opening or expanding chat chrome.
    static func toolbarExpansion() {
        impact(style: .light, intensity: 0.45)
    }

    /// A crisper confirmation that a long-press threshold has been crossed.
    static func longPressThreshold() {
        impact(style: .rigid, intensity: 0.65)
    }

    /// Feedback for changing a selected value or option.
    static func selectionChanged() {
        guard AppPreferences.Interaction.isHapticFeedbackEnabled else { return }
        MainActor.assumeIsolated {
            let feedback = UISelectionFeedbackGenerator()
            feedback.prepare()
            feedback.selectionChanged()
        }
    }

    /// Feedback for an infrequent successful operation.
    static func success() {
        guard AppPreferences.Interaction.isHapticFeedbackEnabled else { return }
        MainActor.assumeIsolated {
            let feedback = UINotificationFeedbackGenerator()
            feedback.prepare()
            feedback.notificationOccurred(.success)
        }
    }

    static func impact(style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat? = nil) {
        guard AppPreferences.Interaction.isHapticFeedbackEnabled else { return }
        MainActor.assumeIsolated {
            let feedback = UIImpactFeedbackGenerator(style: style)
            feedback.prepare()
            if let intensity {
                feedback.impactOccurred(intensity: intensity)
            } else {
                feedback.impactOccurred()
            }
        }
    }
}
