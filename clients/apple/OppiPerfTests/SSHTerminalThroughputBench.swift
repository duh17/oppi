import Foundation
import Testing
@testable import Oppi

/// Headless VT ingest throughput: how fast the SSH terminal turns remote bytes
/// into terminal state, with no rendering. Six workloads modeled on kitty's
/// `kitten __benchmark__` (ASCII, Unicode, unique multi-codepoint cells, CSI,
/// Kitty images, long OSC strings) so results line up with published terminal
/// comparisons. The corpus is generated here from a fixed seed, not copied
/// from kitty, so byte streams match kitty's in shape, not byte for byte.
///
/// Engine-agnostic by construction: the bench only speaks bytes in through
/// `SSHTerminalEngine.receive` and a DSR reply out through the engine's sink.
/// It never touches the VT library behind the engine, so the same numbers stay
/// comparable if that library is rebuilt with other options or replaced.
///
/// Each run builds a fresh 120x80 engine (untimed), enters the alternate screen
/// like the kitten does, feeds the workload block repeatedly in 32 KiB writes
/// (OpenSSH's maximum channel packet) until 256 MiB, then sends DSR `CSI 5n`.
/// The clock stops when the `CSI 0n` reply arrives, which proves the engine
/// parsed every byte before it. Throughput is MiB/s (2^20 bytes), the unit
/// the kitten prints as "MB/s".
///
/// Output: SSH_TERMINAL_THROUGHPUT lines and METRIC MiB/s per workload.
@Suite("SSHTerminalThroughputBench", .tags(.perf), .serialized)
@MainActor
struct SSHTerminalThroughputBench {
    enum Workload: String, CaseIterable, CustomTestStringConvertible {
        case ascii
        case unicode
        case uniqueUnicode = "unique_unicode"
        case csi
        case images
        case longEscapeCodes = "long_escape_codes"

        var testDescription: String { rawValue }
    }

    private static let geometry = SSHTerminalGeometry(columns: 120, rows: 80, cellWidth: 8, cellHeight: 17)
    private static let bytesPerRun = 256 * 1024 * 1024
    private static let warmupBytes = 16 * 1024 * 1024
    private static let writeSize = 32 * 1024
    private static let runs = 7

    private static let alternateScreen = Data("\u{1b}[?1049h".utf8)
    /// Written between block repetitions, as the kitten resets between reps.
    private static let repetitionReset = Data("\u{1b}[m\u{1b}[H\u{1b}[2J".utf8)
    private static let statusRequest = Data("\u{1b}[5n".utf8)
    private static let statusOK = Data("\u{1b}[0n".utf8)

    @Test(arguments: Workload.allCases)
    func ingestThroughput(_ workload: Workload) throws {
        let block = Corpus.block(for: workload)
        _ = try Self.run(block: block, totalBytes: Self.warmupBytes)

        var samples: [Run] = []
        for _ in 0..<Self.runs {
            samples.append(try Self.run(block: block, totalBytes: Self.bytesPerRun))
        }

        let rates = samples.map(\.mibPerSecond).sorted()
        let median = rates[rates.count / 2]
        let initMs = samples.map(\.initMs).sorted()[samples.count / 2]
        let fed = samples[0].bytes
        print("SSH_TERMINAL_THROUGHPUT method=headless_receive workload=\(workload.rawValue) cols=\(Self.geometry.columns) rows=\(Self.geometry.rows) block_bytes=\(block.count) bytes_per_run=\(fed) write_bytes=\(Self.writeSize) runs=\(Self.runs)")
        print("SSH_TERMINAL_THROUGHPUT workload=\(workload.rawValue) median_mib_s=\(Self.format(median)) min_mib_s=\(Self.format(rates.first ?? 0)) max_mib_s=\(Self.format(rates.last ?? 0)) engine_init_ms=\(String(format: "%.3f", initMs))")
        print("METRIC ssh_terminal_throughput_\(workload.rawValue)_mib_s=\(Self.format(median))")

        let completed = samples.allSatisfy { $0.completed }
        #expect(completed, "every run answered the trailing DSR, so every byte was parsed")
        #expect(fed >= Self.bytesPerRun)
    }

    private struct Run {
        var bytes: Int
        var seconds: Double
        var initMs: Double
        var completed: Bool
        var mibPerSecond: Double { Double(bytes) / 1_048_576 / seconds }
    }

    private final class Replies {
        var data = Data()
    }

