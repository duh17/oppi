import Foundation
import Observation

/// A server, workspace, or session that can carry a device-local lock flag.
/// Servers are keyed by their identity fingerprint (`PairedServer.id`);
/// workspaces and sessions by their server plus their own id.
enum ScopedLockScope: Hashable, Codable, Sendable {
    case server(serverId: String)
    case workspace(serverId: String, workspaceId: String)
    case session(serverId: String, sessionId: String)

    var serverId: String {
        switch self {
        case .server(let serverId), .workspace(let serverId, _), .session(let serverId, _):
            serverId
        }
    }
}

/// Something a gate, row, or cover checks: an item and the scopes above it.
struct ScopedLockTarget: Hashable, Sendable {
    let serverId: String
    let workspaceId: String?
    let sessionId: String?
    /// Incognito sessions are always gated while App Lock is on.
    let isIncognito: Bool

    static func server(_ serverId: String) -> Self {
        Self(serverId: serverId, workspaceId: nil, sessionId: nil, isIncognito: false)
    }

    static func workspace(serverId: String, workspaceId: String) -> Self {
        Self(serverId: serverId, workspaceId: workspaceId, sessionId: nil, isIncognito: false)
    }

    static func session(
        serverId: String,
        workspaceId: String?,
        sessionId: String,
        isIncognito: Bool
    ) -> Self {
        Self(
            serverId: serverId,
            workspaceId: workspaceId?.isEmpty == false ? workspaceId : nil,
            sessionId: sessionId,
            isIncognito: isIncognito
        )
    }

    static func session(_ session: Session, serverId: String) -> Self {
        .session(
            serverId: serverId,
            workspaceId: session.workspaceId,
            sessionId: session.id,
            isIncognito: session.ephemeral == true
        )
    }

    /// The item's own scope.
    var scope: ScopedLockScope {
        if let sessionId { return .session(serverId: serverId, sessionId: sessionId) }
        if let workspaceId { return .workspace(serverId: serverId, workspaceId: workspaceId) }
        return .server(serverId: serverId)
    }

    /// Outermost first: server, then workspace, then session.
    var chain: [ScopedLockScope] {
        var scopes: [ScopedLockScope] = [.server(serverId: serverId)]
        if let workspaceId { scopes.append(.workspace(serverId: serverId, workspaceId: workspaceId)) }
        if let sessionId { scopes.append(.session(serverId: serverId, sessionId: sessionId)) }
        return scopes
    }
}

/// Lock state of an item. `none`: nothing gates it.
enum ScopedLockState: Equatable, Sendable {
    case none
    case locked
    case unlocked
}

/// Pure scoped-lock rules; `ScopedLockService` holds the state.
///
/// - A scope is gated when it carries a lock flag. An incognito session is
///   also gated while App Lock is on.
/// - A target is reachable when every gated scope in its chain is covered: it,
///   or a scope above it, was unlocked in the current generation. Unlocking a
///   server covers its workspaces and sessions; a workspace covers its
///   sessions.
/// - An unlock is valid only while `generation` (`AppLockService
///   .scopedUnlockGeneration`) is unchanged: until Oppi locks, or with App
///   Lock off, until Oppi leaves the foreground.
struct ScopedLockPolicy: Equatable, Sendable {
    var flags: Set<ScopedLockScope>
    /// Scope → generation it was unlocked in.
    var unlocks: [ScopedLockScope: Int]
    var generation: Int
    var appLockEnabled: Bool

    func isGated(_ scope: ScopedLockScope, in target: ScopedLockTarget) -> Bool {
        if flags.contains(scope) { return true }
        if case .session = scope, scope == target.scope, target.isIncognito, appLockEnabled {
            return true
        }
        return false
    }

    func gatedScopes(_ target: ScopedLockTarget) -> [ScopedLockScope] {
        target.chain.filter { isGated($0, in: target) }
    }

    func isUnlocked(_ scope: ScopedLockScope) -> Bool {
        unlocks[scope] == generation
    }

