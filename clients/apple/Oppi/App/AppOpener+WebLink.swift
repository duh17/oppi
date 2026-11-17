import OSLog
import Foundation

private let webLinkLog = Logger(subsystem: AppIdentifiers.subsystem, category: "AppOpener")

/// Where a web link went, for its one `Web link opened` log line
/// (`AppOpener.logWebLink`), so a report of a tap that did nothing names the
/// branch. The line never carries the address.
enum WebLinkBranch: String {
    /// A pane made for the page.
    case newPane = "new-pane"
    /// A web page or New Pane launcher already on screen took it.
    case reuse
    /// A pane in Hidden Panes or behind a zoom took it.
    case reuseHidden = "reuse-hidden"
    /// A pane folded to its strip took it.
    case reuseFolded = "reuse-folded"
    /// Safari's sheet.
    case modal
    /// Safari's sheet, in place of one already in front.
    case modalReplaced = "modal-replaced"
    /// Waiting with the parked request for an invite to finish.
    case heldByInvite = "held-by-invite"
    /// The opener has no window to show it in.
    case noWindow = "no-window"
    /// The system's browser, by the Browser setting.
    case external
}

extension AppOpener {
    /// An http(s) page, by the Browser setting: Oppi's browser (a pane beside
    /// the focused one on a wide window, `presentInAppBrowser`), or the
    /// system's.
    func presentWebLink(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            systemOpen(url)
            return
        }
#if DEBUG
        let mode = _browserLinkPreferenceForTesting ?? AppPreferences.Browser.linkOpeningMode
#else
        let mode = AppPreferences.Browser.linkOpeningMode
#endif
        switch mode {
        case .inApp:
            browserPresent(url, navigation.window)
        case .external:
            Self.logWebLink(.external)
            systemOpen(url)
        }
    }

    /// One line per web link, through the client log the server keeps, so
    /// the branch a tap took can be read from a device. `fields` describe
    /// the panes (`PaneHostController.webLinkLogFields`); never the address.
    static func logWebLink(_ branch: WebLinkBranch, _ fields: [String: String] = [:]) {
        var metadata = fields
        metadata["branch"] = branch.rawValue
        let line = metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        webLinkLog.notice("Web link opened: \(line, privacy: .public)")
        ClientLog.info("Navigation", "Web link opened", metadata: metadata, flush: true)
    }
}
