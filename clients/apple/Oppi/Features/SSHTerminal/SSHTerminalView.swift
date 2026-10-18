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
enum SSHTerminalTopBarVisibility {
    static func hidden(
        connected: Bool,
        keyboardUp: Bool,
        rememberedHide: Bool,
        temporaryReveal: Bool
    ) -> Bool {
        guard connected else { return false }
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
/// display is not "up". Keyboard frames in notifications are screen
/// coordinates; convert through the window scene's screen.
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

    static func endFrameInView(_ screenFrame: CGRect, view: UIView) -> CGRect {
        guard let window = view.window else {
            return view.convert(screenFrame, from: nil)
        }
        if let space = window.windowScene?.screen.coordinateSpace {
            let inWindow = window.convert(screenFrame, from: space)
            return view.convert(inWindow, from: window)
        }
        return view.convert(screenFrame, from: window)
    }

    static func animation(duration: TimeInterval, curve: UInt) -> Animation {
        Animation(
            duration: duration,
            options: UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        )
    }
}
