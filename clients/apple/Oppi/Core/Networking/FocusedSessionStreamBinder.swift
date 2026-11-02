import Foundation

/// The focused-session stream binding of one connection: the session and route
/// its socket URL names, frames that arrived before the chat's consumer
/// attached, the external-open claim that lets a tapped session win focus
/// arbitration, which session owns the "recovering" presentation, and session
/// disconnects deferred while live audio drains.
///
/// `ServerConnection` runs the focus, rebind, and teardown workflows around it:
/// they touch the session, ask, and chat stores, which the connection owns.
@MainActor @Observable
final class FocusedSessionStreamBinder {
    // MARK: - Endpoint binding

    /// "split_session" while the socket URL names a session, else "none".
    private(set) var endpointKind = "none"
    private(set) var boundSessionId: String?
    private(set) var boundRouteScope: SessionRouteScope?
    private(set) var streamURL: URL?

    var isBound: Bool { endpointKind == "split_session" }

    /// The session and route a rebuilt route must rebind.
    var boundTarget: (sessionId: String, routeScope: SessionRouteScope)? {
        guard let boundSessionId, let boundRouteScope else { return nil }
        return (boundSessionId, boundRouteScope)
    }

    func bind(sessionId: String, routeScope: SessionRouteScope, url: URL) {
        endpointKind = "split_session"
        boundSessionId = sessionId
        boundRouteScope = routeScope
        streamURL = url
    }

    func clearBinding() {
        endpointKind = "none"
        boundSessionId = nil
        boundRouteScope = nil
        streamURL = nil
    }

    func isBound(sessionId: String, routeScope: SessionRouteScope) -> Bool {
        isBound && boundSessionId == sessionId && boundRouteScope == routeScope
    }

    #if DEBUG
    func _setEndpointKindForTesting(_ kind: String) {
        endpointKind = kind
    }
    #endif

