import Foundation

/// Narrow transport seam shared by the app's three persistent WebSocket clients —
/// the focused session stream (`WebSocketClient`), the global app-event stream
/// (`AppEventStreamClient`), and the dictation stream (`DictationStreamClient`) —
/// for deterministic reconnect tests. Production still delegates every operation
/// to `URLSessionWebSocketTask`.
@MainActor
struct PersistentWebSocketTransport {
    typealias Message = URLSessionWebSocketTask.Message
    typealias CloseCode = URLSessionWebSocketTask.CloseCode

    let identity: ObjectIdentifier
    let resume: () -> Void
    let receive: () async throws -> Message
    /// Production hands the frame to the task before the first suspension, so
    /// frames from one actor reach the socket in call order. The imported async
    /// `task.send(_:)` hops off the actor first, and concurrent frames could race.
    let send: (Message) async throws -> Void
    let sendPing: (@escaping @Sendable (Error?) -> Void) -> Void
    let cancel: (CloseCode, Data?) -> Void
    let state: () -> URLSessionTask.State
    let response: () -> URLResponse?
    let closeCode: () -> CloseCode

    init(task: URLSessionWebSocketTask) {
        identity = ObjectIdentifier(task)
        resume = { task.resume() }
        receive = { try await task.receive() }
        send = { message in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.send(message) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        sendPing = { handler in task.sendPing(pongReceiveHandler: handler) }
        cancel = { code, reason in task.cancel(with: code, reason: reason) }
        state = { task.state }
        response = { task.response }
        closeCode = { task.closeCode }
    }

    init(
        identity: AnyObject,
        resume: @escaping () -> Void,
        receive: @escaping () async throws -> Message,
        send: @escaping (Message) async throws -> Void = { _ in },
        sendPing: @escaping (@escaping @Sendable (Error?) -> Void) -> Void = { _ in },
        cancel: @escaping (CloseCode, Data?) -> Void,
        state: @escaping () -> URLSessionTask.State = { .running },
        response: @escaping () -> URLResponse?,
        closeCode: @escaping () -> CloseCode
    ) {
        self.identity = ObjectIdentifier(identity)
        self.resume = resume
        self.receive = receive
        self.send = send
        self.sendPing = sendPing
        self.cancel = cancel
        self.state = state
        self.response = response
        self.closeCode = closeCode
    }
}

/// Shared 401/4001 recovery decision for a persistent socket's forced token
/// refresh, used by all three transports above. Each reuses a sibling's
/// already-minted token when one is newer than the socket's own, so a refresh
/// another socket on the same auth session just completed is not spent twice.
/// Otherwise it forces exactly one refresh; a second failure on the same
/// connection, an empty refresh, or a thrown error is terminal.
///
/// Ownership of the socket can change while either `await` below is in
/// flight — another path replaced it, or the connection was disconnected.
/// `stillOwnsSocket` is checked right after each await, before anything from
/// that step is used, matching how each caller checked it before this was
/// shared. A caller that only needs to check once, after the whole decision
/// resolves, leaves it at the default and reads the result itself.
@MainActor
enum PersistentStreamAuthRefresh {
    enum Outcome {
        /// Reconnect with this token. `forcedRefresh` is true only when it came
        /// from `refreshTokenProvider`, so the caller can mark its one-refresh
        /// budget spent.
        case token(String, forcedRefresh: Bool)
        /// An ownership check failed mid-flight; the caller must not act further.
        case socketReplaced
        /// `refreshTokenProvider` returned an empty token.
        case emptyRefresh
        /// `currentTokenProvider` or `refreshTokenProvider` threw.
        case refreshThrew(Error)
    }

    static func resolve(
        appliedToken: @MainActor () -> String,
        currentTokenProvider: (@MainActor @Sendable () async throws -> String)?,
        refreshTokenProvider: @MainActor @Sendable () async throws -> String,
        stillOwnsSocket: @MainActor () -> Bool = { true }
    ) async -> Outcome {
        do {
            if let currentTokenProvider {
                let current = try await currentTokenProvider()
                guard stillOwnsSocket() else { return .socketReplaced }
                if !current.isEmpty, current != appliedToken() {
                    return .token(current, forcedRefresh: false)
                }
            }
            let refreshed = try await refreshTokenProvider()
            guard stillOwnsSocket() else { return .socketReplaced }
            guard !refreshed.isEmpty else { return .emptyRefresh }
            return .token(refreshed, forcedRefresh: true)
        } catch {
            return .refreshThrew(error)
        }
    }
}
