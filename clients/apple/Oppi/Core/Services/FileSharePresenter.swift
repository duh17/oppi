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

    /// Share content using the smart default format.
    static func shareDefault(
        _ content: FileShareService.ShareableContent,
        loadingToken: ExportLoadingToken? = nil,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)? = nil
    ) async {
        let format = FileShareService.defaultFormat(for: content)
        await share(content, format: format, loadingToken: loadingToken, sourceItem: sourceItem)
    }

    /// Share content in a specific format.
    static func share(
        _ content: FileShareService.ShareableContent,
        format: FileShareService.ExportFormat,
        loadingToken: ExportLoadingToken? = nil,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)? = nil
    ) async {
        loadingToken?.start()
        let item = await FileShareService.render(content, as: format)
        loadingToken?.stop()
        presentActivityController(item: item, sourceItem: sourceItem)
    }

    /// Share an existing URL from UIKit interaction menus.
    static func share(_ url: URL, sourceView: UIView? = nil) {
        presentActivityController(item: .file(url), sourceItem: sourceView)
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
        sourceItem: (any UIPopoverPresentationControllerSourceItem)?
    ) async {
        guard !isPreparingRemoteFile, let presenter = topViewController() else { return }
        isPreparingRemoteFile = true
        defer { isPreparingRemoteFile = false }

        let destination = FileShareService.temporaryFileURL(named: file.fileName)
        let expectedBytes = file.expectedBytes
        let overlay = FileShareProgressOverlay(
            fileName: file.fileName,
            progress: FileDownloadProgress(received: 0, expected: expectedBytes),
            palette: ThemeRuntimeState.currentPalette()
        )
        let download = Task {
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
            presentActivityController(item: .file(destination), sourceItem: sourceItem)
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

    /// Create a fully-wired share bar button item.
    ///
    /// Single-format content (images, PDFs): tap exports directly.
    /// Multi-format content (code, markdown, etc.): tap opens format picker menu.
    /// Shows a spinner in-place while the export renders.
    ///
    /// Used by ``FullScreenCodeViewController``, ``FullScreenImageViewController``,
    /// and any UIKit surface that needs a share button.
    /// The Share item for a file: its format menu or direct export when its
    /// bytes are in hand, else a download and the share sheet.
    static func makeShareBarButtonItem(for file: ShareableFile) -> UIBarButtonItem {
        switch file {
        case .loaded(let content):
            return makeShareBarButtonItem(for: content)
        case .remote(let remote):
            let box = Weak<UIBarButtonItem>()
            let button = UIBarButtonItem(
                image: UIImage(systemName: "square.and.arrow.up"),
                primaryAction: UIAction { _ in
                    Task { @MainActor in await share(remote, sourceItem: box.value) }
                }
            )
            box.value = button
            return button
        }
    }

    static func makeShareBarButtonItem(
        for content: FileShareService.ShareableContent,
        tintColor: UIColor? = nil
    ) -> UIBarButtonItem {
        let formats = FileShareService.availableFormats(for: content)
        let shareImage = UIImage(systemName: "square.and.arrow.up")
        let button: UIBarButtonItem

        if formats.count <= 1 {
            // Single format — tap exports directly with spinner.
            // Can't capture button weakly before it's initialized, so use
            // an intermediary box that gets populated after init.
            let buttonBox = Weak<UIBarButtonItem>()
            button = UIBarButtonItem(
                image: shareImage,
                primaryAction: UIAction { _ in
                    guard let btn = buttonBox.value else { return }
                    let token = BarButtonLoadingToken(button: btn, tintColor: tintColor)
                    Task { @MainActor in
                        await shareDefault(content, loadingToken: token, sourceItem: btn)
                    }
                }
            )
            buttonBox.value = button
        } else {
            // Multiple formats — tap opens format picker menu.
            // Create button first, then set menu with a weak ref so the
            // spinner can replace the button's content during export.
            button = UIBarButtonItem(image: shareImage, menu: nil)
            let weakButton = Weak(button)
            button.menu = buildFormatMenu(
                for: content,
                tintColor: tintColor,
                buttonRef: { weakButton.value }
            )
        }

        button.tintColor = tintColor
        return button
    }

    // MARK: - Format Menu

    /// Build a UIMenu with format options for the given content.
    ///
    /// Each menu item renders the content in that format and presents
    /// the system share sheet. Shared between bar button items and
    /// any other UIKit surface that needs a format picker.
    static func buildFormatMenu(
        for content: FileShareService.ShareableContent,
        tintColor: UIColor? = nil,
        buttonRef: (@MainActor () -> UIBarButtonItem?)? = nil
    ) -> UIMenu {
        let formats = FileShareService.availableFormats(for: content)
        let actions = formats.map { format in
            let info = FileShareService.formatDisplayInfo(format, for: content)
            return UIAction(
                title: info.label,
                image: UIImage(systemName: info.icon)
            ) { _ in
                let button = buttonRef?()
                let token: ExportLoadingToken? = button.map { BarButtonLoadingToken(button: $0, tintColor: tintColor) }
                Task { @MainActor in
                    await share(content, format: format, loadingToken: token, sourceItem: button)
                }
            }
        }
        return UIMenu(children: actions)
    }

    // MARK: - Activity Controller Presentation

    /// Present UIActivityViewController from the topmost view controller.
    ///
    /// The iPad popover points at `sourceItem` (the row or the bar button).
    /// Cleans up temp files on completion.
    static func presentActivityController(
        item: FileShareService.ShareItem,
        sourceItem: (any UIPopoverPresentationControllerSourceItem)? = nil
    ) {
        guard let topVC = topViewController() else { return }

        let ac = UIActivityViewController(
            activityItems: item.activityItems,
            applicationActivities: nil
        )
        ac.completionWithItemsHandler = { _, _, _, _ in
            FileShareService.cleanupTempFiles()
        }
        if let popover = ac.popoverPresentationController {
            // A row that scrolled away during its download is no anchor.
            if let sourceItem, (sourceItem as? UIView).map({ $0.window != nil }) ?? true {
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

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let rootVC = scene.keyWindow?.rootViewController else {
            return nil
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }
}
