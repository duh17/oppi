import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Mac session inbox grouping")
struct MacSessionInboxTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }

    @Test func groupsAskAndReadyIntoYourTurnAndBusyIntoWorking() {
        let ask = makeTarget(
            makeSession(id: "ask", status: .ready),
            pendingAskCount: 1
        )
        let ready = makeTarget(makeSession(id: "ready", status: .ready))
        let busy = makeTarget(makeSession(id: "busy", status: .busy))
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let sections = MacSessionInboxPresentation.sections(
            targets: [busy, ready, ask],
            now: now,
            calendar: calendar
        )

        #expect(sections.yourTurn.map(\.sessionId) == ["ask", "ready"])
        #expect(sections.working.map(\.sessionId) == ["busy"])
        #expect(sections.stoppedGroups.isEmpty)
    }

    @Test func yourTurnPutsAskFirstThenOldestActivity() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let olderReady = makeTarget(
            makeSession(id: "older-ready", status: .ready, lastActivity: base)
        )
        let newerReady = makeTarget(
            makeSession(
                id: "newer-ready",
                status: .ready,
                lastActivity: base.addingTimeInterval(120)
            )
        )
        let ask = makeTarget(
            makeSession(
                id: "ask",
                status: .ready,
                lastActivity: base.addingTimeInterval(60)
            ),
            pendingAskCount: 2
        )

        let sections = MacSessionInboxPresentation.sections(
            targets: [newerReady, olderReady, ask],
            now: base,
            calendar: calendar
        )

        #expect(sections.yourTurn.map(\.sessionId) == ["ask", "older-ready", "newer-ready"])
    }

    @Test func workingPutsNewestCreatedFirst() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = makeTarget(
            makeSession(
                id: "older-busy",
                status: .busy,
                createdAt: base,
                lastActivity: base.addingTimeInterval(30)
            )
        )
        let newer = makeTarget(
            makeSession(
                id: "newer-busy",
                status: .busy,
                createdAt: base.addingTimeInterval(10),
                lastActivity: base
            )
        )

        let sections = MacSessionInboxPresentation.sections(
            targets: [older, newer],
            now: base,
            calendar: calendar
        )

        #expect(sections.working.map(\.sessionId) == ["newer-busy", "older-busy"])
    }

    @Test func groupsStoppedSessionsByDayNewestFirst() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let targets = [
            makeTarget(makeSession(id: "today", status: .stopped, lastActivity: now)),
            makeTarget(makeSession(id: "yesterday", status: .stopped, lastActivity: yesterday)),
            makeTarget(makeSession(id: "two-days", status: .stopped, lastActivity: twoDaysAgo)),
        ]

        let sections = MacSessionInboxPresentation.sections(
            targets: targets,
            now: now,
            calendar: calendar
        )

        #expect(sections.yourTurn.isEmpty)
        #expect(sections.working.isEmpty)
        #expect(sections.stoppedGroups.map(\.day) == [today, yesterday, twoDaysAgo])
        #expect(sections.stoppedGroups.flatMap(\.items).map(\.sessionId) == [
            "today", "yesterday", "two-days",
        ])
        #expect(
            sections.stoppedGroups.map { group in
                SessionInboxSectionTitle.stopped(day: group.day, now: now, calendar: calendar)
            } == [
                "Stopped · Today",
                "Stopped · Yesterday",
                SessionInboxSectionTitle.stopped(day: twoDaysAgo, now: now, calendar: calendar),
            ]
        )
    }

    @Test func omitsStoppedSessionsOlderThanThreeVisibleDays() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: today))

        #expect(SessionInboxStoppedDayPolicy.visibleDayCount == 3)
        #expect(
            SessionInboxStoppedDayPolicy.visibleRangeStart(now: now, calendar: calendar) == twoDaysAgo
        )

        let sections = MacSessionInboxPresentation.sections(
            targets: [
                makeTarget(makeSession(id: "visible", status: .stopped, lastActivity: twoDaysAgo)),
                makeTarget(makeSession(id: "too-old", status: .stopped, lastActivity: threeDaysAgo)),
            ],
            now: now,
            calendar: calendar
        )

        #expect(sections.stoppedGroups.map(\.day) == [twoDaysAgo])
        #expect(sections.stoppedGroups.flatMap(\.items).map(\.sessionId) == ["visible"])
    }

    @Test func omitsStoppedIncognitoSessions() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 12
        )))
        var incognito = makeSession(id: "incognito", status: .stopped, lastActivity: now)
        incognito.ephemeral = true

        let sections = MacSessionInboxPresentation.sections(
            targets: [
                makeTarget(incognito),
                makeTarget(makeSession(id: "regular", status: .stopped, lastActivity: now)),
            ],
            now: now,
            calendar: calendar
        )

        #expect(!SessionInboxStoppedDayPolicy.includesStoppedSession(incognito))
        #expect(sections.stoppedGroups.flatMap(\.items).map(\.sessionId) == ["regular"])
    }

    @Test func expandsOnlyTodayStoppedGroupByDefault() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let sections = MacSessionInboxPresentation.sections(
            targets: [
                makeTarget(makeSession(id: "today", status: .stopped, lastActivity: now)),
                makeTarget(makeSession(id: "yesterday", status: .stopped, lastActivity: yesterday)),
            ],
            now: now,
            calendar: calendar
        )

        #expect(sections.stoppedGroups.count == 2)
        #expect(
            sections.stoppedGroups.map { group in
                SessionInboxStoppedDayPolicy.isExpandedByDefault(
                    day: group.day,
                    now: now,
                    calendar: calendar
                )
            } == [true, false]
        )
    }

    @Test func stoppedTitlesUseTodayAndYesterday() throws {
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 10,
            hour: 12
        )))
        let today = calendar.startOfDay(for: now)
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))

        #expect(SessionInboxSectionTitle.yourTurn == "Your Turn")
        #expect(SessionInboxSectionTitle.working == "Working")
        #expect(SessionInboxStoppedDayPolicy.title(for: today, now: now, calendar: calendar) == "Today")
        #expect(
            SessionInboxStoppedDayPolicy.title(for: yesterday, now: now, calendar: calendar)
                == "Yesterday"
        )
    }
}

