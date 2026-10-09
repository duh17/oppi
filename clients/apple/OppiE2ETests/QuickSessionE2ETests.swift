import XCTest

/// Focused Quick Session coverage kept outside the release gate.
final class QuickSessionE2ETests: E2ETestCase {
    override var e2eLaunchesSessionsInboxOnly: Bool { true }

    @MainActor
    func testQuickSessionChoosesWorkspaceModelThinkingAndSendsToChat() throws {
        XCTAssertTrue(
            waitForElementToExist(app.collectionViews["workspace.sessionList"], timeout: 20),
            "Sessions inbox did not appear"
        )

        tap(app.buttons["workspace.quickSession.start"], named: "quick session button")
        let input = app.textViews["chat.input"]
        XCTAssertTrue(waitForElementToExist(input, timeout: 20), "Quick Session input did not appear")

        tap(app.buttons["quickSession.workspacePicker"], named: "quick session workspace picker", timeout: 5)
        let workspaceRow = app.buttons["quickSession.workspace.e2e-workspace"]
        XCTAssertTrue(waitForElementToExist(workspaceRow, timeout: 10), "E2E workspace did not appear in Quick Session picker")
        tap(workspaceRow, named: "e2e workspace quick session row", timeout: 1)
        let expectedWorkspaceId = try e2eWorkspaceId()

        tap(app.buttons["session.toolbar.model"], named: "quick session model picker", timeout: 5)
        let modelRow = firstElement(identifierPrefix: "model.picker.row.")
        XCTAssertTrue(waitForElementToExist(modelRow, timeout: 20), "Model picker did not show any selectable model")
        let selectedModel = String(modelRow.identifier.dropFirst("model.picker.row.".count))
        tap(modelRow, named: "first model row", timeout: 1)
        XCTAssertTrue(waitForElementToExist(input, timeout: 10), "Quick Session input did not return after model selection")

        tap(app.buttons["session.toolbar.thinking"], named: "quick session thinking menu", timeout: 5)
        assertThinkingMenuRunsFromMaxToOff()
        tap(thinkingOption("high"), named: "High thinking option", timeout: 5)

        let marker = "E2E_QUICK_SESSION_SEND_OK"
        typeIntoTextView(input, text: marker)
        tap(app.buttons["chat.send"], named: "quick session send button", timeout: 5)

        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(waitForElementToExist(chatInput, timeout: 30), "Created chat did not open")
        let sessionId = waitForFocusedSessionId(timeout: 30)
        XCTAssertTrue(waitForTimelineTextContaining(marker, timeout: 30), "Quick Session prompt did not appear in the created chat")

        focusTextView(chatInput)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "Normal chat keyboard did not appear before opening the thinking picker"
        )
        tap(app.buttons["session.toolbar.thinking"], named: "normal chat thinking menu", timeout: 5)
        assertThinkingMenuRunsFromMaxToOff()
        tap(thinkingOption("high"), named: "current High thinking option", timeout: 5)

