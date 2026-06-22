import Foundation
import OSLog

import MetricKit

private let metricKitLog = Logger(subsystem: AppIdentifiers.subsystem, category: "MetricKit")

final class MetricKitService: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitService()

    private let uploader = MetricKitUploadQueue()
    private let diagnosticFingerprintLock = NSLock()
    private var configured = false
    private var queuedDiagnosticFingerprints = Set<String>()

    override private init() {}

    func configure() {
        guard !configured else { return }
        configured = true

        // Always subscribe to MetricKit — payloads are gated at upload time.
        // This ensures we start receiving data immediately if the user opts in later.
        MXMetricManager.shared.add(self)
        collectPastDiagnosticPayloadsIfAllowed(reason: "configure")
        metricKitLog.info("MetricKit subscriber registered (upload=\(TelemetrySettings.allowsRemoteDiagnosticsUpload, privacy: .public))")
    }

    /// Called when the user toggles the diagnostics preference in Settings.
    /// Re-evaluates upload eligibility and flushes any queued data.
    func refreshAfterPreferenceChange() {
        let allowed = TelemetrySettings.allowsRemoteDiagnosticsUpload
        metricKitLog.info("Telemetry preference changed (upload=\(allowed, privacy: .public))")

        let client = allowed ? currentAPIClient : nil
        Task {
            await ChatMetricsService.shared.setUploadClient(client)
        }
        ClientLogUploadService.configureUploader(client)

        guard allowed else {
            Task { await uploader.clear() }
            return
        }
        collectPastDiagnosticPayloadsIfAllowed(reason: "preference_change")
        Task {
            await uploader.setClient(client)
            await uploader.setMetadata(Self.makeMetadata())
            await uploader.flushIfNeeded()
        }
    }

    /// Stored reference so refreshAfterPreferenceChange can re-wire.
    private var currentAPIClient: APIClient?

    func setUploadClient(_ client: APIClient?) {
        currentAPIClient = client

        Task {
            await ChatMetricsService.shared.setUploadClient(client)
        }
        ClientLogUploadService.configureUploader(client)

        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            Task { await uploader.clear() }
            return
        }

        collectPastDiagnosticPayloadsIfAllowed(reason: "set_upload_client")
        Task {
            await uploader.setClient(client)
            await uploader.setMetadata(Self.makeMetadata())
            await uploader.flushIfNeeded()
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard !payloads.isEmpty else { return }
        let items = payloads.map { payload in
            MetricKitPayloadSerializer.item(
                from: payload,
                kind: .metric,
                windowStartMs: payload.timeStampBegin.toMs(),
                windowEndMs: payload.timeStampEnd.toMs()
            )
        }
        upload(items)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        let context = MetricKitCrashContextStore.snapshotMetadata()
        let items = payloads.compactMap { payload in
            let item = MetricKitPayloadSerializer.item(
                from: payload,
                kind: .diagnostic,
                windowStartMs: payload.timeStampBegin.toMs(),
                windowEndMs: payload.timeStampEnd.toMs(),
                context: context
            )
            return markDiagnosticIfNew(item)
        }
        recordDiagnosticClientLogs(items, reason: "did_receive")
        upload(items)
    }

    private func upload(_ items: [MetricKitPayloadItem]) {
        guard !items.isEmpty else { return }
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }

        Task {
            await uploader.enqueue(payloads: items)
        }
    }

    private func collectPastDiagnosticPayloadsIfAllowed(reason: String) {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }

        let payloads = MXMetricManager.shared.pastDiagnosticPayloads
        guard !payloads.isEmpty else { return }

        let context = MetricKitCrashContextStore.snapshotMetadata()
        let items = payloads.compactMap { payload in
            let item = MetricKitPayloadSerializer.item(
                from: payload,
                kind: .diagnostic,
                windowStartMs: payload.timeStampBegin.toMs(),
                windowEndMs: payload.timeStampEnd.toMs(),
                context: context
            )
            return markDiagnosticIfNew(item)
        }
        recordDiagnosticClientLogs(items, reason: reason)
        upload(items)
    }

    private func markDiagnosticIfNew(_ item: MetricKitPayloadItem) -> MetricKitPayloadItem? {
        let fingerprint = [
            String(item.windowStartMs),
            String(item.windowEndMs),
            item.summary["crashDiagnosticCount"] ?? "0",
            item.summary["hangDiagnosticCount"] ?? "0",
            item.summary["cpuExceptionDiagnosticCount"] ?? "0",
            item.summary["diskWriteExceptionDiagnosticCount"] ?? "0",
        ].joined(separator: "|")
        diagnosticFingerprintLock.lock()
        defer { diagnosticFingerprintLock.unlock() }
        guard !queuedDiagnosticFingerprints.contains(fingerprint) else { return nil }
        queuedDiagnosticFingerprints.insert(fingerprint)
        return item
    }

    private func recordDiagnosticClientLogs(_ items: [MetricKitPayloadItem], reason: String) {
        for item in items {
            let crashCount = Int(item.summary["crashDiagnosticCount"] ?? "0") ?? 0
            let hangCount = Int(item.summary["hangDiagnosticCount"] ?? "0") ?? 0
            let cpuExceptionCount = Int(item.summary["cpuExceptionDiagnosticCount"] ?? "0") ?? 0
            guard crashCount > 0 || hangCount > 0 || cpuExceptionCount > 0 else { continue }

            var metadata: [String: String] = [
                "reason": reason,
                "crashDiagnosticCount": String(crashCount),
                "hangDiagnosticCount": String(hangCount),
                "cpuExceptionDiagnosticCount": String(cpuExceptionCount),
            ]
            if let sessionId = item.summary["lastSessionId"] {
                metadata["sessionId"] = sessionId
            }
            if let workspaceId = item.summary["lastWorkspaceId"] {
                metadata["workspaceId"] = workspaceId
            }
            ClientLog.error("MetricKit", "Crash diagnostic payload queued", metadata: metadata)
        }
    }

    fileprivate static func makeMetadata() -> MetricKitUploadMetadata {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = Self.deviceModel()
        return MetricKitUploadMetadata(
            appVersion: version,
            buildNumber: build,
            osVersion: osVersion,
            deviceModel: model
        )
    }

    private static func deviceModel() -> String {
        "iPhone"
    }

}

