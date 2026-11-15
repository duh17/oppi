import UIKit

// MARK: - Export Loading Token

/// Abstract token that the presenter uses to show/hide a loading spinner
/// during export rendering. The concrete implementation handles UIKit bar buttons.
@MainActor
protocol ExportLoadingToken: AnyObject {
    func start()
    func stop()
}

// MARK: - Weak ref helper

/// Type-erased weak reference box. Used to break retain cycles when passing
/// a bar button reference into a UIMenu/UIAction closure.
@MainActor
final class Weak<T: AnyObject> {
    weak var value: T?
    init(_ value: T? = nil) { self.value = value }
}

// MARK: - BarButtonLoadingToken

/// Swaps a UIBarButtonItem's image for a spinning UIActivityIndicatorView
/// while an export renders, then restores the original image.
@MainActor
final class BarButtonLoadingToken: ExportLoadingToken {
    private weak var button: UIBarButtonItem?
    private let tintColor: UIColor?
    private var savedImage: UIImage?
    private var savedIsEnabled: Bool = true

    init(button: UIBarButtonItem, tintColor: UIColor?) {
        self.button = button
        self.tintColor = tintColor
    }

    func start() {
        guard let button else { return }
        savedImage = button.image
        savedIsEnabled = button.isEnabled

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = tintColor ?? button.tintColor
        spinner.startAnimating()

        button.image = nil
        button.customView = spinner
        button.isEnabled = false
    }

    func stop() {
        guard let button else { return }
        button.customView = nil
        button.image = savedImage
        button.isEnabled = savedIsEnabled
    }
}

// MARK: - FileSharePresenter

/// Single entry point for all share/export interactions.
///
/// Owns the full share flow: format selection → render → activity controller.
/// UIKit callers use ``makeShareBarButtonItem(for:tintColor:)`` to get a
/// fully-wired button; the render + present logic lives here.
@MainActor
enum FileSharePresenter {

    // MARK: - Render + Present

