import Foundation
import Testing
import UserNotifications
@testable import Oppi

// MARK: - Rules

@Suite("Scoped lock rules")
struct ScopedLockPolicyTests {
    private let server = ScopedLockTarget.server("srv")
    private let workspace = ScopedLockTarget.workspace(serverId: "srv", workspaceId: "w1")
    private let session = ScopedLockTarget.session(serverId: "srv", workspaceId: "w1", sessionId: "s1", isIncognito: false)
    private let otherServerSession = ScopedLockTarget.session(
        serverId: "other", workspaceId: "w1", sessionId: "s1", isIncognito: false
    )

    private func policy(
        _ flags: Set<ScopedLockScope>,
        unlocks: [ScopedLockScope: Int] = [:],
        generation: Int = 3,
        appLockEnabled: Bool = false
    ) -> ScopedLockPolicy {
        ScopedLockPolicy(flags: flags, unlocks: unlocks, generation: generation, appLockEnabled: appLockEnabled)
    }

    @Test func nothingFlaggedIsNeverGated() {
        let rules = policy([])
        for target in [server, workspace, session] {
            #expect(rules.access(target) == .none)
            #expect(rules.badge(target) == .none)
            #expect(!rules.hidesContentOutsideApp(target))
        }
    }

    @Test func aLockedServerGatesEverythingUnderItAndOnlyThatServer() {
        let rules = policy([.server(serverId: "srv")])

        #expect(rules.access(server) == .locked)
        #expect(rules.access(workspace) == .locked)
        #expect(rules.access(session) == .locked)
        #expect(rules.access(otherServerSession) == .none, "flags are keyed by server identity")
    }

    @Test func aLockedWorkspaceGatesItsSessionsButNotItsServer() {
        let rules = policy([.workspace(serverId: "srv", workspaceId: "w1")])

        #expect(rules.access(server) == .none)
        #expect(rules.access(workspace) == .locked)
        #expect(rules.access(session) == .locked)
        #expect(rules.access(.session(serverId: "srv", workspaceId: "w2", sessionId: "s2", isIncognito: false)) == .none)
    }

    @Test func unlockingAParentCoversLockedChildren() {
        let flags: Set<ScopedLockScope> = [
            .server(serverId: "srv"),
            .workspace(serverId: "srv", workspaceId: "w1"),
            .session(serverId: "srv", sessionId: "s1"),
        ]
        let serverUnlocked = policy(flags, unlocks: [.server(serverId: "srv"): 3])

        #expect(serverUnlocked.access(workspace) == .unlocked)
        #expect(serverUnlocked.access(session) == .unlocked)
    }

    @Test func unlockingAChildDoesNotOpenALockedParent() {
        var rules = policy([.server(serverId: "srv"), .session(serverId: "srv", sessionId: "s1")])
        rules.unlocks[.session(serverId: "srv", sessionId: "s1")] = 3

        #expect(rules.access(session) == .locked, "the server lock still applies")
        #expect(rules.access(server) == .locked)
    }

    @Test func authenticatingForATargetUnlocksEveryGatedScopeOnItsPath() {
        var rules = policy([.workspace(serverId: "srv", workspaceId: "w1"), .session(serverId: "srv", sessionId: "s1")])

        rules.recordUnlock(session, generation: 3)

        #expect(rules.access(session) == .unlocked)
        #expect(rules.access(workspace) == .unlocked)
        // Siblings in the unlocked workspace open too; the server was never locked.
        #expect(rules.access(.session(serverId: "srv", workspaceId: "w1", sessionId: "s9", isIncognito: false)) == .unlocked)
    }

    @Test func anUnlockFromAnEarlierGenerationNoLongerCounts() {
        let rules = policy([.session(serverId: "srv", sessionId: "s1")], unlocks: [.session(serverId: "srv", sessionId: "s1"): 2])

        #expect(rules.access(session) == .locked)
    }

    @Test func incognitoIsGatedOnlyWhileAppLockIsOn() {
        let incognito = ScopedLockTarget.session(serverId: "srv", workspaceId: "w1", sessionId: "s1", isIncognito: true)

        #expect(policy([], appLockEnabled: true).access(incognito) == .locked)
        #expect(policy([], appLockEnabled: true).badge(incognito) == .locked)
        #expect(policy([], appLockEnabled: false).access(incognito) == .none)
        #expect(policy([], unlocks: [incognito.scope: 3], appLockEnabled: true).access(incognito) == .unlocked)
    }

