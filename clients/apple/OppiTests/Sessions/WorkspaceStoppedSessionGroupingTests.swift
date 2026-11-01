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
    // workspace asks the server for older sections before that same instant, so the
    // newest older section (day:2026-11-01) ends exactly where the recent days begin.
    @Test func dayOnTheOld72HourLineShowsOnlyAsAnOlderSection() throws {
        let now = try date(2026, 11, 4, 10)
        let rangeStart = SessionInboxStoppedDayPolicy.visibleRangeStart(now: now, calendar: calendar)
        let lateFallBackDay = try date(2026, 11, 1, 23, 30)
        let today = try date(2026, 11, 4)
        let yesterday = try date(2026, 11, 3)
        let twoDaysAgo = try date(2026, 11, 2)

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

@Suite("Workspace older-history section rows across refreshes")
struct WorkspaceArchiveSectionRowsTests {
    private let day: TimeInterval = 86_400
    private let monthStart = Date(timeIntervalSince1970: 1_779_000_000)

    private func bucket(_ id: String, from start: Date, days: Int, count: Int = 1) -> WorkspaceSessionArchiveBucket {
        WorkspaceSessionArchiveBucket(
            id: id,
            kind: id.hasPrefix("day:") ? .day : .month,
            startAt: start,
            endAt: start.addingTimeInterval(TimeInterval(days) * day),
            itemCount: count,
            managedStoppedCount: count,
            importableLocalCount: 0,
            latestActivity: nil
        )
    }

    private func loadedState(_ buckets: [WorkspaceSessionArchiveBucket]) -> WorkspaceDetailViewController.ContentState {
        var state = WorkspaceDetailViewController.ContentState()
        state.archiveBuckets = buckets
        for bucket in buckets {
            state.archiveStoppedSessionsByBucketID[bucket.id] = []
            state.archiveLocalSessionsByBucketID[bucket.id] = []
            state.expandedStoppedGroupIDs.insert(bucket.id)
        }
        return state
    }

    /// The server lengthens the month holding the 30-day line by a day at each of its midnights;
    /// rows loaded for the shorter range miss that day, so they go and the open section reloads.
    @Test func sectionWhoseRangeGrewDropsItsRowsAndAsksForAReload() {
        let may = bucket("month:2026-05", from: monthStart, days: 20)
        let unchanged = bucket("month:2026-04", from: monthStart.addingTimeInterval(-30 * day), days: 30)
        var state = loadedState([may, unchanged])

        let grown = bucket("month:2026-05", from: monthStart, days: 21, count: 2)
        let reload = state.replaceArchiveBuckets([grown, unchanged])

        #expect(reload.map(\.id) == ["month:2026-05"])
        #expect(reload.first?.endAt == grown.endAt)
        #expect(state.archiveStoppedSessionsByBucketID["month:2026-05"] == nil)
        #expect(state.archiveLocalSessionsByBucketID["month:2026-05"] == nil)
        #expect(state.archiveStoppedSessionsByBucketID["month:2026-04"] != nil)
        #expect(state.archiveLocalSessionsByBucketID["month:2026-04"] != nil)
        #expect(state.expandedStoppedGroupIDs == ["month:2026-05", "month:2026-04"])
    }

    @Test func sectionWithTheSameRangeKeepsItsRowsWhenOnlyItsCountChanges() {
        let may = bucket("month:2026-05", from: monthStart, days: 20)
        var state = loadedState([may])

        let reload = state.replaceArchiveBuckets([bucket("month:2026-05", from: monthStart, days: 20, count: 3)])

        #expect(reload.isEmpty)
        #expect(state.archiveStoppedSessionsByBucketID["month:2026-05"] != nil)
    }

    @Test func sectionThatLeavesTheListLosesItsRowsAndItsExpansion() {
        let gone = bucket("day:2026-05-01", from: monthStart, days: 1)
        let kept = bucket("day:2026-05-02", from: monthStart.addingTimeInterval(day), days: 1)
        var state = loadedState([gone, kept])
        state.expandedStoppedGroupIDs.insert("recent:today")

        let reload = state.replaceArchiveBuckets([kept])

        #expect(reload.isEmpty)
        #expect(state.archiveStoppedSessionsByBucketID.keys.sorted() == ["day:2026-05-02"])
        #expect(state.expandedStoppedGroupIDs == ["day:2026-05-02", "recent:today"])
    }
}
