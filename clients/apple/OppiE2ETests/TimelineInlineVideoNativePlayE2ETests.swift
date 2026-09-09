import Foundation
import XCTest

/// Paired-server proof that tapping AVKit's native Play on an inline timeline
/// wiki video advances `currentTime` through the authenticated media route.
///
/// Fullscreen and after-dismiss claims pause via the native Pause control
/// first, then tap Play. Uninterrupted playback is not accepted as Play
/// delivery. This is not a hosted `player.play()` unit test.
///
/// The oracle is the presented AVKit player (`videoPlayer.native` value /
/// player-local `e2e.video.playback`). ContentView overlays are not used.
@MainActor
final class TimelineInlineVideoNativePlayE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceName = ""
    private var expectedMid: String?
    private var expectedPid: String?

    override var e2eStartsInAutoCreatedChat: Bool { true }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchEnvironment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] = workspaceName
        application.launchEnvironment["OPPI_E2E_AUTO_CREATE_SESSION"] = "1"
        application.launchEnvironment["OPPI_E2E_DIAGNOSTICS"] = "1"
    }

    override func seedE2EFixtures() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        workspaceName = "timeline-inline-video-\(suffix)"
        let fixture = try createLabWorkspaceFileFixture(
            directoryName: workspaceName,
            filename: Self.videoFilename,
            base64: try Self.videoFixtureBase64()
        )
        _ = try createLabWorkspace(named: workspaceName, hostMount: fixture.hostMount)
    }

    func testNativePlayOnInlineWikiVideoAdvancesCurrentTime() throws {
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        try clearE2EHarnessResponses(sessionId: sessionId)

        let wiki = Self.wikiMessage()
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "text_delta",
            "delta": wiki,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "message_end",
            "role": "assistant",
            "content": wiki,
            "persist": true,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_settled"])
        XCTAssertTrue(
            waitUntilGone(app.buttons["chat.stop"], timeout: 10),
            "Session stayed busy after agent_settled"
        )
        XCTAssertTrue(
            waitForElementToExist(app.textViews["chat.input"], timeout: 15),
            "Composer did not return after the wiki video turn"
        )

        dismissComposerKeyboardIfNeeded()
        let nativePlayer = revealNativePlayer()
        XCTAssertTrue(
            nativePlayer.waitForExistence(timeout: 8),
            "Inline wiki video player did not appear. fallback=\(app.buttons["markdown-video-open"].exists) probe=\(currentPlaybackProbe())"
        )

        let readyProbe = waitForPlaybackProbe(timeout: 15) { probe in
            probe.contains("item=ready") && probe.contains("vis=1")
        }
        XCTAssertTrue(
            readyProbe.contains("item=ready") && readyProbe.contains("vis=1"),
            "Inline video was not ready. probe=\(readyProbe)"
        )
        XCTAssertNotEqual(readyProbe, "missing", "Player-local playback probe did not appear. probe=\(readyProbe)")
        expectedMid = Self.probeToken(readyProbe, key: "mid")
        expectedPid = Self.probeToken(readyProbe, key: "pid")
        XCTAssertNotNil(expectedMid, "ready probe missing model identity. ready=\(readyProbe)")
        XCTAssertNotNil(expectedPid, "ready probe missing player identity. ready=\(readyProbe)")
        XCTAssertNotEqual(expectedPid, "nil", "ready probe has no player. ready=\(readyProbe)")
        XCTAssertLessThan(
            Self.probeTime(readyProbe),
            0.5,
            "Inline video was not paused near start before the Play journey. ready=\(readyProbe)"
        )
        XCTAssertTrue(
            Self.probeRate(readyProbe) <= 0.01,
            "Inline video was already playing before any native tap. ready=\(readyProbe)"
        )
        try saveLabScreenshot(name: "timeline-inline-video-ready")

        try tapNativePlayAndRequireTimeAdvance(
            reason: "inline timeline",
            requiredSubstring: "fs=0"
        )
        try saveLabScreenshot(name: "timeline-inline-video-playing")

        try assertFullscreenNativePlayAdvances()
        try assertPlayAdvancesAfterFullscreenDismiss()
        try hideAndRevealNativePlay()
    }

    private func assertFullscreenNativePlayAdvances() throws {
        pauseIfPlaying(reason: "before fullscreen")
        let nativePlayer = presentedNativePlayer()
        showNativePlaybackChrome(on: nativePlayer)
        let tree = nativeControlSummary(in: nativePlayer)
        guard let fullScreen = fullscreenControl(in: nativePlayer) else {
            XCTFail(
                "Fullscreen control was not in the AX tree. iOS 26 expand arrows sit top-leading and often have an empty label. tree=\(tree) probe=\(currentPlaybackProbe())"
            )
            return
        }
        XCTAssertTrue(
            fullScreen.isHittable,
            "Fullscreen control was not hittable. tree=\(tree) probe=\(currentPlaybackProbe())"
        )
        // 20260909-143551: AX frame was 19x22. element.tap() synthesized but the
        // player stayed inline with "enter full screen" still showing. Hit the
        // same Fullscreen Button's center instead of a guessed screen offset.
        fullScreen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try saveLabScreenshot(name: "timeline-inline-video-fullscreen-tapped")

        let fullscreenProbe = waitForPlaybackProbe(timeout: 10) { probe in
            probe.contains("fs=1") && matchesIdentity(probe)
        }
        if !fullscreenProbe.contains("fs=1") {
            let afterTree = nativeControlSummary(in: presentedNativePlayer())
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "ax-after-fullscreen-tap"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            XCTFail(
                "Fullscreen probe did not appear on the presented player. last=\(fullscreenProbe) beforeTree=\(tree) afterTree=\(afterTree)"
            )
            return
        }
        assertIdentity(fullscreenProbe, reason: "fullscreen presented")
        try tapNativePlayAndRequireTimeAdvance(
            reason: "fullscreen",
            requiredSubstring: "fs=1"
        )
        try saveLabScreenshot(name: "timeline-inline-video-fullscreen-playing")
    }

    private func assertPlayAdvancesAfterFullscreenDismiss() throws {
        let nativePlayer = presentedNativePlayer()
        showNativePlaybackChrome(on: nativePlayer)
        let done = app.buttons.matching(
            NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "Done", "Close")
        ).firstMatch
        XCTAssertTrue(
            done.waitForExistence(timeout: 5),
            "Fullscreen dismiss control did not appear. tree=\(nativeControlSummary(in: nativePlayer)) probe=\(currentPlaybackProbe())"
        )
        XCTAssertTrue(done.isHittable, "Fullscreen dismiss control was not hittable. probe=\(currentPlaybackProbe())")
        done.tap()

        let dismissedProbe = waitForPlaybackProbe(timeout: 10) { probe in
            probe.contains("fs=0") && matchesIdentity(probe)
        }
        XCTAssertTrue(
            dismissedProbe.contains("fs=0"),
            "Inline probe did not return after dismiss. last=\(dismissedProbe)"
        )
        assertIdentity(dismissedProbe, reason: "after fullscreen dismiss")
        try tapNativePlayAndRequireTimeAdvance(
            reason: "after fullscreen dismiss",
            requiredSubstring: "fs=0"
        )
        try saveLabScreenshot(name: "timeline-inline-video-after-dismiss")
    }

    private func hideAndRevealNativePlay() throws {
        let timeline = timelineElement()
        XCTAssertTrue(
            timeline.waitForExistence(timeout: 5),
            "chat.timeline missing; cannot prove hide/reveal. probe=\(currentPlaybackProbe())"
        )

        pauseIfPlaying(reason: "before hide/reveal")
        var hidden = false
        var hiddenProbe = currentPlaybackProbe()
        for _ in 0..<14 {
            timeline.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            hiddenProbe = currentPlaybackProbe()
            let player = presentedNativePlayer()
            if hiddenProbe.contains("vis=0")
                || hiddenProbe == "missing"
                || !player.exists
                || !player.isHittable {
                hidden = true
                break
            }
        }
        XCTAssertTrue(
            hidden,
            "Hide/reveal was not exercised; video stayed visible. last=\(hiddenProbe)"
        )

        var revealed = false
        var revealedProbe = currentPlaybackProbe()
        for _ in 0..<14 {
            timeline.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            revealedProbe = currentPlaybackProbe()
            let player = presentedNativePlayer()
            if player.exists,
               player.isHittable,
               revealedProbe.contains("item=ready"),
               revealedProbe.contains("vis=1") {
                revealed = true
                break
            }
        }
        XCTAssertTrue(
            revealed,
            "Inline player did not return after reveal. last=\(revealedProbe)"
        )
        XCTAssertTrue(
            presentedNativePlayer().waitForExistence(timeout: 8),
            "Inline player did not return after reveal. last=\(revealedProbe)"
        )
        try tapNativePlayAndRequireTimeAdvance(
            reason: "after hide/reveal",
            requiredSubstring: "vis=1"
        )
        try saveLabScreenshot(name: "timeline-inline-video-after-hide-reveal")
    }

    private func tapNativePlayAndRequireTimeAdvance(
        reason: String,
        requiredSubstring: String?
    ) throws {
        pauseIfPlaying(reason: "before Play (\(reason))")
        revealPlayPauseIfNeeded()

        let playButton = nativePlayPauseButton()
        XCTAssertTrue(
            playButton.waitForExistence(timeout: 8),
            "Native Play did not appear (\(reason)). tree=\(nativeControlSummary(in: presentedNativePlayer())) probe=\(currentPlaybackProbe())"
        )
        XCTAssertTrue(
            playButton.isHittable,
            "Native Play was not hittable (\(reason)). probe=\(currentPlaybackProbe()) frame=\(playButton.frame)"
        )

        let beforeProbe = currentPlaybackProbe()
        XCTAssertTrue(
            Self.probeRate(beforeProbe) <= 0.01,
            "Player was not paused before native Play (\(reason)). before=\(beforeProbe)"
        )
        assertIdentity(beforeProbe, reason: "before Play (\(reason))")
        playButton.tap()
        let after = waitForPlaybackTime(
            greaterThan: Self.probeTime(beforeProbe) + 0.15,
            timeout: 8,
            requiredSubstring: requiredSubstring,
            failureMessage: "Native Play did not advance currentTime (\(reason)). before=\(beforeProbe)"
        )
        assertIdentity(after, reason: "after Play (\(reason))")
    }

    private func revealPlayPauseIfNeeded() {
        if hittableNativeControl(nativePlayPauseButton()) {
            return
        }
        showNativePlaybackChrome(on: presentedNativePlayer())
        if hittableNativeControl(nativePlayPauseButton()) {
            return
        }
        let stillPaused = Self.probeRate(currentPlaybackProbe()) <= 0.01
        guard stillPaused else { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if !hittableNativeControl(nativePlayPauseButton()) {
            showNativePlaybackChrome(on: presentedNativePlayer())
        }
    }

    private func showNativePlaybackChrome(on nativePlayer: XCUIElement) {
        if hittableNativeControl(nativePlayPauseButton()) {
            return
        }
        let target = nativePlayer.exists ? nativePlayer : presentedNativePlayer()
        guard target.exists else { return }
        // 20260909-playing.png: top-center between the expand pill and Play/Pause
        // is empty. Center and bottom taps toggle playback on iOS 26 AVKit.
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.22)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    private func pauseIfPlaying(reason: String) {
        let probe = currentPlaybackProbe()
        guard Self.probeRate(probe) > 0.01 else { return }
        let deadline = Date().addingTimeInterval(6)
        var latest = probe
        while Date() < deadline {
            latest = currentPlaybackProbe()
            if Self.probeRate(latest) <= 0.01 {
                return
            }
            showNativePlaybackChrome(on: presentedNativePlayer())
            let pauseButton = nativePlayPauseButton()
            if hittableNativeControl(pauseButton) {
                pauseButton.tap()
                let pausedDeadline = Date().addingTimeInterval(2)
                while Date() < pausedDeadline {
                    latest = currentPlaybackProbe()
                    if Self.probeRate(latest) <= 0.01 {
                        return
                    }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail(
            "Player stayed playing after native Pause (\(reason)). before=\(probe) last=\(latest) tree=\(nativeControlSummary(in: presentedNativePlayer()))"
        )
    }

    private func nativePlayPauseButton() -> XCUIElement {
        // iOS 26 AVKit uses one "Play/Pause" control. 103733 tapped that label;
        // exact "Play" / "Pause" misses it.
        app.buttons.matching(
            NSPredicate(
                format: "label ==[c] %@ OR label ==[c] %@ OR label ==[c] %@ OR identifier ==[c] %@ OR identifier ==[c] %@",
                "Play",
                "Pause",
                "Play/Pause",
                "Play",
                "Pause"
            )
        ).firstMatch
    }

    private func hittableNativeControl(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
    }

    private func fullscreenControl(in player: XCUIElement) -> XCUIElement? {
        let identified = player.buttons["Fullscreen Button"]
        if identified.exists {
            return identified
        }
        let appIdentified = app.buttons["Fullscreen Button"]
        if appIdentified.exists {
            return appIdentified
        }
        let labeledPredicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR label CONTAINS[c] %@ OR identifier CONTAINS[c] %@",
            "Full Screen",
            "Full Screen",
            "fullscreen",
            "fullscreen",
            "zoom",
            "zoom"
        )
        let labeled = player.buttons.matching(labeledPredicate).firstMatch
        if labeled.exists {
            return labeled
        }
        let appLabeled = app.buttons.matching(labeledPredicate).firstMatch
        if appLabeled.exists {
            return appLabeled
        }

        // 20260909-playing.png: unlabeled expand sits top-leading, sharing a pill
        // with AirPlay. Pick the leftmost hittable control in that region that is
        // not Play/Pause, skip, or AirPlay.
        let playerFrame = player.frame
        guard playerFrame.width > 8, playerFrame.height > 8 else { return nil }
        let region = playerFrame.intersection(
            CGRect(
                x: playerFrame.minX,
                y: playerFrame.minY,
                width: playerFrame.width * 0.40,
                height: playerFrame.height * 0.40
            )
        )
        var best: XCUIElement?
        var bestX = CGFloat.greatestFiniteMagnitude
        let buttons = player.buttons.allElementsBoundByIndex
        for button in buttons {
            guard button.exists, button.isHittable else { continue }
            let label = button.label
            if Self.isPlayPauseLabel(label) { continue }
            if Self.isTransportOrRoutingLabel(label) { continue }
            guard region.intersects(button.frame) else { continue }
            if button.frame.minX < bestX {
                best = button
                bestX = button.frame.minX
            }
        }
        return best
    }

    private func nativeControlSummary(in player: XCUIElement) -> String {
        let buttons = player.buttons.allElementsBoundByIndex
        let limit = min(buttons.count, 16)
        var parts: [String] = []
        for index in 0..<limit {
            let button = buttons[index]
            guard button.exists else { continue }
            parts.append(
                "btn label=\(button.label) id=\(button.identifier) hittable=\(button.isHittable) frame=\(button.frame)"
            )
        }
        if parts.isEmpty {
            parts.append("no-player-buttons playerFrame=\(player.frame)")
        }
        return parts.joined(separator: " || ")
    }

    @discardableResult
    private func waitForPlaybackTime(
        greaterThan minimum: TimeInterval,
        timeout: TimeInterval,
        requiredSubstring: String? = nil,
        failureMessage: String
    ) -> String {
        let latest = waitForPlaybackProbe(timeout: timeout) { candidate in
            let matchesTime = Self.probeTime(candidate) > minimum
            let matchesExtra = requiredSubstring.map { candidate.contains($0) } ?? true
            return matchesTime && matchesExtra && matchesIdentity(candidate)
        }
        let matchesTime = Self.probeTime(latest) > minimum
        let matchesExtra = requiredSubstring.map { latest.contains($0) } ?? true
        if !(matchesTime && matchesExtra) {
            XCTFail("\(failureMessage) last=\(latest)")
        }
        return latest
    }

    @discardableResult
    private func waitForPlaybackProbe(
        timeout: TimeInterval,
        matching predicate: (String) -> Bool
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = currentPlaybackProbe()
        while Date() < deadline {
            latest = currentPlaybackProbe()
            if predicate(latest) {
                return latest
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return latest
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func dismissComposerKeyboardIfNeeded() {
        let dismiss = app.buttons["chat.keyboard.dismiss"]
        if dismiss.exists, dismiss.isHittable {
            dismiss.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    @discardableResult
    private func revealNativePlayer() -> XCUIElement {
        let timeline = timelineElement()
        var player = presentedNativePlayer()
        if player.exists, player.isHittable {
            return player
        }
        if timeline.waitForExistence(timeout: 8) {
            for _ in 0..<14 {
                player = presentedNativePlayer()
                if player.exists, player.isHittable {
                    return player
                }
                timeline.swipeDown()
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        return presentedNativePlayer()
    }

    private func timelineElement() -> XCUIElement {
        let collection = app.collectionViews["chat.timeline"]
        if collection.exists {
            return collection
        }
        return app.otherElements["chat.timeline"]
    }

    private func presentedNativePlayer() -> XCUIElement {
        let players = app.otherElements.matching(identifier: "videoPlayer.native")
        let count = players.count
        var best: XCUIElement?
        var bestArea: CGFloat = -1
        for index in 0..<count {
            let player = players.element(boundBy: index)
            guard player.exists else { continue }
            let area = player.frame.width * player.frame.height
            if player.isHittable, area >= bestArea {
                best = player
                bestArea = area
            } else if best == nil {
                best = player
                bestArea = area
            }
        }
        return best ?? app.otherElements["videoPlayer.native"]
    }

    private func currentPlaybackProbe() -> String {
        var values: [String] = []
        let players = app.otherElements.matching(identifier: "videoPlayer.native")
        for index in 0..<players.count {
            let player = players.element(boundBy: index)
            if let value = player.value as? String, value.contains("time=") {
                values.append(value)
            }
        }
        let overlay = app.otherElements["e2e.video.playback"]
        if overlay.exists {
            if overlay.label.contains("time=") {
                values.append(overlay.label)
            } else if let value = overlay.value as? String, value.contains("time=") {
                values.append(value)
            }
        }
        if let fullScreen = values.first(where: { $0.contains("fs=1") && matchesIdentity($0) }) {
            return fullScreen
        }
        if let identified = values.last(where: { matchesIdentity($0) }) {
            return identified
        }
        return values.last ?? "missing"
    }

    private func assertIdentity(_ probe: String, reason: String) {
        XCTAssertTrue(
            matchesIdentity(probe),
            "Player/model identity changed (\(reason)). expected mid=\(expectedMid ?? "nil") pid=\(expectedPid ?? "nil") probe=\(probe)"
        )
    }

    nonisolated private static let videoFilename = "known-good-h264.mp4"
    nonisolated private static let fillerLineCount = 72

    nonisolated private static func wikiMessage() -> String {
        let filler = (1...fillerLineCount)
            .map { "Scroll filler line \($0) to force the inline video off the visible timeline." }
            .joined(separator: "\n")
        return """
        \(filler)

        Play this clip:

        ![[\(videoFilename)]]

        \(filler)
        """
    }

    nonisolated private static func videoFixtureBase64() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OppiTests/Fixtures/known-good-h264.mp4")
        let data = try Data(contentsOf: url)
        return data.base64EncodedString()
    }

    nonisolated private static func probeTime(_ probe: String) -> TimeInterval {
        guard let value = probeToken(probe, key: "time") else { return 0 }
        return TimeInterval(value) ?? 0
    }

    nonisolated private static func probeRate(_ probe: String) -> Double {
        guard let value = probeToken(probe, key: "rate") else { return 0 }
        return Double(value) ?? 0
    }

    nonisolated private static func probeToken(_ probe: String, key: String) -> String? {
        let prefix = "\(key)="
        guard let range = probe.range(of: prefix) else { return nil }
        return String(probe[range.upperBound...]).split(separator: " ").first.map(String.init)
    }

    nonisolated private static func isPlayPauseLabel(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return lowered == "play" || lowered == "pause" || lowered == "play/pause"
    }

    nonisolated private static func isTransportOrRoutingLabel(_ label: String) -> Bool {
        let lowered = label.lowercased()
        if lowered.isEmpty { return false }
        let skipped = ["skip", "airplay", "tv", "route", "picture", "pip", "elapsed", "remaining", "scrubber"]
        return skipped.contains { lowered.contains($0) } || lowered.contains("10")
    }

    private func matchesIdentity(_ probe: String) -> Bool {
        if let expectedMid {
            guard Self.probeToken(probe, key: "mid") == expectedMid else { return false }
        }
        if let expectedPid {
            guard Self.probeToken(probe, key: "pid") == expectedPid else { return false }
        }
        return true
    }
}
