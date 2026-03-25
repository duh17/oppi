import Testing
import Foundation
@testable import Oppi

// MARK: - displayTitle

@Suite("StatsActiveSession — displayTitle")
struct DisplayTitleTests {

    private func makeSession(
        id: String = "abcdef12-3456-7890",
        name: String? = nil,
        firstMessage: String? = nil
    ) -> StatsActiveSession {
        StatsActiveSession(
            id: id,
            status: "idle",
            model: nil,
            cost: 0,
            name: name,
            firstMessage: firstMessage,
            workspaceName: nil,
            thinkingLevel: nil,
            parentSessionId: nil,
            contextTokens: nil,
            contextWindow: nil,
            createdAt: nil
        )
    }

    @Test func returnsNameWhenPresent() {
        let session = makeSession(name: "My Agent")
        #expect(session.displayTitle == "My Agent")
    }

    @Test func returnsNameTrimmed() {
        let session = makeSession(name: "  padded name  ")
        #expect(session.displayTitle == "padded name")
    }

    @Test func fallsThroughWhitespaceOnlyName() {
        let session = makeSession(name: "   ", firstMessage: "Hello world")
        #expect(session.displayTitle == "Hello world")
    }

    @Test func returnsFirstMessageWhenNameNil() {
        let session = makeSession(firstMessage: "Fix the login bug")
        #expect(session.displayTitle == "Fix the login bug")
    }

    @Test func returnsFirstMessageWhenNameEmpty() {
        let session = makeSession(name: "", firstMessage: "Refactor tests")
        #expect(session.displayTitle == "Refactor tests")
    }

    @Test func truncatesFirstMessageAt80Chars() {
        let longMessage = String(repeating: "a", count: 120)
        let session = makeSession(firstMessage: longMessage)
        #expect(session.displayTitle.count == 80)
        #expect(session.displayTitle == String(repeating: "a", count: 80))
    }

    @Test func returnsFallbackWhenBothNil() {
        let session = makeSession(id: "deadbeef-1234-5678")
        #expect(session.displayTitle == "Session deadbeef")
    }

    @Test func returnsFallbackWhenBothWhitespaceOnly() {
        let session = makeSession(id: "cafe0123-abcd", name: "  \t  ", firstMessage: "  \n  ")
        #expect(session.displayTitle == "Session cafe0123")
    }

    @Test func prefersNameOverFirstMessage() {
        let session = makeSession(name: "Agent X", firstMessage: "Do the thing")
        #expect(session.displayTitle == "Agent X")
    }
}

// MARK: - isBusy

@Suite("StatsActiveSession — isBusy")
struct IsBusyTests {

    private func makeSession(status: String) -> StatsActiveSession {
        StatsActiveSession(
            id: "test",
            status: status,
            model: nil,
            cost: 0,
            name: nil,
            firstMessage: nil,
            workspaceName: nil,
            thinkingLevel: nil,
            parentSessionId: nil,
            contextTokens: nil,
            contextWindow: nil,
            createdAt: nil
        )
    }

    @Test("busy statuses",
          arguments: ["busy", "starting"])
    func busyStatuses(status: String) {
        #expect(makeSession(status: status).isBusy)
    }

    @Test("non-busy statuses",
          arguments: ["idle", "stopped", "error", ""])
    func nonBusyStatuses(status: String) {
        #expect(!makeSession(status: status).isBusy)
    }
}

// MARK: - Codable round-trip

@Suite("ServerStats — Codable")
struct ServerStatsCodableTests {

