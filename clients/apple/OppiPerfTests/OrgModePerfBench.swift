import Foundation
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
        // Group resources are copied flat into the bundle.
        let candidates = [
            bundle.resourceURL?.appendingPathComponent(name),
            bundle.resourceURL?.appendingPathComponent("Fixtures/\(name)"),
            bundle.bundleURL.appendingPathComponent("Fixtures/\(name)"),
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
        // The reader draws a fold chevron on each heading that has a section.
        let expectedMarkdown = await Task.detached(priority: .userInitiated) {
            DocumentRenderPipeline.orgToMarkdown(
                Self.orgManualDoc,
                documentPath: "org-manual.org",
                foldingHeadings: .init(),
                cancellationCheck: { false }
            ) ?? ""
        }.value
        #expect(Self.orgManualDoc.utf8.count == 853_547)
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

    /// A fold converts the kept parse again and renders the visible part again.
    /// The first toggle also parses; the later ones, which a person makes, do not.
    @MainActor
    @Test("Fold toggle — org-manual", .timeLimit(.minutes(2)))
    func foldToggleOrgManual() async throws {
        try await measureFoldToggle(doc: Self.orgManualDoc, label: "org_manual")
    }

    /// A notebook file as the notebook keeps them: about 150 lines, 12 KB, with
    /// states, planning lines, property drawers, links and checkboxes.
    private static let notebookDoc: String = {
        var text = "#+TITLE: Notebook\n#+TODO: TODO NEXT WAIT | DONE CANCELLED\n\n"
        for n in 1 ... 6 {
            text += """
            * NEXT [#A] Project \(n) milestone [1/3] :oppi:ios:
            SCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri>
            :PROPERTIES:
            :ID: 3f2a9c1e-7b64-4d0a-9d1e-0c5a2b7e8f1\(n)
            :END:
            Parser, converter and reader for project \(n). See [[file:release.org::*Checklist][the release checklist]] and [[id:3f2a9c1e-7b64-4d0a-9d1e-0c5a2b7e8f1\(n)][this task]].
            - [X] Parse planning lines
            - [ ] Render progress cookies
            - [ ] Open file links from the reader, relative to the document
            ** DONE Draft the brief :oppi:
            CLOSED: [2026-11-06 Fri 14:00]
            Scope was agreed in the planning thread, and the notes are kept with the project.
            ** WAIT Device check [40%]
            SCHEDULED: <2026-11-12 Thu>
            Waiting on a simulator slot; the run takes a few minutes once one frees up.
            *** TODO Record the screenshots
            - [ ] iPhone
            - [ ] iPad mini
            ** CANCELLED Retire the old extension
            CLOSED: [2026-11-05 Thu 09:30]
            * Notes \(n)
            - No dev install until Wednesday. See [[*Project \(n) milestone][the task above]].

            """
        }
        return text
    }()

    @MainActor
    @Test("Fold toggle — notebook-sized file", .timeLimit(.minutes(2)))
    func foldToggleNotebook() async throws {
        try await measureFoldToggle(doc: Self.notebookDoc, label: "notebook")
    }

    @MainActor
    @Test("Fold toggle — Doom", .timeLimit(.minutes(2)))
    func foldToggleDoom() async throws {
        try await measureFoldToggle(doc: Self.doomDoc, label: "doom")
    }

    @MainActor
    private func measureFoldToggle(doc: String, label: String) async throws {
        let controller = FullScreenCodeViewController.makeHarnessController(
            content: .orgMode(content: doc, filePath: "\(label).org"),
            reviewCommentSelectionContext: nil
        )
        let window = try Self.makeTestWindow()
        let openStarted = DispatchTime.now().uptimeNanoseconds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        defer { window.isHidden = true }
        let body = try #require(controller.installedBodyViewForTesting as? NativeFullScreenMarkdownBody)
        let controls = try #require(body.debugOrgControlsForTesting)
        await body.debugWaitForSourcePreparationForTesting()
        print("ORG_FOLD_METRIC \(label) open_to_converted_us=\((DispatchTime.now().uptimeNanoseconds - openStarted) / 1_000)")
        await body.debugWaitForDocumentPreparationForTesting()
        window.layoutIfNeeded()
        body.debugLayoutVisibleMarkdownCellsForTesting()
        print("ORG_FOLD_METRIC \(label) open_to_rendered_us=\((DispatchTime.now().uptimeNanoseconds - openStarted) / 1_000) phases: \(body.debugFirstPaintDiagnosticsForTesting)")
        let openMarkdown = try #require(body.debugRenderedSourceTextForTesting)

        // Folds hide a section each; the ordinal is the manual's first heading.
        print("ORG_FOLD_METRIC \(label) bytes=\(doc.utf8.count) lines=\(doc.split(separator: "\n", omittingEmptySubsequences: false).count)")
        var toggleUs: [UInt64] = []
        var firstContentUs: [UInt64] = []
        var conversionUs: [UInt64] = []
        for _ in 0 ..< 6 {
            let started = DispatchTime.now().uptimeNanoseconds
            controls.toggleFold(ordinal: 1)
            await body.debugWaitForSourcePreparationForTesting()
            firstContentUs.append((DispatchTime.now().uptimeNanoseconds - started) / 1_000)
            await body.debugWaitForDocumentPreparationForTesting()
            window.layoutIfNeeded()
            body.debugLayoutVisibleMarkdownCellsForTesting()
            toggleUs.append((DispatchTime.now().uptimeNanoseconds - started) / 1_000)
            conversionUs.append(body.debugSourcePreparationDurationUsForTesting)
        }
        #expect(controls.folded.isEmpty, "an even number of toggles leaves the document open")
        #expect(body.debugRenderedSourceTextForTesting == openMarkdown)
        toggleUs.sort()
        firstContentUs.sort()
        conversionUs.sort()
        let phases = body.debugFirstPaintDiagnosticsForTesting
        print("ORG_FOLD_METRIC \(label) last_toggle phases: \(phases)")
        print("ORG_FOLD_METRIC \(label) toggle_to_converted_and_rendered_median_us=\(firstContentUs[firstContentUs.count / 2])")
        print("ORG_FOLD_METRIC \(label) toggle_to_render_median_us=\(toggleUs[toggleUs.count / 2]) max_us=\(toggleUs.last ?? 0)")
        print("ORG_FOLD_METRIC \(label) conversion_median_us=\(conversionUs[conversionUs.count / 2])")
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
