import Foundation
import Testing
@testable import Oppi

/// A clock the test advances by hand, so no test waits on real time.
@MainActor
final class ManualNoticeClock {
    private struct Sleeper {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let origin = ContinuousClock().now
    private var elapsed: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var nextID = 0

    /// Every duration a timer asked to sleep, in order.
    private(set) var requested: [Duration] = []
    var voiceOverRunning = false
    private(set) var announcements: [String] = []

    var sleeperCount: Int { sleepers.count }

    var environment: NoticeTimerEnvironment {
        NoticeTimerEnvironment(
            now: { [self] in origin + elapsed },
            sleep: { [self] in try await sleep($0) },
            isVoiceOverRunning: { [self] in voiceOverRunning },
            announce: { [self] in announcements.append($0) }
        )
    }

    func advance(by duration: Duration) {
        elapsed += duration
        let due = sleepers.filter { $0.deadline <= elapsed }
        sleepers.removeAll { sleeper in due.contains { $0.id == sleeper.id } }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers.append(Sleeper(id: id, deadline: elapsed + duration, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [self] in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
                sleepers.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Waits until `count` timers are asleep on this clock.
    func waitForSleepers(_ count: Int) async -> Bool {
        await waitForMainActorCondition { sleeperCount == count }
    }
}

@MainActor
@Suite("Notice dismiss timer")
struct NoticeDismissTimerTests {
    private func makeTimer(
        _ clock: ManualNoticeClock,
        expired: @escaping (String) -> Void
    ) -> NoticeDismissTimer<String> {
        NoticeDismissTimer(environment: clock.environment, onExpire: expired)
    }

    @Test func expiresAfterTheFixedDuration() async {
        let clock = ManualNoticeClock()
        var expired: [String] = []
        let timer = makeTimer(clock) { expired.append($0) }

        timer.start("a")
        #expect(await clock.waitForSleepers(1))
        #expect(clock.requested == [NoticeDismiss.duration])

        clock.advance(by: NoticeDismiss.duration - .milliseconds(1))
        #expect(expired.isEmpty)
        clock.advance(by: .milliseconds(1))
        #expect(await waitForMainActorCondition { expired == ["a"] })
    }

    @Test func startAgainRestartsTheFullDuration() async {
        let clock = ManualNoticeClock()
        var expired: [String] = []
        let timer = makeTimer(clock) { expired.append($0) }

        timer.start("a")
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(4))
        timer.start("a")
        #expect(await waitForMainActorCondition { clock.requested.count == 2 })
        #expect(await clock.waitForSleepers(1), "the first sleep was cancelled")
        #expect(clock.requested == [NoticeDismiss.duration, NoticeDismiss.duration])

        clock.advance(by: .seconds(5))
        #expect(expired.isEmpty)
        clock.advance(by: .seconds(1))
        #expect(await waitForMainActorCondition { expired == ["a"] })
    }

    @Test func pauseHoldsTheRemainingTimeAndResumeContinuesIt() async {
        let clock = ManualNoticeClock()
        var expired: [String] = []
        let timer = makeTimer(clock) { expired.append($0) }

        timer.start("a")
        #expect(await clock.waitForSleepers(1))
        clock.advance(by: .seconds(2))
        timer.setPaused(true, for: "a")
        #expect(await clock.waitForSleepers(0))

        clock.advance(by: .seconds(600))
        #expect(expired.isEmpty)

        timer.setPaused(false, for: "a")
        #expect(await clock.waitForSleepers(1))
        #expect(clock.requested.last == .seconds(4))
        clock.advance(by: .seconds(4))
        #expect(await waitForMainActorCondition { expired == ["a"] })
    }

    @Test func pauseSurvivesAReplacementUntilCancelled() async {
        let clock = ManualNoticeClock()
        var expired: [String] = []
        let timer = makeTimer(clock) { expired.append($0) }

        timer.setPaused(true, for: "a")
        timer.start("a")
        #expect(await clock.waitForSleepers(0))
        #expect(clock.requested.isEmpty)

        timer.setPaused(false, for: "a")
        #expect(await clock.waitForSleepers(1))
        #expect(clock.requested == [NoticeDismiss.duration])

        timer.cancel("a")
        timer.start("a")
        timer.cancel("a")
        timer.start("a")
        #expect(await clock.waitForSleepers(1), "cancel clears the pause, so a new notice runs")
    }

    @Test func explicitDismissStopsTheTimer() async {
        let clock = ManualNoticeClock()
        var expired: [String] = []
        let timer = makeTimer(clock) { expired.append($0) }

        timer.start("a")
        timer.start("b")
        #expect(await clock.waitForSleepers(2))
        timer.cancel("a")
        #expect(await clock.waitForSleepers(1))

        clock.advance(by: NoticeDismiss.duration)
        #expect(await waitForMainActorCondition { expired == ["b"] })
    }

    @Test func voiceOverKeepsANoticeWithAnActionAndAnnouncesIt() async {
        let clock = ManualNoticeClock()
        clock.voiceOverRunning = true
        var expired: [String] = []
        let timer = makeTimer(clock) { expired.append($0) }

        timer.start("a", keepsUntilDismissed: true, announcement: "Dictation stopped")
        #expect(clock.announcements == ["Dictation stopped"])
        #expect(await clock.waitForSleepers(0))
        clock.advance(by: .seconds(3_600))
        #expect(expired.isEmpty)
    }

    @Test func voiceOverStillTimesOutANoticeWithoutAnAction() async {
        let clock = ManualNoticeClock()
        clock.voiceOverRunning = true
        var expired: [String] = []
        let timer = makeTimer(clock) { expired.append($0) }

        timer.start("a", announcement: "ignored")
        #expect(await clock.waitForSleepers(1))
        #expect(clock.announcements.isEmpty)
        clock.advance(by: NoticeDismiss.duration)
        #expect(await waitForMainActorCondition { expired == ["a"] })
    }

    @Test func withoutVoiceOverANoticeWithAnActionTimesOut() async {
        let clock = ManualNoticeClock()
        var expired: [String] = []
        let timer = makeTimer(clock) { expired.append($0) }

        timer.start("a", keepsUntilDismissed: true, announcement: "Dictation stopped")
        #expect(await clock.waitForSleepers(1))
        #expect(clock.announcements.isEmpty)
        clock.advance(by: NoticeDismiss.duration)
        #expect(await waitForMainActorCondition { expired == ["a"] })
    }
}

@MainActor
@Suite("Dictation failure notice dismissal")
struct DictationFailureNoticeTests {
    /// A manager whose take just failed, with the draft rolled back as the
    /// composer does.
    private func failedManager(_ clock: ManualNoticeClock) async throws -> (VoiceInputManager, draft: () -> String) {
        AppPreferences.Voice.setEngineMode(.onDevice)
        let session = MockVoiceSession()
        let provider = MockVoiceProvider(id: .appleClassicDictation, engine: .classicDictation)
        provider.makeSessionHandler = { _, _ in session }
        let manager = VoiceInputManager(
            providerRegistry: VoiceProviderRegistry(providers: [provider]),
            systemAccess: MockVoiceInputSystemAccess(),
            noticeEnvironment: clock.environment
        )
        var draft = "Keep exact draft"
        try await manager.startRecording(keyboardLanguage: "en-US", source: "test", onCaptureFailure: {
            draft = "Keep exact draft"
        })
        draft += " incomplete"
        try await TestCaptureFailureKind.analyzer.finish(session)
        #expect(await waitForMainActorCondition { manager.captureFailure != nil })
        return (manager, { draft })
    }

    @Test func noticeAutoDismissesAndTheDraftStays() async throws {
        let clock = ManualNoticeClock()
        let (manager, draft) = try await failedManager(clock)
        #expect(await clock.waitForSleepers(1))

        clock.advance(by: NoticeDismiss.duration)
        #expect(await waitForMainActorCondition { manager.captureFailure == nil })
        #expect(draft() == "Keep exact draft")
    }

    @Test func dismissClearsTheNoticeAndLeavesRetryWorking() async throws {
        let clock = ManualNoticeClock()
        let (manager, _) = try await failedManager(clock)

        manager.dismissCaptureFailure()
        #expect(manager.captureFailure == nil)
        #expect(await clock.waitForSleepers(0))
        #expect(ComposerShared.micTapAction(for: manager.state) == .start)
    }

    @Test func touchingTheNoticeHoldsItUntilReleased() async throws {
        let clock = ManualNoticeClock()
        let (manager, _) = try await failedManager(clock)
        #expect(await clock.waitForSleepers(1))

        clock.advance(by: .seconds(5))
        manager.setCaptureFailureInteracting(true)
        #expect(await clock.waitForSleepers(0))
        clock.advance(by: .seconds(600))
        #expect(manager.captureFailure != nil)

        manager.setCaptureFailureInteracting(false)
        #expect(await clock.waitForSleepers(1))
        #expect(clock.requested.last == .seconds(1))
        clock.advance(by: .seconds(1))
        #expect(await waitForMainActorCondition { manager.captureFailure == nil })
    }

    @Test func voiceOverAnnouncesTheNoticeAndKeepsItForRetry() async throws {
        let clock = ManualNoticeClock()
        clock.voiceOverRunning = true
        let (manager, _) = try await failedManager(clock)

        #expect(clock.announcements == [manager.captureFailure?.message])
        clock.advance(by: .seconds(3_600))
        #expect(manager.captureFailure != nil)
        manager.dismissCaptureFailure()
        #expect(manager.captureFailure == nil)
    }
}
