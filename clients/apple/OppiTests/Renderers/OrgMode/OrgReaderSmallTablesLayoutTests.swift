import Testing
import UIKit
@testable import Oppi

/// An Org file of sub-headings and small tables opens and its layout settles.
/// Render-ahead parks each measured block until its cell shows it. A parked
/// table that kept no width re-planned at every width its own constraints gave
/// it (clip, then grid, then clip), so each layout pass dirtied it again and
/// the app froze inside the next Core Animation commit.
@MainActor
@Suite("Org reader small tables layout", .serialized)
struct OrgReaderSmallTablesLayoutTests {
    nonisolated private static let table = "| a | b |\n|---+---|\n| 1 | 2 |\n"
    nonisolated private static let tables = "* Notes\n" + String(repeating: table + "\n", count: 180)
    nonisolated private static let subheadingsAndTables = "* Notes\n" + String(repeating: "** Item\n" + table, count: 125)

    @Test(
        "a 5 KB Org file of small tables opens and leaves no view needing layout",
        .timeLimit(.minutes(1)),
        arguments: [tables, subheadingsAndTables]
    )
    func smallTablesSettle(_ org: String) async throws {
        let body = NativeFullScreenMarkdownBody(
            content: org,
            sourceFormat: .orgMode,
            palette: ThemeID.dark.palette,
            reviewCommentSelectionRouter: nil,
            reviewCommentSourceContext: nil,
            sourceFilePath: "notes.org",
            centersReadingColumn: true
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(body)
        body.frame = window.bounds
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        let started = ContinuousClock.now
        await body.debugWaitForDocumentPreparationForTesting()
        let settled = await waitForMainActorCondition(timeout: .seconds(20)) {
            body.layoutIfNeeded()
            return body.debugRenderedSegmentCountForTesting > 0 && !body.debugHasDeferredReaderWorkForTesting
        }
        try #require(settled, "the reader built and measured the document")
        #expect(body.debugParkedHostForTesting.subviews.contains { $0 is NativeTableBlockView }, "render-ahead parked a table")

        // One layout pass settles a stable hierarchy. A view still dirty after
        // it would be laid out again by every commit: the freeze.
        body.layoutIfNeeded()
        let dirty = Self.views(in: body).filter { $0.layer.needsLayout() }
        #expect(dirty.isEmpty, "still needing layout: \(dirty.prefix(4).map { "\(type(of: $0)) \($0.frame)" })")
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { views(in: $0) }
    }
}
