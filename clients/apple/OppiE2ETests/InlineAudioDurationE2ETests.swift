import Foundation
import XCTest

/// Paired-server proof that an inline markdown audio card labels the clip
/// with its server-read length before playback, instead of `0:00 / --:--`.
@MainActor
final class InlineAudioDurationE2ETests: E2ETestCase {
    nonisolated(unsafe) private var workspaceName = ""
    nonisolated(unsafe) private var audioPath = ""

    override var e2eStartsInAutoCreatedChat: Bool { true }
    override var e2eRequiresFreshLaunch: Bool { true }

    override func configureE2ELaunch(_ application: XCUIApplication) {
        application.launchEnvironment["OPPI_E2E_AUTO_OPEN_WORKSPACE"] = workspaceName
        application.launchEnvironment["OPPI_E2E_AUTO_CREATE_SESSION"] = "1"
    }

    override func seedE2EFixtures() throws {
        workspaceName = "inline-audio-\(UUID().uuidString.prefix(8).lowercased())"
        let fixture = try createLabWorkspaceFileFixture(
            directoryName: workspaceName,
            filename: "take-4bit-overlap.wav",
            base64: Self.silentWAVBase64(durationSeconds: 3.5)
        )
        audioPath = fixture.filePath
        _ = try createLabWorkspace(named: workspaceName, hostMount: fixture.hostMount)
    }

    func testInlineAudioShowsLengthBeforePlayback() throws {
        waitForWebSocketConnected()
        let sessionId = waitForFocusedSessionId(timeout: 20)
        try clearE2EHarnessResponses(sessionId: sessionId)

        let message = "Latest take:\n\n![[\(audioPath)]]\n\nDone."
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

        let play = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", ".audio.play")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "Inline audio card did not appear")
        let time = app.staticTexts.matching(NSPredicate(format: "identifier ENDSWITH %@", ".audio.time")).firstMatch
        let labeled = NSPredicate(format: "label == %@", "0:03")
        let result = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: labeled, object: time)],
            timeout: 15
        )
        try saveLabScreenshot(name: "inline-audio-duration-idle")
        XCTAssertEqual(result, .completed, "Idle card should show the clip length; got '\(time.label)'")
        XCTAssertEqual(play.label, "Play audio")
    }

    /// 16-bit mono PCM silence; the server reads the length from this header.
    nonisolated private static func silentWAVBase64(sampleRate: UInt32 = 8_000, durationSeconds: Double) -> String {
        let dataByteCount = UInt32(Double(sampleRate) * durationSeconds) * 2
        var data = Data()
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8)
        appendUInt32(36 + dataByteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(sampleRate)
        appendUInt32(sampleRate * 2)
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: "data".utf8)
        appendUInt32(dataByteCount)
        data.append(Data(count: Int(dataByteCount)))
        return data.base64EncodedString()
    }
}
