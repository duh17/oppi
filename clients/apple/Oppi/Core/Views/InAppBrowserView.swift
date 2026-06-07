import SafariServices
import SwiftUI

/// SwiftUI wrapper for `SFSafariViewController`.
///
/// Used for in-app browsing of regular web links (`http` / `https`) tapped
/// from chat content.
struct InAppBrowserView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        Self.makeController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // No-op. SFSafariViewController uses the URL from initialization.
    }

    static func makeController(url: URL) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.view.accessibilityIdentifier = "inAppBrowser.view"
        return controller
    }
}

@MainActor
enum InAppBrowserPresenter {
    static func present(url: URL) {
        guard let presenter = activePresenter() else { return }
        if presenter is SFSafariViewController { return }

        let controller = InAppBrowserView.makeController(url: url)
        FullScreenViewerPresentationPolicy.configureLargePresentation(
            controller,
            traitCollection: presenter.traitCollection
        )
        presenter.present(controller, animated: true)
    }

    private static func activePresenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
