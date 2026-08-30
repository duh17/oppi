import SwiftUI
import Testing
@testable import Oppi

@Suite("Mac shell navigation")
struct MacShellNavigationTests {

    @Test func controlSessionTargetUsesControlRouteScope() throws {
        var session = Session(
            id: "control-1",
            workspaceId: nil,
            name: "Create Agent",
            status: .busy,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 1),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        session.control = ControlSessionMetadata(
            domain: .agents,
            intent: .create,
            targetId: nil,
            targetName: nil
        )
        let target = try #require(MacSelectedSessionTarget.from(session: session))

        #expect(target.routeScope == .control)
        #expect(target.sessionId == "control-1")
        #expect(MacSelectedSessionTarget.from(session: Session(
            id: "orphaned",
            workspaceId: nil,
            name: "Orphan",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 1),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )) == nil)
    }

    @Test func sidebarMatchesIPadDestinations() {
        #expect(MacSidebarSection.primaryDestinations == [
            .agents, .schedules, .skills, .extensions, .workspaces,
        ])
        #expect(MacSidebarSection.pinnedDestinations == [.settings])
        #expect(MacSidebarSection.workspaces.isDisclosure)
        #expect(MacSidebarSection.agents.icon == "person.crop.circle")
        #expect(MacSidebarSection.skills.icon == "sparkles.rectangle.stack")
    }

    @Test func hostToolsLiveInSettings() {
        #expect(MacSettingsPane.hostToolPanes == [
            .pairing, .permissions, .localServer, .stats, .remoteServers, .logs, .doctor,
        ])
        #expect(MacSettingsPane.allCases == [.app] + MacSettingsPane.hostToolPanes)
        #expect(MacSettingsPane.stats.title == "Stats")
        #expect(MacSettingsPane.stats.icon == "chart.bar")
    }

    @Test func launchColumnVisibilityShowsTheDestinationSidebar() {
        #expect(MacShellColumnVisibility.launch == .all)
        #expect(MacShellColumnVisibility.launch != .detailOnly)
        #expect(MacShellColumnVisibility.launch != .doubleColumn)
        #expect(MacShellColumnVisibility.launch != .automatic)
    }

    @Test func launchDefaultsToSessionHomeAsSidebarRow() {
        #expect(MacSidebarSection.defaultSection == .sessionHome)
        #expect(MacSidebarSection.sidebarDestinations.contains(.sessionHome))
        #expect(MacSidebarSection.sidebarDestinations == [
            .sessionHome, .agents, .schedules, .skills, .extensions, .workspaces, .settings,
        ])
    }

    @Test func homeIsAnOrdinarySidebarRowForSessionHome() {
        #expect(MacSidebarHomeAffordance.allCases == [.home])
        #expect(MacSidebarSection.sidebarDestinations.contains(MacSidebarHomeAffordance.home.destination))
        #expect(MacSidebarHomeAffordance.home.destination == .sessionHome)
        #expect(MacSidebarHomeAffordance.home.title == "Home")
        #expect(MacSidebarHomeAffordance.home.icon == "house")
    }

    @Test func sidebarSelectionCanBeADestinationOrAWorkspaceId() {
        #expect(MacSidebarSelection.section(.agents) != MacSidebarSelection.workspace("ws-1"))
        #expect(MacSidebarSelection.from(section: .agents, workspaceID: nil) == .section(.agents))
        #expect(
            MacSidebarSelection.from(section: .workspaces, workspaceID: "ws-1") == .workspace("ws-1")
        )
    }

    @Test func workspaceFolderHighlightIsTheWorkspaceIdNotAllWorkspaces() {
        let item = MacSidebarSelection.from(section: .workspaces, workspaceID: "ws-1")
        #expect(item == .workspace("ws-1"))
        #expect(item != .section(.workspaces))
        #expect(
            MacSidebarSelection.from(section: .sessionHome, workspaceID: "ws-1") == .section(.sessionHome)
        )
        #expect(
            MacSidebarSelection.from(section: .defaultSection, workspaceID: nil) == .section(.sessionHome)
        )
    }

    @Test func choosingAFolderOpensThatWorkspace() {
        let (section, workspaceID) = MacSidebarSelection.workspace("ws-1")
            .applied(to: .sessionHome, workspaceID: nil)
        #expect(section == .workspaces)
        #expect(workspaceID == "ws-1")
    }

    @Test func choosingAllWorkspacesClearsTheFolderId() {
        let (section, workspaceID) = MacSidebarSelection.section(.workspaces)
            .applied(to: .workspaces, workspaceID: "ws-1")
        #expect(section == .workspaces)
        #expect(workspaceID == nil)
    }
}

