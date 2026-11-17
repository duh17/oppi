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
        // It has prose under it, so it is a foldable heading: one element with its words as the label.
        let plain = fold(3)
        reveal(plain)
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

    /// The reader draws the saved file again; the person stays where they were
    /// reading, not back at the top.
    func testASaveKeepsTheReadingPosition() throws {
        launch(file: "tasks.org", long: true)
        let row = try XCTUnwrap(disk.components(separatedBy: "\n").firstIndex(of: "- [ ] bottom box")) + 1
        let box = app.buttons["fileViewer.task.checkbox.\(row)"]
        let visibleBottom = app.windows.firstMatch.frame.maxY - 60
        for _ in 0..<15 where !(box.exists && box.frame.maxY < visibleBottom && box.frame.minY > 100) { app.swipeUp() }
        let before = box.frame
        XCTAssertLessThan(before.maxY, visibleBottom, "the last task is on screen")
        box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForDisk(Self.orgSeed + Self.longTail.replacingOccurrences(of: "- [ ] bottom box", with: "- [X] bottom box"), after: "toggling the last task")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, abs(box.frame.minY - before.minY) >= 4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(box.frame.minY, before.minY, accuracy: 4, "the redrawn reader keeps the scroll position")
    }

    // MARK: Heading folds

    /// Folding a heading hides everything under it up to the next heading of
    /// the same or a higher level, and the bullet's state reads as the
    /// heading's value.
    func testHeadingsFoldAndUnfoldTheirSections() throws {
        launch(file: "notebook.org")
        XCTAssertEqual(foldValue(1), "Expanded", "a file opens with everything expanded")
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.19"].exists)
        saveScreenshot(name: "org-fold-1-expanded")

        // A level-2 heading folds its own section only: its checkboxes go, its
        // parent and its next sibling stay.
        tapHeading(3)
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.19"].waitUntilGone(timeout: 10), "the folded section is hidden")
        XCTAssertTrue(waitForFold(3, "Collapsed"))
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.10"].exists, "the parent's own body stays")
        XCTAssertTrue(fold(5).exists, "the next heading of the same level stays")
        XCTAssertFalse(fold(4).exists, "a heading inside the fold goes with it")
        saveScreenshot(name: "org-fold-2-device-check-collapsed")

        // The top heading hides every level below it, up to the next top heading.
        tapHeading(1)
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.10"].waitUntilGone(timeout: 10))
        for ordinal in [2, 3, 5] { XCTAssertFalse(fold(ordinal).exists, "heading \(ordinal) is inside the top fold") }
        XCTAssertTrue(fold(6).exists, "the next top-level heading stays")
        saveScreenshot(name: "org-fold-3-top-collapsed")

        // Opening it again returns the section as it was: the inner fold is kept.
        tapHeading(1)
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.10"].waitUntilExists(timeout: 10))
        XCTAssertTrue(waitForFold(3, "Collapsed"))
        XCTAssertFalse(app.buttons["fileViewer.task.checkbox.19"].exists)
        tapHeading(3)
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.19"].waitUntilExists(timeout: 10))
        XCTAssertTrue(waitForFold(3, "Expanded"))
        saveScreenshot(name: "org-fold-4-expanded-again")
    }

    /// The bullet before a heading's words carries its fold: a tap on the
    /// bullet folds the section, and a tap on the heading's words unfolds it.
    func testTheBulletFoldsAndUnfoldsItsHeading() throws {
        launch(file: "notebook.org")
        let heading = fold(3)
        XCTAssertTrue(scrollUntilBuilt(heading), "fold 3 exists")
        reveal(heading)
        let lineStart = heading.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        // The bullet is the line's first glyph, about a text height wide.
        lineStart.withOffset(CGVector(dx: 9, dy: 0)).tap()
        XCTAssertTrue(waitForFold(3, "Collapsed"), "a tap on the bullet folds")
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.19"].waitUntilGone(timeout: 10), "the section is hidden")
        saveScreenshot(name: "org-bullet-folded")
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertTrue(waitForFold(3, "Expanded"), "a tap on the heading's words unfolds")
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.19"].waitUntilExists(timeout: 10), "the section is back")
    }

    /// A still of a notes file: three levels of bullets and colours, states,
    /// tags, and one folded subtree.
    func testOrgHeadingStills() throws {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        XCUIDevice.shared.orientation = .portrait
        launch(file: "notebook.org", colorScheme: "dark")
        tapHeading(2)
        XCTAssertTrue(waitForFold(2, "Collapsed"), "the done heading folds")
        saveScreenshot(name: "org-headings-\(device)-dark")
    }

    /// A saved edit mounts a new reader; the folds stay as the person left them,
    /// and the box they ticked stays where it was on screen.
    func testFoldsAndPositionSurviveASavedEdit() throws {
        launch(file: "notebook.org")
        tapHeading(3)
        XCTAssertTrue(app.buttons["fileViewer.task.checkbox.19"].waitUntilGone(timeout: 10))
        let box = app.buttons["fileViewer.task.checkbox.32"]
        let visibleBottom = app.windows.firstMatch.frame.maxY - 30
        for _ in 0..<10 where !(box.exists && box.frame.maxY < visibleBottom && box.frame.minY > 100) { app.swipeUp() }
        XCTAssertTrue(box.exists && box.frame.maxY < visibleBottom, "the last box is on screen")
        let before = box.frame
        box.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // `disk` shows each CLOSED time as a fixed stamp; the seed's are the same.
        let ticked = Self.notebookSeed
            .replacingOccurrences(of: "- [ ] Review the screenshots", with: "- [X] Review the screenshots")
            .replacingOccurrences(of: #"CLOSED: \[\d{4}-\d{2}-\d{2} [A-Za-z]{3} \d{2}:\d{2}\]"#, with: "CLOSED: [STAMP]", options: .regularExpression)
        waitForDisk(ticked, after: "ticking the last box")

        XCTAssertTrue(waitForFold(3, "Collapsed"), "the fold survives the save")
        XCTAssertFalse(app.buttons["fileViewer.task.checkbox.19"].exists)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, abs(box.frame.minY - before.minY) >= 4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertEqual(box.frame.minY, before.minY, accuracy: 4, "the box stays where it was")
    }

    /// Folding or unfolding a heading far down a long file leaves that heading
    /// where it was on screen, as in an outliner: only what is under it moves.
    /// Both a heading in the middle of the screen and one near its top.
    func testAFoldKeepsTheHeadingWhereItIsOnScreen() throws {
        launch(file: "outline.org")
        let window = app.windows.firstMatch.frame
        for _ in 0..<5 { app.swipeUp() }

        let middle = try XCTUnwrap(
            visibleHeading(within: window.minY + window.height * 0.35...window.minY + window.height * 0.65),
            "a heading sits in the middle of the screen"
        )
        assertFoldKeepsPlace(middle, name: "middle")

        app.swipeUp()
        let nearTop = try XCTUnwrap(
            visibleHeading(within: window.minY + 140...window.minY + window.height * 0.3),
            "a heading sits near the top of the screen"
        )
        assertFoldKeepsPlace(nearTop, name: "top")
    }

    /// Folding edits nothing, so a file the server cannot save still folds,
    /// and still shows no edit control.
    func testAReadOnlyFileFolds() throws {
        launch(file: "notebook.org", readOnly: true)
        // The first screen holds the first task line: drawn, and without a control.
        XCTAssertTrue(fold(1).waitUntilExists(timeout: 20), "the reader draws its headings")
        XCTAssertFalse(app.buttons["fileViewer.task.checkbox.10"].exists, "no edit control")
        // Each heading is its own cell, so a heading below the screen has no fold until it scrolls in.
        XCTAssertTrue(scrollUntilBuilt(fold(7)), "the heading offers a fold")
        tapHeading(7, at: 0.5)
        XCTAssertTrue(waitForFold(7, "Collapsed"))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No dev install'")).firstMatch.waitUntilExists(timeout: 2))
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

    private func fold(_ ordinal: Int) -> XCUIElement {
        app.descendants(matching: .any)["fileViewer.heading.fold.\(ordinal)"]
    }

    private func foldValue(_ ordinal: Int) -> String? {
        let element = fold(ordinal)
        return element.waitUntilExists(timeout: 15) ? element.value as? String : nil
    }

    /// Scrolls down until the element exists. The reader builds a cell only for what is near
    /// the screen, so a heading further down has no fold element until it scrolls in.
    private func scrollUntilBuilt(_ element: XCUIElement) -> Bool {
        if element.waitUntilExists(timeout: 5) { return true }
        for _ in 0..<12 {
            app.swipeUp()
            if element.waitUntilExists(timeout: 1) { return true }
        }
        return false
    }

    /// Scrolls until the element's line is on screen: a coordinate tap does not scroll.
    private func reveal(_ element: XCUIElement) {
        let bottom = app.windows.firstMatch.frame.maxY - 90
        for _ in 0..<8 where element.frame.maxY > bottom { app.swipeUp() }
    }

    /// The ordinal of a heading whose top is inside `band`, with a few headings
    /// after it so a fold has something under it to take away.
    private func visibleHeading(within band: ClosedRange<CGFloat>) -> Int? {
        let prefix = "fileViewer.heading.fold."
        let headings = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
        return headings.lazy
            .compactMap { element -> (Int, CGRect)? in
                guard let ordinal = Int(element.identifier.dropFirst(prefix.count)) else { return nil }
                return (ordinal, element.frame)
            }
            .first { ordinal, frame in band.contains(frame.minY) && ordinal < 38 }?
            .0
    }

    /// The heading's top once it has stopped moving: the reader measures what
    /// it redrew over the next few turns.
    private func settledTop(_ ordinal: Int) -> CGFloat {
        var last = fold(ordinal).frame.minY
        var still = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, still < 4 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let next = fold(ordinal).frame.minY
            still = abs(next - last) < 0.5 ? still + 1 : 0
            last = next
        }
        return last
    }

    private func assertFoldKeepsPlace(_ ordinal: Int, name: String) {
        let before = fold(ordinal).frame.minY
        saveScreenshot(name: "fold-keeps-position-\(name)-1-before")
        fold(ordinal).coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 10, dy: 0)).tap()
        XCTAssertTrue(waitForFold(ordinal, "Collapsed"), "\(name): heading \(ordinal) folds")
        let folded = settledTop(ordinal)
        saveScreenshot(name: "fold-keeps-position-\(name)-2-folded")
        XCTAssertEqual(folded, before, accuracy: 1, "\(name): heading \(ordinal) stays where it was after the fold")

        fold(ordinal).coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 10, dy: 0)).tap()
        XCTAssertTrue(waitForFold(ordinal, "Expanded"), "\(name): heading \(ordinal) unfolds")
        let unfolded = settledTop(ordinal)
        saveScreenshot(name: "fold-keeps-position-\(name)-3-unfolded")
        XCTAssertEqual(unfolded, before, accuracy: 1, "\(name): heading \(ordinal) stays where it was after the unfold")
    }

    private func waitForFold(_ ordinal: Int, _ value: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fold(ordinal).exists, fold(ordinal).value as? String == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return fold(ordinal).value as? String == value
    }

    /// Taps the heading's bullet, at the start of its line: a touch on a state
    /// badge would open that badge's menu, and a long heading wraps its badges
    /// anywhere along the line. `at` taps that far across the line instead.
    private func tapHeading(_ ordinal: Int, at dx: CGFloat? = nil) {
        let element = fold(ordinal)
        XCTAssertTrue(scrollUntilBuilt(element), "fold \(ordinal) exists")
        reveal(element)
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        if let dx {
            element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
        } else {
            start.withOffset(CGVector(dx: 10, dy: 0)).tap()
        }
    }

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

    /// What `OPPI_READER_TASK_LONG` adds to the Org seed.
    private static let longTail = (1...60).map { "\n\nParagraph \($0) of filler prose that makes the file long enough to scroll." }.joined()
        + "\n\n* TODO Bottom\n- [ ] bottom box\n- [ ] second box"

    private static let notebookSeed = """
    #+TITLE: Oppi project
    #+TODO: TODO NEXT WAIT | DONE CANCELLED

    * NEXT [#A] Ship Org rendering [1/3] :oppi:ios:
    SCHEDULED: <2026-11-11 Wed> DEADLINE: <2026-11-13 Fri>
    :PROPERTIES:
    :ID: 3f2a9c1e-7b64-4d0a-9d1e-0c5a2b7e8f10
    :END:
    Parser, converter and reader. See [[file:release.org::*Checklist][the release checklist]].
    - [X] Parse planning lines
    - [ ] Render progress cookies
    ** DONE Draft the brief :oppi:
    CLOSED: [2026-11-06 Fri 14:00]
    Scope was agreed in the planning thread.
    ** WAIT Device check [40%]
    SCHEDULED: <2026-11-12 Thu>
    Waiting on a simulator slot.
    *** TODO Record the screenshots
    - [ ] iPhone
    - [ ] iPad mini
    ** CANCELLED Retire the old extension
    CLOSED: [2026-11-05 Thu 09:30]
    * TODO Write the release notes
    DEADLINE: <2026-11-20 Fri>
    :PROPERTIES:
    :ID: 9d1c4e7a-2b08-4c63-8a5f-6e3b1d0f7a22
    :END:
    Draft after the device check.
    * Notes
    - No dev install until Wednesday.
    - See [[*Ship Org rendering][the task above]] and [[https://example.com][the docs]].
    - [ ] Review the screenshots
    """

    private static let markdownSeed = """
    # Release plan [1/3]

    - [ ] Tag the build
    - [x] Write the notes
    - [ ] Ask for review
      - [ ] Reviewer one
    """

    private func launch(
        file: String,
        readOnly: Bool = false,
        long: Bool = false,
        colorScheme: String? = nil
    ) {
        var environment = ["OPPI_READER_TASK_FILE": file]
        if readOnly { environment["OPPI_READER_TASK_READONLY"] = "1" }
        if long { environment["OPPI_READER_TASK_LONG"] = "1" }
        launchPreview(screen: "reader-task-edit", environment: environment, colorScheme: colorScheme, readyTimeout: 20)
        if !readOnly {
            let first = switch file {
            case "tasks.org": app.buttons["fileViewer.task.checkbox.5"]
            case "notebook.org": app.buttons["fileViewer.task.checkbox.10"]
            case "outline.org": fold(1)
            default: app.buttons["fileViewer.task.checkbox.3"]
            }
            XCTAssertTrue(first.waitUntilExists(timeout: 20), "the reader draws its task controls")
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