    /// Share content using the smart default format, from `screen`'s window.
    static func shareDefault(
        _ content: FileShareService.ShareableContent,
        from screen: UIViewController,
        loadingToken: ExportLoadingToken? = nil,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)? = nil
    ) async {
        let format = FileShareService.defaultFormat(for: content)
        await share(content, format: format, from: screen, loadingToken: loadingToken, sourceItem: sourceItem)
    }

    /// Share content in a specific format, from `screen`'s window.
    static func share(
        _ content: FileShareService.ShareableContent,
        format: FileShareService.ExportFormat,
        from screen: UIViewController,
        loadingToken: ExportLoadingToken? = nil,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)? = nil
    ) async {
        loadingToken?.start()
        let item = await FileShareService.render(content, as: format)
        loadingToken?.stop()
        presentActivityController(item: item, from: screen, sourceItem: sourceItem)
    }

    /// Share an existing URL from UIKit interaction menus, from the window
    /// `sourceView` is in; nothing once it has left its window.
    static func share(_ url: URL, sourceView: UIView?) {
        guard let sourceView, let screen = Router.presenter(near: sourceView) else { return }
        presentActivityController(item: .file(url), from: screen, sourceItem: sourceView)
    }

    // MARK: - Files on the server

    /// One download at a time: a second Share while one is being prepared does nothing.
    private static var isPreparingRemoteFile = false

    /// How long a download may run before its progress shows. A small file
    /// goes straight to the share sheet.
    private static let progressDelay = Duration.milliseconds(350)

    /// Downloads `file` to a temporary file, then presents the share sheet
    /// with it, anchored to `sourceItem` (`download(_:to:from:)`). The
    /// temporary file goes when the sheet closes, or at once when there is
    /// no sheet.
    static func share(
        _ file: RemoteFileShare,
        from screen: UIViewController,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)?
    ) async {
        let destination = FileShareService.temporaryFileURL(named: file.fileName)
        guard await download(file, to: destination, from: screen) else { return }
        presentActivityController(item: .file(destination), from: screen, sourceItem: sourceItem)
    }

    /// Downloads `file` to `destination` on disk, never into memory, and says
    /// whether it is there. A download that takes a moment shows its progress
    /// with Cancel over `screen`'s window, and "Reconnecting" while a dropped
    /// connection waits to resume. A file this device has no room for
    /// (`FileDownloadBudget`) says so in an alert, as does any other failure,
    /// in its own words (`FileDownloadFailure`); a cancel says nothing. On
    /// failure `destination`'s folder is removed.
    static func download(_ file: RemoteFileShare, to destination: URL, from screen: UIViewController) async -> Bool {
        guard !isPreparingRemoteFile, screen.viewIfLoaded?.window != nil else { return false }
        let presenter = Router.topPresenter(from: screen)
        if let refusal = FileDownloadBudget.refusal(
            byteCount: file.expectedBytes,
            availableBytes: FileDownloadBudget.availableBytes()
        ) {
            presenter.errorAlerts.show(title: refusal.title, message: refusal.message(fileName: file.fileName))
            return false
        }
        isPreparingRemoteFile = true
        // A size the listing gave was checked above.
        let transfer = RemoteFileTransfer(checkedSize: file.expectedBytes != nil)
        transfer.beginBackgroundTime()
        defer {
            isPreparingRemoteFile = false
            transfer.endBackgroundTime()
        }

        let expectedBytes = file.expectedBytes
        let overlay = FileShareProgressOverlay(
            fileName: file.fileName,
            progress: FileDownloadProgress(received: 0, expected: expectedBytes),
            palette: ThemeRuntimeState.currentPalette()
        )
        // This function holds the overlay until the download ends anyway.
        let download = Task { [overlay, transfer] in
            try await file.download(destination) { progress in
                Task { @MainActor [weak overlay] in
                    let progress = FileDownloadProgress(
                        received: progress.received,
                        expected: progress.expected ?? expectedBytes,
                        reconnecting: progress.reconnecting
                    )
                    overlay?.update(progress)
                    transfer.check(progress)
                }
            }
        }
        transfer.task = download
        overlay.onCancel = { download.cancel() }
        let showProgress = Task {
            // The download can end between the sleep and this turn of the main actor.
            guard (try? await Task.sleep(for: progressDelay)) != nil, !Task.isCancelled else { return }
            overlay.show(over: presenter.view)
        }

        let result = await download.result
        showProgress.cancel()
        overlay.removeFromSuperview()

        switch result {
        case .success:
            return true
        case .failure(let error):
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            if let refusedMidway = transfer.refusal {
                presenter.errorAlerts.show(title: refusedMidway.title, message: refusedMidway.message(fileName: file.fileName))
            } else if let failure = FileDownloadFailure(error) {
                presenter.errorAlerts.show(title: failure.title, message: failure.message(fileName: file.fileName))
            }
            return false
        }
    }

    /// One download in flight: a size the listing did not know is checked
    /// against the free space (`FileDownloadBudget`) once the response
    /// states it, and the download stops there.
    @MainActor
    private final class RemoteFileTransfer {
        var task: Task<Void, Error>?
        private(set) var refusal: FileDownloadBudget.Refusal?
        private var backgroundTask = UIBackgroundTaskIdentifier.invalid
        private var checkedSize: Bool

        init(checkedSize: Bool) {
            self.checkedSize = checkedSize
        }

        /// Leaving the app keeps the download going for the time iOS grants;
        /// after that the download resumes from where it stopped when the app
        /// comes back (`ResumableFileDownload`).
        func beginBackgroundTime() {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "File download") { [weak self] in
                MainActor.assumeIsolated { self?.endBackgroundTime() }
            }
        }

        func endBackgroundTime() {
            guard backgroundTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }

        func check(_ progress: FileDownloadProgress) {
            guard !checkedSize, let expected = progress.expected else { return }
            checkedSize = true
            // What arrived so far already took its space from the free space.
            guard let available = FileDownloadBudget.availableBytes(),
                  let refusal = FileDownloadBudget.refusal(
                      byteCount: expected,
                      availableBytes: available + progress.received
                  ) else { return }
            self.refusal = refusal
            task?.cancel()
        }
    }

    // MARK: - UIKit Bar Button Factory

    static let shareTitle = String(localized: "Share")
    static let shareImage = UIImage(systemName: "square.and.arrow.up")

    /// The Share item for a file: the share sheet for its bytes when they are
    /// in hand, else a download and then the share sheet. `screen` is the
    /// screen whose bar holds the item: the share sheet opens in its window.
    static func makeShareBarButtonItem(for file: ShareableFile, from screen: UIViewController) -> UIBarButtonItem {
        switch file {
        case .loaded(let content):
            return makeShareBarButtonItem(for: content, from: screen)
        case .remote(let remote):
            let box = Weak<UIBarButtonItem>()
            let button = UIBarButtonItem(
                title: shareTitle,
                image: shareImage,
                primaryAction: UIAction(title: shareTitle, image: shareImage) { [weak screen] action in
                    guard let screen else { return }
                    let anchor = shareAnchor(sender: action.sender, item: box.value)
                    Task { @MainActor in await share(remote, from: screen, sourceItem: anchor) }
                }
            )
            box.value = button
            return button
        }
    }

    /// A titled Share item whose tap presents the share sheet in the content's
    /// default format (`FileShareService.defaultFormat`). Content with more
    /// than one format keeps the choice as "Share As": the button's long-press
    /// menu, and a row after Share when the item sits in a "…" menu
    /// (`menuRepresentation`), so a crowded-out or turned-off Share still
    /// reads "Share", runs at once, and offers every format. The button shows
    /// a spinner while an export renders.
    static func makeShareBarButtonItem(
        for content: FileShareService.ShareableContent,
        from screen: UIViewController,
        tintColor: UIColor? = nil
    ) -> UIBarButtonItem {
        let box = Weak<UIBarButtonItem>()
        let run: @MainActor (FileShareService.ExportFormat, Any?) -> Void = { [weak screen] format, sender in
            guard let screen else { return }
            let button = box.value
            let token = button.map { BarButtonLoadingToken(button: $0, tintColor: tintColor) }
            let anchor = shareAnchor(sender: sender, item: button)
            Task { @MainActor in
                await share(content, format: format, from: screen, loadingToken: token, sourceItem: anchor)
            }
        }
        let defaultFormat = FileShareService.defaultFormat(for: content)
        let shareAction = UIAction(title: shareTitle, image: shareImage) { run(defaultFormat, $0.sender) }
        shareAction.accessibilityIdentifier = "share.menu.share"
        let formats = FileShareService.availableFormats(for: content)
        let formatMenu: UIMenu? = formats.count > 1 ? UIMenu(
            title: String(localized: "Share As"),
            image: UIImage(systemName: "square.and.arrow.up.on.square"),
            children: formats.map { format in
                let info = FileShareService.formatDisplayInfo(format, for: content)
                return UIAction(title: info.label, image: UIImage(systemName: info.icon)) { run(format, $0.sender) }
            }
        ) : nil
        formatMenu?.accessibilityIdentifier = "share.menu.shareAs"

        let button = UIBarButtonItem(title: shareTitle, image: shareImage, primaryAction: shareAction, menu: formatMenu)
        box.value = button
        if let formatMenu {
            button.menuRepresentation = UIMenu(options: .displayInline, children: [shareAction, formatMenu])
        }
        button.tintColor = tintColor
        return button
    }

    /// What the share sheet's iPad popover points at: the control that was
    /// tapped (a "…" menu reports its button), else the bar item, which
    /// `presentActivityController` skips when the bar is not showing it.
    private static func shareAnchor(sender: Any?, item: UIBarButtonItem?) -> (any UIPopoverPresentationControllerSourceItem)? {
        (sender as? any UIPopoverPresentationControllerSourceItem) ?? item
    }

    // MARK: - Activity Controller Presentation

    /// Present UIActivityViewController over `screen`, from the top of its
    /// window; nothing when `screen` has left the window.
    ///
    /// The iPad popover points at `sourceItem` (the row or the bar button).
    /// Cleans up temp files on completion.
    static func presentActivityController(
        item: FileShareService.ShareItem,
        from screen: UIViewController,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)? = nil
    ) {
        present(item.activityItems, from: screen, sourceItem: sourceItem)
    }

    /// Share a web page's address, from `screen`'s window. The sheet gets the
    /// URL itself, not a file, so it offers what a link offers (Messages,
    /// Copy, Reading List).
    static func share(link url: URL, from screen: UIViewController, sourceItem: (any UIPopoverPresentationControllerSourceItem)?) {
        present([url], from: screen, sourceItem: sourceItem)
    }

    private static func present(
        _ activityItems: [Any],
        from screen: UIViewController,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)?
    ) {
        guard screen.viewIfLoaded?.window != nil else { return }
        let topVC = Router.topPresenter(from: screen)

        let ac = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
        ac.completionWithItemsHandler = { _, _, _, _ in
            FileShareService.cleanupTempFiles()
        }
        if let popover = ac.popoverPresentationController {
            // A row that scrolled away during its download, or a bar item
            // the bar crowded into its "…", is no anchor.
            if let sourceItem, Self.isOnScreen(sourceItem, in: topVC.view) {
                popover.sourceItem = sourceItem
            } else {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(
                    x: topVC.view.bounds.midX,
                    y: 44,
                    width: 0,
                    height: 0
                )
            }
        }
        topVC.present(ac, animated: true)
    }

    private static func isOnScreen(_ item: any UIPopoverPresentationControllerSourceItem, in view: UIView) -> Bool {
        if let anchor = item as? UIView { return anchor.window != nil }
        // Nil for a bar item the bar is not drawing.
        guard let frame = item.frame(in: view) else { return false }
        return !frame.isNull && !frame.isEmpty
    }
}

