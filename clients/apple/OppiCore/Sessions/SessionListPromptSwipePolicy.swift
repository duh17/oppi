import Foundation

enum SessionListPromptSwipePolicy {
    enum LeadingAction: Equatable, Sendable {
        case prompt
        case none
    }

    /// Leading (swipe-right) action for session-list rows.
    ///
    /// Prompt is only offered on live rows that belong to a workspace, because
    /// templates load from GET `/workspaces/{id}/quick-actions`. Stopped rows
    /// keep their existing Resume action and do not gain Prompt. Rows without a
    /// workspace cannot load templates, so they get no leading action.
    static func leadingAction(
        status: SessionStatus,
        workspaceId: String?
    ) -> LeadingAction {
        let trimmed = workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, status != .stopped else { return .none }
        return .prompt
    }

    /// HTTP command body for a picked prompt template.
    ///
    /// Always `prompt` + `streamingBehavior: steer`. The server admits this as a
    /// prompt when idle and as a steer when busy (`sendPromptAdmitted`). Do not
    /// pick prompt vs steer vs follow-up from the list row's status; that
    /// projection races the live runtime.
    static func sendMessage(commandName: String) -> ClientMessage {
        .prompt(message: "/\(commandName)", streamingBehavior: .steer)
    }
}

/// Sheet dismiss cancels `.task { await loadTemplates() }`. That is control
/// flow, not a user-facing load failure.
enum SessionListPromptTemplateLoadErrorPolicy {
    static func shouldPresent(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return false
        }

        return true
    }
}
