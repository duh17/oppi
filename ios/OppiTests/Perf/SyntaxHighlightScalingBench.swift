import Foundation
import Testing
import UIKit
@testable import Oppi

/// Scaling benchmark for syntax highlighting across line counts.
///
/// Sweeps 100 - 10,000 lines across multiple languages to find the
/// practical ceiling where highlighting degrades UX. Runs on a
/// background thread to match the real full-screen code path.
///
/// Results written to /tmp/syntax-highlight-bench.txt.
@Suite("Syntax Highlight Scaling Bench")
@MainActor
struct SyntaxHighlightScalingBench {

    private static let resultFile = "/tmp/syntax-highlight-bench.txt"
    private static let lineCounts = [100, 500, 1_000, 2_000, 5_000, 10_000]

    // MARK: - Fixtures

    private static func swiftSource(_ n: Int) -> String {
        RenderStrategyPerfTests.syntheticSwiftSource(lineCount: n)
    }

    private static func shellSource(_ n: Int) -> String {
        (0..<n).map { i in
            switch i % 5 {
            case 0: "# Comment line \(i)"
            case 1: "echo \"Processing item \(i)\" | grep -E 'pattern' >> output.log 2>&1"
            case 2: "if [ -f \"$FILE_\(i)\" ]; then"
            case 3: "    curl -s \"https://api.example.com/v1/items/\(i)\" | jq '.data'"
            default: "fi"
            }
        }.joined(separator: "\n")
    }

    private static func tsSource(_ n: Int) -> String {
        (0..<n).map { i in
            switch i % 6 {
            case 0: "export interface Model\(i) { id: string; name: string; count: number; }"
            case 1: "const value\(i): number = Math.floor(Math.random() * \(i));"
            case 2: "async function process\(i)(input: string): Promise<void> {"
            case 3: "    // TODO: implement transformation for stage \(i)"
            case 4: "    return { id: `id-${value\(i)}`, name: input, count: \(i) };"
            default: "}"
            }
        }.joined(separator: "\n")
    }

    private static func jsonSource(_ n: Int) -> String {
        var lines: [String] = ["["]
        for i in 1..<(n - 1) {
            let comma = i < n - 2 ? "," : ""
            lines.append("  {\"id\": \(i), \"name\": \"item_\(i)\", \"active\": \(i % 2 == 0)}\(comma)")
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    // MARK: - Measure

    private static func benchUs(_ block: @escaping @Sendable () -> Void) async -> Int {
        await Task.detached(priority: .userInitiated) {
            block()
            var best = Int.max
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                block()
                let end = DispatchTime.now().uptimeNanoseconds
                best = min(best, Int((end &- start) / 1_000))
            }
            return best
        }.value
    }

    private static func emit(_ line: String) {
        let data = Data((line + "\n").utf8)
        if let fh = FileHandle(forWritingAtPath: resultFile) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: resultFile, contents: data)
        }
    }

    // MARK: - Bench

    @Test("Scaling sweep")
    func sweep() async {
        try? FileManager.default.removeItem(atPath: Self.resultFile)
        Self.emit("lang,lines,us,ms")

        // Swift
        for count in Self.lineCounts {
            let src = Self.swiftSource(count)
            let us = await Self.benchUs { _ = SyntaxHighlighter.highlight(src, language: .swift) }
            Self.emit("swift,\(count),\(us),\(String(format: "%.1f", Double(us) / 1000))")
        }

        // Shell
        for count in Self.lineCounts {
            let src = Self.shellSource(count)
            let us = await Self.benchUs { _ = SyntaxHighlighter.highlight(src, language: .shell) }
            Self.emit("shell,\(count),\(us),\(String(format: "%.1f", Double(us) / 1000))")
        }

        // TypeScript
        for count in Self.lineCounts {
            let src = Self.tsSource(count)
            let us = await Self.benchUs { _ = SyntaxHighlighter.highlight(src, language: .typescript) }
            Self.emit("typescript,\(count),\(us),\(String(format: "%.1f", Double(us) / 1000))")
        }

        // JSON
        for count in Self.lineCounts {
            let src = Self.jsonSource(count)
            let us = await Self.benchUs { _ = SyntaxHighlighter.highlight(src, language: .json) }
            Self.emit("json,\(count),\(us),\(String(format: "%.1f", Double(us) / 1000))")
        }
    }
}
