import Foundation
import XCTest

/// Paired-server proof that a binary file over the text viewer's 10 MB limit
/// opens from the file browser as a file card, not a load error, and that
/// Share downloads it to the device and offers the share sheet. Run through
/// `clients/apple/scripts/e2e.sh --native` (iPad: `OPPI_SIM_DEVICE_PROFILE=ipad`).
@MainActor
final class FileBrowserFileCardE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceName = ""

    override var e2eLaunchesWorkspaceHomeOnly: Bool { true }

    override var e2eRequiresFreshLaunch: Bool { true }

    override func seedE2EFixtures() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        workspaceName = "file-card-\(suffix)"
        let fixture = try createLabWorkspaceFileFixture(
            directoryName: "oppi-e2e-file-card-\(suffix)",
            filename: Self.filename,
            // An empty archive's end record, padded with zeros past the limit.
            base64: "UEsFBgAAAAAAAAAAAAAAAAAAAAAAAA==",
            sizeBytes: Self.byteCount
        )
        _ = try createLabWorkspace(named: workspaceName, hostMount: fixture.hostMount)
    }

    func testALargeArchiveOpensAsACardAndShares() throws {
        XCTAssertTrue(revealWorkspace(named: workspaceName, timeout: 25), "Seeded workspace did not appear")
        app.buttons["workspace.open.\(workspaceName)"].coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.50)).tap()
        XCTAssertTrue(app.buttons["workspace.files.open"].waitForExistence(timeout: 15), "Workspace detail did not load")
        tap(app.buttons["workspace.files.open"], named: "workspace files button")

        let row = app.staticTexts[Self.filename]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The archive is not listed")
        tap(row, named: "archive row")

        let summary = app.staticTexts["fileViewer.card.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "The archive did not open as a file card")
        XCTAssertTrue(summary.label.contains("12"), "The card states the size (\(summary.label))")
        XCTAssertFalse(app.staticTexts["Unable to Load"].exists, "No load error under the card")
        XCTAssertFalse(app.buttons["Retry"].exists, "No Retry for a file that cannot be shown")
        try saveLabScreenshot(name: "file-card-archive")

        tap(app.buttons["fileViewer.card.share"], named: "card Share")
        let shareSheet = app.otherElements["ActivityListView"].firstMatch
        if !shareSheet.waitForExistence(timeout: 60) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "hierarchy without a share sheet"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail("Share did not download the archive and present the share sheet")
        }
        // The sheet draws its header and rows a moment after its list exists.
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        try saveLabScreenshot(name: "file-card-archive-share")
    }

    nonisolated private static let filename = "archive-sample.zip"
    nonisolated private static let byteCount = 12 * 1_000_000
}
