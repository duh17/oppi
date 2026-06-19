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

    @Test func encodesGetQueue() throws {
        let json = try decode(ClientMessage.getQueue(requestId: "req-q1"))
        #expect(json["type"] as? String == "get_queue")
        #expect(json["requestId"] as? String == "req-q1")
    }

    @Test func encodesSetQueue() throws {
        let msg = ClientMessage.setQueue(
            baseVersion: 3,
            steering: [
                MessageQueueDraftItem(
                    id: "q1",
                    message: "steer this",
                    attachments: nil,
                    createdAt: 123
                ),
            ],
            followUp: [],
            requestId: "req-q2"
        )

        let json = try decode(msg)
        #expect(json["type"] as? String == "set_queue")
        #expect(json["baseVersion"] as? Int == 3)
        #expect(json["requestId"] as? String == "req-q2")
        let steering = json["steering"] as? [[String: Any]]
        #expect(steering?.count == 1)
        #expect(steering?.first?["id"] as? String == "q1")
        #expect(steering?.first?["message"] as? String == "steer this")
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

    @Test func encodesPromptWithAttachments() throws {
        let ref = ChatAttachmentRef(
            type: "attachment",
            id: "upl_123",
            source: .upload,
            name: "screenshot.png",
            mimeType: "image/png",
            sizeBytes: 1234,
            sha256: "abc",
            kind: .image,
            workspacePath: nil
        )
        let msg = ClientMessage.prompt(message: "describe this", attachments: [ref])
        let json = try decode(msg)
        #expect(json["type"] as? String == "prompt")
        #expect(json["message"] as? String == "describe this")
        let attachments = json["attachments"] as? [[String: Any]]
        #expect(attachments?.count == 1)
        #expect(attachments?[0]["id"] as? String == "upl_123")
        #expect(attachments?[0]["source"] as? String == "upload")
        #expect(attachments?[0]["name"] as? String == "screenshot.png")
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

    @Test func encodesReload() throws {
        let json = try decode(ClientMessage.reload(requestId: "req-reload"))
        #expect(json["type"] as? String == "reload")
        #expect(json["requestId"] as? String == "req-reload")
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

    @Test func encodesGetSessionTree() throws {
        let msg = ClientMessage.getSessionTree(requestId: "req-tree")
        let json = try decode(msg)
        #expect(json["type"] as? String == "get_session_tree")
        #expect(json["requestId"] as? String == "req-tree")
        #expect(json["filterMode"] == nil)
    }

    @Test func encodesGetSessionTreeWithFilterMode() throws {
        let msg = ClientMessage.getSessionTree(filterMode: .noTools, requestId: "req-tree")
        let json = try decode(msg)
        #expect(json["type"] as? String == "get_session_tree")
        #expect(json["filterMode"] as? String == "no-tools")
        #expect(json["requestId"] as? String == "req-tree")
    }

    @Test func encodesNavigateTreeWithOptions() throws {
        let msg = ClientMessage.navigateTree(
            targetId: "entry-12",
            summarize: true,
            customInstructions: "Focus on TODOs",
            replaceInstructions: false,
            label: "Branch summary",
            requestId: "req-nav"
        )

        let json = try decode(msg)
        #expect(json["type"] as? String == "navigate_tree")
        #expect(json["targetId"] as? String == "entry-12")
        #expect(json["summarize"] as? Bool == true)
        #expect(json["customInstructions"] as? String == "Focus on TODOs")
        #expect(json["replaceInstructions"] as? Bool == false)
        #expect(json["label"] as? String == "Branch summary")
        #expect(json["requestId"] as? String == "req-nav")
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

    @Test func encodesShareSessionWithRedactionPolicy() throws {
        let policy = ShareSessionRedactionPolicy(
            secrets: false,
            emails: true,
            phones: false,
            userPaths: true,
            ipAddresses: true,
            jwtAndBearer: true,
            namesHeuristic: true,
            skills: true
        )

        let json = try decode(
            ClientMessage.shareSession(action: .publish, redactionPolicy: policy, requestId: "req-share")
        )

        #expect(json["type"] as? String == "share_session")
        #expect(json["action"] as? String == "publish")
        #expect(json["requestId"] as? String == "req-share")

        let payload = json["redactionPolicy"] as? [String: Any]
        #expect(payload?["secrets"] as? Bool == true)
        #expect(payload?["emails"] as? Bool == true)
        #expect(payload?["phones"] as? Bool == false)
        #expect(payload?["namesHeuristic"] as? Bool == true)
        #expect(payload?["skills"] as? Bool == true)
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
