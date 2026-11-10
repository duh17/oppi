import XCTest

/// Durable subagents on the scripted faux model (`server/src/e2e-faux-provider.ts`): the parent
/// spawns a background child whose task runs a ticking `bash`, then answers with the streamed
/// faux reply, so the child stays busy for about twenty seconds.
///
/// Run with `e2e.sh --native --durable --faux-model`; skipped otherwise.
@MainActor
final class DurableSubagentE2ETests: E2ETestCase {
    private static let liveAssistantPrefix = "chat.timeline.assistant.pi.live-"
    private static let replyStart = "Durable faux reply to"
    private static let activityRowPrefix = "extension.native.activity.row."
    private static let childTailPrefix = "chat.timeline.childTail."
    /// Ticks once a second for fourteen seconds, inside bash's fifteen-second foreground window.
    private static let childTask = "faux:bash for i in $(seq 1 14); do echo tick $i; sleep 1; done"

    override var e2eAutoCreatesSessionOnLaunch: Bool { false }

    func testOpeningChildFromPillStreamsItLive() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let parentId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: parentId, level: "full")
        sendMessage("faux:subagent kid \(Self.childTask)")

        // The pill lists the child once its Session is bound.
        expandNativeSurface(title: "Subagents", timeout: 30)
        let childRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.activityRowPrefix)
        ).firstMatch
        XCTAssertTrue(childRow.waitForExistence(timeout: 15), "The pill did not list the child")
        let childId = String(childRow.identifier.dropFirst(Self.activityRowPrefix.count))
        try saveLabScreenshot(name: "durable-subagent-pill")

        tap(childRow, named: "child row in the subagent pill")
        XCTAssertEqual(waitForFocusedSessionId(childId, timeout: 20), childId, "The child did not open")
        waitForAckedSubscription(sessionId: childId, level: "full")

        // Still busy when opened: its bash output keeps arriving, then its reply streams live.
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(
            timelineShows(timeline, "faux:bash", timeout: 15),
            "The child's task did not show"
        )
        try saveLabScreenshot(name: "durable-subagent-child-busy")
        let liveReply = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.liveAssistantPrefix)
        ).firstMatch
        XCTAssertTrue(
            waitForElementToExist(liveReply, timeout: 40),
            "The child's reply never streamed as a live row"
        )
        XCTAssertTrue(app.buttons["chat.stop"].exists, "The child was not running while its reply streamed")
        try saveLabScreenshot(name: "durable-subagent-child-streaming")
    }

    /// A background child's live tail shows in the expanded pill, not under the spawn row, and
    /// the pill picks it up again after a reconnect while the child still works.
    func testBackgroundChildLiveTailShowsInThePillAcrossAReconnect() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let parentId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: parentId, level: "full")
        sendMessage("faux:subagent kid \(Self.childTask)")

        expandNativeSurface(title: "Subagents", timeout: 30)
        let childRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.activityRowPrefix)
        ).firstMatch
        XCTAssertTrue(childRow.waitForExistence(timeout: 15), "The pill did not list the child")
        // The row's second line is the child's newest live line: its running bash call.
        XCTAssertTrue(
            waitForLabel(of: childRow, containing: "$ for i in", timeout: 20),
            "The pill row did not show the child's running bash call: \(elementLabel(childRow))"
        )
        // The spawn call returned, so nothing hangs under its row.
        let timeline = app.collectionViews["chat.timeline"]
        let tail = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.childTailPrefix)
        ).firstMatch
        XCTAssertFalse(tail.exists, "A background child's tail showed under its spawn row")
        try saveLabScreenshot(name: "durable-subagent-tail-pill")

        // The parent's own turn ends while the child still works; an idle app closes its
        // socket on background, and foreground opens a new one.
        waitForTurnToEnd(timeout: 40)
        _ = try backgroundAndActivate(after: e2eLifecycleSnapshot(), scenario: "durable_subagent_busy", cycle: 1)
        waitForWebSocketConnected()
        XCTAssertEqual(waitForFocusedSessionId(parentId), parentId)
        waitForAckedSubscription(sessionId: parentId, level: "full")

        // The child's answer streams after its bash call: the pill follows it on the new socket.
        expandNativeSurface(title: "Subagents", timeout: 15)
        XCTAssertTrue(
            waitForLabel(of: childRow, containing: Self.replyStart, timeout: 40),
            "The pill row did not show the child's streaming answer after the reconnect: \(elementLabel(childRow))"
        )
        try saveLabScreenshot(name: "durable-subagent-tail-pill-after-reconnect")
    }

    /// A child the parent waits on shows its live tail under the running spawn row, and tapping
    /// the tail opens the child.
    func testForegroundChildLiveTailShowsUnderItsToolRowAndOpensTheChild() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }

        createSession()
        waitForWebSocketConnected()
        let parentId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: parentId, level: "full")
        sendMessage("faux:subagent-wait kid \(Self.childTask)")

        let timeline = app.collectionViews["chat.timeline"]
        let tail = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", Self.childTailPrefix)
        ).firstMatch
        XCTAssertTrue(waitForElementToExist(tail, timeout: 30), "No live tail under the waiting spawn row")
        XCTAssertTrue(
            waitForValue(of: tail, containing: "$ for i in", timeout: 20),
            "The tail did not show the child's running bash call: \(elementValue(tail))"
        )
        try saveLabScreenshot(name: "durable-subagent-tail-foreground")

        tap(tail, named: "foreground child live tail")
        let childId = waitForFocusedSessionId(excluding: parentId, timeout: 20)
        XCTAssertNotEqual(childId, parentId, "Tapping the tail did not open the child")
        waitForAckedSubscription(sessionId: childId, level: "full")
        XCTAssertTrue(
            timelineShows(timeline, "faux:bash", timeout: 15),
            "The opened session is not the child running the task"
        )
        try saveLabScreenshot(name: "durable-subagent-foreground-child-opened")
    }

    /// Lab: the subagent pill over real durable children on the faux model, two working (each
    /// waiting on a background job of its own), one asking, one failed, and three finished; the
    /// screenshots go to `/tmp/oppi-screenshots/subagent-panel-<device>-*.png`
    /// (`OPPI_LAB_DEVICE` names the device, default `iphone`). It asserts the pill's live counts and
    /// that each group lists its children, then captures the drawer in dark and light, the whole
    /// list (full screen, or the trailing column on a wide screen), a row's menu, and on a phone
    /// the largest text size.
    func testSubagentPanelLab() throws {
        guard E2ELabServerContext.durableSessions else {
            throw XCTSkip("Needs e2e.sh --native --durable --faux-model")
        }
        let device = ProcessInfo.processInfo.environment["OPPI_LAB_DEVICE"] ?? "iphone"
        let shot = { (name: String) throws in _ = try self.saveLabScreenshot(name: "subagent-panel-\(device)-\(name)") }
        // A feature tip over the composer is not part of the panel.
        let dismissTip = {
            let tip = self.app.buttons["feature-tip.dismiss"]
            if tip.waitForExistence(timeout: 2), tip.isHittable { tip.tap() }
        }

        createSession()
        waitForWebSocketConnected()
        let parentId = waitForFocusedSessionId(timeout: 20)
        waitForAckedSubscription(sessionId: parentId, level: "full")
        let children: [(name: String, task: String)] = [
            ("fable-catalyst-plan", "Write the native Catalyst plan."),
            ("server-drain-scout", "Find the callers of the drain timer."),
            ("tts-voice-picker-review", "Review the voice picker's empty state."),
            ("ipad-mini-sidebar-width-audit", "faux:fail Bad request: the provider refused the tool schema"),
            (
                "catalyst-ghostty-spike-arm64-slice-retag-and-link-check",
                "faux:ask Retag the vendored slice with vtool, or build a Zig macabi target?"
            ),
            ("delete-oppimac", "faux:bash sleep 1800"),
            ("subagent-panel-review", "faux:bash for i in $(seq 1 1800); do echo tick $i; sleep 1; done"),
        ]
        // One answer spawns them all, as a model delegating in parallel does. The parent's turns
        // go on while the children report, so nothing here waits for them to end.
        sendMessage("faux:subagents " + children.map { "\($0.name) \($0.task)" }.joined(separator: " || "))

        // The working children move their bash calls to the background after its foreground window.
        // The pill's counts are its spoken value.
        let pill = app.descendants(matching: .any)["extension-strip-aboveEditor-pill-widget-subagents"]
        XCTAssertTrue(
            waitForValue(of: pill, containing: "1 failed · 1 needs you · 2 working", timeout: 90),
            "The pill did not count one failed, one asking and two working children: \(elementValue(pill))"
        )
        dismissTip()
        expandNativeSurface(title: "Subagents", timeout: 15)
        let row = { (name: String) in
            self.app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@", Self.activityRowPrefix, name)
            ).firstMatch
        }
        let asking = row("catalyst-ghostty-spike")
        XCTAssertTrue(asking.waitForExistence(timeout: 15), "The asking child has no row")
        XCTAssertTrue(asking.label.contains("Retag the vendored slice"), "The asking row does not show the question: \(asking.label)")
        let failed = row("ipad-mini-sidebar-width-audit")
        XCTAssertTrue(failed.label.contains("refused the tool schema"), "The failed row does not show the error: \(failed.label)")
        XCTAssertTrue(
            waitForLabel(of: row("delete-oppimac"), containing: "Waiting on a background job: sleep 1800", timeout: 60),
            "The working child does not say what it waits on: \(elementLabel(row("delete-oppimac")))"
        )
        try shot("dark-drawer")

        // A row's menu: Open first, Stop last.
        asking.press(forDuration: 1.2)
        let stop = app.buttons["Stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "The row's menu has no Stop")
        try shot("dark-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()

        // The whole list: the trailing column beside the chat on a wide screen, else full screen.
        let whole = app.buttons["extension.strip.fullScreen.aboveEditor"]
        XCTAssertTrue(whole.waitForExistence(timeout: 5), "The drawer has no button to the whole list")
        tap(whole, named: "drawer's whole-list button")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        try shot("dark-whole")

        for (variant, arguments) in [
            ("light", ["-dev.chenda.Oppi.theme.mode", "manual", "-dev.chenda.Oppi.theme.id", "light"]),
        ] + (device == "ipad" ? [] : [(
            "dark-largest-text",
            ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )]) {
            let base = app.launchArguments
            app.terminate()
            app.launchArguments = base + arguments
            app.launch()
            openSessionDeepLink(id: parentId)
            dismissTip()
            expandNativeSurface(title: "Subagents", timeout: 30)
            XCTAssertTrue(row("delete-oppimac").waitForExistence(timeout: 15), "No rows after relaunch (\(variant))")
            try shot("\(variant)-drawer")
            if variant == "light" {
                tap(app.buttons["extension.strip.fullScreen.aboveEditor"], named: "drawer's whole-list button")
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                try shot("light-whole")
            }
            app.terminate()
            app.launchArguments = base
            app.launch()
            openSessionDeepLink(id: parentId)
        }
    }

    private func elementValue(_ element: XCUIElement) -> String {
        element.exists ? (element.value as? String) ?? "" : ""
    }

    private func elementLabel(_ element: XCUIElement) -> String {
        element.exists ? element.label : ""
    }

    private func waitForValue(of element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) { self.elementValue(element).contains(text) }
    }

    private func waitForLabel(of element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) { self.elementLabel(element).contains(text) }
    }

    private func waitForCondition(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func waitForTurnToEnd(timeout: TimeInterval) {
        let stopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.buttons["chat.stop"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: timeout), .completed, "The parent's turn did not end")
    }

    private func timelineShows(_ timeline: XCUIElement, _ text: String, timeout: TimeInterval) -> Bool {
        let match = timeline.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
        ).firstMatch
        return waitForElementToExist(match, timeout: timeout)
    }

    private func expandNativeSurface(title: String, timeout: TimeInterval) {
        let collapse = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Collapse \(title) surface")
        ).firstMatch
        if collapse.waitForExistence(timeout: 0.5) { return }
        let expand = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Expand \(title) surface")
        ).firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: timeout), "The \(title) surface did not appear")
        tap(expand, named: "\(title) surface expand toggle", timeout: timeout)
        XCTAssertTrue(collapse.waitForExistence(timeout: timeout), "The \(title) surface did not expand")
    }
}
