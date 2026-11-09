import Foundation
import Testing
@testable import Oppi

/// Counts upload attempts and fails them while `failing` is set.
private actor FlakyClientLogUploader: ClientLogUploading {
    struct Offline: Error {}

    private(set) var attempts = 0
    private(set) var uploadedEntries = 0
    var failing = true

    func setFailing(_ failing: Bool) { self.failing = failing }

    func uploadClientLogs(request: ClientLogUploadRequest) async throws {
        attempts += 1
        if failing { throw Offline() }
        uploadedEntries += request.entries.count
    }

    func waitForAttempts(_ count: Int, timeout: Duration = .seconds(5)) async -> Int {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while attempts < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return attempts
    }

    func waitForUploadedEntries(_ count: Int, timeout: Duration = .seconds(5)) async -> Int {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while uploadedEntries < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return uploadedEntries
    }
}

@Suite("ClientLogUploadQueue")
struct ClientLogUploadQueueTests {
    private static let retryInterval: Duration = .seconds(2)

    private func makeQueue(uploader: any ClientLogUploading) async -> ClientLogUploadQueue {
        let queue = ClientLogUploadQueue(
            clientKind: .ios,
            appInstanceId: "app-1",
            bootId: "boot-1",
            isUploadAllowed: { true },
            nowMs: { 1 },
            maxPending: 10_000,
            maxBatchSize: 50,
            flushInterval: Self.retryInterval
        )
        await queue.setMetadata(ClientLogUploadMetadata(
            appVersion: "1", buildNumber: "1", osVersion: "test", deviceModel: "test"
        ))
        await queue.setUploader(uploader)
        return queue
    }

    private func record(_ count: Int, on queue: ClientLogUploadQueue) async {
        for index in 0 ..< count {
            await queue.record(level: .warn, category: "Test", message: "entry \(index)")
        }
    }

    @Test func failedUploadWaitsForItsRetryTimerInsteadOfUploadingOnEveryNewEntry() async {
        let uploader = FlakyClientLogUploader()
        let queue = await makeQueue(uploader: uploader)

        await record(50, on: queue)
        #expect(await uploader.waitForAttempts(1) == 1)

        // Offline: more entries pile up behind the failed batch, none starts an upload.
        await record(500, on: queue)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await uploader.attempts == 1)

        // The 10 s retry timer (shortened here) is the next and only attempt.
        #expect(await uploader.waitForAttempts(2) == 2)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await uploader.attempts == 2)
    }

    @Test func successfulRetryResumesBatchSizeUploads() async {
        let uploader = FlakyClientLogUploader()
        let queue = await makeQueue(uploader: uploader)

        await record(50, on: queue)
        #expect(await uploader.waitForAttempts(1) == 1)
        await uploader.setFailing(false)
        await record(50, on: queue)
        #expect(await uploader.waitForUploadedEntries(100) == 100)

        // No retry is pending after the success: a full batch uploads at once.
        await record(50, on: queue)
        #expect(await uploader.waitForUploadedEntries(150, timeout: .milliseconds(1_500)) == 150)
    }
}
