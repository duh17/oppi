import Testing
import Foundation
@testable import Oppi

@Suite("WebSocketClient Reconnect Backoff")
@MainActor
struct WebSocketClientReconnectBackoffTests {

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

    @Test func cancelReconnectBackoffDoesNothingWhenNotReconnecting() {
        let client = WebSocketClient(credentials: makeTestCredentials())
        client._setStatusForTesting(.connected)

        client.cancelReconnectBackoff()

        #expect(client.status == .connected)
    }

    @Test func pingDeadlineReturnsTimeoutWhenCallbackNeverArrives() async {
        let result = await WebSocketPingDeadline.wait(timeout: .milliseconds(20)) { _ in }
        #expect(result == .timedOut)
    }

    @Test func pingDeadlineReturnsCallbackFailureBeforeTimeout() async {
        let result = await WebSocketPingDeadline.wait(timeout: .seconds(1)) { callback in
            callback(URLError(.networkConnectionLost))
        }
        #expect(result == .failed)
    }

    @Test func pingDeadlineReturnsSuccessBeforeTimeout() async {
        let result = await WebSocketPingDeadline.wait(timeout: .seconds(1)) { callback in
            callback(nil)
        }
        #expect(result == .succeeded)
    }

    @Test func reconnectThresholdReportsPersistentTransportHealthAtBoundedAttempts() {
        #expect(!WebSocketRecoveryPolicy.shouldReportUnhealthyReconnect(attempt: 3))
        #expect(WebSocketRecoveryPolicy.shouldReportUnhealthyReconnect(attempt: 4))
        #expect(!WebSocketRecoveryPolicy.shouldReportUnhealthyReconnect(attempt: 5))
        #expect(WebSocketRecoveryPolicy.shouldReportUnhealthyReconnect(attempt: 6))
        #expect(WebSocketRecoveryPolicy.shouldReportUnhealthyReconnect(attempt: 7))
        #expect(WebSocketRecoveryPolicy.shouldReportUnhealthyReconnect(attempt: 100))
    }
}
