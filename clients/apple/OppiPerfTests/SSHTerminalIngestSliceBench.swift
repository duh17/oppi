import CoreFoundation
import Foundation
import Testing
@testable import Oppi

/// How long one burst of remote output holds the main thread.
///
/// A burst (`cat` of a big file, a TUI redraw storm, tmux reattach) lands in
/// `SSHTerminalEventQueue` while the main actor is busy. The bench queues 8 MiB
/// of CSI-heavy output in 32 KiB chunks (OpenSSH's maximum channel packet), a
/// title, and an exit status, then runs the real `SSHTerminalChannel.consume`
/// path until the exit status closes the channel.
///
/// A main-run-loop observer timestamps every run loop activity. The longest
/// gap between two activities, not counting the run loop's own sleep, is the
/// longest stretch the main thread ran without returning to the run loop:
/// no display-link frame, touch, or other source could run during it.
///
/// Output: SSH_TERMINAL_INGEST lines, METRIC ms for the longest main slice
/// and for the whole burst (median of runs).
@Suite("SSHTerminalIngestSliceBench", .tags(.perf), .serialized)
@MainActor
struct SSHTerminalIngestSliceBench {
    private static let geometry = SSHTerminalGeometry(columns: 120, rows: 80, cellWidth: 8, cellHeight: 17)
    private static let burstBytes = 8 * 1024 * 1024
    private static let chunkSize = 32 * 1024
    private static let runs = 7
    private static let title = "ingest-done"

    @Test func burstIngestMainSlice() async throws {
        let burst = Self.csiBurst()
        _ = try await Self.run(burst: burst)

        var samples: [Run] = []
        for _ in 0..<Self.runs { samples.append(try await Self.run(burst: burst)) }

        let slices = samples.map(\.maxSliceMs).sorted()
        let totals = samples.map(\.totalMs).sorted()
        let medianSlice = slices[slices.count / 2]
        let medianTotal = totals[totals.count / 2]
        print("SSH_TERMINAL_INGEST method=channel_consume workload=csi cols=\(Self.geometry.columns) rows=\(Self.geometry.rows) burst_bytes=\(burst.count) chunk_bytes=\(Self.chunkSize) runs=\(Self.runs)")
        print("SSH_TERMINAL_INGEST max_slice_ms median=\(Self.format(medianSlice)) min=\(Self.format(slices.first ?? 0)) max=\(Self.format(slices.last ?? 0))")
        print("SSH_TERMINAL_INGEST total_ms median=\(Self.format(medianTotal)) min=\(Self.format(totals.first ?? 0)) max=\(Self.format(totals.last ?? 0))")
        print("METRIC ssh_terminal_ingest_max_main_slice_ms=\(Self.format(medianSlice))")
        print("METRIC ssh_terminal_ingest_burst_total_ms=\(Self.format(medianTotal))")

        // Every byte was interpreted before the exit status closed the channel:
        // the title written after the burst published, and the status is the reason.
        let completed = samples.allSatisfy { $0.completed }
        #expect(completed)
    }

    private struct Run {
        var maxSliceMs: Double
        var totalMs: Double
        var completed: Bool
    }

    private static func run(burst: Data) async throws -> Run {
        let channel = try SSHTerminalChannel()
        channel.opened(IdleConnection())
        channel.engine.resize(geometry)
        let queue = SSHTerminalEventQueue(limit: 2 * burstBytes)
        queue.push(.data(Data("\u{1b}[?1049h".utf8)))
        var offset = burst.startIndex
        while offset < burst.endIndex {
            let end = min(offset + chunkSize, burst.endIndex)
            queue.push(.data(burst.subdata(in: offset..<end)))
            offset = end
        }
        queue.push(.data(Data("\u{1b}]2;\(title)\u{7}".utf8)))
        queue.push(.exitStatus(0))

        // Let the run loop settle so the first gap is the burst's own.
        try await Task.sleep(for: .milliseconds(50))
        let probe = MainSliceProbe()
        probe.start()
        let start = ContinuousClock.now
        await channel.consume(queue)
        let total = ContinuousClock.now - start
        // One more run loop turn closes the stretch that ran the last slice.
        try await Task.sleep(for: .milliseconds(20))
        let maxSlice = probe.stop()

        return Run(
            maxSliceMs: maxSlice,
            totalMs: milliseconds(total),
            completed: channel.title == title && channel.reason == "Shell exited with status 0."
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// About 8 MiB in the shape of the throughput bench's CSI workload: SGR
    /// stacks, 256-color and truecolor, underline color, cursor motion, erase,
    /// repeat, and mode toggles around short runs of text.
    private static func csiBurst() -> Data {
        var rng = SplitMix64(seed: 0x6F70_7069)
        let printable: [UInt8] = Array(0x20...0x7E) + [0x0A, 0x09]
        var out: [UInt8] = []
        out.reserveCapacity(burstBytes + 64)
        while out.count < burstBytes {
            switch rng.next() % 100 {
            case 0..<10:
                for _ in 0..<(Int(rng.next() % 72) + 1) {
                    out.append(printable[Int(rng.next() % UInt64(printable.count))])
                }
            case 10..<30: out += Array("\u{1b}[m\u{1b}[?1h\u{1b}[H".utf8)
            case 30..<40: out += Array("\u{1b}[1;2;3;4:3;31m".utf8)
            case 40..<50: out += Array("\u{1b}[38:5:24;48:2:125:136:147m".utf8)
            case 50..<60: out += Array("\u{1b}[58;5;44;2m".utf8)
            case 60..<80: out += Array("\u{1b}[m\u{1b}[10A\u{1b}[3E\u{1b}[2K".utf8)
            default: out += Array("\u{1b}[39m\u{1b}[10`a\u{1b}[100b\u{1b}[?1l".utf8)
            }
        }
        out += Array("\u{1b}[m".utf8)
        return Data(out)
    }
}

/// Longest main-thread stretch between two run loop activities, excluding
/// the run loop's sleep (before-waiting to after-waiting).
@MainActor
private final class MainSliceProbe {
    private var observer: CFRunLoopObserver?
    private var last: UInt64 = 0
    private var sleeping = false
    private var maxGap: UInt64 = 0

    func start() {
        last = DispatchTime.now().uptimeNanoseconds
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.note(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func note(_ activity: CFRunLoopActivity) {
        let now = DispatchTime.now().uptimeNanoseconds
        if !sleeping { maxGap = max(maxGap, now - last) }
        sleeping = activity == .beforeWaiting
        last = now
    }

    /// Milliseconds.
    func stop() -> Double {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        return Double(maxGap) / 1e6
    }
}

private struct IdleConnection: SSHTerminalConnection {
    func send(_ bytes: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        throw SSHConnectionError.notConnected
    }
    func checkAlive() async throws {}
    func close() {}
    func cancel() async {}
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