@Suite("Mac session window chrome")
struct MacSessionWindowChromeTests {
    @Test func toolbarKeepsTitleAndSessionActions() {
        #expect(MacSessionWindowChrome.items(in: .toolbar) == [
            .title, .context, .outline,
        ])
        #expect(MacSessionChromeItem.title.region == .toolbar)
        #expect(MacSessionChromeItem.context.region == .toolbar)
        #expect(MacSessionChromeItem.outline.region == .toolbar)
    }

    @Test func modelThinkingSteeringAndStopLiveInTheComposer() {
        #expect(MacSessionChromeItem.model.region == .composer)
        #expect(MacSessionChromeItem.thinking.region == .composer)
        #expect(MacSessionChromeItem.steering.region == .composer)
        #expect(MacSessionChromeItem.stop.region == .composer)
        #expect(MacSessionChromeItem.dictation.region == .composer)
        #expect(MacSessionWindowChrome.items(in: .composer) == [
            .model, .thinking, .steering, .stop, .dictation, .composer,
        ])
        #expect(!MacSessionWindowChrome.items(in: .toolbar).contains(.model))
        #expect(!MacSessionWindowChrome.items(in: .toolbar).contains(.thinking))
        #expect(!MacSessionWindowChrome.items(in: .toolbar).contains(.steering))
        #expect(!MacSessionWindowChrome.items(in: .toolbar).contains(.stop))
    }

    @Test func filesAndDiffsLiveInTheInspector() {
        #expect(MacSessionWindowChrome.items(in: .inspector) == [
            .changedFiles, .filePreview, .diff,
        ])
    }

    @Test func composerAndTimelineStayInTheContentColumn() {
        #expect(MacSessionChromeItem.composer.region == .composer)
        #expect(MacSessionChromeItem.timeline.region == .timeline)
    }
}

