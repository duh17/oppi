import Foundation
import Testing
@testable import Oppi

/// Which Markdown lines are inside a fenced code block (after the opening line,
/// through the closing line), and when an edit changes that for lines
/// something already asked about.
@Suite("Code editor fence index")
struct CodeEditorFenceIndexTests {
    /// Line starts as the index sees them: a line ends at \n, \r, or \r\n, and
    /// text that ends in a line break has an empty last line.
    private func lineStarts(_ text: String) -> [Int] {
        let ns = text as NSString
        var starts: [Int] = []
        var cursor = 0
        while cursor < ns.length {
            starts.append(cursor)
            cursor = NSMaxRange(ns.lineRange(for: NSRange(location: cursor, length: 0)))
        }
        if ns.length == 0 || CodeText.isLineBreak(ns.character(at: ns.length - 1)) { starts.append(ns.length) }
        return starts
    }

    /// Lines that are inside a fence, asking in the given order.
    private func insideLines(_ text: String, index: inout CodeEditorFenceIndex, askingInOrder order: [Int]? = nil) -> [Int] {
        let starts = lineStarts(text)
        var answers: [Int: Bool] = [:]
        for line in order ?? Array(starts.indices) { answers[line] = index.contains(starts[line], in: text as NSString) }
        return answers.filter(\.value).keys.sorted()
    }

    private func inside(_ text: String) -> [Int] {
        var index = CodeEditorFenceIndex()
        return insideLines(text, index: &index)
    }

    @Test func fenceLinesAndTheLinesBetweenAreInsideAndTheRestIsNot() {
        #expect(inside("a\n```swift\n- x\n```\nb\n~~~\n1. y\n~~~\nc") == [2, 3, 6, 7])
    }

    @Test func aFenceNeedsItsOwnCharacterAndAtLeastTheOpeningLengthToClose() {
        // ~~~ does not close ```, and a shorter run does not close a longer one.
        #expect(inside("````\n~~~\n```\nstill code\n````\nout") == [1, 2, 3, 4])
        // A closing fence has no info string, so this one stays open to the end.
        #expect(inside("```\ncode\n``` not a closer\nmore") == [1, 2, 3])
    }

    @Test func anUnclosedFenceRunsToTheEnd() {
        #expect(inside("a\n```\nb\nc") == [2, 3])
    }

    @Test func fenceMarkersThatAreNotFencesAreIgnored() {
        // Four spaces is an indented code block; backticks in an info string, and fewer than three, are text.
        #expect(inside("    ```\n``` a`b\ntext ```\n``\nx").isEmpty)
    }

    @Test func theAnswerDoesNotDependOnTheOrderOfTheQuestions() {
        let text = "a\n```\nb\n```\nc\n~~~\nd\n~~~\ne\n```\nf"
        let expected = inside(text)
        let lines = Array(lineStarts(text).indices)
        var backwards = CodeEditorFenceIndex()
        #expect(insideLines(text, index: &backwards, askingInOrder: lines.reversed()) == expected)
        var shuffled = CodeEditorFenceIndex()
        #expect(insideLines(text, index: &shuffled, askingInOrder: [7, 0, 10, 3, 5, 1, 9, 2, 8, 4, 6]) == expected)
    }

    @Test func aQueryNearTheTopOfALargeBufferScansOnlyAsFarAsItNeeds() {
        let group = "intro line\n```\ncode\n```\n- item\n"
        let text = String(repeating: group, count: 20_000)
        var index = CodeEditorFenceIndex()
        let first = index.contains(0, in: text as NSString)
        let inBody = index.contains(group.utf16.count - "- item\n".utf16.count - 6, in: text as NSString)
        #expect(!first && inBody)
        #expect(index.scannedThrough < 200, "asked about the first lines of a \(text.utf16.count)-character buffer, scanned \(index.scannedThrough)")
        // Asking far down scans to there and no further.
        let far = text.utf16.count / 2
        _ = index.contains(far, in: text as NSString)
        #expect(index.scannedThrough > far && index.scannedThrough < far + 200)
    }

    @Test func fencesAreFoundWhereverTheyStartRelativeToTheSearchWindow() {
        // The scan hops through fence-free text in bounded windows; a fence
        // (indented or not) starting at any offset around a window edge is still found.
        for filler in 16_300...16_420 {
            for indent in ["", "   "] {
                let text = String(repeating: "x", count: filler) + "\n\(indent)```\nbody\n\(indent)```\nafter\n"
                var forward = CodeEditorFenceIndex()
                var backward = CodeEditorFenceIndex()
                let lines = Array(lineStarts(text).indices)
                #expect(insideLines(text, index: &forward) == [2, 3], "filler \(filler), indent \(indent.count): forward")
                #expect(insideLines(text, index: &backward, askingInOrder: lines.reversed()) == [2, 3], "filler \(filler), indent \(indent.count): backward")
            }
        }
    }