        let session = try e2eSession(sessionId: sessionId)
        XCTAssertEqual(session["workspaceId"] as? String, expectedWorkspaceId)
        let actualModel = try XCTUnwrap(session["model"] as? String, "Quick Session did not send the selected model override")
        XCTAssertTrue(
            actualModel == selectedModel || selectedModel.hasSuffix("/\(actualModel)"),
            "Quick Session model mismatch. selected=\(selectedModel), actual=\(actualModel)"
        )
        XCTAssertEqual(session["thinkingLevel"] as? String, "high")
    }

    @MainActor
    func testQuickSessionStarSavesPiOrSelectedAgentDefault() throws {
        XCTAssertTrue(waitForElementToExist(app.collectionViews["workspace.sessionList"], timeout: 20))
        let initialModels = try e2eLabAPIJSON(method: "GET", path: "/models")["models"] as? [[String: Any]] ?? []
        let modelId = try XCTUnwrap(
            initialModels.compactMap { $0["id"] as? String }.first { $0.hasPrefix("mlx-serve/") },
            "The isolated E2E server must expose its pinned mlx-serve model"
        )
        let originalPiDefault = initialModels.first(where: { $0["isDefault"] as? Bool == true })?["id"] as? String
        XCTAssertNil(originalPiDefault, "The isolated E2E Pi settings must have no default before this test")

        let agentResponse = try e2eLabAPIJSON(method: "POST", path: "/agents", body: [
            "name": "Quick star agent \(UUID().uuidString.prefix(8))",
            "sessionDefaults": ["thinkingLevel": "high"],
        ])
        let agent = try XCTUnwrap(agentResponse["agent"] as? [String: Any])
        let agentId = try XCTUnwrap(agent["id"] as? String)
        openQuickSession()
        tap(app.buttons["quickSession.agentPicker"], named: "choose saved Agent")
        tap(app.buttons["quickSession.agent.\(agentId)"], named: "saved Agent", timeout: 10)
        tap(app.buttons["session.toolbar.model"], named: "Agent model picker")
        let agentModelSearch = app.searchFields["Search models…"]
        if !agentModelSearch.exists { app.swipeDown() }
        tap(agentModelSearch, named: "search for pinned Agent model")
        agentModelSearch.typeText("E2E MLX Serve Model")
        let agentStar = app.buttons["Set as default"]
        if !waitForElementToExist(agentStar, timeout: 5) {
            print("[e2e] Agent model picker accessibility: \(app.debugDescription)")
        }
        XCTAssertTrue(agentStar.exists, "Pinned Agent model star was not accessible")
        tap(agentStar, named: "save Agent default")
        assertModelPickerDismissed()
        let saved = try e2eLabAPIJSON(method: "GET", path: "/agents/\(agentId)")
        let definition = try XCTUnwrap((saved["agent"] as? [String: Any])?["definition"] as? [String: Any])
        let defaults = try XCTUnwrap(definition["sessionDefaults"] as? [String: Any])
        XCTAssertEqual(defaults["model"] as? String, modelId)
        XCTAssertEqual(defaults["thinkingLevel"] as? String, "high")
        let unchangedPiModels = try e2eLabAPIJSON(method: "GET", path: "/models")["models"] as? [[String: Any]] ?? []
        XCTAssertNil(unchangedPiModels.first(where: { $0["isDefault"] as? Bool == true }),
                     "Saving an Agent default must not change Pi's global default")
        dismissQuickSession()

        openQuickSession()
        tap(app.buttons["quickSession.agentPicker"], named: "choose Pi")
        tap(app.buttons["quickSession.agent.pi"], named: "plain Pi", timeout: 10)
        tap(app.buttons["session.toolbar.model"], named: "Pi model picker")
        let piModelSearch = app.searchFields["Search models…"]
        if !piModelSearch.exists { app.swipeDown() }
        tap(piModelSearch, named: "search for pinned Pi model")
        piModelSearch.typeText("E2E MLX Serve Model")
        let piStar = app.buttons["Set as default"]
        if !waitForElementToExist(piStar, timeout: 5) {
            print("[e2e] Pi model picker accessibility: \(app.debugDescription)")
        }
        tap(piStar, named: "save Pi default")
        assertModelPickerDismissed()
        let piModels = try e2eLabAPIJSON(method: "GET", path: "/models")["models"] as? [[String: Any]] ?? []
        XCTAssertEqual(piModels.first(where: { $0["isDefault"] as? Bool == true })?["id"] as? String, modelId)
    }

    @MainActor
    func testQuickSessionDraftSurvivesDismissalAndRelaunch() {
        XCTAssertTrue(
            waitForElementToExist(app.collectionViews["workspace.sessionList"], timeout: 20),
            "Sessions inbox did not appear"
        )

        let marker = "E2E_QUICK_SESSION_RESTORED_\(UUID().uuidString)"
        openQuickSession()
        replaceText(in: app.textViews["chat.input"], with: marker)
        dismissQuickSession()

        openQuickSession()
        XCTAssertEqual(
            app.textViews["chat.input"].value as? String,
            marker,
            "Quick Session draft did not survive overlay dismissal"
        )
        dismissQuickSession()

        app.terminate()
        app.launch()
        XCTAssertTrue(
            waitForElementToExist(app.collectionViews["workspace.sessionList"], timeout: 30),
            "Sessions inbox did not return after relaunch"
        )

        openQuickSession()
        let restoredInput = app.textViews["chat.input"]
        XCTAssertEqual(
            restoredInput.value as? String,
            marker,
            "Quick Session draft did not survive app relaunch"
        )

        replaceText(in: restoredInput, with: "")
        dismissQuickSession()
    }

    @MainActor
    private func assertModelPickerDismissed() {
        let title = app.navigationBars["Models"]
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: title
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
    }

    @MainActor
    private func openQuickSession() {
        tap(app.buttons["workspace.quickSession.start"], named: "quick session button", timeout: 10)
        XCTAssertTrue(
            waitForElementToExist(app.textViews["chat.input"], timeout: 20),
            "Quick Session input did not appear"
        )
    }

    @MainActor
    private func dismissQuickSession() {
        let overlay = app.buttons["quickSession.overlay"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 5), "Quick Session overlay did not appear")
        let start = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)

        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: overlay
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [dismissed], timeout: 5),
            .completed,
            "Quick Session did not dismiss"
        )
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with text: String) {
        focusTextView(element)
        let currentValue = element.value as? String ?? ""
        if !currentValue.isEmpty {
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count))
        }
        if !text.isEmpty {
            element.typeText(text)
        }
        XCTAssertEqual(element.value as? String, text)
    }

    @MainActor
    private func assertThinkingMenuRunsFromMaxToOff() {
        let expectedOptions = [
            (id: "max", label: "Max"),
            (id: "xhigh", label: "XHigh"),
            (id: "high", label: "High"),
            (id: "medium", label: "Medium"),
            (id: "low", label: "Low"),
            (id: "minimal", label: "Minimal"),
            (id: "off", label: "Off"),
        ]
        let options = expectedOptions.map { thinkingOption($0.id) }
        for (option, expected) in zip(options, expectedOptions) {
            XCTAssertTrue(
                option.waitForExistence(timeout: 5),
                "Thinking option \(expected.label) did not appear"
            )
            XCTAssertEqual(option.label, expected.label)
        }
        for (upper, lower) in zip(options, options.dropFirst()) {
            XCTAssertLessThan(
                upper.frame.midY,
                lower.frame.midY,
                "Thinking menu must run from Max at the top to Off at the bottom"
            )
        }
    }

    private func thinkingOption(_ level: String) -> XCUIElement {
        app.buttons["session.toolbar.thinking.option.\(level)"]
    }

    @MainActor
    private func typeIntoTextView(_ element: XCUIElement, text: String) {
        focusTextView(element)
        element.typeText(text)
    }

    @MainActor
    private func focusTextView(_ element: XCUIElement) {
        tap(element, named: "text input", timeout: 5)
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        if !focusPredicate.evaluate(with: element) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        }
        let deadline = Date().addingTimeInterval(5)
        while !focusPredicate.evaluate(with: element) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(focusPredicate.evaluate(with: element), "Text input did not gain keyboard focus")
    }

    @MainActor
    private func firstElement(identifierPrefix: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }
}