@MainActor
@Suite("Mac session inbox row chrome")
struct MacSessionInboxRowChromeTests {
    @Test func hidesInlineStopAndDeleteForEveryStatus() {
        let statuses: [SessionStatus] = [
            .starting, .ready, .busy, .stopping, .stopped, .error,
        ]

        for status in statuses {
            let chrome = MacSessionInboxRowChrome.make(status: status)
            #expect(!chrome.showsInlineStop)
            #expect(!chrome.showsInlineDelete)
        }
    }

    @Test func keepsStopAndDeleteOnTheContextMenu() {
        let busy = MacSessionInboxRowChrome.make(status: .busy)
        #expect(busy.showsContextMenuStop)
        #expect(!busy.showsContextMenuDelete)

        let stopped = MacSessionInboxRowChrome.make(status: .stopped)
        #expect(!stopped.showsContextMenuStop)
        #expect(stopped.showsContextMenuDelete)
    }

    @Test func sessionListTitlesTruncateAtTheTailLikeNaturalLanguage() {
        #expect(MacSessionInboxRowPaint.titleTruncation == .tail)
    }

    @Test func secondaryMetadataRemainsAvailableOutsideTheScanPath() {
        var session = makeSession(id: "metadata", status: .ready)
        session.cost = 27.45
        session.contextTokens = 25_000
        session.contextWindow = 100_000
        session.worktreeId = "wt_feature"
        session.ephemeral = true
        session.changeStats = SessionChangeStats(
            mutatingToolCalls: 4,
            compactionCount: 2,
            filesChanged: 4,
            changedFiles: ["a.swift", "b.swift", "c.swift", "d.swift"],
            addedLines: 10,
            removedLines: 2
        )
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            pendingAskCount: 1,
            lineageHint: "Child of review session",
            workspaceContext: "Oppi",
            searchSnippet: AttributedString("matched deployment failure")
        )

        let metadata = MacSessionInboxRowPaint.secondaryAccessibilityValue(
            for: presentation
        )

