import XCTest

/// The reader's task controls, driven on a fixture workspace whose files live on
/// the simulator's disk behind the real edit routes. Each step is checked in the
/// bytes the save left on disk, not in what the reader redraws.
@MainActor
final class ReaderTaskEditUITests: XCTestCase, PreviewUITestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
#if !targetEnvironment(simulator)
        throw XCTSkip("Reader task controls run on the simulator's disk fixture")
#endif
        continueAfterFailure = false
    }

    // MARK: Org

    func testOrgCheckboxStateAndDatesEditTheFileOnDisk() throws {
        launch(file: "tasks.org")
        XCTAssertEqual(disk, Self.orgSeed, "the fixture starts from its seed")

        // 1. A checkbox: the box and the heading's cookie change, nothing else.
        tap("fileViewer.task.checkbox.5")
        var expected = Self.orgSeed
            .replacingOccurrences(of: "- [ ] Toggle a checkbox", with: "- [X] Toggle a checkbox")
            .replacingOccurrences(of: "Ship the reader [1/3]", with: "Ship the reader [2/3]")
        waitForDisk(expected, after: "toggling the checkbox")

        // 2. A date: the day moves, the repeater stays.
        tap("fileViewer.task.scheduled.3")
        XCTAssertTrue(app.buttons["fileViewer.task.datePicker.done"].waitUntilExists(timeout: 10), "the date picker opens")
        pickDay("November 18")
        saveScreenshot(name: "reader-task-date-picker")
        app.buttons["fileViewer.task.datePicker.done"].tap()
        expected = expected.replacingOccurrences(of: "SCHEDULED: <2026-11-11 Wed +1w>", with: "SCHEDULED: <2026-11-18 Wed +1w>")
        waitForDisk(expected, after: "changing the scheduled date")

        // 3. A state: the menu lists the file's own states, and done writes CLOSED
        //    in front of the planning line's DEADLINE.
        tap("fileViewer.task.state.9")
        XCTAssertTrue(app.buttons["fileViewer.task.stateMenu.DONE"].waitUntilExists(timeout: 10), "the state menu opens")
        for state in ["TODO", "NEXT", "WAIT", "DONE", "CANCELLED"] {
            XCTAssertTrue(app.buttons["fileViewer.task.stateMenu.\(state)"].exists, "the menu offers #+TODO's \(state)")
        }
        XCTAssertTrue(app.buttons["fileViewer.task.stateMenu.none"].exists, "the menu offers No state")
        saveScreenshot(name: "reader-task-state-menu")
        app.buttons["fileViewer.task.stateMenu.DONE"].tap()
        expected = expected
            .replacingOccurrences(of: "* TODO Write the notes", with: "* DONE Write the notes")
            .replacingOccurrences(of: "DEADLINE: <2026-11-20 Fri>", with: "CLOSED: [STAMP] DEADLINE: <2026-11-20 Fri>")
        waitForDisk(expected, after: "moving into a done state")

        // 4. A plain heading draws no state; its text menu holds the state menu,
        //    which sets a date the heading has none of.
        XCTAssertFalse(app.buttons["fileViewer.task.state.12"].exists, "a plain heading stays plain")
        let plain = app.staticTexts["Plain heading"]
        XCTAssertTrue(plain.waitUntilExists(timeout: 10))
        plain.press(forDuration: 1.0)
        let state = app.descendants(matching: .any).matching(identifier: "fileViewer.task.textMenu.state").firstMatch
        let stateEntry = state.waitUntilExists(timeout: 5) ? state : app.menuItems["State"]
        XCTAssertTrue(stateEntry.waitUntilExists(timeout: 5), "the heading's text menu offers its state")
        saveScreenshot(name: "reader-task-text-menu")
        stateEntry.tap()
        let addDeadline = app.descendants(matching: .any).matching(identifier: "fileViewer.task.stateMenu.addDeadline").firstMatch
        XCTAssertTrue(addDeadline.waitUntilExists(timeout: 10), "a heading without a deadline offers to set one")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "fileViewer.task.stateMenu.addScheduled").firstMatch.exists,
            "and a schedule"
        )
        saveScreenshot(name: "reader-task-text-menu-state")
        addDeadline.tap()
        XCTAssertTrue(app.buttons["fileViewer.task.datePicker.done"].waitUntilExists(timeout: 10))
        pickDay("November 25")
        app.buttons["fileViewer.task.datePicker.done"].tap()
        expected = expected.replacingOccurrences(of: "* Plain heading\n", with: "* Plain heading\nDEADLINE: <2026-11-25 Wed>\n")
        waitForDisk(expected, after: "setting a deadline on a heading that had none")

        // 5. Clear removes the entry, and the line with it.
        tap("fileViewer.task.deadline.12")
        XCTAssertTrue(app.buttons["fileViewer.task.datePicker.clear"].waitUntilExists(timeout: 10))
        app.buttons["fileViewer.task.datePicker.clear"].tap()
        expected = expected.replacingOccurrences(of: "DEADLINE: <2026-11-25 Wed>\n", with: "")
        waitForDisk(expected, after: "clearing the deadline")
    }

    func testMovingOutOfDoneRemovesClosedAndKeepsTheRestOfTheLine() throws {
        launch(file: "tasks.org")
        tap("fileViewer.task.state.9")
        app.buttons["fileViewer.task.stateMenu.DONE"].tap()
        XCTAssertTrue(waitForDisk { $0.contains("CLOSED: [") }, "done writes CLOSED")
        tap("fileViewer.task.state.9")
        app.buttons["fileViewer.task.stateMenu.WAIT"].tap()
        waitForDisk(Self.orgSeed.replacingOccurrences(of: "* TODO Write the notes", with: "* WAIT Write the notes"), after: "leaving done")
    }

    /// A file that changed on disk is a conflict, handled by the editor's own
    /// banner; the reader's edit never overwrites it.
    func testAFileChangedOnDiskOpensTheEditorsConflictInsteadOfOverwriting() throws {
        launch(file: "tasks.org")
        app.buttons["harness.readerTask.changeDisk"].tap()
        let changed = Self.orgSeed + "\nChanged elsewhere.\n"
        waitForDisk(changed, after: "the other writer")

        tap("fileViewer.task.checkbox.5")
        XCTAssertTrue(
            app.descendants(matching: .any)["workspace-file-editor.banner"].waitUntilExists(timeout: 10),
            "the editor opens on its conflict banner"
        )
        XCTAssertTrue(app.buttons["workspace-file-editor.review"].exists || app.buttons["workspace-file-editor.use-disk"].exists)
        XCTAssertEqual(disk, changed, "the other writer's file was not overwritten")
        saveScreenshot(name: "reader-task-conflict")
    }

    // MARK: Markdown

    func testMarkdownCheckboxesToggleWithALowercaseXAndRecountTheHeading() throws {
        launch(file: "notes.md")
        XCTAssertEqual(disk, Self.markdownSeed)
        tap("fileViewer.task.checkbox.3")
        var expected = Self.markdownSeed
            .replacingOccurrences(of: "- [ ] Tag the build", with: "- [x] Tag the build")
            .replacingOccurrences(of: "# Release plan [1/3]", with: "# Release plan [2/3]")
        waitForDisk(expected, after: "toggling a Markdown task")

        // A nested task changes only its own line: its parent has no cookie.
        tap("fileViewer.task.checkbox.6")
        expected = expected.replacingOccurrences(of: "  - [ ] Reviewer one", with: "  - [x] Reviewer one")
        waitForDisk(expected, after: "toggling a nested task")

        tap("fileViewer.task.checkbox.4")
        expected = expected
            .replacingOccurrences(of: "- [x] Write the notes", with: "- [ ] Write the notes")
            .replacingOccurrences(of: "# Release plan [2/3]", with: "# Release plan [1/3]")
        waitForDisk(expected, after: "unchecking a Markdown task")
    }

    // MARK: Read-only

    func testAFileTheServerCannotSaveShowsNoControls() throws {
        launch(file: "tasks.org", readOnly: true)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Toggle a checkbox'")).firstMatch.waitUntilExists(timeout: 10),
            "the file is shown"
        )
        for id in [
            "fileViewer.task.checkbox.5",
            "fileViewer.task.state.3",
            "fileViewer.task.scheduled.3",
        ] {
            XCTAssertFalse(app.buttons[id].exists, "\(id) must not be tappable in a read-only file")
        }
    }

    // MARK: Helpers

    private static let orgSeed = """
    #+TODO: TODO NEXT WAIT | DONE CANCELLED

    * NEXT [#A] Ship the reader [1/3] :oppi:
    SCHEDULED: <2026-11-11 Wed +1w>
    - [ ] Toggle a checkbox
    - [X] Pick a date
    - [ ] Change a state

    * TODO Write the notes
    DEADLINE: <2026-11-20 Fri>

    * Plain heading
    Some prose.
    """

    private static let markdownSeed = """
    # Release plan [1/3]

    - [ ] Tag the build
    - [x] Write the notes
    - [ ] Ask for review
      - [ ] Reviewer one
    """

    private func launch(file: String, readOnly: Bool = false) {
        var environment = ["OPPI_READER_TASK_FILE": file]
        if readOnly { environment["OPPI_READER_TASK_READONLY"] = "1" }
        launchPreview(screen: "reader-task-edit", environment: environment, readyTimeout: 20)
        if !readOnly {
            let first = file == "tasks.org" ? "fileViewer.task.checkbox.5" : "fileViewer.task.checkbox.3"
            XCTAssertTrue(app.buttons[first].waitUntilExists(timeout: 20), "the reader draws its task controls")
        }
    }

    /// The file's text on disk, with the CLOSED time made a fixed stamp.
    private var disk: String {
        let value = app.descendants(matching: .any)["diag.readerTask.disk"].value as? String ?? ""
        return value.replacingOccurrences(
            of: #"CLOSED: \[\d{4}-\d{2}-\d{2} [A-Za-z]{3} \d{2}:\d{2}\]"#,
            with: "CLOSED: [STAMP]",
            options: .regularExpression
        )
    }

    @discardableResult
    private func waitForDisk(_ matches: (String) -> Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if matches(disk) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return matches(disk)
    }

    private func waitForDisk(_ expected: String, after step: String) {
        waitForDisk { $0 == expected }
        XCTAssertEqual(disk, expected, "the file on disk after \(step)")
    }

    private func tap(_ identifier: String) {
        let control = app.buttons[identifier]
        XCTAssertTrue(control.waitUntilExists(timeout: 15), "\(identifier) exists")
        control.tap()
    }

    /// A day in the inline calendar by the date its accessibility label names.
    private func pickDay(_ monthAndDay: String) {
        let predicate = NSPredicate(format: "label CONTAINS %@", monthAndDay)
        let picker = app.datePickers.firstMatch
        XCTAssertTrue(picker.waitUntilExists(timeout: 10), "the date picker is up")
        let day = picker.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(day.waitUntilExists(timeout: 5), "the calendar shows \(monthAndDay)")
        day.tap()
    }

    private func saveScreenshot(name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // The shared screenshot directory also holds other sessions' captures: write only to this suite's own folder.
        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots/reader-interactive", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
}
