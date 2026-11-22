import Accessibility
import UIKit

/// The app's one answer to "may this move?", for every animating view: the
/// Animations setting in Settings, held still by the system's own switches. A view
/// asks this instead of reading the setting or the system itself, so there is
/// one rule rather than one per animation (`IconChoiceUIView`, the busy
/// spinner, the dictation indicator, the sidebar's mark).
@MainActor
enum MotionPolicy {
    /// Reduce Motion, Low Power Mode, or Auto-Play Animated Images off each hold
    /// the whole app still: the person asked the system for no motion.
    static func effective(
        setting: MotionSetting = AppPreferenceStore.Appearance.motion,
        reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled,
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        animatedImages: Bool = AccessibilitySettings.animatedImagesEnabled
    ) -> MotionSetting {
        !reduceMotion && !lowPowerMode && animatedImages ? setting : .off
    }

    /// Motion that never ends on its own: the busy spinner, the dictation
    /// indicator, the sidebar's mark, an icon that plays on its own page.
    static var playsLoops: Bool { effective().playsLoops }

    /// One short burst at a moment: a chat opens, a turn ends, a session needs
    /// the person (`IconChoiceUIView.playBurst`).
    static var playsMoments: Bool { effective().playsMoments }

    /// Runs `handler` when the Animations setting or one of the system's switches
    /// changes. The tokens are the caller's to remove.
    static func observe(_ handler: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        return [
            AppPreferenceStore.Appearance.motionDidChangeNotification,
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            .NSProcessInfoPowerStateDidChange,
            AccessibilitySettings.animatedImagesEnabledDidChangeNotification,
        ].map { name in
            // "queue: .main" so a setting written from any thread runs the
            // handler on the main thread, where these views live.
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }
    }
}
