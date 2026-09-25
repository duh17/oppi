import Foundation

/// Client-side floor for a paired Oppi server.
///
/// Build 52 requires `oppi-server` 0.50.0. Compare against `GET /server/info`
/// `version`. Unparseable versions are treated as unknown, not old.
enum ServerReleaseVersion {
    static let minimumSupported = "0.50.0"

    static func isBelowMinimum(_ version: String?, minimum: String = minimumSupported) -> Bool {
        guard let version else { return false }
        return isOlder(version, than: minimum)
    }

    static func isOlder(_ version: String, than other: String) -> Bool {
        guard let left = parse(version), let right = parse(other) else { return false }
        if left.major != right.major { return left.major < right.major }
        if left.minor != right.minor { return left.minor < right.minor }
        if left.patch != right.patch { return left.patch < right.patch }
        return false
    }

    static func parse(_ raw: String) -> (major: Int, minor: Int, patch: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? trimmed
        let withoutPrerelease = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? core
        let parts = withoutPrerelease.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }
}

enum ServerUpdatePresentation {
    static func availableTitle(latestVersion: String) -> String {
        "Update available: \(latestVersion)"
    }

    static func confirmationTitle(version: String) -> String {
        "Update to \(version)?"
    }

    static let confirmationMessage =
        "The server will restart and running sessions will be interrupted."

    static func progressLabel(status: String, restartMode: String) -> String {
        if status == "installing" { return "Installing…" }
        if status == "restarting" {
            if restartMode == "manual" {
                return "Install succeeded. Restart the Oppi server on the host to use the new version."
            }
            return "Restarting…"
        }
        return "Updating…"
    }

    static let minimumVersionNoticeTitle = "This server is older than this app"
    static let minimumVersionNoticeMessage = "Open Server to update it, then reconnect."
    static let minimumVersionNoticeAction = "Open Server"

    static let fallbackManualCommand = "npm install -g oppi-server@latest"
}