    @Test func badgesShowLockedOnEveryHiddenItemAndUnlockedOnlyOnTheItemThatCarriesTheLock() {
        let locked = policy([.workspace(serverId: "srv", workspaceId: "w1")])
        #expect(locked.badge(workspace) == .locked)
        #expect(locked.badge(session) == .locked, "a session hidden by its workspace shows the lock")

        let unlocked = policy([.workspace(serverId: "srv", workspaceId: "w1")], unlocks: [.workspace(serverId: "srv", workspaceId: "w1"): 3])
        #expect(unlocked.badge(workspace) == .unlocked)
        #expect(unlocked.badge(session) == .none, "an unlocked workspace does not badge every session")
    }

    @Test func notificationsAndLiveActivitiesHideTextForAnythingGatedEvenWhileUnlocked() {
        let rules = policy([.workspace(serverId: "srv", workspaceId: "w1")], unlocks: [.workspace(serverId: "srv", workspaceId: "w1"): 3])

        #expect(rules.access(session) == .unlocked)
        #expect(rules.hidesContentOutsideApp(session), "a banner outlives the unlock")
        #expect(!rules.hidesContentOutsideApp(server))
    }

    @Test func removingAServerForgetsItsFlagsAndUnlocksOnly() {
        var rules = policy(
            [.server(serverId: "srv"), .workspace(serverId: "srv", workspaceId: "w1"), .session(serverId: "other", sessionId: "s1")],
            unlocks: [.server(serverId: "srv"): 3]
        )

        rules.forgetServer("srv")

        #expect(rules.flags == [.session(serverId: "other", sessionId: "s1")])
        #expect(rules.unlocks.isEmpty)
    }
}

// MARK: - Service

@MainActor
@Suite("Scoped lock service")
struct ScopedLockServiceTests {
    private let session = ScopedLockTarget.session(serverId: "srv", workspaceId: "w1", sessionId: "s1", isIncognito: false)

