import Foundation

/// Client-side floor for a paired Oppi server.
///
/// Build 55 requires `oppi-server` 0.52.0: catch-up decodes the `live` field of
/// the session events response, which 0.51.0 omits. Compare against
/// `GET /server/info` `version`. Unparseable versions are treated as unknown, not old.
enum ServerReleaseVersion {
    static let minimumSupported = "0.52.0"

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

/// Update copy. A `source-link` server rebuilds its linked checkout instead of
/// installing from npm, so its copy says rebuild, not update.
enum ServerUpdatePresentation {
    static func availableTitle(_ update: ServerInfo.UpdateInfo) -> String? {
        if update.isSourceLink { return "Source changed since the server started" }
        return update.latestVersion.map { "Update available: \($0)" }
    }

    static func actionTitle(_ update: ServerInfo.UpdateInfo) -> String {
        update.isSourceLink ? "Rebuild & Restart" : "Update"
    }

    static func confirmationTitle(_ update: ServerInfo.UpdateInfo?) -> String {
        if update?.isSourceLink == true { return "Rebuild and restart?" }
        let version = update?.latestVersion ?? update?.targetVersion ?? "the latest version"
        return "Update to \(version)?"
    }

    /// Names the sessions a restart interrupts, so a busy host is a visible cost.
    static func confirmationMessage(busySessionTitles: [String]) -> String {
        guard !busySessionTitles.isEmpty else {
            return "The server will restart and running sessions will be interrupted."
        }
        let shown = busySessionTitles.prefix(3).joined(separator: ", ")
        let more = busySessionTitles.count - 3
        let list = more > 0 ? "\(shown), and \(more) more" : shown
        let noun = busySessionTitles.count == 1 ? "this running session" : "these running sessions"
        return "The server will restart and interrupt \(noun): \(list)."
    }

    static func footer(_ update: ServerInfo.UpdateInfo?) -> String {
        guard let update, update.isAppUpdatable else {
            return "This install cannot be updated from the app. Run the command on the host, then restart the server."
        }
        if update.isSourceLink {
            return "This server runs from a linked source checkout. Rebuilding compiles that checkout and restarts this host. Running sessions are interrupted."
        }
        return "Updating installs a new oppi-server from npm and restarts this host. Running sessions are interrupted."
    }

    static func progressLabel(status: String, restartMode: String, isSourceLink: Bool) -> String {
        if status == "installing" { return isSourceLink ? "Building…" : "Installing…" }
        if status == "restarting" {
            if restartMode == "manual" {
                let done = isSourceLink ? "Build succeeded." : "Install succeeded."
                return "\(done) Restart the Oppi server on the host to use the new version."
            }
            return "Restarting…"
        }
        return "Updating…"
    }

    static let minimumVersionNoticeTitle = "This server is older than this app"

    /// Why the update button cannot clear the notice: the version the server
    /// can move to (npm's newest, or a linked checkout's) is still below the
    /// app's floor, or there is none. Nil when that version meets the floor.
    static func minimumVersionUnpublishedDetail(
        latestVersion: String?,
        isSourceLink: Bool = false,
        minimum: String = ServerReleaseVersion.minimumSupported
    ) -> String? {
        let needs = "This app needs oppi-server \(minimum) or later."
        guard let latestVersion else {
            return isSourceLink
                ? "\(needs) The server cannot read its checkout's version."
                : "\(needs) The server could not find a newer version on npm."
        }
        guard ServerReleaseVersion.isOlder(latestVersion, than: minimum) else { return nil }
        return isSourceLink
            ? "\(needs) The linked checkout is at \(latestVersion)."
            : "\(needs) The newest on npm is \(latestVersion)."
    }
    static let minimumVersionNoticeMessage = "Open Server Settings to update it, then reconnect."
    static let minimumVersionNoticeAction = "Open Server Settings"

    static let fallbackManualCommand = "npm install -g oppi-server@latest"
}
