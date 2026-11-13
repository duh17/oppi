import SafariServices
import UIKit

@MainActor
enum InAppBrowserPresenter {
    /// Presents `url` over `screen`'s window, unless a browser is already in
    /// front there.
    static func present(url: URL, from screen: UIViewController) {
        let presenter = Router.topPresenter(from: screen)
        if presenter is SFSafariViewController { return }

        let controller = makeController(url: url)
        FullScreenViewerPresentationPolicy.configureLargePresentation(controller, over: presenter)
        presenter.present(controller, animated: true)
    }

    private static func makeController(url: URL) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.view.accessibilityIdentifier = "inAppBrowser.view"
        return controller
    }
}
