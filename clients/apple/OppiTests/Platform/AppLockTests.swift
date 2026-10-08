import Foundation
import Testing
import UserNotifications
@testable import Oppi

// MARK: - State machine

/// Times are seconds on the monotonic clock (`AppLockClock`).
@Suite("AppLockMachine")
struct AppLockMachineTests {
    private let t0: TimeInterval = 10_000

    @Test func coldLaunchIsLockedOnlyWhenAppLockIsOnAndUsable() {
        #expect(AppLockMachine(timeout: .fiveMinutes, isAvailable: true).isLocked)
        #expect(AppLockMachine(timeout: .immediately, isAvailable: true).isLocked)
        #expect(!AppLockMachine(timeout: .off, isAvailable: true).isLocked)
        // No device passcode: App Lock cannot run, so it must not lock the user out.
        #expect(!AppLockMachine(timeout: .fiveMinutes, isAvailable: false).isLocked)
    }

    @Test(arguments: [
        (AppLockTimeout.oneMinute, 60.0),
        (AppLockTimeout.fiveMinutes, 300.0),
        (AppLockTimeout.fifteenMinutes, 900.0),
    ])
    func timedLockIsDueExactlyAtTheTimeout(timeout: AppLockTimeout, seconds: TimeInterval) {
        var early = unlocked(timeout)
        early.didEnterBackground(at: t0)
        #expect(!early.isLocked, "timed values do not lock while backgrounding")
        early.didBecomeActive(at: t0 + seconds - 0.001)
        #expect(!early.isLocked)

        var due = unlocked(timeout)
        due.didEnterBackground(at: t0)
        due.didBecomeActive(at: t0 + seconds)
        #expect(due.isLocked)
    }

    @Test func aWallClockSetBackCannotExtendTheTimeout() {
        // Backgrounded at 10:00 with 5 minutes; at 10:20 the user sets the
        // clock to 10:02. The machine only sees monotonic time, which counted
        // the full 20 minutes.
        var machine = unlocked(.fiveMinutes)
        machine.didEnterBackground(at: t0)
        machine.didBecomeActive(at: t0 + 20 * 60)
        #expect(machine.isLocked)
    }

    @Test func immediatelyLocksAsTheAppBackgrounds() {
        var machine = unlocked(.immediately)
        let generation = machine.scopedUnlockGeneration

        machine.didEnterBackground(at: t0)

        #expect(machine.isLocked, "locked before the app-switcher snapshot")
        #expect(machine.scopedUnlockGeneration == generation + 1)
    }

    @Test func offNeverLocksButEndsScopedUnlocksOnEveryBackground() {
        var machine = AppLockMachine(timeout: .off, isAvailable: true)
        let generation = machine.scopedUnlockGeneration

        machine.didEnterBackground(at: t0)
        machine.didBecomeActive(at: t0 + 3_600)
        machine.didEnterBackground(at: t0 + 3_700)
        machine.didBecomeActive(at: t0 + 3_701)

        #expect(!machine.isLocked)
        #expect(machine.scopedUnlockGeneration == generation + 2)
    }

    @Test func scopedUnlocksSurviveABackgroundShorterThanTheTimeout() {
        var machine = unlocked(.fiveMinutes)
        let generation = machine.scopedUnlockGeneration

        machine.didEnterBackground(at: t0)
        machine.didBecomeActive(at: t0 + 30)

        #expect(!machine.isLocked)
        #expect(machine.scopedUnlockGeneration == generation)
    }

    @Test func inactiveWithoutBackgroundNeverLocks() {
        // Control Center, the app switcher, or the Face ID sheet: inactive -> active.
        var machine = unlocked(.immediately)
        machine.didBecomeActive(at: t0 + 10_000)
        #expect(!machine.isLocked)
    }

    @Test func timeoutCountsFromTheFirstBackgroundAcrossScenes() {
        // iPad: a second background report must not restart the timer.
        var machine = unlocked(.oneMinute)
        machine.didEnterBackground(at: t0)
        machine.didEnterBackground(at: t0 + 50)
        machine.didBecomeActive(at: t0 + 60)
        #expect(machine.isLocked)
    }