    /// Edits `before` at `range`, with the index already asked about every line.
    private func edit(
        _ before: String, replacing range: NSRange, with replacement: String
    ) -> (stale: NSRange?, matchesFreshScan: Bool) {
        var index = CodeEditorFenceIndex()
        _ = insideLines(before, index: &index)
        let after = (before as NSString).replacingCharacters(in: range, with: replacement)
        let stale = index.apply(
            editAt: NSRange(location: range.location, length: replacement.utf16.count),
            changeInLength: replacement.utf16.count - range.length,
            in: after as NSString
        )
        return (stale, insideLines(after, index: &index) == inside(after))
    }

    @Test func editsThatLeaveEveryLinesAnswerAloneReportNothingStaleAndStillMatchAFreshScan() {
        let text = "intro\n```\ncode\n```\nout\n"
        // Prose, a stray single backtick, typing inside the fence body, and below it.
        for (range, replacement) in [
            (NSRange(location: 0, length: 0), "more "),
            (NSRange(location: 3, length: 0), "`"),
            (NSRange(location: 14, length: 0), "XY"),
            (NSRange(location: 10, length: 4), "other"),
            (NSRange(location: 22, length: 0), "tail"),
        ] {
            let result = edit(text, replacing: range, with: replacement)
            #expect(result.stale == nil, "\(replacement.debugDescription) at \(range.location) leaves the lines' answers alone")
            #expect(result.matchesFreshScan, "\(replacement.debugDescription) at \(range.location) keeps the index equal to a fresh scan")
        }
    }

    @Test func editsThatOpenCloseOrBreakAFenceReportTheLinesAfterThemAndStillMatchAFreshScan() {
        let text = "intro\n```\ncode\n```\nout\n"
        for (range, replacement, what) in [
            (NSRange(location: 6, length: 4), "", "deleting the opening line"),
            (NSRange(location: 15, length: 3), "", "deleting the closing fence"),
            (NSRange(location: 7, length: 1), "", "deleting a backtick from the opener"),
            (NSRange(location: 5, length: 1), "", "joining the intro to the opener"),
            (NSRange(location: 19, length: 0), "~~~\n", "opening a tilde fence"),
            (NSRange(location: 0, length: 0), "```\n", "opening a fence above"),
        ] {
            let result = edit(text, replacing: range, with: replacement)
            #expect(result.stale != nil, "\(what) changes the lines after it")
            #expect(result.matchesFreshScan, "\(what) keeps the index equal to a fresh scan")
        }
        // Typing the third backtick opens a fence.
        let typing = edit("``\nmore\n", replacing: NSRange(location: 2, length: 0), with: "`")
        #expect(typing.stale != nil && typing.matchesFreshScan)
    }

    @Test func onlyLinesSomethingAskedAboutAreReportedStale() {
        // Asked about the first lines only; an edit far below is not stale for anyone.
        let group = "intro\n```\ncode\n```\n"
        let text = String(repeating: group, count: 100)
        var index = CodeEditorFenceIndex()
        _ = index.contains(0, in: text as NSString)
        let far = text.utf16.count - 10
        let after = (text as NSString).replacingCharacters(in: NSRange(location: far, length: 0), with: "```\n")
        let farStale = index.apply(editAt: NSRange(location: far, length: 4), changeInLength: 4, in: after as NSString)
        #expect(farStale == nil)
        // Asked about everything: opening a fence at the top reports the span that was asked about.
        var asked = CodeEditorFenceIndex()
        _ = insideLines(text, index: &asked)
        let top = "```\n" + text
        let stale = asked.apply(editAt: NSRange(location: 0, length: 4), changeInLength: 4, in: top as NSString)
        #expect(stale?.location == 0)
        #expect((stale?.length ?? 0) >= text.utf16.count - 10)
    }

    /// Applies an edit to `index` the way the editor does; returns the new text
    /// and the lines reported stale.
    private func apply(
        _ index: inout CodeEditorFenceIndex, to before: String, replacing range: NSRange, with replacement: String
    ) -> (text: String, stale: NSRange?) {
        let after = (before as NSString).replacingCharacters(in: range, with: replacement)
        let stale = index.apply(
            editAt: NSRange(location: range.location, length: replacement.utf16.count),
            changeInLength: replacement.utf16.count - range.length,
            in: after as NSString
        )
        return (after, stale)
    }

