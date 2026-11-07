import Foundation
import OSLog

private let renewalLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "StreamAuthRenewal")

/// Keeps one live socket's access ahead of the server's expiry close (`auth_renew`,
/// `capabilities.streamAuthRenewal`).
///
/// The server closes a device socket with `4001 auth_expired` 30 s after the token it holds for
/// that socket expires. A minute before the expiry, the renewer takes a token newer than the
/// socket's from the device auth session and sends it on the socket; the server checks it as at
/// connect and moves the socket's deadline to that token's. Each socket renews on its own
/// deadline, but the session's single-flight refresh mints one token for all of them: the first
/// socket to ask mints it, and the others get the same token back.
///
/// A refused renewal changes nothing on the server: the socket still closes at its old deadline,
/// and the stream's own `4001` recovery reconnects with the session's current token. Until then
/// a refusal that a newer token could fix is retried with one.
@MainActor
final class StreamAuthRenewer {
    /// Where newer tokens come from: the connection's device auth session.
    struct Source: Sendable {
        /// When `token` expires, if it is still the session's current token.
        let expiry: @Sendable (_ token: String) async -> Date?
        /// A token newer than `stale`. The session mints only when it still holds `stale`.
        let freshToken: @Sendable (_ stale: String) async throws -> String

        init(
            expiry: @escaping @Sendable (_ token: String) async -> Date?,
            freshToken: @escaping @Sendable (_ stale: String) async throws -> String
        ) {
            self.expiry = expiry
            self.freshToken = freshToken
        }

        init(session: DeviceAuthSession) {
            self.init(
                expiry: { token in await session.expiry(of: token) },
                freshToken: { stale in try await session.refreshAccessToken(replacing: stale) }
            )
        }
    }

    /// How long before a token's expiry its socket renews. The server closes 30 s after the
    /// expiry, so a renewal has 90 s to land, and a phone clock that runs that much slow still
    /// renews in time. It must exceed the session's own 30 s skew: inside that window the
    /// session would already treat the token as stale.
    nonisolated static let lead: TimeInterval = 60
    /// Wait before retrying a failed or unanswered renewal.
    nonisolated static let retryDelay: TimeInterval = 10

    private let source: Source
    private let streamRole: String
    private let now: () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var send: ((String) async throws -> Void)?
    private var onRenewed: ((String) -> Void)?
    /// The token the next renewal replaces: the one the server holds for the socket, or the
    /// last one it refused.
    private var replacing = ""
    /// Sent on the socket and not yet answered.
    private var pending: String?
    private var task: Task<Void, Never>?

    /// A renewer for one new live socket when the server takes `auth_renew`
    /// (`capabilities.streamAuthRenewal`) and the connection has a device auth session to mint
    /// from. Otherwise nil, and the socket reconnects when its token expires.
    static func ifSupported(
        by capabilities: ServerInfo.Capabilities?,
        session: DeviceAuthSession?,
        streamRole: String
    ) -> StreamAuthRenewer? {
        guard capabilities?.streamAuthRenewal?.version ?? 0 >= 1, let session else { return nil }
        return StreamAuthRenewer(source: Source(session: session), streamRole: streamRole)
    }

    init(
        source: Source,
        streamRole: String,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.source = source
        self.streamRole = streamRole
        self.now = now
        self.sleep = sleep
    }

    /// Renew the socket that opened with `token`. `send` writes one text frame on that socket;
    /// `onRenewed` gets each token the server accepted for it.
    func start(
        token: String,
        send: @escaping (String) async throws -> Void,
        onRenewed: @escaping (String) -> Void
    ) {
        stop()
        self.send = send
        self.onRenewed = onRenewed
        replacing = token
        task = Task { [weak self, source] in
            // An unknown expiry means the session already moved past this token, so renewing
            // now costs no mint.
            let expiresAt = await source.expiry(token)
            guard let self, !Task.isCancelled else { return }
            self.schedule(after: expiresAt.map { self.renewalDelay(expiresAt: $0) } ?? 0)
        }
    }

    /// Stop renewing: the socket closed or was replaced.
    func stop() {
        task?.cancel()
        task = nil
        send = nil
        onRenewed = nil
        pending = nil
    }

    /// The server's answer to the last `auth_renew` this renewer sent.
    func handle(_ result: StreamAuthRenewResult) {
        guard let pending else { return }
        self.pending = nil
        replacing = pending
        switch result {
        case .renewed(let expiresAt):
            onRenewed?(pending)
            schedule(after: renewalDelay(expiresAt: expiresAt))
        case .refused(let reason):
            ClientLog.warning(
                "StreamAuthRenewal",
                "Renewal refused",
                metadata: ["reason": reason, "streamRole": streamRole]
            )
            if result.isFinal {
                stop()
            } else {
                schedule(after: Self.retryDelay)
            }
        }
    }

    /// At least a second: a server deadline that is already due (a phone clock running fast)
    /// must not spin renewals.
    private func renewalDelay(expiresAt: Date) -> TimeInterval {
        max(1, expiresAt.timeIntervalSince(now()) - Self.lead)
    }

    private func schedule(after delay: TimeInterval) {
        task?.cancel()
        task = Task { [weak self, sleep] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.renew()
        }
    }

    private func renew() async {
        guard !Task.isCancelled, let send else { return }
        let token: String
        do {
            token = try await source.freshToken(replacing)
        } catch {
            guard !Task.isCancelled else { return }
            renewalLogger.error("Token for renewal unavailable: \(error.localizedDescription, privacy: .public)")
            schedule(after: Self.retryDelay)
            return
        }
        guard !Task.isCancelled else { return }
        guard !token.isEmpty else {
            schedule(after: Self.retryDelay)
            return
        }
        pending = token
        do {
            try await send(try StreamAuthRenewal.requestFrame(token: token))
        } catch {
            guard !Task.isCancelled else { return }
            // A WebSocket send fails only once the socket is gone; its replacement starts
            // its own renewer.
            renewalLogger.error("Renewal send failed: \(error.localizedDescription, privacy: .public)")
            stop()
            return
        }
        // The answer reschedules, which cancels this task. Without one (a lost frame), try
        // again: the session returns the same pending token without another mint.
        guard !Task.isCancelled else { return }
        schedule(after: Self.retryDelay)
    }
}
