import Foundation

// MARK: - Fork Operations

extension ServerConnection {
    /// Fork from a canonical session entry ID (mirrors pi CLI behavior).
    ///
    /// Flow:
    /// 1. `get_fork_messages` to resolve valid fork entry IDs
    /// 2. Verify requested entry is in that server-authored list
    /// 3. `fork(entryId)` with correlated requestId
    func forkFromTimelineEntry(_ entryId: String) async throws {
        guard UUID(uuidString: entryId) == nil else {
            throw ForkRequestError.turnInProgress
        }

        let forkMessages = try await getForkMessages()
        guard !forkMessages.isEmpty else {
            throw ForkRequestError.noForkableMessages
        }

        guard let resolvedEntryId = Self.resolveForkEntryId(entryId, from: forkMessages) else {
            throw ForkRequestError.entryNotForkable
        }

        _ = try await sendRPCCommandAwaitingResult(command: "fork") { requestId in
            .fork(entryId: resolvedEntryId, requestId: requestId)
        }
    }

    /// Create a new forked app session from a timeline entry.
    ///
    /// Unlike raw pi `fork`, this keeps the current app session untouched and
    /// materializes the branch as a new session row in the workspace.
    func forkIntoNewSessionFromTimelineEntry(
        _ entryId: String,
        sourceSessionId: String,
        workspaceId: String
    ) async throws -> Session {
        guard let apiClient else {
            throw RPCRequestError.rejected(command: "fork", reason: "API client unavailable")
        }

        guard UUID(uuidString: entryId) == nil else {
            throw ForkRequestError.turnInProgress
        }

        let forkMessages = try await getForkMessages()
        guard !forkMessages.isEmpty else {
            throw ForkRequestError.noForkableMessages
        }

        guard let resolvedEntryId = Self.resolveForkEntryId(entryId, from: forkMessages) else {
            throw ForkRequestError.entryNotForkable
        }

        let sourceName = sessionStore.sessions
            .first(where: { $0.id == sourceSessionId })?
            .name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "Session \(sourceSessionId.prefix(8))"
        let baseName = (sourceName?.isEmpty == false ? sourceName! : fallbackName)
        let forkName = "Fork: \(baseName)"

        let forkedSession = try await apiClient.forkWorkspaceSession(
            workspaceId: workspaceId,
            sessionId: sourceSessionId,
            entryId: resolvedEntryId,
            name: forkName
        )

        sessionStore.upsert(forkedSession)

        if let refreshed = try? await apiClient.listWorkspaceSessions(workspaceId: workspaceId) {
            for session in refreshed {
                sessionStore.upsert(session)
            }
        }

        return forkedSession
    }

    // MARK: - Fork Helpers

    static func resolveForkEntryId(_ requestedEntryId: String, from messages: [ForkMessage]) -> String? {
        if messages.contains(where: { $0.entryId == requestedEntryId }) {
            return requestedEntryId
        }

        let normalized = normalizeTraceDerivedEntryId(requestedEntryId)
        guard normalized != requestedEntryId else {
            return nil
        }

        if messages.contains(where: { $0.entryId == normalized }) {
            return normalized
        }

        return nil
    }

    /// Trace assistant rows may use synthetic IDs (`<entry>-text-0`,
    /// `<entry>-think-0`, `<entry>-tool-0`). Normalize those back to the
    /// canonical session entry ID before validating against `get_fork_messages`.
    static func normalizeTraceDerivedEntryId(_ id: String) -> String {
        for marker in ["-text-", "-think-", "-tool-"] {
            if let range = id.range(of: marker, options: .backwards) {
                let prefix = id[..<range.lowerBound]
                if !prefix.isEmpty {
                    return String(prefix)
                }
            }
        }

        return id
    }
}
