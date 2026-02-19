import Testing
import Foundation
@testable import Oppi

@Suite("ClientMessage encoding")
struct ClientMessageTests {

    @Test func encodesPrompt() throws {
        let msg = ClientMessage.prompt(message: "hello world")
        let json = try decode(msg)
        #expect(json["type"] as? String == "prompt")
        #expect(json["message"] as? String == "hello world")
    }

    @Test func encodesStop() throws {
        let json = try decode(ClientMessage.stop())
        #expect(json["type"] as? String == "stop")
    }

    @Test func encodesGetState() throws {
        let json = try decode(ClientMessage.getState())
        #expect(json["type"] as? String == "get_state")
    }

    @Test func encodesPermissionResponse() throws {
        let msg = ClientMessage.permissionResponse(id: "perm1", action: .allow)
        let json = try decode(msg)
        #expect(json["type"] as? String == "permission_response")
        #expect(json["id"] as? String == "perm1")
        #expect(json["action"] as? String == "allow")
    }

    @Test func encodesPermissionResponseWithScopeAndExpiry() throws {
        let msg = ClientMessage.permissionResponse(
            id: "perm2",
            action: .allow,
            scope: .workspace,
            expiresInMs: 3_600_000
        )
        let json = try decode(msg)
        #expect(json["scope"] as? String == "workspace")
        #expect(json["expiresInMs"] as? Int == 3_600_000)
    }

    @Test func encodesExtensionUIResponse() throws {
        let msg = ClientMessage.extensionUIResponse(id: "ext1", value: "option_a")
        let json = try decode(msg)
        #expect(json["type"] as? String == "extension_ui_response")
        #expect(json["id"] as? String == "ext1")
        #expect(json["value"] as? String == "option_a")
    }

    @Test func encodesFollowUp() throws {
        let msg = ClientMessage.followUp(message: "also do this")
        let json = try decode(msg)
        #expect(json["type"] as? String == "follow_up")
        #expect(json["message"] as? String == "also do this")
    }

    @Test func encodesSteer() throws {
        let msg = ClientMessage.steer(message: "change direction")
        let json = try decode(msg)
        #expect(json["type"] as? String == "steer")
        #expect(json["message"] as? String == "change direction")
    }

    @Test func encodesPromptWithImages() throws {
        let img = ImageAttachment(data: "base64data", mimeType: "image/jpeg")
        let msg = ClientMessage.prompt(message: "describe this", images: [img])
        let json = try decode(msg)
        #expect(json["type"] as? String == "prompt")
        #expect(json["message"] as? String == "describe this")
        let images = json["images"] as? [[String: Any]]
        #expect(images?.count == 1)
        #expect(images?[0]["data"] as? String == "base64data")
        #expect(images?[0]["mimeType"] as? String == "image/jpeg")
    }

    @Test func encodesPromptWithStreamingBehavior() throws {
        let msg = ClientMessage.prompt(message: "hi", streamingBehavior: .steer)
        let json = try decode(msg)
        #expect(json["streamingBehavior"] as? String == "steer")
    }

    @Test func encodesExtensionUIResponseConfirmed() throws {
        let msg = ClientMessage.extensionUIResponse(id: "ext2", confirmed: true)
        let json = try decode(msg)
        #expect(json["type"] as? String == "extension_ui_response")
        #expect(json["id"] as? String == "ext2")
        #expect(json["confirmed"] as? Bool == true)
        #expect(json["value"] == nil)
    }

    @Test func encodesExtensionUIResponseCancelled() throws {
        let msg = ClientMessage.extensionUIResponse(id: "ext3", cancelled: true)
        let json = try decode(msg)
        #expect(json["cancelled"] as? Bool == true)
    }

    @Test func jsonStringProducesValidUTF8() throws {
        let msg = ClientMessage.prompt(message: "hello")
        let str = try msg.jsonString()
        #expect(str.contains("\"type\":\"prompt\""))
        #expect(str.contains("\"message\":\"hello\""))
    }

    @Test func permissionResponseDeny() throws {
        let msg = ClientMessage.permissionResponse(id: "p1", action: .deny)
        let json = try decode(msg)
        #expect(json["action"] as? String == "deny")
    }

    // MARK: - New RPC Commands

    @Test func encodesSetModel() throws {
        let msg = ClientMessage.setModel(provider: "anthropic", modelId: "claude-sonnet-4")
        let json = try decode(msg)
        #expect(json["type"] as? String == "set_model")
        #expect(json["provider"] as? String == "anthropic")
        #expect(json["modelId"] as? String == "claude-sonnet-4")
    }

    @Test func encodesCycleModel() throws {
        let json = try decode(ClientMessage.cycleModel())
        #expect(json["type"] as? String == "cycle_model")
    }

    @Test func encodesSetThinkingLevel() throws {
        let msg = ClientMessage.setThinkingLevel(level: .high)
        let json = try decode(msg)
        #expect(json["type"] as? String == "set_thinking_level")
        #expect(json["level"] as? String == "high")
    }

    @Test func encodesNewSession() throws {
        let json = try decode(ClientMessage.newSession())
        #expect(json["type"] as? String == "new_session")
    }

    @Test func encodesCompact() throws {
        let msg = ClientMessage.compact(customInstructions: "focus on code")
        let json = try decode(msg)
        #expect(json["type"] as? String == "compact")
        #expect(json["customInstructions"] as? String == "focus on code")
    }

    @Test func encodesBash() throws {
        let msg = ClientMessage.bash(command: "ls -la")
        let json = try decode(msg)
        #expect(json["type"] as? String == "bash")
        #expect(json["command"] as? String == "ls -la")
    }

    @Test func encodesRequestId() throws {
        let msg = ClientMessage.getMessages(requestId: "req-42")
        let json = try decode(msg)
        #expect(json["type"] as? String == "get_messages")
        #expect(json["requestId"] as? String == "req-42")
    }

    @Test func encodesClientTurnId() throws {
        let msg = ClientMessage.prompt(message: "hello", requestId: "req-1", clientTurnId: "turn-1")
        let json = try decode(msg)
        #expect(json["type"] as? String == "prompt")
        #expect(json["clientTurnId"] as? String == "turn-1")
    }

    @Test func encodesSetSessionName() throws {
        let msg = ClientMessage.setSessionName(name: "my-feature")
        let json = try decode(msg)
        #expect(json["type"] as? String == "set_session_name")
        #expect(json["name"] as? String == "my-feature")
    }

    @Test func encodesSetSteeringMode() throws {
        let msg = ClientMessage.setSteeringMode(mode: .oneAtATime)
        let json = try decode(msg)
        #expect(json["type"] as? String == "set_steering_mode")
        #expect(json["mode"] as? String == "one-at-a-time")
    }

    // MARK: - Helpers

    private enum DecodeError: Error {
        case topLevelNotDictionary
    }

    private func decode(_ msg: ClientMessage) throws -> [String: Any] {
        let data = try msg.jsonData()
        let object = try JSONSerialization.jsonObject(with: data)

        guard let dictionary = object as? [String: Any] else {
            throw DecodeError.topLevelNotDictionary
        }

        return dictionary
    }
}
