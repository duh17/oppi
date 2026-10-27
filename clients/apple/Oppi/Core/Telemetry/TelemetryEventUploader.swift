import Foundation
import OSLog

private let uploaderLog = Logger(subsystem: AppIdentifiers.subsystem, category: "TelemetryUpload")

/// Buffers catalog events and uploads them to `POST /telemetry/events`.
///
/// Holds at most 1000 events, sends batches of 50, and flushes 10 s after the
/// first buffered event or as soon as a batch is full. A failed upload keeps the
/// batch for the next flush. The server answers with the events it refused, by
/// reason; those cannot succeed on retry, so they are logged and not resent.
actor TelemetryEventUploader {
    static let shared = TelemetryEventUploader()

    private var apiClient: APIClient?
    private var backlog: [TelemetryEventPayload] = []
    private var flushing = false
    private var flushTask: Task<Void, Never>?

    private let maxPending = 1_000
    private let maxBatchSize = 50
    private let flushInterval: Duration = .seconds(10)

    private init() {}

    func setUploadClient(_ client: APIClient?) {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
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
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }

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

    func flushIfNeeded() {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        guard !flushing else { return }
        guard !backlog.isEmpty else { return }

        Task { [weak self] in
            await self?.flushLoop()
        }
    }

    private func flushLoop() async {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
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
                let response = try await apiClient.uploadTelemetryEvents(request: request)
                Self.logDrops(response, batchSize: batch.count)
            } catch {
                backlog = batch + backlog
                scheduleFlushTimerIfNeeded()
                return
            }
        }
    }

    private static func logDrops(_ response: TelemetryEventUploadResponse, batchSize: Int) {
        guard !response.dropped.isEmpty else { return }
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

        flushTask = Task { [weak self] in
            try? await Task.sleep(for: self?.flushInterval ?? .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.flushTaskFired()
        }
    }

    private func flushTaskFired() {
        flushTask = nil
        flushIfNeeded()
    }
}