    @Test func dueLockIsVisibleToIntentsBeforeTheAppForegrounds() {
        var machine = unlocked(.oneMinute)
        machine.didEnterBackground(at: t0)

        #expect(!machine.requiresUnlock(at: t0 + 59))
        #expect(machine.requiresUnlock(at: t0 + 61))
        #expect(!machine.isLocked, "the cover state itself changes only on foreground")
    }

    @Test func autoPromptHappensOncePerLock() {
        var machine = AppLockMachine(timeout: .fiveMinutes, isAvailable: true)
        let firstPrompt = machine.takeAutoPrompt()
        let repeatPrompt = machine.takeAutoPrompt()
        #expect(firstPrompt)
        #expect(!repeatPrompt)

        let beganAfterPrompt = machine.beginUnlock()
        #expect(beganAfterPrompt)
        machine.finishUnlock(.cancelled)
        let promptAfterCancel = machine.takeAutoPrompt()
        #expect(machine.isLocked)
        #expect(!promptAfterCancel, "after a cancel the cover waits for the Unlock button")

        let beganRetry = machine.beginUnlock()
        #expect(beganRetry)
        machine.finishUnlock(.success)
        machine.didEnterBackground(at: t0)
        machine.didBecomeActive(at: t0 + 300)
        let promptAfterRelock = machine.takeAutoPrompt()
        #expect(promptAfterRelock, "a new lock prompts again")
    }

    @Test func turningOffOrLosingThePasscodeUnlocks() {
        var off = AppLockMachine(timeout: .fiveMinutes, isAvailable: true)
        off.setTimeout(.off)
        #expect(!off.isLocked)

        var noPasscode = AppLockMachine(timeout: .fiveMinutes, isAvailable: true)
        let began = noPasscode.beginUnlock()
        #expect(began)
        noPasscode.finishUnlock(.unavailable)
        #expect(!noPasscode.isLocked)
        #expect(!noPasscode.isEnabled)
    }

    private func unlocked(_ timeout: AppLockTimeout) -> AppLockMachine {
        var machine = AppLockMachine(timeout: timeout, isAvailable: true)
        if machine.beginUnlock() {
            machine.finishUnlock(.success)
        }
        return machine
    }
}

// MARK: - Service

@MainActor
@Suite("AppLockService")
struct AppLockServiceTests {
    @Test func authFailureStaysLockedAndRetryUnlocks() async {
        let harness = Harness(timeout: .fiveMinutes, outcomes: [.failed, .cancelled, .success])

        #expect(await harness.service.unlock() == false)
        #expect(harness.service.isLocked)
        #expect(harness.service.unlockFailed)

        #expect(await harness.service.unlock() == false)
        #expect(harness.service.isLocked)
        #expect(!harness.service.unlockFailed, "a cancel is not reported as a failure")

        #expect(await harness.service.unlock())
        #expect(!harness.service.isLocked)
        #expect(harness.authenticator.calls == 3)
    }

    @Test func onlyAMissingPasscodeTurnsAppLockOff() async {
        // Any other LocalAuthentication error keeps the app locked.
        let glitch = Harness(timeout: .fiveMinutes, outcomes: [.failed], availability: .unavailable)
        #expect(glitch.service.isLocked)
        glitch.service.refreshAvailability()
        #expect(await glitch.service.sceneDidBecomeActive()?.value == false)
        #expect(glitch.service.isLocked)
        #expect(await glitch.service.authorizeProtectedAction(reason: "Remove") == false)

        let noPasscode = Harness(timeout: .fiveMinutes, outcomes: [], availability: .noPasscode)
        #expect(!noPasscode.service.isLocked)
        #expect(!noPasscode.service.isEnabled)
    }