extension MetricKitService: @unchecked Sendable {}

private struct MetricKitUploadMetadata: Sendable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
}

private actor MetricKitUploadQueue {
    private var apiClient: APIClient?
    private var metadata: MetricKitUploadMetadata?
    private var backlog: [MetricKitPayloadItem] = []
    private var uploading = false

    private let maxPending = 240
    private let maxBatchSize = 30

    func setClient(_ client: APIClient?) {
        apiClient = client
    }

    func setMetadata(_ metadata: MetricKitUploadMetadata) {
        self.metadata = metadata
    }

    func enqueue(payloads: [MetricKitPayloadItem]) {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            clear()
            return
        }
        guard !payloads.isEmpty else { return }

        backlog.append(contentsOf: payloads)
        if backlog.count > maxPending {
            backlog.removeFirst(backlog.count - maxPending)
        }

        flushIfNeeded()
    }

    func flushIfNeeded() {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            clear()
            return
        }
        if uploading {
            return
        }

        Task {
            await self.flush()
        }
    }

    func clear() {
        apiClient = nil
        backlog.removeAll(keepingCapacity: true)
    }

    private func flush() async {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
            clear()
            return
        }
        if uploading { return }
        uploading = true
        defer { uploading = false }

        guard let metadata else {
            metricKitLog.debug("Skipping upload: missing metadata")
            return
        }

        guard let apiClient else {
            metricKitLog.debug("Skipping upload: no API client")
            return
        }

        while !backlog.isEmpty {
            guard TelemetrySettings.allowsRemoteDiagnosticsUpload else {
                clear()
                return
            }
            let batch = Array(backlog.prefix(maxBatchSize))
            backlog.removeFirst(min(maxBatchSize, backlog.count))

            let request = MetricKitUploadRequest(
                generatedAt: Date.nowMs(),
                appVersion: metadata.appVersion,
                buildNumber: metadata.buildNumber,
                osVersion: metadata.osVersion,
                deviceModel: metadata.deviceModel,
                clientKind: .ios,
                appInstanceId: ClientLogUploadService.appInstanceId,
                bootId: ClientLogUploadService.bootId,
                payloads: batch
            )

            do {
                try await apiClient.uploadMetricKitPayload(request: request)
                metricKitLog.debug("Uploaded metrickit batch size=\(batch.count)")
            } catch {
                backlog = batch + backlog
                metricKitLog.error("MetricKit upload failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }
    }

}

// MARK: - Crash context

struct MetricKitCrashContext: Codable, Equatable, Sendable {
    let recordedAtMs: Int64
    let sessionId: String?
    let workspaceId: String?
    let streamState: String
    let lastTimelinePayloadRecordedAtMs: Int64?
    let lastTimelinePayloadBytes: Int?
    let lastTimelinePayloadEventCount: Int?
    let lastTimelinePayloadLargestEventBytes: Int?
}

enum MetricKitCrashContextStore {
    private static let defaultsKey = "oppi.diagnostics.lastActiveContext.v1"

    static func record(sessionId: String?, workspaceId: String?, streamState: String) {
        let previous = snapshot()
        let context = MetricKitCrashContext(
            recordedAtMs: Date.nowMs(),
            sessionId: clean(sessionId),
            workspaceId: clean(workspaceId),
            streamState: clean(streamState) ?? "unknown",
            lastTimelinePayloadRecordedAtMs: previous?.lastTimelinePayloadRecordedAtMs,
            lastTimelinePayloadBytes: previous?.lastTimelinePayloadBytes,
            lastTimelinePayloadEventCount: previous?.lastTimelinePayloadEventCount,
            lastTimelinePayloadLargestEventBytes: previous?.lastTimelinePayloadLargestEventBytes
        )
        save(context)
    }

    static func recordLargeTimelinePayload(
        sessionId: String?,
        eventCount: Int,
        bytes: Int,
        largestEventBytes: Int
    ) {
        let previous = snapshot()
        let context = MetricKitCrashContext(
            recordedAtMs: previous?.recordedAtMs ?? Date.nowMs(),
            sessionId: clean(sessionId) ?? previous?.sessionId,
            workspaceId: previous?.workspaceId,
            streamState: previous?.streamState ?? "unknown",
            lastTimelinePayloadRecordedAtMs: Date.nowMs(),
            lastTimelinePayloadBytes: bytes,
            lastTimelinePayloadEventCount: eventCount,
            lastTimelinePayloadLargestEventBytes: largestEventBytes
        )
        save(context)
    }

    static func snapshot() -> MetricKitCrashContext? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(MetricKitCrashContext.self, from: data)
    }

    static func snapshotMetadata() -> [String: String] {
        guard let context = snapshot() else { return [:] }
        var metadata: [String: String] = [
            "lastContextRecordedAtMs": String(context.recordedAtMs),
            "lastStreamState": context.streamState,
        ]
        if let sessionId = context.sessionId {
            metadata["lastSessionId"] = sessionId
        }
        if let workspaceId = context.workspaceId {
            metadata["lastWorkspaceId"] = workspaceId
        }
        if let recordedAtMs = context.lastTimelinePayloadRecordedAtMs {
            metadata["lastTimelinePayloadRecordedAtMs"] = String(recordedAtMs)
        }
        if let bytes = context.lastTimelinePayloadBytes {
            metadata["lastTimelinePayloadBytes"] = String(bytes)
        }
        if let eventCount = context.lastTimelinePayloadEventCount {
            metadata["lastTimelinePayloadEventCount"] = String(eventCount)
        }
        if let largestEventBytes = context.lastTimelinePayloadLargestEventBytes {
            metadata["lastTimelinePayloadLargestEventBytes"] = String(largestEventBytes)
        }
        return metadata
    }

    private static func save(_ context: MetricKitCrashContext) {
        guard let data = try? JSONEncoder().encode(context) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(128))
    }
}

