import Foundation
import Testing
@testable import Oppi

@Suite("Server Stats Models")
struct ServerStatsTests {

    // MARK: - JSON Helpers

    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Full ServerStats Decoding

    @Test func decodesFullResponse() throws {
        let json = """
        {
          "memory": {
            "heapUsed": 128.5,
            "heapTotal": 256.0,
            "rss": 312.7,
            "external": 8.3
          },
          "activeSessions": [
            {
              "id": "abc-123",
              "status": "busy",
              "model": "claude-sonnet-4-20250514",
              "cost": 0.42,
              "name": "Refactor auth",
              "firstMessage": "Fix the login flow",
              "workspaceName": "oppi",
              "thinkingLevel": "high",
              "parentSessionId": null,
              "contextTokens": 12000,
              "contextWindow": 200000,
              "createdAt": 1711100000000
            }
          ],
          "daily": [
            {
              "date": "2025-03-20",
              "sessions": 5,
              "cost": 1.23,
              "tokens": 50000,
              "byModel": {
                "claude-sonnet-4-20250514": { "sessions": 3, "cost": 0.80, "tokens": 30000 },
                "claude-haiku-3": { "sessions": 2, "cost": 0.43, "tokens": 20000 }
              }
            },
            {
              "date": "2025-03-21",
              "sessions": 8,
              "cost": 2.10,
              "tokens": 80000,
              "byModel": {
                "claude-sonnet-4-20250514": { "sessions": 8, "cost": 2.10, "tokens": 80000 }
              }
            }
          ],
          "modelBreakdown": [
            {
              "model": "claude-sonnet-4-20250514",
              "sessions": 11,
              "cost": 2.90,
              "tokens": 110000,
              "cacheRead": 45000,
              "cacheWrite": 12000,
              "share": 0.87
            },
            {
              "model": "claude-haiku-3",
              "sessions": 2,
              "cost": 0.43,
              "tokens": 20000,
              "cacheRead": 5000,
              "cacheWrite": 1000,
              "share": 0.13
            }
          ],
          "workspaceBreakdown": [
            { "id": "ws-1", "name": "oppi", "sessions": 10, "cost": 2.50 },
            { "id": "ws-2", "name": "mlx-server", "sessions": 3, "cost": 0.83 }
          ],
          "totals": {
            "sessions": 13,
            "cost": 3.33,
            "tokens": 130000
          }
        }
        """
        let stats = try decode(json, as: ServerStats.self)

        // Totals
        #expect(stats.totals.sessions == 13)
        #expect(stats.totals.cost == 3.33)
        #expect(stats.totals.tokens == 130000)

        // Memory
        #expect(stats.memory.heapUsed == 128.5)
        #expect(stats.memory.rss == 312.7)
        #expect(stats.memory.external == 8.3)

        // Active sessions
        #expect(stats.activeSessions.count == 1)
        let session = stats.activeSessions[0]
        #expect(session.id == "abc-123")
        #expect(session.status == "busy")
        #expect(session.model == "claude-sonnet-4-20250514")
        #expect(session.cost == 0.42)
        #expect(session.name == "Refactor auth")
        #expect(session.thinkingLevel == "high")
        #expect(session.contextTokens == 12000)
        #expect(session.contextWindow == 200000)
        #expect(session.parentSessionId == nil)

        // Daily
        #expect(stats.daily.count == 2)
        #expect(stats.daily[0].date == "2025-03-20")
        #expect(stats.daily[1].sessions == 8)

        // Model breakdown
        #expect(stats.modelBreakdown.count == 2)
        #expect(stats.modelBreakdown[0].model == "claude-sonnet-4-20250514")
        #expect(stats.modelBreakdown[0].cacheRead == 45000)
        #expect(stats.modelBreakdown[0].cacheWrite == 12000)
        #expect(stats.modelBreakdown[0].share == 0.87)

        // Workspace breakdown
        #expect(stats.workspaceBreakdown.count == 2)
        #expect(stats.workspaceBreakdown[0].name == "oppi")
        #expect(stats.workspaceBreakdown[1].cost == 0.83)
    }

