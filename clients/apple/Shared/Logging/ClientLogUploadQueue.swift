import Foundation

actor ClientLogUploadQueue {
    private let clientKind: AppleClientKind
    private let appInstanceId: String
    private let bootId: String
    private let isUploadAllowed: @Sendable () -> Bool
    private let nowMs: @Sendable () -> Int64
    private let maxPending: Int
    private let maxBatchSize: Int
    private let flushInterval: Duration

    private var uploader: (any ClientLogUploading)?
    private var metadata: ClientLogUploadMetadata?
    private var backlog: [ClientLogUploadEntry] = []
    private var flushing = false
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    /// Set when an upload failed and the flush timer is the retry. A full batch
    /// must not upload ahead of it: offline, every new entry would otherwise
    /// start another doomed upload, and each failure logs more entries.
    private var retryPending = false
    private var nextSeq = 0
    private var droppedCount = 0

    init(
        clientKind: AppleClientKind,
        appInstanceId: String,
        bootId: String,
        isUploadAllowed: @escaping @Sendable () -> Bool,
        nowMs: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        },
        maxPending: Int = 1_000,
        maxBatchSize: Int = 50,
        flushInterval: Duration = .seconds(10)
    ) {
        self.clientKind = clientKind
        self.appInstanceId = appInstanceId
        self.bootId = bootId
        self.isUploadAllowed = isUploadAllowed
        self.nowMs = nowMs
        self.maxPending = max(1, maxPending)
        self.maxBatchSize = max(1, maxBatchSize)
        self.flushInterval = flushInterval
    }

    func setUploader(_ uploader: (any ClientLogUploading)?) {
        guard isUploadAllowed() else {
            clearUploadState()
            return
        }

        self.uploader = uploader
        if uploader != nil {
            flushIfNeeded()
        }
    }

    func setMetadata(_ metadata: ClientLogUploadMetadata?) {
        self.metadata = metadata
        if metadata != nil {
            flushIfNeeded()
        }
    }

    func record(
        level: ClientLogUploadLevel,
        category: String,
        message: String,
        metadata rawMetadata: [String: String] = [:],
        sessionId explicitSessionId: String? = nil,
        workspaceId explicitWorkspaceId: String? = nil
    ) {
        guard isUploadAllowed() else { return }

        let cleanCategory = ClientLogRedactor.redactedText(
            category.trimmingCharacters(in: .whitespacesAndNewlines),
            maxLength: 96
        )
        let cleanMessage = ClientLogRedactor.redactedText(
            message.trimmingCharacters(in: .whitespacesAndNewlines),
            maxLength: 2_048
        )
        guard !cleanMessage.isEmpty else { return }

        nextSeq += 1
        let metadata = Self.cleanMetadata(rawMetadata)
        let sessionId = Self.cleanOptionalText(explicitSessionId ?? rawMetadata["sessionId"], maxLength: 128)
        let workspaceId = Self.cleanOptionalText(explicitWorkspaceId ?? rawMetadata["workspaceId"], maxLength: 128)

        backlog.append(
            ClientLogUploadEntry(
                ts: nowMs(),
                seq: nextSeq,
                level: level,
                category: cleanCategory.isEmpty ? "General" : cleanCategory,
                message: cleanMessage,
                metadata: metadata.isEmpty ? nil : metadata,
                sessionId: sessionId,
                workspaceId: workspaceId
            )
        )

        if backlog.count > maxPending {
            let overflow = backlog.count - maxPending
            backlog.removeFirst(overflow)
            droppedCount += overflow
        }

        if backlog.count >= maxBatchSize, !retryTimerOwnsNextAttempt {
            flushIfNeeded()
        } else {
            scheduleFlushTimerIfNeeded()
        }
    }

    func flushIfNeeded() {
        guard isUploadAllowed() else {
            clearUploadState()
            return
        }
        guard !flushing else { return }
        guard !backlog.isEmpty else { return }
        guard !retryTimerOwnsNextAttempt else { return }

        Task { [weak self] in
            await self?.flushTriggered()
        }
    }

    /// After a failure the retry timer is the next attempt. `flushTaskFired` clears
    /// `flushTask` before it calls `flushIfNeeded`, so the timer itself passes this check.
    private var retryTimerOwnsNextAttempt: Bool { retryPending && flushTask != nil }

    /// A trigger can be queued behind another that then fails; it re-checks on arrival so it
    /// cannot add an attempt ahead of the timer that failure set.
    private func flushTriggered() async {
        guard !retryTimerOwnsNextAttempt else { return }
        await flushLoop()
    }

    func flushNow() async {
        if flushing {
            await withCheckedContinuation { continuation in
                flushWaiters.append(continuation)
            }
        }
        await flushLoop()
    }

    private func flushLoop() async {
        guard isUploadAllowed() else {
            clearUploadState()
            return
        }
        guard !flushing else { return }
        guard !backlog.isEmpty else { return }

        flushing = true
        defer {
            flushing = false
            let waiters = flushWaiters
            flushWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume()
            }
        }

        flushTask?.cancel()
        flushTask = nil

        guard let metadata else {
            scheduleFlushTimerIfNeeded()
            return
        }

        guard let uploader else {
            scheduleFlushTimerIfNeeded()
            return
        }

        while !backlog.isEmpty {
            let batch = Array(backlog.prefix(maxBatchSize))
            backlog.removeFirst(min(maxBatchSize, backlog.count))

            let batchDroppedCount = droppedCount
            if batchDroppedCount > 0 {
                droppedCount = 0
            }

            let request = ClientLogUploadRequest(
                generatedAt: nowMs(),
                client: ClientLogUploadClient(
                    kind: clientKind,
                    appVersion: metadata.appVersion,
                    buildNumber: metadata.buildNumber,
                    osVersion: metadata.osVersion,
                    deviceModel: metadata.deviceModel,
                    gitCommit: metadata.gitCommit,
                    appInstanceId: appInstanceId,
                    bootId: bootId
                ),
                droppedCount: batchDroppedCount > 0 ? batchDroppedCount : nil,
                entries: batch
            )

            do {
                try await uploader.uploadClientLogs(request: request)
                retryPending = false
            } catch {
                backlog = batch + backlog
                droppedCount += batchDroppedCount
                retryPending = true
                scheduleFlushTimerIfNeeded()
                return
            }
        }
    }

    private func scheduleFlushTimerIfNeeded() {
        guard flushTask == nil else { return }

        let interval = flushInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.flushTaskFired()
        }
    }

    private func flushTaskFired() {
        flushTask = nil
        flushIfNeeded()
    }

    private func clearUploadState() {
        uploader = nil
        backlog.removeAll(keepingCapacity: true)
        droppedCount = 0
        retryPending = false
        flushTask?.cancel()
        flushTask = nil
    }

    private static func cleanText(_ value: String, maxLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength))
    }

    private static func cleanOptionalText(_ value: String?, maxLength: Int) -> String? {
        guard let value else { return nil }
        let cleaned = cleanText(value, maxLength: maxLength)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanMetadata(_ metadata: [String: String]) -> [String: String] {
        ClientLogRedactor.redactedMetadata(metadata)
    }
}
