import Testing
import Foundation
@testable import Oppi

/// Benchmarks for org mode rendering pipeline:
/// OrgParser → OrgToMarkdownConverter → MarkdownBlockSerializer → parseCommonMark.
///
/// Measures the synchronous main-thread work that causes large-document app hangs.
/// Each stage is timed independently; the total pipeline measures the combined cost
/// of producing the markdown string used by OrgModeFileView.
///
/// Test fixtures:
/// - doom-getting-started.org: 1675 lines, 66KB, 95 headings (Doom Emacs docs)
/// - org-manual.org: 23715 lines, 854KB, 424 headings (org-mode official manual)
///
/// Output format: METRIC name=number (microseconds)
@Suite("OrgModePerfBench", .tags(.perf))
struct OrgModePerfBench {

    // MARK: - Configuration

    private static let iterations = 15
    private static let warmupIterations = 3

    // MARK: - Fixture Loading

    private static func loadFixture(_ name: String) -> String {
        let bundle = Bundle(for: BundleAnchor.self)
        // Swift Testing: fixtures are in the test bundle resource directory
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("Fixtures/\(name)"),
            bundle.bundleURL.appendingPathComponent("Fixtures/\(name)"),
            // Fallback: walk up from bundle to find OppiTests/Perf/Fixtures
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/\(name)"),
        ]
        for url in candidates {
            if let url, let data = try? Data(contentsOf: url),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
        }
        fatalError("Missing fixture: \(name). Run curl to download into OppiTests/Perf/Fixtures/")
    }

    /// Doom Emacs getting started: 1675 lines, 66KB, 95 headings — realistic "large file browser" workload
    private static let doomDoc = loadFixture("doom-getting-started.org")
    /// Org-mode official manual: 23715 lines, 854KB, 424 headings — extreme stress test
    private static let orgManualDoc = loadFixture("org-manual.org")

    // MARK: - Timing

    private static func medianNs(
        iterations: Int = Self.iterations,
        warmup: Int = Self.warmupIterations,
        _ block: () -> Void
    ) -> Double {
        var timings: [UInt64] = []
        timings.reserveCapacity(iterations)

        for i in 0 ..< (warmup + iterations) {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            if i >= warmup {
                timings.append(elapsed)
            }
        }

        timings.sort()
        return Double(timings[timings.count / 2])
    }

    @inline(never)
    private static func consume<T>(_ value: T) {}

    // MARK: - Full Pipeline Benchmark (Primary Metric)

    @Test("Full pipeline — Doom getting_started.org (95 headings)")
    func fullPipelineDoom() {
        runFullPipeline(doc: Self.doomDoc, label: "doom")
    }

    @Test("Full pipeline — org-manual.org (424 headings)")
    func fullPipelineOrgManual() {
        runFullPipeline(doc: Self.orgManualDoc, label: "org_manual")
    }

    private func runFullPipeline(doc: String, label: String) {
        let parser = OrgParser()

        // Measure the complete synchronous work used by OrgModeFileView:
        // parse → convert → serialize markdown.
        let totalNs = Self.medianNs {
            let blocks = parser.parse(doc)
            let markdown = MarkdownBlockSerializer.serialize(OrgToMarkdownConverter.convert(blocks))
            Self.consume(markdown)
        }
        print("METRIC org_full_pipeline_\(label)_us=\(String(format: "%.1f", totalNs / 1000.0))")

        let parseNs = Self.medianNs {
            Self.consume(parser.parse(doc))
        }
        print("METRIC org_parse_\(label)_us=\(String(format: "%.1f", parseNs / 1000.0))")

        let blocks = parser.parse(doc)
        let headingCount = blocks.filter { if case .heading = $0 { return true }; return false }.count
        let lineCount = doc.components(separatedBy: "\n").count
        print("METRIC org_heading_count_\(label)=\(headingCount)")
        print("METRIC org_line_count_\(label)=\(lineCount)")
    }

    // MARK: - Per-Stage Benchmarks

    @Test("OrgParser.parse — Doom (1675 lines)")
    func parseDoom() {
        RendererTestSupport.benchParse(
            parser: OrgParser(), input: Self.doomDoc,
            prefix: "org", label: "doom",
            budgetUs: 10_000
        )
    }

    @Test("OrgParser.parse — org-manual (23715 lines)")
    func parseOrgManual() {
        RendererTestSupport.benchParse(
            parser: OrgParser(), input: Self.orgManualDoc,
            prefix: "org", label: "org_manual",
            budgetUs: 200_000
        )
    }

    @Test("Markdown conversion — Doom")
    func markdownConversionDoom() {
        runMarkdownConversion(doc: Self.doomDoc, label: "doom")
    }

    @Test("Markdown conversion — org-manual")
    func markdownConversionOrgManual() {
        runMarkdownConversion(doc: Self.orgManualDoc, label: "org_manual")
    }

    private func runMarkdownConversion(doc: String, label: String) {
        let blocks = OrgParser().parse(doc)
        let ns = Self.medianNs {
            let md = MarkdownBlockSerializer.serialize(OrgToMarkdownConverter.convert(blocks))
            Self.consume(md)
        }
        print("METRIC org_md_conversion_\(label)_us=\(String(format: "%.1f", ns / 1000.0))")
    }

    @Test("CommonMark re-parse of converted markdown — Doom")
    func commonmarkReParseDoom() {
        runCommonMarkReparse(doc: Self.doomDoc, label: "doom")
    }

    @Test("CommonMark re-parse of converted markdown — org-manual")
    func commonmarkReparseOrgManual() {
        runCommonMarkReparse(doc: Self.orgManualDoc, label: "org_manual")
    }

    private func runCommonMarkReparse(doc: String, label: String) {
        let blocks = OrgParser().parse(doc)
        let markdown = MarkdownBlockSerializer.serialize(OrgToMarkdownConverter.convert(blocks))
        let ns = Self.medianNs {
            Self.consume(parseCommonMark(markdown))
        }
        print("METRIC org_cmark_reparse_\(label)_us=\(String(format: "%.1f", ns / 1000.0))")
    }
}

/// Anchor class to locate the test bundle at runtime.
private final class BundleAnchor {}
