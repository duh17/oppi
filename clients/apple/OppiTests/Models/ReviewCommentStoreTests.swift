import Foundation
import Testing
@testable import Oppi

@Suite("Review comment local draft store")
@MainActor
struct ReviewCommentStoreTests {
    @Test func savesDraftsToLocalSessionScopeAndReloadsThem() throws {
        let defaults = try makeDefaults()
        let firstStore = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        firstStore.load(workspaceId: "workspace-1", sessionId: "session-1")

        let saved = try firstStore.create(
            workspaceId: "workspace-1",
            sessionId: "session-1",
            body: "  Please tighten this.  ",
            reference: reference(path: "Sources/App.swift", selectedText: "let value = compute()")
        )

        #expect(saved.body == "Please tighten this.")
        #expect(firstStore.stagedCount == 1)

        let reloadedStore = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        reloadedStore.load(workspaceId: "workspace-1", sessionId: "session-1")

        #expect(reloadedStore.stagedComments.map(\.id) == [saved.id])
        #expect(reloadedStore.stagedComments.first?.reference.path == "Sources/App.swift")

        let otherSessionStore = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        otherSessionStore.load(workspaceId: "workspace-1", sessionId: "session-2")
        #expect(otherSessionStore.stagedComments.isEmpty)
    }

    @Test func updateBodyTrimsAndPersistsDraftChanges() throws {
        let defaults = try makeDefaults()
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        store.load(workspaceId: "workspace-1", sessionId: "session-1")
        let saved = try store.create(
            workspaceId: "workspace-1",
            sessionId: "session-1",
            body: "Original note.",
            reference: reference(path: "Sources/App.swift", selectedText: nil)
        )

        let updated = try store.updateBody(commentId: saved.id, body: "\n  Sharpen this recommendation.  \n")

        #expect(updated.body == "Sharpen this recommendation.")
        #expect(updated.updatedAt >= saved.updatedAt)

        let reloadedStore = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        reloadedStore.load(workspaceId: "workspace-1", sessionId: "session-1")
        #expect(reloadedStore.stagedComments.first?.id == saved.id)
        #expect(reloadedStore.stagedComments.first?.body == "Sharpen this recommendation.")
    }