/// Message launcher must not sit under a pushed chat, including the interactive
/// pop that previously turned a composer tap into Quick Session.
final class QuickSessionCoveredLauncherE2ETests: E2ETestCase {
    private var rootId = ""
    private var childId = ""

    override var e2eLaunchesSessionsInboxOnly: Bool { true }
    override var e2eAutoCreatesSessionOnLaunch: Bool { false }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchArguments += ["-dev.chenda.Oppi.experiments.sessionThreads", "YES"]
    }

    override func seedE2EFixtures() throws {
        let workspaceId = try e2eWorkspaceId()
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/session-threads",
            body: [
                "workspaceId": workspaceId,
                "sessions": [
                    [
                        "key": "root",
                        "name": "Covered launcher root",
                        "status": "stopped",
                        "createdAtOffsetMs": -120_000,
                        "lastActivityOffsetMs": -60_000,
                        "messageCount": 1,
                    ],
                    [
                        "key": "child",
                        "parentKey": "root",
                        "name": "Covered launcher child",
                        "status": "stopped",
                        "createdAtOffsetMs": -90_000,
                        "lastActivityOffsetMs": -30_000,
                        "messageCount": 1,
                    ],
                ],
            ]
        )
        let ids = try XCTUnwrap(response["sessionIds"] as? [String: String])
        rootId = try XCTUnwrap(ids["root"])
        childId = try XCTUnwrap(ids["child"])
    }

    @MainActor
    func testCoveredListsOmitQuickSessionLauncherUntilBack() throws {
        let inbox = app.collectionViews["workspace.sessionList"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 20), "All Sessions did not appear")
        let rootRow = app.descendants(matching: .any)["session.nav.\(rootId)"]
        XCTAssertTrue(
            waitForSeededRow(rootRow, in: inbox),
            "Root session row missing for \(rootId). \(visibleControlIDs())"
        )
        rootRow.tap()
        assertChatPushedWithoutLauncher(from: "all sessions")
        interactivePopThenComposerTap(from: "all sessions")
        returnToInbox()
        assertLauncherPresent(on: "all sessions")

        let thread = app.buttons["thread.nav.\(rootId)"]
        XCTAssertTrue(thread.waitForExistence(timeout: 15), "Thread strip missing")
        // Close a row swipe the pop may have revealed, then open the strip.
        app.collectionViews["workspace.sessionList"].swipeDown()
        thread.tap()
        XCTAssertTrue(app.collectionViews["thread.detail"].waitForExistence(timeout: 15), "Thread detail did not open")
        assertLauncherPresent(on: "thread detail")

        // Stopped children fold into "finished". The root row is always in the outline.
        let member = app.descendants(matching: .any)["thread.row.\(rootId)"]
        XCTAssertTrue(member.waitForExistence(timeout: 15), "Thread root row missing")
        member.tap()
        assertChatPushedWithoutLauncher(from: "thread detail")
        interactivePopThenComposerTap(from: "thread detail")
        XCTAssertTrue(
            app.collectionViews["thread.detail"].waitForExistence(timeout: 10)
                || app.buttons["chat.toolbar.back"].waitForExistence(timeout: 2),
            "Thread detail did not return after the pop"
        )
        if app.buttons["chat.toolbar.files"].exists {
            app.buttons["chat.toolbar.back"].tap()
        }
        XCTAssertTrue(app.collectionViews["thread.detail"].waitForExistence(timeout: 10), "Back did not return to thread detail")
        assertLauncherPresent(on: "thread detail after back")
    }

    @MainActor
    private func assertChatPushedWithoutLauncher(from source: String) {
        XCTAssertTrue(
            app.buttons["chat.toolbar.files"].waitForExistence(timeout: 20),
            "Chat did not open from \(source)"
        )
        let launcher = app.buttons["workspace.quickSession.start"]
        XCTAssertFalse(launcher.exists, "Message launcher installed while chat from \(source) is pushed")
        XCTAssertFalse(app.buttons["quickSession.overlay"].exists, "Quick Session opened with the chat from \(source)")
    }

    @MainActor
    private func assertLauncherPresent(on surface: String) {
        let launcher = app.buttons["workspace.quickSession.start"]
        XCTAssertTrue(launcher.waitForExistence(timeout: 8), "Message launcher missing on \(surface)")
        XCTAssertTrue(launcher.isHittable, "Message launcher not hittable on \(surface)")
    }

    /// Same gesture as the misfire: edge drag out and back, then a tap at the
    /// composer band. A completed pop may restore the launcher; that tap must
    /// not open Quick Session while chat is still the surface.
    @MainActor
    private func interactivePopThenComposerTap(from source: String) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let mid = app.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
        // One completing pop. A second drag after the list is back swipes a row
        // open and steals the next tap.
        start.press(forDuration: 0.15, thenDragTo: mid, withVelocity: .slow, thenHoldForDuration: 0.2)

        let overlay = app.buttons["quickSession.overlay"]
        let liftOpened = overlay.waitForExistence(timeout: 1)
        print("QSREPORT \(source) after-lift overlay=\(liftOpened) launcher=\(app.buttons["workspace.quickSession.start"].exists) chat=\(app.buttons["chat.toolbar.files"].exists)")
        XCTAssertFalse(liftOpened, "Interactive pop lift opened Quick Session from \(source)")

        let composer = app.coordinate(withNormalizedOffset: CGVector(dx: 0.425, dy: 0.94))
        composer.tap()
        let tapOpened = overlay.waitForExistence(timeout: 2)
        let chatStillPushed = app.buttons["chat.toolbar.files"].exists
        let launcher = app.buttons["workspace.quickSession.start"]
        print(
            "QSREPORT \(source) after-tap overlay=\(tapOpened) chat=\(chatStillPushed) launcher=\(launcher.exists) hittable=\(launcher.exists && launcher.isHittable) frame=\(launcher.exists ? String(describing: launcher.frame) : "none")"
        )
        if chatStillPushed {
            XCTAssertFalse(tapOpened, "Composer-position tap opened Quick Session while chat from \(source) was still pushed")
        } else if tapOpened {
            // Pop completed onto the list. The restored launcher accepted a new
            // tap; that is not the covered-chat misfire. Dismiss and continue.
            overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
            XCTAssertTrue(app.buttons["workspace.quickSession.start"].waitForExistence(timeout: 5), "Launcher missing after dismissing a completed-pop tap")
        }
    }

    /// Fixture sessions are stored before launch. Pull to refresh if the first
    /// snapshot raced an empty store, and expand today's stopped group if it is collapsed.
    @MainActor
    private func waitForSeededRow(_ row: XCUIElement, in list: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        var refreshed = false
        while Date() < deadline {
            if row.exists { return true }
            if !refreshed {
                list.swipeDown()
                refreshed = true
            }
            let collapsed = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND value == %@",
                            "workspace.sessionList.", "Collapsed")
            ).firstMatch
            if collapsed.exists {
                collapsed.tap()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return row.exists
    }

    @MainActor
    private func visibleControlIDs() -> String {
        let ids = app.descendants(matching: .any)
            .allElementsBoundByIndex
            .prefix(40)
            .map { "\($0.identifier)" }
            .filter { !$0.isEmpty }
        return ids.joined(separator: ", ")
    }

    @MainActor
    private func returnToInbox() {
        for _ in 0..<4 {
            if app.collectionViews["workspace.sessionList"].exists,
               !app.buttons["chat.toolbar.files"].exists,
               !app.collectionViews["thread.detail"].exists {
                return
            }
            if app.buttons["chat.toolbar.back"].exists {
                app.buttons["chat.toolbar.back"].tap()
            } else if app.navigationBars.buttons["Back"].exists {
                app.navigationBars.buttons["Back"].tap()
            } else {
                break
            }
        }
        XCTAssertTrue(app.collectionViews["workspace.sessionList"].waitForExistence(timeout: 10), "All Sessions did not return")
    }
}