// MARK: - Download failures

/// Why a file download from the server failed, in words the person can act
/// on: the file is gone, the server refuses it, the device is offline, or the
/// server cannot be reached. Nil for a cancel, which needs no words.
struct FileDownloadFailure: Equatable {
    enum Kind: Equatable {
        case notFound
        /// The path leaves what the server shares, or the server refuses it.
        case refused(reason: String?)
        case tooLarge(reason: String?)
        case notSignedIn
        case offline
        case serverUnreachable
        case outOfSpace
        case changedInTransfer
        case serverError(status: Int, reason: String?)
        case other
    }

    let kind: Kind

    init?(_ error: Error) {
        if error is CancellationError { return nil }
        switch error {
        case FileDownloadError.digestMismatch:
            kind = .changedInTransfer
        case FileDownloadError.rejected(let status, let message):
            switch status {
            case 401: kind = .notSignedIn
            case 403: kind = .refused(reason: message)
            case 404, 410: kind = .notFound
            case 413: kind = .tooLarge(reason: message)
            default: kind = .serverError(status: status, reason: message)
            }
        case let error as URLError:
            switch error.code {
            case .cancelled: return nil
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                kind = .offline
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
                 .networkConnectionLost, .resourceUnavailable, .backgroundSessionWasDisconnected:
                kind = .serverUnreachable
            case .userAuthenticationRequired:
                kind = .notSignedIn
            default:
                kind = .other
            }
        case let error as CocoaError where error.code == .fileWriteOutOfSpace:
            kind = .outOfSpace
        default:
            kind = .other
        }
    }