@Suite("Mac real-window session toolbar")
struct MacRealWindowSessionToolbarTests {
    @Test func principalTitleUsesSessionStatusAndWorkspaceSemantics() {
        let session = Session(
            id: "session-1",
            workspaceId: "workspace-1",
            workspaceName: "Oppi",
            name: "Polish the Mac shell",
            status: .busy,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        let target = MacSelectedSessionTarget(
            workspaceId: "workspace-1",
            sessionId: session.id,
            summary: SessionSummary(from: session)
        )

        let presentation = MacSessionToolbarPresentation.make(
            session: session,
            selectedTarget: target
        )

        #expect(presentation.title == "Polish the Mac shell")
        #expect(presentation.statusTitle == "Working")
        #expect(presentation.workspaceTitle == "Oppi")
        #expect(presentation.detailText == "Working · Oppi")
    }

    @Test func principalTitleUsesPiControlForControlSessions() throws {
        var session = Session(
            id: "control-1",
            workspaceId: nil,
            name: "Create Agent",
            status: .ready,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            messageCount: 1,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        session.control = ControlSessionMetadata(
            domain: .agents,
            intent: .create,
            targetId: nil,
            targetName: nil
        )
        let target = try #require(MacSelectedSessionTarget.from(session: session))

        let presentation = MacSessionToolbarPresentation.make(
            session: session,
            selectedTarget: target
        )

        #expect(presentation.statusTitle == "Done")
        #expect(presentation.workspaceTitle == "Pi Control")
    }

    @Test func contextToolbarUsesTheIOSProgressRingSemantics() {
        #expect(MacSessionContextRingPaint.percentage(for: ContextUsageSnapshot(
            tokens: 50_000,
            window: 200_000
        )) == "25")
        #expect(MacSessionContextRingPaint.percentage(for: ContextUsageSnapshot(
            tokens: nil,
            window: nil
        )) == "0")
        #expect(MacSessionContextRingPaint.tone(progress: nil) == .neutral)
        #expect(MacSessionContextRingPaint.tone(progress: 0.7) == .normal)
        #expect(MacSessionContextRingPaint.tone(progress: 0.71) == .warning)
        #expect(MacSessionContextRingPaint.tone(progress: 0.91) == .critical)
    }

    @Test func selectedSessionOwnsPrincipalTitleAndFileOutlineContextActions() throws {
        let source = try macShellSource("OppiMac/Views/MacSessionShellViews.swift")

        #expect(source.contains("ToolbarItem(placement: .principal)"))
        #expect(source.contains("MacSessionToolbarTitle"))
        #expect(source.contains("mac.session.toolbar.title"))
        #expect(source.contains("mac.session.toolbar.files"))
        #expect(source.contains("mac.session.toolbar.outline"))
        #expect(source.contains("mac.session.toolbar.context"))
    }

    @Test func principalTitleOptsOutOfTheSharedGlassBackground() throws {
        let source = try macShellSource("OppiMac/Views/MacSessionShellViews.swift")
        let titleItem = try sourceSlice(
            from: "ToolbarItem(placement: .principal)",
            to: "ToolbarItem(placement: .navigation)",
            in: source
        )

        #expect(titleItem.contains(".sharedBackgroundVisibility(.hidden)"))
    }

    @Test func contextControlPaintsTheProgressRingInsteadOfADocumentGlyph() throws {
        let source = try macShellSource("OppiMac/Views/MacSessionShellViews.swift")
        let context = try sourceSlice(
            from: "private var contextToolbarItem: some View {",
            to: "@ViewBuilder\n    private var sessionInspector",
            in: source
        )

        #expect(context.contains("MacSessionContextToolbarLabel"))
        #expect(source.contains("MacSessionContextRing"))
        #expect(!source.contains("chart.bar.doc.horizontal"))
    }

    @Test func sessionSearchAndRefreshStayInsideTheSessionListColumn() throws {
        let main = try macShellSource("OppiMac/Views/MainWindowView.swift")
        let homeCase = try sourceSlice(
            from: "case .sessionHome:",
            to: "case .settings:",
            in: main
        )
        let home = try macShellSource("OppiMac/Views/MacHomeSessionList.swift")
        let list = try macShellSource("OppiMac/Views/MacSessionListView.swift")

        #expect(!homeCase.contains(".searchable"))
        #expect(home.contains("workspace.sessionList.search"))
        #expect(home.contains("workspace.sessionList.refresh"))
        #expect(!list.contains(".toolbar {"))
    }

    @Test func selectedSessionRebuildsTheDetailToolbarWhenADeepLinkChangesTargets() throws {
        let main = try macShellSource("OppiMac/Views/MainWindowView.swift")
        let traceDetail = try sourceSlice(
            from: "case .trace(let target):",
            to: "case .statsOnly(let selectedSession):",
            in: main
        )

        #expect(traceDetail.contains(".id(target.sessionId)"))
    }

    @Test func deepLinkedSessionIsRevealedInTheSessionListViewport() throws {
        let list = try macShellSource("OppiMac/Views/MacSessionListView.swift")
        let listBody = try sourceSlice(
            from: "var body: some View {",
            to: "private func sessionSection",
            in: list
        )

        #expect(listBody.contains("ScrollViewReader"))
        #expect(listBody.contains(".onChange(of: selectedSessionID, initial: true)"))
        #expect(list.contains("scrollProxy.scrollTo(sessionID, anchor: .center)"))
        #expect(list.contains("collapsedStoppedGroupIDs.remove(group.id)"))
        #expect(list.contains("expandedStoppedGroupIDs.insert(group.id)"))
    }

    @Test func sessionListColumnGetsModestlyMoreRoomForTitles() throws {
        let main = try macShellSource("OppiMac/Views/MainWindowView.swift")

        #expect(main.contains(
            ".navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 420)"
        ))
    }

    private func macShellSource(_ relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func sourceSlice(
        from startMarker: String,
        to endMarker: String,
        in source: String
    ) throws -> String {
        let start = try #require(source.range(of: startMarker))
        let end = try #require(source.range(
            of: endMarker,
            range: start.upperBound..<source.endIndex
        ))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

