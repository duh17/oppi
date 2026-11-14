import Darwin
import Foundation
import os
import Testing
@testable import Oppi

/// The app keeps running for as long as it holds a lock: iOS kills an app it
/// suspends while it holds a file lock in a shared container (0xdead10cc).
/// Serialized: each test swaps the process-wide hook.
@Suite("Cross-process file lock background hold", .serialized)
struct CrossProcessFileLockBackgroundHoldTests {
    /// Steps the hook and the locked body saw, each with whether another open
    /// of the lock file could take it at that moment.
    private final class Recorder: Sendable {
        let lockURL: URL
        private let events = OSAllocatedUnfairLock<[String]>(initialState: [])

        init(lockURL: URL) { self.lockURL = lockURL }

        var recorded: [String] { events.withLock { $0 } }

        func record(_ step: String) {
            events.withLock { $0.append("\(step) \(lockIsFree() ? "free" : "held")") }
        }

        private func lockIsFree() -> Bool {
            let fd = open(lockURL.path, O_RDWR)
            // Not created yet: nobody holds it.
            guard fd >= 0 else { return true }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
            flock(fd, LOCK_UN)
            return true
        }
    }

    private struct BodyFailure: Error {}

    /// Runs `body` with a hook that records this test's lock and passes any other
    /// lock (a parallel suite's) to the hook that was installed.
    private func withRecordingHold(_ recorder: Recorder, _ body: () throws -> Void) rethrows {
        let installed = CrossProcessFileLock.backgroundHold
        defer { CrossProcessFileLock.backgroundHold = installed }
        let name = recorder.lockURL.lastPathComponent
        let hold: CrossProcessFileLock.BackgroundHold = { lockName in
            guard lockName == name else { return installed?(lockName) ?? {} as @Sendable () -> Void }
            recorder.record("begin")
            return { recorder.record("end") }
        }
        CrossProcessFileLock.backgroundHold = hold
        try body()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aServerLockIsHeldOnlyInsideTheHold() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let serverId = "sha256:\(UUID().uuidString)"
        let recorder = Recorder(lockURL: CrossProcessFileLock.lockURL(serverId: serverId, container: container))

        try withRecordingHold(recorder) {
            try CrossProcessFileLock.withLock(serverId: serverId, container: container) {
                recorder.record("body")
            }
        }

        #expect(recorder.recorded == ["begin free", "body held", "end free"])
    }

    @Test func theHoldEndsAfterReleaseWhenTheBodyThrows() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Recorder(lockURL: directory.appendingPathComponent("\(UUID().uuidString).lock"))

        withRecordingHold(recorder) {
            #expect(throws: BodyFailure.self) {
                try CrossProcessFileLock.withLock(fileAt: recorder.lockURL, protection: .completeUntilFirstUserAuthentication) {
                    recorder.record("body")
                    throw BodyFailure()
                }
            }
        }

        #expect(recorder.recorded == ["begin free", "body held", "end free"])
    }

    @Test func theHoldEndsWhenTheLockCannotBeTaken() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The lock file's directory does not exist, so opening it fails.
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        let recorder = Recorder(lockURL: missing.appendingPathComponent("\(UUID().uuidString).lock"))

        withRecordingHold(recorder) {
            #expect(throws: POSIXError.self) {
                try CrossProcessFileLock.withLock(fileAt: recorder.lockURL, protection: .completeUntilFirstUserAuthentication) {
                    recorder.record("body")
                }
            }
        }

        #expect(recorder.recorded == ["begin free", "end free"])
    }
}
