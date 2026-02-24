import Foundation
import OSLog

import MetricKit

private let metricKitLog = Logger(subsystem: AppIdentifiers.subsystem, category: "MetricKit")

final class MetricKitService: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricKitService()

    private let uploader = MetricKitUploadQueue()
    private var configured = false

    override private init() {}

    func configure() {
        guard !configured else { return }
        configured = true

        MXMetricManager.shared.add(self)
        metricKitLog.info("MetricKit subscriber registered")
    }

    func setUploadClient(_ client: APIClient?) {
        Task {
            await uploader.setClient(client)
            await uploader.setMetadata(Self.makeMetadata())
            await uploader.flushIfNeeded()
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard !payloads.isEmpty else { return }
        let now = nowMs()
        let items = payloads.compactMap { payload in
            MetricKitPayloadSerializer.item(
                from: payload,
                kind: .metric,
                windowStartMs: now,
                windowEndMs: now
            )
        }
        upload(items)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        let now = nowMs()
        let items = payloads.compactMap { payload in
            MetricKitPayloadSerializer.item(
                from: payload,
                kind: .diagnostic,
                windowStartMs: now,
                windowEndMs: now
            )
        }
        upload(items)
    }

    private func upload(_ items: [MetricKitPayloadItem]) {
        guard !items.isEmpty else { return }
        Task {
            await uploader.enqueue(payloads: items)
        }
    }

    private static func makeMetadata() -> MetricKitUploadMetadata {
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

    private func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
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
        guard !payloads.isEmpty else { return }

        backlog.append(contentsOf: payloads)
        if backlog.count > maxPending {
            backlog.removeFirst(backlog.count - maxPending)
        }

        flushIfNeeded()
    }

    func flushIfNeeded() {
        if uploading {
            return
        }

        Task {
            await self.flush()
        }
    }

    private func flush() async {
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
            let batch = Array(backlog.prefix(maxBatchSize))
            backlog.removeFirst(min(maxBatchSize, backlog.count))

            let request = MetricKitUploadRequest(
                generatedAt: nowMs(),
                appVersion: metadata.appVersion,
                buildNumber: metadata.buildNumber,
                osVersion: metadata.osVersion,
                deviceModel: metadata.deviceModel,
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

    private func nowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }
}

private enum MetricKitPayloadSerializer {
    static func item(
        from payload: MXMetricPayload,
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64
    ) -> MetricKitPayloadItem? {
        makeItem(
            from: objectDictionary(payload),
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs
        )
    }

    static func item(
        from payload: MXDiagnosticPayload,
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64
    ) -> MetricKitPayloadItem? {
        makeItem(
            from: objectDictionary(payload),
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs
        )
    }

    private static func makeItem(
        from snapshot: [String: Any],
        kind: MetricKitPayloadItem.Kind,
        windowStartMs: Int64,
        windowEndMs: Int64
    ) -> MetricKitPayloadItem {
        let summary = summarize(snapshot)
        return MetricKitPayloadItem(
            kind: kind,
            windowStartMs: windowStartMs,
            windowEndMs: windowEndMs,
            summary: summary,
            raw: ["payload": jsonString(from: snapshot)]
        )
    }

    private static func summarize(_ snapshot: [String: Any]) -> [String: String] {
        var out: [String: String] = [
            "source": snapshot["type"] as? String ?? "MetricKit"
        ]

        for (key, value) in snapshot {
            guard out.count < 24, !key.isEmpty else { continue }
            let safeKey = String(key.prefix(64))
            out[safeKey] = summarizeValue(value)
        }

        return out
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

    private static func objectDictionary(_ value: Any) -> [String: Any] {
        guard let object = value as? NSObject else {
            return ["payload": summarizeValue(value)]
        }

        if let encoded = objectToDictionary(object) {
            return encoded
        }

        return ["description": object.description]
    }

    private static func objectToDictionary(_ object: NSObject) -> [String: Any]? {
        let mirror = Mirror(reflecting: object)
        var result: [String: Any] = [
            "type": String(describing: type(of: object))
        ]

        for child in mirror.children {
            guard let key = child.label else { continue }
            result[String(key)] = sanitize(value: child.value)
        }

        return result.isEmpty ? nil : result
    }

    private static func sanitize(value: Any?) -> Any {
        guard let value else { return "" }

        if let boolValue = value as? Bool { return boolValue }
        if let number = value as? NSNumber { return number }
        if let string = value as? String { return string.prefix(240) }
        if let date = value as? Date { return date }

        if let obj = value as? NSObject {
            return objectToDictionary(obj) ?? obj.description
        }

        if let array = value as? [Any] {
            return array.prefix(16).map(sanitize)
        }

        return String(describing: value)
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

        if let nsObject = value as? NSObject,
           let dict = objectToDictionary(nsObject) {
            return dict
        }

        return String(describing: value)
    }
}