    /// Whether `target`'s content may be shown now.
    func access(_ target: ScopedLockTarget) -> ScopedLockState {
        let chain = target.chain
        var sawGate = false
        var covered = false
        for scope in chain {
            covered = covered || isUnlocked(scope)
            guard isGated(scope, in: target) else { continue }
            sawGate = true
            if !covered { return .locked }
        }
        return sawGate ? .unlocked : .none
    }

    /// Badge on the item's row. Every item whose content is hidden shows
    /// `locked`; only the item that carries the lock shows `unlocked` once
    /// reachable, so an unlocked server does not badge everything under it.
    func badge(_ target: ScopedLockTarget) -> ScopedLockState {
        let state = access(target)
        if isGated(target.scope, in: target) { return state }
        return state == .locked ? .locked : .none
    }

    /// Notifications and Live Activities outlive a generation, so they hide
    /// text for anything gated, unlocked or not.
    func hidesContentOutsideApp(_ target: ScopedLockTarget) -> Bool {
        !gatedScopes(target).isEmpty
    }

    /// After device authentication for `target`: every gated scope in its
    /// chain counts as unlocked for `generation`.
    mutating func recordUnlock(_ target: ScopedLockTarget, generation: Int) {
        for scope in gatedScopes(target) {
            unlocks[scope] = generation
        }
    }

    /// Remove every flag and unlock owned by a removed server.
    mutating func forgetServer(_ serverId: String) {
        flags = flags.filter { $0.serverId != serverId }
        unlocks = unlocks.filter { $0.key.serverId != serverId }
    }

    mutating func forget(_ scopes: some Sequence<ScopedLockScope>) {
        for scope in scopes {
            flags.remove(scope)
            unlocks.removeValue(forKey: scope)
        }
    }
}

/// Per-server, per-workspace, and per-session locks.
///
/// Flags are device-local (`UserDefaults.standard`) and never sent to a
/// server. Unlocks live in memory and end when `AppLockService
/// .scopedUnlockGeneration` advances. Authentication reuses App Lock's
/// LocalAuthentication path and works with App Lock off.
///
/// This is a UI lock: it protects against someone holding an unlocked phone,
/// not server-side data or other paired devices.
@MainActor @Observable
final class ScopedLockService {
    static let shared = ScopedLockService()

    static let flagsKey = "\(AppIdentifiers.subsystem).scopedLock.flags"

    private(set) var flags: Set<ScopedLockScope>
    /// Workspace of each locked session, recorded when it was locked, so
    /// deleting the workspace forgets session locks the device no longer lists.
    private var sessionWorkspaceIds: [ScopedLockScope: String] = [:]
    private var unlocks: [ScopedLockScope: Int] = [:]
    /// A device-auth prompt from this service is up.
    private(set) var isAuthenticating = false
    @ObservationIgnored private var authorization: Task<Void, Never>?

    /// Workspace and incognito state for a session the caller only knows by id
    /// (deep links, notification taps). Set at launch from the session stores.
    @ObservationIgnored var sessionLookup: @MainActor (_ serverId: String, _ sessionId: String) -> Session? = { _, _ in nil }
    /// Called after a lock turns on so Oppi's own notifications and the Live
    /// Activity stop showing text from the newly locked scope.
    @ObservationIgnored private let didLock: @MainActor () -> Void
    /// Stops audio and video when Oppi leaves the foreground and that ends
    /// the unlocks: what was playing may come from a now-locked scope.
    @ObservationIgnored private let stopPlayback: @MainActor () -> Void

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appLock: AppLockService