        #expect(metadata.contains("Child of review session"))
        #expect(metadata.contains("matched deployment failure"))
        #expect(metadata.contains("Context 25%"))
        #expect(metadata.contains("2 compactions"))
        #expect(metadata.contains("Worktree wt_feature"))
        #expect(metadata.contains("Incognito"))
        #expect(metadata.contains("$27.45"))
        #expect(metadata.contains("4 files touched"))
        #expect(metadata.contains("question pending"))
    }

    @Test func secondaryMetadataIsWiredToHelpAndAccessibility() throws {
        let source = try macSessionInboxRowSource()
        let body = try sourceSlice(
            named: "var body: some View {",
            until: "private var titleBand",
            in: source
        )

        #expect(body.contains(".accessibilityValue(secondaryMetadata)"))
        #expect(body.contains(".help(secondaryMetadata)"))
    }

    @Test func searchReasonMetadataPreservesHiddenWorkspaceAndPrimaryModel() {
        var session = makeSession(id: "search-context", status: .ready)
        session.model = "openai/gpt-5.6-sol"
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            workspaceContext: "Oppi",
            searchSnippet: SessionSearchStore.parseSnippet("Fixed <b>launch</b> flash")
        )

        let metadata = MacSessionInboxRowPaint.secondaryAccessibilityValue(
            for: presentation
        )

        #expect(metadata.contains("Search match: Fixed launch flash"))
        #expect(metadata.contains("Workspace Oppi"))
        #expect(metadata.contains("Model gpt-5.6-sol"))
    }

    @Test func lineageReasonMetadataPreservesHiddenWorkspaceAndPrimaryModel() {
        var session = makeSession(id: "lineage-context", status: .busy)
        session.model = "anthropic/claude-sonnet-4-6"
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            lineageHint: "Child of review session",
            workspaceContext: "Client App"
        )

        let metadata = MacSessionInboxRowPaint.secondaryAccessibilityValue(
            for: presentation
        )

        #expect(metadata.contains("Child of review session"))
        #expect(metadata.contains("Workspace Client App"))
        #expect(metadata.contains("Model claude-sonnet-4-6"))
    }

    @Test func searchReasonWinsAndPreservesMatchEmphasis() throws {
        let session = makeSession(id: "search", status: .ready)
        let snippet = SessionSearchStore.parseSnippet("Fixed <b>launch</b> flash")
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            lineageHint: "Child of review session",
            workspaceContext: "Oppi",
            searchSnippet: snippet
        )

        guard case .search(let visibleSnippet) = MacSessionInboxRowPaint.visibleReason(
            for: presentation
        ) else {
            Issue.record("Search matches should replace ordinary context in the visible second band")
            return
        }

        #expect(String(visibleSnippet.characters) == "Fixed launch flash")
        #expect(visibleSnippet.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        #expect(presentation.statusKind == .done)
    }

    @Test func lineageReasonUsesSecondBandWhenNoSearchMatchExists() {
        let presentation = SessionRowPresentationBuilder.make(
            session: makeSession(id: "child", status: .busy),
            lineageHint: "  Child of review session  ",
            workspaceContext: "Oppi"
        )

        #expect(
            MacSessionInboxRowPaint.visibleReason(for: presentation)
                == .lineage("Child of review session")
        )
        #expect(presentation.statusKind == .working)
    }

    @Test func ordinaryRowsKeepWorkspaceAndModelContext() {
        let presentation = SessionRowPresentationBuilder.make(
            session: makeSession(id: "ordinary", status: .ready),
            workspaceContext: "Oppi"
        )

        #expect(MacSessionInboxRowPaint.visibleReason(for: presentation) == nil)
    }

    @Test func visibleReasonBandKeepsStatusAndHighlightsSearchMatches() throws {
        let source = try macSessionInboxRowSource()
        let band = try sourceSlice(
            named: "private var contextBand: some View {",
            until: "private var statusForeground",
            in: source
        )

        #expect(band.contains("MacSessionInboxRowPaint.visibleReason"))
        #expect(band.contains("Text(pillVariant.label)"))
        #expect(band.contains("highlightedSearchSnippet"))
    }
}

