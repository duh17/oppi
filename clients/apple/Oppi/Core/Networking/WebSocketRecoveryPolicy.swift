import Foundation

/// Shared retry and close-classification rules for persistent WebSocket transports.
///
/// The focused session stream and global app-event stream have different payload
/// semantics, but should answer transport recovery questions the same way: when
/// to retry, how long to wait, and which handshake failures are terminal.
enum PersistentStreamHealthFailure: Equatable, Sendable {
    case tunnelOpenFailure
    case establishedStreamFailure
    case pingTimeout
    case pingFailures(count: Int)
    case reconnectThreshold(attempt: Int)
}

enum WebSocketPingResult: Equatable, Sendable {
    case succeeded
    case failed
    case timedOut
}

enum WebSocketRecoveryPolicy {
    static let pingInterval: Duration = .seconds(30)
    static let pingTimeout: Duration = .seconds(8)
    static let maxConsecutivePingFailures = 2

    /// Escalate repeated socket retries into transport selection without probing
    /// on every transient reconnect. Attempts 4 and 6 provide early bounded
    /// recovery, then the existing 15-second reconnect cap governs later probes.
    nonisolated static func shouldReportUnhealthyReconnect(attempt: Int) -> Bool {
        attempt == 4 || attempt >= 6
    }

    /// Persistent stream subscriptions retry until their owner disconnects them.
    /// Saturating arithmetic avoids a theoretical overflow after years of outage.
    nonisolated static func nextReconnectAttempt(after attempt: Int) -> Int {
        attempt == Int.max ? Int.max : attempt + 1
    }

    /// Reconnect delay curve tuned for mobile networking:
    ///
    /// - Attempts 1-3: 500ms (transient — suspension wake, network handoff)
    /// - Attempts 4-6: 2s, 4s, 8s (moderate — server restart, Tailscale reconnect)
    /// - Attempts 7+:  15s cap while the owning subscription remains intended
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

    /// Close codes that report a terminal payload, policy, or WebSocket protocol rejection.
    /// Transport closures such as abnormalClosure, goingAway, and internalServerError remain
    /// recoverable because a later connection can succeed without changing the request.
    nonisolated static func isNonRetryableCloseCode(
        _ closeCode: URLSessionWebSocketTask.CloseCode
    ) -> Bool {
        switch closeCode {
        case .protocolError,
             .unsupportedData,
             .invalidFramePayloadData,
             .policyViolation,
             .messageTooBig:
            return true
        default:
            return false
        }
    }

    /// Retry telemetry must remain low-cardinality even though the internal counter is unbounded.
    nonisolated static func reconnectAttemptTag(_ attempt: Int) -> String {
        attempt >= 7 ? "7_plus" : String(max(0, attempt))
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

/// Adds a deadline to URLSession's callback-based WebSocket ping API. A zombie
/// socket can otherwise withhold the callback forever and wedge its watchdog.
enum WebSocketPingDeadline {
    @MainActor
    static func wait(
        timeout: Duration,
        sendPing: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async -> WebSocketPingResult {
        await withCheckedContinuation { continuation in
            let resolver = WebSocketPingResolver(continuation)
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                resolver.resolve(.timedOut)
            }
            resolver.setTimeoutTask(timeoutTask)
            sendPing { error in
                resolver.resolve(error == nil ? .succeeded : .failed)
            }
        }
    }
}

private final class WebSocketPingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WebSocketPingResult, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<WebSocketPingResult, Never>) {
        self.continuation = continuation
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if continuation == nil {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    func resolve(_ result: WebSocketPingResult) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation.resume(returning: result)
    }
}