    // MARK: - Minimal / Missing Optional Fields

    @Test func decodesMinimalActiveSession() throws {
        let json = """
        {
          "id": "sess-min",
          "status": "idle",
          "cost": 0
        }
        """
        let session = try decode(json, as: StatsActiveSession.self)

        #expect(session.id == "sess-min")
        #expect(session.model == nil)
        #expect(session.name == nil)
        #expect(session.firstMessage == nil)
        #expect(session.workspaceName == nil)
        #expect(session.thinkingLevel == nil)
        #expect(session.parentSessionId == nil)
        #expect(session.contextTokens == nil)
        #expect(session.contextWindow == nil)
        #expect(session.createdAt == nil)
    }

    @Test func decodesActiveSessionWithExplicitNulls() throws {
        let json = """
        {
          "id": "sess-nulls",
          "status": "idle",
          "model": null,
          "cost": 0,
          "name": null,
          "firstMessage": null,
          "workspaceName": null,
          "thinkingLevel": null,
          "parentSessionId": null,
          "contextTokens": null,
          "contextWindow": null,
          "createdAt": null
        }
        """
        let session = try decode(json, as: StatsActiveSession.self)

        #expect(session.model == nil)
        #expect(session.name == nil)
        #expect(session.createdAt == nil)
    }

    @Test func decodesDailyEntryWithNullByModel() throws {
        // iOS type marks byModel as optional; server always sends it,
        // but the client should tolerate null or missing gracefully.
        let json = """
        {
          "date": "2025-03-22",
          "sessions": 3,
          "cost": 0.50,
          "tokens": 10000,
          "byModel": null
        }
        """
        let entry = try decode(json, as: StatsDailyEntry.self)

        #expect(entry.byModel == nil)
        #expect(entry.sessions == 3)
    }

    @Test func decodesDailyEntryWithMissingByModel() throws {
        let json = """
        {
          "date": "2025-03-22",
          "sessions": 3,
          "cost": 0.50,
          "tokens": 10000
        }
        """
        let entry = try decode(json, as: StatsDailyEntry.self)

        #expect(entry.byModel == nil)
    }

    @Test func decodesModelBreakdownWithNullCacheFields() throws {
        // iOS marks cacheRead/cacheWrite optional; server sends them non-null.
        // Verify the optional path works for robustness.
        let json = """
        {
          "model": "gpt-4o",
          "sessions": 5,
          "cost": 1.20,
          "tokens": 50000,
          "cacheRead": null,
          "cacheWrite": null,
          "share": 0.50
        }
        """
        let breakdown = try decode(json, as: StatsModelBreakdown.self)

        #expect(breakdown.cacheRead == nil)
        #expect(breakdown.cacheWrite == nil)
        #expect(breakdown.share == 0.50)
    }

    @Test func decodesModelBreakdownWithMissingCacheFields() throws {
        let json = """
        {
          "model": "gpt-4o",
          "sessions": 5,
          "cost": 1.20,
          "tokens": 50000,
          "share": 0.50
        }
        """
        let breakdown = try decode(json, as: StatsModelBreakdown.self)

        #expect(breakdown.cacheRead == nil)
        #expect(breakdown.cacheWrite == nil)
    }

    // MARK: - Empty Arrays

    @Test func decodesEmptyArraysGracefully() throws {
        let json = """
        {
          "memory": { "heapUsed": 0, "heapTotal": 0, "rss": 0, "external": 0 },
          "activeSessions": [],
          "daily": [],
          "modelBreakdown": [],
          "workspaceBreakdown": [],
          "totals": { "sessions": 0, "cost": 0, "tokens": 0 }
        }
        """
        let stats = try decode(json, as: ServerStats.self)

        #expect(stats.activeSessions.isEmpty)
        #expect(stats.daily.isEmpty)
        #expect(stats.modelBreakdown.isEmpty)
        #expect(stats.workspaceBreakdown.isEmpty)
        #expect(stats.totals.sessions == 0)
        #expect(stats.totals.cost == 0)
        #expect(stats.totals.tokens == 0)
    }

