import Testing
import UIKit
@testable import Oppi

// TEMPORARY: delete with `ReviewCommentsTextFallback` in the next release.
/// A server without `capabilities.promptContext` drops context items, so the chat sends its
/// staged comments folded into the message text; a server with it gets them as items.
@Suite("Review comments text fallback")
@MainActor
struct ReviewCommentsTextFallbackTests {
    private static let comment = PromptContextItem(
        source: .file,
        path: "Sources/App.swift",
        startLine: 12,
        endLine: 14,
        quote: "let total = items.count",
        note: "Rename total; it shadows the property."
    )

    @Test func aServerWithoutPromptContextGetsTheCommentsInTheText() async throws {
        let rig = try await CommentSendRig.open(promptContext: false)
        defer { rig.close() }

        let (message, context) = try await rig.send("Please fix this.")

        #expect(context == nil, "No context items go to a server that drops them")
        #expect(message == """
        Please fix this.

        ## Review comments

        Please address these review comments.

        ### Comment 1

        **Where:** `Sources/App.swift`:12-14 (file)

        **Selected text:**

        ```swift
        let total = items.count
        ```

        **Comment:**

        > Rename total; it shadows the property.
        """)
        #expect(await rig.acknowledgeClearsComments(), "Sent comments stay staged after the send")
    }

    @Test func aServerWithPromptContextGetsTheCommentsAsItems() async throws {
        let rig = try await CommentSendRig.open(promptContext: true)
        defer { rig.close() }

        let (message, context) = try await rig.send("Please fix this.")

        #expect(message == "Please fix this.")
        #expect(context?.count == 1)
        #expect(context?.first?.note == Self.comment.note)
        #expect(await rig.acknowledgeClearsComments(), "Sent comments stay staged after the send")
    }

    /// A chat on a scripted, connected stream with one staged comment, recording each prompt.
    @MainActor
    private final class CommentSendRig {
        let connection: ServerConnection
        let chat: ChatViewController
        private let frames = ScriptedFrameStreamFactory()
        private let window: UIWindow
        private let sessionId: String
        private var prompts: [ClientMessage] = []

        static func open(promptContext: Bool) async throws -> CommentSendRig {
            let sessionId = "session-\(UUID().uuidString)"
            let (connection, _) = await makeTestConnection(sessionId: sessionId)
            let rig = CommentSendRig(connection: connection, sessionId: sessionId, promptContext: promptContext)
            try await rig.connect()
            return rig
        }

        private init(connection: ServerConnection, sessionId: String, promptContext: Bool) {
            self.connection = connection
            self.sessionId = sessionId
            connection.setSplitStreamCapabilitiesForTesting(sessionStream: true, promptContext: promptContext)
            connection.sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1", status: .ready))
            let frames = frames
            connection._connectStreamForTesting = { [weak connection] in
                connection?.wsClient?._setStatusForTesting(.connected)
                return frames.makeStream()
            }
            let navigation = SceneNavigation()
            navigation.open(.chat(WorkspaceSessionNavTarget(serverId: connection.currentServerId ?? "server-1", sessionId: sessionId)))
            chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: navigation)
            chat.sessionManager._loadHistoryForTesting = { _, _ in nil }
            chat.sessionManager._focusedStreamLivenessForTesting = { .connected }
            window = makeSceneWindow()
            window.traitOverrides.appRootEnvironment = makeTestAppRoot()
            window.rootViewController = chat
            window.makeKeyAndVisible()
            chat.view.layoutIfNeeded()
            connection._sendMessageForTesting = { [weak self] message in
                if case .prompt = message { self?.prompts.append(message) }
            }
        }

        private func connect() async throws {
            try #require(await waitForMainActorCondition(timeout: .seconds(3)) {
                if case .awaitingConnected = self.chat.sessionManager.entryState { return self.frames.streamsCreated > 0 }
                return false
            }, "The chat never began waiting for `connected`")
            deliver(.connected(session: makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)))
            try #require(await waitForMainActorCondition(timeout: .seconds(3)) {
                self.chat.sessionManager.entryState == .streaming
            }, "The chat never connected")
        }

        /// Stages the comment, types `text`, presses Send, and returns the prompt that left.
        func send(_ text: String) async throws -> (String, [PromptContextItem]?) {
            let restageError = chat.reviewComments.restage(
                [ReviewCommentsTextFallbackTests.comment],
                localScopeId: chat.reviewCommentLocalScopeId,
                sessionId: sessionId
            )
            try #require(restageError == nil)
            try #require(chat.reviewComments.stagedCount == 1)
            chat.composerSetText(text)
            chat.sendPrompt()
            try #require(await waitForMainActorCondition(timeout: .seconds(3)) { !self.prompts.isEmpty }, "Nothing was sent")
            guard case .prompt(let message, _, let context, _, _, _) = prompts[0] else {
                throw CancellationError()
            }
            return (message, context)
        }

        /// Acknowledges the sent prompt and reports whether its comments left the stage.
        func acknowledgeClearsComments() async -> Bool {
            guard case .prompt(_, _, _, _, let requestId?, let clientTurnId?) = prompts.first else { return false }
            deliver(.turnAck(command: "prompt", clientTurnId: clientTurnId, stage: .dispatched, requestId: requestId, duplicate: false))
            deliver(.commandResult(command: "prompt", requestId: requestId, success: true, data: nil, error: nil))
            return await waitForMainActorCondition(timeout: .seconds(3)) { self.chat.reviewComments.stagedCount == 0 }
        }

        func close() {
            window.rootViewController = UIViewController()
            window.isHidden = true
            chat.sessionManager.cleanup()
            for index in 0..<frames.streamsCreated { frames.finish(index: index) }
            connection.disconnectStream()
        }

        private func deliver(_ message: ServerMessage) {
            frames.yield(
                index: max(0, frames.streamsCreated - 1),
                event: StreamFrameEvent(sessionId: sessionId, message: message, meta: nil)
            )
        }
    }
}
