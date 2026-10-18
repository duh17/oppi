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

/// One wheel notch is three cell-rows of finger travel, matching the common
/// 3-lines-per-notch default (xterm, vim, Herdr). Herdr content then tracks
/// the finger 1:1. tmux (five lines per notch) runs a little ahead.
enum SSHTerminalWheelScaling {
    static let cellsPerEvent: CGFloat = 3
}

/// Turns finger travel into whole steps (one ↑/↓ per row, one wheel notch per
/// three rows) for an app that scrolls itself. The remote only moves whole
/// lines, so content stays within about half a step of the finger: a step is
/// sent once travel passes the halfway point, not after a full step. The
/// first step comes after half a step, not a whole one. Reversing a step
/// takes `hysteresis` more travel, so a finger wobbling at the halfway point
/// does not send ↑↓↑. Remainder carries across events in one gesture. Sign:
/// finger down is negative (wheel-up, ↑): content follows the finger.
struct SSHTerminalStepQuantizer {
    static let hysteresis: CGFloat = 3
    var remainder: CGFloat = 0

    /// Finger translation in the view (positive is down). Returns signed steps.
    mutating func steps(travel: CGFloat, step: CGFloat) -> Int {
        guard step > 0 else { return 0 }
        remainder -= travel
        guard abs(remainder) >= step / 2 + Self.hysteresis else { return 0 }
        let count = Int((remainder / step).rounded())
        remainder -= CGFloat(count) * step
        return count
    }
}

/// Where local history draws for a scroll offset: the top viewport row, and how
/// far the grid moves up into that row in whole device pixels so glyphs stay
/// on the pixel grid. Past either end the grid stays on the first or last row
/// and moves by `bounce` points (positive is down) for the rubber band.
struct SSHTerminalHistoryPosition: Equatable {
    var row: Int
    var shiftPixels: Int
    var bounce: CGFloat

    static func resolve(
        offset: CGFloat, maxOffset: CGFloat, lastRow: Int, cellHeight: CGFloat, scale: CGFloat
    ) -> Self {
        guard cellHeight > 0 else { return .init(row: 0, shiftPixels: 0, bounce: 0) }
        if offset < 0 { return .init(row: 0, shiftPixels: 0, bounce: -offset) }
        if offset >= maxOffset { return .init(row: lastRow, shiftPixels: 0, bounce: maxOffset - offset) }
        let row = min(lastRow, Int((offset / cellHeight).rounded(.down)))
        let shift = Int(((offset - CGFloat(row) * cellHeight) * max(scale, 1)).rounded())
        return .init(row: row, shiftPixels: shift, bounce: 0)
    }
}

/// UIScrollView's pan starts about 10 pt after the finger starts moving and
/// then trails the finger by that much for the whole drag. Local history
/// instead follows from the first move: before the pan starts, the grid is
/// drawn `lead` above the scroll view's offset, and the first drag callback
/// moves contentOffset to where the grid already is, so nothing jumps.
/// `deadZone` keeps the jitter of a tap or a touch-and-hold from moving text.
enum SSHTerminalHistoryFingerLead {
    static let deadZone: CGFloat = 2

    /// Content travel for finger travel (both positive down).
    static func lead(fingerTravel: CGFloat) -> CGFloat {
        let magnitude = max(0, abs(fingerTravel) - deadZone)
        return fingerTravel < 0 ? -magnitude : magnitude
    }

    /// The offset that puts content under the finger once the drag starts.
    /// It never pushes past an end further than the scroll view already is,
    /// so the native rubber band keeps its own position.
    static func dragOffset(
        start: CGFloat, current: CGFloat, fingerTravel: CGFloat, maxOffset: CGFloat
    ) -> CGFloat {
        let target = start - lead(fingerTravel: fingerTravel)
        return min(max(target, min(0, current)), max(maxOffset, current))
    }
}