    private static func run(block: Data, totalBytes: Int) throws -> Run {
        let clock = ContinuousClock()
        let replies = Replies()
        let initStart = clock.now
        let engine = try SSHTerminalEngine(geometry: geometry) { replies.data.append($0) }
        let initElapsed = clock.now - initStart
        defer { engine.close() }

        var fed = 0
        let start = clock.now
        engine.receive(alternateScreen)
        fed += alternateScreen.count
        while fed < totalBytes {
            var offset = block.startIndex
            while offset < block.endIndex {
                let end = min(offset + writeSize, block.endIndex)
                engine.receive(block[offset..<end])
                offset = end
            }
            engine.receive(repetitionReset)
            fed += block.count + repetitionReset.count
        }
        engine.receive(statusRequest)
        fed += statusRequest.count
        let elapsed = clock.now - start
        return Run(
            bytes: fed,
            seconds: seconds(elapsed),
            initMs: seconds(initElapsed) * 1_000,
            completed: replies.data.range(of: statusOK) != nil
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Deterministic workload blocks. Sizes follow the kitten's: about 2 MiB of
/// ASCII, 1024 repeated Unicode lines, 256Ki unique cells, 1 MiB of CSI,
/// one 1024x1024 RGBA image, and 1024 OSC strings of 8024 bytes.
private enum Corpus {
    static func block(for workload: SSHTerminalThroughputBench.Workload) -> Data {
        var rng = SplitMix64(seed: 0x6F70_7069)
        switch workload {
        case .ascii: return ascii(&rng)
        case .unicode: return unicode(&rng)
        case .uniqueUnicode: return uniqueUnicode()
        case .csi: return csi(&rng)
        case .images: return images()
        case .longEscapeCodes: return longEscapeCodes(&rng)
        }
    }

    /// Printable ASCII (0x20...0x7E) plus newline and tab.
    private static let printable: [UInt8] = Array(0x20...0x7E)
    private static let printableWithControls: [UInt8] = printable + [0x0A, 0x09]

    private static func randomBytes(_ count: Int, from alphabet: [UInt8], _ rng: inout SplitMix64) -> [UInt8] {
        (0..<count).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }
    }

    private static func ascii(_ rng: inout SplitMix64) -> Data {
        Data(randomBytes(2 * 1024 * 1024 + 13, from: printableWithControls, &rng))
    }

    /// One mixed line repeated 1024 times: wide CJK ideographs and punctuation,
    /// then emoji, typographic symbols, accented Latin, Greek, and base letters
    /// with stacked combining marks.
    private static func unicode(_ rng: inout SplitMix64) -> Data {
        let punctuation: [Character] = ["，", "。", "；", "：", "！", "？", "「", "」", "、"]
        var line = ""
        for index in 0..<480 {
            if index % 23 == 22 {
                line.append(punctuation[Int(rng.next() % UInt64(punctuation.count))])
            } else {
                let scalar = UnicodeScalar(UInt32(0x4E00) + UInt32(rng.next() % 0x51A6))!
                line.unicodeScalars.append(scalar)
            }
        }
        line += "“quoted” ‘single’ «guillemets» — – … • · ° ± × ÷ ½ ¾ § ¶ † ‡ © ® ™ → ⇒ € £ ¥ ¢ "
        line += "😀😃😄😁😆😅🤣😂🙂🙃😉😊😇🥰😍🤩😘👍👎👋🚀🌈 "
        line += "ÀÁÂÃÄÅÆÇÈÉÊËÌÍÎÏÑÒÓÔÕÖØÙÚÛÜÝàáâãäåæçèéêëìíîïñòóôõöøùúûüýÿßœŒšŠ "
        line += "αβγδεζηθικλμνξοπρστυφχψωΩ∞ "
        line += "e\u{301}a\u{300}o\u{302}\u{323}u\u{308}\u{304}n\u{303}x\u{332}\u{338}"
        line += "\n\t"
        return Data(String(repeating: line, count: 1024).utf8)
    }

    /// 256Ki cells, each "a" plus three combining marks from U+0300..U+036F
    /// chosen by the cell index in base 0x70, so no two cells share a grapheme.
    private static func uniqueUnicode() -> Data {
        let cells = 256 * 1024
        let marks: UInt32 = 0x70
        var text = String.UnicodeScalarView()
        text.reserveCapacity(cells * 4)
        for index in 0..<cells {
            var digits = UInt32(index)
            text.append("a")
            for _ in 0..<3 {
                text.append(UnicodeScalar(0x300 + digits % marks)!)
                digits /= marks
            }
        }
        return Data(String(text).utf8)
    }

    /// About 1 MiB of mostly control sequences with short runs of text: SGR
    /// resets and attribute stacks, 256-color and truecolor in colon and
    /// semicolon forms, underline color, cursor motion, erase, character
    /// position and repeat, and cursor-key mode toggles.
    private static func csi(_ rng: inout SplitMix64) -> Data {
        let target = 1024 * 1024 + 17
        var out: [UInt8] = []
        out.reserveCapacity(target + 64)
        while out.count < target {
            switch rng.next() % 100 {
            case 0..<10:
                out += randomBytes(Int(rng.next() % 72) + 1, from: printableWithControls, &rng)
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

    /// One uncompressed 1024x1024 RGBA Kitty graphics transmission in 4096-byte
    /// base64 chunks, quiet, then a delete by id, so the store never fills.
    private static func images() -> Data {
        let dimension = 1024
        let payload = Data(count: 4 * dimension * dimension).base64EncodedData()
        let chunk = 4096
        var out = Data()
        out.reserveCapacity(payload.count + payload.count / chunk * 16 + 128)
        var offset = payload.startIndex
        var first = true
        while offset < payload.endIndex {
            let end = min(offset + chunk, payload.endIndex)
            let more = end < payload.endIndex ? 1 : 0
            let keys = first ? "a=t,f=32,s=\(dimension),v=\(dimension),i=12345,q=2,m=\(more)" : "q=2,m=\(more)"
            out += Data("\u{1b}_G\(keys);".utf8)
            out += payload[offset..<end]
            out += Data("\u{1b}\\".utf8)
            offset = end
            first = false
        }
        out += Data("\u{1b}_Ga=d,d=I,i=12345,q=2\u{1b}\\".utf8)
        return out
    }

    /// 1024 OSC 6 strings, each carrying 8024 printable bytes. OSC 6 is a
    /// report most terminals parse and ignore, so this isolates string scanning.
    private static func longEscapeCodes(_ rng: inout SplitMix64) -> Data {
        var one = Array("\u{1b}]6;".utf8)
        one += randomBytes(8024, from: printable, &rng)
        one.append(0x07)
        var out = Data()
        out.reserveCapacity(one.count * 1024)
        for _ in 0..<1024 { out.append(contentsOf: one) }
        return out
    }
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
