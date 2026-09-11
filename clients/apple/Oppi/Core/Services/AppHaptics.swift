@preconcurrency import AVFoundation
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

    /// Immediate acknowledgement that the mic tap was accepted.
    static func dictationTapAccepted() {
        impact(style: .light, intensity: 0.5)
    }

    /// Use the same confirmation as saving a comment, once capture is ready.
    static func dictationActivated() {
        guard AppPreferences.Interaction.isHapticFeedbackEnabled else { return }
        #if os(iOS)
        // Reassert after the engine has finished configuring its audio session,
        // not just before category/route setup. This never changes the mic route.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            ClientLog.warning("VoiceInput", "Could not enable activation haptic", metadata: [
                "error_domain": (error as NSError).domain,
                "error_code": String((error as NSError).code),
            ])
        }
        ClientLog.info("VoiceInput", "Dictation activation haptic requested", metadata: [
            "feedback": "success",
            "recording_haptics_allowed": String(session.allowHapticsAndSystemSoundsDuringRecording),
        ])
        #endif
        success()
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
