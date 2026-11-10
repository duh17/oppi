import Foundation
import Testing
@testable import Oppi

/// While a scroll gesture runs, the channel keeps the main actor for the pane
/// being scrolled: other panes' output and every history download wait, then
/// apply in order when the gesture ends, and a hold that grows past its cap
/// applies its oldest part in small slices instead of dropping any.
@Suite("Terminal scroll hold")
struct SSHTerminalScrollHoldTests {
    private typealias Item = SSHTerminalEventQueue.Item

    private func data(_ text: String, _ block: String) -> Item { .data(Data(text.utf8), block: block) }

    // MARK: - What waits

    @Test func onlyOutputOfPanesOffScreenAndHistoryWaitWhileScrolling() {
        let hold = SSHTerminalScrollHold()
        #expect(hold.shouldHold(data("x", "b"), presented: "a", scrolling: true))
        #expect(!hold.shouldHold(data("x", "a"), presented: "a", scrolling: true), "the pane being scrolled keeps parsing")
        #expect(!hold.shouldHold(data("x", "b"), presented: "a", scrolling: false), "nothing waits between gestures")
        #expect(hold.shouldHold(.snapshotRecords(Data([1]), block: "a"), presented: "a", scrolling: true), "even the shown pane's history waits")
        #expect(!hold.shouldHold(.snapshot(Data([1]), block: "b"), presented: "a", scrolling: true), "a screen to draw does not wait")
        #expect(!hold.shouldHold(.event(.data(Data([1]))), presented: nil, scrolling: true), "a shell's output is the pane on screen")
    }

    @Test func aPanesLaterItemsStayBehindItsHeldOnesEvenAfterTheGesture() {
        var hold = SSHTerminalScrollHold()
        hold.hold(data("one", "b"))
        #expect(hold.shouldHold(data("two", "b"), presented: "a", scrolling: false), "it must not overtake the held item")
        #expect(hold.shouldHold(data("two", "b"), presented: "b", scrolling: true), "nor when that pane is shown by now")
        #expect(hold.shouldHold(.snapshot(Data([1]), block: "b"), presented: "a", scrolling: false))
        #expect(!hold.shouldHold(data("other", "c"), presented: "a", scrolling: false), "another pane is free")
        _ = hold.popFirst()
        #expect(!hold.shouldHold(data("two", "b"), presented: "a", scrolling: false), "free once nothing of it is held")
    }

    @Test func anItemForTheWholeChannelHoldsEverythingBehindIt() {
        var hold = SSHTerminalScrollHold()
        #expect(!hold.shouldHold(.ended("over"), presented: "a", scrolling: true), "with nothing held, it applies at once")
        hold.hold(data("one", "b"))
        #expect(hold.shouldHold(.ended("over"), presented: "a", scrolling: false), "it stays behind what was held")
        hold.hold(.ended("over"))
        #expect(hold.shouldHold(data("late", "a"), presented: "a", scrolling: false), "and what follows it stays behind it")
    }

    @Test func aStatusEventBelongsToNoPaneAndNeverWaits() {
        var hold = SSHTerminalScrollHold()
        hold.hold(data("one", "b"))
        hold.hold(.ended("over"))
        #expect(!hold.shouldHold(.event(.writabilityChanged(true)), presented: "a", scrolling: true), "not even behind the stream's end")
    }

    @Test func aRunOfOnePanesOutputComesBackAsOneWriteInOrder() {
        var hold = SSHTerminalScrollHold()
        hold.hold(data("b1", "b"))
        hold.hold(data("c1", "c"))
        hold.hold(data("b2", "b"))
        hold.hold(.snapshotRecords(Data([9]), block: "b"))
        hold.hold(data("b3", "b"))
        #expect(hold.popFirstRun(maxBytes: 100) == data("b1b2", "b"), "b's output joins across c's, which stays put")
        #expect(hold.popFirstRun(maxBytes: 100) == data("c1", "c"))
        #expect(hold.popFirstRun(maxBytes: 100) == .snapshotRecords(Data([9]), block: "b"), "history stops the join")
        #expect(hold.popFirstRun(maxBytes: 100) == data("b3", "b"))
        #expect(hold.isEmpty && hold.bytes == 0)
    }

