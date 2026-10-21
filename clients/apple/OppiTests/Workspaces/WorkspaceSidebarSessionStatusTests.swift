import SwiftUI
import Testing
@testable import Oppi

@Suite("Workspace catalog availability")
struct WorkspaceCatalogAvailabilityTests {
    @Test func workspaceDisclosureStartsExpandedAndUsesStableStorageKey() {
        #expect(WorkspaceSidebarDisclosurePolicy.defaultExpanded)
        #expect(AppIdentifiers.workspaceSidebarExpandedKey == "workspace.sidebar.workspaces.expanded")
    }

    @Test func authoritativeEmptyCatalogIsDistinctFromUnloadedAndFailedCatalogs() {
        #expect(WorkspaceCatalogAvailability(
            hasWorkspaces: false,
            isLoaded: true,
            isSyncing: false,
            lastSyncFailed: false
        ) == .empty)
        #expect(WorkspaceCatalogAvailability(
            hasWorkspaces: false,
            isLoaded: false,
            isSyncing: false,
            lastSyncFailed: false
        ) == .loading)
        #expect(WorkspaceCatalogAvailability(
            hasWorkspaces: false,
            isLoaded: false,
            isSyncing: false,
            lastSyncFailed: true
        ) == .unavailable)
    }

    @Test func offlineEmptyCatalogCannotMasqueradeAsAuthoritativeEmpty() {
        #expect(WorkspaceCatalogAvailability(
            hasWorkspaces: false,
            isLoaded: true,
            isSyncing: false,
            lastSyncFailed: false,
            hasAPIClient: false
        ) == .unavailable)
        #expect(WorkspaceCatalogAvailability(
            hasWorkspaces: false,
            isLoaded: false,
            isSyncing: false,
            lastSyncFailed: false,
            hasAPIClient: false,
            isPreparing: true
        ) == .loading)
        #expect(WorkspaceCatalogAvailability(
            hasWorkspaces: true,
            isLoaded: true,
            isSyncing: false,
            lastSyncFailed: false,
            hasAPIClient: false
        ) == .available)
    }

    @Test func cachedCatalogRemainsAvailableAfterRefreshFailure() {
        #expect(WorkspaceCatalogAvailability(
            hasWorkspaces: true,
            isLoaded: true,
            isSyncing: false,
            lastSyncFailed: true
        ) == .available)
    }
}

@Suite("Session inbox transport availability")
struct SessionInboxTransportAvailabilityTests {
    @Test func neverConnectedServerIsUnavailableUntilPreparedOrConnected() {
        #expect(SessionInboxTransportAvailability.isUnavailable(hasAPIClient: false, isPreparing: false))
        #expect(!SessionInboxTransportAvailability.isUnavailable(hasAPIClient: false, isPreparing: true))
        #expect(!SessionInboxTransportAvailability.isUnavailable(hasAPIClient: true, isPreparing: false))
    }
}

@Suite("Workspace sidebar session status")
struct WorkspaceSidebarSessionStatusTests {
    @Test func countsAttentionWorkingAndDoneUsingSessionRowSemantics() {
        let status = WorkspaceSidebarSessionStatus(sessions: [
            makeTestSession(id: "busy", status: .busy, messageCount: 1, firstMessage: "Working"),
            makeTestSession(id: "starting", status: .starting, messageCount: 1, firstMessage: "Starting"),
            makeTestSession(id: "ready", status: .ready, messageCount: 1, firstMessage: "Finished"),
            makeTestSession(id: "stopped", status: .stopped, messageCount: 1, firstMessage: "Stopped"),
            makeTestSession(id: "error", status: .error, messageCount: 1, firstMessage: "Failed"),
        ])

        #expect(status.blockedCount == 0)
        #expect(status.errorCount == 1)
        #expect(status.attentionCount == 1)
        #expect(status.workingCount == 2)
        #expect(status.doneCount == 1)
        #expect(status.showsDone == false)
        #expect(status.accessibilityValue == "1 session has an error, 2 working sessions, 1 done session")
    }

    @Test func excludesDraftSessionsAndPrioritizesQuestionsOverDone() {
        let status = WorkspaceSidebarSessionStatus(
            sessions: [
                makeTestSession(id: "ready-draft", status: .ready),
                makeTestSession(id: "starting-draft", status: .starting),
                makeTestSession(
                    id: "question",
                    status: .ready,
                    messageCount: 1,
                    firstMessage: "Need input"
                ),
            ],
            pendingAskCountForSession: { $0 == "question" ? 1 : 0 }
        )

        #expect(status.blockedCount == 1)
        #expect(status.errorCount == 0)
        #expect(status.attentionCount == 1)
        #expect(status.doneCount == 0)
        #expect(status.showsDone == false)
        #expect(status.isVisible)
        #expect(status.accessibilityValue == "1 session needs attention")
    }

    @Test func countsOnlyLiveSessionsAndStoppedOutcomesNeverCount() {
        let since = Date(timeIntervalSince1970: 1_000)
        func session(
            _ id: String,
            _ status: SessionStatus,
            _ state: ProgramStatusState,
            kind: ProgramStatusKind? = nil
        ) -> Session {
            makeTestSession(
                id: id,
                status: status,
                programStatus: ProgramStatus(state: state, kind: kind, since: since),
                messageCount: 1,
                firstMessage: "go"
            )
        }
        let status = WorkspaceSidebarSessionStatus(sessions: [
            session("approval", .ready, .blocked, kind: .permission),
            session("signin", .ready, .blocked, kind: .auth),
            session("live-done", .ready, .done),
            session("live-idle", .ready, .idle),
            session("stopped-done", .stopped, .done),
            session("stopped-error", .stopped, .error),
            session("stopped-idle", .stopped, .idle),
        ])

        #expect(status.blockedCount == 2)
        #expect(status.errorCount == 0)
        #expect(status.workingCount == 0)
        #expect(status.doneCount == 2)
    }

    @Test func stoppedSessionsAloneHideTheStatus() {
        let status = WorkspaceSidebarSessionStatus(sessions: [
            makeTestSession(
                id: "finished",
                status: .stopped,
                programStatus: ProgramStatus(state: .done, since: Date(timeIntervalSince1970: 1_000)),
                messageCount: 1,
                firstMessage: "go"
            ),
        ])

        #expect(!status.isVisible)
    }

    @Test func showsDoneWhenNoSessionNeedsAttention() {
        let status = WorkspaceSidebarSessionStatus(sessions: [
            makeTestSession(id: "working", status: .busy, messageCount: 1, firstMessage: "Working"),
            makeTestSession(id: "done", status: .ready, messageCount: 1, firstMessage: "Finished"),
        ])

        #expect(status.showsDone)
    }

    @MainActor
    @Test func rendersPriorityMetricsWithinTheNarrowTrailingBudget() {
        let status = WorkspaceSidebarSessionStatus(sessions: [
            makeTestSession(id: "error", status: .error, messageCount: 1, firstMessage: "Failed"),
            makeTestSession(id: "working", status: .busy, messageCount: 1, firstMessage: "Working"),
            makeTestSession(id: "done", status: .ready, messageCount: 1, firstMessage: "Finished"),
        ])
        let text = WorkspaceSidebarRowContentView.statusText(
            status,
            colors: ComposerThemeColors(palette: ThemeID.dark.palette)
        )
        let size = text.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            context: nil
        ).size

        #expect(size.width <= 64)
        #expect(size.height <= 44)
    }
}
