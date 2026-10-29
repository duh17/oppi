import Foundation

/// Where fenced code blocks (``` or ~~~) are in a Markdown buffer. A fence
/// runs from its opening line to its closing line, or to the end of the text
/// when it never closes. A line is inside one when it comes after the opening
/// line, up to and including the closing line: such a line is code, whatever
/// it looks like. The opening line itself is entered from outside.
///
/// The index is the list of lines that open or close a fence, read lazily: a
/// question about an offset reads the text only up to that offset, hopping
/// between fence markers with native searches, and keeps what it found. An
/// edit replaces only the markers of the lines it touched. When the state
/// entering the line after them is unchanged, the markers after them are still
/// right and move along with the text, so typing and Replace do not make the
/// index read the rest of the buffer again.
struct CodeEditorFenceIndex {
    /// Whether a line is entered inside a fence, and which kind (a closing
    /// line must match the opening line's character and be at least as long).
    enum State: Equatable {
        case outside
        case inside(character: unichar, length: Int)
    }

    /// A line that opens or closes a fence.
    private struct Marker {
        var line: NSRange
        var opens: Bool
        /// The fence's character and length (the one being opened or closed).
        var character: unichar
        var length: Int

        /// The state after this line.
        var stateAfter: State { opens ? .inside(character: character, length: length) : .outside }
    }

    /// Sorted by line; covers the text before `scannedThrough`.
    private var markers: [Marker] = []
    /// Every line that starts before this offset has been read.
    private(set) var scannedThrough = 0
    /// The start of the farthest line anything asked about. It is shifted by
    /// edits, and never cut back when an edit discards what was read, so every
    /// paragraph built from an answer can still be reported.
    private(set) var askedThrough = 0
    private var tick = Candidate()
    private var tilde = Candidate()

