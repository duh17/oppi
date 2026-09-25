import Foundation
import XCTest

/// Paired-server proof that an owner-host video outside any workspace shows
/// timed captions from adjacent `clip.srt` and `clip.<lang>.srt` sidecars in
/// the inline chat player and the file-browser player.
///
/// The oracle is the caption overlay text and the player-local playback probe
/// (`videoPlayer.native` value). Captions are Oppi's overlay, not AVKit CC.
@MainActor
final class HostVideoCaptionsE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceName = ""
    nonisolated(unsafe) private var hostVideoPath = ""

    override var e2eStartsInAutoCreatedChat: Bool { true }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchEnvironment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] = workspaceName
        application.launchEnvironment["OPPI_E2E_AUTO_CREATE_SESSION"] = "1"
        application.launchEnvironment["OPPI_E2E_DIAGNOSTICS"] = "1"
    }

    override func seedE2EFixtures() throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        workspaceName = "host-captions-\(suffix)"
        let workspaceFixture = try createLabWorkspaceFileFixture(
            directoryName: workspaceName,
            filename: "README.md",
            base64: Data("# Host captions\n".utf8).base64EncodedString()
        )
        _ = try createLabWorkspace(named: workspaceName, hostMount: workspaceFixture.hostMount)

        // A separate directory that no workspace mounts: a plain host path.
        let hostDirectory = "host-captions-media-\(suffix)"
        let video = try createLabWorkspaceFileFixture(
            directoryName: hostDirectory,
            filename: Self.videoFilename,
            base64: try Self.videoFixtureBase64()
        )
        hostVideoPath = video.filePath
        for (name, body) in [
            ("host-clip.srt", Self.bareSRT),
            ("host-clip.fr.srt", Self.frenchSRT),
        ] {
            _ = try createLabWorkspaceFileFixture(
                directoryName: hostDirectory,
                filename: name,
                base64: Data(body.utf8).base64EncodedString()
            )
        }
    }

    func testHostVideoShowsSidecarCaptionsInlineAndInFileBrowser() throws {
        waitForRequiredSplitStreamCapabilities()
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        try clearE2EHarnessResponses(sessionId: sessionId)

        let message = """
        Open it: [[\(hostVideoPath)|Open host clip]]

        Inline host clip:
        ![[\(hostVideoPath)]]
        """
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "text_delta", "delta": message])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "message_end",
            "role": "assistant",
            "content": message,
            "persist": true,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_settled"])

        // Inline chat player: bare sidecar auto-picked at t=0, language control present.
        let inlinePlayer = app.otherElements.matching(identifier: "videoPlayer.native").element(boundBy: 0)
        XCTAssertTrue(inlinePlayer.waitForExistence(timeout: 20), "Inline host video did not appear")
        XCTAssertTrue(
            waitForCaption(containing: "Caption one", in: inlinePlayer, timeout: 15),
            "Inline host video did not show the bare .srt cue. tree=\(captionSummary())"
        )
        XCTAssertTrue(
            inlinePlayer.buttons["Caption language"].waitForExistence(timeout: 5),
            "Two host sidecars should offer the caption language control"
        )
        try saveLabScreenshot(name: "host-captions-inline-cue-one")

        // Playback moves the cue.
        tapPlay(on: inlinePlayer)
        XCTAssertTrue(
            waitForCaption(containing: "Caption two", in: inlinePlayer, timeout: 12),
            "Inline caption did not follow playback to cue two. probe=\(playbackProbe()) tree=\(captionSummary())"
        )
        XCTAssertFalse(captionExists(containing: "Caption one", in: inlinePlayer), "Cue one stayed visible after its end time")
        try saveLabScreenshot(name: "host-captions-inline-cue-two")
        tapPause(on: inlinePlayer)

        // File-browser player from the host wiki link.
        let link = app.links.matching(NSPredicate(format: "label CONTAINS %@", "Open host clip")).firstMatch
        if !link.waitForExistence(timeout: 10) {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "ax-missing-host-clip-link"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Host clip wiki link did not render")
            return
        }
        let inlineFrame = inlinePlayer.frame
        link.tap()

        // Scope every file-browser query to the pushed player, not the inline
        // player that stays mounted underneath on the chat stack.
        let browserPlayer = pushedPlayer(excludingFrame: inlineFrame)
        XCTAssertTrue(browserPlayer.exists, "File-browser host video did not open")
        XCTAssertTrue(
            waitForCaption(containing: "Caption one", in: browserPlayer, timeout: 15),
            "File-browser host video did not show the bare .srt cue. tree=\(captionSummary())"
        )

        // Language picker switches tracks at the same authored time.
        let language = browserPlayer.buttons["Caption language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5), "File-browser caption language control missing")
        language.tap()
        let french = app.buttons["fr"].exists ? app.buttons["fr"] : app.menuItems["fr"]
        XCTAssertTrue(french.waitForExistence(timeout: 5), "French track missing from the language menu")
        french.tap()
        XCTAssertTrue(
            waitForCaption(containing: "Légende une", in: browserPlayer, timeout: 5),
            "Selecting fr did not show the French cue. tree=\(captionSummary())"
        )
        try saveLabScreenshot(name: "host-captions-browser-french")

        // Seeking moves the cue: scrub near the end, inside cue three.
        // AVKit's scrubber is not always a descendant of the player element; the
        // pushed player is the only visible one, so take the hittable slider.
        guard let scrubber = visibleScrubber(on: browserPlayer) else {
            XCTFail("File-browser scrubber did not appear. player=\(browserPlayer.debugDescription)")
            return
        }
        seek(scrubber, toFraction: 0.8)
        XCTAssertTrue(
            waitForCaption(containing: "Légende trois", in: browserPlayer, timeout: 10),
            "Caption did not follow seeking to cue three. probe=\(playbackProbe()) tree=\(captionSummary())"
        )
        try saveLabScreenshot(name: "host-captions-browser-seeked")
    }

    /// AVKit's scrubber: a hittable slider, or on newer AVKit an element named
    /// like a timeline/scrubber. Tap once to reveal controls; a second tap
    /// would hide them again.
    private func visibleScrubber(on player: XCUIElement) -> XCUIElement? {
        showControls(on: player)
        if let slider = app.sliders.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
            return slider
        }
        let named = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier CONTAINS[c] %@ OR label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "scrub", "scrub", "timeline", "timeline"
        )).firstMatch
        return named.waitForExistence(timeout: 2) ? named : nil
    }

    private func seek(_ scrubber: XCUIElement, toFraction fraction: CGFloat) {
        if scrubber.elementType == .slider {
            scrubber.adjust(toNormalizedSliderPosition: fraction)
            return
        }
        let start = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let end = scrubber.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)
    }

    /// The largest player whose frame differs from the inline chat player.
    private func pushedPlayer(excludingFrame inlineFrame: CGRect) -> XCUIElement {
        let players = app.otherElements.matching(identifier: "videoPlayer.native")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let candidates = players.allElementsBoundByIndex.filter { player in
                player.exists && player.frame != inlineFrame && player.frame.width > 8
            }
            if let best = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                return best
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "ax-missing-pushed-player"
        tree.lifetime = .keepAlways
        add(tree)
        return players.element(boundBy: players.count)
    }

    // MARK: - Helpers

    private func captionQuery(containing text: String, in player: XCUIElement) -> XCUIElementQuery {
        player.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text))
    }

    private func captionExists(containing text: String, in player: XCUIElement) -> Bool {
        captionQuery(containing: text, in: player).firstMatch.exists
    }

    private func waitForCaption(
        containing text: String,
        in player: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        captionQuery(containing: text, in: player).firstMatch.waitForExistence(timeout: timeout)
    }

    private func captionSummary() -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(40).map(\.label)
        return texts.filter { $0.contains("Caption") || $0.contains("Légende") }.joined(separator: " | ")
    }

    private func playbackProbe() -> String {
        let players = app.otherElements.matching(identifier: "videoPlayer.native")
        for index in 0..<players.count {
            if let value = players.element(boundBy: index).value as? String, value.contains("time=") {
                return value
            }
        }
        return "missing"
    }

    private func playPauseButton() -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label ==[c] %@ OR label ==[c] %@ OR label ==[c] %@", "Play", "Pause", "Play/Pause")
        ).firstMatch
    }

    /// Tap the video surface, not the player container: a file-browser player
    /// container is taller than the letterboxed video it hosts.
    private func showControls(on player: XCUIElement) {
        if playPauseButton().exists, playPauseButton().isHittable { return }
        let video = player.otherElements["Video"]
        let surface = video.exists ? video : player
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.22)).tap()
        _ = playPauseButton().waitForExistence(timeout: 2)
    }

    private func tapPlay(on player: XCUIElement) {
        showControls(on: player)
        let button = playPauseButton()
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Native Play did not appear")
        button.tap()
    }

    private func tapPause(on player: XCUIElement) {
        showControls(on: player)
        let button = playPauseButton()
        if button.waitForExistence(timeout: 4), button.isHittable {
            button.tap()
        }
    }

    nonisolated private static let videoFilename = "host-clip.mp4"

    nonisolated private static let bareSRT = """
    1
    00:00:00,000 --> 00:00:01,500
    Caption one

    2
    00:00:02,000 --> 00:00:30,000
    Caption two

    3
    00:00:40,000 --> 00:01:30,000
    Caption three

    """

    nonisolated private static let frenchSRT = """
    1
    00:00:00,000 --> 00:00:01,500
    Légende une

    2
    00:00:02,000 --> 00:00:30,000
    Légende deux

    3
    00:00:40,000 --> 00:01:30,000
    Légende trois

    """

    nonisolated private static func videoFixtureBase64() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("OppiTests/Fixtures/known-good-h264.mp4")
        return try Data(contentsOf: url).base64EncodedString()
    }
}
