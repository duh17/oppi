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

    @Test func stagedCommentsBecomeTheContextItemsTheNextMessageSends() throws {
        let defaults = try makeDefaults()
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        store.load(workspaceId: "workspace-1", sessionId: "session-1")
        _ = try store.create(
            workspaceId: "workspace-1",
            sessionId: "session-1",
            body: "Check the nil path.",
            reference: reference(path: "Sources/App.swift", selectedText: "guard let value else { return }")
        )

        let items = store.contextItems()

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.id == store.stagedComments.first?.id)
        #expect(item.source == .file)
        #expect(item.path == "Sources/App.swift")
        #expect(item.startLine == 12)
        #expect(item.quote == "guard let value else { return }")
        #expect(item.note == "Check the nil path.")
    }

    @Test func aSelectionPastTheServerLimitIsTrimmedVisiblyWhenStaged() throws {
        let defaults = try makeDefaults()
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "test.reviewComments")
        let selection = String(repeating: "let value = 10 // é\n", count: 620)
        #expect(selection.count == 12_400)
        _ = try store.create(
            workspaceId: "workspace-1",
            sessionId: "session-1",
            body: "Too long?",
            reference: reference(path: "Sources/App.swift", selectedText: selection)
        )

        let quote = try #require(store.contextItems().first?.quote)
        #expect(quote.utf16.count <= PromptContextItem.maxTextLength)
        #expect(quote.hasSuffix("\n… trimmed, 12,400 characters"))
        #expect(selection.hasPrefix(String(quote.dropLast("\n… trimmed, 12,400 characters".count))))
        // A selection that fits is kept whole.
        #expect(PromptContextItem.capturedQuote("short") == "short")
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

    @Test func unreadableStoredDraftsLoadEmptyAndReportAnError() throws {
        let defaults = try makeDefaults()
        let prefix = "test.reviewComments"
        defaults.set(
            Data("not-json".utf8),
            forKey: ReviewCommentStore.makeStorageKey(prefix: prefix, workspaceId: "workspace-1", sessionId: "session-1")
        )
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: prefix)

        store.load(workspaceId: "workspace-1", sessionId: "session-1")

        #expect(store.stagedComments.isEmpty)
        #expect(store.lastError?.contains("could not be read") == true)
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