    @Test func aRunStopsAtTheWriteSize() {
        var hold = SSHTerminalScrollHold()
        hold.hold(data("aaaa", "b"))
        hold.hold(data("bbbb", "b"))
        hold.hold(data("cc", "b"))
        #expect(hold.popFirstRun(maxBytes: 6) == data("aaaa", "b"))
        #expect(hold.popFirstRun(maxBytes: 6) == data("bbbbcc", "b"))
    }

    @Test func itemsComeBackOldestFirstAndTheCountsFollow() {
        var hold = SSHTerminalScrollHold(capBytes: 10)
        hold.hold(data("aaaa", "b"))
        hold.hold(.snapshotRecords(Data(repeating: 0, count: 5), block: "c"))
        #expect(hold.bytes == 9 && !hold.isOverCap)
        hold.hold(data("zz", "b"))
        #expect(hold.bytes == 11 && hold.isOverCap)
        #expect(hold.popFirst() == data("aaaa", "b"))
        #expect(hold.popFirst() == .snapshotRecords(Data(repeating: 0, count: 5), block: "c"))
        #expect(hold.popFirst() == data("zz", "b"))
        #expect(hold.popFirst() == nil && hold.isEmpty && hold.bytes == 0)
        #expect(hold.totalHeldBytes == 11, "the total counts what was ever held")
    }

    // MARK: - The channel

    private struct IdleConnection: SSHTerminalConnection {
        func send(_ bytes: Data) async throws {}
        func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
        func run(_ command: String, input: Data) async throws -> SSHExecResult { throw SSHConnectionError.commandRequestRejected }
        func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream { throw SSHConnectionError.notConnected }
        func checkAlive() async throws {}
        func close() {}
        func cancel() async {}
    }

