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

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ReviewCommentStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
