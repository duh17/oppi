import Foundation
import Testing
@testable import Oppi

/// Which Markdown lines are inside a fenced code block (after the opening line,
/// through the closing line), and when an edit changes that for lines
/// something already asked about.
@Suite("Code editor fence index")
struct CodeEditorFenceIndexTests {
    private func lineStarts(_ text: String) -> [Int] {
        var starts: [Int] = []
        var start = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            starts.append(start)
            start += line.utf16.count + 1
        }
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
}