    @Test func cancelledAuthenticationKeepsTheTargetLocked() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.cancelled])
        harness.locks.lock(.session(serverId: "srv", sessionId: "s1"))

        #expect(await !harness.locks.authorize(session))
        #expect(harness.locks.isLocked(session))
        #expect(harness.prompts == 1)
    }

    @Test func scopedLocksAskEvenWithAppLockOffAndLastUntilOppiLeavesTheForeground() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.success])
        harness.locks.lock(.session(serverId: "srv", sessionId: "s1"))

        #expect(await harness.locks.authorize(session))
        #expect(harness.locks.access(session) == .unlocked)
        #expect(await harness.locks.authorize(session), "no second prompt in the same generation")
        #expect(harness.prompts == 1)

        harness.appLock.appDidEnterBackground()
        harness.appLock.sceneDidBecomeActive()

        #expect(harness.locks.isLocked(session))
    }

    @Test func scopedUnlocksEndWhenTheAppLocks() async {
        let harness = ScopedHarness(appLock: .immediately, outcomes: [.success, .success])
        #expect(await harness.appLock.unlock())
        harness.locks.lock(.workspace(serverId: "srv", workspaceId: "w1"))
        #expect(await harness.locks.authorize(session))
        #expect(harness.locks.access(session) == .unlocked)

        harness.appLock.appDidEnterBackground()

        #expect(harness.appLock.isLocked)
        #expect(harness.locks.isLocked(session))
        // Never prompts behind the App Lock cover.
        #expect(await !harness.locks.authorize(session))
        #expect(harness.prompts == 2)
    }

    @Test func anUnlockThatFinishesAfterOppiLeftTheForegroundDoesNotCount() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.success])
        harness.locks.lock(.session(serverId: "srv", sessionId: "s1"))
        harness.authenticator.duringPrompt = { harness.appLock.appDidEnterBackground() }

        #expect(await !harness.locks.authorize(session))
        #expect(harness.locks.isLocked(session))
    }

    @Test func requestsWhileAPromptIsUpShareItInsteadOfFailing() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.success])
        harness.locks.lock(.workspace(serverId: "srv", workspaceId: "w1"))
        harness.locks.lock(.workspace(serverId: "srv", workspaceId: "w2"))
        let workspace = ScopedLockTarget.workspace(serverId: "srv", workspaceId: "w1")
        harness.authenticator.holdsPrompt = true

        // Quick Session's loaders all ask for the same workspace at once.
        let locks = harness.locks
        let first = Task { await locks.authorize(workspace) }
        while harness.prompts == 0 { await Task.yield() }
        let second = Task { await locks.authorize(session) }
        let third = Task { await locks.authorize(.workspace(serverId: "srv", workspaceId: "w2")) }
        for _ in 0..<20 { await Task.yield() }
        harness.authenticator.releasePrompt()
        let results = await [first.value, second.value, third.value]

        // The one prompt unlocked w1: w1 and its session open; w2 stays locked.
        #expect(results == [true, true, false])
        #expect(harness.prompts == 1)
    }

    @Test func turningALockOnNeverAsksAndTurningItOffAlwaysDoes() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.cancelled, .success])
        let scope = ScopedLockScope.workspace(serverId: "srv", workspaceId: "w1")

        harness.locks.lock(scope, unlockedForNow: true)
        #expect(harness.prompts == 0)
        #expect(harness.locks.access(session) == .unlocked, "settings that just turned it on stay open")

        #expect(await !harness.locks.removeLock(scope))
        #expect(harness.locks.isFlagged(scope), "cancel keeps the lock")
        #expect(await harness.locks.removeLock(scope))
        #expect(!harness.locks.isFlagged(scope))
        #expect(harness.prompts == 2)
    }

    @Test func flagsPersistOnThisDeviceAndAreForgottenWithTheirServerWorkspaceOrSession() {
        let harness = ScopedHarness(appLock: .off, outcomes: [])
        harness.locks.lock(.server(serverId: "gone"))
        harness.locks.lock(.workspace(serverId: "srv", workspaceId: "w1"))
        harness.locks.lock(.session(serverId: "srv", sessionId: "in-w1"))
        harness.locks.lock(.session(serverId: "srv", sessionId: "s2"))
        harness.locks.lock(.session(serverId: "srv", sessionId: "s3"))

        harness.locks.forgetServer("gone")
        harness.locks.forgetWorkspace(serverId: "srv", workspaceId: "w1", sessionIds: ["in-w1"])
        harness.locks.forgetSession(serverId: "srv", sessionId: "s2")

        let reloaded = ScopedLockService(defaults: harness.defaults, appLock: harness.appLock, didLock: {})
        #expect(reloaded.flags == [.session(serverId: "srv", sessionId: "s3")])
    }

    @Test func aSessionThisDeviceCreatedOpensWithoutAskingEvenWhenIncognito() {
        let harness = ScopedHarness(appLock: .immediately, outcomes: [])
        let incognito = ScopedLockTarget.session(serverId: "srv", workspaceId: "w1", sessionId: "new", isIncognito: true)
        #expect(harness.locks.isLocked(incognito))

        harness.locks.noteCreated(incognito)

        #expect(harness.locks.access(incognito) == .unlocked)
    }

    @Test func aLockedWorkspaceHidesItsSessionNameFromTheLiveActivity() {
        let harness = ScopedHarness(appLock: .off, outcomes: [])
        let locks = harness.locks
        let manager = LiveActivityManager(
            hidesSessionText: { false },
            hidesScopedSessionText: { locks.hidesContentOutsideApp($0) }
        )
        manager.sync(connectionId: "srv", sessions: [
            makeTestSession(id: "s1", workspaceId: "w1", name: "Secret plan", status: .busy),
        ])
        #expect(manager.currentState.primarySessionName == "Secret plan")

        locks.lock(.workspace(serverId: "srv", workspaceId: "w1"))
        manager.recoverIfNeeded()

        #expect(manager.currentState.primarySessionName == "Oppi")
        #expect(manager.currentState.primaryPhase == .working)
    }
}

// MARK: - Surfaces outside the open screen

@MainActor
@Suite("Scoped lock surfaces", .serialized)
struct ScopedLockSurfaceTests {
    @Test func aLiveActivityUpdateQueuedBeforeALockIsDeliveredRedacted() {
        let harness = ScopedHarness(appLock: .off, outcomes: [])
        let locks = harness.locks
        let manager = LiveActivityManager(
            hidesSessionText: { false },
            hidesScopedSessionText: { locks.hidesContentOutsideApp($0) }
        )
        manager.sync(connectionId: "srv", sessions: [
            makeTestSession(id: "s1", workspaceId: "w1", name: "Secret plan", status: .busy),
        ])
        let queued = manager.currentState
        #expect(manager.deliveryState(for: queued).primarySessionName == "Secret plan")

        // The lock lands after the update was queued, before it is delivered.
        locks.lock(.session(serverId: "srv", sessionId: "s1"), workspaceId: "w1")

        let delivered = manager.deliveryState(for: queued)
        #expect(delivered.primarySessionName == "Oppi")
        #expect(delivered.primaryTool == nil)
        #expect(delivered.totalActiveSessions == queued.totalActiveSessions)
    }