@Suite("Mac session shell layout")
struct MacSessionShellLayoutTests {
    @Test func timelineStaysVisibleWhenNoDocumentIsOpen() {
        #expect(MacSessionShellLayoutPolicy.columns(
            availableWidth: 400,
            hasDocument: false
        ) == .timelineOnly)
        #expect(MacSessionShellLayoutPolicy.columns(
            availableWidth: 1_400,
            hasDocument: false
        ) == .timelineOnly)
    }

    @Test func constrainedDocumentReplacesTheTimeline() {
        #expect(MacSessionShellLayoutPolicy.columns(
            availableWidth: MacSessionShellLayoutPolicy.sideBySideMinimumWidth - 1,
            hasDocument: true
        ) == .documentOnly)
    }

    @Test func genuinelyWideDocumentKeepsTheTimelineBesideIt() {
        #expect(MacSessionShellLayoutPolicy.columns(
            availableWidth: MacSessionShellLayoutPolicy.sideBySideMinimumWidth,
            hasDocument: true
        ) == .timelineAndDocument)
    }

    @Test func eitherDocumentKindSuppressesTheInspector() {
        let workspaceDocument = MacSessionShellLayoutPolicy.hasDocument(
            workspaceDocumentIsOpen: true,
            toolDocumentIsOpen: false
        )
        let toolDocument = MacSessionShellLayoutPolicy.hasDocument(
            workspaceDocumentIsOpen: false,
            toolDocumentIsOpen: true
        )

        #expect(workspaceDocument)
        #expect(toolDocument)
        #expect(!MacSessionShellLayoutPolicy.shouldPresentInspector(
            requested: true,
            hasDocument: workspaceDocument
        ))
        #expect(!MacSessionShellLayoutPolicy.shouldPresentInspector(
            requested: true,
            hasDocument: toolDocument
        ))
        #expect(MacSessionShellLayoutPolicy.shouldPresentInspector(
            requested: true,
            hasDocument: false
        ))
    }
}

@Suite("Mac session composer control placement")
struct MacSessionComposerControlPlacementTests {
    @Test func stoppedSessionUsesResumeSurfaceInsteadOfDisabledComposerControls() {
        #expect(MacSessionWindowChrome.composerSurface(for: .stopped) == .resume)
        #expect(MacSessionWindowChrome.composerSurface(for: .ready) == .editor)
        #expect(MacSessionWindowChrome.composerSurface(for: .busy) == .editor)
        #expect(MacSessionWindowChrome.composerSurface(for: .stopping) == .stopping)
        #expect(MacSessionWindowChrome.composerSurface(for: .error) == .failed)
        #expect(MacSessionWindowChrome.composerSurface(for: nil) == .loading)
        #expect(MacSessionWindowChrome.composerSurface(for: .ready, isLoading: true) == .loading)
        #expect(!MacSessionWindowChrome.inspectorInitiallyPresented)
    }

    @Test func onlyTheEditorSurfaceAcceptsComposerInput() {
        #expect(MacSessionComposerSurface.editor.acceptsInput)
        #expect(!MacSessionComposerSurface.loading.acceptsInput)
        #expect(!MacSessionComposerSurface.resume.acceptsInput)
        #expect(!MacSessionComposerSurface.stopping.acceptsInput)
        #expect(!MacSessionComposerSurface.failed.acceptsInput)
    }

