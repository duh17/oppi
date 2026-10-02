import Foundation
import Testing
@testable import Oppi

private actor StreamSidecar {
    let data: Data
    var requests: [Range<Int>] = []
    init(_ text: String) { data = Data(text.utf8) }
    init(data: Data) { self.data = data }
    func fetch(_ range: Range<Int>) -> TerminalOutputRange {
        requests.append(range)
        return .init(data: data.subdata(in: range), start: range.lowerBound, end: range.upperBound)
    }
}

private actor StreamRangeGate {
    private var gate: CheckedContinuation<Void, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?
    var requests: [Range<Int>] = []
    func fetch(_ range: Range<Int>) async -> TerminalOutputRange {
        requests.append(range)
        if requests.count == 1 {
            await withCheckedContinuation { continuation in
                gate = continuation
                requestWaiter?.resume()
                requestWaiter = nil
            }
        }
        return .init(data: Data(repeating: 0x61, count: range.count), start: range.lowerBound, end: range.upperBound)
    }
    func waitForRequest() async {
        if gate != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func release() { gate?.resume(); gate = nil }
}

@Suite("Terminal byte stream owner") @MainActor
struct TerminalOutputStreamTests {
    private func chunk(_ offset: Int, _ bytes: Int, epoch: Int = 1) -> ToolOutputStreamChunk {
        .init(epoch: epoch, offset: offset, bytes: bytes)
    }

    @Test func contiguousDuplicatesAndWireByteCount() async {
        let sidecar = StreamSidecar("first\nsecond\n")
        let owner = TerminalOutputStream { await sidecar.fetch($0) }
        owner.receive(chunk(0, 6), output: "first\n")
        owner.receive(chunk(0, 6), output: "first\n")
        owner.receive(chunk(6, 7), output: "second\n")
        #expect(owner.cursor == 13)
        #expect(owner.state == .live)
        #expect(await sidecar.requests.isEmpty)
        owner.discard()
    }

    @Test(arguments: [Data([0x9b, 0x32, 0x4a, 0x78, 0x0a]), Data("�\n".utf8), Data("raw\n".utf8)])
    func lossyOrReplacementChunkUsesRawFileBytes(raw: Data) async throws {
        let sidecar = StreamSidecar(data: raw)
        let owner = TerminalOutputStream { await sidecar.fetch($0) }
        let decoded = raw == Data("raw\n".utf8) ? "wrong\n" : String(decoding: raw, as: UTF8.self)
        owner.receive(chunk(0, raw.count), output: decoded)
        #expect(owner.state == .resyncing)
        #expect(owner.cursor == 0)
        await owner.waitForRecovery()
        owner.finish(.init(epoch: 1, totalBytes: raw.count))
        let reference = try TerminalLogEngine()
        try reference.feed(raw)
        #expect(owner.formatted == (try reference.paint()))
        #expect(owner.cursor == raw.count)
        #expect(await sidecar.requests == [0..<raw.count])
    }

    @Test(arguments: [true, false])
    func short206RetriesWithoutFeedingPartialBytes(fileCatchesUp: Bool) async {
        actor Sidecar {
            var requests = 0
            let catchesUp: Bool
            init(_ catchesUp: Bool) { self.catchesUp = catchesUp }
            func fetch() -> TerminalOutputRange {
                requests += 1
                if catchesUp, requests == 3 { return .init(data: Data("full\n".utf8), start: 0, end: 5) }
                return .init(data: Data("bad".utf8), start: 0, end: 3)
            }
        }
        let sidecar = Sidecar(fileCatchesUp)
        let owner = TerminalOutputStream { _ in await sidecar.fetch() }
        owner.finish(.init(epoch: 1, totalBytes: 5))
        #expect(owner.state == .resyncing)
        await owner.waitForRecovery()
        #expect(await sidecar.requests == 3)
        #expect(owner.state == (fileCatchesUp ? .complete : .resyncFailed))
        #expect(owner.cursor == (fileCatchesUp ? 5 : 0))
        #expect(ANSIParser.strip(owner.formatted) == (fileCatchesUp ? "full\n" : ""))
    }

    @Test func gapQueuesLiveChunksAndFetchesExactRange() async {
        let sidecar = StreamSidecar("first\nsecond\nthird\n")
        let owner = TerminalOutputStream { await sidecar.fetch($0) }
        owner.receive(chunk(0, 6), output: "first\n")
        owner.receive(chunk(13, 6), output: "third\n")
        #expect(owner.state == .resyncing)
        owner.receive(chunk(19, 4), output: "end\n")
        await owner.waitForRecovery()
        owner.finish(.init(epoch: 1, totalBytes: 23))
        #expect(await sidecar.requests == [6..<13])
        #expect(owner.state == .complete)
        #expect(ANSIParser.strip(owner.formatted) == "first\nsecond\nthird\nend\n")
    }

    @Test func partialOverlapRefetchesFromZero() async {
        let sidecar = StreamSidecar("first\nsecond\n")
        let owner = TerminalOutputStream { await sidecar.fetch($0) }
        owner.receive(chunk(0, 6), output: "first\n")
        owner.receive(chunk(4, 9), output: "t\nsecond\n")
        #expect(owner.state == .resyncing)
        await owner.waitForRecovery()
        owner.finish(.init(epoch: 1, totalBytes: 13))
        #expect(await sidecar.requests == [0..<13])
        #expect(ANSIParser.strip(owner.formatted) == "first\nsecond\n")
    }

    @Test func epochResetDropsOldBytesAndOldEpoch() async {
        let sidecar = StreamSidecar("new\n")
        let owner = TerminalOutputStream { await sidecar.fetch($0) }
        owner.receive(chunk(0, 4), output: "old\n")
        owner.receive(chunk(0, 4, epoch: 2), output: "new\n")
        owner.receive(chunk(4, 6), output: "stale\n")
        owner.finish(.init(epoch: 1, totalBytes: 10))
        owner.finish(.init(epoch: 2, totalBytes: 4))
        #expect(owner.cursor == 4)
        #expect(ANSIParser.strip(owner.formatted) == "new\n")
        #expect(await sidecar.requests.isEmpty)
    }

    @Test func endGapAndAttachMarkerRecoverEvenWithoutNextOutput() async {
        let sidecar = StreamSidecar("first\nsecond\n")
        let owner = TerminalOutputStream { await sidecar.fetch($0) }
        owner.receive(chunk(0, 6), output: "first\n")
        owner.markReconnecting()
        #expect(owner.state == .resyncing)
        owner.receive(chunk(13, 0), output: "")
        await owner.waitForRecovery()
        #expect(owner.state == .live)
        #expect(await sidecar.requests == [6..<13])
        owner.finish(.init(epoch: 1, totalBytes: 13))
        #expect(owner.state == .complete)

        let endOnly = TerminalOutputStream { await sidecar.fetch($0) }
        endOnly.finish(.init(epoch: 1, totalBytes: 13))
        #expect(endOnly.state == .resyncing)
        await endOnly.waitForRecovery()
        #expect(endOnly.state == .complete)
        #expect(await sidecar.requests == [6..<13, 0..<13])
        #expect(ANSIParser.strip(endOnly.formatted) == "first\nsecond\n")
    }

    @Test func tailRecoveryIsBoundedAndOmissionStaysVisible() async {
        let text = String(repeating: "line\n", count: 900_000)
        let sidecar = StreamSidecar(text)
        let owner = TerminalOutputStream { await sidecar.fetch($0) }
        let size = text.utf8.count
        owner.receive(chunk(size, 0), output: "")
        await owner.waitForRecovery()
        #expect(await sidecar.requests == [(size - 4 * 1024 * 1024)..<size])
        #expect(owner.cursor == size)
        #expect(owner.omittedBytes > size - 4 * 1024 * 1024)
        #expect(owner.state == .tailResync(omittedBytes: owner.omittedBytes))
        owner.finish(.init(epoch: 1, totalBytes: size))
        #expect(owner.omittedBytes > 0)
        #expect(owner.formatted.split(separator: "\n", omittingEmptySubsequences: false).count <= 2000)
    }

    @Test func failedSidecarAndMalformedRangeStayVisible() async {
        struct Unavailable: Error {}
        let owner = TerminalOutputStream { _ in throw Unavailable() }
        owner.receive(chunk(10, 0), output: "")
        await owner.waitForRecovery()
        #expect(owner.state == .resyncFailed)
        #expect(owner.cursor == 0)
        #expect(owner.state.notice != nil)
        let malformed = TerminalOutputStream { range in
            .init(data: Data([65]), start: range.lowerBound, end: range.upperBound)
        }
        malformed.finish(.init(epoch: 1, totalBytes: 10))
        await malformed.waitForRecovery()
        #expect(malformed.state == .resyncFailed)
    }

    @Test func epochChangeDuringRecoveryCannotCommitStaleRange() async {
        let gate = StreamRangeGate()
        let owner = TerminalOutputStream { await gate.fetch($0) }
        owner.receive(chunk(10, 0), output: "")
        await gate.waitForRequest()
        let started = AsyncStream<Void>.makeStream()
        let settlement = Task { @MainActor in
            started.continuation.yield(())
            await owner.waitForRecovery()
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        owner.receive(chunk(0, 4, epoch: 2), output: "new\n")
        owner.finish(.init(epoch: 2, totalBytes: 4))
        await gate.release()
        await settlement.value
        started.continuation.finish()
        #expect(owner.epoch == 2)
        #expect(owner.cursor == 4)
        #expect(owner.state == .complete)
        #expect(ANSIParser.strip(owner.formatted) == "new\n")
    }

    @Test func reconnectCancelsFillBeforeFreshLossyChunkRecovery() async {
        actor Sidecar {
            let gate = StreamRangeGate()
            var requests: [Range<Int>] = []
            func fetch(_ range: Range<Int>) async -> TerminalOutputRange {
                requests.append(range)
                if requests.count == 1 { return await gate.fetch(range) }
                // Only the fresh one-byte span is currently servable. An old
                // high-water request gets a short 206, as a lagging file would.
                return .init(data: Data([0xFF]), start: 0, end: 1)
            }
        }
        let sidecar = Sidecar()
        let owner = TerminalOutputStream { await sidecar.fetch($0) }
        owner.receive(chunk(100, 0), output: "")
        await sidecar.gate.waitForRequest()
        owner.markReconnecting()
        owner.receive(chunk(0, 1), output: "\u{FFFD}")
        await sidecar.gate.release()
        await owner.waitForRecovery()
        #expect(await sidecar.requests == [0..<100, 0..<1])
        #expect(owner.cursor == 1)
        #expect(owner.state == .live)
        owner.finish(.init(epoch: 1, totalBytes: 1))
        #expect(owner.state == .complete)
    }

    @Test func recoveryQueueOverflowRefetchesDroppedChunks() async {
        let gate = StreamRangeGate()
        let owner = TerminalOutputStream { await gate.fetch($0) }
        owner.receive(chunk(10, 0), output: "")
        await gate.waitForRequest()
        let size = 64 * 1024
        for index in 0..<5 {
            owner.receive(chunk(10 + index * size, size), output: String(repeating: "a", count: size))
        }
        await gate.release()
        await owner.waitForRecovery()
        #expect(await gate.requests == [0..<10, 10..<(10 + 5 * size)])
        #expect(owner.cursor == 10 + 5 * size)
        #expect(owner.state == .live)
        owner.finish(.init(epoch: 1, totalBytes: owner.cursor))
        #expect(owner.state == .complete)
    }

    @Test func coalescerPreservesAtomicChunksAndLegacyReplaceBarrier() {
        let coalescer = DeltaCoalescer()
        var received: [ToolOutputEventPayload] = []
        coalescer.onFlush = { events in
            received += events.compactMap { if case .toolOutput(let payload) = $0 { payload } else { nil } }
        }
        let output = String(repeating: "x", count: DeltaCoalescer.maxBufferedBytesForTesting + 1)
        for (offset, mode) in [(0, ToolOutputMode.append), (output.utf8.count, .replace)] {
            coalescer.receive(.toolOutput(.init(sessionId: "s", toolEventId: "t", output: output, isError: false,
                mode: mode, outputStream: chunk(offset, output.utf8.count))))
        }
        coalescer.receive(.toolOutput(.init(sessionId: "s", toolEventId: "t", output: "", isError: false,
            outputStream: chunk(2 * output.utf8.count, 0))))
        coalescer.flushNow()
        #expect(received.count == 3)
        #expect(received.map(\.output) == [output, output, ""])
        #expect(received.map { $0.outputStream?.offset } == [0, output.utf8.count, 2 * output.utf8.count])
    }

    @Test func reducerRoutesToOneOwnerAndHistoryDiscardsIt() async throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: "arbitrary", args: [:],
            outputPresentation: .init(kind: "terminal")))
        reducer.processBatch([
            .toolOutput(.init(sessionId: "s", toolEventId: "t", output: "old\r", isError: false, outputStream: chunk(0, 4))),
            .toolOutput(.init(sessionId: "s", toolEventId: "t", output: "new\n", isError: false, outputStream: chunk(4, 4))),
            .toolEnd(sessionId: "s", toolEventId: "t", details: .object(["expandedText": .string("stale cumulative output")]),
                outputStream: .init(epoch: 1, totalBytes: 8))
        ])
        let owner = try #require(reducer.terminalOutputStreams.owner(for: "t"))
        #expect(reducer.toolOutputStore.fullOutput(for: "t").isEmpty)
        #expect(ANSIParser.strip(reducer.toolOutput(for: "t")) == "new\n")
        #expect(reducer.terminalOutputStreams.owner(for: "t") === owner)
        let item = try #require(reducer.items.first { $0.id == "t" })
        let inspection = try #require(reducer.toolInspection(for: item))
        guard case .terminal(let terminal) = inspection.output.first else { Issue.record("Expected terminal content"); return }
        #expect(ANSIParser.strip(terminal.output ?? "") == "new\n")
        reducer.reset()
        #expect(reducer.terminalOutputStreams.owner(for: "t") == nil)
    }

    @Test func streamMetadataDoesNotOverrideNonterminalPresentation() {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "t", tool: "arbitrary", args: [:],
            outputPresentation: .init(kind: "text")))
        reducer.process(.toolOutput(.init(sessionId: "s", toolEventId: "t", output: "ordinary", isError: false,
            outputStream: chunk(0, 8))))
        reducer.process(.toolEnd(sessionId: "s", toolEventId: "t", outputStream: .init(epoch: 1, totalBytes: 8)))
        #expect(reducer.terminalOutputStreams.owner(for: "t") == nil)
        #expect(reducer.toolOutputStore.fullOutput(for: "t") == "ordinary")
    }

    @Test func nestedTerminalCallKeepsItsOwnOwner() throws {
        let reducer = TimelineReducer()
        reducer.process(.toolStart(sessionId: "s", toolEventId: "parent", tool: "arbitrary", args: [:]))
        reducer.processBatch([
            .toolStart(sessionId: "s", toolEventId: "child", tool: "other", args: [:],
                outputPresentation: .init(kind: "terminal"), parentToolCallId: "parent"),
            .toolOutput(.init(sessionId: "s", toolEventId: "child", output: "child\n", isError: false,
                parentToolCallId: "parent", outputStream: chunk(0, 6))),
            .toolEnd(sessionId: "s", toolEventId: "child", parentToolCallId: "parent",
                outputStream: .init(epoch: 1, totalBytes: 6))
        ])
        let child = try #require(reducer.terminalOutputStreams.owner(for: "child"))
        #expect(child.state == .complete)
        #expect(ANSIParser.strip(child.formatted) == "child\n")
        #expect(reducer.terminalOutputStreams.owner(for: "parent") == nil)
        #expect(reducer.toolOutputStore.fullOutput(for: "child").isEmpty)
    }

    @Test(arguments: [true, false])
    func rangePastServableBytesRetriesVisiblyAndRemainsBounded(fileCatchesUp: Bool) async {
        actor LaggingSidecar {
            var requests = 0
            let fileCatchesUp: Bool
            init(fileCatchesUp: Bool) { self.fileCatchesUp = fileCatchesUp }
            func fetch(_ range: Range<Int>) throws -> TerminalOutputRange {
                requests += 1
                guard fileCatchesUp, requests == 3 else {
                    throw APIError.server(status: 416, message: "Range past servable bytes")
                }
                return .init(data: Data("done\n".utf8), start: 0, end: 5)
            }
        }
        let sidecar = LaggingSidecar(fileCatchesUp: fileCatchesUp)
        let owner = TerminalOutputStream { try await sidecar.fetch($0) }
        owner.finish(.init(epoch: 1, totalBytes: 5))
        #expect(owner.state == .resyncing)
        #expect(owner.state.notice != nil)
        await owner.waitForRecovery()
        #expect(await sidecar.requests == 3)
        if fileCatchesUp {
            #expect(owner.state == .complete)
            #expect(owner.cursor == 5)
            #expect(ANSIParser.strip(owner.formatted) == "done\n")
        } else {
            #expect(owner.state == .resyncFailed)
            #expect(owner.state.notice == "Terminal output resync failed")
            #expect(owner.cursor == 0)
        }
    }
}