@MainActor
@Suite("Mac session inbox row hierarchy")
struct MacSessionInboxRowHierarchyTests {
    @Test func metadataHeavyRowStaysCompactAtTheReferenceSidebarWidth() {
        let referenceSidebarWidth: CGFloat = 280
        let maximumTwoBandRowHeight: CGFloat = 58
        var session = makeSession(id: "A long natural-language session title", status: .ready)
        session.model = "anthropic/claude-sonnet-4-6"
        session.workspaceName = "A long workspace name"
        session.cost = 27.45
        session.contextTokens = 75_000
        session.contextWindow = 100_000
        session.worktreeId = "wt_feature"
        session.ephemeral = true
        session.changeStats = SessionChangeStats(
            mutatingToolCalls: 4,
            compactionCount: 2,
            filesChanged: 4,
            changedFiles: ["a.swift", "b.swift", "c.swift", "d.swift"],
            addedLines: 10,
            removedLines: 2
        )
        let presentation = SessionRowPresentationBuilder.make(
            session: session,
            pendingAskCount: 1,
            lineageHint: "Child of review session",
            workspaceContext: session.workspaceName,
            searchSnippet: AttributedString("matched deployment failure")
        )
        let row = WorkspaceSessionSummaryRow(presentation: presentation)
            .frame(width: referenceSidebarWidth)
        let controller = NSHostingController(rootView: row)

        let size = controller.sizeThatFits(
            in: CGSize(
                width: referenceSidebarWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        )

        #expect(
            size.height <= maximumTwoBandRowHeight,
            "The 280pt row should remain a two-band scan target; painted height was \(size.height)"
        )
    }

    @Test func searchReasonRowStaysWithinTwoBands() {
        let presentation = SessionRowPresentationBuilder.make(
            session: makeSession(id: "search", status: .ready),
            workspaceContext: "Oppi",
            searchSnippet: SessionSearchStore.parseSnippet(
                "Fixed <b>launch</b> flash while reconnecting to the live session"
            )
        )

        assertTwoBandHeight(presentation, context: "search result")
    }

    @Test func lineageReasonRowStaysWithinTwoBands() {
        let presentation = SessionRowPresentationBuilder.make(
            session: makeSession(id: "child", status: .busy),
            lineageHint: "Child of the live UI review session",
            workspaceContext: "Oppi"
        )

        assertTwoBandHeight(presentation, context: "lineage row")
    }

    private func assertTwoBandHeight(
        _ presentation: SessionRowPresentation,
        context: String
    ) {
        let referenceSidebarWidth: CGFloat = 280
        let maximumTwoBandRowHeight: CGFloat = 58
        let row = WorkspaceSessionSummaryRow(presentation: presentation)
            .frame(width: referenceSidebarWidth)
        let controller = NSHostingController(rootView: row)
        let size = controller.sizeThatFits(
            in: CGSize(
                width: referenceSidebarWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        )

        #expect(
            size.height <= maximumTwoBandRowHeight,
            "The \(context) should stay within two bands; painted height was \(size.height)"
        )
    }
}

@Suite("Mac home session list selection")
struct MacHomeSessionSelectionTests {
    @Test func overlappingInboxAndRuntimeIDOpensTraceNotStatsOnly() {
        let target = makeTarget(makeSession(id: "sess-1", status: .busy))
        let runtime = makeRuntimeSession(id: "sess-1")

        let resolved = MacHomeSessionSelection.resolve(
            selectedSessionID: "sess-1",
            targets: [target],
            runtimeSessions: [runtime]
        )

        guard case .trace(let selected) = resolved else {
            Issue.record("List selection of an inbox session must open the trace shell, not stats-only")
            return
        }
        #expect(selected.sessionId == "sess-1")
        #expect(selected.workspaceId == "ws1")
    }

    @Test func runtimeRowWithoutWorkspaceTargetStaysStatsOnly() {
        let inbox = makeTarget(makeSession(id: "inbox", status: .ready))
        let runtime = makeRuntimeSession(id: "runtime-only")

        let resolved = MacHomeSessionSelection.resolve(
            selectedSessionID: "runtime-only",
            targets: [inbox],
            runtimeSessions: [runtime]
        )

        guard case .statsOnly(let session) = resolved else {
            Issue.record("Runtime rows with no workspace target should stay stats-only")
            return
        }
        #expect(session.id == "runtime-only")
    }

    @Test func runtimeActivityOmitsInboxDuplicates() {
        let inbox = makeTarget(makeSession(id: "sess-1", status: .busy))
        let runtime = [
            makeRuntimeSession(id: "sess-1"),
            makeRuntimeSession(id: "orphan"),
        ]

        let rows = MacHomeSessionSelection.runtimeActivity(
            targets: [inbox],
            runtimeSessions: runtime
        )

        #expect(rows.map(\.id) == ["orphan"])
    }