    @Test func initialTimelineLoadingOwnsProgressInsteadOfDuplicatingItInTheComposer() {
        #expect(!MacSessionWindowChrome.showsComposerStateBar(
            surface: .loading,
            hasTimelineItems: false
        ))
        #expect(MacSessionWindowChrome.showsComposerStateBar(
            surface: .loading,
            hasTimelineItems: true
        ))
        #expect(MacSessionWindowChrome.showsComposerStateBar(
            surface: .resume,
            hasTimelineItems: false
        ))
    }

    @Test func changingSessionsDiscardsUnsentComposerState() {
        #expect(MacSessionWindowChrome.shouldResetComposer(
            previousSessionID: "session-a",
            currentSessionID: "session-b"
        ))
        #expect(!MacSessionWindowChrome.shouldResetComposer(
            previousSessionID: "session-a",
            currentSessionID: "session-a"
        ))
    }

    @Test func asynchronousComposerResultsStayWithTheirOriginatingSession() {
        #expect(MacSessionWindowChrome.shouldApplyComposerCompletion(
            originatingSessionID: "session-a",
            currentSessionID: "session-a"
        ))
        #expect(!MacSessionWindowChrome.shouldApplyComposerCompletion(
            originatingSessionID: "session-a",
            currentSessionID: "session-b"
        ))
        #expect(!MacSessionWindowChrome.shouldApplyComposerCompletion(
            originatingSessionID: nil,
            currentSessionID: nil
        ))

        #expect(MacSessionWindowChrome.shouldApplyAttachmentCompletion(
            originatingSessionID: "session-a",
            currentSessionID: "session-a",
            surface: .editor
        ))
        #expect(!MacSessionWindowChrome.shouldApplyAttachmentCompletion(
            originatingSessionID: "session-a",
            currentSessionID: "session-b",
            surface: .editor
        ))
        #expect(!MacSessionWindowChrome.shouldApplyAttachmentCompletion(
            originatingSessionID: "session-a",
            currentSessionID: "session-a",
            surface: .resume
        ))
    }

    @Test func aboveAndBelowAuxiliaryRegionsShareOneHeightBudget() {
        let total = MacSessionWindowChrome.composerAuxiliaryTotalMaximumHeight
        let singleRegion = MacSessionWindowChrome.composerAuxiliaryRegionMaximumHeight(
            hasAboveEditorContent: true,
            hasBelowEditorContent: false
        )
        let splitRegion = MacSessionWindowChrome.composerAuxiliaryRegionMaximumHeight(
            hasAboveEditorContent: true,
            hasBelowEditorContent: true
        )

        #expect(singleRegion == total)
        #expect(
            splitRegion * 2 + MacSessionWindowChrome.composerAuxiliaryRegionSpacing == total
        )
        #expect(MacSessionWindowChrome.composerAuxiliaryRegionMaximumHeight(
            hasAboveEditorContent: false,
            hasBelowEditorContent: false
        ) == 0)
    }

    @Test func actionRowHoldsModelThinkingAndSteering() {
        #expect(MacSessionChromeItem.model.composerSlot == .actionRow)
        #expect(MacSessionChromeItem.thinking.composerSlot == .actionRow)
        #expect(MacSessionChromeItem.steering.composerSlot == .actionRow)
        #expect(MacSessionWindowChrome.composerActionRowItems(isBusy: true, hasAskRequest: false) == [
            .steering, .model, .thinking,
        ])
    }

    @Test func actionRowHidesSteeringWhenIdleOrAskIsVisible() {
        #expect(MacSessionWindowChrome.composerActionRowItems(isBusy: false, hasAskRequest: false) == [
            .model, .thinking,
        ])
        #expect(MacSessionWindowChrome.composerActionRowItems(isBusy: true, hasAskRequest: true) == [
            .model, .thinking,
        ])
        #expect(!MacSessionWindowChrome.showsSteering(isBusy: false, hasAskRequest: false))
        #expect(!MacSessionWindowChrome.showsSteering(isBusy: true, hasAskRequest: true))
        #expect(MacSessionWindowChrome.showsSteering(isBusy: true, hasAskRequest: false))
    }

    @Test func stopLivesOnTheSendButtonNotTheActionRow() {
        #expect(MacSessionChromeItem.stop.composerSlot == .primaryButton)
        #expect(!MacSessionWindowChrome.composerActionRowItems(isBusy: true, hasAskRequest: false).contains(.stop))
        #expect(!MacSessionWindowChrome.composerActionRowItems(isBusy: false, hasAskRequest: false).contains(.stop))
    }

    @Test func dictationLivesLeftOfTheSendFieldNotTheActionRow() {
        #expect(MacSessionChromeItem.dictation.composerSlot == .textRow)
        #expect(MacSessionWindowChrome.composerTextRowItems() == [.dictation])
        #expect(!MacSessionWindowChrome.composerActionRowItems(isBusy: true, hasAskRequest: false).contains(.dictation))
        #expect(!MacSessionWindowChrome.composerActionRowItems(isBusy: false, hasAskRequest: false).contains(.dictation))
    }

    @Test func sendBecomesStopWhileStreamingWithoutADraft() {
        #expect(
            MacSessionWindowChrome.composerPrimaryAction(
                isBusy: true,
                canSend: false,
                isSending: false,
                hasAskRequest: false
            ) == .stop
        )
    }

    @Test func sendStaysSendWhenBusyWithADraft() {
        #expect(
            MacSessionWindowChrome.composerPrimaryAction(
                isBusy: true,
                canSend: true,
                isSending: false,
                hasAskRequest: false
            ) == .send
        )
    }

    @Test func sendStaysSendWhileASendIsInFlight() {
        #expect(
            MacSessionWindowChrome.composerPrimaryAction(
                isBusy: true,
                canSend: false,
                isSending: true,
                hasAskRequest: false
            ) == .send
        )
    }

    @Test func askCardsKeepSendInsteadOfMorphingToStop() {
        #expect(
            MacSessionWindowChrome.composerPrimaryAction(
                isBusy: true,
                canSend: false,
                isSending: false,
                hasAskRequest: true
            ) == .send
        )
    }

    @Test func idleComposerKeepsSend() {
        #expect(
            MacSessionWindowChrome.composerPrimaryAction(
                isBusy: false,
                canSend: false,
                isSending: false,
                hasAskRequest: false
            ) == .send
        )
    }

    @Test func composerStopAbortsTurnInsteadOfKillingTheSession() {
        #expect(MacSessionWindowChrome.composerStopKind() == .abortTurn)
        #expect(MacSessionWindowChrome.sessionListStopKind() == .stopSessionProcess)
        #expect(MacSessionWindowChrome.composerStopKind() != MacSessionWindowChrome.sessionListStopKind())
    }
}