    @Test func coldLaunchAutoPromptsOnceAndCancelDoesNotLoop() async {
        let harness = Harness(timeout: .immediately, outcomes: [.cancelled])

        let prompt = harness.service.sceneDidBecomeActive()
        #expect(await prompt?.value == false)
        // The cancelled sheet makes the scene active again.
        #expect(harness.service.sceneDidBecomeActive() == nil)

        #expect(harness.service.isLocked)
        #expect(harness.authenticator.calls == 1)
    }

    @Test func systemAuthSheetTransitionsDoNotObscureOrRelock() async {
        let harness = Harness(timeout: .immediately, outcomes: [.success])
        var obscuredDuringSheet: Bool?
        var promptStartedDuringSheet: Bool?
        harness.authenticator.duringPrompt = {
            // The Face ID / passcode sheet: scene inactive, then active again.
            obscuredDuringSheet = harness.service.obscuresInactiveScenes
            promptStartedDuringSheet = harness.service.sceneDidBecomeActive() != nil
        }

        let prompt = harness.service.sceneDidBecomeActive()
        #expect(await prompt?.value == true)
        #expect(harness.service.sceneDidBecomeActive() == nil)

        #expect(obscuredDuringSheet == false)
        #expect(promptStartedDuringSheet == false)
        #expect(!harness.service.isLocked)
        #expect(harness.authenticator.calls == 1)
        #expect(harness.service.obscuresInactiveScenes, "after the sheet, inactive obscures again")
    }

    @Test func returningAfterTheTimeoutLocksAndPrompts() async {
        let harness = Harness(timeout: .oneMinute, outcomes: [.success, .success])
        #expect(await harness.service.unlock())

        harness.service.appDidEnterBackground()
        harness.clock.monotonic += 30
        #expect(harness.service.sceneDidBecomeActive() == nil)
        #expect(!harness.service.isLocked)

        harness.service.appDidEnterBackground()
        harness.clock.monotonic += 60
        let prompt = harness.service.sceneDidBecomeActive()
        #expect(harness.service.isLocked)
        #expect(await prompt?.value == true)
        #expect(harness.authenticator.calls == 2)
    }

    @Test func coverAndForegroundIntentShareOneAuthentication() async {
        let harness = Harness(timeout: .fiveMinutes, outcomes: [.success])
        harness.authenticator.suspends = true

        let cover = harness.service.sceneDidBecomeActive()
        let intent = Task { await harness.service.unlock() }
        await harness.authenticator.waitForPrompt()
        harness.authenticator.resume()

        #expect(await cover?.value == true)
        #expect(await intent.value == true)
        #expect(harness.authenticator.calls == 1)
    }

    @Test func lockingStopsPlayback() async {
        let harness = Harness(timeout: .immediately, outcomes: [.success])
        #expect(await harness.service.unlock())
        #expect(harness.playbackStops == 0)

        harness.service.appDidEnterBackground()

        #expect(harness.service.isLocked)
        #expect(harness.playbackStops == 1)
    }

    @Test func turningAppLockOnClearsContentShownWhileItWasOff() {
        let harness = Harness(timeout: .off, outcomes: [])
        harness.service.setTimeout(.fiveMinutes)
        #expect(harness.turnedOn == 1)
        harness.service.setTimeout(.fifteenMinutes)
        #expect(harness.turnedOn == 1, "changing the timeout is not turning it on")
        harness.service.setTimeout(.off)
        harness.service.setTimeout(.immediately)
        #expect(harness.turnedOn == 2)
    }

    @Test func onlyTheLatestLinkWaitsAndOnlyForASuccessfulUnlock() async {
        let harness = Harness(timeout: .oneMinute, outcomes: [.success, .cancelled, .success])
        var handled: [String] = []

        // Locked at cold launch: the latest request wins.
        harness.service.performWhenUnlocked { handled.append("oppi://connect") }
        harness.service.performWhenUnlocked { handled.append("notification tap") }
        #expect(handled.isEmpty)
        #expect(await harness.service.unlock())
        #expect(handled == ["notification tap"])

        // Unlocked: runs at once.
        harness.service.performWhenUnlocked { handled.append("in-app link") }
        #expect(handled.count == 2)

        // Lock due while backgrounded; a link opens Oppi before it activates.
        harness.service.appDidEnterBackground()
        harness.clock.monotonic += 61
        harness.service.performWhenUnlocked { handled.append("oppi://session") }
        _ = harness.service.sceneDidBecomeActive()
        #expect(await harness.service.unlock() == false, "cancelled")
        #expect(await harness.service.unlock())
        #expect(handled.count == 2, "a cancelled unlock drops the waiting link")
    }