    /// The next place each marker may be: a real hit, or the end of the window
    /// searched without finding one (searching is bounded, so a keystroke does
    /// not scan the rest of a large buffer for a marker that never occurs).
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
        askedThrough = max(askedThrough, offset)
        return resolve(at: offset, in: text) != .outside
    }

    private mutating func resolve(at offset: Int, in text: NSString) -> State {
        advance(past: offset, in: text)
        return knownState(at: offset)
    }

    /// Forgets everything read, keeping what was asked about.
    mutating func reset() {
        markers = []
        scannedThrough = 0
        tick = Candidate()
        tilde = Candidate()
    }

    /// The state entering the line that starts at `offset`, which the scan has
    /// already passed: the state after the last marker line that ends by then.
    private func knownState(at offset: Int) -> State {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(markers[mid].line) <= offset { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? .outside : markers[low - 1].stateAfter
    }

    /// First marker whose line ends after `offset`.
    private func firstMarker(endingAfter offset: Int) -> Int {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(markers[mid].line) <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// First marker whose line starts at or after `offset`.
    private func firstMarker(startingAtOrAfter offset: Int) -> Int {
        var low = 0
        var high = markers.count
        while low < high {
            let mid = (low + high) / 2
            if markers[mid].line.location < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: - Edits

    /// Brings the index up to date after text was replaced: `edited` is the
    /// new text's range, the text is `changeInLength` characters longer than
    /// before. Returns the range of lines whose answer may have changed and
    /// that something already asked about (so they need styling again), or
    /// nil when none did.
    mutating func apply(editAt edited: NSRange, changeInLength delta: Int, in text: NSString) -> NSRange? {
        let length = text.length
        let location = min(edited.location, length)
        let lineStart = text.lineRange(for: NSRange(location: location, length: 0)).location
        // The line holding the edit's last character: when the edit ends in a
        // line break that is the new line after it, so `blockEnd - changeInLength`
        // is a line boundary in the old text too.
        let editEnd = min(NSMaxRange(edited), length)
        let blockEnd = NSMaxRange(text.lineRange(for: NSRange(location: editEnd, length: 0)))
        let oldEditEnd = NSMaxRange(edited) - delta
        let oldBlockEnd = blockEnd - delta
        let oldScanned = scannedThrough
        tick = Candidate()
        tilde = Candidate()

        // Where the farthest asked line is now. One inside the replaced text is
        // gone; what is built there next asks again.
        if askedThrough >= oldEditEnd {
            askedThrough += delta
        } else if askedThrough >= location {
            askedThrough = lineStart
        }

        // Read up to the edited line if the scan had not got there: the text before it is unchanged.
        if oldScanned < lineStart { advance(past: lineStart - 1, in: text) }

        // The old state entering the line after the block, from the old markers.
        let oldTextRead = oldScanned >= length - delta
        let tailKnown = oldBlockEnd < oldScanned || oldTextRead
        let before: State? = tailKnown ? knownState(at: oldBlockEnd) : nil

        // The markers before the edited line stay; those on the block's lines are replaced.
        let headEnd = min(firstMarker(endingAfter: lineStart), markers.count)
        let tailStart = tailKnown ? max(headEnd, firstMarker(startingAtOrAfter: oldBlockEnd)) : markers.count
        let entering = headEnd > 0 ? markers[headEnd - 1].stateAfter : .outside
        let block = Self.scan(text, from: lineStart, to: blockEnd, entering: entering)

        if let before, before == block.state {
            // The state entering the line after the block is unchanged, so the
            // markers after it are still right: they only move with the text.
            markers.replaceSubrange(headEnd..<tailStart, with: block.markers)
            if delta != 0 {
                for index in (headEnd + block.markers.count)..<markers.count { markers[index].line.location += delta }
            }
            scannedThrough = max(blockEnd, oldScanned + delta)
            return nil
        }
        // Everything after the block was read under a different state, or never read.
        markers.replaceSubrange(headEnd..<markers.count, with: block.markers)
        scannedThrough = blockEnd
        guard askedThrough > lineStart else { return nil }
        let askedLineEnd = NSMaxRange(text.lineRange(for: NSRange(location: min(askedThrough, length), length: 0)))
        return NSRange(location: lineStart, length: min(length, max(blockEnd, askedLineEnd)) - lineStart)
    }

    // MARK: - Scanning

    /// The fence marker lines in `from..<to`, entering with `state`, and the
    /// state after them.
    private static func scan(_ text: NSString, from start: Int, to end: Int, entering state: State) -> (markers: [Marker], state: State) {
        var found: [Marker] = []
        var state = state
        var cursor = start
        var tickHit = -1
        var tildeHit = -1
        func search(_ marker: String, from position: Int) -> Int {
            let range = text.range(of: marker, options: .literal, range: NSRange(location: position, length: end - position))
            return range.location == NSNotFound ? Int.max : range.location
        }
        while cursor < end {
            if tickHit < cursor { tickHit = search("```", from: cursor) }
            if tildeHit < cursor { tildeHit = search("~~~", from: cursor) }
            let hit = min(tickHit, tildeHit)
            if hit == Int.max { break }
            let line = text.lineRange(for: NSRange(location: hit, length: 0))
            if let marker = marker(for: line, in: text, entering: state) {
                found.append(marker)
                state = marker.stateAfter
            }
            cursor = max(NSMaxRange(line), hit + 1)
        }
        return (found, state)
    }

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
            if let marker = Self.marker(for: line, in: text, entering: markers.last?.stateAfter ?? .outside) {
                markers.append(marker)
            }
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

    /// The marker a line is, given the state entering it: it opens a fence
    /// when outside one, closes the fence it is inside when it matches.
    private static func marker(for line: NSRange, in text: NSString, entering state: State) -> Marker? {
        guard let fence = parseFenceLine(text, line: line) else { return nil }
        switch state {
        case .inside(let character, let length):
            guard fence.character == character, fence.length >= length, fence.restIsBlank else { return nil }
            return Marker(line: line, opens: false, character: character, length: length)
        case .outside:
            guard fence.canOpen else { return nil }
            return Marker(line: line, opens: true, character: fence.character, length: fence.length)
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
