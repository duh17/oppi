import Foundation
import Testing
@testable import Oppi

/// Tests for MetricKit payload serialization.
///
/// We can't create real MXMetricPayload/MXDiagnosticPayload in tests — those come
/// from the system. But the core pipeline is: dictionary -> MetricKitPayloadItem.
/// That's what we test here, using dictionaries that match real jsonRepresentation() output.
@Suite("MetricKit serializer")
struct MetricKitSerializerTests {

    // MARK: - Metric payloads

    @Test func metricPayloadPreservesAllTopLevelKeys() {
        let dict: [String: Any] = [
            "appVersion": "1.0.0",
            "cpuMetrics": ["cumulativeCPUTime": "6879 sec", "cumulativeCPUInstructions": "50204015744 kiloinstructions"],
            "applicationTimeMetrics": ["cumulativeForegroundTime": "38371 sec", "cumulativeBackgroundTime": "1552 sec"],
            "displayMetrics": ["averagePixelLuminance": ["averageValue": "120 apl"]],
            "gpuMetrics": ["cumulativeGPUTime": "450 sec"],
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 1000,
            windowEndMs: 2000
        )

        #expect(item.kind == .metric)
        #expect(item.windowStartMs == 1000)
        #expect(item.windowEndMs == 2000)

        // Raw payload must contain the original keys as parseable JSON
        let rawPayload = item.raw["payload"] ?? ""
        #expect(!rawPayload.isEmpty, "raw payload must not be empty")

        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]
        #expect(parsed != nil, "raw payload must be valid JSON")
        #expect(parsed?["cpuMetrics"] != nil, "cpuMetrics must survive serialization")
        #expect(parsed?["applicationTimeMetrics"] != nil, "applicationTimeMetrics must survive")
        #expect(parsed?["gpuMetrics"] != nil, "gpuMetrics must survive")
    }

    @Test func metricPayloadSummaryIncludesTopLevelKeys() {
        let dict: [String: Any] = [
            "cpuMetrics": ["cumulativeCPUTime": "6879 sec"],
            "diskIOMetrics": ["cumulativeLogicalWrites": "150 MB"],
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        // Summary should have entries for each top-level key
        #expect(item.summary["cpuMetrics"] != nil)
        #expect(item.summary["diskIOMetrics"] != nil)
        #expect(item.summary["source"] == "MetricKit", "missing type key falls back to MetricKit")
    }

    // MARK: - Diagnostic payloads

    @Test func diagnosticPayloadPreservesCPUExceptions() {
        let dict: [String: Any] = [
            "cpuExceptionDiagnostics": [
                [
                    "callStackTree": ["callStackPerThread": false],
                    "totalCPUTime": "120 sec",
                ]
            ],
            "timeStampBegin": "2026-03-27 00:00:00 +0000",
            "timeStampEnd": "2026-03-28 00:00:00 +0000",
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .diagnostic,
            windowStartMs: 5000,
            windowEndMs: 6000
        )

        #expect(item.kind == .diagnostic)

        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]
        #expect(parsed?["cpuExceptionDiagnostics"] != nil, "CPU exception diagnostics must survive")
    }

    // MARK: - Empty/broken payloads (the old bug)

    @Test func emptyDictionaryProducesMinimalItem() {
        let item = MetricKitPayloadItemBuilder.makeItem(
            from: [:],
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        // Even empty dict should produce a valid item
        #expect(item.kind == .metric)
        #expect(item.summary["source"] == "MetricKit")

        // Raw should be parseable (even if empty object)
        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]
        #expect(parsed != nil, "raw must be valid JSON even for empty dict")
    }

    @Test func typeOnlyDictionaryIsTheOldBrokenCase() {
        // This is exactly what the Mirror-based serializer produced:
        // just {"type": "MXMetricPayload"} with no actual metrics.
        let brokenDict: [String: Any] = ["type": "MXMetricPayload"]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: brokenDict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]

        // This documents the broken state — only the type key, no metrics.
        // A real payload from jsonRepresentation() should have 10+ keys.
        #expect(parsed?.count == 1, "type-only dict has just 1 key (the old bug)")
        #expect(item.summary["source"] == "MXMetricPayload")
    }

    // MARK: - Summary truncation

    @Test func summaryCapsAt24Fields() {
        var dict: [String: Any] = [:]
        for i in 0..<30 {
            dict["field_\(i)"] = "value_\(i)"
        }

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        // 24 max from dict + 1 for "source" = at most 25, but source counts in the 24 budget
        #expect(item.summary.count <= 24)
    }

    @Test func summaryTruncatesLongValues() {
        let longValue = String(repeating: "x", count: 500)
        let dict: [String: Any] = ["bigField": longValue]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        let summarized = item.summary["bigField"] ?? ""
        #expect(summarized.count <= 140, "summary values capped at 140 chars")
    }

    // MARK: - Raw payload JSON fidelity

    @Test func rawPayloadPreservesNestedStructure() {
        let dict: [String: Any] = [
            "cpuMetrics": [
                "cumulativeCPUTime": "6879 sec",
                "cumulativeCPUInstructions": "50204015744 kiloinstructions",
            ] as [String: Any],
            "applicationLaunchMetrics": [
                "histogrammedResumeTime": [
                    "histogramNumBuckets": 3,
                    "histogramValue": [
                        ["bucketStart": "0 ms", "bucketEnd": "500 ms", "bucketCount": 12],
                        ["bucketStart": "500 ms", "bucketEnd": "1000 ms", "bucketCount": 3],
                    ],
                ] as [String: Any],
            ] as [String: Any],
        ]

        let item = MetricKitPayloadItemBuilder.makeItem(
            from: dict,
            kind: .metric,
            windowStartMs: 0,
            windowEndMs: 0
        )

        let rawPayload = item.raw["payload"] ?? ""
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(rawPayload.utf8)
        ) as? [String: Any]

        // Nested structure must survive
        let cpuMetrics = parsed?["cpuMetrics"] as? [String: Any]
        #expect(cpuMetrics?["cumulativeCPUTime"] as? String == "6879 sec")

        let launchMetrics = parsed?["applicationLaunchMetrics"] as? [String: Any]
        let resumeTime = launchMetrics?["histogrammedResumeTime"] as? [String: Any]
        #expect(resumeTime?["histogramNumBuckets"] as? Int == 3)
    }
}
