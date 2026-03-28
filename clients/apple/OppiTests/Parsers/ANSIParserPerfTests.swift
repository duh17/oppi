import Testing
import Foundation
import UIKit
@testable import Oppi

/// Helper to locate the test bundle for resource loading.
private final class _ANSIParserPerfBundle {}

/// Benchmark for ANSIParser.attributedString(from:).
///
/// Uses real `npm test` output (~316KB, vitest with heavy ANSI coloring)
/// as the benchmark input. Prints METRIC lines for autoresearch.
@Suite("ANSIParserPerf")
@MainActor
struct ANSIParserPerfTests {

    /// Load the real npm test output fixture.
    static let testInput: String = {
        let bundle = Bundle(for: _ANSIParserPerfBundle.self)
        guard let url = bundle.url(forResource: "ansi-heavy-output", withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            // Fallback: generate synthetic data if fixture missing
            return generateFallbackInput(targetBytes: 300_000)
        }
        return text
    }()

    /// Fallback generator if fixture is missing.
    private static func generateFallbackInput(targetBytes: Int) -> String {
        let patterns: [String] = [
            "\u{1B}[32m✓\u{1B}[39m src/session.test.ts \u{1B}[2m(12 tests)\u{1B}[22m \u{1B}[33m142ms\u{1B}[39m",
            "\u{1B}[90mstdout\u{1B}[2m | tests/gondolin.test.ts\u{1B}[2m > \u{1B}[22m\u{1B}[2mGondolinManager\u{1B}[22m\u{1B}[39m",
            "[gondolin] starting VM { workspaceId: \u{1B}[32m'w1'\u{1B}[39m, cwd: \u{1B}[32m'/home/user/project'\u{1B}[39m }",
            "\u{1B}[1m\u{1B}[46m RUN \u{1B}[49m\u{1B}[22m \u{1B}[36mv4.0.18 \u{1B}[39m\u{1B}[90m/workspace/server\u{1B}[39m",
            "\u{1B}[38;5;59m─\u{1B}[39m\u{1B}[38;5;59m─\u{1B}[39m \u{1B}[38;5;179m⠋\u{1B}[39m \u{1B}[38;5;60mWorking...\u{1B}[39m",
        ]
        var result = ""
        result.reserveCapacity(targetBytes + 1024)
        var idx = 0
        while result.utf8.count < targetBytes {
            result.append(patterns[idx % patterns.count])
            result.append("\n")
            idx += 1
        }
        return result
    }

    @Test("benchmark attributedString parsing")
    func benchmarkAttributedString() {
        let input = Self.testInput
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
        let input = Self.testInput
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
