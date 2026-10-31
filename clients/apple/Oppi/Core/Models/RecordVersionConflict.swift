import Foundation

/// What a form says when the record it is editing changed on the server first.
///
/// The in-app editor answers the same 409 with its conflict banner and the
/// version it read; a form has nothing to merge, so it says what to do.
enum RecordVersionConflict {
    /// The message for a version conflict, or nil for any other failure (which
    /// the form shows as the server worded it).
    static func message(for error: Error) -> String? {
        guard isVersionConflict(error) else { return nil }
        return String(localized: "Someone else changed this first. Close it and open it again to see the latest version, then make your change.")
    }

    static func isVersionConflict(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        guard case .codedServer(let status, _, let code) = apiError, status == 409 else { return false }
        // A plain 409 is another refusal (an ambiguous name, say): only the
        // server's own conflict code means someone else wrote the record.
        return code == "AGENT_VERSION_CONFLICT" || code == "SCHEDULE_VERSION_CONFLICT"
    }
}
