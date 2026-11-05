import Testing
import UIKit
@testable import Oppi

/// The slash list comes from one `get_commands` the chat asks for when the stream
/// connects. A list that went missing after that answer, or an answer that failed,
/// left the composer on its built-in `/compact` until the stream next reconnected.
@Suite("Chat slash command recovery")
@MainActor
struct ChatSlashCommandRecoveryTests {
    @Test func aChatCoveredByAReaderKeepsItsSlashCommandsWhenItReturns() async throws {
        let rig = try await SlashChatRig.open()
        defer { rig.close() }
        let requestId = try await rig.connectAndAwaitRequest()
        rig.answer(requestId, commands: ["skill:lint"])
        try #require(await rig.waitForCommands(["skill:lint"]))

        let reader = ChatReaderNavTarget(id: UUID())
        rig.appNavigation.openChatReader(reader)
        rig.stack.pushViewController(UIViewController(), animated: false)
        rig.stack.view.layoutIfNeeded()
        #expect(rig.chat.viewIfLoaded?.window == nil, "The chat must leave the window for this proof")

        rig.stack.popViewController(animated: false)
        rig.stack.view.layoutIfNeeded()

        #expect(
            await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
                rig.connection.chatState.slashCommands.map(\.name) == ["skill:lint"]
            },
            "Coming back to a chat whose stream never dropped emptied its slash list"
        )
    }

    @Test func typingSlashAsksAgainAfterTheCommandListFailed() async throws {
        let rig = try await SlashChatRig.open()
        defer { rig.close() }
        let first = try await rig.connectAndAwaitRequest()
        rig.fail(first)
        try #require(await waitForMainActorCondition { rig.connection.chatState.slashCommandsRequestId == nil })
        #expect(rig.connection.chatState.slashCommands.isEmpty)

        rig.chat.composerSetText("/")

        let second = try #require(
            await rig.waitForRequest(count: 2),
            "A failed command list was never asked for again"
        )
        rig.answer(second, commands: ["skill:lint"])
        #expect(await rig.waitForCommands(["skill:lint"]))
        #expect(rig.chat.availableSlashCommands.map(\.name).contains("skill:lint"))
    }

    @Test func typingSlashAsksOncePerOpenedPanelAndNotWhileTheListIsLoaded() async throws {
        let rig = try await SlashChatRig.open()
        defer { rig.close() }
        let first = try await rig.connectAndAwaitRequest()
        rig.fail(first)
        try #require(await waitForMainActorCondition { rig.connection.chatState.slashCommandsRequestId == nil })

        rig.chat.composerSetText("/")
        rig.chat.composerSetText("/s")
        rig.chat.composerSetText("/sk")
        let second = try #require(await rig.waitForRequest(count: 2))
        #expect(
            await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) { rig.requestIds.count == 2 },
            "Each keystroke inside one slash token asked for the list again"
        )

        rig.answer(second, commands: ["skill:lint"])
        try #require(await rig.waitForCommands(["skill:lint"]))
        rig.chat.composerSetText("")
        rig.chat.composerSetText("/")
        #expect(
            await waitForMainActorConditionToStayTrue(for: .milliseconds(200)) { rig.requestIds.count == 2 },
            "A loaded command list was fetched again when the slash panel opened"
        )
    }
}

/// A chat on a scripted stream inside a navigation stack, with every `get_commands`
/// it sends recorded and answerable by hand.
@MainActor
private final class SlashChatRig {
    let connection: ServerConnection
    let appNavigation = AppNavigation()
    let chat: ChatViewController
    let stack: UINavigationController
    private let frames = ScriptedFrameStreamFactory()
    private let window: UIWindow
    private let sessionId: String
    private(set) var requestIds: [String] = []

    static func open() async throws -> SlashChatRig {
        let sessionId = "session-\(UUID().uuidString)"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        return SlashChatRig(connection: connection, sessionId: sessionId)
    }

    private init(connection: ServerConnection, sessionId: String) {
        self.connection = connection
        self.sessionId = sessionId
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, workspaceId: "w1", status: .ready))
        let frames = frames
        connection._connectStreamForTesting = { [weak connection] in
            connection?.wsClient?._setStatusForTesting(.connected)
            return frames.makeStream()
        }
        appNavigation.openWorkspaceSession(
            WorkspaceSessionNavTarget(serverId: connection.currentServerId ?? "server-1", sessionId: sessionId)
        )
        chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: appNavigation)
        chat.sessionManager._loadHistoryForTesting = { _, _ in nil }
        // The scripted stream has no URL-bound socket; report it live.
        chat.sessionManager._focusedStreamLivenessForTesting = { .connected }
        stack = UINavigationController(rootViewController: chat)
        window = makeSceneWindow()
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        window.rootViewController = stack
        window.makeKeyAndVisible()
        stack.view.setNeedsLayout()
        stack.view.layoutIfNeeded()
        connection._sendMessageForTesting = { [weak self] message in
            if case .getCommands(let requestId?) = message { self?.requestIds.append(requestId) }
        }
    }

    func close() {
        window.rootViewController = UIViewController()
        window.isHidden = true
        chat.sessionManager.cleanup()
        for index in 0..<frames.streamsCreated { frames.finish(index: index) }
        connection.disconnectStream()
    }

    /// Opens the stream, delivers `connected`, and returns the first command-list request.
    func connectAndAwaitRequest() async throws -> String {
        // The chat reads the newest stream: re-entry opens one before the connect loop's own.
        try #require(await waitForMainActorCondition(timeout: .seconds(3)) {
            if case .awaitingConnected = self.chat.sessionManager.entryState { return self.frames.streamsCreated > 0 }
            return false
        }, "The chat never began waiting for `connected`")
        deliver(.connected(session: makeTestSession(id: sessionId, workspaceId: "w1", status: .ready)))
        return try #require(await waitForRequest(count: 1), "The chat never asked for its commands")
    }

    func waitForRequest(count: Int) async -> String? {
        guard await waitForMainActorCondition(timeout: .seconds(3), { self.requestIds.count >= count }) else {
            return nil
        }
        return requestIds[count - 1]
    }

    func answer(_ requestId: String, commands: [String]) {
        let entries = commands.map { name -> JSONValue in
            ["name": .string(name), "description": "d", "source": "skill"]
        }
        deliver(.commandResult(
            command: "get_commands",
            requestId: requestId,
            success: true,
            data: ["commands": .array(entries)],
            error: nil
        ))
    }

    func fail(_ requestId: String) {
        deliver(.commandResult(
            command: "get_commands",
            requestId: requestId,
            success: false,
            data: nil,
            error: "Session not active"
        ))
    }

    private func deliver(_ message: ServerMessage) {
        frames.yield(
            index: max(0, frames.streamsCreated - 1),
            event: StreamFrameEvent(sessionId: sessionId, message: message, meta: nil)
        )
    }

    func waitForCommands(_ names: [String]) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(3)) {
            self.connection.chatState.slashCommands.map(\.name) == names
        }
    }
}
