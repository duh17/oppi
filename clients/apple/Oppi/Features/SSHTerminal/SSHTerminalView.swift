import CoreGraphics
import UIKit

/// Showing or hiding the navigation bar resizes the remote terminal, so a
/// history drag must not do it. A pull counts only when it is long enough and
/// mostly vertical. Finger down is show; finger up is hide. The reveal handle
/// commits show only.
enum SSHTerminalTopBarGesture {
    /// Shorter than a nav-bar height. The old 24pt scroll threshold resized
    /// the terminal on an ordinary history nudge.
    static let minimumTravel: CGFloat = 44
    static let dominanceRatio: CGFloat = 1.35

    enum Action: Equatable {
        case show
        case hide
    }

    static func action(translation: CGSize) -> Action? {
        let vertical = translation.height
        guard abs(vertical) >= minimumTravel else { return nil }
        guard abs(vertical) > abs(translation.width) * dominanceRatio else { return nil }
        return vertical > 0 ? .show : .hide
    }
}

/// Navigation bar visibility: remembered Hide Bar, keyboard auto-hide, and a
/// temporary reveal from the chevron while the keyboard is up.
///
/// Temporary reveal stays until the keyboard goes down. It does not re-hide on
/// a keystroke (that would resize the remote PTY again) and does not write the
/// remembered Hide Bar choice.
///
/// A terminal that is leaving (popped, swiped back, or covered by a push)
/// shows the shared bar: the incoming screen needs its Back and title, and
/// the keyboard going down on the way out must not hide it again.
enum SSHTerminalTopBarVisibility {
    static func hidden(
        connected: Bool,
        leaving: Bool,
        keyboardUp: Bool,
        rememberedHide: Bool,
        temporaryReveal: Bool
    ) -> Bool {
        guard connected, !leaving else { return false }
        let wantsHide = rememberedHide || keyboardUp
        let revealed = temporaryReveal && keyboardUp
        return wantsHide && !revealed
    }

    static func handleVisible(barHidden: Bool, connected: Bool) -> Bool {
        barHidden && connected
    }
}

/// Dot on the Hide Bar handle: Herdr waiting, or a blocked program. Same
/// signals as the Herdr attention tint and the waiting-program card. OSC 9
/// notifications are not this.
enum SSHTerminalTopBarAttention {
    static func pending(herdrWaiting: Int, blockedProgram: Bool) -> Bool {
        herdrWaiting > 0 || blockedProgram
    }
}

/// Docked software keyboard covering the bottom of this terminal's display.
/// A floating iPad keyboard is not "up". A keyboard on the Duo's other
/// display is ignored: the notification's object is the keyboard's screen,
/// and its frame is in that screen's coordinate space.
enum SSHTerminalTopBarKeyboard {
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

    /// The grid's size once the keyboard settles. The grid's top is already
    /// final (the bar changed in this layout pass); its bottom moves with the
    /// keyboard guide, with or without the chat bar between them.
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
