import XCTest

/// The file reader's own bar on a Markdown file, as a chat link opens it
/// (`SCREENSHOT_SCREEN=reader-task-edit`, `OPPI_READER_TASK_CHROME=pushed`):
/// its buttons and … are one glass group, a narrow bar keeps the first ones
/// in the Reader Bar order, every … row has a title and an icon, the source
/// toggle shows whether the source is on, and Share presents the share sheet.
@MainActor
final class ReaderBarUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    private static let screenshotDirectory = "/tmp/oppi-reader-bar"

    /// The reader's buttons for this file, in the default Reader Bar order.
    private static let barOrder = [
        "workspace-file-editor.edit", "fileViewer.find.button", "fileViewer.outline.button",
        "fullscreen-code.copy", "fileViewer.share", "fileViewer.sourceToggle", "fullscreen.viewingOptions.button",
    ]

    /// A … row with no title reads its icon's own label (Copy's row read
    /// "copy"). These titled rows happen to read the same as their icon.
    private static let titlesLikeTheirIcon: Set = ["Share"]

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("The reader runs on the simulator's disk fixture")
#endif
        continueAfterFailure = false
    }

    /// The bar and its … in both themes: one group, the first buttons in
    /// order, and every row titled with an icon.
    func testTheBarIsOneGroupAndEveryMenuRowHasATitleAndAnIcon() {
        for scheme in ["light", "dark"] {
            launch(colorScheme: scheme)
            let shown = assertOneGroup()
            XCTAssertEqual(
                shown, Array(Self.barOrder.prefix(shown.count)),
                "a narrow bar keeps the first buttons of the Reader Bar order and crowds out the rest"
            )
            save("bar-\(scheme)")

            let rows = openMenu()
            for row in rows {
                let icons = row.images.allElementsBoundByIndex.filter { $0.identifier != "chevron.forward" }
                XCTAssertFalse(icons.isEmpty, "the … row \"\(row.label)\" has its icon")
                let readsItsIcon = icons.contains { $0.label == row.label }
                XCTAssertTrue(
                    !row.label.isEmpty && (!readsItsIcon || Self.titlesLikeTheirIcon.contains(row.label)),
                    "the … row \"\(row.label)\" reads its title, not its icon's name"
                )
            }
            let crowdedOut = Self.barOrder.filter { !shown.contains($0) }
            if crowdedOut.contains("fileViewer.share") {
                let share = menuRow("share.menu.share")
                XCTAssertEqual(share.label, "Share")
                XCTAssertFalse(share.images["chevron.forward"].exists, "Share runs at once; it is not a submenu")
                XCTAssertTrue(menuRow("share.menu.shareAs").images["chevron.forward"].exists, "Share As holds the formats")
            }
            save("menu-\(scheme)")
        }
    }

    /// Source keeps its title and shows whether it is on: selected in the
    /// bar, checked in the … menu.
    func testTheSourceToggleShowsItsState() {
        launch(colorScheme: "light")
        XCTAssertFalse(sourceToggle().isSelected, "the rendered view opens with Source off")
        XCTAssertEqual(sourceToggle().label, "Source")
        sourceToggle().tap()
        let on = sourceToggle()
        XCTAssertTrue(waitFor(on.isSelected), "Source shows that it is on")
        XCTAssertEqual(on.label, "Source", "the toggle keeps its title")
        save("source-on")
        on.tap()
        XCTAssertTrue(waitFor(!self.sourceToggle().isSelected), "and off again")
    }

    /// Share presents the share sheet at once, from the bar or from the …
    /// that crowded it out; a popover in regular width points at it.
    func testSharePresentsTheShareSheetWithTheDocument() {
        launch(colorScheme: "light")
        let barShare = app.buttons["fileViewer.share"].firstMatch
        let anchor: CGRect
        if barShare.exists, barShare.isHittable {
            anchor = barShare.frame
            barShare.tap()
        } else {
            anchor = app.barOverflowButton.frame
            _ = openMenu()
            menuRow("share.menu.share").tap()
        }
        let sheet = app.otherElements["ActivityListView"].firstMatch
        if !sheet.waitUntilExists(timeout: 20) {
            attachHierarchy("no share sheet")
            XCTFail("Share presents the share sheet")
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let popover = app.popovers.firstMatch
            XCTAssertTrue(popover.waitUntilExists(timeout: 5), "the share sheet is a popover in regular width")
            XCTAssertTrue(
                popover.frame.intersects(anchor.insetBy(dx: -60, dy: -60)),
                "the share popover \(popover.frame) points at what opened it \(anchor)"
            )
        }
        // The sheet's header and rows are a remote view the pool's slimmed
        // simulator leaves unlabelled, so what it carries is
        // `FileShareServiceTests`' to prove.
        save("share-sheet")
    }

    // MARK: Steps

    private func launch(colorScheme: String) {
        XCUIDevice.shared.orientation = .portrait
        launchPreview(
            screen: "reader-task-edit",
            environment: ["OPPI_READER_TASK_FILE": "notes.md", "OPPI_READER_TASK_CHROME": "pushed"],
            colorScheme: colorScheme,
            ready: nil,
            readyTimeout: 20
        )
        // The pencil joins once the fixture server's capabilities arrive.
        XCTAssertTrue(app.buttons["workspace-file-editor.edit"].firstMatch.waitUntilExists(timeout: 20), "the reader shows notes.md")
        XCTAssertTrue(app.barOverflowButton.waitUntilExists(timeout: 5), "the reader has its …")
        hold()
    }

    /// The reader's buttons the bar draws, in bar order, after checking that
    /// they and the … sit evenly spaced in one line (or one column on the
    /// Duo's rail): a second glass group adds its own padding between them.
    @discardableResult
    private func assertOneGroup() -> [String] {
        let back = app.buttons["fullScreen.code.close"].firstMatch
        XCTAssertTrue(back.exists && back.isHittable, "Back stays on the bar; it never folds into …")
        let drawn = Self.barOrder.map { app.buttons[$0].firstMatch }.filter { $0.exists && $0.isHittable }
        let frames = (drawn + [app.barOverflowButton]).map(\.frame)
        let vertical = Set(frames.map { Int($0.midX.rounded()) }).count == 1
        let line = vertical ? frames.sorted { $0.minY < $1.minY } : frames.sorted { $0.minX < $1.minX }
        XCTAssertEqual(
            Set(line.map { Int((vertical ? $0.midX : $0.midY).rounded()) }).count, 1,
            "the buttons and … share one \(vertical ? "column" : "row"): \(line)"
        )
        if vertical {
            // The Duo's rail runs down the screen's trailing edge, as in every
            // other screen, not inset beside the clock column.
            let screen = app.windows.firstMatch.frame
            XCTAssertLessThan(screen.maxX - (line.first?.maxX ?? 0), 60, "the rail sits at the screen's edge (\(line.first ?? .zero) in \(screen))")
        }
        let gaps = zip(line, line.dropFirst()).map { vertical ? $1.minY - $0.maxY : $1.minX - $0.maxX }
        XCTAssertGreaterThanOrEqual(gaps.count, 2, "the bar draws the reader's buttons")
        XCTAssertLessThanOrEqual(
            (gaps.max() ?? 0) - (gaps.min() ?? 0), 1,
            "the bar's buttons and … are one glass group, evenly spaced (gaps \(gaps))"
        )
        return drawn.map(\.identifier)
    }

    /// Opens the … and returns its rows.
    private func openMenu() -> [XCUIElement] {
        app.barOverflowButton.tap()
        XCTAssertTrue(app.buttons["fileViewer.menu.customize"].waitUntilExists(timeout: 5), "the … opens with Customize Bar…")
        return menu.buttons.allElementsBoundByIndex
    }

    private var menu: XCUIElement {
        app.collectionViews.containing(.button, identifier: "fileViewer.menu.customize").firstMatch
    }

    private func menuRow(_ identifier: String) -> XCUIElement {
        let row = menu.buttons[identifier].firstMatch
        XCTAssertTrue(row.waitUntilExists(timeout: 5), "the … holds \(identifier)")
        return row
    }

    /// The source toggle where the bar puts it: its button, or its … row (the
    /// menu opened to read it).
    private func sourceToggle() -> XCUIElement {
        let button = app.buttons["fileViewer.sourceToggle"].firstMatch
        if !menu.exists, button.exists, button.isHittable { return button }
        if !menu.exists { _ = openMenu() }
        return menuRow("fileViewer.sourceToggle")
    }

    private func attachHierarchy(_ name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    /// Keeps a screenshot in the result bundle and the screenshot folder,
    /// named for the device so the three profiles do not overwrite each other.
    private func save(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "device"
        let file = "\(model)-\(name)"
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.createDirectory(atPath: Self.screenshotDirectory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: "\(Self.screenshotDirectory)/\(file).png"), options: .atomic)
    }
}