/// UIScrollView offset to the same finger-travel sign as the old pan gesture
/// (positive is finger down). Finger down decreases `contentOffset.y`.
enum SSHTerminalAppScrollTranslation {
    static func fingerTravel(previousOffset: CGFloat, currentOffset: CGFloat) -> CGFloat {
        previousOffset - currentOffset
    }
}

/// In-flight wheel and arrow emission. A remote mode change reseeds this so a
/// history offset cannot become PTY input, and a fake app-surface offset cannot
/// jump local history.
struct SSHTerminalAppScrollAccumulator {
    var wheelSteps = SSHTerminalStepQuantizer()
    var altSteps = SSHTerminalStepQuantizer()
    var lastOffset: CGFloat = 0
    var pendingWheelSteps = 0
    var pendingAltRows = 0
    var pendingWheelCell: (column: Int, row: Int)?

    mutating func cancelQueuedSteps() {
        pendingWheelSteps = 0
        pendingAltRows = 0
    }

    mutating func resetGesture() {
        wheelSteps = SSHTerminalStepQuantizer()
        altSteps = SSHTerminalStepQuantizer()
        pendingWheelSteps = 0
        pendingAltRows = 0
        pendingWheelCell = nil
    }

    mutating func reseed(offset: CGFloat) {
        resetGesture()
        lastOffset = offset
    }

    mutating func consume(
        offset: CGFloat,
        cellHeight: CGFloat,
        action: SSHTerminalScrollAction,
        wheelCell: (column: Int, row: Int)?
    ) {
        let travel = SSHTerminalAppScrollTranslation.fingerTravel(
            previousOffset: lastOffset, currentOffset: offset
        )
        lastOffset = offset
        guard cellHeight > 0, travel != 0 else { return }
        switch action {
        case .mouseWheel:
            pendingWheelSteps += wheelSteps.steps(
                travel: travel, step: cellHeight * SSHTerminalWheelScaling.cellsPerEvent
            )
            if let wheelCell {
                pendingWheelCell = wheelCell
            }
        case .alternateKeys:
            pendingAltRows += altSteps.steps(travel: travel, step: cellHeight)
        case .history:
            break
        }
    }

    mutating func takeFlush(action: SSHTerminalScrollAction) -> Flush {
        let wheel = action == .mouseWheel ? pendingWheelSteps : 0
        let alt = action == .alternateKeys ? pendingAltRows : 0
        pendingWheelSteps = 0
        pendingAltRows = 0
        return Flush(
            wheelSteps: wheel,
            altRows: alt,
            wheelCell: pendingWheelCell ?? (column: 0, row: 0)
        )
    }

    struct Flush: Equatable {
        var wheelSteps: Int
        var altRows: Int
        var wheelCell: (column: Int, row: Int)

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.wheelSteps == rhs.wheelSteps
                && lhs.altRows == rhs.altRows
                && lhs.wheelCell.column == rhs.wheelCell.column
                && lhs.wheelCell.row == rhs.wheelCell.row
        }
    }
}

/// Travel the pan already recognized before UIScrollView starts tracking.
/// Prefer the pan translation at `.began`; if that is still zero, use the
/// delta from the first touch to the current pan location.
enum SSHTerminalAppScrollSlop {
    static func uncountedTravel(
        panTranslationY: CGFloat,
        firstTouchY: CGFloat?,
        panLocationY: CGFloat
    ) -> CGFloat {
        if panTranslationY != 0 { return panTranslationY }
        guard let firstTouchY else { return 0 }
        return panLocationY - firstTouchY
    }
}

/// One SSH write for every notch or arrow produced in a frame, so a fling
/// does not enqueue one write per event.
enum SSHTerminalScrollCoalescing {
    static func encodeRepeated(_ count: Int, encode: () -> Data) -> Data {
        guard count > 0 else { return Data() }
        var bytes = Data()
        bytes.reserveCapacity(count * 8)
        for _ in 0..<count {
            bytes.append(encode())
        }
        return bytes
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