    @Test func goingToTheBackgroundDropsTheWaitingLink() async {
        let harness = Harness(timeout: .fiveMinutes, outcomes: [.success])
        var handled = false
        harness.service.performWhenUnlocked { handled = true }

        harness.service.appDidEnterBackground()
        #expect(await harness.service.unlock())

        #expect(!handled)
    }

    @Test func protectedActionsAskOnlyWhileAppLockIsOn() async {
        let off = Harness(timeout: .off, outcomes: [])
        #expect(await off.service.authorizeProtectedAction(reason: "Remove"))
        #expect(off.authenticator.calls == 0)

        let on = Harness(timeout: .fiveMinutes, outcomes: [.success, .cancelled])
        #expect(await on.service.unlock())
        #expect(await on.service.authorizeProtectedAction(reason: "Remove") == false)
        #expect(on.authenticator.calls == 2)
    }

    @Test func timeoutPersistsInTheStoreTheShareExtensionReads() {
        let harness = Harness(timeout: .off, outcomes: [])
        harness.service.setTimeout(.fifteenMinutes)
        #expect(AppLockSettings.timeout(in: harness.defaults) == .fifteenMinutes)
        #expect(AppLockService(defaults: harness.defaults, availability: { .available }).timeout == .fifteenMinutes)
    }
}

// MARK: - Out-of-app entry points

@MainActor
@Suite("App Lock intent gate")
struct AppLockIntentGateTests {
    @Test func dueLockUnlocksInTheAppBeforeAnyWork() async {
        let harness = Harness(timeout: .oneMinute, outcomes: [.success, .cancelled, .success])
        #expect(await harness.service.unlock())
        harness.service.appDidEnterBackground()
        harness.clock.monotonic += 61

        var events: [String] = []
        harness.authenticator.duringPrompt = { events.append("auth") }
        let cancelled = await AppLockIntentGate.unlockIfNeeded(
            service: harness.service,
            continueInForeground: { events.append("foreground") },
            waitUntilActive: {}
        )
        if cancelled { events.append("work") }
        #expect(!cancelled, "a cancelled unlock must not create a session")
        #expect(events == ["foreground", "auth"])

        let unlocked = await AppLockIntentGate.unlockIfNeeded(
            service: harness.service,
            continueInForeground: { events.append("foreground") },
            waitUntilActive: {}
        )
        if unlocked { events.append("work") }
        #expect(events == ["foreground", "auth", "foreground", "auth", "work"])
    }

    @Test func insideTheTimeoutIntentsBehaveAsUnlocked() async {
        let harness = Harness(timeout: .fiveMinutes, outcomes: [.success])
        #expect(await harness.service.unlock())
        harness.service.appDidEnterBackground()
        harness.clock.monotonic += 120

        var cameForward = false
        let allowed = await AppLockIntentGate.unlockIfNeeded(
            service: harness.service,
            continueInForeground: { cameForward = true },
            waitUntilActive: {}
        )

        #expect(allowed)
        #expect(!cameForward)
        #expect(harness.authenticator.calls == 1, "only the initial unlock prompted")
    }

    @Test func refusingToComeForwardSendsNothing() async {
        let harness = Harness(timeout: .immediately, outcomes: [])
        struct Refused: Error {}
        let allowed = await AppLockIntentGate.unlockIfNeeded(
            service: harness.service,
            continueInForeground: { throw Refused() },
            waitUntilActive: {}
        )
        #expect(!allowed)
        #expect(harness.authenticator.calls == 0)
    }
}

