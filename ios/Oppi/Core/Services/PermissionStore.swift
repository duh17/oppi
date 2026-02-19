import Foundation

/// Observable store for pending permission requests.
///
/// Internally partitioned by server ID — each server's permissions are
/// stored separately. The `pending` property delegates to the active
/// server's partition.
///
/// Separate from SessionStore so permission timer ticks don't re-render
/// the session list.
///
/// Key design: `take(id:)` removes AND returns the full request so callers
/// can pass tool/summary to the reducer for resolved timeline markers.
@MainActor @Observable
final class PermissionStore {
    // ── Per-server backing storage ──

    private var serverPending: [String: [PermissionRequest]] = [:]

    /// Which server's permissions are currently active.
    private(set) var activeServerId: String?

    // ── Public API: delegates to active server ──

    /// Pending permissions for the currently active server.
    var pending: [PermissionRequest] {
        get { serverPending[activeServerId ?? ""] ?? [] }
        set { serverPending[activeServerId ?? ""] = newValue }
    }

    /// Total pending count for the active server (for badge display).
    var count: Int { pending.count }

    /// Convenience emptiness check for active server permissions.
    var isEmpty: Bool { pending.isEmpty }

    /// Add a new permission request.
    func add(_ request: PermissionRequest) {
        guard !pending.contains(where: { $0.id == request.id }) else { return }
        var list = pending
        list.append(request)
        pending = list
    }

    /// Remove and return a permission (caller needs tool/summary for resolved marker).
    func take(id: String) -> PermissionRequest? {
        var list = pending
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return nil }
        let request = list.remove(at: idx)
        pending = list
        return request
    }

    /// Remove without returning (fire-and-forget cleanup).
    func remove(id: String) {
        var list = pending
        list.removeAll { $0.id == id }
        pending = list
    }

    /// Pending permissions for a specific session (active server only).
    func pending(for sessionId: String) -> [PermissionRequest] {
        pending.filter { $0.sessionId == sessionId }
    }

    /// Remove permissions whose timeout has passed.
    /// Returns the full requests so callers can record resolved markers with tool/summary.
    func sweepExpired() -> [PermissionRequest] {
        let now = Date()
        var list = pending
        let expired = list.filter { $0.hasExpiry && $0.timeoutAt < now }
        list.removeAll { $0.hasExpiry && $0.timeoutAt < now }
        pending = list
        return expired
    }

    // ── Cross-server queries ──

    /// ALL pending permissions across ALL servers. Used by cross-session
    /// permission banner in ContentView.
    var allPending: [PermissionRequest] {
        serverPending.values.flatMap { $0 }
    }

    /// Total pending count across ALL servers.
    var allCount: Int { allPending.count }

    /// Pending permissions for a specific server.
    func pending(forServer serverId: String) -> [PermissionRequest] {
        serverPending[serverId] ?? []
    }

    // ── Server switching ──

    /// Switch the active server partition.
    func switchServer(to serverId: String) {
        guard serverId != activeServerId else { return }
        activeServerId = serverId
        if serverPending[serverId] == nil {
            serverPending[serverId] = []
        }
    }

    /// Remove all data for a server (on unpair).
    func removeServer(_ serverId: String) {
        serverPending.removeValue(forKey: serverId)
        if activeServerId == serverId {
            activeServerId = nil
        }
    }
}
