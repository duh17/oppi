import CoreGraphics
import UIKit

/// The terminal has no navigation bar. Back sits in a glass pill at the top
/// leading corner; status, Herdr, and the … menu share one at the trailing
/// corner. They float over the grid, so showing or hiding them never resizes
/// the remote terminal.
enum SSHTerminalFloatingControls {
    /// The pills step aside while a docked keyboard is up (typing) and come
    /// back when it goes down. A broken connection keeps them: Back and
    /// Reconnect must stay in reach.
    static func visible(keyboardUp: Bool, connected: Bool) -> Bool {
        !keyboardUp || !connected
    }

    /// Dot on the Back pill: Herdr waiting, or a blocked program. Same
    /// signals as the Herdr attention tint and the waiting-program card.
    /// OSC 9 notifications are not this.
    static func attentionPending(herdrWaiting: Int, blockedProgram: Bool) -> Bool {
        herdrWaiting > 0 || blockedProgram
    }
}

/// Docked software keyboard covering the bottom of this terminal's display.
/// A floating iPad keyboard is not "up". A keyboard on the Duo's other
/// display is ignored: the notification's object is the keyboard's screen,
/// and its frame is in that screen's coordinate space.
enum SSHTerminalKeyboard {
    struct Animation {
        var duration: TimeInterval
        var options: UIView.AnimationOptions
    }

    static func isUp(endFrameInView: CGRect, viewBounds: CGRect) -> Bool {
        let overlap = endFrameInView.intersection(viewBounds)
        guard overlap.height > 1, overlap.width > 1 else { return false }
        // Docked to this view's bottom (phone, Duo inner, iPad docked),
        // even when the keyboard is only as wide as one Duo panel.
        return overlap.maxY >= viewBounds.maxY - 2
    }

    /// The keyboard's end frame in `view`, or nil when the keyboard is on
    /// another display than the view's (or the notification names none).
    static func endFrame(
        _ frame: CGRect,
        keyboardScreen: AnyObject?,
        viewScreen: AnyObject?,
        screenSpace: any UICoordinateSpace,
        in view: any UICoordinateSpace
    ) -> CGRect? {
        guard let keyboardScreen, let viewScreen, keyboardScreen === viewScreen else { return nil }
        return screenSpace.convert(frame, to: view)
    }

    /// Where the keyboard layout guide's top settles, in view coordinates.
    /// The guide follows a docked keyboard and otherwise rests on the bottom
    /// safe area; it does not follow a floating keyboard.
    static func settledGuideTop(endFrameInView: CGRect, viewBounds: CGRect, bottomSafeArea: CGFloat) -> CGFloat {
        let safeBottom = viewBounds.maxY - bottomSafeArea
        guard isUp(endFrameInView: endFrameInView, viewBounds: viewBounds) else { return safeBottom }
        return min(endFrameInView.minY, safeBottom)
    }

    /// The grid's size once the keyboard settles. Its top is fixed; its
    /// bottom moves with the keyboard guide, with or without the chat bar's
    /// resting height between them.
    static func settledGridSize(current: CGSize, guideTop: CGFloat, settledGuideTop: CGFloat) -> CGSize {
        CGSize(width: current.width, height: max(0, current.height + settledGuideTop - guideTop))
    }

    static func animation(duration: TimeInterval, curve: UInt) -> Animation {
        Animation(
            duration: duration,
            options: UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        )
    }
}