    @Test func aWorkspaceAttentionRefreshNeverPutsALockedQuestionInANotification() async throws {
        let harness = ScopedHarness(appLock: .off, outcomes: [])
        let conn = ServerConnection()
        _ = conn.configure(credentials: makeTestCredentials(fingerprint: "sha256:scoped-srv"))
        let serverId = try #require(conn.currentServerId)
        conn.scopedLocks = harness.locks
        conn.sessionStore.upsert(makeTestSession(id: "s2", workspaceId: "w1"))
        harness.locks.lock(.workspace(serverId: serverId, workspaceId: "w1"))

        func ask(_ id: String) -> AskRequest {
            AskRequest(
                id: id,
                sessionId: "s2",
                questions: [AskQuestion(id: "q", question: "Rotate the prod key?", options: [], multiSelect: false)],
                allowCustom: true,
                timeout: nil,
                workspaceId: "w1"
            )
        }

        let service = AttentionNotificationService.shared
        let previousState = service._applicationStateForTesting
        let previousSkip = service._skipSchedulingForTesting
        defer {
            service._applicationStateForTesting = previousState
            service._skipSchedulingForTesting = previousSkip
            service._deliverForTesting = nil
            service._appLockEnabledForTesting = nil
        }
        service._applicationStateForTesting = .background
        service._appLockEnabledForTesting = false
        service._skipSchedulingForTesting = true
        conn.storeAskRequest(ask("a1"), for: "s2", isFocusedSession: false)
        conn.storeAskRequest(ask("a2"), for: "s2", isFocusedSession: false)
        service._skipSchedulingForTesting = false

        let body: String? = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            service._deliverForTesting = { once.resume($0.content.body) }
            // The snapshot drops a1, so a2 is announced again.
            conn.applyWorkspaceAttentionSnapshot(
                APIClient.WorkspaceAttentionResponse(workspaceId: "w1", serverNow: 0, attention: .init(asks: [ask("a2")]))
            )
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                once.resume(nil)
            }
        }

        #expect(body == String(localized: "Open Oppi to answer a question."))
    }

    @Test func anOpenUnlockCoversTheSwitcherUntilOppiLeavesWithAppLockOff() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.success])
        harness.locks.lock(.session(serverId: "srv", sessionId: "s1"))
        #expect(!harness.locks.obscuresInactiveScenes, "nothing open, nothing to cover")
        #expect(await harness.locks.authorize(.session(serverId: "srv", workspaceId: nil, sessionId: "s1", isIncognito: false)))
        #expect(harness.locks.obscuresInactiveScenes)

        harness.appLock.appDidEnterBackground()

        #expect(!harness.locks.hasOpenUnlock, "leaving Oppi ended the unlock")
    }

    @Test func theSwitcherIsNotCoveredWhileTheDeviceAuthSheetIsUp() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.success])
        harness.locks.noteCreated(.session(serverId: "srv", workspaceId: nil, sessionId: "open", isIncognito: false))
        harness.locks.lock(.session(serverId: "srv", sessionId: "s1"))
        var coveredDuringPrompt: Bool?
        harness.authenticator.duringPrompt = { coveredDuringPrompt = harness.locks.obscuresInactiveScenes }

        _ = await harness.locks.authorize(.session(serverId: "srv", workspaceId: nil, sessionId: "s1", isIncognito: false))

        #expect(coveredDuringPrompt == false)
    }

    @Test func deletingAWorkspaceForgetsSessionLocksTheDeviceNoLongerLists() {
        let harness = ScopedHarness(appLock: .off, outcomes: [])
        harness.locks.lock(.session(serverId: "srv", sessionId: "old-archived"), workspaceId: "w1")
        harness.locks.lock(.session(serverId: "srv", sessionId: "elsewhere"), workspaceId: "w2")

        harness.locks.forgetWorkspace(serverId: "srv", workspaceId: "w1")

        let reloaded = ScopedLockService(defaults: harness.defaults, appLock: harness.appLock, didLock: {})
        #expect(reloaded.flags == [.session(serverId: "srv", sessionId: "elsewhere")])
        reloaded.forgetWorkspace(serverId: "srv", workspaceId: "w2")
        #expect(reloaded.flags.isEmpty, "the recorded workspace survives a reload")
    }
}

