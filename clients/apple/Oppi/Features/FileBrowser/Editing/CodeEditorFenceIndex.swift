import Foundation

/// Where fenced code blocks (``` or ~~~) are in a Markdown buffer. A fence
/// runs from its opening line to its closing line, or to the end of the text
/// when it never closes. A line is inside one when it comes after the opening
/// line, up to and including the closing line: such a line is code, whatever
/// it looks like. The opening line itself is entered from outside.
///
/// Scanned lazily: a question about an offset scans the text only up to that
/// offset, hopping between fence markers with native searches, and keeps what
/// it found. An edit discards only what lies at or after the edited line.
struct CodeEditorFenceIndex {
    /// Whether a position is in a fence, and which kind (a closing line must
    /// match the opening line's character and be at least as long).
    enum State: Equatable {
        case outside
        case inside(character: unichar, length: Int)
    }

    private struct Fence {
        /// From the opening line's start to the end of the closing line.
        var range: NSRange
        /// End of the opening line, line break included.
        var openerEnd: Int
        var character: unichar
        var length: Int
    }

    private struct OpenFence {
        var start: Int
        var openerEnd: Int
        var character: unichar
        var length: Int
    }

    /// Closed fences, sorted, all before `scannedThrough`.
    private var fences: [Fence] = []
    /// A fence that opened before `scannedThrough` and has not closed yet.
    private var open: OpenFence?
    /// Every line that starts before this offset has been read.
    private(set) var scannedThrough = 0
    /// The next place each marker may be: a real hit, or the end of the window
    /// searched without finding one (searching is bounded, so a keystroke does
    /// not scan the rest of a large buffer for a marker that never occurs).
    private var tick = Candidate()
    private var tilde = Candidate()

    private struct Candidate {
        var position = -1
        var isMarker = false
        var isExhausted = false

        /// A marker is used up once the scan passes it; "none up to here" once the scan gets there.
        func isBehind(_ position: Int) -> Bool {
            self.position < position || (!isMarker && self.position == position)
        }
    }

    private static let searchWindow = 16_384

    mutating func contains(_ offset: Int, in text: NSString) -> Bool {
        state(at: offset, in: text) != .outside
    }

    mutating func state(at offset: Int, in text: NSString) -> State {
        advance(past: offset, in: text)
        return knownState(at: offset)
    }

    /// The state entering the line that starts at `offset`, which the scan has
    /// already passed.
    private func knownState(at offset: Int) -> State {
        if let open, offset >= open.openerEnd { return .inside(character: open.character, length: open.length) }
        var low = 0
        var high = fences.count
        while low < high {
            let mid = (low + high) / 2
            let fence = fences[mid]
            if offset < fence.range.location {
                high = mid
            } else if offset >= NSMaxRange(fence.range) {
                low = mid + 1
            } else {
                return offset >= fence.openerEnd ? .inside(character: fence.character, length: fence.length) : .outside
            }
        }
        return .outside
    }

    /// Brings the index up to date after text was replaced: `edited` is the
    /// new text's range, the text is `changeInLength` characters longer than
    /// before. Returns the range of lines whose answer may have changed and
    /// that something already asked about (so they need styling again), or
    /// nil when none did.
    mutating func apply(editAt edited: NSRange, changeInLength delta: Int, in text: NSString) -> NSRange? {
        let length = text.length
        let location = min(edited.location, length)
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        tick = Candidate()
        tilde = Candidate()
        let oldScanned = scannedThrough
        // Nothing at or after the edited line was read: nothing there can be stale.
        guard lineStart < oldScanned else { return nil }

        // The state entering the line after the edited block, before and after.
        let blockEnd = NSMaxRange(text.lineRange(for: NSRange(location: location, length: min(edited.length, length - location))))
        let oldBlockEnd = blockEnd - delta
        let before: State? = oldBlockEnd < oldScanned ? knownState(at: oldBlockEnd) : nil

        // Forget everything from the edited line on; a fence that spans it is open again.
        var reopened: OpenFence?
        while let last = fences.last, NSMaxRange(last.range) > lineStart {
            fences.removeLast()
            if last.range.location < lineStart {
                reopened = OpenFence(start: last.range.location, openerEnd: last.openerEnd, character: last.character, length: last.length)
            }
        }
        if let current = open, current.start >= lineStart { open = nil }
        if let reopened { open = reopened }
        scannedThrough = lineStart

        let after = state(at: blockEnd, in: text)
        guard let before, before != after else { return nil }
        let end = min(length, max(blockEnd, oldScanned + delta))
        return NSRange(location: lineStart, length: end - lineStart)
    }

