import Foundation

/// Sheet-backed generic extension dialogs waiting for an answer, queued per
/// session. A session's first request is the one its sheet shows
/// (`ServerConnection.activeExtensionDialog`). `ServerConnection` owns one and
/// keeps the cross-store work around it: workspace attention summaries, push
/// discovery, and the silence watchdog.
@MainActor @Observable
final class ExtensionDialogQueue {
    /// Never holds an empty queue: removing a session's last request removes its key.
    private(set) var queues: [String: [ExtensionUIRequest]] = [:]

    var requests: [ExtensionUIRequest] {
        queues.values.flatMap { $0 }
    }

    func requests(for sessionId: String) -> [ExtensionUIRequest] {
        queues[sessionId] ?? []
    }

    func hasPending(for sessionId: String) -> Bool {
        !(queues[sessionId]?.isEmpty ?? true)
    }

    /// Append, or replace in place a request with the same id.
    func enqueue(_ request: ExtensionUIRequest, for sessionId: String) {
        var queue = queues[sessionId] ?? []
        if let existingIndex = queue.firstIndex(where: { $0.id == request.id }) {
            queue[existingIndex] = request
        } else {
            queue.append(request)
        }
        queues[sessionId] = queue
    }

    /// Replace the request the session's sheet shows (or start its queue).
    func replaceFirst(_ request: ExtensionUIRequest, for sessionId: String) {
        var queue = queues[sessionId] ?? []
        if queue.isEmpty {
            queue = [request]
        } else {
            queue[0] = request
        }
        queues[sessionId] = queue
    }

    /// Drop a session's whole queue. Returns the dropped queue, nil when it had none.
    func removeQueue(for sessionId: String) -> [ExtensionUIRequest]? {
        queues.removeValue(forKey: sessionId)
    }

    /// Remove request `requestId` from every queue. Returns each session it left
    /// and the workspace id the removed request named.
    func remove(id requestId: String) -> [(sessionId: String, workspaceId: String?)] {
        var changedSessions: [(sessionId: String, workspaceId: String?)] = []
        for sessionId in Array(queues.keys) {
            guard var queue = queues[sessionId] else { continue }
            let removedWorkspaceId = queue.first(where: { $0.id == requestId })?.workspaceId
            let originalCount = queue.count
            queue.removeAll { $0.id == requestId }
            guard queue.count != originalCount else { continue }
            if queue.isEmpty {
                queues.removeValue(forKey: sessionId)
            } else {
                queues[sessionId] = queue
            }
            changedSessions.append((sessionId: sessionId, workspaceId: removedWorkspaceId))
        }
        return changedSessions
    }
}
