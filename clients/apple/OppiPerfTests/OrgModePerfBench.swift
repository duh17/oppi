import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Oppi

/// Benchmarks for org mode rendering pipeline:
/// OrgParser → OrgToMarkdownConverter → MarkdownBlockSerializer → parseCommonMark.
///
/// Measures the conversion and CommonMark work that previously ran synchronously
/// on the main thread. Each stage is timed independently; the reader contract test
/// verifies that the same work now runs behind a visible, virtualized shell.
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

    // MARK: - Large document reader contract

    @MainActor
    @Test(
        "org-manual is shell-first, off-main, and virtualized",
        .timeLimit(.minutes(1))
    )
    func largeDocumentReaderUsesMarkdownViewport() async throws {
        let expectedMarkdown = await Task.detached(priority: .userInitiated) {
            DocumentRenderPipeline.orgToMarkdown(Self.orgManualDoc)
        }.value
        #expect(Self.orgManualDoc.utf8.count == 853_547)
        #expect(expectedMarkdown.utf8.count == 855_654)
        #expect(expectedMarkdown.contains("orgtbl-radio-table-templates"))

        let reviewRouter = ReviewCommentSelectionRouter(dispatch: { _ in })
        let reviewContext = ReviewCommentSelectionContext(
            dispatcher: reviewRouter,
            sessionId: "org-reader-contract",
            sourceLabel: "Org manual",
            filePath: "org-manual.org",
            languageHint: "org"
        )
        let controller = FullScreenCodeViewController.makeHarnessController(
            content: .orgMode(content: Self.orgManualDoc, filePath: "org-manual.org"),
            reviewCommentSelectionContext: reviewContext
        )
        let window = try Self.makeTestWindow()
        let shellStarted = DispatchTime.now().uptimeNanoseconds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        let shellDurationUs = (DispatchTime.now().uptimeNanoseconds - shellStarted) / 1_000
        defer { window.isHidden = true }

        let body = try #require(
            controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody,
            "Completed Org must enter the shared virtualized Markdown reader"
        )
        #expect(shellDurationUs < 1_000_000, "reader shell took \(shellDurationUs)µs")
        #expect(body.debugIsSourcePreparationPendingForTesting)
        #expect(body.debugRenderedSegmentCountForTesting == 0)

        await body.debugWaitForDocumentPreparationForTesting()
        window.layoutIfNeeded()
        body.debugLayoutVisibleMarkdownCellsForTesting()

        #expect(body.debugSourcePreparationRanOnMainThreadForTesting == false)
        #expect(body.debugAsyncMarkdownBuildRanOnMainThreadForTesting == false)
        #expect(body.debugRenderedSourceTextForTesting == expectedMarkdown)
        #expect(body.debugRenderedSourceTextForTesting?.contains("orgtbl-radio-table-templates") == true)
        #expect(body.debugRenderedSegmentCountForTesting > body.debugVisibleCellCountForTesting)
        #expect(body.debugAppliedItemCountForTesting < body.debugRenderedSegmentCountForTesting)
        #expect(body.debugInitialSynchronousPreparationItemCountForTesting <= 8)
        #expect(body.debugMaxRenderAheadItemsPerSliceForTesting <= 2)

        print("ORG_READER_METRIC shell_us=\(shellDurationUs)")
        print("ORG_READER_METRIC source_bytes=\(Self.orgManualDoc.utf8.count)")
        print("ORG_READER_METRIC converted_bytes=\(expectedMarkdown.utf8.count)")
        print("ORG_READER_METRIC conversion_us=\(body.debugSourcePreparationDurationUsForTesting)")
        print("ORG_READER_METRIC segment_count=\(body.debugRenderedSegmentCountForTesting)")
        print("ORG_READER_METRIC applied_count=\(body.debugAppliedItemCountForTesting)")
        print("ORG_READER_METRIC visible_count=\(body.debugVisibleCellCountForTesting)")
        window.isHidden = true

        do {
            let linkedController = UIHostingController(rootView: OrgModeFileView(
                content: Self.orgManualDoc,
                filePath: "org-manual.org",
                presentation: .document
            ))
            let linkedWindow = try Self.makeTestWindow()
            linkedWindow.rootViewController = linkedController
            linkedWindow.makeKeyAndVisible()
            linkedController.loadViewIfNeeded()
            linkedWindow.layoutIfNeeded()

            let linkedBody = try #require(
                Self.firstDescendant(
                    of: NativeFullScreenMarkdownBody.self,
                    in: linkedController.view
                ),
                "Linked Org document must install the shared Markdown reader"
            )
            #expect(linkedBody.debugIsSourcePreparationPendingForTesting)
            #expect(linkedBody.debugRenderedSegmentCountForTesting == 0)
            await linkedBody.debugWaitForDocumentPreparationForTesting()
            linkedWindow.layoutIfNeeded()
            linkedBody.debugLayoutVisibleMarkdownCellsForTesting()
            #expect(linkedBody.debugRenderedSourceTextForTesting == expectedMarkdown)
            #expect(linkedBody.debugAppliedItemCountForTesting < linkedBody.debugRenderedSegmentCountForTesting)
            linkedWindow.isHidden = true
        }

        do {
            let inlineController = UIHostingController(rootView: OrgModeFileView(
                content: Self.orgManualDoc,
                filePath: "org-manual.org",
                presentation: .inline
            ))
            let inlineWindow = try Self.makeTestWindow()
            inlineWindow.rootViewController = inlineController
            inlineWindow.makeKeyAndVisible()
            inlineController.loadViewIfNeeded()
            inlineWindow.layoutIfNeeded()
            let inlineBody = try #require(Self.firstDescendant(
                of: NativeFullScreenMarkdownBody.self,
                in: inlineController.view
            ))
            await inlineBody.debugWaitForDocumentPreparationForTesting()
            inlineWindow.layoutIfNeeded()
            #expect(inlineBody.bounds.height > 0)
            #expect(abs(inlineBody.bounds.height - 500) <= 0.5)
            inlineWindow.isHidden = true
        }

        let sourceController = FullScreenCodeViewController.makeHarnessController(
            content: .orgMode(
                content: "#+title: Toggle check\n\n* Complete source",
                filePath: "toggle-check.org"
            ),
            reviewCommentSelectionContext: nil
        )
        sourceController.loadViewIfNeeded()
        #expect(sourceController.installedBodyViewForTesting is NativeFullScreenMarkdownBody)
        sourceController.toggleSourceForTesting()
        #expect(sourceController.installedBodyViewForTesting is NativeFullScreenCodeBody)
        sourceController.toggleSourceForTesting()
        #expect(sourceController.installedBodyViewForTesting is NativeFullScreenMarkdownBody)
    }

    @MainActor
    @Test("One-line inline Org preview uses its natural height")
    func oneLineInlineOrgPreviewUsesNaturalHeight() async throws {
        let controller = UIHostingController(rootView: OrgModeFileView(
            content: "* Short preview",
            filePath: "short.org",
            presentation: .inline
        ))
        let window = try Self.makeTestWindow()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        let body = try #require(Self.firstDescendant(
            of: NativeFullScreenMarkdownBody.self,
            in: controller.view
        ))
        await body.debugWaitForDocumentPreparationForTesting()
        window.layoutIfNeeded()

        #expect(body.bounds.height > 20)
        #expect(body.bounds.height < 200)
    }

    @Test("Org conversion skips later stages when cancelled after parsing")
    func orgConversionSkipsLaterStagesAfterParsingCancellation() {
        // The parser is synchronous; check 2 is the cooperative boundary
        // immediately after parsing and before conversion or serialization.
        let probe = OrgConversionCancellationProbe(cancelAtCheck: 2)
        let markdown = DocumentRenderPipeline.orgToMarkdown(
            Self.orgManualDoc,
            cancellationCheck: { probe.shouldCancel() }
        )
        #expect(markdown == nil)
        #expect(probe.checkCount == 2)
    }

    @MainActor
    private static func makeTestWindow() throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 844)
        return window
    }

    @MainActor
    private static func firstDescendant<T: UIView>(of type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = firstDescendant(of: type, in: child) { return match }
        }
        return nil
    }

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

        // Measure the complete conversion work now dispatched off-main:
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

private final class OrgConversionCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAtCheck: Int
    private var storedCheckCount = 0

    init(cancelAtCheck: Int) {
        self.cancelAtCheck = cancelAtCheck
    }

    var checkCount: Int {
        lock.withLock { storedCheckCount }
    }

    func shouldCancel() -> Bool {
        lock.withLock {
            storedCheckCount += 1
            return storedCheckCount >= cancelAtCheck
        }
    }
}
