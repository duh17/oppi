import Testing
import Foundation
@testable import Oppi

@Suite("WebSocketClient Reconnect Backoff")
struct WebSocketClientReconnectBackoffTests {

    @MainActor
    @Test func cancelReconnectBackoffResolvesWaitingSends() async {
        let client = WebSocketClient(
            credentials: makeTestCredentials(),
            waitForConnectionTimeout: .seconds(5),
            sendTimeout: .seconds(1)
        )
        client._setStatusForTesting(.reconnecting(attempt: 3))

        let startedAt = ContinuousClock.now

        let sendTask = Task {
            do {
                try await client.send(.getState())
                return false
            } catch let error as WebSocketError {
                if case .notConnected = error {
                    return true
                }
                return false
            } catch {
                return false
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        client.cancelReconnectBackoff()

        let gotNotConnected = await sendTask.value
        let elapsed = ContinuousClock.now - startedAt

        #expect(gotNotConnected, "Waiting send should be released with notConnected")
        #expect(client.status == .disconnected)
        #expect(elapsed < .seconds(1), "Send should unblock quickly after cancelReconnectBackoff")
    }

    @MainActor
    @Test func cancelReconnectBackoffDoesNothingWhenNotReconnecting() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._setStatusForTesting(.connected)

        client.cancelReconnectBackoff()

        #expect(client.status == .connected)
    }
}
