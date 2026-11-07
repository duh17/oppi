@testable import Oppi
import Foundation
import Testing

@Suite("ScreenAwakeController", .serialized)
@MainActor
struct ScreenAwakeControllerTests {

    @Test("active session immediately prevents sleep")
    func activeSessionDisablesIdleTimer() {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { .seconds(2) },
            idleTimerSetter: { idleTimerUpdates.append($0) },
            sleepFunction: { _ in }
        )

        controller.setSessionActivity(true, sessionId: "s1")

        #expect(controller.isPreventingSleep)
        #expect(idleTimerUpdates.last == true)
    }

    @Test("idle timeout releases prevention after activity ends")
    func releasesAfterTimeout() async {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { .milliseconds(40) },
            idleTimerSetter: { idleTimerUpdates.append($0) }
        )

        controller.setSessionActivity(true, sessionId: "s1")
        controller.setSessionActivity(false, sessionId: "s1")

        let released = await waitForTestCondition(timeout: .milliseconds(300), poll: .milliseconds(10)) {
            await MainActor.run { !controller.isPreventingSleep }
        }

        #expect(released)
        #expect(idleTimerUpdates.contains(true))
        #expect(idleTimerUpdates.last == false)
    }

    @Test("off timeout releases immediately when activity stops")
    func offTimeoutReleasesImmediately() {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { nil },
            idleTimerSetter: { idleTimerUpdates.append($0) }
        )

        controller.setSessionActivity(true, sessionId: "s1")
        controller.setSessionActivity(false, sessionId: "s1")

        #expect(!controller.isPreventingSleep)
        #expect(idleTimerUpdates == [true, false])
    }

    @Test("voice capture immediately prevents sleep")
    func voiceInputDisablesIdleTimer() {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { .seconds(2) },
            idleTimerSetter: { idleTimerUpdates.append($0) },
            sleepFunction: { _ in }
        )

        controller.setVoiceInputActive(true)

        #expect(controller.isPreventingSleep)
        #expect(idleTimerUpdates.last == true)
    }

    @Test("off timeout releases immediately when voice capture ends")
    func offTimeoutReleasesImmediatelyAfterVoice() {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { nil },
            idleTimerSetter: { idleTimerUpdates.append($0) }
        )

        controller.setVoiceInputActive(true)
        controller.setVoiceInputActive(false)

        #expect(!controller.isPreventingSleep)
        #expect(idleTimerUpdates == [true, false])
    }

    @Test("idle timeout releases prevention after voice capture ends")
    func releasesAfterTimeoutWhenVoiceEnds() async {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { .milliseconds(40) },
            idleTimerSetter: { idleTimerUpdates.append($0) }
        )

        controller.setVoiceInputActive(true)
        controller.setVoiceInputActive(false)

        let released = await waitForTestCondition(timeout: .milliseconds(300), poll: .milliseconds(10)) {
            await MainActor.run { !controller.isPreventingSleep }
        }

        #expect(released)
        #expect(idleTimerUpdates.contains(true))
        #expect(idleTimerUpdates.last == false)
    }

    @Test("voice plus busy session stays prevented until both clear")
    func voiceAndSessionOverlapUntilBothClear() {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { nil },
            idleTimerSetter: { idleTimerUpdates.append($0) }
        )

        controller.setVoiceInputActive(true)
        controller.setSessionActivity(true, sessionId: "s1")
        controller.setVoiceInputActive(false)
        #expect(controller.isPreventingSleep)
        #expect(idleTimerUpdates == [true])

        controller.setSessionActivity(false, sessionId: "s1")
        #expect(!controller.isPreventingSleep)
        #expect(idleTimerUpdates == [true, false])

        controller.setSessionActivity(true, sessionId: "s1")
        controller.setVoiceInputActive(true)
        controller.setSessionActivity(false, sessionId: "s1")
        #expect(controller.isPreventingSleep)
        #expect(idleTimerUpdates == [true, false, true])

        controller.setVoiceInputActive(false)
        #expect(!controller.isPreventingSleep)
        #expect(idleTimerUpdates == [true, false, true, false])
    }

    @Test("voice reason is not a session id")
    func voiceReasonIsNotASessionId() {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { nil },
            idleTimerSetter: { idleTimerUpdates.append($0) }
        )

        controller.setVoiceInputActive(true)
        controller.clearSessionActivity(sessionId: "voice-input")
        controller.setSessionActivity(false, sessionId: "voice-input")

        #expect(controller.isPreventingSleep)
        #expect(idleTimerUpdates == [true])

        controller.setVoiceInputActive(false)
        #expect(!controller.isPreventingSleep)
        #expect(idleTimerUpdates == [true, false])
    }

    @Test("updates that change no reason never wake an idle screen")
    func noOpUpdatesLeaveTheIdleTimerAlone() {
        var idleTimerUpdates: [Bool] = []

        let controller = ScreenAwakeController(
            timeoutProvider: { .seconds(120) },
            idleTimerSetter: { idleTimerUpdates.append($0) },
            sleepFunction: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        controller.setSessionActivity(false, sessionId: "idle")
        controller.clearSessionActivity(sessionId: "idle")
        controller.setVoiceInputActive(false)
        controller.setSetupInstallActive(false)
        controller.refreshFromPreferences()

        #expect(!controller.isPreventingSleep)
        #expect(idleTimerUpdates.isEmpty)
    }

    @Test("updates that change no reason do not restart the release timeout")
    func noOpUpdatesDoNotExtendTheTimeout() async {
        let controller = ScreenAwakeController(
            timeoutProvider: { .milliseconds(40) },
            idleTimerSetter: { _ in }
        )

        controller.setSessionActivity(true, sessionId: "s1")
        controller.setSessionActivity(false, sessionId: "s1")

        // Idle sessions keep reporting more often than the timeout.
        var released = false
        for _ in 0..<30 where !released {
            controller.setSessionActivity(false, sessionId: "idle")
            controller.clearSessionActivity(sessionId: "idle")
            try? await Task.sleep(for: .milliseconds(10))
            released = !controller.isPreventingSleep
        }

        #expect(released)
    }
}
