import Foundation
import Testing
@testable import Oppi

@Suite("Server Metrics page")
@MainActor
struct ServerMetricsPageTests {
    /// Shape of `GET /server/metrics` as the server writes it, including a
    /// pre-host-sampling gap (`null`) and a sample without a `host` block.
    private static let responseJSON = """
    {
      "enabled": true,
      "intervalMs": 30000,
      "serverStartedAt": 1792100000000,
      "platform": "darwin",
      "arch": "arm64",
      "latest": {
        "ts": 1792108773159,
        "cpu": { "user": 8.73, "system": 0.85, "total": 9.58 },
        "memory": { "heapUsed": 217.25, "heapTotal": 272.91, "rss": 845.41, "external": 23.67 },
        "sessions": { "busy": 2, "ready": 4, "starting": 0, "total": 6, "peak": 6 },
        "wsConnections": 0,
        "eventLoop": { "p50": 21.79, "p95": 22.43, "p99": 23.95, "max": 141.82 },
        "host": { "scope": "host", "cpu": 12.5, "cpuCores": 32, "load1": 4.43,
                  "memUsed": 283000, "memTotal": 524288, "diskUsed": 1500000, "diskTotal": 3800000 }
      },
      "history": {
        "range": "24h",
        "bucketMs": 300000,
        "ts": [1792108200000, 1792108500000],
        "series": {
          "cpu": { "avg": [null, 9.58], "max": [null, 30] },
          "hostCpu": { "avg": [null, 12.5], "max": [null, 40] },
          "sessions": { "avg": [null, 6], "max": [null, 7] }
        }
      }
    }
    """

    private func snapshot(_ json: String = responseJSON) throws -> ServerMetricsSnapshot {
        try JSONDecoder().decode(ServerMetricsSnapshot.self, from: Data(json.utf8))
    }

    @Test func decodesTheServerResponseWithGaps() throws {
        let value = try snapshot()
        #expect(value.latest?.host?.memTotal == 524288)
        #expect(value.history?.series(.cpu)?.avg == [nil, 9.58])
        #expect(value.history?.series(.diskUsed) == nil)
    }

    @Test func offSnapshotDecodesWithoutSamples() throws {
        let value = try snapshot("""
        {"enabled":false,"intervalMs":30000,"serverStartedAt":1,"platform":"linux",
         "arch":"x64","latest":null,"history":null}
        """)
        #expect(!value.enabled)
        #expect(value.latest == nil && value.history == nil)
    }

    @Test func cardsReadLatestValuesAndPeaks() throws {
        let model = ServerMetricsPageModel(
            snapshot: try snapshot(),
            range: .day,
            now: Date(timeIntervalSince1970: 1_792_100_000 + 2 * 3600 + 32 * 60)
        )
        let palette = ThemeID.dark.palette
        #expect(model.hasHostData)
        #expect(model.hostTitle == "Host")
        #expect(model.hostCPU(palette: palette).value == "13%")
        #expect(model.hostCPU(palette: palette).detail == "32 cores · load 4.43 · peak 40%")
        #expect(model.hostMemory(palette: palette).value == "276 GB of 512 GB")
        #expect(model.processCPU(palette: palette).detail == "Share of one core · peak 30%")
        #expect(model.activity(palette: palette).value == "6 active · 2 busy")
        #expect(model.activity(palette: palette).detail == "0 connections · up 2h 32m · macOS arm64")
    }

    private func containerJSON(limited: Bool) -> String {
        let host = limited
            ? #""scope": "container", "cpu": 12.5, "cpuCores": 1.5, "cpuLimited": true, "memLimited": true,"#
            : #""scope": "container", "cpu": 12.5, "cpuCores": 32,"#
        return Self.responseJSON.replacingOccurrences(
            of: #""scope": "host", "cpu": 12.5, "cpuCores": 32, "load1": 4.43,"#,
            with: host
        )
    }

    @Test func containerCardsDescribeItsLimits() throws {
        let model = ServerMetricsPageModel(snapshot: try snapshot(containerJSON(limited: true)), range: .day, now: Date())
        let palette = ThemeID.dark.palette
        #expect(model.hostTitle == "Container")
        #expect(model.hostCPU(palette: palette).detail == "1.5 cores limit \u{00B7} peak 40%")
        #expect(model.hostMemory(palette: palette).detail.contains("of the container limit"))
    }

    @Test func unlimitedContainerNeverCallsTheMachineItsLimit() throws {
        let model = ServerMetricsPageModel(snapshot: try snapshot(containerJSON(limited: false)), range: .day, now: Date())
        let palette = ThemeID.dark.palette
        #expect(model.hostTitle == "Container")
        #expect(model.hostCPU(palette: palette).detail == "32 cores \u{00B7} peak 40%")
        #expect(!model.hostMemory(palette: palette).detail.contains("limit"))
    }

    @Test func hostSectionHidesForSamplesWrittenBeforeHostSampling() throws {
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(Self.responseJSON.utf8)) as? [String: Any]
        )
        var latest = try #require(root["latest"] as? [String: Any])
        latest.removeValue(forKey: "host")
        root["latest"] = latest
        var history = try #require(root["history"] as? [String: Any])
        var series = try #require(history["series"] as? [String: Any])
        series.removeValue(forKey: "hostCpu")
        history["series"] = series
        root["history"] = history
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)

        let model = ServerMetricsPageModel(snapshot: try snapshot(json), range: .day, now: Date())
        #expect(!model.hasHostData)
    }

    @Test func scrubReadoutNamesGapsInsteadOfInventingValues() throws {
        let model = ServerMetricsPageModel(snapshot: try snapshot(), range: .day, now: Date())
        let chart = model.processCPU(palette: ThemeID.dark.palette).chart
        #expect(chart.readout(at: 0)?.value == "—")
        #expect(chart.readout(at: 1)?.value == "10%")
        #expect(chart.readout(at: 2) == nil)
    }

    @Test func sessionsChartFitsConnectionsAndNamesThemInTheReadout() throws {
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(Self.responseJSON.utf8)) as? [String: Any]
        )
        var history = try #require(root["history"] as? [String: Any])
        var series = try #require(history["series"] as? [String: Any])
        series["wsConnections"] = ["avg": [NSNull(), 9], "max": [NSNull(), 12]]
        history["series"] = series
        root["history"] = history
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)

        let chart = ServerMetricsPageModel(snapshot: try snapshot(json), range: .day, now: Date())
            .activity(palette: ThemeID.dark.palette).chart
        #expect(chart.yMax >= 12)
        #expect(chart.readout(at: 1)?.value == "7 sessions, 12 connections")
    }

    @Test func megabytesScaleToGigabytesAndTerabytes() {
        #expect(ServerMetricsFormat.megabytes(845.4) == "845 MB")
        #expect(ServerMetricsFormat.megabytes(1536) == "1.5 GB")
        #expect(ServerMetricsFormat.megabytes(3_800_000) == "3.6 TB")
    }
}
