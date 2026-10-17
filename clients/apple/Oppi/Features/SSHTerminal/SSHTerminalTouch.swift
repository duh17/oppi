import CoreGraphics
import Foundation

/// Where a vertical finger move goes. Matches Ghostty `Surface.zig`
/// `scrollCallback`: mouse reports win; otherwise alternate screen with
/// DEC 1007 sends cursor keys; otherwise local history.
enum SSHTerminalScrollAction: Equatable {
    case history
    case alternateKeys
    case mouseWheel

    static func resolve(altScreen: Bool, mouseReporting: Bool, alternateScroll: Bool) -> Self {
        if mouseReporting { return .mouseWheel }
        if altScreen && alternateScroll { return .alternateKeys }
        return .history
    }
}

/// Long-press-drag is a mouse drag only while the app asked for reports.
/// Otherwise it is a local selection and never writes the PTY.
enum SSHTerminalDragTarget: Equatable {
    case selection
    case mouse

    static func resolve(mouseReporting: Bool) -> Self {
        mouseReporting ? .mouse : .selection
    }
}

/// Convert finger travel into wheel notches for mouse-reporting apps.
///
/// tmux (the named case) scrolls five lines per wheel notch. Today's grid
/// sent one notch per row of travel, so a one-row swipe jumped five tmux
/// lines. Touch has no hardware notch, so one notch is five cell-rows of
/// travel: tmux then moves about one line per cell of finger, like native
/// scrolling. Remainder carries across events in one gesture. Sign matches
/// the previous pan: finger down is wheel-up (earlier history / content
/// follows the finger).
enum SSHTerminalWheelScaling {
    static let cellsPerEvent: CGFloat = 5

    struct Accumulator {
        var remainder: CGFloat = 0

        /// Finger translation in the view (positive is down). Returns signed
        /// wheel steps: negative is wheel-up, positive is wheel-down.
        mutating func steps(travel: CGFloat, cellHeight: CGFloat) -> Int {
            guard cellHeight > 0 else { return 0 }
            remainder -= travel
            let step = cellHeight * SSHTerminalWheelScaling.cellsPerEvent
            let count = Int(remainder / step)
            remainder -= CGFloat(count) * step
            return count
        }
    }
}

/// Viewport-local highlight for a selection snapshot. Columns are inclusive.
struct SSHTerminalSelectionSpan: Equatable {
    var row: Int
    var startColumn: Int
    var endColumn: Int
}

struct SSHTerminalSelectionSnapshot: Equatable {
    var text: String
    var spans: [SSHTerminalSelectionSpan]
}

/// Back to Live is a history-mode affordance. Alt-screen and mouse reporting
/// hide it without changing `engine.following`.
enum SSHTerminalFollowChrome {
    static func showsBackToLive(scrollAction: SSHTerminalScrollAction, following: Bool) -> Bool {
        scrollAction == .history && !following
    }
}

/// History content height so the live row is reachable when the grid is not a
/// whole number of cells: `contentSize.height - bounds.height == (total - rows) × cellHeight`.
enum SSHTerminalHistoryLayout {
    static func contentHeight(
        boundsHeight: CGFloat,
        totalRows: Int,
        viewportRows: Int,
        cellHeight: CGFloat
    ) -> CGFloat {
        guard boundsHeight > 0, cellHeight > 0 else { return 0 }
        return boundsHeight + CGFloat(max(0, totalRows - viewportRows)) * cellHeight
    }
}

/// Single-tap stays immediate. A second tap inside the double-tap window only
/// copies the word captured on tap 1 — it never runs the single-tap action.
struct SSHTerminalTapSequence {
    static let doubleTapTimeout: TimeInterval = 0.35
    static let doubleTapSlop: CGFloat = 44

    enum Decision: Equatable {
        case firstTap
        case secondTap
    }

    private var last: (time: TimeInterval, location: CGPoint)?
    private(set) var pendingSnapshot: SSHTerminalSelectionSnapshot?

    mutating func recognize(
        location: CGPoint,
        time: TimeInterval,
        snapshot: SSHTerminalSelectionSnapshot?
    ) -> Decision {
        if let last,
           time - last.time <= Self.doubleTapTimeout,
           hypot(location.x - last.location.x, location.y - last.location.y) <= Self.doubleTapSlop {
            self.last = nil
            return .secondTap
        }
        self.last = (time, location)
        pendingSnapshot = snapshot
        return .firstTap
    }

    mutating func takePendingSnapshot() -> SSHTerminalSelectionSnapshot? {
        let value = pendingSnapshot
        pendingSnapshot = nil
        last = nil
        return value
    }

    mutating func reset() {
        last = nil
        pendingSnapshot = nil
    }
}

/// Long-press sets this so its own tap is ignored. Clear on a failed tap
/// recognizer at long-press end, or on the next touch begin, so the following
/// independent tap is not eaten.
struct SSHTerminalTapIgnore {
    private(set) var armed = false

    mutating func arm() { armed = true }

    mutating func longPressEnded(tapFailed: Bool) {
        if tapFailed { armed = false }
    }

    mutating func touchBegan() { armed = false }

    mutating func consumeTap() -> Bool {
        guard armed else { return false }
        armed = false
        return true
    }
}

/// Local copies cap at `maximumCopyBytes` on a UTF-8 boundary, not characters.
enum SSHTerminalCopyLimit {
    static func clip(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let utf8 = text.utf8
        if utf8.count <= maxBytes { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while end > utf8.startIndex && (utf8[end] & 0b1100_0000) == 0b1000_0000 {
            end = utf8.index(before: end)
        }
        return String(decoding: utf8[..<end], as: UTF8.self)
    }
}

/// `:` is not a word boundary (paths and URLs stay one word). Drop one trailing
/// colon unless the word is a URL with a port or an IPv6 address.
enum SSHTerminalWordCopy {
    static func normalize(_ text: String) -> String {
        guard text.hasSuffix(":"), text.count > 1 else { return text }
        if isIPv6(text) || isURLWithPort(text) { return text }
        return String(text.dropLast())
    }

    static func applyingTrailingColonTrim(_ snapshot: SSHTerminalSelectionSnapshot) -> SSHTerminalSelectionSnapshot {
        let text = normalize(snapshot.text)
        guard text != snapshot.text else { return snapshot }
        var spans = snapshot.spans
        guard !spans.isEmpty else {
            return SSHTerminalSelectionSnapshot(text: text, spans: spans)
        }
        var last = spans[spans.count - 1]
        if last.endColumn > last.startColumn {
            last.endColumn -= 1
            spans[spans.count - 1] = last
        } else if spans.count > 1 {
            spans.removeLast()
        }
        return SSHTerminalSelectionSnapshot(text: text, spans: spans)
    }

    static func isURLWithPort(_ text: String) -> Bool {
        if let url = URL(string: text), url.port != nil { return true }
        if text.hasSuffix(":"), let url = URL(string: String(text.dropLast())), url.port != nil {
            return true
        }
        return false
    }

    static func isIPv6(_ text: String) -> Bool {
        if text.contains("::") { return true }
        let core = text.hasSuffix(":") ? String(text.dropLast()) : text
        let stripped = core.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.")
        guard stripped.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        return stripped.filter { $0 == ":" }.count >= 2
    }
}