@Suite("App Lock share extension")
struct AppLockShareExtensionTests {
    @Test func shareAsksEveryTimeWhileAppLockIsOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "AppLockShare-\(UUID().uuidString)"))
        #expect(!AppLockSettings.shareRequiresAuthentication(in: defaults), "default is Off")
        for timeout in AppLockTimeout.allCases {
            AppLockSettings.setTimeout(timeout, in: defaults)
            #expect(AppLockSettings.shareRequiresAuthentication(in: defaults) == (timeout != .off))
        }
    }
}

// MARK: - Redaction

@MainActor
@Suite("App Lock redaction")
struct AppLockRedactionTests {
    @Test func liveActivityNeverShowsSessionTextWhileAppLockIsOn() {
        let unlockedOff = LiveActivityManager(hidesSessionText: { false })
        unlockedOff.sync(connectionId: "c1", sessions: [makeTestSession(id: "s1", name: "Secret plan", status: .busy)])
        #expect(unlockedOff.currentState.primarySessionName == "Secret plan", "App Lock off shows the name")

        let manager = LiveActivityManager(hidesSessionText: { true })
        manager.sync(connectionId: "c1", sessions: [makeTestSession(id: "s1", name: "Secret plan", status: .busy)])
        manager.recordEvent(connectionId: "c1", event: .toolStart(
            sessionId: "s1", toolEventId: "t1", tool: "bash", args: [:]
        ))

        #expect(manager.currentState.primaryPhase == .working)
        #expect(manager.currentState.totalActiveSessions == 1)
        #expect(manager.currentState.primarySessionName == "Oppi")
        #expect(manager.currentState.primaryTool == nil)
        #expect(manager.currentState.primaryLastActivity == String(localized: "Working"))
    }

    @Test func turningAppLockOnRemovesOnlyAskNotifications() {
        func request(_ identifier: String, category: String) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.categoryIdentifier = category
            content.body = "Rotate the prod key?"
            return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        }
        let requests = [
            request("ask-s1", category: AttentionNotificationPolicy.askCategoryId),
            request("done-s1", category: AttentionNotificationPolicy.sessionDoneCategoryId),
            request("ask-s2", category: AttentionNotificationPolicy.askCategoryId),
        ]

