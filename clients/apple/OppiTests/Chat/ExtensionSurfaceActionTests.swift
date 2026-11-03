import Foundation
import Testing
@testable import Oppi

/// A tap on a card's action asks the host to send it: the frame carries the revision the client
/// holds and a fresh request id, the declared pending state shows until the server settles that
/// request, and a send that never leaves clears the wait instead of leaving a card waiting.
@Suite("Composable surface actions")
@MainActor
struct ExtensionSurfaceActionTests {
    /// The frames one connection sent, in order.
    private final class SentFrames {
        var messages: [ClientMessage] = []
    }

    private func surface(_ name: String) throws -> ExtensionUISurface {
        try JSONDecoder().decode(ExtensionUISurface.self, from: ProtocolFixtures.data("surfaces/\(name)"))
    }

    private func intent(
        surfaceId: String,
        compositeId: String,
        actionId: String,
        rowId: String? = nil,
        revision: Int
    ) -> ExtensionSurfaceActionIntent {
        ExtensionSurfaceActionIntent(
            surfaceId: surfaceId,
            compositeId: compositeId,
            actionId: actionId,
            rowId: rowId,
            revision: revision
        )
    }

    private func connect(_ sessionId: String, surface name: String) throws -> (ServerConnection, SentFrames) {
        let connection = ServerConnection()
        connection.extensionSurfaces.apply(try surface(name), sessionId: sessionId)
        let frames = SentFrames()
        connection._sendMessageForTesting = { frames.messages.append($0) }
        return (connection, frames)
    }

    private func waitFor(_ count: Int, in frames: SentFrames) async -> [ClientMessage] {
        for _ in 0 ..< 100 {
            if frames.messages.count >= count { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return frames.messages
    }

    @Test func aTapSendsTheActionWithARequestIdAndShowsItsPendingUntilSettled() async throws {
        let sessionId = "s1"
        let (connection, frames) = try connect(sessionId, surface: "status-card.json")

        connection.sendExtensionSurfaceAction(
            intent(surfaceId: "deploy", compositeId: "status", actionId: "retry", revision: 7),
            sessionId: sessionId
        )
        let message = try testUnwrap(await waitFor(1, in: frames).first)

        guard case .extensionUIAction(
            let surfaceId,
            let compositeId,
            let actionId,
            let rowId,
            let revision,
            let values,
            let requestId
        ) = message else {
            Issue.record("Expected an action frame, got \(message.typeLabel)")
            return
        }
        #expect(surfaceId == "deploy")
        #expect(compositeId == "status")
        #expect(actionId == "retry")
        #expect(rowId == nil)
        #expect(revision == 7)
        #expect(values == nil)
        let mintedRequestId = try testUnwrap(requestId)

        // The pressed action shows its declared words and disables the ids it names.
        let pending = try testUnwrap(connection.extensionSurfaces.surface(for: sessionId).pendingAction)
        #expect(pending.requestId == mintedRequestId)
        #expect(pending.actionId == "retry")
        #expect(pending.title == "Retrying…")
        #expect(pending.disabledActionIds == ["retry"])
        #expect(pending.revision == 7)

        // The server's settled frame for that request ends the wait.
        connection.extensionSurfaces.settle(requestId: mintedRequestId, sessionId: sessionId)
        #expect(connection.extensionSurfaces.surface(for: sessionId).pendingAction == nil)
    }

    @Test func everyTapMintsItsOwnRequestIdAndNamesItsRow() async throws {
        let sessionId = "s1"
        let (connection, frames) = try connect(sessionId, surface: "data-table.json")

        for rowId in ["table:sessions", "table:events"] {
            connection.sendExtensionSurfaceAction(
                intent(surfaceId: "query", compositeId: "rows", actionId: "copy", rowId: rowId, revision: 2),
                sessionId: sessionId
            )
        }

        let actions = await waitFor(2, in: frames).compactMap { message -> (rowId: String?, requestId: String?)? in
            guard case .extensionUIAction(_, _, _, let rowId, _, _, let requestId) = message else {
                return nil
            }
            return (rowId, requestId)
        }
        #expect(actions.map(\.rowId) == ["table:sessions", "table:events"])
        let requestIds = actions.compactMap(\.requestId)
        #expect(requestIds.count == 2)
        #expect(Set(requestIds).count == 2)
    }

    @Test func aSendThatNeverLeavesClearsTheWait() async throws {
        let sessionId = "s1"
        let (connection, _) = try connect(sessionId, surface: "status-card.json")
        connection._sendMessageForTesting = { _ in throw WebSocketError.notConnected }

        connection.sendExtensionSurfaceAction(
            intent(surfaceId: "deploy", compositeId: "status", actionId: "retry", revision: 7),
            sessionId: sessionId
        )
        // Nothing will settle a frame that never left, so the action ends its own wait.
        for _ in 0 ..< 100 where connection.extensionSurfaces.surface(for: sessionId).pendingAction != nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(connection.extensionSurfaces.surface(for: sessionId).pendingAction == nil)
    }
}