    @MainActor
    private static func lines(_ engine: SSHTerminalEngine) -> [String] {
        let frame = engine.frame()
        return frame.rows.prefix(frame.rows.count - frame.rowsBelowViewport)
            .map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    private func rig() throws -> (channel: SSHTerminalChannel, queue: SSHTerminalEventQueue, consumer: Task<Void, Never>) {
        let channel = try SSHTerminalChannel(answersTerminalQueries: false)
        channel.opened(IdleConnection())
        channel.present("a")
        let queue = SSHTerminalEventQueue()
        return (channel, queue, Task { @MainActor in await channel.consume(queue) })
    }

    @MainActor
    @Test func aPaneOffScreenWaitsForTheGestureWhileTheShownPaneKeepsParsing() async throws {
        let (channel, queue, consumer) = try rig()
        defer { channel.close(reason: "done") }
        channel.isScrollGestureActive = true
        queue.pushData(Data("b one\r\n".utf8), block: "b")
        queue.pushData(Data("b two\r\n".utf8), block: "b")
        queue.pushData(Data("a shown\r\n".utf8), block: "a")
        // The shown pane's line landing proves the burst was processed.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { Self.lines(channel.engine(for: "a")) == ["a shown"] })
        #expect(Self.lines(channel.engine(for: "b")).isEmpty, "held while the finger or the coasting is on the grid")
        #expect(channel.scrollHold.bytes == 14)

        // More for the same pane while it is held queues behind, in order.
        queue.pushData(Data("b three\r\n".utf8), block: "b")
        channel.isScrollGestureActive = false
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.lines(channel.engine(for: "b")) == ["b one", "b two", "b three"]
        }, "all of it, once the gesture ended, in the order it arrived: \(Self.lines(channel.engine(for: "b")))")
        #expect(channel.scrollHold.isEmpty)
        queue.end("done")
        await consumer.value
    }

    @MainActor
    @Test func aWritabilityEventDuringAGestureIsNotBlockedByHeldOutput() async throws {
        let (channel, queue, consumer) = try rig()
        defer { channel.close(reason: "done") }
        channel.isScrollGestureActive = true
        queue.pushData(Data("b one\r\n".utf8), block: "b")
        queue.push(.writabilityChanged(true))
        queue.pushData(Data("a shown\r\n".utf8), block: "a")
        // Behind a held barrier the shown pane's line would be held too.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { Self.lines(channel.engine(for: "a")) == ["a shown"] })
        #expect(channel.scrollHold.bytes == 7, "only the neighbour's output is held")
        channel.isScrollGestureActive = false
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { channel.scrollHold.isEmpty })
        queue.end("done")
        await consumer.value
    }

    /// A switch mid-gesture changes which pane is shown; what was held stays held
    /// in its order, and the pane just left is now the one that waits.
    @MainActor
    @Test func aPaneSwitchWhileOutputIsHeldKeepsEachPanesOrder() async throws {
        let (channel, queue, consumer) = try rig()
        defer { channel.close(reason: "done") }
        channel.isScrollGestureActive = true
        queue.pushData(Data("a1\r\n".utf8), block: "a")
        queue.pushData(Data("b1\r\n".utf8), block: "b")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { Self.lines(channel.engine(for: "a")) == ["a1"] })
        #expect(channel.scrollHold.bytes == 4)

        channel.present("b")
        queue.pushData(Data("b2\r\n".utf8), block: "b")
        queue.pushData(Data("a2\r\n".utf8), block: "a")
        // b is shown now, but its b1 is held, so b2 queues behind it; a waits.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { channel.scrollHold.bytes == 12 })
        #expect(Self.lines(channel.engine(for: "b")).isEmpty)

        channel.isScrollGestureActive = false
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            Self.lines(channel.engine(for: "b")) == ["b1", "b2"] && Self.lines(channel.engine(for: "a")) == ["a1", "a2"]
        }, "a: \(Self.lines(channel.engine(for: "a"))), b: \(Self.lines(channel.engine(for: "b")))")
        queue.end("done")
        await consumer.value
    }

    @MainActor
    @Test func aHistoryDownloadWaitsForTheGestureAndThenCompletesTheHistory() async throws {
        let (screen, records) = try snapshotParts(try ghosttySnapshot(of: numberedLines(4000, name: "a")))
        try #require(!records.isEmpty)
        let (channel, queue, consumer) = try rig()
        defer { channel.close(reason: "done") }
        channel.isScrollGestureActive = true
        queue.pushSnapshot(screen, block: "a")
        for record in records { queue.pushSnapshotRecords(record, block: "a") }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { channel.screenEngine(for: "a") != nil })
        #expect(!channel.scrollHold.isEmpty, "the records are held, the screen is not")

        channel.isScrollGestureActive = false
        #expect(await waitForMainActorCondition(timeout: .seconds(10)) { channel.scrollHold.isEmpty })
        let engine = channel.engine(for: "a")
        engine.scrollToRow(0)
        #expect(Self.lines(engine).first == "a line 0", "the whole history arrived")
        queue.end("done")
        await consumer.value
    }

    @MainActor
    @Test func pastTheCapTheOldestIsAppliedInSlicesAndNothingIsLost() async throws {
        let (channel, queue, consumer) = try rig()
        defer { channel.close(reason: "done") }
        channel.setScrollHoldCap(40)
        channel.isScrollGestureActive = true
        let names = (0..<12).map { String(format: "b%02d", $0) }
        for name in names { queue.pushData(Data("\(name) 12345\r\n".utf8), block: "b") }
        // 12 lines of 10 bytes against a cap of 40: the oldest went in during the gesture.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { Self.lines(channel.engine(for: "b")).count >= 8 })
        #expect(channel.scrollHold.bytes <= 40, "bounded while the gesture runs")
        #expect(Self.lines(channel.engine(for: "b")).first == "b00 12345", "oldest first")
        #expect(channel.isScrollGestureActive)

        channel.isScrollGestureActive = false
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { Self.lines(channel.engine(for: "b")).count == 12 })
        #expect(Self.lines(channel.engine(for: "b")) == names.map { "\($0) 12345" }, "every line, in order")
        queue.end("done")
        await consumer.value
    }

    /// A stream that ends mid-gesture still ends in its own words, after its panes'
    /// last output: nothing held is left behind when the terminal closes.
    @MainActor
    @Test func theStreamEndingMidGestureAppliesWhatWasHeldFirst() async throws {
        let (channel, queue, consumer) = try rig()
        channel.isScrollGestureActive = true
        queue.pushData(Data("b last words\r\n".utf8), block: "b")
        queue.end("stream over")
        await consumer.value
        #expect(!channel.connected)
        #expect(channel.reason == "stream over", "\(channel.reason)")
        #expect(channel.scrollHold.isEmpty, "everything held was applied before the close")
        #expect(channel.isScrollGestureActive, "the gesture itself was never touched")
    }
}
