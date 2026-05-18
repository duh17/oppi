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
            hasPermissionInQueue: { _ in false },
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
            hasPermissionInQueue: { _ in false },
            hasAskInQueue: { _ in false }
        )

        #expect(sorted.map(\.id) == ["activity-first", "created-first"])
    }

    @Test func permissionsStayAheadOfAsksAndPlainSessions() {
        let permission = makeSession(id: "permission", lastActivity: baseTime.addingTimeInterval(120))
        let ask = makeSession(id: "ask", lastActivity: baseTime)
        let plain = makeSession(id: "plain", lastActivity: baseTime.addingTimeInterval(-120))

        let sorted = workspaceYourTurnSorted(
            [plain, ask, permission],
            hasPermissionInQueue: { $0 == "permission" },
            hasAskInQueue: { $0 == "ask" }
        )

        #expect(sorted.map(\.id) == ["permission", "ask", "plain"])
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
            hasPermissionInQueue: { _ in false },
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
}