    // MARK: - Zero Cost Edge Cases

    @Test func decodesZeroCostModelBreakdown() throws {
        // Server bug or edge: model used 0 sessions but has cost (shouldn't happen,
        // but the client shouldn't crash)
        let json = """
        {
          "model": "phantom-model",
          "sessions": 0,
          "cost": 0.01,
          "tokens": 0,
          "cacheRead": 0,
          "cacheWrite": 0,
          "share": 0
        }
        """
        let breakdown = try decode(json, as: StatsModelBreakdown.self)

        #expect(breakdown.sessions == 0)
        #expect(breakdown.cost == 0.01)
        #expect(breakdown.share == 0)
    }

    @Test func decodesZeroCostWorkspace() throws {
        let json = """
        { "id": "ws-empty", "name": "ghost", "sessions": 0, "cost": 0 }
        """
        let ws = try decode(json, as: StatsWorkspaceBreakdown.self)

        #expect(ws.sessions == 0)
        #expect(ws.cost == 0)
    }

    @Test func decodesWorkspaceWithNullName() throws {
        // Server sends workspace name, but handle null for robustness
        let json = """
        { "id": "ws-noname", "name": null, "sessions": 1, "cost": 0.10 }
        """
        let ws = try decode(json, as: StatsWorkspaceBreakdown.self)

        #expect(ws.name == nil)
        #expect(ws.id == "ws-noname")
    }

    // MARK: - DailyDetail Decoding

    @Test func decodesDailyDetailFull() throws {
        let json = """
        {
          "date": "2025-03-22",
          "totals": { "sessions": 4, "cost": 1.50, "tokens": 40000 },
          "hourly": [
            {
              "hour": 9,
              "sessions": 2,
              "cost": 0.80,
              "tokens": 20000,
              "byModel": {
                "claude-sonnet-4-20250514": { "sessions": 2, "cost": 0.80, "tokens": 20000 }
              }
            },
            {
              "hour": 14,
              "sessions": 2,
              "cost": 0.70,
              "tokens": 20000,
              "byModel": null
            }
          ],
          "sessions": [
            {
              "id": "s1",
              "name": "Morning fix",
              "model": "claude-sonnet-4-20250514",
              "cost": 0.40,
              "tokens": 10000,
              "createdAt": 1711100000000,
              "workspaceName": "oppi",
              "status": "stopped"
            },
            {
              "id": "s2",
              "name": null,
              "model": null,
              "cost": 0,
              "tokens": 0,
              "createdAt": 1711110000000,
              "workspaceName": null,
              "status": "error"
            }
          ]
        }
        """
        let detail = try decode(json, as: DailyDetail.self)

        #expect(detail.date == "2025-03-22")
        #expect(detail.totals.sessions == 4)
        #expect(detail.totals.cost == 1.50)

        // Hourly
        #expect(detail.hourly.count == 2)
        #expect(detail.hourly[0].hour == 9)
        #expect(detail.hourly[0].sessions == 2)
        #expect(detail.hourly[1].hour == 14)
        #expect(detail.hourly[1].byModel == nil)

        // Sessions
        #expect(detail.sessions.count == 2)
        #expect(detail.sessions[0].name == "Morning fix")
        #expect(detail.sessions[1].model == nil)
        #expect(detail.sessions[1].name == nil)
        #expect(detail.sessions[1].status == "error")
    }

    @Test func decodesDailyDetailWithEmptyHourlyAndSessions() throws {
        let json = """
        {
          "date": "2025-01-01",
          "totals": { "sessions": 0, "cost": 0, "tokens": 0 },
          "hourly": [],
          "sessions": []
        }
        """
        let detail = try decode(json, as: DailyDetail.self)

        #expect(detail.hourly.isEmpty)
        #expect(detail.sessions.isEmpty)
        #expect(detail.totals.sessions == 0)
    }

    @Test func decodesHourlyEntryWithEmptyByModel() throws {
        let json = """
        {
          "hour": 0,
          "sessions": 1,
          "cost": 0.01,
          "tokens": 100,
          "byModel": {}
        }
        """
        let entry = try decode(json, as: StatsDailyHourlyEntry.self)

        #expect(entry.hour == 0)
        #expect(entry.byModel?.isEmpty == true)
    }

