import Foundation
import OSLog

private let uploaderLog = Logger(subsystem: AppIdentifiers.subsystem, category: "TelemetryUpload")

/// Buffers catalog events and uploads them to `POST /telemetry/events`.
/// `uploadTelemetryEvents` returns `nil` for a 2xx whose body cannot be read.
///
/// Holds at most 1000 events, sends batches of 50, and flushes 10 s after the
/// first buffered event or as soon as a batch is full. A failed upload (no 2xx)
/// keeps the batch for the next flush. A 2xx never requeues: the server stored
/// the accepted events, and the ones it refused, which it reports by reason,
/// cannot succeed on retry, so they are logged and not resent.
actor TelemetryEventUploader {
    static let shared = TelemetryEventUploader()

    private var apiClient: APIClient?
    private var backlog: [TelemetryEventPayload] = []
    private var flushing = false
    private var flushTask: Task<Void, Never>?

    private let isUploadAllowed: @Sendable () -> Bool
    private let onDrops: @Sendable (TelemetryEventUploadResponse, Int) -> Void
    private let maxPending: Int
    private let maxBatchSize: Int
    private let flushInterval: Duration

    init(
        isUploadAllowed: @escaping @Sendable () -> Bool = { TelemetrySettings.allowsRemoteDiagnosticsUpload },
        onDrops: @escaping @Sendable (TelemetryEventUploadResponse, Int) -> Void = TelemetryEventUploader.logDrops,
        maxPending: Int = 1_000,
        maxBatchSize: Int = 50,
        flushInterval: Duration = .seconds(10)
    ) {
        self.isUploadAllowed = isUploadAllowed
        self.onDrops = onDrops
        self.maxPending = maxPending
        self.maxBatchSize = maxBatchSize
        self.flushInterval = flushInterval
    }

    func setUploadClient(_ client: APIClient?) {
        guard isUploadAllowed() else {
            apiClient = nil
            backlog.removeAll(keepingCapacity: true)
            flushTask?.cancel()
            flushTask = nil
            return
        }

        apiClient = client
        guard client != nil else { return }
        flushIfNeeded()
    }

    func enqueue(_ event: TelemetryEventPayload) {
        guard isUploadAllowed() else { return }

        backlog.append(event)
        if backlog.count > maxPending {
            backlog.removeFirst(backlog.count - maxPending)
        }

        if backlog.count >= maxBatchSize {
            flushIfNeeded()
        } else {
            scheduleFlushTimerIfNeeded()
        }
    }

    /// Events waiting for upload.
    var pendingCount: Int { backlog.count }

    func flushIfNeeded() {
        guard isUploadAllowed() else { return }
        guard !flushing else { return }
        guard !backlog.isEmpty else { return }

        Task { [weak self] in
            await self?.flush()
        }
    }

    /// Uploads every buffered batch, stopping at the first failure.
    func flush() async {
        guard isUploadAllowed() else {
            backlog.removeAll(keepingCapacity: true)
            return
        }

        guard !flushing else { return }
        flushing = true
        defer { flushing = false }

        flushTask?.cancel()
        flushTask = nil

        guard let apiClient else {
            scheduleFlushTimerIfNeeded()
            return
        }

        while !backlog.isEmpty {
            let batch = Array(backlog.prefix(maxBatchSize))
            backlog.removeFirst(min(maxBatchSize, backlog.count))

            let request = TelemetryEventUploadRequest(
                generatedAt: Date.nowMs(),
                client: TelemetryClientIdentity.current,
                events: batch
            )

            do {
                if let response = try await apiClient.uploadTelemetryEvents(request: request),
                   !response.dropped.isEmpty {
                    onDrops(response, batch.count)
                }
            } catch {
                backlog = batch + backlog
                scheduleFlushTimerIfNeeded()
                return
            }
        }
    }

    @Sendable
    static func logDrops(_ response: TelemetryEventUploadResponse, batchSize: Int) {
        let reasons = response.dropped
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        uploaderLog.error(
            "Telemetry upload dropped events accepted=\(response.accepted, privacy: .public) batch=\(batchSize, privacy: .public) \(reasons, privacy: .public)"
        )
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
}