    @Test func aFenceChangeAfterAnUnrelatedEditStillReportsEveryLineAlreadyAskedAbout() {
        // Every line was asked about. An edit that changes nothing leaves the scan
        // stopped at the marker-looking line after it, short of the last line, and
        // the next edit, which opens a fence, must still reach the last line.
        let text = "``\n- one\ntext```\n- two\n"
        var index = CodeEditorFenceIndex()
        _ = insideLines(text, index: &index)
        let unrelated = apply(&index, to: text, replacing: NSRange(location: 8, length: 0), with: "x")
        #expect(unrelated.stale == nil)
        let opened = apply(&index, to: unrelated.text, replacing: NSRange(location: 2, length: 0), with: "`")
        let twoStart = (opened.text as NSString).range(of: "- two").location
        #expect(opened.stale.map { NSMaxRange($0) > twoStart } == true, "stale \(String(describing: opened.stale)), the last asked line starts at \(twoStart)")
        var fresh = CodeEditorFenceIndex()
        #expect(insideLines(opened.text, index: &index) == insideLines(opened.text, index: &fresh))
    }

    @Test func aReturnThatSplitsALineEndingInAFenceMarkerOpensTheFence() {
        // "ab```" is text; after Return, "```" is a line of its own and opens a fence.
        let text = "ab```\n- item\nafter\n"
        var index = CodeEditorFenceIndex()
        _ = insideLines(text, index: &index)
        let split = apply(&index, to: text, replacing: NSRange(location: 2, length: 0), with: "\n")
        #expect(split.stale != nil, "the lines after the new fence line changed")
        var fresh = CodeEditorFenceIndex()
        #expect(insideLines(split.text, index: &index) == insideLines(split.text, index: &fresh))
    }

    @Test func undoingAJoinThatHidAFenceMarkerRestoresTheFence() {
        // "intro```" hides the opener; splitting it (what undoing the join does) restores a closed fence.
        let joined = "intro```\ncode\n```\nout\n"
        var index = CodeEditorFenceIndex()
        _ = insideLines(joined, index: &index)
        let undone = apply(&index, to: joined, replacing: NSRange(location: 5, length: 0), with: "\n")
        #expect(undone.stale != nil, "\"out\" is no longer inside a fence")
        var fresh = CodeEditorFenceIndex()
        #expect(insideLines(undone.text, index: &index) == insideLines(undone.text, index: &fresh))
    }

    @Test func aReplaceWalkDownTheBufferNeverReportsStaleAndStillMatchesAFreshScan() {
        // Find > Replace steps down a file one replacement at a time. Nothing
        // changes any line's answer, so no step may report stale lines.
        let group = "intro\n```\ncode item\n```\n- item here\nout\n"
        var text = String(repeating: group, count: 40)
        var index = CodeEditorFenceIndex()
        _ = insideLines(text, index: &index)
        let end = text.utf16.count
        var searchFrom = 0
        for step in 0..<20 {
            let match = (text as NSString).range(of: "item", range: NSRange(location: searchFrom, length: text.utf16.count - searchFrom))
            let result = apply(&index, to: text, replacing: match, with: "entries")
            #expect(result.stale == nil, "replace \(step) reported stale lines \(String(describing: result.stale))")
            text = result.text
            searchFrom = match.location + 7
        }
        #expect(index.scannedThrough == text.utf16.count, "the replacements did not cut the scan back (\(index.scannedThrough) of \(text.utf16.count), was \(end))")
        var fresh = CodeEditorFenceIndex()
        #expect(insideLines(text, index: &index) == insideLines(text, index: &fresh))
    }

    @Test func aFenceChangeAfterAnEditThatChangedNothingStillReportsEveryAskedLine() {
        let group = "intro\n```\ncode\n```\n- item\n"
        let text = String(repeating: group, count: 30)
        var index = CodeEditorFenceIndex()
        _ = insideLines(text, index: &index)
        let unrelated = apply(&index, to: text, replacing: NSRange(location: 2, length: 0), with: "x")
        #expect(unrelated.stale == nil)
        // Delete a closing fence far below: every line after it flips.
        let target = (unrelated.text as NSString).range(of: "```\n- item", range: NSRange(location: 400, length: 200))
        let broken = apply(&index, to: unrelated.text, replacing: NSRange(location: target.location, length: 3), with: "")
        #expect(broken.stale != nil && NSMaxRange(broken.stale!) >= broken.text.utf16.count - 12, "stale \(String(describing: broken.stale))")
        var fresh = CodeEditorFenceIndex()
        #expect(insideLines(broken.text, index: &index) == insideLines(broken.text, index: &fresh))
    }

