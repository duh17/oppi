import Foundation
import Observation
import OSLog

private let pairingDenyLogger = Logger(subsystem: AppIdentifiers.subsystem, category: "PairingApprovals")

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

    private struct DenyKey: Hashable {
        let serverId: String
        let approvalId: String
    }

    /// Server lifetime of a pending approval (`PAIRING_APPROVAL_TTL_MS`).
    nonisolated static let denyLifetime: Duration = .seconds(120)

    private(set) var presented: Presented?
    private var snoozedIds: Set<String> = []
    private var preferred: (serverId: String, approvalId: String)?
    private var pendingDenies: [DenyKey] = []
    private var denyInFlight: Set<DenyKey> = []
    @ObservationIgnored private weak var syncedCoordinator: ConnectionCoordinator?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?

    // MARK: - Sync triggers

    /// Keeps `presented` in step with the connections' pending approvals: now, on every
    /// `.pairingApprovalsDidChange`, and whenever a connection's pending ids change. The
    /// scene becoming active is the app's call (`sceneDidBecomeActive(coordinator:)`). Safe
    /// to call again for the same coordinator.
    func startSyncing(coordinator: ConnectionCoordinator) {
        guard syncedCoordinator !== coordinator else { return }
        syncedCoordinator = coordinator
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .pairingApprovalsDidChange, object: nil, queue: .main
        ) { [weak self, weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let self, let coordinator else { return }
                self.sync(coordinator: coordinator)
            }
        }
        observePendingIds(of: coordinator)
        sync(coordinator: coordinator)
    }

    /// The app became active: ask every server again, send the denies that were waiting for
    /// a connection, then sync.
    func sceneDidBecomeActive(coordinator: ConnectionCoordinator) {
        Task { await refreshAndSync(coordinator: coordinator) }
    }

    private func observePendingIds(of coordinator: ConnectionCoordinator) {
        withObservationTracking {
            for connection in coordinator.connections.values { _ = connection.pendingPairingApprovals.map(\.id) }
        } onChange: { [weak self, weak coordinator] in
            Task { @MainActor in
                guard let self, let coordinator, self.syncedCoordinator === coordinator else { return }
                self.sync(coordinator: coordinator)
                self.observePendingIds(of: coordinator)
            }
        }
    }

    func sync(coordinator: ConnectionCoordinator, now: Date = Date()) {
        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        var pending: [(serverId: String, serverName: String, approval: PendingPairingApproval)] = []
        for (serverId, connection) in coordinator.connections {
            let serverName = coordinator.serverStore.server(for: serverId)?.name
                ?? connection.credentials?.name
                ?? "Server"
            for approval in connection.pendingPairingApprovals where approval.expiresAt > nowMs {
                pending.append((serverId, serverName, approval))
            }
        }
        apply(pending: pending, now: now)
    }

    func apply(
        pending: [(serverId: String, serverName: String, approval: PendingPairingApproval)],
        now: Date = Date()
    ) {
        let nowMs = Int64((now.timeIntervalSince1970 * 1_000).rounded())
        var candidates: [Presented] = []
        for item in pending where item.approval.expiresAt > nowMs {
            let key = DenyKey(serverId: item.serverId, approvalId: item.approval.id)
            guard !blocksApprove(key) else { continue }
            candidates.append(
                Presented(
                    serverId: item.serverId,
                    serverName: item.serverName,
                    approval: item.approval,
                    errorMessage: nil,
                    isBusy: false
                )
            )
        }
        candidates.sort {
            if $0.approval.requestedAt != $1.approval.requestedAt {
                return $0.approval.requestedAt < $1.approval.requestedAt
            }
            return $0.id < $1.id
        }

        if let preferred {
            if let match = candidates.first(where: {
                $0.serverId == preferred.serverId && $0.approval.id == preferred.approvalId
            }) {
                presented = keepTransientState(on: match)
                return
            }
            self.preferred = nil
            presented = nil
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
        await performQueuedDenies(coordinator: coordinator)
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
            Task { await performNotificationDeny(serverId: serverId, approvalId: approvalId, coordinator: coordinator) }
        case .open, .approve:
            if let approvalId {
                prefer(serverId: serverId, approvalId: approvalId)
            }
            Task { await refreshAndSync(coordinator: coordinator) }
        }
    }

    func performNotificationDeny(
        serverId: String,
        approvalId: String,
        coordinator: ConnectionCoordinator
    ) async {
        queueDeny(serverId: serverId, approvalId: approvalId)
        // The server forgets a pending approval after its 2-minute lifetime, so a
        // deny that has not landed by then has nothing left to deny.
        let deadline = ContinuousClock.now + Self.denyLifetime
        while hasQueuedDeny(serverId: serverId, approvalId: approvalId),
              !Task.isCancelled,
              ContinuousClock.now < deadline {
            await performQueuedDenies(coordinator: coordinator)
            if hasQueuedDeny(serverId: serverId, approvalId: approvalId) {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        sync(coordinator: coordinator)
    }

    func prefer(serverId: String, approvalId: String) {
        preferred = (serverId, approvalId)
        snoozedIds.remove("\(serverId)|\(approvalId)")
    }

    func queueDeny(serverId: String, approvalId: String) {
        let key = DenyKey(serverId: serverId, approvalId: approvalId)
        if !pendingDenies.contains(key), !denyInFlight.contains(key) {
            pendingDenies.append(key)
        }
        if presented?.serverId == serverId, presented?.approval.id == approvalId {
            presented = nil
        }
        if preferred?.serverId == serverId, preferred?.approvalId == approvalId {
            preferred = nil
        }
        snoozedIds.insert("\(serverId)|\(approvalId)")
    }

    func hasQueuedDeny(serverId: String, approvalId: String) -> Bool {
        blocksApprove(DenyKey(serverId: serverId, approvalId: approvalId))
    }

    func dismiss(snooze: Bool = true) {
        if snooze, let presented {
            snoozedIds.insert(presented.id)
        }
        preferred = nil
        presented = nil
    }

    /// Approves the request `presentedId` names (`Presented.id`): the one the sheet is
    /// showing, on its own server. A tap that arrives after the sheet moved on to another
    /// request (or none), or while this one is already being approved, does nothing; an
    /// expired request is never signed; and nothing is approved without the device owner's
    /// authentication. A request that leaves while the owner authenticates or the server
    /// answers (denied elsewhere, settled, expired) is not signed, and nothing is written
    /// back for it: the sheet has moved on to whatever is presented now.
    ///
    /// `now` is this device's clock, compared with the server's `expiresAt`. A skewed device
    /// clock can call a live request expired or the reverse; the server checks its own clock
    /// again on approve, so this only spares the owner a doomed authentication.
    func approve(
        presentedId: String,
        coordinator: ConnectionCoordinator,
        now: @escaping () -> Date = { Date() },
        authenticate: (String) async -> Bool = { reason in
            await DeviceOwnerAuthentication.authenticate(reason: reason) == .success
        }
    ) async {
        guard var current = presented, current.id == presentedId, !current.isBusy else { return }
        let key = DenyKey(serverId: current.serverId, approvalId: current.approval.id)
        guard !blocksApprove(key) else {
            presented = nil
            return
        }
        func isExpired() -> Bool {
            current.approval.expiresAt <= Int64((now().timeIntervalSince1970 * 1_000).rounded())
        }
        func showsStill() -> Bool { presented?.id == presentedId }
        guard !isExpired() else {
            current.errorMessage = String(localized: "This request expired. Ask the device to try again.")
            presented = current
            return
        }
        // Busy is set in the same turn as the guard above, so a second tap returns there.
        current.isBusy = true
        current.errorMessage = nil
        presented = current
        let authorized = await authenticate(String(localized: "Approve a new device"))
        guard showsStill() else { return }
        guard authorized else {
            current.isBusy = false
            presented = current
            return
        }
        guard !blocksApprove(key) else {
            presented = nil
            return
        }
        guard !isExpired() else {
            current.isBusy = false
            current.errorMessage = String(localized: "This request expired. Ask the device to try again.")
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
            // The connection dropped the approval and synced `presented` to the next request.
            if showsStill() { presented = nil }
            if preferred?.serverId == current.serverId, preferred?.approvalId == current.approval.id { preferred = nil }
        } catch {
            guard showsStill() else { return }
            current.isBusy = false
            current.errorMessage = UserFacingErrorText.normalize(error.localizedDescription)
            presented = current
        }
    }

    /// Denies the request `presentedId` names, like `approve(presentedId:...)`.
    func deny(presentedId: String, coordinator: ConnectionCoordinator) async {
        guard let current = presented, current.id == presentedId else { return }
        queueDeny(serverId: current.serverId, approvalId: current.approval.id)
        await performQueuedDenies(coordinator: coordinator)
        if hasQueuedDeny(serverId: current.serverId, approvalId: current.approval.id) {
            var failed = current
            failed.isBusy = false
            failed.errorMessage = "Could not deny this device. Try again."
            presented = failed
        }
        sync(coordinator: coordinator)
    }

    func performQueuedDenies(
        coordinator: ConnectionCoordinator? = nil,
        postDeny: ((String, String) async throws -> Void)? = nil
    ) async {
        let queued = pendingDenies
        pendingDenies.removeAll()
        for key in queued {
            denyInFlight.insert(key)
            do {
                if let postDeny {
                    try await postDeny(key.serverId, key.approvalId)
                } else if let coordinator {
                    try await sendDeny(serverId: key.serverId, approvalId: key.approvalId, coordinator: coordinator)
                } else {
                    pendingDenies.append(key)
                    denyInFlight.remove(key)
                    continue
                }
                denyInFlight.remove(key)
                coordinator?.connection(for: key.serverId)?.removePendingPairingApproval(id: key.approvalId)
            } catch {
                denyInFlight.remove(key)
                if Self.denyIsSettled(error) {
                    coordinator?.connection(for: key.serverId)?.removePendingPairingApproval(id: key.approvalId)
                    continue
                }
                pairingDenyLogger.error(
                    "Pairing deny failed for \(key.approvalId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                if !pendingDenies.contains(key) {
                    pendingDenies.append(key)
                }
            }
        }
    }

    private func sendDeny(
        serverId: String,
        approvalId: String,
        coordinator: ConnectionCoordinator
    ) async throws {
        // Wait for the DeviceAuthSession-backed connection client. A raw
        // APIClient built from `effectiveAccessToken` cannot refresh, so an
        // expired `at_` gets 401 and the deny never lands.
        guard let client = await coordinator.apiClientReady(for: serverId) else {
            throw APIError.server(status: 503, message: "server_unavailable")
        }
        try await client.denyPairingApproval(id: approvalId)
    }

    private func blocksApprove(_ key: DenyKey) -> Bool {
        pendingDenies.contains(key) || denyInFlight.contains(key)
    }

    private func keepTransientState(on candidate: Presented) -> Presented {
        var next = candidate
        if let presented, presented.id == candidate.id {
            next.errorMessage = presented.errorMessage
            next.isBusy = presented.isBusy
        }
        return next
    }

    private static func denyIsSettled(_ error: Error) -> Bool {
        switch error as? APIError {
        case .server(404, _), .codedServer(404, _, _):
            true
        default:
            false
        }
    }
}