    @Test func missingSelectionResolvesToNone() {
        let resolved = MacHomeSessionSelection.resolve(
            selectedSessionID: nil,
            targets: [makeTarget(makeSession(id: "sess-1", status: .ready))],
            runtimeSessions: [makeRuntimeSession(id: "sess-1")]
        )
        guard case .none = resolved else {
            Issue.record("Nil list selection should not open a detail pane")
            return
        }
    }

    @Test func runtimeHomeListCaptionIsTitleDotReadableStatus() {
        let inbox = makeTarget(makeSession(id: "inbox", status: .ready))
        let runtimeOverlap = makeRuntimeSession(id: "inbox")
        let runtimeOnly = makeRuntimeSession(id: "runtime-only")

        #expect(
            MacHomeSessionListPaint.runtimeCaption(for: runtimeOnly)
                == "runtime-only · Running"
        )
        #expect(
            MacHomeSessionSelection.runtimeActivity(
                targets: [inbox],
                runtimeSessions: [runtimeOverlap, runtimeOnly]
            ).map(\.id) == ["runtime-only"]
        )
        #expect(
            MacHomeSessionListPaint.runtimeCaption(
                for: makeRuntimeSession(id: "build", status: "busy")
            ) == "build · Running"
        )
        #expect(
            MacHomeSessionListPaint.runtimeCaption(
                for: makeRuntimeSession(id: "boot", status: "starting")
            ) == "boot · Starting"
        )
        #expect(
            MacHomeSessionListPaint.runtimeCaption(
                for: makeRuntimeSession(id: "idle", status: "ready")
            ) == "idle · Idle"
        )
        #expect(
            MacHomeSessionListPaint.runtimeCaption(
                for: makeRuntimeSession(id: "halt", status: "stopped")
            ) == "halt · Stopped"
        )
    }

    @Test func homeListRuntimeActivityDoesNotUseSessionRowView() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacSessionListView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.contains("MacHomeSessionListPaint.runtimeCaption"))
        #expect(source.contains("Section(\"Runtime activity\")"))
        #expect(!source.contains("SessionRowView"))
    }

    @Test func laterCatalogHitOnSelectedRuntimeIDBindsTraceStore() {
        let sessionID = "runtime-only"
        let runtime = makeRuntimeSession(id: sessionID)

        #expect(
            MacHomeSessionSelection.unboundTraceTarget(
                selectedSessionID: sessionID,
                targets: [],
                runtimeSessions: [runtime],
                boundSessionID: nil
            ) == nil
        )

        let catalogTarget = makeTarget(makeSession(id: sessionID, status: .busy))
        let toBind = MacHomeSessionSelection.unboundTraceTarget(
            selectedSessionID: sessionID,
            targets: [catalogTarget],
            runtimeSessions: [runtime],
            boundSessionID: nil
        )

        #expect(toBind?.sessionId == sessionID)
        #expect(toBind?.workspaceId == "ws1")
        #expect(
            MacHomeSessionSelection.unboundTraceTarget(
                selectedSessionID: sessionID,
                targets: [catalogTarget],
                runtimeSessions: [runtime],
                boundSessionID: sessionID
            ) == nil
        )
    }
}

