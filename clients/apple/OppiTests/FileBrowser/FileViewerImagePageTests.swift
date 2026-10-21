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
        FileViewerImageURLProtocol.pngData = pngData
        let client = FileViewerImageURLProtocol.makeClient()

        let viewer = FileViewerViewController(
            configuration: .init(
                workspaceId: FileViewerImageURLProtocol.workspaceId,
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

/// Serves one workspace image to the mounted viewer.
private final class FileViewerImageURLProtocol: URLProtocol, @unchecked Sendable {
    static let host = "file-viewer-image.test"
    static let workspaceId = "ws-image"
    nonisolated(unsafe) static var pngData = Data()

    static func makeClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FileViewerImageURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isImage = url.path == "/files/current"
        let body = isImage ? Self.pngData : Data(#"{"error":"not found"}"#.utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: isImage ? 200 : 404,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": isImage ? "image/png" : "application/json",
                "Content-Length": "\(body.count)",
            ]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
