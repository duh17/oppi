import Foundation

/// Observable store for pending permission requests.
///
/// Separate from SessionStore so permission timer ticks don't re-render
/// the session list.
///
/// Key design: `take(id:)` removes AND returns the full request so callers
/// can pass tool/summary to the reducer for resolved timeline markers.
@MainActor @Observable
final class PermissionStore {
    var pending: [PermissionRequest] = []

    /// Total pending count (for badge display).
    var count: Int { pending.count }

    /// Add a new permission request.
    func add(_ request: PermissionRequest) {
        // Avoid duplicates
        guard !pending.contains(where: { $0.id == request.id }) else { return }
        pending.append(request)
    }

    /// Remove and return a permission (caller needs tool/summary for resolved marker).
    func take(id: String) -> PermissionRequest? {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return nil }
        return pending.remove(at: idx)
    }

    /// Remove without returning (fire-and-forget cleanup).
    func remove(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Pending permissions for a specific session.
    func pending(for sessionId: String) -> [PermissionRequest] {
        pending.filter { $0.sessionId == sessionId }
    }

    /// Remove permissions whose timeout has passed.
    /// Returns the full requests so callers can record resolved markers with tool/summary.
    func sweepExpired() -> [PermissionRequest] {
        let now = Date()
        let expired = pending.filter { $0.hasExpiry && $0.timeoutAt < now }
        pending.removeAll { $0.hasExpiry && $0.timeoutAt < now }
        return expired
    }
}
