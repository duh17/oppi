import XCTest

/// Pins against the real server: a folder of the server's home folder is
/// pinned from its row's menu, shows in the Home root's Pinned section, and
/// opens from there as that folder's File Browser.
@MainActor
final class FileBrowserPinsE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    override func tearDownWithError() throws {
        // Pins outlive a case on the shared server; leave none behind.
        if let revision = try? e2eLabAPIJSON(method: "GET", path: "/pins")["revision"] as? Int {
            _ = try? e2eLabAPIJSON(method: "PUT", path: "/pins", body: ["baseRevision": revision, "pins": [Any]()])
        }
        try super.tearDownWithError()
    }

    func testPinAHomeFolderAndOpenItFromPinned() {
        tap(app.buttons["workspace.files.open"], named: "Files", timeout: 10)

        // The home folder's first row, whatever its name: folders sort first and
        // hidden files show by default, so a home with many dot-folders still
        // builds this row on screen while a later, unhidden one stays off it.
        let folders = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'fileBrowser.row.' AND identifier ENDSWITH '/'"
        ))
        let folder = folders.firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 15), "the home folder lists a folder")
        let name = String(folder.identifier.dropFirst("fileBrowser.row.".count).dropLast())

        folder.press(forDuration: 1.0)
        tap(app.buttons["fileBrowser.pin.add"], named: "Pin", timeout: 5)

        let pinned = app.cells["fileBrowser.pin.~/\(name)"]
        XCTAssertTrue(pinned.waitForExistence(timeout: 10), "\(name) shows in the Pinned section")
        XCTAssertTrue(
            (try? e2eLabAPIJSON(method: "GET", path: "/pins")["pins"] as? [[String: Any]])?.count == 1,
            "the server keeps the pin"
        )
        folder.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["fileBrowser.pin.remove"].waitForExistence(timeout: 5), "the pinned folder's menu offers Unpin")
        // Close the menu with a tap outside it, on the bar.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["fileBrowser.pin.remove"].waitForNonExistence(timeout: 5), "the menu closed")

        tap(pinned, named: "pinned \(name)", timeout: 5)
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), "the pin opens \(name) in the File Browser")
    }
}
