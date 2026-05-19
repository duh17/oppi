import Testing
import Foundation
@testable import Oppi

/// Regression tests for ChatView session reuse.
///
/// When SwiftUI reuses a ChatView at the same structural position (e.g.
/// deep-link navigation replaces one session ID with another), @State is
/// preserved. ChatView must detect the sessionId mismatch via
/// `onChange(of: sessionId)` and recreate its ChatSessionManager —
/// otherwise the header shows the new session but the timeline shows
/// stale content from the old session.
///
/// These tests verify the underlying invariants:
/// 1. ChatSessionManager binds to exactly one session ID
/// 2. Two managers for different sessions are fully independent
/// 3. Cleanup tears down cleanly, enabling safe replacement
@Suite("ChatView Session Reuse")
@MainActor
struct ChatViewSessionReuseTests {

    // MARK: - Manager identity

    @Test func managerSessionIdMatchesInit() {
        let manager = ChatSessionManager(sessionId: "session-A")
        #expect(manager.sessionId == "session-A")
    }

    @Test func twoManagersAreIndependent() {
        let managerA = ChatSessionManager(sessionId: "session-A")
        let managerB = ChatSessionManager(sessionId: "session-B")

        #expect(managerA.sessionId != managerB.sessionId)

        // Both start with clean state
        #expect(managerA.entryState == .idle)
        #expect(managerB.entryState == .idle)
        #expect(managerA.reducer.items.isEmpty)
        #expect(managerB.reducer.items.isEmpty)
        #expect(managerA.connectionGeneration == 0)
        #expect(managerB.connectionGeneration == 0)
    }

    // MARK: - Cleanup for safe replacement

    @Test func cleanupTransitionsToDisconnected() {
        let manager = ChatSessionManager(sessionId: "session-A")
        #expect(manager.entryState == .idle)

        manager.cleanup()

        if case .disconnected(reason: .cancelled) = manager.entryState {
            // Expected — old manager is torn down
        } else {
            Issue.record("Expected .disconnected(.cancelled) after cleanup, got \(manager.entryState)")
        }
    }

    // MARK: - Simulated reuse scenario

    /// Simulates the onChange(of: sessionId) flow that fires when SwiftUI
    /// reuses ChatView at the same navigation position.
    ///
    /// Steps match ChatView.onChange(of: sessionId):
    /// 1. Detect mismatch (manager.sessionId != newSessionId)
    /// 2. Cleanup old manager
    /// 3. Create new manager
    @Test func simulatedViewReuseCreatesNewManager() {
        // Phase 1: "View appears" with session A
        var sessionManager = ChatSessionManager(sessionId: "session-A")
        #expect(sessionManager.sessionId == "session-A")

        // Phase 2: SwiftUI reuses view with session B
        let newSessionId = "session-B"

        // Step 1: Detect mismatch (the guard in onChange)
        #expect(sessionManager.sessionId != newSessionId,
                "Mismatch must be detected for reuse to trigger")

        // Step 2: Tear down old
        sessionManager.cleanup()
        if case .disconnected = sessionManager.entryState {} else {
            Issue.record("Old manager should be disconnected after cleanup")
        }

        // Step 3: Replace with new
        sessionManager = ChatSessionManager(sessionId: newSessionId)
        #expect(sessionManager.sessionId == "session-B")
        #expect(sessionManager.entryState == .idle,
                "New manager should start fresh in .idle state")
        #expect(sessionManager.reducer.items.isEmpty,
                "New manager should have empty timeline")
    }

    // MARK: - Connection task key

    /// The connection task must restart when the session changes.
    /// This requires the task key to include sessionId, not just
    /// connectionGeneration (which starts at 0 for all managers).
    @Test func connectionTaskKeyDiffersAcrossSessions() {
        let keyA = ConnectionTaskKey(sessionId: "session-A", generation: 0)
        let keyB = ConnectionTaskKey(sessionId: "session-B", generation: 0)
        #expect(keyA != keyB,
                "Different sessions at same generation must produce different task keys")
    }

    @Test func connectionTaskKeySameForIdenticalState() {
        let key1 = ConnectionTaskKey(sessionId: "session-A", generation: 0)
        let key2 = ConnectionTaskKey(sessionId: "session-A", generation: 0)
        #expect(key1 == key2,
                "Same session + generation = no unnecessary task restart")
    }

    @Test func connectionTaskKeyChangesOnReconnect() {
        let key1 = ConnectionTaskKey(sessionId: "session-A", generation: 0)
        let key2 = ConnectionTaskKey(sessionId: "session-A", generation: 1)
        #expect(key1 != key2,
                "Bumped generation must trigger reconnect")
    }

    // MARK: - Review comment load key

    /// Review comments are fetched with both workspaceId and sessionId.
    /// If ChatView is reused for another session in the same workspace,
    /// the load task must restart; otherwise staged comments from session A
    /// can remain visible in session B.
    @Test func reviewCommentLoadKeyDiffersAcrossSessionsInSameWorkspace() {
        let keyA = ReviewCommentLoadKey(workspaceId: "workspace-1", sessionId: "session-A")
        let keyB = ReviewCommentLoadKey(workspaceId: "workspace-1", sessionId: "session-B")
        #expect(keyA != keyB,
                "Different sessions in the same workspace must reload session-scoped review comments")
    }

    @Test func reviewCommentLoadKeySameForIdenticalScope() {
        let key1 = ReviewCommentLoadKey(workspaceId: "workspace-1", sessionId: "session-A")
        let key2 = ReviewCommentLoadKey(workspaceId: "workspace-1", sessionId: "session-A")
        #expect(key1 == key2,
                "Same workspace + session should not reload review comments unnecessarily")
    }

    // MARK: - Shared state isolation

    /// Verifies that replacing the manager does NOT affect the old one.
    /// (Catches accidental shared state via singletons or statics.)
    @Test func replacementDoesNotCorruptOldManager() {
        let oldManager = ChatSessionManager(sessionId: "session-A")
        oldManager.cleanup()

        let newManager = ChatSessionManager(sessionId: "session-B")

        // Old manager stays disconnected (not affected by new)
        if case .disconnected = oldManager.entryState {} else {
            Issue.record("Old manager state should not change after new manager creation")
        }

        // New manager is independent
        #expect(newManager.entryState == .idle)
        #expect(newManager.sessionId == "session-B")
    }
}
