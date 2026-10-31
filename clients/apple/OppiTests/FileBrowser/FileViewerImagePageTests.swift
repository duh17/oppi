import Foundation
import Testing
import UIKit
@testable import Oppi

/// The file viewer's image page: one VoiceOver stop over the renderer, which
/// opens the full-screen viewer. Tap and accessibility activation are the same
/// action, as they are for the chat's markdown image.
@Suite("File viewer image page")
@MainActor
struct FileViewerImagePageTests {
    @Test func imagePageIsAnActivatableButtonThatOpensFullScreen() async throws {
        let (_, pngData) = try makePNG()
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path == "/files/current" else { return nil }
            return try mockBinaryResponse(status: 200, contentType: "image/png", body: pngData, for: request)
        })
        defer { routes.end() }
        let client = makeTestURLProtocolClient(host: "file-viewer-image.test")

        let viewer = FileViewerViewController(
            configuration: .init(
                workspaceId: "ws-image",
                serverId: "srv-image-\(UUID().uuidString)",
                filePath: "images/shot.png",
                fileName: "shot.png",
                chromeMode: .pushed
            ),
            services: .init(apiClient: client)
        )
        let navigation = UINavigationController(rootViewController: viewer)
        let window = try showInKeyWindow(navigation)
        defer { window.isHidden = true }

        let mounted = await waitForMainActorCondition(timeout: .seconds(5)) {
            window.layoutIfNeeded()
            return imagePage(in: viewer.view)?.isAccessibilityElement == true
        }
        #expect(mounted, "The image page did not mount")
        let page = try #require(imagePage(in: viewer.view))
        #expect(page.accessibilityIdentifier == "fileViewer.image.open")
        #expect(page.accessibilityLabel?.isEmpty == false, "The image page must be a labeled stop")
        #expect(page.accessibilityTraits.contains(.image))
        #expect(page.accessibilityTraits.contains(.button))
        #expect(page.accessibilityElementsHidden, "The renderer inside must not be a second stop")

        #expect(page.accessibilityActivate())

        let opened = await waitForMainActorCondition(timeout: .seconds(3)) {
            window.layoutIfNeeded()
            guard let presented = navigation.presentedViewController as? UINavigationController else {
                return false
            }
            return presented.topViewController is FullScreenImageViewController
        }
        #expect(opened, "VoiceOver activation must open the image full screen")
    }

    private func imagePage(in root: UIView) -> DataImagePreviewView? {
        if let page = root as? DataImagePreviewView { return page }
        for subview in root.subviews {
            if let page = imagePage(in: subview) { return page }
        }
        return nil
    }

    /// The full-screen viewer resolves its presenter from the key window, so
    /// the test window joins the app's scene and takes key.
    private func showInKeyWindow(_ root: UIViewController) throws -> UIWindow {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        return window
    }
}

private func makePNG() throws -> (UIImage, Data) {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
    let image = renderer.image { context in
        UIColor.systemBlue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    }
    return (image, try #require(image.pngData()))
}