@Suite("Mac session inbox row presentation")
struct MacSessionInboxRowPresentationTests {
    @Test func yourTurnWorkingAndStoppedRowsShareSessionRowPresentationFields() {
        var ready = makeSession(id: "ready", status: .ready)
        ready.model = "anthropic/claude-sonnet-4-6"
        ready.cost = 27.45
        ready.contextTokens = 25_000
        ready.contextWindow = 100_000
        ready.workspaceName = "oppi"
        ready.changeStats = SessionChangeStats(
            mutatingToolCalls: 4,
            compactionCount: 2,
            filesChanged: 4,
            changedFiles: ["a.swift", "b.swift", "c.swift", "d.swift"],
            addedLines: 10,
            removedLines: 2
        )

        var busy = makeSession(id: "busy", status: .busy)
        busy.model = "openai/gpt-5.5"
        busy.worktreeId = "wt_feature"

        let stopped = makeSession(id: "stopped", status: .stopped)
        let yourTurn = makeTarget(ready, pendingAskCount: 1)
        let working = makeTarget(busy)
        let stoppedTarget = makeTarget(stopped)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current

        let sections = MacSessionInboxPresentation.sections(
            targets: [yourTurn, working, stoppedTarget],
            now: now,
            calendar: calendar
        )
        #expect(sections.yourTurn.map(\.sessionId) == ["ready"])
        #expect(sections.working.map(\.sessionId) == ["busy"])
        #expect(sections.stoppedGroups.flatMap(\.items).map(\.sessionId) == ["stopped"])

        let yourTurnPresentation = MacSessionInboxPresentation.rowPresentation(for: yourTurn)
        #expect(yourTurnPresentation.session.displayTitle == "ready")
        #expect(yourTurnPresentation.workspaceContext == "oppi")
        #expect(yourTurnPresentation.modelSummaries.map(\.label) == ["claude-sonnet-4-6"])
        #expect(yourTurnPresentation.attentionText == "question pending")
        #expect(yourTurnPresentation.session.cost == 27.45)
        #expect(yourTurnPresentation.contextPercent == 0.25)
        #expect(yourTurnPresentation.session.changeStats?.filesChanged == 4)
        #expect(yourTurnPresentation.session.changeStats?.compactionCount == 2)
        #expect(yourTurnPresentation.statusKind == .question)

        let workingPresentation = MacSessionInboxPresentation.rowPresentation(for: working)
        #expect(workingPresentation.workspaceContext == "Oppi")
        #expect(workingPresentation.modelSummaries.map(\.label) == ["gpt-5.5"])
        #expect(workingPresentation.attentionText == nil)
        #expect(workingPresentation.statusKind == .working)
        #expect(SessionWorktreeIndicatorPresentation(session: workingPresentation.session) != nil)

        let stoppedPresentation = MacSessionInboxPresentation.rowPresentation(for: stoppedTarget)
        #expect(stoppedPresentation.attentionText == nil)
        #expect(stoppedPresentation.statusKind == .stopped)
        #expect(stoppedPresentation.workspaceContext == "Oppi")
    }

    @Test func workspaceDetailOmitsWorkspaceContext() {
        let target = makeTarget(makeSession(id: "ready", status: .ready))
        let presentation = MacSessionInboxPresentation.rowPresentation(
            for: target,
            includeWorkspaceContext: false
        )
        #expect(presentation.workspaceContext == nil)
        #expect(presentation.modelSummaries.first?.label == "model")
        #expect(presentation.statusKind == .done)
    }

    @Test func controlSessionUsesPiControlContext() {
        var session = makeSession(id: "control-1", status: .ready)
        session.workspaceId = nil
        session.workspaceName = nil
        session.control = ControlSessionMetadata(
            domain: .workspaces,
            intent: .create,
            targetId: nil,
            targetName: nil
        )
        let presentation = MacSessionInboxPresentation.rowPresentation(for: makeTarget(session))
        #expect(presentation.workspaceContext == "Pi Control")
    }

    @Test func idleDraftUsesIdleStatusLabel() {
        var session = makeSession(id: "draft", status: .ready)
        session.messageCount = 0
        session.firstMessage = nil
        session.name = nil
        let presentation = MacSessionInboxPresentation.rowPresentation(for: makeTarget(session))
        #expect(presentation.statusKind == .idle)
        #expect(presentation.statusKind.label == "Idle")
    }

    @Test func namedProviderPaintsSharedGlyphBesideModelLabel() throws {
        var session = makeSession(id: "ready", status: .ready)
        session.model = "anthropic/claude-sonnet-4-6"
        let presentation = MacSessionInboxPresentation.rowPresentation(for: makeTarget(session))
        let model = try #require(presentation.visibleModelSummaries.first)
        #expect(model.provider == "anthropic")

        let source = try macSessionInboxRowSource()
        let slice = try sourceSlice(
            named: "private func modelSummaryView(_ model: SessionModelSummary)",
            until: "/// SwiftUI session identity.",
            in: source
        )
        #expect(slice.contains("if !model.provider.isEmpty"))
        #expect(slice.contains("ProviderGlyph(provider: model.provider, size: 11"))
        #expect(!slice.contains("ProviderIcon"))
    }

    @Test func emptyProviderOmitsGlyphBesideModelLabel() throws {
        var session = makeSession(id: "ready", status: .ready)
        session.model = "claude-sonnet-4-6"
        let presentation = MacSessionInboxPresentation.rowPresentation(for: makeTarget(session))
        let model = try #require(presentation.visibleModelSummaries.first)
        #expect(model.provider.isEmpty)
    }
}

