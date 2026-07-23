import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Workspace Detail Your Turn Sorting")
struct WorkspaceDetailSortTests {
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeSession(
        id: String,
        status: SessionStatus = .ready,
        createdAt: Date? = nil,
        lastActivity: Date? = nil
    ) -> Session {
        let created = createdAt ?? baseTime
        return Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Test",
            name: "Session \(id)",
            status: status,
            createdAt: created,
            lastActivity: lastActivity ?? created,
            model: "test/model",
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
    }

    @Test func sameTier_olderVisibleActivityComesFirst() {
        let older = makeSession(id: "older", lastActivity: baseTime)
        let newer = makeSession(id: "newer", lastActivity: baseTime.addingTimeInterval(60))

        let sorted = workspaceYourTurnSorted(
            [newer, older],
            hasAskInQueue: { _ in false }
        )

        #expect(sorted.map(\.id) == ["older", "newer"])
    }

    @Test func visibleActivityWinsOverCreationTime() {
        let createdEarlierButNewerActivity = makeSession(
            id: "created-first",
            createdAt: baseTime,
            lastActivity: baseTime.addingTimeInterval(120)
        )
        let createdLaterButOlderActivity = makeSession(
            id: "activity-first",
            createdAt: baseTime.addingTimeInterval(60),
            lastActivity: baseTime.addingTimeInterval(30)
        )

        let sorted = workspaceYourTurnSorted(
            [createdEarlierButNewerActivity, createdLaterButOlderActivity],
            hasAskInQueue: { _ in false }
        )

        #expect(sorted.map(\.id) == ["activity-first", "created-first"])
    }

    @Test func asksStayAheadOfPlainSessions() {
        let ask = makeSession(id: "ask", lastActivity: baseTime)
        let plain = makeSession(id: "plain", lastActivity: baseTime.addingTimeInterval(-120))

        let sorted = workspaceYourTurnSorted(
            [plain, ask],
            hasAskInQueue: { $0 == "ask" }
        )

        #expect(sorted.map(\.id) == ["ask", "plain"])
    }

    @Test func equalVisibleActivityFallsBackToCreationTime() {
        let older = makeSession(
            id: "older",
            createdAt: baseTime,
            lastActivity: baseTime.addingTimeInterval(30)
        )
        let newer = makeSession(
            id: "newer",
            createdAt: baseTime.addingTimeInterval(60),
            lastActivity: baseTime.addingTimeInterval(30)
        )

        let sorted = workspaceYourTurnSorted(
            [newer, older],
            hasAskInQueue: { _ in false }
        )

        #expect(sorted.map(\.id) == ["older", "newer"])
    }

    @Test func deleteConfirmationClearsPendingBeforeDeleteCallback() {
        let session = makeSession(id: "delete-me")
        var pendingSession: Session? = session
        var didDelete = false
        var pendingWasClearedBeforeDelete = false

        SessionDeleteConfirmationPolicy.confirm(
            session: session,
            clearPending: { pendingSession = nil },
            performDelete: { deleted in
                didDelete = deleted.id == session.id
                pendingWasClearedBeforeDelete = pendingSession == nil
            }
        )

        #expect(didDelete)
        #expect(pendingSession == nil)
        #expect(pendingWasClearedBeforeDelete)
    }

    @Test func deleteSwipeActionOnlyOpensConfirmation() {
        #expect(SessionDeleteConfirmationPolicy.swipeButtonRole == nil)
    }

    @Test func knownWorkspaceNotFoundDoesNotPresentBlockingLoadError() {
        let shouldPresent = WorkspaceDetailLoadErrorPolicy.shouldPresent(
            error: APIError.server(status: 404, message: "Workspace not found"),
            workspaceId: "ws-known",
            hadVisibleData: false,
            knownWorkspaceIds: ["ws-known"]
        )

        #expect(!shouldPresent)
    }

    @Test func unknownWorkspaceNotFoundStillPresentsLoadError() {
        let shouldPresent = WorkspaceDetailLoadErrorPolicy.shouldPresent(
            error: APIError.server(status: 404, message: "Workspace not found"),
            workspaceId: "ws-missing",
            hadVisibleData: false,
            knownWorkspaceIds: ["ws-known"]
        )

        #expect(shouldPresent)
    }
}