    @Test func decodesFullJSON() throws {
        let json = """
        {
            "memory": {
                "heapUsed": 52428800,
                "heapTotal": 67108864,
                "rss": 104857600,
                "external": 1048576
            },
            "activeSessions": [
                {
                    "id": "sess-001",
                    "status": "busy",
                    "model": "claude-sonnet-4-20250514",
                    "cost": 0.15,
                    "name": "Test Agent",
                    "firstMessage": "Hello",
                    "workspaceName": "oppi",
                    "thinkingLevel": "high",
                    "parentSessionId": null,
                    "contextTokens": 5000,
                    "contextWindow": 200000,
                    "createdAt": 1711234567890
                }
            ],
            "daily": [
                {
                    "date": "2026-03-25",
                    "sessions": 3,
                    "cost": 0.42,
                    "tokens": 15000,
                    "byModel": {
                        "claude-sonnet-4-20250514": {
                            "sessions": 2,
                            "cost": 0.30,
                            "tokens": 10000
                        }
                    }
                }
            ],
            "modelBreakdown": [
                {
                    "model": "claude-sonnet-4-20250514",
                    "sessions": 10,
                    "cost": 3.50,
                    "tokens": 100000,
                    "cacheRead": 50000,
                    "cacheWrite": 20000,
                    "share": 0.85
                }
            ],
            "workspaceBreakdown": [
                {
                    "id": "ws-001",
                    "name": "oppi",
                    "sessions": 10,
                    "cost": 3.50
                }
            ],
            "totals": {
                "sessions": 42,
                "cost": 12.50,
                "tokens": 500000
            }
        }
        """
        let data = Data(json.utf8)
        let stats = try JSONDecoder().decode(ServerStats.self, from: data)

        // Totals
        #expect(stats.totals.sessions == 42)
        #expect(stats.totals.cost == 12.50)
        #expect(stats.totals.tokens == 500000)

        // Memory
        #expect(stats.memory.heapUsed == 52428800)
        #expect(stats.memory.rss == 104857600)

        // Active sessions
        #expect(stats.activeSessions.count == 1)
        let session = stats.activeSessions[0]
        #expect(session.id == "sess-001")
        #expect(session.status == "busy")
        #expect(session.isBusy)
        #expect(session.displayTitle == "Test Agent")
        #expect(session.model == "claude-sonnet-4-20250514")
        #expect(session.parentSessionId == nil)
        #expect(session.contextTokens == 5000)

        // Daily
        #expect(stats.daily.count == 1)
        #expect(stats.daily[0].date == "2026-03-25")
        #expect(stats.daily[0].byModel?["claude-sonnet-4-20250514"]?.sessions == 2)

        // Model breakdown
        #expect(stats.modelBreakdown.count == 1)
        #expect(stats.modelBreakdown[0].cacheRead == 50000)
        #expect(stats.modelBreakdown[0].share == 0.85)

        // Workspace breakdown
        #expect(stats.workspaceBreakdown.count == 1)
        #expect(stats.workspaceBreakdown[0].name == "oppi")
    }

    @Test func decodesMinimalJSON() throws {
        let json = """
        {
            "memory": {"heapUsed": 0, "heapTotal": 0, "rss": 0, "external": 0},
            "activeSessions": [],
            "daily": [],
            "modelBreakdown": [],
            "workspaceBreakdown": [],
            "totals": {"sessions": 0, "cost": 0, "tokens": 0}
        }
        """
        let stats = try JSONDecoder().decode(ServerStats.self, from: Data(json.utf8))

        #expect(stats.activeSessions.isEmpty)
        #expect(stats.daily.isEmpty)
        #expect(stats.totals.sessions == 0)
    }

    @Test func decodesSessionWithOptionalFieldsNull() throws {
        let json = """
        {
            "id": "sess-minimal",
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
        let session = try JSONDecoder().decode(StatsActiveSession.self, from: Data(json.utf8))

        #expect(session.id == "sess-minimal")
        #expect(session.model == nil)
        #expect(session.name == nil)
        #expect(session.createdAt == nil)
        #expect(session.displayTitle == "Session sess-min")
    }

    @Test func encodesAndDecodesRoundTrip() throws {
        let original = ServerStats(
            memory: StatsMemory(heapUsed: 100, heapTotal: 200, rss: 300, external: 50),
            activeSessions: [],
            daily: [],
            modelBreakdown: [],
            workspaceBreakdown: [],
            totals: StatsTotals(sessions: 5, cost: 1.23, tokens: 9999)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerStats.self, from: data)

        #expect(decoded.totals.sessions == original.totals.sessions)
        #expect(decoded.totals.cost == original.totals.cost)
        #expect(decoded.totals.tokens == original.totals.tokens)
        #expect(decoded.memory.heapUsed == original.memory.heapUsed)
    }
}

// MARK: - DailyDetail Codable

@Suite("DailyDetail — Codable")
struct DailyDetailCodableTests {

    @Test func decodesCorrectly() throws {
        let json = """
        {
            "date": "2026-03-25",
            "totals": {"sessions": 5, "cost": 2.0, "tokens": 10000},
            "hourly": [
                {"hour": 9, "sessions": 2, "cost": 0.5, "tokens": 3000, "byModel": null}
            ],
            "sessions": [
                {
                    "id": "s1",
                    "name": "morning run",
                    "model": "claude-sonnet-4-20250514",
                    "cost": 0.5,
                    "tokens": 3000,
                    "createdAt": 1711234567890,
                    "workspaceName": "oppi",
                    "status": "stopped"
                }
            ]
        }
        """
        let detail = try JSONDecoder().decode(DailyDetail.self, from: Data(json.utf8))

        #expect(detail.date == "2026-03-25")
        #expect(detail.totals.sessions == 5)
        #expect(detail.hourly.count == 1)
        #expect(detail.hourly[0].hour == 9)
        #expect(detail.sessions.count == 1)
        #expect(detail.sessions[0].name == "morning run")
    }
}
