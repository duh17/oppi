import CoreGraphics
import UIKit

/// The terminal has no navigation bar. Back sits in a glass pill at the bottom
/// leading corner; status, Herdr, and the … menu share one at the bottom
/// trailing corner. The bar ends at the keyboard layout guide, and the grid
/// ends above it, so it never covers a terminal row.
enum SSHTerminalFloatingControls {
    /// The bar steps aside while a docked keyboard is up (typing) and comes
    /// back when it goes down. A broken connection keeps it: Back and
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

/// Bottom bar geometry. The glass is 36 pt tall and rests 4 pt above the
/// keyboard layout guide (the bottom safe area without a keyboard), and the
/// grid keeps 8 pt more free so no row touches the glass. Hiding the bar gives
/// all of it back to the grid, inside the one resize a keyboard change sends.
@MainActor
enum SSHTerminalBottomBar {
    static let pillHeight = SSHTerminalGlassPill.height
    static let bottomInset: CGFloat = 4
    static let gridGap: CGFloat = 8
    /// The container's height while the bar shows.
    static let shownHeight = pillHeight + bottomInset
    /// Rows the grid leaves free while the bar shows.
    static let reserve = shownHeight + gridGap
}

/// The chat bar grows over the grid instead of shrinking it: the grid keeps
/// the room for the bar at rest, so typing more lines, attachments, or
/// suggestions never resizes the remote terminal. When the bar covers the
/// row the program's cursor is on, the grid's picture moves up by the fewest
/// whole rows that keep that row above the bar, as a chat transcript moves
/// up for a growing composer. Whole rows leave no half-cut row at the top
/// edge; the rows above slide under it until the bar shrinks. A cursor
/// below the grid's last row moves nothing: the keyboard just resized the
/// grid and the terminal has not taken the new size yet.
enum SSHTerminalComposerOverlap {
    static func shift(gridHeight: CGFloat, covered: CGFloat, cursorRow: Int, cellHeight: CGFloat) -> CGFloat {
        guard covered > 0, cellHeight > 0,
              cursorRow < Int(gridHeight / cellHeight) else { return 0 }
        let cursorBottom = CGFloat(cursorRow + 1) * cellHeight
        let needed = cursorBottom - (gridHeight - covered)
        guard needed > 0 else { return 0 }
        return (needed / cellHeight).rounded(.up) * cellHeight
    }

    /// While you read history the picture keeps the shift it had, so
    /// nothing moves; a bar that shrank still gives back the rows it no
    /// longer covers.
    static func held(_ current: CGFloat, covered: CGFloat, cellHeight: CGFloat) -> CGFloat {
        guard covered > 0, cellHeight > 0 else { return 0 }
        return min(current, (covered / cellHeight).rounded(.up) * cellHeight)
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
