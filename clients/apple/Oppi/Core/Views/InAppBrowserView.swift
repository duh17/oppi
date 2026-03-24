import SafariServices
import SwiftUI

/// SwiftUI wrapper for `SFSafariViewController`.
///
/// Used for in-app browsing of regular web links (`http` / `https`) tapped
/// from chat content.
struct InAppBrowserView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // No-op. SFSafariViewController uses the URL from initialization.
    }
}