// MARK: - Siri and Shortcuts

@MainActor
@Suite("Scoped lock intent gate")
struct ScopedLockIntentGateTests {
    private let target = ScopedLockTarget.workspace(serverId: "srv", workspaceId: "w1")

    @Test func anOpenWorkspaceNeedsNoPromptAndNoForeground() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [])
        var foregrounded = false

        let allowed = await AppLockIntentGate.authorizeScope(
            target,
            locks: harness.locks,
            isActive: { false },
            continueInForeground: { foregrounded = true },
            waitUntilActive: {}
        )

        #expect(allowed)
        #expect(!foregrounded)
        #expect(harness.prompts == 0)
    }

    @Test func aLockedWorkspaceSendsNothingWhenOppiCannotComeForward() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.success])
        harness.locks.lock(.workspace(serverId: "srv", workspaceId: "w1"))

        let allowed = await AppLockIntentGate.authorizeScope(
            target,
            locks: harness.locks,
            isActive: { false },
            continueInForeground: { throw CancellationError() },
            waitUntilActive: {}
        )

        #expect(!allowed)
        #expect(harness.prompts == 0, "no prompt from the background")
    }

    @Test func aLockedServerAsksInTheForegroundAndCancelSendsNothing() async {
        let harness = ScopedHarness(appLock: .off, outcomes: [.cancelled, .success])
        harness.locks.lock(.server(serverId: "srv"))
        var foregrounded = 0

        let cancelled = await AppLockIntentGate.authorizeScope(
            target,
            locks: harness.locks,
            isActive: { false },
            continueInForeground: { foregrounded += 1 },
            waitUntilActive: {}
        )
        let approved = await AppLockIntentGate.authorizeScope(
            target,
            locks: harness.locks,
            isActive: { true },
            continueInForeground: { foregrounded += 1 },
            waitUntilActive: {}
        )

        #expect(!cancelled)
        #expect(approved)
        #expect(foregrounded == 1)
        #expect(harness.prompts == 2)
    }
}

// MARK: - Test doubles

/// Resumes a continuation once; later calls are ignored.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<String?, Never>?

    init(_ continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: String?) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
private final class ScopedAuthenticator {
    var outcomes: [DeviceOwnerAuthentication.Outcome]
    private(set) var calls = 0
    var duringPrompt: (() -> Void)?

    init(outcomes: [DeviceOwnerAuthentication.Outcome]) {
        self.outcomes = outcomes
    }

    var holdsPrompt = false
    private var heldPrompt: CheckedContinuation<Void, Never>?

    func authenticate() async -> DeviceOwnerAuthentication.Outcome {
        calls += 1
        duringPrompt?()
        if holdsPrompt {
            await withCheckedContinuation { heldPrompt = $0 }
        }
        return outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }

    func releasePrompt() {
        holdsPrompt = false
        heldPrompt?.resume()
        heldPrompt = nil
    }
}

@MainActor
private struct ScopedHarness {
    let defaults: UserDefaults
    let appLock: AppLockService
    let locks: ScopedLockService
    let authenticator: ScopedAuthenticator

    var prompts: Int { authenticator.calls }

    init(appLock timeout: AppLockTimeout, outcomes: [DeviceOwnerAuthentication.Outcome]) {
        guard let defaults = UserDefaults(suiteName: "ScopedLockTests-\(UUID().uuidString)") else {
            preconditionFailure("isolated UserDefaults suite")
        }
        AppLockSettings.setTimeout(timeout, in: defaults)
        self.defaults = defaults
        let authenticator = ScopedAuthenticator(outcomes: outcomes)
        self.authenticator = authenticator
        let clock = ScopedClock()
        appLock = AppLockService(
            defaults: defaults,
            monotonicNow: { clock.now },
            availability: { .available },
            method: { .faceID },
            authenticator: { _ in await authenticator.authenticate() },
            didTurnOn: {}
        )
        locks = ScopedLockService(defaults: defaults, appLock: appLock, didLock: {})
    }
}

@MainActor
private final class ScopedClock {
    var now: TimeInterval = 10_000
}
