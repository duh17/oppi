import Foundation
import Testing
@testable import Oppi

/// Tests for fork helper logic in ServerConnection+Fork.
///
/// Exercises the pure functions (resolveForkEntryId, normalizeTraceDerivedEntryId)
/// without needing a live ServerConnection or WebSocket.
@Suite("Fork Helpers")
@MainActor
struct ForkHelperTests {

    // MARK: - normalizeTraceDerivedEntryId

    @Test func normalizeStripsTextSuffix() {
        let id = "abc123-text-0"
        let result = ServerConnection.normalizeTraceDerivedEntryId(id)
        #expect(result == "abc123")
    }

    @Test func normalizeStripsThinkSuffix() {
        let id = "entry-456-think-2"
        let result = ServerConnection.normalizeTraceDerivedEntryId(id)
        #expect(result == "entry-456")
    }

    @Test func normalizeStripsToolSuffix() {
        let id = "msg-789-tool-0"
        let result = ServerConnection.normalizeTraceDerivedEntryId(id)
        #expect(result == "msg-789")
    }

    @Test func normalizeReturnsOriginalWhenNoSyntheticSuffix() {
        let id = "plain-entry-id"
        let result = ServerConnection.normalizeTraceDerivedEntryId(id)
        #expect(result == "plain-entry-id")
    }

    @Test func normalizeHandlesMultipleMarkers() {
        // The function iterates markers in fixed order (-text-, -think-, -tool-).
        // When the entry ID itself contains a marker substring (e.g. "-text-"),
        // the first-matching marker wins. In practice entry IDs are UUIDs so
        // this doesn't occur, but the behavior is defined: first marker match
        // takes precedence.
        let id = "entry-text-prefix-tool-0"
        let result = ServerConnection.normalizeTraceDerivedEntryId(id)
        #expect(result == "entry")
    }

    @Test func normalizeHandlesEmptyPrefix() {
        // "-text-0" has empty prefix — should not strip (returns original)
        let id = "-text-0"
        let result = ServerConnection.normalizeTraceDerivedEntryId(id)
        // The prefix before "-text-" is empty, so it returns the original ID.
        #expect(result == "-text-0")
    }

    @Test func normalizeDoesNotStripPartialMarkers() {
        // "entry-tex-0" doesn't contain "-text-", just "-tex-" which isn't a marker
        let id = "entry-tex-0"
        let result = ServerConnection.normalizeTraceDerivedEntryId(id)
        #expect(result == "entry-tex-0")
    }

    @Test func normalizePreservesLongEntryIds() {
        let id = "550e8400-e29b-41d4-a716-446655440000-text-3"
        let result = ServerConnection.normalizeTraceDerivedEntryId(id)
        #expect(result == "550e8400-e29b-41d4-a716-446655440000")
    }

    // MARK: - resolveForkEntryId

    @Test func resolveExactMatch() {
        let messages = [
            ForkMessage(entryId: "entry-1", text: "Hello"),
            ForkMessage(entryId: "entry-2", text: "World"),
        ]
        let result = ServerConnection.resolveForkEntryId("entry-2", from: messages)
        #expect(result == "entry-2")
    }

    @Test func resolveNormalizedMatch() {
        // Requested ID has a synthetic suffix; after normalization it matches
        let messages = [
            ForkMessage(entryId: "entry-1", text: "Hello"),
            ForkMessage(entryId: "entry-2", text: "World"),
        ]
        let result = ServerConnection.resolveForkEntryId("entry-2-text-0", from: messages)
        #expect(result == "entry-2")
    }

    @Test func resolveReturnsNilForUnknownEntry() {
        let messages = [
            ForkMessage(entryId: "entry-1", text: "Hello"),
        ]
        let result = ServerConnection.resolveForkEntryId("entry-99", from: messages)
        #expect(result == nil)
    }

    @Test func resolveReturnsNilForEmptyMessages() {
        let result = ServerConnection.resolveForkEntryId("entry-1", from: [])
        #expect(result == nil)
    }

    @Test func resolvePreferExactOverNormalized() {
        // If both the exact and normalized form exist, exact match wins
        let messages = [
            ForkMessage(entryId: "entry-1-text-0", text: "Exact"),
            ForkMessage(entryId: "entry-1", text: "Normalized"),
        ]
        // Requesting "entry-1-text-0" should match exactly first
        let result = ServerConnection.resolveForkEntryId("entry-1-text-0", from: messages)
        #expect(result == "entry-1-text-0")
    }

    @Test func resolveNormalizedDoesNotMatchWhenOriginalUnchanged() {
        // If normalizeTraceDerivedEntryId returns the same string (no suffix stripped),
        // and it's not in the list, result should be nil
        let messages = [
            ForkMessage(entryId: "entry-1", text: "Hello"),
        ]
        let result = ServerConnection.resolveForkEntryId("entry-2", from: messages)
        #expect(result == nil)
    }

    // MARK: - ForkRequestError descriptions

    @Test func forkRequestErrorDescriptionsAreNonEmpty() {
        let errors: [ForkRequestError] = [.turnInProgress, .noForkableMessages, .entryNotForkable]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty) // swiftlint:disable:this force_unwrapping
        }
    }

    @Test func forkRequestErrorEquality() {
        #expect(ForkRequestError.turnInProgress == ForkRequestError.turnInProgress)
        #expect(ForkRequestError.turnInProgress != ForkRequestError.noForkableMessages)
    }
}
