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

    // MARK: - Helpers

    private func decode(_ msg: ClientMessage) throws -> [String: Any] {
        let data = try msg.jsonData()
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
}