    // MARK: - Scanning

    /// Reads fence lines until the scan has passed `target`.
    private mutating func advance(past target: Int, in text: NSString) {
        let length = text.length
        while scannedThrough <= target, scannedThrough < length {
            guard let next = nextCandidate(from: scannedThrough, in: text) else {
                scannedThrough = length
                return
            }
            guard next.isMarker else {
                // No marker up to here: the state holds, so skip ahead. The next
                // search starts a few characters early (see `search`).
                scannedThrough = next.position
                continue
            }
            let line = text.lineRange(for: NSRange(location: next.position, length: 0))
            // No fence marker between here and that line: the state holds up to it.
            if line.location > target {
                scannedThrough = line.location
                return
            }
            read(line, in: text)
            scannedThrough = NSMaxRange(line)
        }
    }

    /// The nearest place at or after `position` where a run of three backticks
    /// or tildes may start; nil when there is none. A kind is searched for again
    /// only when its last answer is behind us.
    private mutating func nextCandidate(from position: Int, in text: NSString) -> Candidate? {
        if !tick.isExhausted, tick.isBehind(position) { search("```", from: position, in: text, into: &tick) }
        if !tilde.isExhausted, tilde.isBehind(position) { search("~~~", from: position, in: text, into: &tilde) }
        switch (tick.isExhausted, tilde.isExhausted) {
        case (true, true): return nil
        case (false, true): return tick
        case (true, false): return tilde
        case (false, false): return tick.position <= tilde.position ? tick : tilde
        }
    }

    private func search(_ marker: String, from position: Int, in text: NSString, into candidate: inout Candidate) {
        let remaining = text.length - position
        let window = min(Self.searchWindow, remaining)
        let found = text.range(of: marker, options: .literal, range: NSRange(location: position, length: window))
        if found.location != NSNotFound {
            candidate = Candidate(position: found.location, isMarker: true, isExhausted: false)
        } else if window == remaining {
            candidate = Candidate(position: position, isMarker: false, isExhausted: true)
        } else {
            // A fence marker starts within three spaces of its line, and the scan
            // resumes at a line that may start inside the window's last
            // characters: look again from four before its end.
            candidate = Candidate(position: position + window - 4, isMarker: false, isExhausted: false)
        }
    }

    private mutating func read(_ line: NSRange, in text: NSString) {
        guard let fence = Self.parseFenceLine(text, line: line) else { return }
        if let current = open {
            if fence.character == current.character, fence.length >= current.length, fence.restIsBlank {
                fences.append(Fence(
                    range: NSRange(location: current.start, length: NSMaxRange(line) - current.start),
                    openerEnd: current.openerEnd,
                    character: current.character,
                    length: current.length
                ))
                open = nil
            }
        } else if fence.canOpen {
            open = OpenFence(start: line.location, openerEnd: NSMaxRange(line), character: fence.character, length: fence.length)
        }
    }

    private static let backtick: unichar = 0x60
    private static let tilde: unichar = 0x7E

    private struct FenceLine {
        var character: unichar
        var length: Int
        var restIsBlank: Bool
        var restHasBacktick: Bool
        /// An opening fence's info string cannot hold a backtick when the fence is made of them.
        var canOpen: Bool { character == CodeEditorFenceIndex.tilde || !restHasBacktick }
    }

    /// The fence a line is: up to three spaces, then three or more of one fence character.
    private static func parseFenceLine(_ text: NSString, line: NSRange) -> FenceLine? {
        var index = line.location
        let end = NSMaxRange(line)
        while index < end, text.character(at: index) == CodeText.space, index - line.location < 4 { index += 1 }
        guard index - line.location <= 3, index < end else { return nil }
        let character = text.character(at: index)
        guard character == backtick || character == tilde else { return nil }
        var run = 0
        while index + run < end, text.character(at: index + run) == character { run += 1 }
        guard run >= 3 else { return nil }
        var blank = true
        var hasBacktick = false
        var rest = index + run
        while rest < end {
            let unit = text.character(at: rest)
            if unit == backtick { hasBacktick = true }
            if !CodeText.isBlank(unit), !CodeText.isLineBreak(unit) { blank = false }
            rest += 1
        }
        return FenceLine(character: character, length: run, restIsBlank: blank, restHasBacktick: hasBacktick)
    }
}