    @Test func decodesHourBoundaries() throws {
        // Hour 0 and 23 are valid extremes
        for hour in [0, 23] {
            let json = """
            { "hour": \(hour), "sessions": 1, "cost": 0, "tokens": 0, "byModel": {} }
            """
            let entry = try decode(json, as: StatsDailyHourlyEntry.self)
            #expect(entry.hour == hour)
        }
    }

    // MARK: - StatsMetric Enum

    @Test func statsMetricRawValueRoundTrip() {
        for metric in StatsMetric.allCases {
            let raw = metric.rawValue
            let decoded = StatsMetric(rawValue: raw)
            #expect(decoded == metric)
        }
    }

    @Test func statsMetricAllCasesCoversThree() {
        #expect(StatsMetric.allCases.count == 3)
        #expect(StatsMetric.allCases.contains(.sessions))
        #expect(StatsMetric.allCases.contains(.cost))
        #expect(StatsMetric.allCases.contains(.tokens))
    }

    @Test func statsMetricChartTitles() {
        #expect(StatsMetric.sessions.chartTitle == "Daily Sessions")
        #expect(StatsMetric.cost.chartTitle == "Daily Cost")
        #expect(StatsMetric.tokens.chartTitle == "Daily Tokens")
    }

    @Test func statsMetricInvalidRawValueReturnsNil() {
        #expect(StatsMetric(rawValue: "bandwidth") == nil)
        #expect(StatsMetric(rawValue: "") == nil)
    }

    // MARK: - StatsActiveSession Computed Properties

    @Test func displayTitlePrefersName() throws {
        let json = """
        {
          "id": "abc-12345678-rest",
          "status": "idle",
          "cost": 0,
          "name": "Refactor auth",
          "firstMessage": "Please fix the login"
        }
        """
        let session = try decode(json, as: StatsActiveSession.self)
        #expect(session.displayTitle == "Refactor auth")
    }

    @Test func displayTitleFallsBackToFirstMessage() throws {
        let json = """
        {
          "id": "abc-12345678-rest",
          "status": "idle",
          "cost": 0,
          "firstMessage": "Please fix the login flow for me"
        }
        """
        let session = try decode(json, as: StatsActiveSession.self)
        #expect(session.displayTitle == "Please fix the login flow for me")
    }

    @Test func displayTitleTruncatesLongFirstMessage() throws {
        let longMessage = String(repeating: "a", count: 120)
        let json = """
        {
          "id": "abc-12345678-rest",
          "status": "idle",
          "cost": 0,
          "firstMessage": "\(longMessage)"
        }
        """
        let session = try decode(json, as: StatsActiveSession.self)
        #expect(session.displayTitle.count == 80)
    }

    @Test func displayTitleFallsBackToSessionId() throws {
        let json = """
        { "id": "abc-12345678-rest", "status": "idle", "cost": 0 }
        """
        let session = try decode(json, as: StatsActiveSession.self)
        #expect(session.displayTitle == "Session abc-1234")
    }

    @Test func displayTitleIgnoresWhitespaceOnlyName() throws {
        let json = """
        {
          "id": "abc-12345678-rest",
          "status": "idle",
          "cost": 0,
          "name": "   ",
          "firstMessage": "real message"
        }
        """
        let session = try decode(json, as: StatsActiveSession.self)
        #expect(session.displayTitle == "real message")
    }

    @Test func displayTitleIgnoresEmptyName() throws {
        let json = """
        {
          "id": "abc-12345678-rest",
          "status": "idle",
          "cost": 0,
          "name": "",
          "firstMessage": "fallback"
        }
        """
        let session = try decode(json, as: StatsActiveSession.self)
        #expect(session.displayTitle == "fallback")
    }

