import Testing
import UIKit
@testable import Oppi

/// Keeps every `begin` call's handler, so a test can fire one left over from
/// a window that is already over.
@MainActor
private final class RecordingBackgroundTasks: AppBackgroundTasks {
    private(set) var endedIDs: [UIBackgroundTaskIdentifier] = []
    private(set) var expirations: [@MainActor () -> Void] = []

    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier? {
        expirations.append(expiration)
        return UIBackgroundTaskIdentifier(rawValue: expirations.count)
    }

    func end(_ task: UIBackgroundTaskIdentifier) { endedIDs.append(task) }
}

@Suite("Background task window")
@MainActor
struct BackgroundTaskWindowTests {
    @Test func aSecondBeginWhileOpenIsRefused() throws {
        let tasks = RecordingBackgroundTasks()
        let window = BackgroundTaskWindow(backgroundTasks: tasks)
        let first = try #require(window.begin {})
        #expect(window.begin {} == nil)
        window.end(first)
        #expect(tasks.endedIDs.count == 1)
        #expect(window.begin {} != nil)
    }

    @Test func aStaleExpiryLeavesTheWindowThatReplacedItAlone() throws {
        let tasks = RecordingBackgroundTasks()
        let window = BackgroundTaskWindow(backgroundTasks: tasks)
        var expired = 0
        let first = try #require(window.begin { expired += 1 })
        window.end(first)
        let second = try #require(window.begin { expired += 1 })

        tasks.expirations[0]()
        window.end(first)
        #expect(expired == 0)
        #expect(window.isCurrent(second))
        #expect(tasks.endedIDs == [UIBackgroundTaskIdentifier(rawValue: 1)])

        tasks.expirations[1]()
        tasks.expirations[1]()
        #expect(expired == 1)
        #expect(tasks.endedIDs.count == 2)
    }

    @Test func expiryEndsTheTaskAfterItsOwnerIsGone() {
        let tasks = RecordingBackgroundTasks()
        _ = BackgroundTaskWindow(backgroundTasks: tasks).begin {}
        tasks.expirations[0]()
        #expect(tasks.endedIDs.count == 1)
    }
}