@Suite("Mac session deep links")
struct MacSessionDeepLinkTests {
    @Test func parserAcceptsOnlyCanonicalSessionRoute() throws {
        let canonical = try #require(URL(string: "oppi://session/child%2D1?workspaceId=ignored"))
        let extraPath = try #require(URL(string: "oppi://session/child/extra"))
        let workspace = try #require(URL(string: "oppi://workspace?path=/tmp/project"))
        let web = try #require(URL(string: "https://example.com/session/child-1"))
        let uppercase = try #require(URL(string: "OPPI://SESSION/abc-123"))

        #expect(MacSessionDeepLink.sessionId(from: canonical) == "child-1")
        #expect(MacSessionDeepLink.sessionId(from: extraPath) == nil)
        #expect(MacSessionDeepLink.sessionId(from: workspace) == nil)
        #expect(MacSessionDeepLink.sessionId(from: web) == nil)
        #expect(MacSessionDeepLink.sessionId(from: uppercase) == "abc-123")
    }

    @Test func urlRoundTripsCanonicalSessionId() throws {
        let url = try #require(MacSessionDeepLink.url(for: "child-1"))
        #expect(MacSessionDeepLink.sessionId(from: url) == "child-1")
        #expect(MacSessionDeepLink.url(for: "") == nil)
    }