    @Test func displayTitleIgnoresWhitespaceOnlyFirstMessage() throws {
        let json = """
        {
          "id": "abc-12345678-rest",
          "status": "idle",
          "cost": 0,
          "firstMessage": "\\n  \\t  "
        }
        """
        let session = try decode(json, as: StatsActiveSession.self)
        #expect(session.displayTitle == "Session abc-1234")
    }

    @Test func isBusyForBusyAndStartingStatus() throws {
        for status in ["busy", "starting"] {
            let json = """
            { "id": "s1", "status": "\(status)", "cost": 0 }
            """
            let session = try decode(json, as: StatsActiveSession.self)
            #expect(session.isBusy, "Expected isBusy=true for status '\(status)'")
        }
    }

    @Test func isNotBusyForOtherStatuses() throws {
        for status in ["idle", "stopped", "error", "waiting", "unknown"] {
            let json = """
            { "id": "s1", "status": "\(status)", "cost": 0 }
            """
            let session = try decode(json, as: StatsActiveSession.self)
            #expect(!session.isBusy, "Expected isBusy=false for status '\(status)'")
        }
    }

    // MARK: - Memory Edge Cases

    @Test func decodesNegativeMemoryValues() throws {
        // Server bug: negative values shouldn't crash decoding
        let json = """
        { "heapUsed": -1.5, "heapTotal": 0, "rss": -100, "external": -0.01 }
        """
        let memory = try decode(json, as: StatsMemory.self)

        #expect(memory.heapUsed == -1.5)
        #expect(memory.rss == -100)
    }

    @Test func decodesLargeMemoryValues() throws {
        let json = """
        { "heapUsed": 8192.99, "heapTotal": 16384.0, "rss": 32768.5, "external": 4096.0 }
        """
        let memory = try decode(json, as: StatsMemory.self)

        #expect(memory.heapTotal == 16384.0)
    }

    // MARK: - Floating Point Precision

    @Test func decodesFractionalCostPrecision() throws {
        let json = """
        { "sessions": 1, "cost": 0.001, "tokens": 100 }
        """
        let totals = try decode(json, as: StatsTotals.self)

        #expect(totals.cost == 0.001)
    }

    @Test func decodesLargeCostValues() throws {
        let json = """
        { "sessions": 9999, "cost": 12345.67, "tokens": 999999999 }
        """
        let totals = try decode(json, as: StatsTotals.self)

        #expect(totals.sessions == 9999)
        #expect(totals.cost == 12345.67)
        #expect(totals.tokens == 999999999)
    }

    // MARK: - ByModel Dictionary Decoding

    @Test func decodesByModelWithMultipleEntries() throws {
        let json = """
        {
          "date": "2025-03-22",
          "sessions": 10,
          "cost": 5.0,
          "tokens": 100000,
          "byModel": {
            "claude-sonnet-4-20250514": { "sessions": 5, "cost": 3.0, "tokens": 60000 },
            "claude-haiku-3": { "sessions": 3, "cost": 1.5, "tokens": 30000 },
            "gpt-4o": { "sessions": 2, "cost": 0.5, "tokens": 10000 }
          }
        }
        """
        let entry = try decode(json, as: StatsDailyEntry.self)

        #expect(entry.byModel?.count == 3)
        #expect(entry.byModel?["claude-sonnet-4-20250514"]?.sessions == 5)
        #expect(entry.byModel?["gpt-4o"]?.cost == 0.5)
    }

    @Test func decodesByModelWithEmptyDictionary() throws {
        let json = """
        {
          "date": "2025-03-22",
          "sessions": 0,
          "cost": 0,
          "tokens": 0,
          "byModel": {}
        }
        """
        let entry = try decode(json, as: StatsDailyEntry.self)

        #expect(entry.byModel?.isEmpty == true)
    }

    // MARK: - DailyModelEntry Decoding

    @Test func decodesDailyModelEntry() throws {
        let json = """
        { "sessions": 7, "cost": 2.34, "tokens": 45000 }
        """
        let entry = try decode(json, as: DailyModelEntry.self)

        #expect(entry.sessions == 7)
        #expect(entry.cost == 2.34)
        #expect(entry.tokens == 45000)
    }

    // MARK: - Cache Fields in Model Breakdown

