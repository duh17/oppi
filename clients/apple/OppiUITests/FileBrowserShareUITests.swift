import XCTest

/// Share from the File Browser's rows and from the file viewer, on the
/// workspace route's fixture (`SCREENSHOT_SCREEN=file-browser-column`, its
/// `media/` folder) and the video viewer's (`file-viewer-video`). The fixture
/// server answers the raw-file route the app downloads through, so the share
/// sheet gets the file the app wrote to its temporary folder.
@MainActor
final class FileBrowserShareUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private static let screenshotDirectory = "/tmp/oppi-file-share"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func row(_ path: String) -> XCUIElement { app.buttons["fileBrowser.row.\(path)"] }
    private var shareAction: XCUIElement { app.buttons["fileBrowser.rowMenu.share"].firstMatch }
    /// The row's own Open. On the iPad, where Split Panes ships on, Open Here
    /// stands in for it, with Open in New Pane beside it (`PaneOpenMenu`).
    private var rowOpenAction: XCUIElement { app.buttons["fileBrowser.rowMenu.open"].firstMatch }
    private var openHereAction: XCUIElement { app.buttons["pane.open.here"].firstMatch }
    private var openInNewPaneAction: XCUIElement { app.buttons["pane.open.newPane.right"].firstMatch }
    private var openAction: XCUIElement { isPad ? openHereAction : rowOpenAction }
    private var paneItems: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane.open.'"))
    }
    private var copyPathAction: XCUIElement { app.buttons["fileBrowser.rowMenu.copyPath"].firstMatch }
    private var viewerShare: XCUIElement { app.buttons["fileViewer.share"].firstMatch }
    private var progress: XCUIElement { app.otherElements["fileBrowser.share.progress"].firstMatch }
    private var progressStatus: XCUIElement { app.staticTexts["fileBrowser.share.status"].firstMatch }
    /// The system share sheet's list, which has no identifier of the app's.
    private var shareSheet: XCUIElement { app.otherElements["ActivityListView"].firstMatch }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func launchMediaFolder(openFile: String? = nil, splitPanes: Bool = true) {
        var environment = ["SCREENSHOT_FILE_BROWSER_FOLDER": "media/"]
        if let openFile { environment["SCREENSHOT_FILE_BROWSER_FILE"] = openFile }
        launchPreview(
            screen: "file-browser-column",
            environment: environment,
            colorScheme: "dark",
            arguments: OppiTestLaunch.experimentArguments([.splitPanes: splitPanes]),
            readyTimeout: 20
        )
        guard openFile == nil || isPad else { return }
        XCTAssertTrue(row("media/harvest.mp4").waitUntilExists(timeout: 20), "the media folder lists its files")
    }

    /// Regular width presents the share sheet as a popover that points at what
    /// opened it; compact width presents a sheet with no anchor.
    private func assertAnchored(to source: CGRect, _ what: String) {
        guard isPad else { return }
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitUntilExists(timeout: 5), "the share sheet is a popover in regular width")
        XCTAssertTrue(
            popover.frame.intersects(source.insetBy(dx: -60, dy: -60)),
            "the share popover \(popover.frame) points at \(what) \(source)"
        )
    }

    private func openRowMenu(_ path: String) {
        let target = row(path)
        XCTAssertTrue(target.waitUntilExists(timeout: 10), "\(path) is listed")
        target.press(forDuration: 1)
        XCTAssertTrue(copyPathAction.waitUntilExists(timeout: 5), "a long press on \(path) opens its menu")
    }

    private func assertShareSheet(_ message: String) {
        if !shareSheet.waitUntilExists(timeout: 20) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "hierarchy without a share sheet"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail(message)
        }
        // The sheet draws its header and rows a moment after its list exists.
        hold(for: 2)
    }

    /// Long press on a file row, Share…, and the system share sheet comes up
    /// with the downloaded file.
    func testLongPressOnAFileRowSharesTheFile() {
        launchMediaFolder()
        openRowMenu("media/harvest.mp4")
        XCTAssertTrue(shareAction.exists, "a file's menu offers Share")
        XCTAssertTrue(openAction.exists, "and Open (Open Here on the iPad)")
        if isPad {
            XCTAssertFalse(rowOpenAction.exists, "Open Here stands in for Open")
            XCTAssertTrue(openInNewPaneAction.exists, "beside Open in New Pane")
        }
        XCTAssertLessThan(shareAction.frame.minY, openAction.frame.minY, "Share is the first action")
        XCTAssertLessThan(openAction.frame.minY, copyPathAction.frame.minY)
        save("row-menu-\(device)")

        let rowFrame = row("media/harvest.mp4").frame
        shareAction.tap()
        assertShareSheet("Share… presents the share sheet for the row's file")
        assertAnchored(to: rowFrame, "the row")
        XCTAssertFalse(progress.exists, "a small file shows no progress")
        save("share-sheet-video-row-\(device)")
    }

    /// The server has no folder download, so a folder's menu has no Share.
    func testAFolderRowOffersOpenAndCopyPathOnly() {
        launchMediaFolder()
        openRowMenu("media/stills/")
        XCTAssertTrue(openAction.exists, "a folder's menu offers Open (Open Here on the iPad)")
        if isPad { XCTAssertTrue(openInNewPaneAction.exists, "and Open in New Pane") }
        hold()
        XCTAssertFalse(shareAction.exists, "a folder cannot be shared")
        save("row-menu-folder-\(device)")
    }

    /// With Split Panes off the iPad window has one pane: a row's menu offers
    /// its own Open and no pane items, and Open opens the file beside the list.
    func testWithSplitPanesOffAnIPadRowOffersOpen() throws {
        guard isPad else { throw XCTSkip("The phone's menu never has pane items") }
        launchMediaFolder(splitPanes: false)
        openRowMenu("media/raised-beds.png")
        XCTAssertTrue(rowOpenAction.exists, "the row's menu offers Open")
        XCTAssertEqual(paneItems.count, 0, "and no pane items")
        XCTAssertLessThan(shareAction.frame.minY, rowOpenAction.frame.minY)
        XCTAssertLessThan(rowOpenAction.frame.minY, copyPathAction.frame.minY)
        save("row-menu-split-panes-off-\(device)")

        rowOpenAction.tap()
        XCTAssertTrue(viewerShare.waitUntilExists(timeout: 20), "Open opened the image")
    }

    /// A large download shows how far it is; when its connection drops it
    /// says it is reconnecting and resumes where it stopped; Cancel stops it
    /// before any share sheet.
    func testASlowDownloadShowsProgressReconnectsAndCancels() {
        launchMediaFolder()
        openRowMenu("media/long-take.mov")
        shareAction.tap()
        XCTAssertTrue(progress.waitUntilExists(timeout: 10), "a slow download shows its progress")
        XCTAssertTrue(
            waitFor(self.progressStatus.label.contains("MB of 1.2 GB"), timeout: 10),
            "the progress says how much of the file has arrived (\(progressStatus.label))"
        )
        save("share-progress-\(device)")
        // The fixture's first connection drops a quarter of the way in.
        XCTAssertTrue(
            waitFor(self.progressStatus.label.contains("Reconnecting"), timeout: 15),
            "a dropped connection says it is reconnecting (\(progressStatus.label))"
        )
        save("share-reconnecting-\(device)")
        XCTAssertTrue(
            waitFor(!self.progressStatus.label.contains("Reconnecting") && self.progressStatus.label.contains("of 1.2 GB"), timeout: 15),
            "the download resumes (\(progressStatus.label))"
        )
        hold(for: 3)
        save("share-resumed-\(device)")

        app.buttons["fileBrowser.share.cancel"].firstMatch.tap()
        XCTAssertTrue(progress.waitUntilGone(timeout: 5))
        XCTAssertFalse(shareSheet.waitForExistence(timeout: 3), "a cancelled download shares nothing")
        save("share-cancelled-\(device)")
    }

    /// A file over the server's size limit says so, with the server's reason.
    func testAFileOverTheServerLimitSaysSo() {
        launchMediaFolder()
        openRowMenu("media/sensor-trace.log")
        shareAction.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitUntilExists(timeout: 10), "an over-limit file raises an alert")
        let reason = NSPredicate(format: "label CONTAINS 'max 10MB'")
        XCTAssertTrue(
            alert.staticTexts.matching(reason).firstMatch.waitUntilExists(timeout: 5),
            "the alert carries the server's limit"
        )
        save("share-too-large-\(device)")
        XCTAssertFalse(shareSheet.exists)
    }

    /// A Markdown file's row shares the Markdown file itself.
    func testAMarkdownRowSharesTheFile() {
        launchMediaFolder()
        openRowMenu("media/planting-notes.md")
        shareAction.tap()
        assertShareSheet("Share… presents the share sheet for the Markdown file")
        save("share-sheet-markdown-\(device)")
    }

    /// An open image has Share in the bar, beside the tree in regular width
    /// and alone in compact width. The fixture opens the file itself in
    /// compact width: it has no app shell for a row's file route.
    func testAnOpenImageSharesFromItsBar() {
        if isPad {
            launchMediaFolder()
            row("media/raised-beds.png").tap()
        } else {
            launchMediaFolder(openFile: "raised-beds.png")
        }
        XCTAssertTrue(viewerShare.waitUntilExists(timeout: 20), "the image viewer's bar has Share")
        let buttonFrame = viewerShare.frame
        viewerShare.tap()
        assertShareSheet("the viewer's Share presents the share sheet for the image")
        assertAnchored(to: buttonFrame, "the Share button")
        save("share-sheet-image-\(device)")
    }

    /// The video viewer has Share in its bar; it downloads the video and
    /// presents the share sheet.
    func testTheVideoViewerSharesItsFile() {
        launchPreview(screen: "file-viewer-video", colorScheme: "dark", readyTimeout: 20)
        XCTAssertTrue(viewerShare.waitUntilExists(timeout: 20), "the video viewer's bar has Share")
        hold(for: 2)
        save("video-viewer-share-button-\(device)")

        let buttonFrame = viewerShare.frame
        viewerShare.tap()
        assertShareSheet("the video viewer's Share presents the share sheet")
        assertAnchored(to: buttonFrame, "the Share button")
        save("share-sheet-video-\(device)")
    }

    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(uprightScreenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.createDirectory(atPath: Self.screenshotDirectory, withIntermediateDirectories: true)
        try? screenshot.uprightPNG.write(
            to: URL(fileURLWithPath: "\(Self.screenshotDirectory)/\(name).png"),
            options: .atomic
        )
    }
}
