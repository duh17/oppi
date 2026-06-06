import Foundation
import Testing
@testable import Oppi

@Suite("ServerMessage decoding")
struct ServerMessageTests {

    // MARK: - Connection lifecycle

    @Test func decodesConnected() throws {
        let json = """
        {"type":"connected","session":{"id":"abc","status":"ready","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .connected(let session) = msg else {
            Issue.record("Expected .connected, got \(msg)")
            return
        }
        #expect(session.id == "abc")
        #expect(session.status == .ready)
    }

    @Test func decodesConnectedWithCurrentSeq() throws {
        let json = """
        {"type":"connected","currentSeq":42,"session":{"id":"abc","status":"ready","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .connected(let session) = msg else {
            Issue.record("Expected .connected")
            return
        }
        #expect(session.id == "abc")
    }

    @Test func decodesState() throws {
        let json = """
        {"type":"state","session":{"id":"abc","status":"busy","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":5,"tokens":{"input":100,"output":200},"cost":0.05,"lastMessage":"hello"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .state(let session) = msg else {
            Issue.record("Expected .state")
            return
        }
        #expect(session.status == .busy)
        #expect(session.messageCount == 5)
        #expect(session.lastMessage == "hello")
    }

    @Test func decodesSessionRuntimeKinds() throws {
        let json = """
        {"type":"connected","session":{"id":"abc","status":"ready","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"runtime":"pi-tui"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .connected(let session) = msg else {
            Issue.record("Expected .connected")
            return
        }
        #expect(session.runtime == .piTui)
    }

    @Test func rejectsUnknownSessionRuntimeKinds() {
        let json = """
        {"type":"connected","session":{"id":"abc","status":"ready","createdAt":1700000000000,"lastActivity":1700000000000,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"runtime":"legacy-runtime"}}
        """
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func decodesSessionEnded() throws {
        let json = """
        {"type":"session_ended","reason":"stopped"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .sessionEnded(let reason) = msg else {
            Issue.record("Expected .sessionEnded")
            return
        }
        #expect(reason == "stopped")
    }

    @Test func decodesStopRequested() throws {
        let json = #"{"type":"stop_requested","source":"user","reason":"Stopping current turn"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .stopRequested(let source, let reason) = msg else {
            Issue.record("Expected .stopRequested")
            return
        }
        #expect(source == .user)
        #expect(reason == "Stopping current turn")
    }

    @Test func decodesStopConfirmed() throws {
        let json = #"{"type":"stop_confirmed","source":"timeout"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .stopConfirmed(let source, let reason) = msg else {
            Issue.record("Expected .stopConfirmed")
            return
        }
        #expect(source == .timeout)
        #expect(reason == nil)
    }

    @Test func decodesStopFailed() throws {
        let json = #"{"type":"stop_failed","source":"server","reason":"timed out"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .stopFailed(let source, let reason) = msg else {
            Issue.record("Expected .stopFailed")
            return
        }
        #expect(source == .server)
        #expect(reason == "timed out")
    }

    // MARK: - Agent streaming

    @Test func decodesAgentStart() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"agent_start"}"#)
        #expect(msg == .agentStart)
    }

    @Test func decodesAgentEnd() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"agent_end"}"#)
        #expect(msg == .agentEnd)
    }

    @Test func decodesMessageEnd() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"message_end","role":"assistant","content":"Done"}"#)
        guard case .messageEnd(let role, let content) = msg else {
            Issue.record("Expected .messageEnd")
            return
        }
        #expect(role == "assistant")
        #expect(content == "Done")
    }

    @Test func decodesTextDelta() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"text_delta","delta":"Hello "}"#)
        guard case .textDelta(let delta) = msg else {
            Issue.record("Expected .textDelta")
            return
        }
        #expect(delta == "Hello ")
    }

    @Test func decodesThinkingDelta() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"thinking_delta","delta":"Let me think...","contentIndex":2}"#)
        guard case .thinkingDelta(let delta, let contentIndex) = msg else {
            Issue.record("Expected .thinkingDelta")
            return
        }
        #expect(delta == "Let me think...")
        #expect(contentIndex == 2)
    }

    @Test func decodesAudioStreamChunk() throws {
        let json = #"{"type":"audio_stream","kind":"audio-stream","id":"tts-1","event":"chunk","mimeType":"audio/pcm; codecs=s16le","sampleRate":24000,"channels":1,"chunkIndex":3,"audioBase64":"AAAA","text":"hello","durationSeconds":0.2}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .audioStream(let stream) = msg else {
            Issue.record("Expected .audioStream")
            return
        }
        #expect(stream.id == "tts-1")
        #expect(stream.event == .chunk)
        #expect(stream.mimeType == "audio/pcm; codecs=s16le")
        #expect(stream.sampleRate == 24_000)
        #expect(stream.channels == 1)
        #expect(stream.chunkIndex == 3)
        #expect(stream.audioBase64 == "AAAA")
        #expect(stream.text == "hello")
        #expect(stream.durationSeconds == 0.2)
    }

    @Test func decodesAudioStreamPlaybackBehavior() throws {
        let json = #"{"type":"audio_stream","kind":"audio-stream","id":"audio-1","event":"metadata","mimeType":"audio/wav","playbackBehavior":"playNow","text":"hello"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .audioStream(let stream) = msg else {
            Issue.record("Expected .audioStream")
            return
        }
        #expect(stream.playbackBehavior == .playNow)
    }

    // MARK: - Tool execution

    @Test func decodesToolStart() throws {
        let json = """
        {"type":"tool_start","tool":"bash","args":{"command":"ls -la"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolStart(let tool, let args, let toolCallId, _) = msg else {
            Issue.record("Expected .toolStart")
            return
        }
        #expect(tool == "bash")
        #expect(args["command"] == .string("ls -la"))
        #expect(toolCallId == nil)
    }

    @Test func decodesToolStartWithToolCallId() throws {
        let json = """
        {"type":"tool_start","tool":"bash","args":{"command":"ls"},"toolCallId":"tc-42"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolStart(let tool, _, let toolCallId, _) = msg else {
            Issue.record("Expected .toolStart")
            return
        }
        #expect(tool == "bash")
        #expect(toolCallId == "tc-42")
    }

    @Test func decodesToolUpdate() throws {
        let json = """
        {"type":"tool_update","tool":"write","args":{"path":"README.md","content":"hello"},"toolCallId":"tc-update-1"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolUpdate(let tool, let args, let toolCallId, _) = msg else {
            Issue.record("Expected .toolUpdate")
            return
        }
        #expect(tool == "write")
        #expect(args["path"] == .string("README.md"))
        #expect(toolCallId == "tc-update-1")
    }

    @Test func decodesToolOutput() throws {
        let json = """
        {"type":"tool_output","output":"total 42\\ndrwxr-xr-x"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(let output, let isError, let toolCallId, _, _, _, _) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(output.contains("total 42"))
        #expect(!isError)
        #expect(toolCallId == nil)
    }

    @Test func decodesToolOutputWithToolCallId() throws {
        let json = """
        {"type":"tool_output","output":"data","toolCallId":"tc-42"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(_, _, let toolCallId, _, _, _, _) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(toolCallId == "tc-42")
    }

    @Test func decodesToolOutputWithError() throws {
        let json = """
        {"type":"tool_output","output":"command not found","isError":true}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(_, let isError, _, _, _, _, _) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(isError)
    }

    @Test func decodesToolEnd() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"tool_end","tool":"bash"}"#)
        guard case .toolEnd(let tool, let toolCallId, let details, let isError, _) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(tool == "bash")
        #expect(toolCallId == nil)
        #expect(details == nil)
        #expect(isError == false)
    }

    @Test func decodesToolEndWithToolCallId() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"tool_end","tool":"bash","toolCallId":"tc-42"}"#)
        guard case .toolEnd(let tool, let toolCallId, _, _, _) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(tool == "bash")
        #expect(toolCallId == "tc-42")
    }

    @Test func decodesToolEndWithDetails() throws {
        let json = #"{"type":"tool_end","tool":"remember","toolCallId":"tc-ext","details":{"file":"2026-02-18.md","redacted":false},"isError":false}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolEnd(let tool, let toolCallId, let details, let isError, _) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(tool == "remember")
        #expect(toolCallId == "tc-ext")
        #expect(isError == false)
        // Verify details structure
        guard case .object(let dict) = details else {
            Issue.record("Expected object details")
            return
        }
        #expect(dict["file"] == .string("2026-02-18.md"))
        #expect(dict["redacted"] == .bool(false))
    }

    @Test func decodesToolEndWithIsError() throws {
        let json = #"{"type":"tool_end","tool":"bash","toolCallId":"tc-err","details":{"exitCode":127},"isError":true}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolEnd(_, _, let details, let isError, _) = msg else {
            Issue.record("Expected .toolEnd")
            return
        }
        #expect(isError == true)
        guard case .object(let dict) = details else {
            Issue.record("Expected object details")
            return
        }
        #expect(dict["exitCode"] == .number(127))
    }

    @Test func decodesQueueState() throws {
        let json = #"{"type":"queue_state","queue":{"version":4,"steering":[{"id":"q1","message":"steer one","images":[{"data":"aGVsbG8=","mimeType":"image/png"}],"attachments":[{"type":"attachment","id":"att-1","source":"upload","name":"image-1.png","mimeType":"image/png","sizeBytes":5,"workspacePath":".pi/attachments/demo/image-1.png"}],"createdAt":1}],"followUp":[{"id":"q2","message":"follow one","createdAt":2}]}}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .queueState(let queue) = msg else {
            Issue.record("Expected .queueState")
            return
        }
        #expect(queue.version == 4)
        #expect(queue.steering.count == 1)
        #expect(queue.steering.first?.id == "q1")
        #expect(queue.steering.first?.optimisticImages == nil)
        #expect(queue.steering.first?.attachments?.first?.workspacePath == ".pi/attachments/demo/image-1.png")
        #expect(queue.followUp.count == 1)
        #expect(queue.followUp.first?.message == "follow one")
    }

    @Test func decodesQueueItemStarted() throws {
        let json = #"{"type":"queue_item_started","kind":"follow_up","item":{"id":"q3","message":"continue","createdAt":3},"queueVersion":5}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .queueItemStarted(let kind, let item, let queueVersion) = msg else {
            Issue.record("Expected .queueItemStarted")
            return
        }
        #expect(kind == .followUp)
        #expect(item.id == "q3")
        #expect(item.message == "continue")
        #expect(queueVersion == 5)
    }

    @Test func decodesTurnAck() throws {
        let json = #"{"type":"turn_ack","command":"prompt","clientTurnId":"turn-1","stage":"dispatched","requestId":"req-1","duplicate":false}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .turnAck(let command, let clientTurnId, let stage, let requestId, let duplicate) = msg else {
            Issue.record("Expected .turnAck")
            return
        }
        #expect(command == "prompt")
        #expect(clientTurnId == "turn-1")
        #expect(stage == .dispatched)
        #expect(requestId == "req-1")
        #expect(!duplicate)
    }

    // MARK: - Legacy Permissions

    @Test func legacyPermissionMessagesDecodeAsUnknown() throws {
        let legacyTypes = [
            "permission_request",
            "permission_expired",
            "permission_cancelled",
            "permission_resolved",
            "permission_auto_reviewed",
        ]

        for type in legacyTypes {
            let msg = try ServerMessage.decode(from: #"{"type":"\#(type)"}"#)
            guard case .unknown(let decodedType) = msg else {
                Issue.record("Expected .unknown for legacy type \(type)")
                return
            }
            #expect(decodedType == type)
        }
    }

    // MARK: - Error

    @Test func decodesError() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"error","error":"something broke"}"#)
        guard case .error(let message, let code, let fatal) = msg else {
            Issue.record("Expected .error")
            return
        }
        #expect(message == "something broke")
        #expect(code == nil)
        #expect(!fatal)
    }

    @Test func decodesFatalError() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"error","error":"Workspace session limit reached (3)","code":"SESSION_LIMIT_WORKSPACE","fatal":true}"#)
        guard case .error(let message, let code, let fatal) = msg else {
            Issue.record("Expected .error")
            return
        }
        #expect(message == "Workspace session limit reached (3)")
        #expect(code == "SESSION_LIMIT_WORKSPACE")
        #expect(fatal)
    }

    // MARK: - Unknown type handling

    @Test func unknownTypeDecodesToUnknown() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"future_feature","data":"stuff"}"#)
        guard case .unknown(let type) = msg else {
            Issue.record("Expected .unknown")
            return
        }
        #expect(type == "future_feature")
    }

    // MARK: - Extension UI

    @Test func decodesExtensionUIRequest() throws {
        let json = """
        {"type":"extension_ui_request","id":"ext1","sessionId":"s1","method":"select","title":"Choose option","options":["A","B","C"],"timeout":5000,"timeoutAt":1893456000000}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUIRequest(let req) = msg else {
            Issue.record("Expected .extensionUIRequest")
            return
        }
        #expect(req.id == "ext1")
        #expect(req.method == "select")
        #expect(req.options == ["A", "B", "C"])
        #expect(req.timeout == 5000)
        #expect(req.timeoutAt == Date(timeIntervalSince1970: 1_893_456_000))
    }

    @Test func decodesExtensionUIRequestNativeSurface() throws {
        let json = """
        {
          "type": "extension_ui_request",
          "id": "ext-native",
          "sessionId": "s1",
          "method": "editor",
          "title": "Edit plan",
          "nativeSurface": {
            "version": 1,
            "id": "request:plan",
            "source": "custom",
            "presentation": { "style": "sheet", "title": "Edit plan" },
            "blocks": [{ "type": "text", "spans": [{ "text": "Review before submit." }] }]
          }
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUIRequest(let request) = msg else {
            Issue.record("Expected .extensionUIRequest")
            return
        }
        #expect(request.nativeSurface?.id == "request:plan")
        #expect(request.nativeSurface?.hasVisibleContent == true)
    }

    @Test func decodesExtensionUISettled() throws {
        let json = #"{"type":"extension_ui_settled","id":"ext1","sessionId":"s1"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUISettled(let id, let sessionId) = msg else {
            Issue.record("Expected .extensionUISettled")
            return
        }
        #expect(id == "ext1")
        #expect(sessionId == "s1")
    }

    @Test func decodesExtensionUINativeSurfaceNotification() throws {
        let json = """
        {
          "type": "extension_ui_notification",
          "method": "setWidget",
          "widgetKey": "subagents",
          "nativeSurface": {
            "version": 1,
            "id": "widget:subagents",
            "source": "widget",
            "presentation": { "style": "surfacePanel", "placement": "aboveEditor", "title": "Agents" },
            "blocks": [
              {
                "type": "activityList",
                "id": "agents",
                "rows": [
                  {
                    "id": "child-1",
                    "title": "Explore files",
                    "subtitle": "Running · 3 messages",
                    "state": "running",
                    "link": "oppi://session/child-1"
                  }
                ]
              }
            ],
            "fallback": { "lines": ["● Agents", "  Running Explore files"] }
          }
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUINotification(let notification) = msg else {
            Issue.record("Expected .extensionUINotification")
            return
        }
        #expect(notification.nativeSurface?.id == "widget:subagents")
        guard case .activityList(_, let rows)? = notification.nativeSurface?.blocks.first else {
            Issue.record("Expected native activityList block")
            return
        }
        #expect(rows.first?.link == "oppi://session/child-1")
    }

    @Test func extensionSurfaceSessionLinkParsesWorkspaceQuery() throws {
        let url = try #require(URL(string: "oppi://session/child-1?workspaceId=ws-1"))
        let link = try #require(ExtensionSurfaceSessionLink.parse(url, defaultWorkspaceId: nil))

        #expect(link.sessionId == "child-1")
        #expect(link.workspaceId == "ws-1")
    }

    @Test func extensionSurfaceSessionLinkFallsBackToCurrentWorkspace() throws {
        let url = try #require(URL(string: "oppi://session/child-1"))
        let link = try #require(ExtensionSurfaceSessionLink.parse(url, defaultWorkspaceId: " ws-parent "))

        #expect(link.sessionId == "child-1")
        #expect(link.workspaceId == "ws-parent")
    }

    @Test func unsupportedExtensionUINativeBlocksDoNotFailMessageDecode() throws {
        let json = """
        {
          "type": "extension_ui_notification",
          "method": "setWidget",
          "widgetKey": "future",
          "nativeSurface": {
            "version": 1,
            "id": "widget:future",
            "source": "widget",
            "presentation": { "style": "surfacePanel" },
            "blocks": [{ "type": "futureBlock", "id": "f1" }],
            "fallback": { "lines": ["future fallback"] }
          }
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUINotification(let notification) = msg else {
            Issue.record("Expected .extensionUINotification")
            return
        }
        guard case .unsupported(_, let type)? = notification.nativeSurface?.blocks.first else {
            Issue.record("Expected unsupported native block")
            return
        }
        #expect(type == "futureBlock")
        #expect(notification.nativeSurface?.nativeDisplayBlocks.isEmpty == true)
        #expect(notification.nativeSurface?.fallbackDisplayLines == ["future fallback"])
    }

    @Test func extensionUINativeSurfaceFallbackTextIsRenderable() throws {
        let json = """
        {
          "type": "extension_ui_notification",
          "method": "setWidget",
          "widgetKey": "future",
          "nativeSurface": {
            "version": 1,
            "id": "widget:future",
            "source": "widget",
            "presentation": { "style": "surfacePanel" },
            "blocks": [],
            "fallback": { "text": "fallback one\\nfallback two" }
          }
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUINotification(let notification) = msg else {
            Issue.record("Expected .extensionUINotification")
            return
        }
        #expect(notification.nativeSurface?.hasVisibleContent == true)
        #expect(notification.nativeSurface?.fallbackDisplayLines == ["fallback one", "fallback two"])
    }

    @Test func extensionUINativeSurfaceFallsBackForUndisplayableSection() throws {
        let json = """
        {
          "type": "extension_ui_notification",
          "method": "setWidget",
          "widgetKey": "nested-settings",
          "nativeSurface": {
            "version": 1,
            "id": "widget:nested-settings",
            "source": "widget",
            "presentation": { "style": "surfacePanel" },
            "blocks": [
              {
                "type": "section",
                "id": "outer",
                "blocks": [
                  { "type": "form", "id": "credentials", "fields": [] },
                  { "type": "settingsList", "id": "models", "items": [] }
                ]
              }
            ]
          }
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUINotification(let notification) = msg else {
            Issue.record("Expected .extensionUINotification")
            return
        }
        #expect(notification.nativeSurface?.nativeDisplayBlocks.isEmpty == true)
        #expect(notification.nativeSurface?.fallbackDisplayLines == ["Unsupported extension surface: form, settingsList"])
    }

    @Test func decodesExtensionUINativeFormAndSettingsPayloads() throws {
        let json = """
        {
          "type": "extension_ui_notification",
          "method": "setWidget",
          "widgetKey": "settings",
          "nativeSurface": {
            "version": 1,
            "id": "widget:settings",
            "source": "widget",
            "presentation": { "style": "surfacePanel" },
            "blocks": [
              {
                "type": "form",
                "id": "credentials",
                "fields": [
                  { "id": "token", "type": "text", "label": "Token", "placeholder": "paste token", "required": true, "sensitive": true },
                  { "id": "enabled", "type": "toggle", "label": "Enabled", "value": true, "description": "Use this token" }
                ]
              },
              {
                "type": "settingsList",
                "id": "models",
                "items": [
                  { "id": "model", "label": "Model", "value": "gpt", "description": "Default model", "values": ["gpt", "local"], "disabled": false }
                ]
              }
            ]
          }
        }
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUINotification(let notification) = msg,
              let blocks = notification.nativeSurface?.blocks,
              blocks.count == 2 else {
            Issue.record("Expected native form and settings blocks")
            return
        }

        guard case .form(_, let fields) = blocks[0] else {
            Issue.record("Expected form fields to decode")
            return
        }
        #expect(fields.count == 2)
        guard case .text(let textField) = fields[0] else {
            Issue.record("Expected text field")
            return
        }
        #expect(textField.id == "token")
        #expect(textField.placeholder == "paste token")
        #expect(textField.required == true)
        #expect(textField.sensitive == true)
        guard case .toggle(let toggleField) = fields[1] else {
            Issue.record("Expected toggle field")
            return
        }
        #expect(toggleField.value == true)

        guard case .settingsList(_, let items) = blocks[1] else {
            Issue.record("Expected settings items to decode")
            return
        }
        #expect(items.first?.id == "model")
        #expect(items.first?.values == ["gpt", "local"])
        #expect(items.first?.disabled == false)
        #expect(notification.nativeSurface?.nativeDisplayBlocks.isEmpty == true)
        #expect(notification.nativeSurface?.fallbackDisplayLines == ["Unsupported extension surface: form, settingsList"])
    }

    // MARK: - Malformed / Edge Cases

    @Test func missingTypeFieldThrows() {
        let json = #"{"data":"no type field"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func emptyStringThrows() {
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: "")
        }
    }

    @Test func invalidJSONThrows() {
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: "not json at all {{{")
        }
    }

    @Test func textDeltaMissingDeltaFieldThrows() {
        // text_delta requires a "delta" field
        let json = #"{"type":"text_delta"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func toolStartMissingToolFieldThrows() {
        let json = #"{"type":"tool_start","args":{}}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func errorMissingMessageFieldThrows() {
        let json = #"{"type":"error"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }

    @Test func extraFieldsAreIgnored() throws {
        // Extra fields should not break decoding
        let json = #"{"type":"agent_start","extra":"ignored","nested":{"a":1}}"#
        let msg = try ServerMessage.decode(from: json)
        #expect(msg == .agentStart)
    }

    @Test func toolStartWithNullArgsDefaultsToEmpty() throws {
        let json = #"{"type":"tool_start","tool":"read"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolStart(let tool, let args, _, _) = msg else {
            Issue.record("Expected .toolStart")
            return
        }
        #expect(tool == "read")
        #expect(args.isEmpty)
    }

    @Test func toolOutputDefaultsIsErrorToFalse() throws {
        let json = #"{"type":"tool_output","output":"data"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(let output, let isError, _, let mode, let truncated, let totalBytes, _) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(output == "data")
        #expect(!isError)
        #expect(mode == .append)
        #expect(!truncated)
        #expect(totalBytes == nil)
    }

    @Test func toolOutputDecodesReplaceMode() throws {
        let json = #"{"type":"tool_output","output":"tail preview","toolCallId":"tc-1","mode":"replace","truncated":true,"totalBytes":32768}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(let output, _, let toolCallId, let mode, let truncated, let totalBytes, _) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(output == "tail preview")
        #expect(toolCallId == "tc-1")
        #expect(mode == .replace)
        #expect(truncated)
        #expect(totalBytes == 32768)
    }

    @Test func toolOutputDefaultsToAppendModeWhenOmitted() throws {
        let json = #"{"type":"tool_output","output":"data","toolCallId":"tc-2"}"#
        let msg = try ServerMessage.decode(from: json)
        guard case .toolOutput(_, _, _, let mode, let truncated, _, _) = msg else {
            Issue.record("Expected .toolOutput")
            return
        }
        #expect(mode == .append)
        #expect(!truncated)
    }

    @Test func multipleUnknownTypesAllDecode() throws {
        let types = ["new_feature", "v2_event", "debug_info", ""]
        for type in types {
            let json = #"{"type":"\#(type)"}"#
            let msg = try ServerMessage.decode(from: json)
            guard case .unknown(let decoded) = msg else {
                Issue.record("Expected .unknown for type '\(type)', got \(msg)")
                return
            }
            #expect(decoded == type)
        }
    }

    @Test func sessionEndedMissingReasonThrows() {
        let json = #"{"type":"session_ended"}"#
        #expect(throws: DecodingError.self) {
            try ServerMessage.decode(from: json)
        }
    }



    @Test func extensionUINotification() throws {
        let json = """
        {"type":"extension_ui_notification","method":"status","message":"Building...","notifyType":"info"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .extensionUINotification(let notification) = msg else {
            Issue.record("Expected .extensionUINotification")
            return
        }
        #expect(notification.method == "status")
        #expect(notification.message == "Building...")
        #expect(notification.notifyType == "info")
    }

    // MARK: - Command Result

    @Test func decodesCommandResult() throws {
        let json = """
        {"type":"command_result","command":"set_model","requestId":"req-1","success":true,"data":{"id":"claude-sonnet-4"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .commandResult(let command, let requestId, let success, let data, let error) = msg else {
            Issue.record("Expected .commandResult")
            return
        }
        #expect(command == "set_model")
        #expect(requestId == "req-1")
        #expect(success)
        #expect(data != nil)
        #expect(error == nil)
    }

    @Test func decodesCommandResultFailure() throws {
        let json = """
        {"type":"command_result","command":"bash","success":false,"error":"Permission denied"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .commandResult(let command, _, let success, _, let error) = msg else {
            Issue.record("Expected .commandResult")
            return
        }
        #expect(command == "bash")
        #expect(!success)
        #expect(error == "Permission denied")
    }

    @Test func rpcResultDecodesAsUnknown() throws {
        // Server only emits "command_result" — the old "rpc_result" alias was removed.
        // Unknown types decode gracefully to .unknown.
        let json = """
        {"type":"rpc_result","command":"get_state","requestId":"r-2","success":true}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .unknown(let type) = msg else {
            Issue.record("Expected .unknown for removed rpc_result type")
            return
        }
        #expect(type == "rpc_result")
    }

    // MARK: - Compaction

    @Test func decodesCompactionStart() throws {
        let msg = try ServerMessage.decode(from: #"{"type":"compaction_start","reason":"threshold"}"#)
        guard case .compactionStart(let reason) = msg else {
            Issue.record("Expected .compactionStart")
            return
        }
        #expect(reason == "threshold")
    }

    @Test func decodesCompactionEnd() throws {
        let json = """
        {"type":"compaction_end","aborted":false,"willRetry":true,"summary":"Summarized context","tokensBefore":150000}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .compactionEnd(let aborted, let willRetry, let summary, let tokensBefore) = msg else {
            Issue.record("Expected .compactionEnd")
            return
        }
        #expect(!aborted)
        #expect(willRetry)
        #expect(summary == "Summarized context")
        #expect(tokensBefore == 150_000)
    }

    // MARK: - Retry

    @Test func decodesRetryStart() throws {
        let json = """
        {"type":"retry_start","attempt":1,"maxAttempts":3,"delayMs":2000,"errorMessage":"529 overloaded"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .retryStart(let attempt, let maxAttempts, let delayMs, let errorMessage) = msg else {
            Issue.record("Expected .retryStart")
            return
        }
        #expect(attempt == 1)
        #expect(maxAttempts == 3)
        #expect(delayMs == 2000)
        #expect(errorMessage == "529 overloaded")
    }

    @Test func decodesRetryEnd() throws {
        let json = """
        {"type":"retry_end","success":false,"attempt":3,"finalError":"Max retries exceeded"}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .retryEnd(let success, let attempt, let finalError) = msg else {
            Issue.record("Expected .retryEnd")
            return
        }
        #expect(!success)
        #expect(attempt == 3)
        #expect(finalError == "Max retries exceeded")
    }

    // MARK: - Full session

    @Test func connectedWithFullSessionFields() throws {
        let json = """
        {"type":"connected","session":{"id":"s1","status":"busy","createdAt":1700000000000,\
        "lastActivity":1700000000000,"messageCount":3,"tokens":{"input":50,"output":100},"cost":0.02,\
        "model":"anthropic/claude-sonnet-4-0","contextTokens":150,"contextWindow":200000,"lastMessage":"working"}}
        """
        let msg = try ServerMessage.decode(from: json)
        guard case .connected(let session) = msg else {
            Issue.record("Expected .connected")
            return
        }
        #expect(session.model == "anthropic/claude-sonnet-4-0")
        #expect(session.contextTokens == 150)
        #expect(session.contextWindow == 200_000)
    }
}