    @Test func decodesModelBreakdownWithCacheStats() throws {
        let json = """
        {
          "model": "claude-sonnet-4-20250514",
          "sessions": 20,
          "cost": 5.0,
          "tokens": 200000,
          "cacheRead": 80000,
          "cacheWrite": 25000,
          "share": 0.75
        }
        """
        let breakdown = try decode(json, as: StatsModelBreakdown.self)

        #expect(breakdown.cacheRead == 80000)
        #expect(breakdown.cacheWrite == 25000)
        // Cache tokens are a significant fraction of total
        let cacheTotal = (breakdown.cacheRead ?? 0) + (breakdown.cacheWrite ?? 0)
        #expect(cacheTotal == 105000)
    }

    @Test func decodesModelBreakdownWithZeroCacheValues() throws {
        let json = """
        {
          "model": "local-model",
          "sessions": 3,
          "cost": 0,
          "tokens": 5000,
          "cacheRead": 0,
          "cacheWrite": 0,
          "share": 0
        }
        """
        let breakdown = try decode(json, as: StatsModelBreakdown.self)

        #expect(breakdown.cacheRead == 0)
        #expect(breakdown.cacheWrite == 0)
    }

    // MARK: - ServerInfo Presentation Helpers

    @Test func uptimeLabelFormatsDays() {
        let info = makeServerInfo(uptime: 2 * 86400 + 14 * 3600)
        #expect(info.uptimeLabel == "2d 14h")
    }

    @Test func uptimeLabelFormatsHoursAndMinutes() {
        let info = makeServerInfo(uptime: 3 * 3600 + 25 * 60)
        #expect(info.uptimeLabel == "3h 25m")
    }

    @Test func uptimeLabelFormatsMinutesAndSeconds() {
        let info = makeServerInfo(uptime: 12 * 60 + 45)
        #expect(info.uptimeLabel == "12m 45s")
    }

    @Test func uptimeLabelFormatsSecondsOnly() {
        let info = makeServerInfo(uptime: 30)
        #expect(info.uptimeLabel == "30s")
    }

    @Test func uptimeLabelFormatsZero() {
        let info = makeServerInfo(uptime: 0)
        #expect(info.uptimeLabel == "0s")
    }

    @Test func platformLabelMapsDarwin() {
        let info = makeServerInfo(os: "darwin", arch: "arm64")
        #expect(info.platformLabel == "macOS arm64")
    }

    @Test func platformLabelMapsLinux() {
        let info = makeServerInfo(os: "linux", arch: "x64")
        #expect(info.platformLabel == "Linux x64")
    }

    @Test func platformLabelMapsWindows() {
        let info = makeServerInfo(os: "win32", arch: "x64")
        #expect(info.platformLabel == "Windows x64")
    }

    @Test func platformLabelPassesUnknownOSThrough() {
        let info = makeServerInfo(os: "freebsd", arch: "riscv64")
        #expect(info.platformLabel == "freebsd riscv64")
    }

    // MARK: - StatsDailySession (non-optional createdAt)

    @Test func decodesDailySessionWithAllFields() throws {
        let json = """
        {
          "id": "ds-1",
          "name": "Test session",
          "model": "claude-sonnet-4-20250514",
          "cost": 0.55,
          "tokens": 15000,
          "createdAt": 1711100000000,
          "workspaceName": "oppi",
          "status": "stopped"
        }
        """
        let session = try decode(json, as: StatsDailySession.self)

        #expect(session.id == "ds-1")
        #expect(session.name == "Test session")
        #expect(session.createdAt == 1711100000000)
        #expect(session.status == "stopped")
    }

    @Test func decodesDailySessionWithMinimalFields() throws {
        let json = """
        {
          "id": "ds-min",
          "cost": 0,
          "tokens": 0,
          "createdAt": 0,
          "status": "error"
        }
        """
        let session = try decode(json, as: StatsDailySession.self)

        #expect(session.name == nil)
        #expect(session.model == nil)
        #expect(session.workspaceName == nil)
        #expect(session.createdAt == 0)
    }

    // MARK: - Sendable Conformance (compile-time check)

