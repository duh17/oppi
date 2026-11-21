import XCTest

/// Edit Sidebar in the real workspace shell over fixture services
/// (`SCREENSHOT_SCREEN=workspace-shell`): Edit beside the sidebar's app icon
/// opens the shared Customize screen, a popover on the iPad mini and a sheet
/// over the drawer on iPhone. Hiding Terminal and dragging Rex above Agents
/// change this device's sidebar, a relaunch keeps them, and Reset to Default
/// brings the default order back.
@MainActor
final class SidebarEditUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Sidebar journeys are simulator-only")
#endif
        continueAfterFailure = false
    }

    /// The split view: the sidebar stays in view beside the popover.
    func testEditSidebarPopoverOnTheIPadMiniInLandscape() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The split view needs the iPad mini in landscape")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        runJourney(device: "ipad", showSidebar: {})
    }

    /// The compact shell: Edit Sidebar opens as a sheet over the drawer.
    func testEditSidebarSheetOverTheDrawerOnIPhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "The drawer on a phone")
        XCUIDevice.shared.orientation = .portrait
        runJourney(device: "iphone") { [self] in
            app.buttons["workspace.sidebar.open"].tap()
            XCTAssertTrue(waitFor(isShowing(app.buttons["workspace.allSessions.open"])), "The drawer did not open")
        }
    }

    private func runJourney(device: String, showSidebar: () -> Void) {
        launchShell()
        showSidebar()
        let edit = app.buttons["workspace.sidebar.edit"]
        XCTAssertTrue(edit.waitUntilExists(timeout: 5), "The sidebar header has no Edit")
        let icon = app.descendants(matching: .any)["workspace.sidebar.appIcon"]
        XCTAssertEqual(edit.label, "Edit Sidebar", "The glyph speaks as Edit Sidebar")
        XCTAssertGreaterThanOrEqual(min(edit.frame.width, edit.frame.height), 44, "Edit keeps a 44 pt target")
        XCTAssertEqual(edit.frame.midY, icon.frame.midY, accuracy: 1, "Edit is centred on the app icon")
        XCTAssertGreaterThanOrEqual(edit.frame.minX - icon.frame.maxX, 8, "Edit keeps at least 8 pt from the icon")
        let initial = sidebarOrder()
        XCTAssertTrue(initial.contains("terminal") && initial.contains("rex"), "The fixture offers Terminal and Rex: \(initial)")
        XCTAssertEqual(initial, Self.defaultOrder.filter(initial.contains), "The fixture starts with the default sidebar")
        capture("\(device)-edit-button")

        edit.tap()
        let list = app.collectionViews["workspace.sidebar.edit.list"]
        XCTAssertTrue(list.waitUntilExists(timeout: 5), "Edit Sidebar did not open")
        XCTAssertTrue(app.cells["workspace.sidebar.edit.row.agents"].waitUntilExists(timeout: 5), "Edit Sidebar lists the places")
        if device == "ipad" {
            XCTAssertTrue(
                app.buttons["workspace.sidebar.edit.features"].waitUntilExists(timeout: 5),
                "A server with feature switches has the Features row"
            )
        }
        capture("\(device)-edit-sidebar")

        app.switches["workspace.sidebar.edit.terminal"].tap()
        let rex = app.cells["workspace.sidebar.edit.row.rex"]
        let agents = app.cells["workspace.sidebar.edit.row.agents"]
        for _ in 0..<3 where !rex.isHittable { list.swipeUp() }
        XCTAssertTrue(rex.isHittable, "Rex's row is in view")
        rex.buttons["workspace.sidebar.edit.row.rex"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.8,
                thenDragTo: agents.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
                withVelocity: .slow,
                thenHoldForDuration: 0.5
            )
        XCTAssertTrue(waitFor(rex.frame.maxY <= agents.frame.minY + 1), "Rex did not move above Agents")
        hold()
        capture("\(device)-edit-sidebar-changed")
        close(list, device: device)

        let changed = initial.filter { $0 != "terminal" }.reordered(moving: "rex", before: "agents")
        XCTAssertTrue(waitFor(sidebarOrder() == changed), "The sidebar shows the change at once: \(sidebarOrder())")

        launchShell()
        showSidebar()
        XCTAssertTrue(waitFor(sidebarOrder() == changed), "A relaunch keeps this device's sidebar: \(sidebarOrder())")
        capture("\(device)-sidebar-after-relaunch")

        app.buttons["workspace.sidebar.edit"].tap()
        let reset = app.buttons["workspace.sidebar.edit.reset"]
        for _ in 0..<3 where !reset.exists { list.swipeUp() }
        XCTAssertTrue(reset.waitUntilExists(timeout: 5), "Reset to Default shows once the sidebar changed")
        reset.tap()
        XCTAssertTrue(reset.waitUntilGone(timeout: 5), "Reset to Default leaves once the sidebar is the default")
        close(list, device: device)
        XCTAssertTrue(waitFor(sidebarOrder() == initial), "Reset restores the default sidebar: \(sidebarOrder())")
        assertRunning()
    }

    /// The popover closes with a tap outside it and has no Done; the sheet
    /// closes with Done.
    private func close(_ list: XCUIElement, device: String) {
        let done = app.buttons["barCustomize.done"]
        if device == "ipad" {
            XCTAssertFalse(done.exists, "A popover has no Done")
            app.tapOutsidePopover(list)
        } else {
            done.tap()
        }
        XCTAssertTrue(list.waitUntilGone(timeout: 10), "Edit Sidebar did not close")
    }

    /// The fixture server's places in the default order; All Sessions first.
    private static let defaultOrder = ["allSessions", "pinned", "agents", "schedules", "extensions", "terminal", "rex"]

    /// The sidebar's built-in places, top to bottom, by the last part of each
    /// row's `workspace.<place>.open` id.
    private func sidebarOrder() -> [String] {
        Self.defaultOrder
            .map { (name: $0, row: app.buttons["workspace.\($0).open"]) }
            .filter { $0.row.exists }
            .sorted { $0.row.frame.minY < $1.row.frame.minY }
            .map(\.name)
    }

    private func isShowing(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
    }

    private func launchShell() {
        // A server with feature switches (Herdr off has no sidebar place), so
        // Edit Sidebar has its Features row.
        launchPreview(screen: "workspace-shell", environment: ["SCREENSHOT_FEATURES_OFF": "herdr"], colorScheme: "dark", ready: nil)
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitUntilExists(timeout: 10), "The workspace shell did not appear")
    }

    /// The whole screen as the simulator shows it, popover and all.
    private func capture(_ name: String) {
        let attachment = XCTAttachment(uprightScreenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension Array where Element == String {
    func reordered(moving element: String, before other: String) -> [String] {
        var result = filter { $0 != element }
        result.insert(element, at: result.firstIndex(of: other) ?? result.endIndex)
        return result
    }
}
