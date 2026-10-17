import Foundation
import GhosttyVt
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal touch", .serialized)
@MainActor
struct SSHTerminalTouchTests {
    @Test func altScrollIsAltScreenWithoutMouseWhenMode1007IsOn() {
        let cases: [(alt: Bool, mouse: Bool, mode: Bool, expected: SSHTerminalScrollAction)] = [
            (false, false, false, .history),
            (false, false, true, .history),
            (false, true, false, .mouseWheel),
            (false, true, true, .mouseWheel),
            (true, false, false, .history),
            (true, false, true, .alternateKeys),
            (true, true, false, .mouseWheel),
            (true, true, true, .mouseWheel),
        ]
        for item in cases {
            #expect(
                SSHTerminalScrollAction.resolve(
                    altScreen: item.alt, mouseReporting: item.mouse, alternateScroll: item.mode
                ) == item.expected,
                "alt=\(item.alt) mouse=\(item.mouse) 1007=\(item.mode)"
            )
        }
    }

    @Test func longPressDragIsMouseOnlyWhileTheAppReports() {
        #expect(SSHTerminalDragTarget.resolve(mouseReporting: false) == .selection)
        #expect(SSHTerminalDragTarget.resolve(mouseReporting: true) == .mouse)
    }

    @Test func wheelScalingEmitsOneNotchPerThreeCellsAndKeepsRemainder() {
        var wheel = SSHTerminalWheelScaling.Accumulator()
        let cell: CGFloat = 17
        #expect(SSHTerminalWheelScaling.cellsPerEvent == 3)
        // Finger down 3 cells: one wheel-up (negative steps).
        #expect(wheel.steps(travel: 3 * cell, cellHeight: cell) == -1)
        // Another 2 cells: not yet a notch.
        #expect(wheel.steps(travel: 2 * cell, cellHeight: cell) == 0)
        // 1 more: second notch.
        #expect(wheel.steps(travel: 1 * cell, cellHeight: cell) == -1)
        // Reverse 3 cells: one wheel-down.
        #expect(wheel.steps(travel: -3 * cell, cellHeight: cell) == 1)
    }

    @Test func appScrollOffsetDeltaMatchesPanFingerTravelAndWheelSteps() {
        let cell: CGFloat = 17
        let travel = SSHTerminalAppScrollTranslation.fingerTravel(
            previousOffset: 400, currentOffset: 400 - 3 * cell
        )
        #expect(travel == 3 * cell, "finger down decreases offset")
        var wheel = SSHTerminalWheelScaling.Accumulator()
        #expect(wheel.steps(travel: travel, cellHeight: cell) == -1)

        var fling = SSHTerminalWheelScaling.Accumulator()
        var total = 0
        var offset: CGFloat = 800
        // Decelerating offsets like a native fling (offset falling toward 0).
        for delta in [50, 30, 18, 10, 6, 3, 1] as [CGFloat] {
            let next = offset - delta
            total += fling.steps(
                travel: SSHTerminalAppScrollTranslation.fingerTravel(
                    previousOffset: offset, currentOffset: next
                ),
                cellHeight: cell
            )
            offset = next
        }
        #expect(total < 0, "a downward fling keeps emitting wheel-up steps")
        #expect(abs(total) >= 2, "the fling spans more than one notch")
    }

    @Test func scrollCoalescingConcatenatesOneWrite() {
        #expect(SSHTerminalScrollCoalescing.encodeRepeated(0) { Data([1]) } == Data())
        #expect(SSHTerminalScrollCoalescing.encodeRepeated(3) { Data([0x1B, 0x4D]) } == Data([0x1B, 0x4D, 0x1B, 0x4D, 0x1B, 0x4D]))
    }

    @Test func mode1007DefaultsOnAndFollowsGhosttyAltScrollRules() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine(geometry: .init(columns: 20, rows: 8)) { sent.append($0) }
        #expect(engine.alternateScroll)
        #expect(!engine.alternateScreen)
        #expect(engine.scrollAction == .history)

        engine.receive(Data("\u{1b}[?1049h".utf8))
        #expect(engine.alternateScreen)
        #expect(engine.scrollAction == .alternateKeys)

        engine.receive(Data("\u{1b}[?1007l".utf8))
        #expect(!engine.alternateScroll)
        #expect(engine.scrollAction == .history)

        engine.receive(Data("\u{1b}[?1007h\u{1b}[?1000h\u{1b}[?1006h".utf8))
        #expect(engine.mouseTracking)
        #expect(engine.scrollAction == .mouseWheel)

        engine.receive(Data("\u{1b}[?1000l".utf8))
        #expect(engine.scrollAction == .alternateKeys)
        #expect(sent.isEmpty)
    }

    @Test func libghosttyWordSelectionKeepsAPathTogether() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine(geometry: .init(columns: 40, rows: 3)) { sent.append($0) }
        engine.receive(Data("see /usr/local/bin/thing now".utf8))
        let path = try #require(engine.selectWord(column: 10, row: 0))
        #expect(path.text == "/usr/local/bin/thing")
        #expect(!path.spans.isEmpty)
        let word = try #require(engine.selectWord(column: 1, row: 0))
        #expect(word.text == "see")
        #expect(sent.isEmpty)
    }

    @Test func libghosttyWordSelectionKeepsAURLTogether() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine(geometry: .init(columns: 80, rows: 2)) { sent.append($0) }
        engine.receive(Data("go https://example.com/a/b?x=1 now".utf8))
        let url = try #require(engine.selectWord(column: 10, row: 0))
        #expect(url.text == "https://example.com/a/b?x=1")
        let word = try #require(engine.selectWord(column: 1, row: 0))
        #expect(word.text == "go")
        #expect(sent.isEmpty)
    }

    @Test func longPressDragSelectsARangeWithoutWritingTheHost() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine(geometry: .init(columns: 20, rows: 3, cellWidth: 8, cellHeight: 16)) {
            sent.append($0)
        }
        engine.receive(Data("alpha beta".utf8))
        // Ghostty includes a cell only once the drag is past that cell's
        // midpoint, so land past the last letter of "beta".
        engine.beginSelection(column: 0, row: 0, surfacePoint: CGPoint(x: 1, y: 8))
        let snapshot = try #require(engine.dragSelection(column: 9, row: 0, surfacePoint: CGPoint(x: 79, y: 8)))
        #expect(snapshot.text == "alpha beta")
        engine.endSelection(column: 9, row: 0)
        #expect(sent.isEmpty)
    }

    @Test func mouseReportingEncodesPressMotionReleaseNotSelection() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 20, rows: 10)) { _ in }
        #expect(engine.mouse(.press, column: 3, row: 2).isEmpty)
        engine.receive(Data("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h".utf8))
        #expect(engine.mouse(.press, column: 3, row: 2) == Data("\u{1b}[<0;4;3M".utf8))
        #expect(engine.mouse(.motion, column: 4, row: 3) == Data("\u{1b}[<32;5;4M".utf8))
        #expect(engine.mouse(.release, column: 4, row: 3) == Data("\u{1b}[<0;5;4m".utf8))
        #expect(SSHTerminalDragTarget.resolve(mouseReporting: engine.mouseTracking) == .mouse)
    }

    @Test func localCopyIgnoresTheRemoteClipboardGate() throws {
        let channel = try SSHTerminalChannel()
        // Not opened, not viewed: OSC 52 would be dropped.
        UIPasteboard.general.string = "local-only"
        channel.copyLocalSelection("/usr/local/bin/thing")
        #expect(UIPasteboard.general.string == "/usr/local/bin/thing")
        #expect(channel.copies == 1)
        #expect(channel.lastCopyLength == "/usr/local/bin/thing".count)
    }

    @Test func scrollToRowPinsFollowingAtTheLiveEnd() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 2)) { _ in }
        engine.receive(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
        engine.scrollToRow(0)
        #expect(!engine.following)
        let top = engine.frame().rows[0].map(\.text).joined()
        engine.backToLive()
        #expect(engine.following)
        #expect(engine.frame().rows[0].map(\.text).joined() != top)
        let bar = engine.scrollbar
        #expect(bar.len == 2)
        #expect(bar.total >= bar.len)
    }

    @Test func secondTapCopiesTheTap1SnapshotAndSkipsTheTapAction() {
        var sequence = SSHTerminalTapSequence()
        let first = SSHTerminalSelectionSnapshot(
            text: "/usr/local/bin/thing",
            spans: [SSHTerminalSelectionSpan(row: 0, startColumn: 4, endColumn: 22)]
        )
        let later = SSHTerminalSelectionSnapshot(
            text: "other",
            spans: [SSHTerminalSelectionSpan(row: 3, startColumn: 0, endColumn: 4)]
        )
        #expect(sequence.recognize(location: CGPoint(x: 40, y: 8), time: 1, snapshot: first) == .firstTap)
        #expect(sequence.pendingSnapshot?.text == first.text)
        #expect(sequence.recognize(location: CGPoint(x: 42, y: 9), time: 1.12, snapshot: later) == .secondTap)
        #expect(sequence.takePendingSnapshot()?.text == first.text)
        #expect(sequence.pendingSnapshot == nil)
        #expect(sequence.recognize(location: CGPoint(x: 40, y: 8), time: 2, snapshot: later) == .firstTap)
    }

    @Test func secondTapDoesNotToggleKeyboardAndCopiesTheTap1Word() throws {
        let channel = try SSHTerminalChannel()
        UIPasteboard.general.string = ""
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        grid.tapTypesInTerminal = true
        let mounted = try MountedTouchGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        channel.engine.receive(Data("see /usr/local/bin/thing now".utf8))
        let word = try #require(channel.engine.selectWord(column: 10, row: 0))
        #expect(word.text == "/usr/local/bin/thing")
        let point = try mounted.point(column: 10, row: 0)
        #expect(!grid.isFirstResponder)
        grid.handleTap(at: point, now: 10)
        #expect(grid.isFirstResponder, "tap 1 raises the keyboard")
        grid.handleTap(at: point, now: 10.1)
        #expect(grid.isFirstResponder, "tap 2 must not hide the keyboard")
        #expect(UIPasteboard.general.string == "/usr/local/bin/thing")
    }

    @Test func secondTapSkipsMouseClickAndKeyboardToggleActions() {
        #expect(
            SSHTerminalTapAction.resolve(
                terminalTyping: true, keyboardUp: true, otherInputFocused: false, appWantsClicks: true
            ) == .mouseClick
        )
        #expect(
            SSHTerminalTapAction.resolve(
                terminalTyping: true, keyboardUp: false, otherInputFocused: false, appWantsClicks: false
            ) == .typeInTerminal
        )
        var sequence = SSHTerminalTapSequence()
        let word = SSHTerminalSelectionSnapshot(text: "WORD", spans: [])
        #expect(sequence.recognize(location: .zero, time: 1, snapshot: word) == .firstTap)
        #expect(sequence.recognize(location: .zero, time: 1.1, snapshot: word) == .secondTap)
        #expect(sequence.takePendingSnapshot()?.text == "WORD")
    }

    @Test func followChromeHidesTheButtonWithoutWritingFollowOutsideHistory() {
        #expect(SSHTerminalFollowChrome.showsBackToLive(scrollAction: .history, following: false))
        #expect(!SSHTerminalFollowChrome.showsBackToLive(scrollAction: .history, following: true))
        #expect(!SSHTerminalFollowChrome.showsBackToLive(scrollAction: .alternateKeys, following: false))
        #expect(!SSHTerminalFollowChrome.showsBackToLive(scrollAction: .mouseWheel, following: false))
    }

    @Test func backToLiveFollowSurvivesLessAndASecondFlick() throws {
        let channel = try SSHTerminalChannel()
        var reports: [Bool] = []
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { reports.append($0) })
        let mounted = try MountedTouchGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let engine = channel.engine
        engine.receive(Data((1...120).map { "line \($0)\r\n" }.joined().utf8))
        engine.scrollToRow(0)
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        #expect(!engine.following)
        #expect(reports.last == false, "detach shows Back to Live")

        engine.receive(Data("\u{1b}[?1049h".utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        #expect(engine.scrollAction == .alternateKeys)
        #expect(!engine.following, "less must not write follow state")
        #expect(reports.last == true, "less hides the button")

        if let scroll = grid.subviews.compactMap({ $0 as? UIScrollView }).first {
            grid.scrollViewDidScroll(scroll)
            grid.scrollViewDidEndDecelerating(scroll)
        }
        #expect(!engine.following, "alt-screen scroll callbacks must not mark following")

        engine.receive(Data("\u{1b}[?1049l".utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        #expect(engine.scrollAction == .history)
        #expect(!engine.following)
        #expect(reports.last == false, "quit less keeps Back to Live")

        grid.backToLive()
        #expect(engine.following)
        #expect(reports.last == true)

        engine.scrollToRow(0)
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        #expect(!engine.following)
        #expect(reports.last == false, "flick after Back to Live shows the button again")
    }

    @Test func historyContentHeightReachesLiveWithAFractionalRow() {
        let cell: CGFloat = 17
        let bounds: CGFloat = 24 * cell + 8.5
        let height = SSHTerminalHistoryLayout.contentHeight(
            boundsHeight: bounds, totalRows: 100, viewportRows: 24, cellHeight: cell
        )
        #expect(height - bounds == (100 - 24) * cell)
    }

    @Test func historyScrollRangeReachesLiveWithAFractionalGridHeight() throws {
        let channel = try SSHTerminalChannel()
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedTouchGrid(grid, height: 24 * 17 + 8.5)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        channel.engine.receive(Data((1...80).map { "row \($0)\r\n" }.joined().utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        let scroll = try #require(grid.subviews.compactMap { $0 as? UIScrollView }.first)
        let bar = channel.engine.scrollbar
        let cellHeight = SSHTerminalCellMetrics.codeFont().cellSize.height
        let extra = CGFloat(max(0, Int(bar.total) - Int(bar.len)))
        #expect(extra > 0)
        #expect(scroll.contentSize.height > 0)
        let expected = SSHTerminalHistoryLayout.contentHeight(
            boundsHeight: scroll.bounds.height,
            totalRows: Int(bar.total),
            viewportRows: Int(bar.len),
            cellHeight: cellHeight
        )
        #expect(abs(scroll.contentSize.height - expected) < 0.6)
    }

    @Test func longPressTapIgnoreClearsWhenTheTapFailedOrTheNextTouchBegins() {
        var ignore = SSHTerminalTapIgnore()
        ignore.arm()
        let first = ignore.consumeTap()
        let second = ignore.consumeTap()
        #expect(first)
        #expect(!second)

        ignore.arm()
        ignore.longPressEnded(tapFailed: true)
        let afterFailedTap = ignore.consumeTap()
        #expect(!afterFailedTap, "failed tap recognizer clears the sticky ignore")

        ignore.arm()
        ignore.longPressEnded(tapFailed: false)
        let lateTap = ignore.consumeTap()
        #expect(lateTap, "a late tap from the same press is still eaten")

        ignore.arm()
        ignore.touchBegan()
        let afterNextTouch = ignore.consumeTap()
        #expect(!afterNextTouch, "the next touch begin must not eat that tap")
    }

    @Test func localCopyClipsOnAUTF8Boundary() {
        #expect(SSHTerminalCopyLimit.clip("héllo", maxBytes: 1) == "h")
        #expect(SSHTerminalCopyLimit.clip("héllo", maxBytes: 2) == "h")
        #expect(SSHTerminalCopyLimit.clip("héllo", maxBytes: 3) == "hé")
        #expect(SSHTerminalCopyLimit.clip("é", maxBytes: 1).isEmpty)
        let over = String(repeating: "é", count: 8)
        let clipped = SSHTerminalCopyLimit.clip(over, maxBytes: 9)
        #expect(clipped.utf8.count == 8)
        #expect(clipped == String(repeating: "é", count: 4))
    }

    @Test func wordCopyDropsOneTrailingColonUnlessPortOrIPv6() throws {
        #expect(SSHTerminalWordCopy.normalize("src/x.swift:42:") == "src/x.swift:42")
        #expect(SSHTerminalWordCopy.normalize("error:") == "error")
        #expect(SSHTerminalWordCopy.normalize("https://example.com:8080") == "https://example.com:8080")
        #expect(SSHTerminalWordCopy.normalize("https://example.com:8080:") == "https://example.com:8080:")
        #expect(SSHTerminalWordCopy.normalize("fe80::") == "fe80::")
        #expect(SSHTerminalWordCopy.normalize("2001:db8::1") == "2001:db8::1")

        var sent = Data()
        let engine = try SSHTerminalEngine(geometry: .init(columns: 40, rows: 2)) { sent.append($0) }
        engine.receive(Data("src/x.swift:42:".utf8))
        let path = try #require(engine.selectWord(column: 2, row: 0))
        #expect(path.text == "src/x.swift:42")
        engine.receive(Data("\r\nerror:".utf8))
        let label = try #require(engine.selectWord(column: 1, row: 1))
        #expect(label.text == "error")
        #expect(sent.isEmpty)
    }

    @Test func modeSwitchDropsOldOffsetAsTravel() {
        var acc = SSHTerminalAppScrollAccumulator()
        acc.lastOffset = 0
        let cell: CGFloat = 17
        acc.consume(offset: 5000, cellHeight: cell, action: .alternateKeys, wheelCell: nil)
        #expect(acc.pendingAltRows != 0, "a stale history offset would inject arrows")
        acc.reseed(offset: 400)
        #expect(acc.takeFlush(action: .alternateKeys).altRows == 0)
        acc.consume(offset: 400, cellHeight: cell, action: .alternateKeys, wheelCell: nil)
        #expect(acc.takeFlush(action: .alternateKeys).altRows == 0)

        acc.lastOffset = 0
        acc.consume(offset: 5000, cellHeight: cell, action: .mouseWheel, wheelCell: (4, 4))
        #expect(acc.pendingWheelSteps != 0)
        acc.reseed(offset: 400)
        #expect(acc.takeFlush(action: .mouseWheel).wheelSteps == 0)
    }

    @Test func flushDropsQueuedStepsWhenTheActionChanged() {
        var acc = SSHTerminalAppScrollAccumulator()
        acc.pendingAltRows = 40
        acc.pendingWheelSteps = -12
        acc.pendingWheelCell = (column: 3, row: 5)
        let asHistory = acc.takeFlush(action: .history)
        #expect(asHistory.altRows == 0)
        #expect(asHistory.wheelSteps == 0)

        acc.pendingAltRows = 40
        acc.pendingWheelSteps = -12
        acc.pendingWheelCell = (column: 3, row: 5)
        let asWheel = acc.takeFlush(action: .mouseWheel)
        #expect(asWheel.wheelSteps == -12)
        #expect(asWheel.altRows == 0)
        #expect(asWheel.wheelCell.column == 3)
        #expect(asWheel.wheelCell.row == 5)

        acc.pendingAltRows = 7
        acc.pendingWheelSteps = 4
        let asAlt = acc.takeFlush(action: .alternateKeys)
        #expect(asAlt.altRows == 7)
        #expect(asAlt.wheelSteps == 0)
    }

    @Test func wheelCellSticksThroughDeceleration() {
        var acc = SSHTerminalAppScrollAccumulator()
        acc.lastOffset = 800
        acc.consume(offset: 749, cellHeight: 17, action: .mouseWheel, wheelCell: (1, 2))
        acc.consume(offset: 700, cellHeight: 17, action: .mouseWheel, wheelCell: nil)
        #expect(acc.pendingWheelCell?.column == 1)
        #expect(acc.pendingWheelCell?.row == 2)
        let flush = acc.takeFlush(action: .mouseWheel)
        #expect(flush.wheelCell.column == 1)
        #expect(flush.wheelCell.row == 2)
    }

    @Test func touchDownClearsQueuedFlingSteps() {
        var acc = SSHTerminalAppScrollAccumulator()
        acc.pendingWheelSteps = 4
        acc.pendingAltRows = -3
        acc.cancelQueuedSteps()
        #expect(acc.takeFlush(action: .mouseWheel).wheelSteps == 0)
        acc.pendingAltRows = -3
        acc.cancelQueuedSteps()
        #expect(acc.takeFlush(action: .alternateKeys).altRows == 0)
    }

    @Test func panSlopSeedsUncountedFingerTravel() {
        #expect(
            SSHTerminalAppScrollSlop.uncountedTravel(
                panTranslationY: 10, firstTouchY: 20, panLocationY: 30
            ) == 10
        )
        #expect(
            SSHTerminalAppScrollSlop.uncountedTravel(
                panTranslationY: 0, firstTouchY: 20, panLocationY: 32
            ) == 12
        )
        #expect(
            SSHTerminalAppScrollSlop.uncountedTravel(
                panTranslationY: 0, firstTouchY: nil, panLocationY: 32
            ) == 0
        )
        let cell: CGFloat = 17
        var acc = SSHTerminalAppScrollAccumulator()
        let offset: CGFloat = 400
        let slop = SSHTerminalAppScrollSlop.uncountedTravel(
            panTranslationY: 10, firstTouchY: nil, panLocationY: 0
        )
        acc.reseed(offset: offset + slop)
        acc.consume(offset: offset - 41, cellHeight: cell, action: .alternateKeys, wheelCell: nil)
        #expect(
            acc.takeFlush(action: .alternateKeys).altRows == -3,
            "10 pt slop plus 41 pt tracked is three rows, not two"
        )
    }

    @Test func modeChangeDuringDragDoesNotEmitInTheNewMode() throws {
        let channel = try SSHTerminalChannel()
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedTouchGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let engine = channel.engine
        engine.receive(Data((1...300).map { "line \($0)\r\n" }.joined().utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        let scroll = try #require(grid.subviews.compactMap { $0 as? UIScrollView }.first)
        let began = scroll.contentOffset.y
        #expect(began > 200, "live history offset must be large enough to inject")
        #expect(channel.inputNotice.isEmpty)

        grid.scrollViewWillBeginDragging(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: began - 80), animated: false)
        grid.scrollViewDidScroll(scroll)

        engine.receive(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        #expect(engine.scrollAction == .mouseWheel)
        grid.scrollViewDidScroll(scroll)

        // UIScrollView can write the drag-began offset back after a mode
        // switch, then keep applying the same finger. That delta must not
        // become wheel steps; the next touch starts fresh.
        scroll.setContentOffset(CGPoint(x: 0, y: began), animated: false)
        grid.scrollViewDidScroll(scroll)
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, began - 240)), animated: false)
        grid.scrollViewDidScroll(scroll)
        grid.scrollViewDidEndDragging(scroll, willDecelerate: false)
        #expect(
            !channel.inputNotice.contains("Not sent"),
            "a drag that crosses a mode change must not emit wheel steps: \(channel.inputNotice)"
        )
    }

    @Test func historyFlingDoesNotBecomeKeysWhenTheRemoteEntersAltOrMouse() throws {
        let channel = try SSHTerminalChannel()
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedTouchGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let engine = channel.engine
        engine.receive(Data((1...300).map { "line \($0)\r\n" }.joined().utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        let scroll = try #require(grid.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(scroll.contentOffset.y > 200, "live history offset must be large enough to inject")
        let liveOffset = engine.scrollbar.offset
        #expect(channel.inputNotice.isEmpty)

        engine.receive(Data("\u{1b}[?1049h".utf8))
        #expect(engine.scrollAction == .alternateKeys)
        grid.scrollViewDidScroll(scroll)
        grid.scrollViewDidEndDecelerating(scroll)
        #expect(
            !channel.inputNotice.contains("Not sent"),
            "history fling must not become arrows: \(channel.inputNotice)"
        )

        engine.receive(Data("\u{1b}[?1049l".utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        #expect(engine.scrollAction == .history)
        #expect(engine.scrollbar.offset == liveOffset, "leaving less restores the same history row")
        engine.receive(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        #expect(engine.scrollAction == .mouseWheel)
        grid.scrollViewDidScroll(scroll)
        grid.scrollViewDidEndDecelerating(scroll)
        #expect(
            !channel.inputNotice.contains("Not sent"),
            "history fling must not become wheel reports: \(channel.inputNotice)"
        )
        #expect(engine.scrollbar.offset == liveOffset, "mouse mode must not rewrite history")
    }

    @Test func quittingAltOrMouseMidFlingDoesNotJumpHistory() throws {
        let channel = try SSHTerminalChannel()
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedTouchGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let engine = channel.engine
        engine.receive(Data((1...300).map { "line \($0)\r\n" }.joined().utf8))
        engine.scrollToRow(0)
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        let scroll = try #require(grid.subviews.compactMap { $0 as? UIScrollView }.first)
        #expect(engine.scrollbar.offset == 0)

        engine.receive(Data("\u{1b}[?1049h".utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        #expect(engine.scrollAction == .alternateKeys)
        #expect(scroll.contentSize.height > scroll.bounds.height * 8)
        engine.receive(Data("\u{1b}[?1049l".utf8))
        #expect(engine.scrollAction == .history)
        grid.scrollViewDidScroll(scroll)
        grid.scrollViewDidEndDecelerating(scroll)
        #expect(engine.scrollbar.offset == 0, "quitting less must not jump history")
        #expect(
            !channel.inputNotice.contains("Not sent"),
            "pending arrows must not reach the shell: \(channel.inputNotice)"
        )

        engine.receive(Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        #expect(engine.scrollAction == .mouseWheel)
        engine.receive(Data("\u{1b}[?1000l".utf8))
        #expect(engine.scrollAction == .history)
        grid.scrollViewDidScroll(scroll)
        grid.scrollViewDidEndDecelerating(scroll)
        #expect(engine.scrollbar.offset == 0, "leaving mouse reporting must not jump history")
        #expect(!channel.inputNotice.contains("Not sent"))
    }

    @Test func touchDownDropsQueuedFlingStepsBeforeFlush() throws {
        let channel = try SSHTerminalChannel()
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedTouchGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        channel.engine.receive(Data("\u{1b}[?1049h".utf8))
        grid.setNeedsLayout()
        grid.layoutIfNeeded()
        let scroll = try #require(grid.subviews.compactMap { $0 as? UIScrollView }.first)
        let mid = scroll.contentOffset.y
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, mid - 200)), animated: false)
        grid.scrollViewDidScroll(scroll)
        grid.scrollViewWillBeginDragging(scroll)
        grid.scrollViewDidEndDragging(scroll, willDecelerate: false)
        #expect(
            !channel.inputNotice.contains("Not sent"),
            "touch-down must drop queued arrows: \(channel.inputNotice)"
        )
    }
}

@MainActor
private final class MountedTouchGrid {
    let window: UIWindow
    let grid: SSHTerminalGridView

    init(_ grid: SSHTerminalGridView, height: CGFloat = 844) throws {
        self.grid = grid
        let host = UIViewController()
        grid.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: host.view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func point(column: Int, row: Int) throws -> CGPoint {
        let cell = SSHTerminalCellMetrics.codeFont().cellSize
        #expect(cell.width > 0 && cell.height > 0)
        return CGPoint(
            x: cell.width * CGFloat(column) + cell.width / 2,
            y: cell.height * CGFloat(row) + cell.height / 2
        )
    }

    func dismiss() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
