import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "PairingApprovals")

/// One server's pending pairing approvals (`GET /auth/pairing-approvals` plus app
/// events). Each `ServerConnection` owns one; `PairingApprovalController` reads every
/// connection's list to present one request app-wide.
@MainActor @Observable
final class PairingApprovalList {
    private(set) var pending: [PendingPairingApproval] = []
    /// Bumped by every app-event change, so a list read that started before it cannot
    /// overwrite it.
    private var mutationGeneration: UInt64 = 0
    /// Bumped by every read, so an older overlapping read cannot replace a newer one.
    private var refreshSequence: UInt64 = 0

    func upsert(_ approval: PendingPairingApproval) {
        mutationGeneration &+= 1
        if let index = pending.firstIndex(where: { $0.id == approval.id }) {
            pending[index] = approval
        } else {
            pending.append(approval)
        }
        pending.sort { $0.requestedAt < $1.requestedAt }
        NotificationCenter.default.post(name: .pairingApprovalsDidChange, object: nil)
    }

    func remove(id: String) {
        let before = pending.count
        pending.removeAll { $0.id == id }
        guard pending.count != before else { return }
        mutationGeneration &+= 1
        NotificationCenter.default.post(name: .pairingApprovalsDidChange, object: nil)
    }

    /// Replace the list with the server's, unless an app event or a newer read changed it
    /// while this read ran. A nil `fetch` (no client yet) still counts as a read.
    func refresh(using fetch: (() async throws -> [PendingPairingApproval])?) async {
        refreshSequence &+= 1
        let sequence = refreshSequence
        let generation = mutationGeneration
        guard let fetch else { return }
        do {
            let list = try await fetch()
            guard refreshSequence == sequence,
                  mutationGeneration == generation else { return }
            pending = list.sorted { $0.requestedAt < $1.requestedAt }
            NotificationCenter.default.post(name: .pairingApprovalsDidChange, object: nil)
        } catch {
            logger.error("Failed to refresh pairing approvals: \(error.localizedDescription, privacy: .public)")
        }
    }
}