    @Test func typingMoreOnAnOpenerRightAfterItOpenedTheFenceReportsNothingAgain() {
        // Open a fence above lines something asked about, then keep typing the
        // info string on the same line: only the first keystroke changes anything.
        let text = "``\n- item\n- more\n"
        var index = CodeEditorFenceIndex()
        _ = insideLines(text, index: &index)
        let opened = apply(&index, to: text, replacing: NSRange(location: 2, length: 0), with: "`")
        #expect(opened.stale != nil)
        let info = apply(&index, to: opened.text, replacing: NSRange(location: 3, length: 0), with: "s")
        #expect(info.stale == nil, "a second keystroke on the opener reported \(String(describing: info.stale))")
        let more = apply(&index, to: info.text, replacing: NSRange(location: 4, length: 0), with: "w")
        #expect(more.stale == nil)
        var fresh = CodeEditorFenceIndex()
        #expect(insideLines(more.text, index: &index) == insideLines(more.text, index: &fresh))
    }

    @Test func anEditBetweenACarriageReturnAndItsLineFeedKeepsTheLinesFenceMarker() {
        // Deleting the line feed of a CRLF fence line leaves "```\r" as a line of its own.
        let text = "a\r\n```\r\nbody\r\n```\r\nafter\r\n"
        var index = CodeEditorFenceIndex()
        _ = insideLines(text, index: &index)
        let lineFeed = (text as NSString).range(of: "```\r\nbody").location + 4
        let result = apply(&index, to: text, replacing: NSRange(location: lineFeed, length: 1), with: "")
        var fresh = CodeEditorFenceIndex()
        #expect(insideLines(result.text, index: &index) == insideLines(result.text, index: &fresh), "the opener's marker was lost")
    }

    // MARK: - Every single-character edit

    /// Line starts as the index sees them (a line ends at \n, \r, or \r\n).
    private func starts(of text: NSString) -> [Int] {
        var result: [Int] = []
        var cursor = 0
        while cursor < text.length {
            result.append(cursor)
            cursor = NSMaxRange(text.lineRange(for: NSRange(location: cursor, length: 0)))
        }
        return result
    }

    /// For a small corpus with both fence kinds, 0/3/4-space indents, info
    /// strings and CRLF: ask the first lines, then insert or delete each
    /// interesting character at every offset. The index must answer like a
    /// fresh scan, and the report must cover every asked line outside the
    /// edit whose answer changed.
    @Test func everySingleCharacterEditKeepsAnswersRightAndReportsEveryAskedLineThatChanged() {
        let corpus = "intro\r\n```swift\r\n- code\r\n```\n- item\n   ~~~ info\r\ntext\n~~~\r\n    ``` four\n```\n``` a`b\n> quote\r\n```\r\n- tail"
        let characters = ["`", "~", " ", "\n", "\r", "x"]
        var failures: [String] = []
        var edits = 0
        for askedLines in [3, Int.max] {
            var cases: [(NSRange, String)] = []
            let length = (corpus as NSString).length
            for offset in 0...length {
                for character in characters { cases.append((NSRange(location: offset, length: 0), character)) }
                if offset < length { cases.append((NSRange(location: offset, length: 1), "")) }
            }
            for (range, replacement) in cases {
                edits += 1
                let old = corpus as NSString
                var index = CodeEditorFenceIndex()
                let asked = Array(starts(of: old).prefix(askedLines))
                for start in asked { _ = index.contains(start, in: old) }
                let new = old.replacingCharacters(in: range, with: replacement) as NSString
                let delta = replacement.utf16.count - range.length
                let stale = index.apply(editAt: NSRange(location: range.location, length: replacement.utf16.count), changeInLength: delta, in: new)
                let label = "edit \(range) with \(replacement.debugDescription), asked \(asked.count) lines"

                var freshNew = CodeEditorFenceIndex()
                for start in starts(of: new) where index.contains(start, in: new) != freshNew.contains(start, in: new) {
                    failures.append("\(label): line at \(start) answers differently from a fresh scan")
                }
                // The asked lines outside the edit's own lines: block start/end in the old text.
                var blockStart = old.lineRange(for: NSRange(location: min(range.location, old.length), length: 0)).location
                if range.location > 0, old.character(at: range.location - 1) == 0x0D {
                    blockStart = old.lineRange(for: NSRange(location: range.location - 1, length: 0)).location
                }
                let blockEnd = NSMaxRange(old.lineRange(for: NSRange(location: min(NSMaxRange(range), old.length), length: 0)))
                var freshOld = CodeEditorFenceIndex()
                var freshNow = CodeEditorFenceIndex()
                for start in asked where start < blockStart || start >= blockEnd {
                    let now = start < blockStart ? start : start + delta
                    guard now < new.length else { continue }
                    if freshOld.contains(start, in: old) != freshNow.contains(now, in: new) {
                        if stale.map({ NSLocationInRange(now, $0) }) != true {
                            failures.append("\(label): asked line at \(start) (now \(now)) changed but the report was \(String(describing: stale))")
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) of \(edits) edits failed, first: \(failures.prefix(4))")
    }
}
