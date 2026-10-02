import Foundation
import GhosttyVt
import Testing
import UIKit
@testable import Oppi

@Suite("Interactive SSH terminal", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct SSHTerminalTests {
    @Test func clipboardSequencesHaveNoAuthority() throws {
        var sent = [Data]()
        let engine = try SSHTerminalEngine { sent.append($0) }
        UIPasteboard.general.string = "local-only"
        engine.receive(Data("\u{1b}]52;c;cmVtb3Rl\u{7}\u{1b}]52;c;?\u{7}\u{1b}]1337;Copy=cmVtb3Rl\u{7}\u{1b}]5522;type=read\u{7}".utf8))
        #expect(UIPasteboard.general.string == "local-only")
        #expect(sent.isEmpty)
    }

    @Test func statusAndDeviceRepliesReachTheSamePTYSinkInOrder() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.receive(Data("\u{1b}[6n\u{1b}[c\u{1b}[>c\u{1b}[=c\u{1b}[>q".utf8))
        #expect(String(decoding: sent, as: UTF8.self) == "\u{1b}[1;1R\u{1b}[?62;22c\u{1b}[>1;0;0c\u{1b}P!|00000000\u{1b}\\\u{1b}P>|Oppi\u{1b}\\")
    }

    @Test func titleIsDisplayOnlySanitizedAndCapped() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data(("\u{1b}]2;hello\t\u{202e}" + String(repeating: "x", count: 150) + "\u{7}").utf8))
        #expect(engine.title == "hello" + String(repeating: "x", count: 115))
    }

    @Test func closedEngineDropsLateRepliesAndInput() throws {
        var sent = [Data]()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.close()
        engine.receive(Data("\u{1b}[6n\u{1b}[c".utf8))
        #expect(sent.isEmpty)
        #expect(engine.key(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL)).isEmpty)
        #expect(throws: SSHTerminalError.self) { try engine.paste("late", confirmed: true) }
    }

    @Test func controlAndNavigationKeysUseTerminalModes() throws {
        let engine = try SSHTerminalEngine { _ in }
        #expect(engine.key(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL)) == Data([3]))
        #expect(engine.key(GHOSTTY_KEY_ESCAPE) == Data([27]))
        #expect(engine.key(GHOSTTY_KEY_TAB) == Data([9]))
        #expect(engine.key(GHOSTTY_KEY_ENTER) == Data([13]))
        #expect(engine.key(GHOSTTY_KEY_BACKSPACE) == Data([127]))
        for (key, letter) in [(GHOSTTY_KEY_ARROW_UP, "A"), (GHOSTTY_KEY_ARROW_DOWN, "B"),
                              (GHOSTTY_KEY_ARROW_RIGHT, "C"), (GHOSTTY_KEY_ARROW_LEFT, "D")] {
            #expect(engine.key(key) == Data("\u{1b}[\(letter)".utf8))
        }
        engine.receive(Data("\u{1b}[?1h".utf8))
        for (key, letter) in [(GHOSTTY_KEY_ARROW_UP, "A"), (GHOSTTY_KEY_ARROW_DOWN, "B"),
                              (GHOSTTY_KEY_ARROW_RIGHT, "C"), (GHOSTTY_KEY_ARROW_LEFT, "D")] {
            #expect(engine.key(key) == Data("\u{1b}O\(letter)".utf8))
        }
    }

    @Test func pasteRequiresConsentAndStripsControlInjection() throws {
        let engine = try SSHTerminalEngine { _ in }
        #expect(SSHTerminalEngine.pasteIsSafe("plain"))
        #expect(!SSHTerminalEngine.pasteIsSafe("echo a\necho b"))
        #expect(!SSHTerminalEngine.pasteIsSafe("\u{1b}[201~bad"))
        #expect(throws: SSHTerminalError.self) { try engine.paste("echo a\necho b", confirmed: false) }
        #expect(try engine.paste("a\nb\u{1b}c", confirmed: true) == Data("a\rb c".utf8))
    }

    @Test func pasteHonorsBracketedModeAndSizeLimit() throws {
        let engine = try SSHTerminalEngine { _ in }
        engine.receive(Data("\u{1b}[?2004h".utf8))
        #expect(try engine.paste("a\nb", confirmed: true) == Data("\u{1b}[200~a\nb\u{1b}[201~".utf8))
        #expect(try engine.paste("\u{1b}[201~bad", confirmed: true) == Data("\u{1b}[200~ [201~bad\u{1b}[201~".utf8))
        #expect(throws: SSHTerminalError.self) {
            try engine.paste(String(repeating: "x", count: SSHTerminalEngine.maximumPasteBytes + 1), confirmed: true)
        }
    }

    @Test func renderCopiesUnicodeColorsAndAlternateScreen() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 3)) { _ in }
        engine.receive(Data("\u{1b}[31m中e\u{301}".utf8))
        let original = engine.frame()
        #expect(original.rows[0][0].text == "中")
        #expect(original.rows[0][0].width == 2)
        #expect(original.rows[0][1].width == 0)
        #expect(original.rows[0][2].text == "e\u{301}")
        #expect(original.rows[0][0].foreground.r > original.rows[0][0].foreground.g)
        engine.receive(Data("\u{1b}[?1049h\u{1b}[Halt".utf8))
        #expect(engine.frame().rows[0][0].text == "a")
        #expect(original.rows[0][0].text == "中") // copied frame remains valid after mutation
        engine.receive(Data("\u{1b}[?1049l".utf8))
        #expect(engine.frame().rows[0][0].text == "中")
    }

    @Test func draggingHistoryDetachesUntilExplicitLive() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 10, rows: 2)) { _ in }
        engine.receive(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
        engine.scroll(rows: -2)
        let reading = engine.frame().rows[0].map(\.text).joined()
        engine.receive(Data("\r\nfive\r\nsix".utf8))
        #expect(!engine.following)
        #expect(engine.frame().rows[0].map(\.text).joined() == reading)
        engine.backToLive()
        #expect(engine.following)
        #expect(engine.frame().rows[1].map(\.text).joined() == "six")
    }

    @Test func synchronizedOutputHoldsOnlyPaintNotReplies() throws {
        var sent = Data()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.receive(Data("old\u{1b}[?2026h\rnew\u{1b}[6n".utf8))
        #expect(engine.frame().rows[0].prefix(3).map(\.text).joined() == "old")
        #expect(sent == Data("\u{1b}[1;4R".utf8))
        engine.receive(Data("\u{1b}[?2026l".utf8))
        #expect(engine.frame().rows[0].prefix(3).map(\.text).joined() == "new")
    }

    @Test func resizeUpdatesGridAndRemotePTYTogether() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        let target = SSHTerminalGeometry(columns: 42, rows: 13, cellWidth: 18, cellHeight: 34)
        channel.resize(.init(columns: 20, rows: 8))
        channel.resize(target)
        var resizes = fixture.resizes.makeAsyncIterator()
        #expect(await resizes.next() == target)
        let frame = channel.engine.frame()
        #expect(frame.rows.count == 13)
        #expect(frame.rows[0].count == 42)
        var sent = Data()
        let engine = try SSHTerminalEngine { sent.append($0) }
        engine.resize(target)
        engine.receive(Data("\u{1b}[18t\u{1b}[16t".utf8))
        #expect(sent == Data("\u{1b}[8;13;42t\u{1b}[6;34;18t".utf8))
        channel.close(reason: "done")
    }

    @Test func backpressurePreservesInputOrderWithinOneSession() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        channel.event(.writabilityChanged(false))
        channel.key(GHOSTTY_KEY_C, text: "c", modifiers: GhosttyMods(GHOSTTY_MODS_CTRL))
        channel.event(.data(Data("\u{1b}[6n".utf8)))
        #expect(await fixture.sentBytes.isEmpty)
        channel.event(.writabilityChanged(true))
        var bytes = fixture.bytes.makeAsyncIterator()
        #expect(await bytes.next() == Data([3]))
        #expect(await bytes.next() == Data("\u{1b}[1;1R".utf8))
        channel.close(reason: "done")
    }

    @Test func newerWritableEventWinsOverAnOlderSendRejection() async throws {
        let fixture = TerminalConnectionFixture(suspendFirstSend: true)
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        channel.send(Data("a".utf8))
        var attempts = fixture.attempts.makeAsyncIterator()
        #expect(await attempts.next() == Data("a".utf8))
        // The transport rejected the first attempt while not writable, but
        // resumes before its async rejection reaches the main-actor consumer.
        channel.event(.writabilityChanged(false))
        channel.event(.writabilityChanged(true))
        await fixture.rejectSuspendedSend()
        let received = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var bytes = fixture.bytes.makeAsyncIterator()
                return await bytes.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2)) // bounded failure oracle, not synchronization
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(received == Data("a".utf8))
        #expect(await fixture.sentBytes == Data("a".utf8))
        channel.close(reason: "done")
    }

    @Test func disconnectClearsBufferedInputAndLateOutputCannotReplay() async throws {
        let first = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(first)
        channel.event(.writabilityChanged(false))
        channel.key(GHOSTTY_KEY_A, text: "a")
        channel.event(.closed)
        channel.key(GHOSTTY_KEY_C, text: "c")
        channel.event(.data(Data("\u{1b}[6n".utf8)))
        channel.event(.writabilityChanged(true))
        #expect(channel.inputNotice.contains("Not sent"))
        #expect(!channel.connected)
        #expect(await first.sentBytes.isEmpty)
        let second = TerminalConnectionFixture()
        let fresh = try SSHTerminalChannel()
        fresh.opened(second)
        fresh.key(GHOSTTY_KEY_B, text: "b")
        var bytes = second.bytes.makeAsyncIterator()
        #expect(await bytes.next() == Data("b".utf8))
        #expect(await second.sentBytes == Data("b".utf8))
        fresh.close(reason: "done")
    }

    @Test func carriageReturnAndOtherControlPastesNeedConsentAndWriteNothing() async throws {
        let engine = try SSHTerminalEngine { _ in }
        #expect(!SSHTerminalEngine.pasteNeedsConfirmation("plain\ttabbed text"))
        for text in ["echo hi\r", "cd /tmp\rrm important-file\r", "a\u{3}b", "a\u{7f}b", "a\u{1b}[31mb"] {
            #expect(SSHTerminalEngine.pasteNeedsConfirmation(text))
            #expect(throws: SSHTerminalError.unsafePaste) { try engine.paste(text, confirmed: false) }
        }
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        #expect(throws: SSHTerminalError.unsafePaste) { try channel.paste("echo hi\r") }
        #expect(await fixture.sentBytes.isEmpty)
        try channel.paste("echo hi\r", confirmed: true)
        var bytes = fixture.bytes.makeAsyncIterator()
        #expect(await bytes.next() == Data("echo hi\r".utf8))
        channel.close(reason: "done")
    }

    @Test func ctrlLatchAppliesToTheNextKeyOnly() throws {
        var latch = SSHTerminalCtrlLatch()
        #expect(latch.take() == 0)
        latch.toggle()
        #expect(latch.armed)
        let engine = try SSHTerminalEngine { _ in }
        #expect(engine.key(GHOSTTY_KEY_C, text: "c", modifiers: latch.take()) == Data([3]))
        #expect(!latch.armed)
        #expect(engine.key(GHOSTTY_KEY_C, text: "c", modifiers: latch.take()) == Data("c".utf8))
        latch.toggle()
        latch.toggle()
        #expect(latch.take() == 0) // a second tap turns it off again
    }

    @Test func eofStopsInputThenExitStatusBecomesTheReason() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        channel.event(.writabilityChanged(false))
        channel.key(GHOSTTY_KEY_A, text: "a")
        channel.event(.eof)
        #expect(channel.connected) // still reading: a status may follow
        channel.key(GHOSTTY_KEY_C, text: "c")
        #expect(channel.inputNotice.contains("Not sent"))
        channel.event(.data(Data("\u{1b}[6n".utf8)))
        channel.event(.writabilityChanged(true))
        channel.event(.exitStatus(3))
        channel.event(.closed)
        #expect(!channel.connected)
        #expect(channel.reason == "Shell exited with status 3.")
        #expect(await fixture.sentBytes.isEmpty)
    }

    @Test func eofThenCloseWithoutStatusIsAConnectionLoss() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        channel.event(.eof)
        channel.event(.closed)
        #expect(channel.reason == "The SSH connection closed.")
    }

    @Test func consumerAppliesStatusThatFollowsEOFInTheSameStream() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let queue = SSHTerminalEventQueue()
        for event in [SSHPTYEvent.data(Data("bye".utf8)), .eof, .exitStatus(3), .closed] { queue.push(event) }
        await channel.consume(queue)
        #expect(channel.reason == "Shell exited with status 3.")
        #expect(channel.engine.frame().rows[0].prefix(3).map(\.text).joined() == "bye")
    }

    @Test func outputBurstBeyondTheCapFailsTheSessionAfterInterpretingAcceptedBytesInOrder() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture())
        let queue = SSHTerminalEventQueue(limit: 8)
        // The consumer has not run yet, as when the main actor is saturated.
        queue.push(.data(Data("one".utf8)))
        queue.push(.data(Data("two".utf8)))
        queue.push(.data(Data("three".utf8))) // 11 queued bytes would exceed 8
        queue.push(.data(Data("late".utf8)))
        queue.push(.closed)
        await channel.consume(queue)
        #expect(!channel.connected)
        #expect(channel.reason.contains("stopped consuming"))
        #expect(channel.engine.frame().rows[0].prefix(6).map(\.text).joined() == "onetwo")
    }

    @Test func touchesBecomeMouseReportsOnlyWhileTheAppAsksForThem() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 20, rows: 10)) { _ in }
        #expect(!engine.mouseTracking)
        #expect(engine.mouse(.click, column: 3, row: 2).isEmpty)
        // Herdr's own request: normal + button + any-event tracking, SGR format.
        engine.receive(Data("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h".utf8))
        #expect(engine.mouseTracking)
        #expect(engine.mouse(.click, column: 3, row: 2) == Data("\u{1b}[<0;4;3M\u{1b}[<0;4;3m".utf8))
        #expect(engine.mouse(.wheelUp, column: 0, row: 0) == Data("\u{1b}[<64;1;1M".utf8))
        #expect(engine.mouse(.wheelDown, column: 99, row: 99) == Data("\u{1b}[<65;20;10M".utf8)) // clamped
        engine.receive(Data("\u{1b}[?1003l\u{1b}[?1002l\u{1b}[?1000l".utf8))
        #expect(engine.mouse(.click, column: 3, row: 2).isEmpty)
    }

    @Test func startupCommandExitIsReportedAsTheCommandNotTheShell() throws {
        let channel = try SSHTerminalChannel()
        channel.opened(TerminalConnectionFixture(), command: "herdr")
        channel.event(.exitStatus(0))
        #expect(channel.reason == "`herdr` exited with status 0.")
    }

    @Test func herdrSnapshotStatusAndFailuresAreRead() throws {
        let json = #"{"id":"cli:api:snapshot","result":{"snapshot":{"agents":[{"agent":"pi","agent_status":"blocked","focused":false,"pane_id":"w1:p2","revision":3,"tab_id":"w1:t1","terminal_id":"t","workspace_id":"w1","terminal_title_stripped":"pi - dotfiles"},{"name":"rev","agent_status":"compacting","focused":true,"pane_id":"w2:p1","revision":1,"tab_id":"w2:t1","terminal_id":"u","workspace_id":"w2"}],"tabs":[{"agent_status":"unknown","focused":true,"label":"1","number":1,"pane_count":1,"tab_id":"w1:t1","workspace_id":"w1"}],"workspaces":[{"active_tab_id":"w1:t1","agent_status":"blocked","focused":true,"label":"dotfiles","number":1,"pane_count":1,"tab_count":1,"workspace_id":"w1"}]},"type":"session_snapshot"}}"#
        let snapshot = try HerdrRemote.snapshot(from: .init(output: Data(json.utf8), errorOutput: Data(), exitStatus: 0))
        #expect(snapshot.needsAttention == 1)
        #expect(snapshot.agents(in: snapshot.workspaces[0]).map(\.displayName) == ["pi"])
        #expect(snapshot.agents[1].status == .unknown) // a newer state does not break decoding
        #expect(snapshot.tabLabel("w1:t1") == "1")

        #expect(throws: HerdrRemoteError.notInstalled) {
            try HerdrRemote.snapshot(from: .init(output: Data(), errorOutput: Data("fish: Unknown command: herdr".utf8), exitStatus: 127))
        }
        let refused = #"{"id":"x","error":{"code":"server_not_running","message":"no herdr server is running"}}"#
        #expect(throws: HerdrRemoteError.rejected("no herdr server is running")) {
            try HerdrRemote.snapshot(from: .init(output: Data(refused.utf8), errorOutput: Data(), exitStatus: 1))
        }
        #expect(HerdrRemote.focusCommand(.agent("w1:p2")) == "herdr agent focus w1:p2")
        #expect(HerdrRemote.focusCommand(.workspace("w1; rm -rf ~")) == nil)
    }

    @Test func pasteLineCountIgnoresATrailingTerminator() {
        #expect(SSHTerminalEngine.pasteLineCount("echo one\recho two\r") == 2)
        #expect(SSHTerminalEngine.pasteLineCount("echo one\necho two\n") == 2)
        #expect(SSHTerminalEngine.pasteLineCount("a\r\nb\r\n") == 2)
        #expect(SSHTerminalEngine.pasteLineCount("a\rb\nc") == 3)
        #expect(SSHTerminalEngine.pasteLineCount("echo hi\r") == 1)
        #expect(SSHTerminalEngine.pasteLineCount("plain") == 1)
    }

    @Test func queuedOutputChunksAreInterpretedAsOneTerminalWriteAndTitlePublishes() async throws {
        let fixture = TerminalConnectionFixture()
        let channel = try SSHTerminalChannel()
        channel.opened(fixture)
        var resizes = fixture.resizes.makeAsyncIterator()
        _ = await resizes.next() // the coalesced opening resize has been applied
        let queue = SSHTerminalEventQueue()
        for chunk in 0..<50 { queue.push(.data(Data("line \(chunk)\r\n".utf8))) }
        queue.push(.data(Data("\u{1b}]2;built\u{7}".utf8)))
        queue.push(.exitStatus(0))
        let before = channel.engine.changeCount
        await channel.consume(queue)
        #expect(channel.engine.changeCount - before == 1) // 51 chunks, one vt write
        #expect(channel.title == "built")
        #expect(channel.reason == "Shell exited with status 0.")
    }

    @Test func keyRepeaterRepeatsUntilStoppedOrTheActionDeclines() async throws {
        let repeater = SSHTerminalKeyRepeater(initialDelay: .milliseconds(30), interval: .milliseconds(5))
        let (ticks, tickSink) = AsyncStream<Int>.makeStream()
        var count = 0
        repeater.start {
            count += 1
            tickSink.yield(count)
            return true
        }
        #expect(count == 0) // nothing before the initial delay
        var iterator = ticks.makeAsyncIterator()
        while let value = await iterator.next(), value < 3 {}
        repeater.stop()
        let stoppedAt = count
        try await Task.sleep(for: .milliseconds(60))
        #expect(count == stoppedAt)

        var declined = 0
        repeater.start { declined += 1; return declined < 2 }
        try await Task.sleep(for: .milliseconds(120))
        #expect(declined == 2) // a false return ends the repeat
        repeater.stop()
    }

    @Test func disconnectedInputAndOversizedQueueAreVisiblyRefused() async throws {
        let channel = try SSHTerminalChannel()
        channel.key(GHOSTTY_KEY_A, text: "a")
        #expect(channel.inputNotice.contains("disconnected"))
        let fixture = TerminalConnectionFixture()
        channel.opened(fixture)
        channel.event(.writabilityChanged(false))
        channel.send(Data(repeating: 1, count: SSHTerminalChannel.maximumQueuedBytes + 1))
        #expect(channel.inputNotice.contains("full"))
        #expect(await fixture.sentBytes.isEmpty)
        channel.close(reason: "done")
    }
}