        #expect(AttentionNotificationService.askIdentifiers(in: requests) == ["ask-s1", "ask-s2"])
    }

    @Test func askNotificationHidesQuestionTextWhileAppLockIsOn() {
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [AskQuestion(id: "q1", question: "Deploy the secret branch?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )

        let payload = AttentionNotificationPolicy.askPayload(for: ask, revealsQuestionText: false)

        #expect(payload.body == String(localized: "Open Oppi to answer a question."))
        #expect(![payload.title, payload.subtitle, payload.body].contains { $0.contains("secret") })
    }
}

@MainActor
@Suite("App Lock content races")
struct AppLockContentRaceTests {
    @Test func onceTheLockIsDueNothingPlaysOrResumes() {
        let lock = Flag()
        let player = AudioPlayerService(appLockBlocksPlayback: { lock.value })
        #expect(player.shouldAutoplayAudioMessage(itemID: "v1", playbackBehavior: .playNow))
        player._startPCMStreamForTesting(id: "before")
        player.pause()

        lock.value = true
        player.resume()
        #expect(player.isPaused, "the Lock Screen play command cannot resume")
        #expect(!player.shouldAutoplayAudioMessage(itemID: "v2", playbackBehavior: .playNow))
        player.stop()
        player._startPCMStreamForTesting(id: "after")
        #expect(player.playingItemID == nil, "no new voice stream")
        player.toggleDataPlayback(data: Data([0, 1, 2]), itemID: "clip")
        #expect(player.playingItemID == nil)
        #expect(player.loadingItemID == nil)
    }

    @Test func anAskQueuedWhileAppLockTurnsOnIsAddedRedacted() async {
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
        service._skipSchedulingForTesting = false
        service._appLockEnabledForTesting = false
        let ask = AskRequest(
            id: "ask-race",
            sessionId: "s-race",
            questions: [AskQuestion(id: "q1", question: "Rotate the prod key?", options: [], multiSelect: false)],
            allowCustom: true,
            timeout: nil
        )

        let delivered: (identifier: String, body: String) = await withCheckedContinuation { continuation in
            service._deliverForTesting = { continuation.resume(returning: ($0.identifier, $0.content.body)) }
            service.notifyAskIfNeeded(ask, activeSessionId: nil, hidesQuestionText: { false })
            // App Lock turns on after the ask was queued, before it is added.
            service._appLockEnabledForTesting = true
        }

        #expect(delivered.identifier == "ask-s-race")
        #expect(delivered.body == String(localized: "Open Oppi to answer a question."))
    }

    @Test func turningAppLockOnRedactsTheLiveActivityAndInFlightUpdates() {
        let lock = Flag()
        let manager = LiveActivityManager(hidesSessionText: { lock.value })
        manager.sync(connectionId: "c1", sessions: [makeTestSession(id: "s1", name: "Secret plan", status: .busy)])
        let queued = manager.currentState
        #expect(queued.primarySessionName == "Secret plan")

        lock.value = true
        manager.endAllForAppLock()

        #expect(manager.currentState.primarySessionName == "Oppi")
        // An update queued before the switch is re-checked before delivery.
        let delivered = LiveActivityManager.stateForDelivery(queued, hidesSessionText: true)
        #expect(delivered.primarySessionName == "Oppi")
        #expect(delivered.primaryTool == nil)
        #expect(delivered.totalActiveSessions == queued.totalActiveSessions)
    }
}

// MARK: - Test doubles

@MainActor
private final class Flag {
    var value = false
}

@MainActor
private final class TestClock {
    /// Monotonic seconds; the only time App Lock reads.
    var monotonic: TimeInterval = 10_000
}

@MainActor
private final class StubAuthenticator {
    var outcomes: [DeviceOwnerAuthentication.Outcome]
    private(set) var calls = 0
    var duringPrompt: (() -> Void)?
    var suspends = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var promptWaiter: CheckedContinuation<Void, Never>?

    init(outcomes: [DeviceOwnerAuthentication.Outcome]) {
        self.outcomes = outcomes
    }

    func authenticate() async -> DeviceOwnerAuthentication.Outcome {
        calls += 1
        duringPrompt?()
        if suspends {
            promptWaiter?.resume()
            promptWaiter = nil
            await withCheckedContinuation { continuation = $0 }
        }
        return outcomes.isEmpty ? .failed : outcomes.removeFirst()
    }

    func waitForPrompt() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { promptWaiter = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class HookCounts {
    var playbackStops = 0
    var turnedOn = 0
}

@MainActor
private struct Harness {
    let clock: TestClock
    let authenticator: StubAuthenticator
    let defaults: UserDefaults
    let service: AppLockService
    private let hooks: HookCounts

    var playbackStops: Int { hooks.playbackStops }
    var turnedOn: Int { hooks.turnedOn }

    init(
        timeout: AppLockTimeout,
        outcomes: [DeviceOwnerAuthentication.Outcome],
        availability: DeviceOwnerAuthentication.Availability = .available
    ) {
        guard let defaults = UserDefaults(suiteName: "AppLockTests-\(UUID().uuidString)") else {
            preconditionFailure("isolated UserDefaults suite")
        }
        AppLockSettings.setTimeout(timeout, in: defaults)
        let clock = TestClock()
        self.clock = clock
        let authenticator = StubAuthenticator(outcomes: outcomes)
        self.authenticator = authenticator
        self.defaults = defaults
        let hooks = HookCounts()
        self.hooks = hooks
        service = AppLockService(
            defaults: defaults,
            monotonicNow: { clock.monotonic },
            availability: { availability },
            method: { .faceID },
            authenticator: { _ in await authenticator.authenticate() },
            stopPlayback: { hooks.playbackStops += 1 },
            didTurnOn: { hooks.turnedOn += 1 }
        )
    }
}