    init(
        defaults: UserDefaults = .standard,
        appLock: AppLockService = .shared,
        didLock: @escaping @MainActor () -> Void = { ScopedLockService.clearContentShownBeforeLock() },
        stopPlayback: @escaping @MainActor () -> Void = { AppLockPlayback.stopAll() }
    ) {
        self.stopPlayback = stopPlayback
        self.defaults = defaults
        self.appLock = appLock
        self.didLock = didLock
        let stored = Self.loadFlags(from: defaults)
        flags = Set(stored.map(\.scope))
        sessionWorkspaceIds = Dictionary(
            stored.compactMap { flag in flag.workspaceId.map { (flag.scope, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var policy: ScopedLockPolicy {
        ScopedLockPolicy(
            flags: flags,
            unlocks: unlocks,
            generation: appLock.scopedUnlockGeneration,
            appLockEnabled: appLock.isEnabled
        )
    }

    // MARK: - Queries

    func access(_ target: ScopedLockTarget) -> ScopedLockState {
        policy.access(target)
    }

    func badge(_ target: ScopedLockTarget) -> ScopedLockState {
        policy.badge(target)
    }

    func isLocked(_ target: ScopedLockTarget) -> Bool {
        access(target) == .locked
    }

    func isFlagged(_ scope: ScopedLockScope) -> Bool {
        flags.contains(scope)
    }

    func hidesContentOutsideApp(_ target: ScopedLockTarget) -> Bool {
        policy.hidesContentOutsideApp(target)
    }

    /// A session target from ids, filling workspace and incognito state from
    /// the loaded session when the caller does not have it.
    func sessionTarget(serverId: String, sessionId: String, workspaceId: String? = nil) -> ScopedLockTarget {
        let known = sessionLookup(serverId, sessionId)
        return .session(
            serverId: serverId,
            workspaceId: workspaceId ?? known?.workspaceId,
            sessionId: sessionId,
            isIncognito: known?.ephemeral == true
        )
    }

    /// Content whose scope is unknown might be locked: some lock exists, or
    /// App Lock is on (Incognito sessions are locked then).
    var mayLockUnknownScope: Bool {
        !flags.isEmpty || appLock.isEnabled
    }

    /// Something gated was unlocked in this generation, so locked content may
    /// be on screen or playing right now.
    var hasOpenUnlock: Bool {
        let generation = appLock.scopedUnlockGeneration
        return unlocks.values.contains(generation)
    }

    /// A scene going inactive (app switcher, Control Center) covers itself
    /// while an unlock is open, so the switcher snapshot never holds locked
    /// content. Not while a device-auth sheet is up: that sheet makes the
    /// scene inactive too.
    var obscuresInactiveScenes: Bool {
        hasOpenUnlock && !isAuthenticating && !appLock.isAuthenticating
    }

    /// Wraps App Lock's background transition. Returns whether unlocked
    /// content was open, so the backgrounded scene stays covered. When the
    /// transition ends those unlocks (App Lock off, or an immediate lock),
    /// playback stops.
    @discardableResult
    func backgroundTransition(_ transition: () -> Void) -> Bool {
        let wasOpen = hasOpenUnlock
        transition()
        if wasOpen, !hasOpenUnlock {
            stopPlayback()
        }
        return wasOpen
    }

    // MARK: - Gates

    /// Device authentication for `target` unless it is already reachable.
    /// Success unlocks every gated scope in its chain for this generation.
    func authorize(_ target: ScopedLockTarget) async -> Bool {
        let current = policy
        guard current.access(target) == .locked else { return true }
        // One prompt at a time. A request that arrives while a prompt is up
        // (several loaders for one screen) waits for it and opens only if
        // that unlock covers it.
        if let authorization {
            await authorization.value
            return !isLocked(target)
        }
        guard !isAuthenticating else { return false }
        let generation = current.generation
        let reason = Self.reason(for: target, policy: current)
        let task = Task { @MainActor in
            isAuthenticating = true
            defer { isAuthenticating = false }
            guard await appLock.authenticateScopedUnlock(reason: reason) else { return }
            var next = policy
            next.recordUnlock(target, generation: generation)
            unlocks = next.unlocks
        }
        authorization = task
        await task.value
        authorization = nil
        // Oppi left the foreground or locked during the prompt: that unlock
        // belongs to an ended generation.
        return !isLocked(target)
    }

    /// Synchronous gate for navigation: true when `target` is reachable now.
    /// Otherwise asks for authentication and calls `onUnlock` after success;
    /// cancel or failure leaves the caller where it was.
    func gate(_ target: ScopedLockTarget, onUnlock: @escaping @MainActor () -> Void) -> Bool {
        guard isLocked(target) else { return true }
        Task { @MainActor in
            if await authorize(target) { onUnlock() }
        }
        return false
    }

    /// This device just created the session: it stays open for this
    /// generation even when it is gated (Incognito while App Lock is on).
    func noteCreated(_ target: ScopedLockTarget) {
        unlocks[target.scope] = appLock.scopedUnlockGeneration
    }

    // MARK: - Changing locks

    /// Turning a lock on never asks. `unlockedForNow` keeps the item open for
    /// the current generation when the user locks it from inside (settings).
    /// `workspaceId` is a session's workspace, kept for workspace deletion.
    func lock(_ scope: ScopedLockScope, workspaceId: String? = nil, unlockedForNow: Bool = false) {
        guard !flags.contains(scope) else { return }
        flags.insert(scope)
        if case .session = scope, let workspaceId, !workspaceId.isEmpty {
            sessionWorkspaceIds[scope] = workspaceId
        }
        if unlockedForNow {
            unlocks[scope] = appLock.scopedUnlockGeneration
        }
        save()
        didLock()
    }

    /// Turning a lock off always asks for device authentication.
    @discardableResult
    func removeLock(_ scope: ScopedLockScope) async -> Bool {
        guard flags.contains(scope), !isAuthenticating else { return !flags.contains(scope) }
        isAuthenticating = true
        defer { isAuthenticating = false }
        guard await appLock.authenticateScopedUnlock(reason: Self.removeReason(for: scope)) else { return false }
        flags.remove(scope)
        unlocks.removeValue(forKey: scope)
        sessionWorkspaceIds.removeValue(forKey: scope)
        save()
        return true
    }

    // MARK: - Cleanup

    func forgetServer(_ serverId: String) {
        var next = policy
        next.forgetServer(serverId)
        apply(next)
    }

    /// Also forgets the workspace's sessions: every session locked while
    /// recorded in it, plus the listed ids the device still has for it.
    func forgetWorkspace(serverId: String, workspaceId: String, sessionIds: [String] = []) {
        let recorded = sessionWorkspaceIds
            .filter { $0.key.serverId == serverId && $0.value == workspaceId }
            .map(\.key)
        var next = policy
        next.forget([ScopedLockScope.workspace(serverId: serverId, workspaceId: workspaceId)]
            + sessionIds.map { ScopedLockScope.session(serverId: serverId, sessionId: $0) }
            + recorded)
        apply(next)
    }

    func forgetSession(serverId: String, sessionId: String) {
        var next = policy
        next.forget([ScopedLockScope.session(serverId: serverId, sessionId: sessionId)])
        apply(next)
    }

    // MARK: - Private

    private func apply(_ next: ScopedLockPolicy) {
        unlocks = next.unlocks
        guard next.flags != flags else { return }
        flags = next.flags
        sessionWorkspaceIds = sessionWorkspaceIds.filter { next.flags.contains($0.key) }
        save()
    }

    /// One stored lock flag.
    private struct StoredFlag: Codable {
        let scope: ScopedLockScope
        let workspaceId: String?
    }

    private func save() {
        let stored = flags.map { StoredFlag(scope: $0, workspaceId: sessionWorkspaceIds[$0]) }
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.flagsKey)
    }

    private static func loadFlags(from defaults: UserDefaults) -> [StoredFlag] {
        guard let data = defaults.data(forKey: flagsKey),
              let stored = try? JSONDecoder().decode([StoredFlag].self, from: data) else { return [] }
        return stored
    }

    private static func reason(for target: ScopedLockTarget, policy: ScopedLockPolicy) -> String {
        switch policy.gatedScopes(target).first {
        case .server: String(localized: "Unlock this server")
        case .workspace: String(localized: "Unlock this workspace")
        case .session, nil: String(localized: "Unlock this session")
        }
    }

    private static func removeReason(for scope: ScopedLockScope) -> String {
        switch scope {
        case .server: String(localized: "Remove the lock from this server")
        case .workspace: String(localized: "Remove the lock from this workspace")
        case .session: String(localized: "Remove the lock from this session")
        }
    }

    /// A new lock: delivered ask notifications may show its question text,
    /// and the Live Activity its session name; both follow the lock now.
    static func clearContentShownBeforeLock() {
        if ReleaseFeatures.localAttentionNotificationsEnabled {
            AttentionNotificationService.shared.removeAskNotifications()
        }
        if ReleaseFeatures.liveActivitiesEnabled {
            LiveActivityManager.shared.recoverIfNeeded()
        }
    }
}
