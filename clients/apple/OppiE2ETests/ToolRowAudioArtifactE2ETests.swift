import Foundation
import XCTest

/// Paired-server proof that voice/audio tool results become server-owned
/// session attachments and remain replayable from the native timeline row.
@MainActor
final class ToolRowAudioArtifactE2ETests: E2ETestCase {
    func testToolRowVoiceAudioUsesSessionAttachmentPlayback() throws {
        createAndEnterSession()
        _ = waitForWebSocketConnected(timeout: 20)
        let sessionId = waitForFocusedSessionId(timeout: 20)
        let workspaceId = try e2eWorkspaceId()
        let toolId = "tool-row-audio-e2e"
        let transcript = "E2E audio artifact reached the client."

        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_notification",
            "method": "setToolsExpanded",
            "toolsExpanded": false,
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_start"])
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_start",
            "tool": "voice_speak",
            "toolCallId": toolId,
            "args": ["text": transcript],
        ])
        let endResponse = try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "tool_end",
            "tool": "voice_speak",
            "toolCallId": toolId,
            "details": [
                "kind": "audio_presentation",
                "text": transcript,
                "playbackBehavior": "tapToPlay",
                "audio": [
                    "kind": "audio",
                    "mimeType": "audio/wav",
                    "fileName": "e2e-voice.wav",
                    "durationSeconds": 0.75,
                    "base64": Self.silentWAVBase64(durationSeconds: 0.75),
                ],
            ],
        ])
        try sendE2EHarnessMessage(sessionId: sessionId, ["type": "agent_end"])

        let attachmentId = try assertHarnessMaterializedAttachment(in: endResponse)
        let attachment = try e2eLabAPIBytes(
            method: "GET",
            path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/attachments/\(attachmentId)"
        )
        XCTAssertEqual(attachment.statusCode, 200)
        XCTAssertEqual(String(data: attachment.body.prefix(4), encoding: .ascii), "RIFF")

        let toolRow = app.descendants(matching: .any)["chat.timeline.row.\(toolId)"]
        XCTAssertTrue(toolRow.waitForExistence(timeout: 10), "Audio tool row did not appear")

        let playButton = app.buttons["chat.timeline.row.\(toolId).audio.play"]
        XCTAssertTrue(playButton.waitForExistence(timeout: 10), "Collapsed audio replay button did not appear")
        XCTAssertEqual(playButton.label, "Play voice message")

        tap(playButton, named: "collapsed audio replay button", timeout: 5)
        XCTAssertTrue(
            waitForButtonLabel(playButton, "Stop voice message", timeout: 5),
            "Audio replay button did not enter playback/loading state"
        )

        tapToolRowChrome(toolRow)
        let audioTranscript = app.staticTexts["chat.timeline.row.\(toolId).audio.message.transcript"]
        XCTAssertTrue(audioTranscript.waitForExistence(timeout: 10), "Expanded voice transcript did not appear")
        XCTAssertTrue(audioTranscript.label.contains(transcript), "Expanded voice transcript text did not match")
        try saveLabScreenshot(name: "tool-row-audio-artifact-e2e")
    }

    private func assertHarnessMaterializedAttachment(in response: [String: Any]) throws -> String {
        let message = try XCTUnwrap(response["message"] as? [String: Any], "Harness response missing message")
        let details = try XCTUnwrap(message["details"] as? [String: Any], "Harness response missing tool details")
        let audio = try XCTUnwrap(details["audio"] as? [String: Any], "Harness response missing audio details")
        let attachmentId = try XCTUnwrap(audio["id"] as? String, "Harness did not materialize an audio attachment id")
        XCTAssertNil(audio["base64"], "Harness response should strip inline base64 after materializing the attachment")
        XCTAssertEqual(audio["mimeType"] as? String, "audio/wav")
        return attachmentId
    }

    private func e2eWorkspaceId() throws -> String {
        let response = try e2eLabAPIJSON(method: "GET", path: "/workspaces")
        let workspaces = try XCTUnwrap(response["workspaces"] as? [[String: Any]], "Workspace list response missing workspaces")
        let workspace = try XCTUnwrap(
            workspaces.first { ($0["name"] as? String) == "e2e-workspace" },
            "e2e-workspace not found"
        )
        return try XCTUnwrap(workspace["id"] as? String, "e2e-workspace response missing id")
    }

    private func tapToolRowChrome(_ row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Tool row did not exist before tap")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.16)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func waitForButtonLabel(_ button: XCUIElement, _ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if button.exists, button.label == label {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return button.exists && button.label == label
    }

    private static func silentWAVBase64(sampleRate: UInt32 = 8_000, durationSeconds: Double) -> String {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = UInt32(Double(sampleRate) * durationSeconds)
        let dataByteCount = sampleCount * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        var data = Data()

        func appendASCII(_ string: String) {
            data.append(contentsOf: string.utf8)
        }

        func appendUInt16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        func appendUInt32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataByteCount)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(channelCount)
        appendUInt32(sampleRate)
        appendUInt32(sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8))
        appendUInt16(channelCount * (bitsPerSample / 8))
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(dataByteCount)
        data.append(Data(count: Int(dataByteCount)))
        return data.base64EncodedString()
    }
}