    var title: String {
        switch kind {
        case .notFound: String(localized: "File Not Found")
        case .refused: String(localized: "Can't Download This File")
        case .tooLarge: String(localized: "File Too Large")
        case .notSignedIn: String(localized: "Not Signed In")
        case .offline: String(localized: "You're Offline")
        case .serverUnreachable: String(localized: "Server Unreachable")
        case .outOfSpace: String(localized: "Not Enough Storage")
        case .changedInTransfer, .serverError, .other: String(localized: "Download Failed")
        }
    }

    func message(fileName: String) -> String {
        switch kind {
        case .notFound:
            return String(localized: "“\(fileName)” is no longer on the server. It may have been moved or deleted.")
        case .refused(let reason):
            let reason = reason ?? String(localized: "it is outside the folders it shares")
            return String(localized: "The server won't send “\(fileName)”: \(reason).")
        case .tooLarge(let reason):
            let reason = reason ?? String(localized: "it is over the size limit for this kind of file")
            return String(localized: "The server won't send “\(fileName)”: \(reason).")
        case .notSignedIn:
            return String(localized: "The server did not accept this device's sign-in. Reconnect to the server, then try again.")
        case .offline:
            return String(localized: "“\(fileName)” stopped downloading because this device is offline. Try again once it's back online.")
        case .serverUnreachable:
            return String(localized: "Oppi lost the server while downloading “\(fileName)” and could not reach it again. Check that the server is running and reachable, then try again.")
        case .outOfSpace:
            return String(localized: "This device ran out of space while downloading “\(fileName)”. Nothing was saved.")
        case .changedInTransfer:
            return String(localized: "“\(fileName)” did not match the server's copy: it changed or was damaged on the way. Nothing was saved.")
        case .serverError(let status, let reason):
            let reason = reason ?? HTTPURLResponse.localizedString(forStatusCode: status)
            return String(localized: "The server could not send “\(fileName)”: \(reason).")
        case .other:
            return String(localized: "“\(fileName)” could not be downloaded. Please try again.")
        }
    }
}