    @Test func updateBodyRejectsEmptyDraftChanges() throws {
        let defaults = try makeDefaults()
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        store.load(workspaceId: "workspace-1", sessionId: "session-1")
        let saved = try store.create(
            workspaceId: "workspace-1",
            sessionId: "session-1",
            body: "Keep this.",
            reference: reference(path: "Sources/App.swift", selectedText: nil)
        )

        #expect(throws: ReviewCommentStoreError.emptyBody) {
            try store.updateBody(commentId: saved.id, body: "   \n")
        }
        #expect(store.stagedComments.first?.body == "Keep this.")
    }

    @Test func appendReviewBlockIncludesLocalDraftContextForAgentSubmission() throws {
        let defaults = try makeDefaults()
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        store.load(workspaceId: "workspace-1", sessionId: "session-1")
        _ = try store.create(
            workspaceId: "workspace-1",
            sessionId: "session-1",
            body: "Check the nil path.",
            reference: reference(path: "Sources/App.swift", selectedText: "guard let value else { return }")
        )

        let message = store.appendReviewBlock(to: "Please fix this.")

        #expect(message.contains("Please fix this."))
        #expect(message.contains("## Review comments"))
        #expect(message.contains("**Where:** `Sources/App.swift`:12 (file)"))
        #expect(message.contains("guard let value else { return }"))
        #expect(message.contains("> Check the nil path."))
    }

    @Test func clearSentRemovesSubmittedDraftsFromLocalPersistence() throws {
        let defaults = try makeDefaults()
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        store.load(workspaceId: "workspace-1", sessionId: "session-1")
        let saved = try store.create(
            workspaceId: "workspace-1",
            sessionId: "session-1",
            body: "Done after send.",
            reference: reference(path: "Sources/App.swift", selectedText: nil)
        )

        store.clearSent(ids: [saved.id])

        let reloadedStore = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        reloadedStore.load(workspaceId: "workspace-1", sessionId: "session-1")
        #expect(reloadedStore.stagedComments.isEmpty)
    }

    @Test func movesTargetDraftsIntoControlSessionWithoutDuplicates() throws {
        let defaults = try makeDefaults()
        let prefix = "test.reviewComments"
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        store.load(workspaceId: ReviewCommentLocalScope.controlDraft, sessionId: "schedules:schedule-1")
        let first = try store.create(
            workspaceId: ReviewCommentLocalScope.controlDraft,
            sessionId: "schedules:schedule-1",
            body: "Change the heading.",
            reference: reference(path: "Schedules/Daily review.md", selectedText: "# Daily review")
        )
        let second = try store.create(
            workspaceId: ReviewCommentLocalScope.controlDraft,
            sessionId: "schedules:schedule-1",
            body: "Make this weekly.",
            reference: reference(path: "Schedules/Daily review.md", selectedText: "Run every day")
        )

        let controlScopeId = SessionRouteScope.control.composerDraftScopeID
        let destinationSeed = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        destinationSeed.load(workspaceId: controlScopeId, sessionId: "control-session-1")
        let existing = try destinationSeed.create(
            workspaceId: controlScopeId,
            sessionId: "control-session-1",
            body: "Keep this existing note.",
            reference: reference(path: "Existing.md", selectedText: nil)
        )

        let moved = try store.moveStagedComments(
            fromWorkspaceId: ReviewCommentLocalScope.controlDraft,
            fromSessionId: "schedules:schedule-1",
            toWorkspaceId: controlScopeId,
            toSessionId: "control-session-1"
        )
        let movedAgain = try store.moveStagedComments(
            fromWorkspaceId: ReviewCommentLocalScope.controlDraft,
            fromSessionId: "schedules:schedule-1",
            toWorkspaceId: controlScopeId,
            toSessionId: "control-session-1"
        )

        #expect(moved == 2)
        #expect(movedAgain == 0)

        let source = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        source.load(workspaceId: ReviewCommentLocalScope.controlDraft, sessionId: "schedules:schedule-1")
        #expect(source.stagedComments.isEmpty)

        let destination = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        destination.load(workspaceId: controlScopeId, sessionId: "control-session-1")
        #expect(destination.comments.map(\.id) == [existing.id, first.id, second.id])
        #expect(destination.comments.map(\.workspaceId) == [
            controlScopeId,
            controlScopeId,
            controlScopeId,
        ])
        #expect(destination.comments.map(\.sessionId) == [
            "control-session-1",
            "control-session-1",
            "control-session-1",
        ])
    }

    @Test func interruptedMoveJournalFinishesBeforeEitherScopeLoads() throws {
        let defaults = try makeDefaults()
        let prefix = "test.reviewComments"
        let sourceScope = ReviewCommentLocalScope.controlDraft
        let sourceSession = "server-1:schedules:schedule-1"
        let destinationScope = SessionRouteScope.control.composerDraftScopeID
        let destinationSession = "control-session-1"
        let sourceStore = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        sourceStore.load(workspaceId: sourceScope, sessionId: sourceSession)
        let saved = try sourceStore.create(
            workspaceId: sourceScope,
            sessionId: sourceSession,
            body: "Finish moving this.",
            reference: reference(path: "Prompt.md", selectedText: "Daily")
        )

        let sourceKey = ReviewCommentStore.makeStorageKey(
            prefix: prefix,
            workspaceId: sourceScope,
            sessionId: sourceSession
        )
        let destinationKey = ReviewCommentStore.makeStorageKey(
            prefix: prefix,
            workspaceId: destinationScope,
            sessionId: destinationSession
        )
        let moved = retargeted(saved, workspaceId: destinationScope, sessionId: destinationSession)
        let journal = ReviewCommentMoveJournal(
            sourceKey: sourceKey,
            destinationKey: destinationKey,
            sourceData: try JSONEncoder().encode([ReviewComment]()),
            destinationData: try JSONEncoder().encode([moved])
        )
        defaults.set(
            try JSONEncoder().encode(journal),
            forKey: ReviewCommentStore.moveJournalKey(prefix: prefix)
        )
        defaults.set(try JSONEncoder().encode([moved]), forKey: destinationKey)

        let recoveredSource = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        recoveredSource.load(workspaceId: sourceScope, sessionId: sourceSession)
        #expect(recoveredSource.stagedComments.isEmpty)
        #expect(defaults.data(forKey: ReviewCommentStore.moveJournalKey(prefix: prefix)) == nil)

        let recoveredDestination = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        recoveredDestination.load(workspaceId: destinationScope, sessionId: destinationSession)
        #expect(recoveredDestination.stagedComments.map(\.id) == [saved.id])
    }

    @Test func invalidDestinationLeavesSourceDraftIntact() throws {
        let defaults = try makeDefaults()
        let prefix = "test.reviewComments"
        let sourceScope = ReviewCommentLocalScope.controlDraft
        let sourceSession = "server-1:agents:agent-1"
        let destinationScope = SessionRouteScope.control.composerDraftScopeID
        let destinationSession = "control-session-1"
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        store.load(workspaceId: sourceScope, sessionId: sourceSession)
        let saved = try store.create(
            workspaceId: sourceScope,
            sessionId: sourceSession,
            body: "Do not lose this.",
            reference: reference(path: "Definition.md", selectedText: "Reviewer")
        )
        defaults.set(
            Data("not-json".utf8),
            forKey: ReviewCommentStore.makeStorageKey(
                prefix: prefix,
                workspaceId: destinationScope,
                sessionId: destinationSession
            )
        )

        #expect(throws: ReviewCommentStoreError.invalidStoredComments) {
            try store.moveStagedComments(
                fromWorkspaceId: sourceScope,
                fromSessionId: sourceSession,
                toWorkspaceId: destinationScope,
                toSessionId: destinationSession
            )
        }

        let reloaded = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)
        reloaded.load(workspaceId: sourceScope, sessionId: sourceSession)
        #expect(reloaded.stagedComments.map(\.id) == [saved.id])
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ReviewCommentStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func retargeted(
        _ comment: ReviewComment,
        workspaceId: String,
        sessionId: String
    ) -> ReviewComment {
        ReviewComment(
            id: comment.id,
            workspaceId: workspaceId,
            sessionId: sessionId,
            turnId: comment.turnId,
            author: comment.author,
            status: comment.status,
            severity: comment.severity,
            body: comment.body,
            attachments: comment.attachments,
            reference: comment.reference,
            createdAt: comment.createdAt,
            updatedAt: comment.updatedAt,
            sentAt: comment.sentAt
        )
    }

    private func reference(path: String, selectedText: String?) -> ReviewCommentReference {
        ReviewCommentReference(
            source: .file,
            label: nil,
            path: path,
            side: nil,
            startLine: 12,
            endLine: 12,
            selectedText: selectedText,
            toolCallId: nil,
            timelineItemId: nil,
            url: nil
        )
    }
}
