import Testing
import Foundation
@testable import PiRemote

@Suite("ClientMessage encoding")
struct ClientMessageTests {

    @Test func encodesPrompt() throws {
        let msg = ClientMessage.prompt(message: "hello world")
        let json = try decode(msg)
        #expect(json["type"] as? String == "prompt")
        #expect(json["message"] as? String == "hello world")
    }

    @Test func encodesStop() throws {
        let json = try decode(ClientMessage.stop)
        #expect(json["type"] as? String == "stop")
    }

    @Test func encodesGetState() throws {
        let json = try decode(ClientMessage.getState)
        #expect(json["type"] as? String == "get_state")
    }

    @Test func encodesPermissionResponse() throws {
        let msg = ClientMessage.permissionResponse(id: "perm1", action: .allow)
        let json = try decode(msg)
        #expect(json["type"] as? String == "permission_response")
        #expect(json["id"] as? String == "perm1")
        #expect(json["action"] as? String == "allow")
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

    // MARK: - Helpers

    private func decode(_ msg: ClientMessage) throws -> [String: Any] {
        let data = try msg.jsonData()
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