    @Test func knownSessionSelectsEvenBeforeCatalogFinishes() {
        #expect(
            MacSessionDeepLinkNavigation.destination(
                sessionId: "sess-1",
                knownSessionIDs: ["sess-1"],
                catalogReady: false
            ) == .selectSession("sess-1")
        )
    }

    @Test func unknownSessionParksUntilCatalogIsReady() {
        #expect(
            MacSessionDeepLinkNavigation.destination(
                sessionId: "sess-missing",
                knownSessionIDs: ["sess-1"],
                catalogReady: false
            ) == .park
        )
    }

    @Test func unknownSessionOpensWorkspacesAfterCatalogIsReady() {
        #expect(
            MacSessionDeepLinkNavigation.destination(
                sessionId: "sess-missing",
                knownSessionIDs: ["sess-1"],
                catalogReady: true
            ) == .showWorkspaces
        )
    }

    @Test func emptyOrMissingSessionIdIsIgnored() {
        #expect(
            MacSessionDeepLinkNavigation.destination(
                sessionId: nil,
                knownSessionIDs: ["sess-1"],
                catalogReady: true
            ) == .ignore
        )
        #expect(
            MacSessionDeepLinkNavigation.destination(
                sessionId: "",
                knownSessionIDs: ["sess-1"],
                catalogReady: true
            ) == .ignore
        )
    }

    @MainActor
    @Test func initialCatalogFailureRetriesOnReadinessAndFindsUncachedSession() async throws {
        #expect(
            MacSessionDeepLinkNavigation.destination(
                sessionId: "session-old",
                knownSessionIDs: [],
                catalogReady: false
            ) == .park
        )
        #expect(!MacSessionDeepLinkNavigation.shouldRetryAfterServerBecameReady(
            state: .starting,
            hasPendingSessionDeepLink: true
        ))
        #expect(MacSessionDeepLinkNavigation.shouldRetryAfterServerBecameReady(
            state: .running,
            hasPendingSessionDeepLink: true
        ))

        let session = Session(
            id: "session-old",
            workspaceId: "ws-old",
            name: "Old session",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            messageCount: 3,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )

        let destination = await MacSessionDeepLinkNavigation.fetchedDestination(
            sessionId: "session-old",
            isCurrentRequest: { true },
            fetchSession: { requestedID in
                #expect(requestedID == "session-old")
                return session
            }
        )

        guard case .selectTarget(let target) = destination else {
            Issue.record("Expected fetched stopped session to select its target")
            return
        }
        #expect(target.sessionId == "session-old")
        #expect(target.workspaceId == "ws-old")
        #expect(target.routeScope == .workspace("ws-old"))
    }

    @MainActor
    @Test func uncachedControlSessionFetchPreservesControlRouting() async throws {
        var session = Session(
            id: "control-old",
            workspaceId: nil,
            name: "Old control session",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            messageCount: 3,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        session.control = ControlSessionMetadata(
            domain: .agents,
            intent: .revise,
            targetId: "agent-1",
            targetName: "Agent"
        )

        let destination = await MacSessionDeepLinkNavigation.fetchedDestination(
            sessionId: "control-old",
            isCurrentRequest: { true },
            fetchSession: { _ in session }
        )

        guard case .selectTarget(let target) = destination else {
            Issue.record("Expected fetched control session to select its target")
            return
        }
        #expect(target.routeScope == .control)
    }

    @MainActor
    @Test func initialCatalogFailureRetriesOnReadinessAndFallsBackWhenSessionIsNotFound() async {
        #expect(
            MacSessionDeepLinkNavigation.destination(
                sessionId: "session-missing",
                knownSessionIDs: [],
                catalogReady: false
            ) == .park
        )
        #expect(MacSessionDeepLinkNavigation.shouldRetryAfterServerBecameReady(
            state: .running,
            hasPendingSessionDeepLink: true
        ))
        #expect(!MacSessionDeepLinkNavigation.shouldRetryAfterServerBecameReady(
            state: .running,
            hasPendingSessionDeepLink: false
        ))

        for error in [
            MacWorkspaceClientError.server(status: 404, message: "not found"),
            MacWorkspaceClientError.server(status: 500, message: "failed"),
        ] {
            let destination = await MacSessionDeepLinkNavigation.fetchedDestination(
                sessionId: "session-missing",
                isCurrentRequest: { true },
                fetchSession: { _ in throw error }
            )
            #expect(destination == .showWorkspaces)
        }
    }

    @MainActor
    @Test func staleFetchDoesNotNavigateAfterNewerDeepLink() async {
        var isCurrentRequest = true
        let staleSession = Session(
            id: "session-old",
            workspaceId: "ws-old",
            status: .stopped,
            createdAt: Date(timeIntervalSince1970: 1),
            lastActivity: Date(timeIntervalSince1970: 2),
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )

        let destination = await MacSessionDeepLinkNavigation.fetchedDestination(
            sessionId: "session-old",
            isCurrentRequest: { isCurrentRequest },
            fetchSession: { _ in
                isCurrentRequest = false
                return staleSession
            }
        )

        #expect(destination == .ignore)
    }

    @Test func macAppOpensSessionURLsOnTheMainWindow() throws {
        let appSource = try macSource("OppiMac/App/OppiMacApp.swift")
        let windowSource = try macSource("OppiMac/Views/MainWindowView.swift")
        #expect(appSource.contains(".onOpenURL"))
        #expect(appSource.contains("MacSessionDeepLink"))
        #expect(appSource.contains("pendingSessionDeepLinkURL"))
        #expect(windowSource.contains("pendingSessionDeepLinkURL"))
        #expect(windowSource.contains("MacSessionDeepLinkNavigation"))
        #expect(windowSource.contains(".onChange(of: processManager.state)"))
        #expect(windowSource.contains("shouldRetryAfterServerBecameReady"))
        #expect(windowSource.contains("selectSessionTarget"))
        #expect(windowSource.contains(".workspaces"))
    }

    @Test func macInfoPlistRegistersTheOppiURLScheme() throws {
        let plist = try macSource("OppiMac/Resources/Info.plist")
        #expect(plist.contains("CFBundleURLSchemes"))
        #expect(plist.contains("<string>oppi</string>"))
    }

    private func macSource(_ relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

@Suite("Mac stats chrome")
struct MacStatsChromeTests {

    @Test func menuBarSummaryIsOmittedUntilLiveStatsArrive() {
        #expect(MenuBarStatsSummary.line(from: nil) == nil)
    }

    @Test func menuBarSummaryUsesLiveTotals() {
        let stats = ServerStats(
            memory: StatsMemory(heapUsed: 0, heapTotal: 0, rss: 0, external: 0),
            activeSessions: [],
            daily: [],
            modelBreakdown: [],
            workspaceBreakdown: [],
            totals: StatsTotals(sessions: 3, cost: 1.25, tokens: 9000)
        )
        #expect(MenuBarStatsSummary.line(from: stats) == "3 sessions \u{00B7} $1.25")
    }

    @Test func menuBarSummaryUsesSingularSession() {
        let stats = ServerStats(
            memory: StatsMemory(heapUsed: 0, heapTotal: 0, rss: 0, external: 0),
            activeSessions: [],
            daily: [],
            modelBreakdown: [],
            workspaceBreakdown: [],
            totals: StatsTotals(sessions: 1, cost: 0.004, tokens: 10)
        )
        #expect(MenuBarStatsSummary.line(from: stats) == "1 session \u{00B7} \(SessionFormatting.costString(0.004))")
    }

    @Test func hostToolRevealSelectsSettingsStats() {
        let revealed = MacHostToolReveal.selection(for: .stats)
        #expect(revealed.section == .settings)
        #expect(revealed.pane == .stats)
    }

    @Test func hostToolRevealReadsStatsPaneFromNotification() {
        let note = Notification(
            name: .revealMacHostTool,
            object: MacSettingsPane.stats
        )
        #expect(MacHostToolReveal.pane(from: note) == .stats)
        #expect(MacHostToolReveal.pane(from: Notification(name: .revealMacHostTool)) == nil)
    }
}