    /// The URL-bound socket for one session: the server binds the destination
    /// in the path, so a frame can never be redirected by an envelope field.
    static func streamURL(
        selection: EndpointSelection,
        sessionId: String,
        routeScope: SessionRouteScope
    ) -> URL? {
        guard var components = URLComponents(url: selection.baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = selection.baseURL.scheme == "https" ? "wss" : "ws"
        switch routeScope {
        case .workspace(let workspaceId):
            components.path = "/workspaces/\(workspaceId)/sessions/\(sessionId)/stream"
        case .control:
            components.path = "/control-sessions/\(sessionId)/stream"
        }
        return components.url
    }

    // MARK: - Parked frames

    /// Focused-session frames that arrived after `connectStream()` but before
    /// `streamSession` registered a continuation. Notification tap and in-app
    /// re-entry open the bound socket first; without this buffer the server
    /// bootstrap (`connected`, catch-up, `state`) is dropped and later
    /// `connectStream()` is a no-op because the socket is already connected.
    private var parkedFrames: [String: [SessionStreamEvent]] = [:]
    static let parkedFrameLimit = 64

    func park(_ event: SessionStreamEvent) {
        var buffer = parkedFrames[event.sessionId] ?? []
        if buffer.count >= Self.parkedFrameLimit {
            if let index = buffer.firstIndex(where: { !Self.isProtectedParkedMessage($0.message) }) {
                let dropped = buffer.remove(at: index)
                ClientLog.info("Stream", "Dropped oldest non-protected parked frame", metadata: [
                    "sessionId": event.sessionId,
                    "droppedType": dropped.message.typeLabel,
                    "incomingType": event.message.typeLabel,
                    "limit": String(Self.parkedFrameLimit),
                ])
            } else if !Self.isProtectedParkedMessage(event.message) {
                ClientLog.info("Stream", "Dropped parked frame at bound", metadata: [
                    "sessionId": event.sessionId,
                    "type": event.message.typeLabel,
                    "limit": String(Self.parkedFrameLimit),
                ])
                return
            }
            // Protected bootstrap frames may exceed the bound so connected/state
            // are never evicted. The overflow is a handful of UI frames, not catch-up.
        }
        if buffer.isEmpty {
            ClientLog.info("Stream", "Parking focused session frames until consumer attaches", metadata: [
                "sessionId": event.sessionId,
                "type": event.message.typeLabel,
            ])
        }
        buffer.append(event)
        parkedFrames[event.sessionId] = buffer
    }

    func hasParkedBootstrap(for sessionId: String) -> Bool {
        parkedFrames[sessionId]?.contains {
            if case .connected = $0.message { return true }
            return false
        } ?? false
    }

    /// Remove and return a session's parked frames, oldest first.
    func takeParkedFrames(for sessionId: String) -> [SessionStreamEvent] {
        parkedFrames.removeValue(forKey: sessionId) ?? []
    }

    func dropParkedFrames(for sessionId: String) {
        parkedFrames.removeValue(forKey: sessionId)
    }

    /// Frames from a dying socket: attach must not replay two bootstrap generations.
    func dropAllParkedFrames() {
        parkedFrames.removeAll()
    }

    private static func isProtectedParkedMessage(_ message: ServerMessage) -> Bool {
        switch message {
        case .connected, .state, .sessionSummary, .extensionUIRequest, .extensionUINotification:
            return true
        default:
            return false
        }
    }

    // MARK: - External session open claim

    /// A notification or `oppi://session` tap binds the focused-session stream
    /// before navigation commits. A ChatViewController for a different session is often
    /// still mounted at that moment: its `onAppear` re-entry or connect loop
    /// would steal focus and tear down the socket that was opened for the
    /// tapped session milliseconds earlier, leaving the target with an ask card
    /// and no timeline. The claim makes the tapped session win focus
    /// arbitration until its own view binds the stream.
    private struct ExternalOpenClaim {
        let sessionId: String
        let expiresAt: ContinuousClock.Instant
    }

    private var externalOpenClaim: ExternalOpenClaim?

    /// Bounded so a target whose view never mounts cannot pin arbitration.
    static let externalOpenClaimWindow: Duration = .seconds(5)

    var externalOpenClaimSessionId: String? { externalOpenClaim?.sessionId }

    func beginExternalOpenClaim(for sessionId: String, window: Duration) {
        externalOpenClaim = ExternalOpenClaim(
            sessionId: sessionId,
            expiresAt: ContinuousClock.now.advanced(by: window)
        )
    }

    /// True while another session holds the external-open claim.
    func externalOpenClaimBlocks(_ sessionId: String) -> Bool {
        guard let claim = externalOpenClaim else { return false }
        guard ContinuousClock.now < claim.expiresAt else {
            externalOpenClaim = nil
            return false
        }
        return claim.sessionId != sessionId
    }

    func resolveExternalOpenClaim(for sessionId: String) {
        guard externalOpenClaim?.sessionId == sessionId else { return }
        externalOpenClaim = nil
    }

    // MARK: - Recovery presentation

    /// Session that currently owns focused-stream recovery presentation.
    private var recoveringSessionId: String?

    /// True only while the owner is the focused session (or nothing is focused yet).
    func isRecovering(focusedSessionId: String?) -> Bool {
        guard let owner = recoveringSessionId else { return false }
        if let focusedSessionId {
            return owner == focusedSessionId
        }
        return true
    }

    func setRecovering(_ recovering: Bool, sessionId: String, focusedSessionId: String?) {
        if recovering {
            if let focusedSessionId, focusedSessionId != sessionId { return }
            recoveringSessionId = sessionId
        } else if recoveringSessionId == sessionId {
            recoveringSessionId = nil
        }
    }

    // MARK: - Deferred playback disconnects

    /// Deferred disconnects for hidden sessions that still need live audio-stream delivery.
    private var deferredDisconnects: [String: Task<Void, Never>] = [:]

    func deferDisconnect(of sessionId: String, until task: Task<Void, Never>) {
        deferredDisconnects[sessionId] = task
    }

    func cancelDeferredDisconnect(of sessionId: String) {
        if let task = deferredDisconnects.removeValue(forKey: sessionId) {
            task.cancel()
        }
    }

    /// The deferred task's own completion: it no longer needs cancelling.
    func finishDeferredDisconnect(of sessionId: String) {
        deferredDisconnects.removeValue(forKey: sessionId)
    }
}
