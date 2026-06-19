import Testing
import Foundation
@testable import Oppi

/// Benchmarks for org mode rendering pipeline:
/// OrgParser → buildOrgSectionTree → OrgToMarkdownConverter → MarkdownBlockSerializer → parseCommonMark.
///
/// Measures the synchronous main-thread work that causes large-document app hangs.
/// Each stage is timed independently; the total pipeline measures the combined cost
/// of producing all MarkdownContentViewWrapper input strings for a document.
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

        // Measure the complete synchronous work: parse + tree build (which now includes
        // pre-computing body markdown groups). This matches the real code path in
        // OrgModeFileView.task(id:) → buildOrgSectionTree → computeBodyGroups.
        // Headings are rendered natively (no markdown roundtrip).
        let totalNs = Self.medianNs {
            let blocks = parser.parse(doc)
            let (sections, _) = buildOrgSectionTree(blocks)
            Self.consume(sections)
        }
        let totalUs = totalNs / 1000.0
        print("METRIC org_full_pipeline_\(label)_us=\(String(format: "%.1f", totalUs))")

        // Secondary: parse only
        let parseNs = Self.medianNs {
            Self.consume(parser.parse(doc))
        }
        print("METRIC org_parse_\(label)_us=\(String(format: "%.1f", parseNs / 1000.0))")

        // Secondary: tree build only
        let blocks = parser.parse(doc)
        let treeNs = Self.medianNs {
            Self.consume(buildOrgSectionTree(blocks))
        }
        print("METRIC org_tree_\(label)_us=\(String(format: "%.1f", treeNs / 1000.0))")

        // Count MarkdownContentViewWrapper instances from pre-computed body groups
        let (sections, _) = buildOrgSectionTree(blocks)
        var wrapperCount = 0
        func countWrappers(_ secs: [OrgSection]) {
            for s in secs {
                wrapperCount += s.precomputedBodyGroups.filter {
                    if case .markdown = $0 { return true }; return false
                }.count
                countWrappers(s.children)
            }
        }
        countWrappers(sections)

        let headingCount = blocks.filter { if case .heading = $0 { return true }; return false }.count
        let lineCount = doc.components(separatedBy: "\n").count

        print("METRIC org_wrapper_count_\(label)=\(wrapperCount)")
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

    @Test("buildOrgSectionTree — Doom")
    func treeBuildDoom() {
        let blocks = OrgParser().parse(Self.doomDoc)
        let ns = Self.medianNs {
            Self.consume(buildOrgSectionTree(blocks))
        }
        print("METRIC org_tree_doom_us=\(String(format: "%.1f", ns / 1000.0))")
    }

    @Test("buildOrgSectionTree — org-manual")
    func treeBuildOrgManual() {
        let blocks = OrgParser().parse(Self.orgManualDoc)
        let ns = Self.medianNs {
            Self.consume(buildOrgSectionTree(blocks))
        }
        print("METRIC org_tree_org_manual_us=\(String(format: "%.1f", ns / 1000.0))")
    }

    @Test("Markdown conversion — Doom (all sections)")
    func markdownConversionDoom() {
        runMarkdownConversion(doc: Self.doomDoc, label: "doom")
    }

    @Test("Markdown conversion — org-manual (all sections)")
    func markdownConversionOrgManual() {
        runMarkdownConversion(doc: Self.orgManualDoc, label: "org_manual")
    }

    private func runMarkdownConversion(doc: String, label: String) {
        let blocks = OrgParser().parse(doc)
        let (sections, _) = buildOrgSectionTree(blocks)

        var allBodyGroups: [[OrgBlock]] = []
        func collect(_ secs: [OrgSection]) {
            for s in secs {
                if !s.bodyBlocks.isEmpty { allBodyGroups.append(s.bodyBlocks) }
                collect(s.children)
            }
        }
        collect(sections)

        let ns = Self.medianNs {
            for bodyBlocks in allBodyGroups {
                let mdBlocks = OrgToMarkdownConverter.convert(bodyBlocks)
                let md = MarkdownBlockSerializer.serialize(mdBlocks)
                Self.consume(md)
            }
        }
        print("METRIC org_md_conversion_\(label)_us=\(String(format: "%.1f", ns / 1000.0))")
        print("METRIC org_body_group_count_\(label)=\(allBodyGroups.count)")
    }

    @Test("CommonMark re-parse of all section markdown — Doom")
    func commonmarkReParseDoom() {
        runCommonMarkReparse(doc: Self.doomDoc, label: "doom")
    }

    @Test("CommonMark re-parse of all section markdown — org-manual")
    func commonmarkReparseOrgManual() {
        runCommonMarkReparse(doc: Self.orgManualDoc, label: "org_manual")
    }

    private func runCommonMarkReparse(doc: String, label: String) {
        let blocks = OrgParser().parse(doc)
        let (sections, _) = buildOrgSectionTree(blocks)

        var allMdStrings: [String] = []
        func collect(_ secs: [OrgSection]) {
            for s in secs {
                if let heading = s.heading {
                    allMdStrings.append(Self.serializeHeading(heading, section: s))
                }
                var pending: [OrgBlock] = []
                for b in s.bodyBlocks {
                    if case .drawer = b {
                        if !pending.isEmpty {
                            allMdStrings.append(MarkdownBlockSerializer.serialize(OrgToMarkdownConverter.convert(pending)))
                            pending = []
                        }
                    } else { pending.append(b) }
                }
                if !pending.isEmpty {
                    allMdStrings.append(MarkdownBlockSerializer.serialize(OrgToMarkdownConverter.convert(pending)))
                }
                collect(s.children)
            }
        }
        collect(sections)

        let ns = Self.medianNs {
            for md in allMdStrings {
                Self.consume(parseCommonMark(md))
            }
        }
        print("METRIC org_cmark_reparse_\(label)_us=\(String(format: "%.1f", ns / 1000.0))")
        print("METRIC org_cmark_reparse_count_\(label)=\(allMdStrings.count)")
    }

    // MARK: - Helpers

    private static func serializeHeading(_ heading: OrgBlock, section: OrgSection) -> String {
        guard case .heading(let level, let keyword, _, let title, let tags) = heading else {
            return ""
        }
        var inlines = [MarkdownInline]()
        let expandedBullets = ["◈", "•", "‣", "◦", "·", "·"]
        let idx = min(level - 1, expandedBullets.count - 1)
        inlines.append(.text("\(expandedBullets[idx]) "))

        if let kw = keyword {
            inlines.append(.strong([.text(kw)]))
            inlines.append(.text(" "))
        }
        inlines.append(contentsOf: title.map { OrgToMarkdownConverter.convertSingleInline($0) })
        if !tags.isEmpty {
            inlines.append(.text("  "))
            inlines.append(.code(":" + tags.joined(separator: ":") + ":"))
        }
        let mdBlocks: [MarkdownBlock] = [.heading(level: min(level, 6), inlines: inlines)]
        return MarkdownBlockSerializer.serialize(mdBlocks)
    }
}

/// Anchor class to locate the test bundle at runtime.
private final class BundleAnchor {}
