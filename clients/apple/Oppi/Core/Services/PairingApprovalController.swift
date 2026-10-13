import Foundation

/// Owns the in-app pending-pairing prompt across connected servers.
@MainActor @Observable
final class PairingApprovalController {
    static let shared = PairingApprovalController()

    struct Presented: Identifiable, Equatable {
        var id: String { "\(serverId)|\(approval.id)" }
        let serverId: String
        let serverName: String
        let approval: PendingPairingApproval
        var errorMessage: String?
        var isBusy: Bool
    }

    private(set) var presented: Presented?
    private var snoozedIds: Set<String> = []
    private var preferred: (serverId: String, approvalId: String)?
    private var pendingDenies: [(serverId: String, approvalId: String)] = []

    var authenticate: (String) async -> Bool = { reason in
        await DeviceOwnerAuthentication.authenticate(reason: reason) == .success
    }

    func sync(coordinator: ConnectionCoordinator, now: Date = Date()) {
        flushPendingDenies(coordinator: coordinator)
        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        var candidates: [Presented] = []
        for (serverId, connection) in coordinator.connections {
            let serverName = coordinator.serverStore.server(for: serverId)?.name
                ?? connection.credentials?.name
                ?? "Server"
            for approval in connection.pendingPairingApprovals where approval.expiresAt > nowMs {
                candidates.append(
                    Presented(
                        serverId: serverId,
                        serverName: serverName,
                        approval: approval,
                        errorMessage: nil,
                        isBusy: false
                    )
                )
            }
        }
        candidates.sort {
            if $0.approval.requestedAt != $1.approval.requestedAt {
                return $0.approval.requestedAt < $1.approval.requestedAt
            }
            return $0.id < $1.id
        }

        if let preferred,
           let match = candidates.first(where: { $0.serverId == preferred.serverId && $0.approval.id == preferred.approvalId }) {
            presented = keepTransientState(on: match)
            return
        }

        if let presented,
           let match = candidates.first(where: { $0.id == presented.id }) {
            self.presented = keepTransientState(on: match)
            return
        }

        presented = candidates.first { !snoozedIds.contains($0.id) }
    }

    func refreshAndSync(coordinator: ConnectionCoordinator) async {
        for connection in coordinator.connections.values {
            await connection.refreshPairingApprovals()
        }
        sync(coordinator: coordinator)
    }

    func handleNotification(
        serverId: String,
        approvalId: String?,
        action: PairingNotificationAction,
        coordinator: ConnectionCoordinator
    ) {
        switch action {
        case .deny:
            guard let approvalId else { return }
            pendingDenies.append((serverId, approvalId))
            Task { await refreshAndSync(coordinator: coordinator) }
        case .open, .approve:
            if let approvalId {
                preferred = (serverId, approvalId)
                snoozedIds.remove("\(serverId)|\(approvalId)")
            }
            Task { await refreshAndSync(coordinator: coordinator) }
        }
    }

    func dismiss(snooze: Bool = true) {
        if snooze, let presented {
            snoozedIds.insert(presented.id)
        }
        preferred = nil
        presented = nil
    }

    func approve(coordinator: ConnectionCoordinator) async {
        guard var current = presented else { return }
        current.isBusy = true
        current.errorMessage = nil
        presented = current
        let authorized = await authenticate(String(localized: "Approve a new device"))
        guard authorized else {
            current.isBusy = false
            presented = current
            return
        }
        guard let connection = coordinator.connection(for: current.serverId) else {
            current.isBusy = false
            current.errorMessage = "That server is not connected."
            presented = current
            return
        }
        do {
            try await connection.approvePairingApproval(current.approval)
            preferred = nil
            presented = nil
        } catch {
            current.isBusy = false
            current.errorMessage = UserFacingErrorText.normalize(error.localizedDescription)
            presented = current
        }
    }

    func deny(coordinator: ConnectionCoordinator) async {
        guard var current = presented else { return }
        current.isBusy = true
        current.errorMessage = nil
        presented = current
        guard let connection = coordinator.connection(for: current.serverId) else {
            current.isBusy = false
            current.errorMessage = "That server is not connected."
            presented = current
            return
        }
        do {
            try await connection.denyPairingApproval(id: current.approval.id)
            preferred = nil
            presented = nil
        } catch {
            current.isBusy = false
            current.errorMessage = UserFacingErrorText.normalize(error.localizedDescription)
            presented = current
        }
    }

    private func keepTransientState(on candidate: Presented) -> Presented {
        var next = candidate
        if let presented, presented.id == candidate.id {
            next.errorMessage = presented.errorMessage
            next.isBusy = presented.isBusy
        }
        return next
    }

    private func flushPendingDenies(coordinator: ConnectionCoordinator) {
        guard !pendingDenies.isEmpty else { return }
        let queued = pendingDenies
        pendingDenies.removeAll()
        for item in queued {
            if let connection = coordinator.connection(for: item.serverId) {
                Task {
                    try? await connection.denyPairingApproval(id: item.approvalId)
                }
            } else {
                pendingDenies.append(item)
            }
        }
    }
}