@Suite("Mac session row identity")
struct MacSessionRowIdentityTests {
    @Test func ordinaryInboxAndWorkspaceRowsPaintOfficialPiIdentity() {
        let session = makeSession(id: "session-alpha", status: .ready)
        let paint = MacSessionRowIdentityPaint.make(session: session)

        #expect(paint == .officialPi)
    }

    @Test func ordinarySessionIdentityIsStableAcrossSessionIds() {
        let first = MacSessionRowIdentityPaint.make(
            session: makeSession(id: "session-one", status: .ready)
        )
        let second = MacSessionRowIdentityPaint.make(
            session: makeSession(id: "session-two", status: .ready)
        )

        #expect(first == .officialPi)
        #expect(second == .officialPi)
    }

    @Test func agentIconWithoutAgentIdStillUsesOfficialPiIdentity() {
        var session = makeSession(id: "plain", status: .ready)
        session.launch = SessionLaunchMetadata(agentId: nil, agentIcon: .emoji("🧘"))
        let paint = MacSessionRowIdentityPaint.make(session: session)

        #expect(paint == .officialPi)
    }

    @Test func savedAgentRowsPaintLaunchEmojiInsteadOfPiIdentity() {
        var session = makeSession(id: "agent-session", status: .ready)
        session.launch = SessionLaunchMetadata(agentId: "agent-1", agentIcon: .emoji("🧘"))
        #expect(MacSessionRowIdentityPaint.make(session: session) == .emoji("🧘"))
    }

    @Test func savedAgentRowsPaintLaunchSymbolInsteadOfPiIdentity() {
        var session = makeSession(id: "agent-session", status: .ready)
        session.launch = SessionLaunchMetadata(agentId: "agent-1", agentIcon: .symbol("checkmark.shield"))
        #expect(MacSessionRowIdentityPaint.make(session: session) == .symbol("checkmark.shield"))
    }

    @Test func unreadCompletionAtPaintsLeadingDotLikeIOS() {
        let session = makeSession(id: "ready", status: .ready)
        let unread = SessionRowPresentationBuilder.make(
            session: session,
            unreadCompletionAt: Date(timeIntervalSince1970: 7)
        )
        let read = SessionRowPresentationBuilder.make(session: session)

        #expect(MacSessionInboxRowPaint.showsUnreadDot(for: unread))
        #expect(!MacSessionInboxRowPaint.showsUnreadDot(for: read))
    }
}

private func makeSession(
    id: String,
    status: SessionStatus,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    lastActivity: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> Session {
    Session(
        id: id,
        workspaceId: "ws1",
        workspaceName: "Oppi",
        name: id,
        status: status,
        createdAt: createdAt,
        lastActivity: lastActivity,
        model: "test/model",
        messageCount: 1,
        tokens: TokenUsage(input: 0, output: 0),
        cost: 0,
        firstMessage: "Hello from \(id)"
    )
}

private func makeTarget(
    _ session: Session,
    pendingAskCount: Int = 0
) -> MacSelectedSessionTarget {
    var summary = SessionSummary(from: session)
    summary.pendingAskCount = pendingAskCount
    return MacSelectedSessionTarget(
        workspaceId: session.workspaceId ?? "ws1",
        sessionId: session.id,
        summary: summary
    )
}

private func macSessionInboxRowSource() throws -> String {
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "OppiMac/Views/MacSessionInboxRow.swift")
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func sourceSlice(named marker: String, until endMarker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker) else {
        Issue.record("Missing source marker \(marker)")
        throw SourceSliceError.missingMarker(marker)
    }
    guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
        Issue.record("Missing source end marker \(endMarker)")
        throw SourceSliceError.missingMarker(endMarker)
    }
    return String(source[start.lowerBound..<end.lowerBound])
}

private enum SourceSliceError: Error {
    case missingMarker(String)
}

private func makeRuntimeSession(id: String, status: String = "busy") -> StatsActiveSession {
    StatsActiveSession(
        id: id,
        status: status,
        model: "test/model",
        cost: 0,
        name: id,
        firstMessage: nil,
        workspaceName: "Oppi",
        thinkingLevel: nil,
        contextTokens: nil,
        contextWindow: nil,
        createdAt: nil
    )
}
