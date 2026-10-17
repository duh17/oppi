import Foundation
import Observation
import UserNotifications

/// Keeps the app icon badge on the sessions that owe the user a look, across every paired
/// server (`SessionBadge`).
///
/// While the app runs it recounts on every session store change, including each session the
/// user sees, so opening a session counts down at once. Each recount is written back to the
/// App Group, where the Notification Service Extension adds the sessions of pushes that
/// arrive while the app is not running. A paired server whose session list has not loaded
/// yet keeps the sessions those pushes recorded.
@MainActor
final class AppIconBadgeService {
    static let shared = AppIconBadgeService()

    /// What one recount found; the stored set changes only when this does.
    struct Recount: Equatable {
        var owed: Set<SessionBadge.Key> = []
        var loadedServerIds: Set<String> = []
        var pairedServerIds: Set<String> = []
    }

    private weak var coordinator: ConnectionCoordinator?
    private var badge = SessionBadge()
    private var lastRecount: Recount?
    private var appliedCount: Int?

    private init() {}

    /// Start recounting on every change to the paired servers and their session stores.
    func start(coordinator: ConnectionCoordinator) {
        guard self.coordinator !== coordinator else { return }
        self.coordinator = coordinator
        observe()
    }

    /// Pushes may have added sessions and set the badge while the app was away.
    func appDidBecomeActive() {
        lastRecount = nil
        appliedCount = nil
        refresh()
    }

    /// Recount, store the set, and set the badge. Returns the badge, or nil before `start`.
    @discardableResult
    func refresh() -> Int? {
        guard let coordinator else { return nil }
        var recount = Self.recount(stores: coordinator.connections.mapValues(\.sessionStore))
        recount.pairedServerIds = Set(coordinator.serverStore.servers.map(\.id))
        if recount != lastRecount {
            lastRecount = recount
            let reconcile = { (badge: inout SessionBadge) in
                badge.reconcile(
                    owed: recount.owed,
                    loadedServerIds: recount.loadedServerIds,
                    pairedServerIds: recount.pairedServerIds
                )
            }
            if let stored = PushSharedStore.updateSessionBadge(reconcile) {
                badge = stored
            } else {
                reconcile(&badge)
            }
        }
        let count = badge.count
        if count != appliedCount {
            appliedCount = count
            Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
        }
        return count
    }

    /// Sessions owing a look on each server whose session list has loaded from the server.
    static func recount(stores: [String: SessionStore]) -> Recount {
        var recount = Recount()
        for (serverId, store) in stores where store.lastSuccessfulSyncAt != nil {
            recount.loadedServerIds.insert(serverId)
            for sessionId in store.sessionIdsOwingALook {
                recount.owed.insert(SessionBadge.Key(serverId: serverId, sessionId: sessionId))
            }
        }
        return recount
    }

    private func observe() {
        _ = withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }
}