// MARK: - Payload item builder (internal for testing)

/// Converts a dictionary (from MX*.jsonRepresentation()) into a MetricKitPayloadItem.
/// Internal visibility so tests can exercise the summary/raw pipeline directly
/// without needing real MXMetricPayload instances (which only the system creates).
enum MetricKitPayloadItemBuilder {
    static func makeItem(
        from snapshot: [String: Any],
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64,
        context: [String: String] = [:]
    ) -> MetricKitPayloadItem {
        var enrichedSnapshot = snapshot
        if !context.isEmpty {
            enrichedSnapshot["oppiDiagnosticContext"] = context
        }

        let summary = summarize(enrichedSnapshot, context: context)
        return MetricKitPayloadItem(
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            summary: summary,
            raw: ["payload": jsonString(from: enrichedSnapshot)]
        )
    }

    private static func summarize(_ snapshot: [String: Any], context: [String: String]) -> [String: String] {
        var out: [String: String] = [
            "source": snapshot["type"] as? String ?? "MetricKit"
        ]

        addDiagnosticCounts(from: snapshot, to: &out)
        for (key, value) in context {
            guard out.count < 24, !key.isEmpty else { break }
            out[key] = String(value.prefix(140))
        }

        for (key, value) in snapshot {
            guard out.count < 24, !key.isEmpty else { continue }
            let safeKey = String(key.prefix(64))
            if out[safeKey] == nil {
                out[safeKey] = summarizeValue(value)
            }
        }

        return out
    }

    private static func addDiagnosticCounts(from snapshot: [String: Any], to out: inout [String: String]) {
        let fields = [
            ("crashDiagnostics", "crashDiagnosticCount"),
            ("hangDiagnostics", "hangDiagnosticCount"),
            ("cpuExceptionDiagnostics", "cpuExceptionDiagnosticCount"),
            ("diskWriteExceptionDiagnostics", "diskWriteExceptionDiagnosticCount"),
            ("appLaunchDiagnostics", "appLaunchDiagnosticCount"),
        ]

        for (payloadKey, summaryKey) in fields {
            if let diagnostics = snapshot[payloadKey] as? [Any] {
                out[summaryKey] = String(diagnostics.count)
            }
        }
    }

