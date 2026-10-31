import CoreGraphics
import UIKit

/// The terminal has no navigation bar. Back sits in a glass pill at the bottom
/// leading corner; the program status, the bar's buttons, and the … menu share
/// one centred pill between Back and the trailing end, where a Rex session's
/// pane switcher has a pill of its own. The bar ends at the keyboard layout
/// guide, and the grid ends above it, so it never covers a terminal row.
enum SSHTerminalFloatingControls {
    /// The bar steps aside while a docked keyboard is up (typing) and comes
    /// back when it goes down. A broken connection keeps it: Back and
    /// Reconnect must stay in reach.
    static func visible(keyboardUp: Bool, connected: Bool) -> Bool {
        !keyboardUp || !connected
    }

    /// Rows the grid leaves free for the bottom bar. Only with the keyboard
    /// down: with a docked keyboard up the bar is gone, and when a broken
    /// connection brings it back it floats over the grid's bottom rows instead
    /// of taking them. A connection change therefore never resizes the shell;
    /// only a keyboard change does, and it already sends one.
    @MainActor
    static func bottomBarReserve(keyboardUp: Bool) -> CGFloat {
        keyboardUp ? 0 : SSHTerminalBottomBar.reserve
    }

    /// Dot on the Back pill: a pane waiting in Herdr or Rex, or a blocked
    /// program. Same signals as the multiplexer buttons' attention tint and the
    /// waiting-program card. OSC 9 notifications are not this.
    static func attentionPending(multiplexersWaiting: Int, blockedProgram: Bool) -> Bool {
        multiplexersWaiting > 0 || blockedProgram
    }
}

/// Bottom bar geometry. The glass is 36 pt tall, inset 4 pt from the top of a
/// 44 pt container, which rests 4 pt above the keyboard layout guide (the
/// bottom safe area without a keyboard). The container's top inset is where
/// the pills' 4 pt touch outset lives, so a finger just above the glass still
/// reaches the button; the grid keeps 8 pt more free so no row touches the
/// glass. Hiding the bar gives all of it back to the grid, inside the one
/// resize a keyboard change sends.
@MainActor
enum SSHTerminalBottomBar {
    static let pillHeight = SSHTerminalGlassPill.height
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 4
    static let gridGap: CGFloat = 8
    /// The container's height while the bar shows: a 44 pt touch target.
    static let shownHeight = pillHeight + topInset + bottomInset
    /// Rows the grid leaves free while the bar shows.
    static let reserve = shownHeight + gridGap
    /// Back and the pane switcher's pill sit this far inside the safe area.
    static let sideInset: CGFloat = 12
    /// The least room between Back and the centred pill, and between it and the pane switcher.
    static let pillGap: CGFloat = 8

    /// The width between Back and what sits at the trailing end: the Rex pane
    /// switcher's pill while it shows, else the screen's edge. The pill
    /// lives in it; it is centred on the screen when it fits there
    /// (`pillMinX`).
    static func roomWidth(width: CGFloat, safeInsets: UIEdgeInsets, rexPanesShown: Bool) -> CGFloat {
        let reserve = rexPanesShown ? SSHTerminalGlassPill.itemWidth + pillGap : 0
        return width - safeInsets.left - safeInsets.right - 2 * sideInset
            - SSHTerminalGlassPill.height - pillGap - reserve
    }

    /// Where the pill's leading edge is, for a pill `pillWidth` wide in a bar
    /// `viewWidth` wide: centered on the screen, unless that would bring an
    /// edge closer than `pillGap` to Back or to the pane switcher's pill (or
    /// the side inset at the trailing edge), when it moves just far enough. A
    /// pill wider than its room (the capacity prevents it) starts at the room's
    /// leading edge.
    static func pillMinX(pillWidth: CGFloat, viewWidth: CGFloat, safeInsets: UIEdgeInsets, rexPanesShown: Bool) -> CGFloat {
        let lower = safeInsets.left + sideInset + SSHTerminalGlassPill.height + pillGap
        let reserve = rexPanesShown ? SSHTerminalGlassPill.itemWidth + pillGap : 0
        let upper = viewWidth - safeInsets.right - sideInset - reserve
        let centered = (viewWidth - pillWidth) / 2
        return max(lower, min(centered, upper - pillWidth))
    }

    /// How many buttons the pill has room for besides its fixed items (the
    /// program-status symbol while shown, and …): whole 44 pt items in
    /// `roomWidth`. Whatever is left over goes to the … menu.
    static func capacity(width: CGFloat, safeInsets: UIEdgeInsets, rexPanesShown: Bool, fixedItems: Int) -> Int {
        let room = roomWidth(width: width, safeInsets: safeInsets, rexPanesShown: rexPanesShown)
        return max(0, Int((room / SSHTerminalGlassPill.itemWidth).rounded(.down)) - fixedItems)
    }
}

/// What the pill's capacity depends on besides the layout and what sits
/// beside it: the bar's width and its side safe-area insets.
struct SSHTerminalBarFit: Equatable {
    var width: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0

    init() {}

    @MainActor
    init(_ view: UIView) {
        width = view.bounds.width
        left = view.safeAreaInsets.left
        right = view.safeAreaInsets.right
    }
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
    @MainActor
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
