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
    /// with it, anchored to `sourceItem`. A download that takes a moment
    /// shows its progress with Cancel. A file over the server's size limit
    /// says so. The temporary file goes when the sheet closes, or at once
    /// when there is no sheet.
    static func share(
        _ file: RemoteFileShare,
        from screen: UIViewController,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)?
    ) async {
        guard !isPreparingRemoteFile, screen.viewIfLoaded?.window != nil else { return }
        let presenter = Router.topPresenter(from: screen)
        isPreparingRemoteFile = true
        defer { isPreparingRemoteFile = false }

        let destination = FileShareService.temporaryFileURL(named: file.fileName)
        let expectedBytes = file.expectedBytes
        let overlay = FileShareProgressOverlay(
            fileName: file.fileName,
            progress: FileDownloadProgress(received: 0, expected: expectedBytes),
            palette: ThemeRuntimeState.currentPalette()
        )
        // This function holds the overlay until the download ends anyway.
        let download = Task { [overlay] in
            try await file.download(destination) { progress in
                Task { @MainActor [weak overlay] in
                    overlay?.update(
                        FileDownloadProgress(received: progress.received, expected: progress.expected ?? expectedBytes)
                    )
                }
            }
        }
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
            presentActivityController(item: .file(destination), from: screen, sourceItem: sourceItem)
        case .failure(let error):
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            if error is CancellationError { return }
            if case .rejected(status: 413, let message)? = error as? FileDownloadError {
                let reason = message ?? String(localized: "it is over the size limit for this kind of file")
                presenter.errorAlerts.show(
                    title: String(localized: "File Too Large to Share"),
                    message: String(localized: "The server won't send “\(file.fileName)”: \(reason).")
                )
            } else {
                presenter.errorAlerts.showShareFailure()
            }
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
        guard screen.viewIfLoaded?.window != nil else { return }
        let topVC = Router.topPresenter(from: screen)

        let ac = UIActivityViewController(
            activityItems: item.activityItems,
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
