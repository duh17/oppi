import Foundation
import Testing
@testable import Oppi

@Suite("Session list prompt swipe")
struct SessionListPromptSwipePolicyTests {
    @Test(arguments: [SessionStatus.starting, .ready, .busy, .stopping, .error])
    func liveWorkspaceSessionShowsLeadingPrompt(status: SessionStatus) {
        #expect(
            SessionListPromptSwipePolicy.leadingAction(
                status: status,
                workspaceId: "ws-1"
            ) == .prompt
        )
    }

    @Test func stoppedWorkspaceSessionDoesNotShowLeadingPrompt() {
        #expect(
            SessionListPromptSwipePolicy.leadingAction(
                status: .stopped,
                workspaceId: "ws-1"
            ) == .none
        )
    }

    @Test(arguments: [SessionStatus.ready, .busy, .stopped])
    func sessionWithoutWorkspaceShowsNoLeadingPrompt(status: SessionStatus) {
        #expect(
            SessionListPromptSwipePolicy.leadingAction(
                status: status,
                workspaceId: nil
            ) == .none
        )
        #expect(
            SessionListPromptSwipePolicy.leadingAction(
                status: status,
                workspaceId: ""
            ) == .none
        )
        #expect(
            SessionListPromptSwipePolicy.leadingAction(
                status: status,
                workspaceId: "   "
            ) == .none
        )
    }

    @Test func sendPayloadIsSlashCommandWithSteerStreamingBehavior() throws {
        let message = SessionListPromptSwipePolicy.sendMessage(commandName: "grill-me")
        let json = try decode(message)

        #expect(json["type"] as? String == "prompt")
        #expect(json["message"] as? String == "/grill-me")
        #expect(json["streamingBehavior"] as? String == "steer")
        #expect(json["attachments"] == nil)
    }

    @Test func cancelledTemplateLoadDoesNotPresentErrorAlert() {
        #expect(!SessionListPromptTemplateLoadErrorPolicy.shouldPresent(CancellationError()))
        #expect(!SessionListPromptTemplateLoadErrorPolicy.shouldPresent(URLError(.cancelled)))
        #expect(!SessionListPromptTemplateLoadErrorPolicy.shouldPresent(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
    }

    @Test func realTemplateLoadFailuresPresentErrorAlert() {
        #expect(SessionListPromptTemplateLoadErrorPolicy.shouldPresent(URLError(.notConnectedToInternet)))
        #expect(SessionListPromptTemplateLoadErrorPolicy.shouldPresent(URLError(.timedOut)))
        #expect(SessionListPromptTemplateLoadErrorPolicy.shouldPresent(
            APIError.server(status: 500, message: "boom")
        ))
    }

    @Test func sendPayloadDoesNotBranchOnSessionStatus() throws {
        let idle = try decode(SessionListPromptSwipePolicy.sendMessage(commandName: "review"))
        let busy = try decode(SessionListPromptSwipePolicy.sendMessage(commandName: "review"))

        #expect(idle["type"] as? String == "prompt")
        #expect(busy["type"] as? String == idle["type"] as? String)
        #expect(idle["message"] as? String == "/review")
        #expect(busy["message"] as? String == idle["message"] as? String)
        #expect(idle["streamingBehavior"] as? String == "steer")
        #expect(busy["streamingBehavior"] as? String == idle["streamingBehavior"] as? String)
    }

    private enum DecodeError: Error {
        case topLevelNotDictionary
    }

    private func decode(_ message: ClientMessage) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: message.jsonData())
        guard let dictionary = object as? [String: Any] else {
            throw DecodeError.topLevelNotDictionary
        }
        return dictionary
    }
}
