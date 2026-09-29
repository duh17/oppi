import Foundation

/// Tool-output transport for one session, bound at construction.
///
/// `SessionContentAccess.toolOutputAccess(sessionId:routeScope:)` builds it from the
/// connection's current API client and the source's route scope, so timeline code never
/// touches a client or scope. It exists only when both were available at that moment;
/// otherwise the timeline has no fetch, sidecar, or copy capability, and no readiness
/// wait is started. Session identity is fixed here. The tool call is named per operation.
///
/// This value only builds requests. *When* to fetch, retry, cancel, or discard a stale
/// result stays with `ExpandedToolOutputLoader`; stored output stays in `ToolOutputStore`.
struct SessionToolOutputAccess: Sendable {
    let sessionId: String
    private let apiClient: APIClient
    private let scope: SessionRouteScope

    init(apiClient: APIClient, scope: SessionRouteScope, sessionId: String) {
        self.apiClient = apiClient
        self.scope = scope
        self.sessionId = sessionId
    }

    /// Expansion fetch: a shell tool's first sidecar window (preview-only when large),
    /// or the non-empty stored output for other tools.
    func fetchForExpand(tool: String, toolCallId: String) async throws -> ExpandedToolOutputFetch.Result {
        try await ExpandedToolOutputFetch.fetchForExpand(
            tool: tool,
            apiClient: apiClient,
            scope: scope,
            sessionId: sessionId,
            toolCallId: toolCallId
        )
    }

    /// Windowed reads of the full sidecar, used by the full-screen terminal reader.
    func sidecarSource(toolCallId: String) -> ToolOutputSidecarWindowSource {
        ToolOutputSidecarWindowSource(
            loadFirst: { [apiClient, scope, sessionId] in
                try await apiClient.openFullToolOutputSidecar(
                    scope: scope,
                    sessionId: sessionId,
                    toolCallId: toolCallId
                )
            },
            loadNext: { [apiClient, scope, sessionId] startByte in
                try await apiClient.getFullToolOutputSidecarWindow(
                    scope: scope,
                    sessionId: sessionId,
                    toolCallId: toolCallId,
                    startByte: startByte
                )
            }
        )
    }

    /// Complete-output fetch for copy. Only shell-sidecar tools have one (`nil` otherwise).
    /// A complete output already held by `store` wins; a stored preview does not, so copy
    /// never yields a truncated clipboard.
    @MainActor
    func completeOutputFetch(
        tool: String,
        toolCallId: String,
        store: ToolOutputStore?
    ) -> (() async throws -> String?)? {
        guard ExpandedToolOutputFetch.isShellSidecarTool(tool) else { return nil }
        return { [apiClient, scope, sessionId] in
            if let store, store.hasCompleteOutput(for: toolCallId) {
                let text = store.fullOutput(for: toolCallId)
                return text.isEmpty ? nil : text
            }
            return try await ExpandedToolOutputFetch.fetchForCopy(
                apiClient: apiClient,
                scope: scope,
                sessionId: sessionId,
                toolCallId: toolCallId
            )
        }
    }
}
