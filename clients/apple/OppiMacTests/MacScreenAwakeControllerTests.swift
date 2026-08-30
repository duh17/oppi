import Foundation
import Testing
@testable import Oppi

@Suite("MacScreenAwakeController", .serialized)
@MainActor
struct MacScreenAwakeControllerTests {
    @Test func activeSessionImmediatelyPreventsSleep() {
        var activityUpdates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { .seconds(2) },
            activitySetter: { activityUpdates.append($0) },
            sleepFunction: { _ in }
        )

        controller.setSessionActivity(true, sessionId: "s1")

        #expect(controller.isPreventingSleep)
        #expect(activityUpdates.last == true)
    }

    @Test func idleTimeoutReleasesPreventionAfterActivityEnds() async {
        var activityUpdates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { .milliseconds(40) },
            activitySetter: { activityUpdates.append($0) }
        )

        controller.setSessionActivity(true, sessionId: "s1")
        controller.setSessionActivity(false, sessionId: "s1")

        let released = await waitForMacCondition(timeout: .milliseconds(300)) {
            !controller.isPreventingSleep
        }

        #expect(released)
        #expect(activityUpdates.contains(true))
        #expect(activityUpdates.last == false)
    }

    @Test func offTimeoutReleasesImmediatelyWhenActivityStops() {
        var activityUpdates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { activityUpdates.append($0) }
        )

        controller.setSessionActivity(true, sessionId: "s1")
        controller.setSessionActivity(false, sessionId: "s1")

        #expect(!controller.isPreventingSleep)
        #expect(activityUpdates == [true, false])
    }

    @Test func secondSessionKeepsPreventionUntilTheLastSessionEnds() {
        var activityUpdates: [Bool] = []
        let controller = MacScreenAwakeController(
            timeoutProvider: { nil },
            activitySetter: { activityUpdates.append($0) }
        )

        controller.setSessionActivity(true, sessionId: "s1")
        controller.setSessionActivity(true, sessionId: "s2")
        controller.setSessionActivity(false, sessionId: "s1")

        #expect(controller.isPreventingSleep)
        #expect(activityUpdates == [true])

        controller.setSessionActivity(false, sessionId: "s2")
        #expect(!controller.isPreventingSleep)
        #expect(activityUpdates == [true, false])
    }

    @Test func usesProcessInfoDisplaySleepPreventionNotUIKitIdleTimer() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Services/MacScreenAwakeController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("idleDisplaySleepDisabled"))
        #expect(source.contains("beginActivity"))
        #expect(source.contains("endActivity"))
        #expect(!source.contains("UIApplication.shared"))
        #expect(!source.contains("import UIKit"))
    }
}

@MainActor
private func waitForMacCondition(
    timeout: Duration,
    poll: Duration = .milliseconds(10),
    _ predicate: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() {
            return true
        }
        await Task.yield()
        try? await Task.sleep(for: poll)
    }
    return predicate()
}
