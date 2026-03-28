import Testing
import Foundation
import UIKit
@testable import Oppi

/// Benchmark for ANSIParser.attributedString(from:).
///
/// Generates realistic ANSI-colored output similar to `npm test` (vitest)
/// and measures parsing time. Prints METRIC lines for autoresearch.
@Suite("ANSIParserPerf")
@MainActor
struct ANSIParserPerfTests {

    /// Build a ~300KB string that looks like vitest output.
    /// Mix of plain text lines and heavily ANSI-colored lines.
    static func generateTestInput(targetBytes: Int = 300_000) -> String {
        // Patterns observed in real vitest/npm test output:
        let patterns: [String] = [
            // Green checkmark + test name + dim count + yellow timing
            "\u{1B}[32m✓\u{1B}[39m src/session-protocol.test.ts \u{1B}[2m(12 tests)\u{1B}[22m \u{1B}[33m142ms\u{1B}[39m",
            // Dimmed stdout header
            "\u{1B}[90mstdout\u{1B}[2m | tests/gondolin-manager.test.ts\u{1B}[2m > \u{1B}[22m\u{1B}[2mGondolinManager\u{1B}[2m > \u{1B}[22m\u{1B}[2mcreates VM on first call\u{1B}[22m\u{1B}[39m",
            // Colored JSON-like log output
            "[gondolin] starting VM { workspaceId: \u{1B}[32m'w1'\u{1B}[39m, cwd: \u{1B}[32m'/home/user/project'\u{1B}[39m, allowedHosts: [ \u{1B}[32m'*'\u{1B}[39m ], roMounts: \u{1B}[33m0\u{1B}[39m, ts: \u{1B}[32m'09:21:06.330'\u{1B}[39m }",
            // Bold + color compound codes
            "\u{1B}[1m\u{1B}[46m RUN \u{1B}[49m\u{1B}[22m \u{1B}[36mv4.0.18 \u{1B}[39m\u{1B}[90m/Users/chenda/workspace/oppi/server\u{1B}[39m",
            // Error with red + dim stacktrace
            "\u{1B}[31mError: Connection refused\u{1B}[39m\n    at Object.<anonymous> \u{1B}[90m(/Users/chenda/workspace/oppi/server/\u{1B}[39mtests/integration.test.ts:42:15\u{1B}[90m)\u{1B}[39m",
            // 256-color codes (pi TUI style)
            "\u{1B}[38;5;59m─\u{1B}[39m\u{1B}[38;5;59m─\u{1B}[39m\u{1B}[38;5;59m─\u{1B}[39m \u{1B}[38;5;179m⠋\u{1B}[39m \u{1B}[38;5;60mWorking...\u{1B}[39m \u{1B}[38;5;59m$0.000 (sub)\u{1B}[39m",
            // Plain text lines (no ANSI)
            "  158 passed | 0 failed | 3 skipped (24 tests per file, 42 files)",
            // Bold magenta + reset
            "\u{1B}[1;35m  PASS \u{1B}[0m src/ansi.test.ts \u{1B}[2m(27 tests)\u{1B}[22m",
            // Background color codes
            "\u{1B}[41;37m ERROR \u{1B}[0m\u{1B}[31m Module not found: src/missing.ts\u{1B}[39m",
            // RGB foreground
            "\u{1B}[38;2;255;100;0mwarning:\u{1B}[0m unused import 'foo' at line 42",
        ]

        var result = ""
        result.reserveCapacity(targetBytes + 1024)
        var patternIndex = 0

        while result.utf8.count < targetBytes {
            result.append(patterns[patternIndex % patterns.count])
            result.append("\n")
            patternIndex += 1
        }

        return result
    }

    @Test("benchmark attributedString parsing")
    func benchmarkAttributedString() {
        let input = Self.generateTestInput(targetBytes: 300_000)
        let inputBytes = input.utf8.count
        let iterations = 5

        // Warmup
        for _ in 0..<2 {
            _ = ANSIParser.attributedString(from: input)
        }

        // Timed runs
        var durationsMs: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = ANSIParser.attributedString(from: input)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            durationsMs.append(elapsed)
        }

        durationsMs.sort()
        let median = durationsMs[durationsMs.count / 2]
        let mean = durationsMs.reduce(0, +) / Double(durationsMs.count)
        let min = durationsMs.first!
        let max = durationsMs.last!
        let throughputMBs = (Double(inputBytes) / 1_000_000.0) / (median / 1000.0)

        print("METRIC parse_p50_ms=\(String(format: "%.2f", median))")
        print("METRIC parse_mean_ms=\(String(format: "%.2f", mean))")
        print("METRIC parse_min_ms=\(String(format: "%.2f", min))")
        print("METRIC parse_max_ms=\(String(format: "%.2f", max))")
        print("METRIC input_bytes=\(inputBytes)")
        print("METRIC throughput_mbs=\(String(format: "%.2f", throughputMBs))")
    }

    @Test("benchmark strip")
    func benchmarkStrip() {
        let input = Self.generateTestInput(targetBytes: 300_000)
        let iterations = 10

        // Warmup
        for _ in 0..<2 {
            _ = ANSIParser.strip(input)
        }

        var durationsMs: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = ANSIParser.strip(input)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            durationsMs.append(elapsed)
        }

        durationsMs.sort()
        let median = durationsMs[durationsMs.count / 2]
        print("METRIC strip_p50_ms=\(String(format: "%.2f", median))")
    }
}
