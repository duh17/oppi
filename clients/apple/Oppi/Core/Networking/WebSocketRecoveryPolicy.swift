import Foundation

/// Shared retry and close-classification rules for persistent WebSocket transports.
///
/// The focused session stream and global app-event stream have different payload
/// semantics, but should answer transport recovery questions the same way: when
/// to retry, how long to wait, and which handshake failures are terminal.
enum WebSocketRecoveryPolicy {
    static let maxReconnectAttempts = 10
    static let pingInterval: Duration = .seconds(30)
    static let maxConsecutivePingFailures = 2

    /// Reconnect delay curve tuned for mobile networking:
    ///
    /// - Attempts 1-3: 500ms (transient — suspension wake, network handoff)
    /// - Attempts 4-6: 2s, 4s, 8s (moderate — server restart, Tailscale reconnect)
    /// - Attempts 7+:  15s cap (real problems — server down)
    ///
    /// ±25% jitter prevents synchronized retries if multiple connections exist.
    nonisolated static func reconnectDelay(attempt: Int) -> TimeInterval {
        let base: Double
        switch attempt {
        case 1...3: base = 0.5
        case 4:     base = 2
        case 5:     base = 4
        case 6:     base = 8
        default:    base = 15
        }
        let jitterFactor = Double.random(in: 0.75...1.25)
        return base * jitterFactor
    }

    nonisolated static func isNonRetryableHandshakeStatus(_ statusCode: Int) -> Bool {
        [400, 401, 403, 404, 410, 426].contains(statusCode)
    }

    nonisolated static func isRecoverableReceiveError(
        _ error: Error,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) -> Bool {
        let rawCloseCode = closeCode.rawValue
        if rawCloseCode == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue ||
            rawCloseCode == URLSessionWebSocketTask.CloseCode.goingAway.rawValue {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            // Socket closed/not connected during app/network handoff. Reconnect is the signal;
            // per-close errors are expected noise unless retries exhaust.
            return [53, 57, 89].contains(nsError.code)
        }
        if nsError.domain == NSURLErrorDomain {
            return [
                NSURLErrorCancelled,
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
            ].contains(nsError.code)
        }
        return false
    }
}

/// Thread-safe one-shot resolver for callback APIs that may race timeout/cancel paths.
///
/// SAFETY (`@unchecked Sendable`):
/// - `continuation` is protected by `lock` and consumed exactly once.
/// - Resume is always executed after lock release.
/// - Double-resume is prevented by nil-ing `continuation` under lock.
final class OneShotBoolContinuation: @unchecked Sendable {
    private var continuation: UnsafeContinuation<Bool, Never>?
    private let lock = NSLock()

    init(_ continuation: UnsafeContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Bool) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }
}
