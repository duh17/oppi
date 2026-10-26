import Foundation
import Testing
@testable import Oppi

@Suite("Workspace recent stopped days")
struct WorkspaceStoppedSessionGroupingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    private func stopped(_ id: String, at lastActivity: Date) -> Session {
        Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Test",
            name: "Session \(id)",
            status: .stopped,
            createdAt: lastActivity,
            lastActivity: lastActivity,
            model: "test/model",
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
    }

    private func local(_ path: String, at lastModified: Date) -> LocalSession {
        LocalSession(
            path: path,
            piSessionId: path,
            cwd: "/tmp/project",
            name: nil,
            firstMessage: nil,
            model: nil,
            messageCount: 0,
            createdAt: lastModified,
            lastModified: lastModified
        )
    }

    private func ids(_ group: WorkspaceStoppedSessionGrouping.Group) -> [String] {
        group.items.map { item in
            switch item {
            case .entry(let entry): entry.id
            case .local(let local): local.path
            }
        }
    }

    // Wed 2026-11-04 10:00 PST. The old 72-hour window began Sun 11-01 10:00, partway
    // through the 25-hour fall-back day, so 11-01 showed as a recent group and again as
    // an older section. Recent days now start at local midnight Mon 11-02, and the
    // workspace asks the server for older sections before that same instant.
    @Test func dayOnTheOld72HourLineShowsOnlyAsAnOlderSection() throws {
        let now = try date(2026, 11, 4, 10)
        let rangeStart = SessionInboxStoppedDayPolicy.visibleRangeStart(now: now, calendar: calendar)
        let lateFallBackDay = try date(2026, 11, 1, 23, 30)
        let today = try date(2026, 11, 4)
        let yesterday = try date(2026, 11, 3)
        let twoDaysAgo = try date(2026, 11, 2)
        #expect(rangeStart == twoDaysAgo)
        #expect(lateFallBackDay > now.addingTimeInterval(-72 * 3_600))

        let groups = WorkspaceStoppedSessionGrouping.groups(
            stoppedEntries: SessionListEntries.flat([
                stopped("today", at: try date(2026, 11, 4, 9)),
                stopped("yesterday", at: try date(2026, 11, 3, 12)),
                stopped("fall-back-late", at: lateFallBackDay),
            ]),
            localSessions: [
                local("/tmp/at-boundary.jsonl", at: rangeStart),
                local("/tmp/fall-back-noon.jsonl", at: try date(2026, 11, 1, 12)),
            ],
            rangeStart: rangeStart,
            calendar: calendar
        )

        #expect(groups.map(\.day) == [today, yesterday, twoDaysAgo])
        #expect(groups.map(ids) == [["today"], ["yesterday"], ["/tmp/at-boundary.jsonl"]])
        // The newest older section (the server's day:2026-11-01 for beforeMs = rangeStart)
        // ends exactly where the recent days begin, so the two never share a day.
        let fallBackDay = calendar.startOfDay(for: lateFallBackDay)
        #expect(calendar.date(byAdding: .day, value: 1, to: fallBackDay) == rangeStart)
        #expect(groups.allSatisfy { $0.day >= rangeStart })
    }

    @Test func recentDaysMatchAllSessionsForTheSameSessions() throws {
        let now = try date(2026, 3, 10, 8)
        let sessions = [
            stopped("today", at: try date(2026, 3, 10, 7)),
            stopped("spring-forward-late", at: try date(2026, 3, 8, 23, 30)),
            stopped("spring-forward-start", at: try date(2026, 3, 8)),
            stopped("before-window", at: try date(2026, 3, 7, 23, 59)),
        ]

        let inbox = SessionInboxGrouping.make(
            items: sessions,
            now: now,
            calendar: calendar,
            session: { $0 },
            attention: { _ in .none }
        ).stoppedGroups
        let workspace = WorkspaceStoppedSessionGrouping.groups(
            stoppedEntries: SessionListEntries.flat(sessions),
            localSessions: [],
            rangeStart: SessionInboxStoppedDayPolicy.visibleRangeStart(now: now, calendar: calendar),
            calendar: calendar
        )

        #expect(workspace.map(\.day) == inbox.map(\.day))
        #expect(workspace.map(ids) == inbox.map { $0.items.map(\.id) })
        #expect(workspace.map(ids) == [["today"], ["spring-forward-late", "spring-forward-start"]])
    }
}
