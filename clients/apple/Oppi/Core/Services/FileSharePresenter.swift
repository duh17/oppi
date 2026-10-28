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
        loadingToken: ExportLoadingToken? = nil
    ) async {
        let format = FileShareService.defaultFormat(for: content)
        await share(content, format: format, loadingToken: loadingToken)
    }

    /// Share content in a specific format.
    static func share(
        _ content: FileShareService.ShareableContent,
        format: FileShareService.ExportFormat,
        loadingToken: ExportLoadingToken? = nil
    ) async {
        loadingToken?.start()
        let item = await FileShareService.render(content, as: format)
        loadingToken?.stop()
        presentActivityController(item: item)
    }

    /// Share an existing URL from UIKit interaction menus.
    static func share(_ url: URL, sourceView: UIView? = nil) {
        presentActivityController(item: .file(url), sourceView: sourceView)
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
                        await shareDefault(content, loadingToken: token)
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
                let token: ExportLoadingToken?
                if let button = buttonRef?() {
                    token = BarButtonLoadingToken(button: button, tintColor: tintColor)
                } else {
                    token = nil
                }
                Task { @MainActor in
                    await share(content, format: format, loadingToken: token)
                }
            }
        }
        return UIMenu(children: actions)
    }

    // MARK: - Activity Controller Presentation

    /// Present UIActivityViewController from the topmost view controller.
    ///
    /// Handles popover positioning for iPad. Cleans up temp files on completion.
    static func presentActivityController(
        item: FileShareService.ShareItem,
        sourceView: UIView? = nil
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
            if let sourceView {
                popover.sourceView = sourceView
                popover.sourceRect = sourceView.bounds
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