    private static func summarizeValue(_ value: Any) -> String {
        if let boolValue = value as? Bool {
            return boolValue ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let string = value as? String {
            return String(string.prefix(140))
        }
        if let date = value as? Date {
            return date.ISO8601Format()
        }
        if let dict = value as? [String: Any] {
            return String(
                String(jsonString(from: dict).prefix(140))
            )
        }
        return String(String(describing: value).prefix(140))
    }

    private static func jsonString(from value: Any) -> String {
        let jsonObject = convertForJSON(value)
        guard JSONSerialization.isValidJSONObject(jsonObject) else {
            return String(describing: value)
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return String(describing: value)
        }
    }

    private static func convertForJSON(_ value: Any) -> Any {
        if let value = value as? NSNumber {
            return value
        }
        if let value = value as? String {
            return value
        }
        if let value = value as? Bool {
            return value
        }
        if let value = value as? Date {
            return value.timeIntervalSince1970
        }
        if let value = value as? [String: Any] {
            return value.reduce(into: [String: Any]()) { partial, entry in
                partial[String(entry.key)] = convertForJSON(entry.value)
            }
        }
        if let value = value as? [Any] {
            return value.map(convertForJSON)
        }
        return String(describing: value)
    }
}

// MARK: - MX* payload → dictionary (private, thin layer over Apple's API)

private enum MetricKitPayloadSerializer {
    static func item(
        from payload: MXMetricPayload,
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64
    ) -> MetricKitPayloadItem {
        MetricKitPayloadItemBuilder.makeItem(
            from: dictionaryFrom(payload),
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs
        )
    }

    static func item(
        from payload: MXDiagnosticPayload,
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64,
        context: [String: String] = [:]
    ) -> MetricKitPayloadItem {
        MetricKitPayloadItemBuilder.makeItem(
            from: dictionaryFrom(payload),
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            context: context
        )
    }

    private static func dictionaryFrom(_ payload: MXMetricPayload) -> [String: Any] {
        let data = payload.jsonRepresentation()
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return ["type": "MXMetricPayload", "error": "json_parse_failed"]
    }

    private static func dictionaryFrom(_ payload: MXDiagnosticPayload) -> [String: Any] {
        let data = payload.jsonRepresentation()
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return ["type": "MXDiagnosticPayload", "error": "json_parse_failed"]
    }
}

actor ChatMetricsService {
    static let shared = ChatMetricsService()

    private var apiClient: APIClient?
    private var metadata: MetricKitUploadMetadata?
    private var backlog: [ChatMetricSample] = []
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
        if metadata == nil {
            metadata = MetricKitService.makeMetadata()
        }

        guard client != nil else {
            return
        }

        flushIfNeeded()
    }

    func record(
        metric: ChatMetricName,
        value: Double,
        unit: ChatMetricUnit,
        sessionId: String? = nil,
        workspaceId: String? = nil,
        tags: [String: String] = [:],
        timestampMs: Int64 = Date.nowMs()
    ) {
        guard value.isFinite else { return }
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }

        var trimmedTags: [String: String]? = nil
        if !tags.isEmpty {
            var out: [String: String] = [:]
            out.reserveCapacity(min(tags.count, 16))
            for (key, tagValue) in tags {
                if out.count >= 16 { break }
                let cleanKey = String(key.prefix(96))
                guard !cleanKey.isEmpty else { continue }
                out[cleanKey] = String(tagValue.prefix(256))
            }
            if !out.isEmpty {
                trimmedTags = out
            }
        }

        let sample = ChatMetricSample(
            ts: timestampMs,
            metric: metric,
            value: value,
            unit: unit,
            sessionId: sessionId.flatMap { $0.isEmpty ? nil : String($0.prefix(96)) },
            workspaceId: workspaceId.flatMap { $0.isEmpty ? nil : String($0.prefix(96)) },
            tags: trimmedTags
        )

        backlog.append(sample)
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

        guard let metadata else {
            return
        }

        guard let apiClient else {
            scheduleFlushTimerIfNeeded()
            return
        }

        while !backlog.isEmpty {
            let batch = Array(backlog.prefix(maxBatchSize))
            backlog.removeFirst(min(maxBatchSize, backlog.count))

            let request = ChatMetricUploadRequest(
                generatedAt: Date.nowMs(),
                appVersion: metadata.appVersion,
                buildNumber: metadata.buildNumber,
                osVersion: metadata.osVersion,
                deviceModel: metadata.deviceModel,
                samples: batch
            )

            do {
                try await apiClient.uploadChatMetrics(request: request)
            } catch {
                backlog = batch + backlog
                scheduleFlushTimerIfNeeded()
                return
            }
        }
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
