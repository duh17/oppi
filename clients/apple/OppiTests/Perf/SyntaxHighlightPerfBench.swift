import Testing
import UIKit
@testable import Oppi

/// Microbenchmark for syntax highlighting pipeline.
///
/// Measures wall-clock μs for each stage:
/// - SyntaxHighlighter.highlight (raw scanner)
/// - SyntaxHighlighter.highlight (block)
/// - ToolRowTextRenderer.makeCodeAttributedText (full pipeline: gutter + highlight + assembly)
///
/// Outputs METRIC lines for autoresearch.sh to parse.
@Suite("Syntax Highlight Perf Bench")
@MainActor
struct SyntaxHighlightPerfBench {

    // MARK: - Fixtures

    static let source100 = RenderStrategyPerfTests.syntheticSwiftSource(lineCount: 100)
    static let source500 = RenderStrategyPerfTests.syntheticSwiftSource(lineCount: 500)

    // MARK: - Timing

    private static func measureUs(iterations: Int = 5, _ block: () -> Void) -> Int {
        // Warmup
        block()

        var best = Int.max
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let end = DispatchTime.now().uptimeNanoseconds
            let us = Int((end &- start) / 1_000)
            best = min(best, us)
        }
        return best
    }

    // MARK: - Benchmarks

    @Test("Benchmark: highlight 100 lines")
    func highlight100() {
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(Self.source100, language: .swift)
        }
        print("METRIC highlight_100=\(us)")
        #expect(us < 500_000, "highlight 100 lines: \(us)μs")
    }

    @Test("Benchmark: highlight 500 lines")
    func highlight500() {
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(Self.source500, language: .swift)
        }
        print("METRIC highlight_500=\(us)")
        #expect(us < 500_000, "highlight 500 lines: \(us)μs")
    }

    @Test("Benchmark: makeCodeAttributedText 100 lines")
    func codeAttr100() {
        let us = Self.measureUs {
            _ = ToolRowTextRenderer.makeCodeAttributedText(
                text: Self.source100, language: .swift, startLine: 1
            )
        }
        print("METRIC codeAttr_100=\(us)")
        #expect(us < 500_000, "makeCodeAttributedText 100 lines: \(us)μs")
    }

    @Test("Benchmark: makeCodeAttributedText 500 lines")
    func codeAttr500() {
        let us = Self.measureUs {
            _ = ToolRowTextRenderer.makeCodeAttributedText(
                text: Self.source500, language: .swift, startLine: 1
            )
        }
        print("METRIC codeAttr_500=\(us)")
        #expect(us < 500_000, "makeCodeAttributedText 500 lines: \(us)μs")
    }

    @Test("Benchmark: highlight JSON 500 lines")
    func highlightJSON500() {
        let json = (0..<500).map { "  \"key\($0)\": \($0)," }.joined(separator: "\n")
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(json, language: .json)
        }
        print("METRIC highlight_json_500=\(us)")
        #expect(us < 500_000, "highlight JSON 500 lines: \(us)μs")
    }

    @Test("Benchmark: highlight Shell 100 lines")
    func highlightShell100() {
        let shell = (0..<100).map { "echo \"line \($0)\" | grep -E 'pattern' >> output.log 2>&1" }
            .joined(separator: "\n")
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(shell, language: .shell)
        }
        print("METRIC highlight_shell_100=\(us)")
        #expect(us < 500_000, "highlight Shell 100 lines: \(us)μs")
    }

    // MARK: - New Language Benchmarks

    @Test("Benchmark: highlight XML 500 lines")
    func highlightXML500() {
        let xml = (0..<500).map {
            "  <item id=\"\($0)\" name=\"value\($0)\">content &amp; more</item>"
        }.joined(separator: "\n")
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(xml, language: .xml)
        }
        print("METRIC highlight_xml_500=\(us)")
        #expect(us < 500_000, "highlight XML 500 lines: \(us)μs")
    }

    @Test("Benchmark: highlight Diff 500 lines")
    func highlightDiff500() {
        var lines: [String] = [
            "--- a/file.swift",
            "+++ b/file.swift",
            "@@ -1,250 +1,260 @@",
        ]
        for i in 0..<497 {
            switch i % 4 {
            case 0: lines.append("+let added\(i) = true")
            case 1: lines.append("-let removed\(i) = false")
            case 2: lines.append("@@ -\(i),10 +\(i),12 @@")
            default: lines.append(" let context\(i) = 42")
            }
        }
        let diff = lines.joined(separator: "\n")
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(diff, language: .diff)
        }
        print("METRIC highlight_diff_500=\(us)")
        #expect(us < 500_000, "highlight Diff 500 lines: \(us)μs")
    }

    @Test("Benchmark: highlight Protobuf 200 lines")
    func highlightProtobuf200() {
        let proto = (0..<200).map {
            "  message Item\($0) { repeated string field\($0) = \($0 + 1); }"
        }.joined(separator: "\n")
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(proto, language: .protobuf)
        }
        print("METRIC highlight_proto_200=\(us)")
        #expect(us < 500_000, "highlight Protobuf 200 lines: \(us)μs")
    }

    @Test("Benchmark: highlight GraphQL 200 lines")
    func highlightGraphQL200() {
        let gql = (0..<200).map {
            "  type Query\($0) { user(id: ID!): User\($0) }"
        }.joined(separator: "\n")
        let us = Self.measureUs {
            _ = SyntaxHighlighter.highlight(gql, language: .graphql)
        }
        print("METRIC highlight_graphql_200=\(us)")
        #expect(us < 500_000, "highlight GraphQL 200 lines: \(us)μs")
    }

    @Test("Benchmark: FileType.detect 10K calls")
    func fileTypeDetect10K() {
        let paths = [
            "main.swift", "index.ts", "app.py", "Makefile",
            ".gitignore", ".env", "config.xml", "schema.proto",
            "queries.graphql", "changes.diff", "doc.pdf", "archive.gz",
            "video.mp4", "README.md", "style.css", "data.json",
            "unknown.xyz", ".prettierrc", "Info.plist", "image.png",
        ]
        let us = Self.measureUs {
            for _ in 0..<500 {
                for path in paths {
                    _ = FileType.detect(from: path)
                }
            }
        }
        print("METRIC filetype_detect_10K=\(us)")
        #expect(us < 100_000, "FileType.detect 10K calls: \(us)μs — should be <100ms")
    }
}