private actor TerminalConnectionFixture: SSHTerminalConnection {
    nonisolated let bytes: AsyncStream<Data>
    nonisolated let resizes: AsyncStream<SSHTerminalGeometry>
    nonisolated let attempts: AsyncStream<Data>
    private let byteSink: AsyncStream<Data>.Continuation
    private let resizeSink: AsyncStream<SSHTerminalGeometry>.Continuation
    private let attemptSink: AsyncStream<Data>.Continuation
    private var suspendFirstSend: Bool
    private var suspendedSend: CheckedContinuation<Void, any Error>?
    private(set) var sentBytes = Data()

    init(suspendFirstSend: Bool = false) {
        (bytes, byteSink) = AsyncStream.makeStream()
        (resizes, resizeSink) = AsyncStream.makeStream()
        (attempts, attemptSink) = AsyncStream.makeStream()
        self.suspendFirstSend = suspendFirstSend
    }
    func send(_ data: Data) async throws {
        if suspendFirstSend {
            suspendFirstSend = false
            try await withCheckedThrowingContinuation { continuation in
                suspendedSend = continuation
                attemptSink.yield(data)
            }
        }
        sentBytes.append(data)
        byteSink.yield(data)
    }
    func rejectSuspendedSend() {
        suspendedSend?.resume(throwing: SSHPTYSessionError.notWritable)
        suspendedSend = nil
    }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        resizeSink.yield(.init(columns: columns, rows: rows,
                              cellWidth: pixelWidth / columns, cellHeight: pixelHeight / rows))
    }
    func run(_ command: String) async throws -> SSHExecResult { throw SSHPTYSessionError.commandRequestRejected }
    func cancel() {
        suspendedSend?.resume(throwing: SSHPTYSessionError.connectionClosed)
        suspendedSend = nil
        byteSink.finish()
        resizeSink.finish()
        attemptSink.finish()
    }
}