@Suite("Workspace Edit Save Completion")
struct WorkspaceEditSaveCompletionTests {
    @Test func callbackOwnsCompletionWhenProvided() {
        var callbackCount = 0
        var dismissCount = 0

        WorkspaceEditSaveCompletionPolicy.complete(
            onSaved: { callbackCount += 1 },
            dismiss: { dismissCount += 1 }
        )

        #expect(callbackCount == 1)
        #expect(dismissCount == 0)
    }

    @Test func environmentDismissesWhenNoCallbackIsProvided() {
        var dismissCount = 0

        WorkspaceEditSaveCompletionPolicy.complete(
            onSaved: nil,
            dismiss: { dismissCount += 1 }
        )

        #expect(dismissCount == 1)
    }
}

@Suite("Workspace Pi Resource Scope")
struct WorkspacePiResourceScopePolicyTests {
    @Test func mountlessSandboxUsesWorkspaceIdentity() {
        let scope = WorkspacePiResourceScopePolicy.resolve(
            runtime: .sandbox,
            persistedHostMount: nil,
            draftHostMount: "",
            workspaceId: "sandbox-workspace"
        )

        #expect(scope == WorkspacePiResourceScope(workspaceId: "sandbox-workspace", cwd: nil))
    }

    @Test func unchangedHostWorkspaceUsesWorkspaceIdentity() {
        let scope = WorkspacePiResourceScopePolicy.resolve(
            runtime: .host,
            persistedHostMount: " ~/workspace/project ",
            draftHostMount: "~/workspace/project",
            workspaceId: "host-workspace"
        )

        #expect(scope == WorkspacePiResourceScope(workspaceId: "host-workspace", cwd: nil))
    }

    @Test func clearedHostFolderFallsBackToWorkspaceIdentity() {
        let scope = WorkspacePiResourceScopePolicy.resolve(
            runtime: .host,
            persistedHostMount: "~/workspace/old",
            draftHostMount: "  ",
            workspaceId: "host-workspace"
        )

        #expect(scope == WorkspacePiResourceScope(workspaceId: "host-workspace", cwd: nil))
    }

    @Test func draftHostFolderUsesExplicitProjectCwd() {
        let scope = WorkspacePiResourceScopePolicy.resolve(
            runtime: .host,
            persistedHostMount: "~/workspace/old",
            draftHostMount: " ~/workspace/new ",
            workspaceId: "host-workspace"
        )

        #expect(scope == WorkspacePiResourceScope(workspaceId: nil, cwd: "~/workspace/new"))
    }
}

@Suite("Workspace icon picker catalog")
struct WorkspaceIconPickerCatalogTests {
    @Test func emptySearchReturnsEveryCuratedSymbol() {
        #expect(WorkspaceIconCatalog.filtered(by: "").count == WorkspaceIconCatalog.options.count)
    }

    @Test func searchMatchesLabelsAndSymbolNamesCaseInsensitively() {
        #expect(WorkspaceIconCatalog.filtered(by: "CODE").contains { $0.symbolName == "chevron.left.forwardslash.chevron.right" })
        #expect(WorkspaceIconCatalog.filtered(by: "branch").contains { $0.symbolName == "arrow.triangle.branch" })
    }

    @Test func unmatchedSearchReturnsNoSymbols() {
        #expect(WorkspaceIconCatalog.filtered(by: "definitely-not-an-icon").isEmpty)
    }

    @Test func curatedSymbolsResolveToHumanFacingLabels() {
        #expect(WorkspaceIconCatalog.label(for: "chevron.left.forwardslash.chevron.right") == "Code")
        #expect(WorkspaceIconCatalog.label(for: "🧠") == nil)
    }
}

@Suite("Workspace Pi Resource Error Policy")
struct WorkspacePiResourceErrorPolicyTests {
    @Test func cancellationDoesNotPresentAsSettingsError() {
        #expect(!WorkspacePiResourceErrorPolicy.shouldPresent(CancellationError()))
        #expect(!WorkspacePiResourceErrorPolicy.shouldPresent(URLError(.cancelled)))
    }

    @Test func nonCancellationErrorPresentsAsSettingsError() {
        #expect(WorkspacePiResourceErrorPolicy.shouldPresent(URLError(.notConnectedToInternet)))
        #expect(WorkspacePiResourceErrorPolicy.shouldPresent(APIError.server(status: 500, message: "boom")))
    }
}