    @Test func sendableConformanceCompiles() async {
        // This test verifies Sendable conformance at compile time by passing
        // values across an async boundary.
        let stats = ServerStats(
            memory: StatsMemory(heapUsed: 1, heapTotal: 2, rss: 3, external: 4),
            activeSessions: [],
            daily: [],
            modelBreakdown: [],
            workspaceBreakdown: [],
            totals: StatsTotals(sessions: 0, cost: 0, tokens: 0)
        )

        let result: ServerStats = await Task.detached {
            return stats
        }.value

        #expect(result.totals.sessions == 0)
    }

    // MARK: - ServerInfo Full Decoding

    @Test func decodesServerInfoFull() throws {
        let json = """
        {
          "name": "my-server",
          "version": "1.2.3",
          "uptime": 3600,
          "os": "darwin",
          "arch": "arm64",
          "hostname": "mac-studio",
          "nodeVersion": "v22.0.0",
          "piVersion": "0.9.0",
          "configVersion": 5,
          "identity": {
            "fingerprint": "SHA256:abc123",
            "keyId": "key-1",
            "algorithm": "ed25519"
          },
          "runtimeUpdate": {
            "packageName": "@anthropic/pi",
            "currentVersion": "1.2.3",
            "latestVersion": "1.3.0",
            "pendingVersion": null,
            "updateAvailable": true,
            "canUpdate": true,
            "checking": false,
            "updateInProgress": false,
            "restartRequired": false,
            "lastCheckedAt": 1711100000000,
            "checkError": null,
            "lastUpdatedAt": null,
            "lastUpdateError": null
          },
          "stats": {
            "workspaceCount": 3,
            "activeSessionCount": 2,
            "totalSessionCount": 150,
            "skillCount": 12,
            "modelCount": 5
          }
        }
        """
        let info = try decode(json, as: ServerInfo.self)

        #expect(info.name == "my-server")
        #expect(info.version == "1.2.3")
        #expect(info.uptime == 3600)
        #expect(info.hostname == "mac-studio")
        #expect(info.configVersion == 5)

        #expect(info.identity?.fingerprint == "SHA256:abc123")
        #expect(info.identity?.algorithm == "ed25519")

        #expect(info.runtimeUpdate?.updateAvailable == true)
        #expect(info.runtimeUpdate?.latestVersion == "1.3.0")
        #expect(info.runtimeUpdate?.pendingVersion == nil)

        #expect(info.stats.workspaceCount == 3)
        #expect(info.stats.skillCount == 12)
    }

    @Test func decodesServerInfoWithNullOptionals() throws {
        let json = """
        {
          "name": "bare-server",
          "version": "0.1.0",
          "uptime": 0,
          "os": "linux",
          "arch": "x64",
          "hostname": "ci-runner",
          "nodeVersion": "v20.0.0",
          "piVersion": "0.1.0",
          "configVersion": 1,
          "identity": null,
          "runtimeUpdate": null,
          "stats": {
            "workspaceCount": 0,
            "activeSessionCount": 0,
            "totalSessionCount": 0,
            "skillCount": 0,
            "modelCount": 0
          }
        }
        """
        let info = try decode(json, as: ServerInfo.self)

        #expect(info.identity == nil)
        #expect(info.runtimeUpdate == nil)
        #expect(info.stats.totalSessionCount == 0)
    }

    // MARK: - Helpers

    private func makeServerInfo(
        uptime: Int = 0,
        os: String = "darwin",
        arch: String = "arm64"
    ) -> ServerInfo {
        ServerInfo(
            name: "test",
            version: "1.0.0",
            uptime: uptime,
            os: os,
            arch: arch,
            hostname: "test-host",
            nodeVersion: "v22.0.0",
            piVersion: "0.9.0",
            configVersion: 1,
            identity: nil,
            runtimeUpdate: nil,
            stats: ServerInfo.ServerStats(
                workspaceCount: 0,
                activeSessionCount: 0,
                totalSessionCount: 0,
                skillCount: 0,
                modelCount: 0
            )
        )
    }
}
