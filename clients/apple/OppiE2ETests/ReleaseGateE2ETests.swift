import XCTest

/// Fast release-gate coverage for the highest-risk mobile chat path.
///
/// These tests keep the old broad E2E suites available, but give release lanes a
/// smaller preferred gate: paired server, real app navigation, stable
/// accessibility identifiers, and harness-driven prompts where a model round trip
/// is not the behavior under test.
final class ReleaseGateE2ETests: E2ETestCase {
    override var e2eStartsInAutoCreatedChat: Bool { true }
    override var e2eRequiresFreshLaunch: Bool {
        !name.contains("testFocusedSessionStreamSurvivesSessionSwitch")
    }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        guard name.contains("testExpandedComposerAttachmentSendAndStop") else { return }
        MainActor.assumeIsolated {
            application.launchEnvironment["OPPI_E2E_CHAT_PENDING_IMAGE_BASE64"] = Self.onePixelPNGBase64
            application.launchEnvironment["OPPI_E2E_CHAT_PENDING_IMAGE_MIME_TYPE"] = "image/png"
        }
    }

    @MainActor
    func testComposerAskAnswerAndIgnoreUseInlineCard() throws {
        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        try clearE2EHarnessResponses(sessionId: sessionId)
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        defer { _ = try? sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"]) }

        let answerRequestId = "gate-ask-answer"
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": answerRequestId,
            "method": "ask",
            "allowCustom": true,
            "questions": [[
                "id": "answer",
                "question": "Gate ask answer prompt",
                "multiSelect": false,
                "options": [[
                    "value": "use-default",
                    "label": "Use default",
                    "description": "Exercise option rendering while the typed answer path stays available.",
                ]],
            ]],
        ])

        let answerOption = app.buttons["ask.option.use-default"]
        if !waitForElementToExist(answerOption, timeout: 5) {
            let expandButton = app.buttons["ask.expand"]
            if waitForElementToExist(expandButton, timeout: 5) {
                tap(expandButton, named: "ask card expand button", timeout: 1)
            }
        }
        XCTAssertTrue(
            waitForElementToExist(answerOption, timeout: 10),
            "Ask card option did not render for the answer prompt"
        )
        typeIntoChatInput("gate ask answer")
        tap(app.buttons["chat.send"], named: "ask answer send button", timeout: 5)

        let answer = try waitForE2EHarnessResponse(sessionId: sessionId, requestId: answerRequestId)
        XCTAssertEqual(answer["value"] as? String, "{\"answer\":\"gate ask answer\"}")
        XCTAssertNil(answer["cancelled"])
        try settleE2EUIRequest(sessionId: sessionId, requestId: answerRequestId)

        let ignoreRequestId = "gate-ask-ignore"
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_request",
            "id": ignoreRequestId,
            "method": "ask",
            "allowCustom": false,
            "questions": [[
                "id": "ignore",
                "question": "Gate ask ignore prompt",
                "multiSelect": false,
                "options": [[
                    "value": "continue",
                    "label": "Continue",
                    "description": "This option should not be selected in the ignore path.",
                ]],
            ]],
        ])

        let ignoreButton = app.buttons["chat.askIgnore"]
        XCTAssertTrue(waitForElementToExist(ignoreButton, timeout: 10), "Ask ignore button did not appear")
        tap(ignoreButton, named: "ask ignore button", timeout: 1)

        let ignored = try waitForE2EHarnessResponse(sessionId: sessionId, requestId: ignoreRequestId)
        XCTAssertEqual(ignored["cancelled"] as? Bool, true)
        XCTAssertNil(ignored["value"])
        try settleE2EUIRequest(sessionId: sessionId, requestId: ignoreRequestId)
    }

    @MainActor
    func testExpandedComposerAttachmentSendAndStop() throws {
        createAndEnterSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)

        let pendingImage = firstElement(identifierPrefix: "chat.attachment.image.")
        XCTAssertTrue(waitForElementToExist(pendingImage, timeout: 10), "Seeded image attachment did not appear")

        let marker = "E2E_ATTACHMENT_STOP_OK"
        let prompt = """
        \(marker)
        line 2
        line 3
        line 4
        line 5
        """
        typeIntoChatInput(prompt)

        let expandButton = app.buttons["chat.expand"]
        XCTAssertTrue(waitForElementToExist(expandButton, timeout: 5), "Expanded composer button did not appear")
        tap(expandButton, named: "expanded composer button", timeout: 1)

        let expandedEditor = app.textViews["expanded.composer.editor"]
        XCTAssertTrue(waitForElementToExist(expandedEditor, timeout: 10), "Expanded composer editor did not appear")
        let expandedValue = waitForInputValue(expandedEditor, containing: marker, timeout: 5)
        XCTAssertTrue(
            expandedValue.contains(marker),
            "Expanded composer did not preserve inline text. Last value: \(expandedValue)"
        )
        tap(app.buttons["expanded.composer.cancel"], named: "expanded composer done button", timeout: 5)
        let inlineComposer = app.textViews["chat.input"]
        XCTAssertTrue(waitForElementToExist(inlineComposer, timeout: 10), "Inline composer did not return")
        dismissKeyboardLearningOverlayIfNeeded()
        tap(inlineComposer, named: "inline composer before attachment send", timeout: 1)
        waitForKeyboardFocus(inlineComposer, name: "inline composer before attachment send")

        tap(app.buttons["chat.send"], named: "attachment prompt send button", timeout: 5)
        XCTAssertTrue(
            waitForTimelineTextContaining(marker, timeout: 20),
            "Sent attachment prompt did not appear in the timeline"
        )
        XCTAssertTrue(
            waitForKeyboardToDismiss(timeout: 5),
            "Keyboard stayed visible after the attachment prompt was acknowledged"
        )
        XCTAssertTrue(
            waitForElementToExist(app.descendants(matching: .any)["chat.user.thumbnail.0"], timeout: 20),
            "Sent image thumbnail did not appear in the user timeline row"
        )

        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        defer { _ = try? sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"]) }

        let stopButton = app.buttons["chat.stop"]
        XCTAssertTrue(waitForElementToExist(stopButton, timeout: 10), "Stop button never appeared after harness busy state")
        tap(stopButton, named: "stop response button", timeout: 1)
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])

        let stopGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: stopButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [stopGone], timeout: 10),
            .completed,
            "Stop button did not disappear after tapping stop"
        )
        XCTAssertTrue(waitForElementToExist(app.textViews["chat.input"], timeout: 20), "Chat input did not recover after stop")
    }

    @MainActor
    func testRenderedSessionWikiLinkOpensReferencedChat() throws {
        createSession()
        let sourceSessionID = waitForFocusedSessionId(timeout: 20)

        navigateBackToWorkspace()
        createSession()
        let targetSessionID = waitForFocusedSessionId(excluding: sourceSessionID, timeout: 20)

        navigateBackToWorkspace()
        enterSession(id: sourceSessionID)
        sendMessageAndWaitForResponse(
            "Reply with exactly [[\(targetSessionID)]] and nothing else. Do not use a code span or code fence.",
            timeout: 240
        )

        let assistantRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "chat.timeline.assistant.")
        )
        guard assistantRows.count > 0 else {
            XCTFail("Assistant response row did not render")
            return
        }
        let latestAssistantResponse = assistantRows.element(boundBy: assistantRows.count - 1)
        let matchingLinks = app.links
            .matching(NSPredicate(format: "label == %@", targetSessionID))
            .allElementsBoundByIndex
        let assistantLinks = matchingLinks.filter {
            latestAssistantResponse.frame.intersects($0.frame)
        }
        XCTAssertEqual(
            assistantLinks.count,
            2,
            "Expected the assistant row's two accessibility projections for its rendered session wiki link"
        )
        guard let renderedLink = assistantLinks.last else { return }
        XCTAssertTrue(
            waitForElementToExist(renderedLink, timeout: 20),
            "Assistant response did not render a tappable session wiki link"
        )
        tap(renderedLink, named: "rendered session wiki link", timeout: 5)
        XCTAssertEqual(waitForFocusedSessionId(targetSessionID, timeout: 20), targetSessionID)
    }

    @MainActor
    func testFocusedSessionStreamSurvivesSessionSwitch() throws {
        createSession()
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        waitForSessionStreamEndpoint()
        let sessionA = waitForFocusedSessionId(timeout: 20)
        waitForDesiredSubscription(sessionId: sessionA, level: "full")
        waitForAckedSubscription(sessionId: sessionA, level: "full")

        navigateBackToWorkspace()
        waitForNoDesiredSubscription(sessionId: sessionA)
        waitForNoAckedSubscription(sessionId: sessionA)

        createSession()
        waitForSessionStreamEndpoint()
        let sessionB = waitForFocusedSessionId(excluding: sessionA, timeout: 20)
        waitForDesiredSubscription(sessionId: sessionB, level: "full")
        waitForAckedSubscription(sessionId: sessionB, level: "full")
        waitForNoDesiredSubscription(sessionId: sessionA)

        openSessionDeepLink(id: sessionA)
        waitForSessionStreamEndpoint()
        waitForDesiredSubscription(sessionId: sessionA, level: "full")
        waitForAckedSubscription(sessionId: sessionA, level: "full")
        waitForNoDesiredSubscription(sessionId: sessionB)
    }

    @MainActor
    private func typeIntoChatInput(_ text: String) {
        let chatInput = app.textViews["chat.input"]
        XCTAssertTrue(waitForElementToExist(chatInput, timeout: 10), "Chat input not available before typing")
        dismissKeyboardLearningOverlayIfNeeded()
        tap(chatInput, named: "chat input", timeout: 1)
        waitForKeyboardFocus(chatInput, name: "chat input")
        dismissKeyboardLearningOverlayIfNeeded()
        waitForKeyboardFocus(chatInput, name: "chat input")
        chatInput.typeText(text)
    }

    @MainActor
    private func waitForKeyboardFocus(_ element: XCUIElement, name: String) {
        let focusPredicate = NSPredicate(format: "hasKeyboardFocus == true")
        if !focusPredicate.evaluate(with: element) {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        }
        let deadline = Date().addingTimeInterval(5)
        while !focusPredicate.evaluate(with: element) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(focusPredicate.evaluate(with: element), "\(name) did not gain keyboard focus")
    }

    @MainActor
    private func waitForKeyboardToDismiss(timeout: TimeInterval) -> Bool {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return true }
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: keyboard
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForInputValue(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = element.value as? String ?? ""
        while Date() < deadline {
            latest = element.value as? String ?? ""
            if latest.contains(text) {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return latest
    }

    @MainActor
    private func firstElement(identifierPrefix: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", identifierPrefix)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func dismissKeyboardLearningOverlayIfNeeded() {
        let continueButton = app.buttons["Continue"]
        if continueButton.waitForExistence(timeout: 0.5) {
            tap(continueButton, named: "keyboard learning overlay continue button", timeout: 1)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private static let onePixelPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
}

/// Native navigation-lifecycle proof for chat viewport restoration after a
/// workspace document opened from assistant markdown.
@MainActor
final class TimelineDocumentPositionE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceName = ""

    override var e2eStartsInAutoCreatedChat: Bool { true }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchEnvironment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] = workspaceName
        application.launchEnvironment["OPPI_E2E_AUTO_CREATE_SESSION"] = "1"
    }

    override func seedE2EFixtures() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        workspaceName = "timeline-document-anchor-\(suffix)"
        let fixture = try createLabWorkspaceFileFixture(
            directoryName: workspaceName,
            filename: "reader-note.md",
            base64: Data("# Reader note\n\nDocument navigation proof.\n".utf8).base64EncodedString()
        )
        _ = try createLabWorkspace(
            named: workspaceName,
            hostMount: fixture.hostMount
        )
    }

    func testWorkspaceWikiDocumentBackPathsPreserveReadingAnchor() throws {
        let linkLabel = "Open reader note"
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        try clearE2EHarnessResponses(sessionId: sessionId)
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "text_delta",
            "delta": Self.deterministicWikiResponse,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "message_end",
            "role": "assistant",
            "content": Self.deterministicWikiResponse,
            "persist": true,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])
        waitForActiveResponseToFinish()

        // Re-enter once so the measured journey starts from the same persisted
        // trace rendering path used after document navigation, rather than the
        // synthetic stream's transient row layout.
        let backButton = app.buttons["fullscreen-code.back"]
        let streamedLink = try waitForStableWikiLink(label: linkLabel)
        tap(streamedLink, named: "workspace document wiki link fixture warm-up", timeout: 5)
        XCTAssertTrue(waitForElementToExist(backButton, timeout: 20), "Workspace document did not open")
        tap(backButton, named: "workspace document warm-up back control", timeout: 5)

        // The fixture places the link in the initial tail viewport. Perform a
        // bounded user drag to detach while keeping that known link visible;
        // all later lookup helpers are read-only and never recover by scrolling,
        // so each Y measurement describes the restored viewport.
        let initialLink = try waitForStableWikiLink(label: linkLabel)
        let initialBeforeY = timelineRelativeY(of: initialLink)
        var link = initialLink
        var firstBeforeY = initialBeforeY
        for _ in 0..<2 where abs(firstBeforeY - initialBeforeY) <= 0.5 {
            detachTimelineForReadingAnchor()
            link = try waitForStableWikiLink(label: linkLabel)
            firstBeforeY = timelineRelativeY(of: link)
        }
        XCTAssertNotEqual(
            initialBeforeY,
            firstBeforeY,
            accuracy: 0.5,
            "The bounded setup drags should move the link before the first navigation"
        )

        tap(link, named: "workspace document wiki link", timeout: 5)
        XCTAssertTrue(waitForElementToExist(backButton, timeout: 20), "Workspace document did not open")
        tap(backButton, named: "workspace document back control", timeout: 5)

        let afterButtonBack = try waitForRestoredWikiLink(
            label: linkLabel,
            expectedRelativeY: firstBeforeY,
            failureMessage: "Back control changed the assistant wiki link's viewport position"
        )

        let secondBeforeY = timelineRelativeY(of: afterButtonBack)
        tap(afterButtonBack, named: "workspace document wiki link before swipe back", timeout: 5)
        XCTAssertTrue(waitForElementToExist(backButton, timeout: 20), "Workspace document did not reopen")
        app.swipeRight()

        _ = try waitForRestoredWikiLink(
            label: linkLabel,
            expectedRelativeY: secondBeforeY,
            failureMessage: "Swipe Back changed the assistant wiki link's viewport position"
        )
    }

    private func waitForStableWikiLink(label: String) throws -> XCUIElement {
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(waitForElementToExist(timeline, timeout: 20), "Chat timeline did not appear")
        let deadline = Date().addingTimeInterval(20)
        var previousRelativeY: CGFloat?
        var stableObservations = 0
        var latestVisible: XCUIElement?

        repeat {
            if let visible = currentVisibleWikiLink(label: label, timeline: timeline) {
                let relativeY = timelineRelativeY(of: visible)
                latestVisible = visible
                if let previousRelativeY, abs(relativeY - previousRelativeY) <= 0.5 {
                    stableObservations += 1
                    if stableObservations >= 5 {
                        return visible
                    }
                } else {
                    stableObservations = 0
                }
                previousRelativeY = relativeY
            } else {
                stableObservations = 0
                previousRelativeY = nil
                latestVisible = nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        XCTFail("Assistant wiki link \(label) did not settle in the viewport; last visible: \(latestVisible != nil)")
        throw TimelineDocumentPositionE2EError.linkNotVisible
    }

    private func waitForRestoredWikiLink(
        label: String,
        expectedRelativeY: CGFloat,
        failureMessage: String
    ) throws -> XCUIElement {
        let timeline = app.collectionViews["chat.timeline"]
        XCTAssertTrue(waitForElementToExist(timeline, timeout: 20), "Chat timeline did not return")
        let deadline = Date().addingTimeInterval(20)
        var lastRelativeY: CGFloat?

        repeat {
            if let visible = currentVisibleWikiLink(label: label, timeline: timeline) {
                let relativeY = timelineRelativeY(of: visible)
                lastRelativeY = relativeY
                if abs(relativeY - expectedRelativeY) <= 8 {
                    return visible
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        let lastObserved = lastRelativeY.map { String(describing: $0) } ?? "none"
        XCTFail("\(failureMessage); expected \(expectedRelativeY), last observed \(lastObserved)")
        throw TimelineDocumentPositionE2EError.linkNotVisible
    }

    private func currentVisibleWikiLink(
        label: String,
        timeline: XCUIElement
    ) -> XCUIElement? {
        let predicate = NSPredicate(format: "label == %@", label)
        let linkCandidates = timeline.descendants(matching: .link)
            .matching(predicate)
            .allElementsBoundByIndex
        let staticTextCandidates = timeline.descendants(matching: .staticText)
            .matching(predicate)
            .allElementsBoundByIndex
        let candidates: [XCUIElement]
        if !linkCandidates.isEmpty {
            candidates = linkCandidates
        } else if !staticTextCandidates.isEmpty {
            candidates = staticTextCandidates
        } else {
            candidates = timeline.descendants(matching: .any)
                .matching(predicate)
                .allElementsBoundByIndex
        }
        let timelineFrame = timeline.frame
        return candidates.last(where: { element in
            element.exists && !element.frame.isEmpty && element.frame.intersects(timelineFrame)
        })
    }

    private func detachTimelineForReadingAnchor() {
        let timeline = app.collectionViews["chat.timeline"]
        // Stay in the collection's trailing section inset, outside the full-width
        // markdown UITextView, so its selection recognizer cannot consume the drag.
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.3))
        let end = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.72))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func timelineRelativeY(of element: XCUIElement) -> CGFloat {
        element.frame.minY - app.collectionViews["chat.timeline"].frame.minY
    }

    private func waitForActiveResponseToFinish() {
        let stopButton = app.buttons["chat.stop"]
        guard stopButton.exists else { return }
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: stopButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [finished], timeout: 240),
            .completed,
            "Assistant response did not finish before document navigation"
        )
    }

    private static let deterministicWikiResponse = """
    Context line 1

    Context line 2

    Context line 3

    Context line 4

    Context line 5

    Context line 6

    Context line 7

    Context line 8

    Context line 9

    Context line 10

    Context line 11

    Context line 12

    [[reader-note|Open reader note]]

    Context line 13

    Context line 14

    Context line 15

    Context line 16

    Context line 17

    Context line 18

    Context line 19

    Context line 20

    Context line 21

    Context line 22

    Context line 23

    Context line 24

    Context line 25

    Context line 26

    Context line 27
    """
}

private enum TimelineDocumentPositionE2EError: Error {
    case linkNotVisible
}
