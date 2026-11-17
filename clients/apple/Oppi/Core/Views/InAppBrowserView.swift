import SafariServices
import UIKit

@MainActor
enum InAppBrowserPresenter {
    /// Presents `url` over `screen`'s window. A Safari sheet already in
    /// front there cannot load another address, so the new page replaces
    /// it: a link that reaches here came from behind that sheet (another
    /// window's link, a notification, an extension), and dropping it would
    /// leave the tap doing nothing. True when it replaced one.
    @discardableResult
    static func present(url: URL, from screen: UIViewController) -> Bool {
        let top = Router.topPresenter(from: screen)
        let controller = makeController(url: url)
        guard top is SFSafariViewController, let presenter = top.presentingViewController else {
            FullScreenViewerPresentationPolicy.configureLargePresentation(controller, over: top)
            top.present(controller, animated: true)
            return false
        }
        presenter.dismiss(animated: false) {
            FullScreenViewerPresentationPolicy.configureLargePresentation(controller, over: presenter)
            presenter.present(controller, animated: true)
        }
        return true
    }

    private static func makeController(url: URL) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.view.accessibilityIdentifier = "inAppBrowser.view"
        return controller
    }
}
