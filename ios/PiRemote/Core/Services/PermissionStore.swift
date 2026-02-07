import Foundation

/// Observable store for pending permission requests.
///
/// Separate from SessionStore so permission timer ticks don't re-render
/// the session list.
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

    /// Remove a resolved or cancelled permission.
    func remove(id: String) {
        pending.removeAll { $0.id == id }
    }

    /// Mark a permission as resolved (remove from pending).
    func resolve(id: String) {
        remove(id: id)
    }

    /// Mark a permission as expired (remove from pending).
    func expire(id: String) {
        remove(id: id)
    }

    /// Pending permissions for a specific session.
    func pending(for sessionId: String) -> [PermissionRequest] {
        pending.filter { $0.sessionId == sessionId }
    }
}
