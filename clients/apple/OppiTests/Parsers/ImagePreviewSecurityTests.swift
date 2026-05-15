import SwiftUI
import Testing
import UIKit
import WebKit

@testable import Oppi

@Suite("Image preview web security")
struct ImagePreviewSecurityTests {
    @MainActor
    @Test("preview WebKit configuration disables persistent state and JavaScript")
    func previewWebKitConfigurationDisablesPersistentStateAndJavaScript() {
        let configuration = ImagePreviewWebSecurity.makeConfiguration()

        #expect(configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        if #available(iOS 14.0, *) {
            #expect(configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        }
        #expect(configuration.userContentController.userScripts.isEmpty)
    }

    @MainActor
    @Test("fullscreen SVG preview gives WebKit a nonzero viewport")
    func fullscreenSVGPreviewGivesWebKitNonzeroViewport() async throws {
        let controller = FullScreenImageDataPreviewViewController(
            data: Self.svgData,
            mimeType: "image/svg+xml",
            title: "Preview"
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let hasNonzeroWebView = await waitForTimelineCondition(timeoutMs: 1_500) { @MainActor in
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return timelineAllViews(in: controller.view).contains { view in
                String(describing: type(of: view)).contains("PiWKWebView") &&
                    view.bounds.width > 100 &&
                    view.bounds.height > 50
            }
        }

        #expect(hasNonzeroWebView, "Fullscreen SVG preview should not present a blank zero-sized WebKit view")
    }

    @MainActor
    @Test("fullscreen SVG preview supports pinch zoom")
    func fullscreenSVGPreviewSupportsPinchZoom() throws {
        let controller = FullScreenImageDataPreviewViewController(
            data: Self.svgData,
            mimeType: "image/svg+xml",
            title: "Preview"
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let scrollView = try #require(timelineAllViews(in: controller.view).compactMap { $0 as? UIScrollView }.first)
        let zoomTarget = try #require(controller.viewForZooming(in: scrollView))

        #expect(scrollView.minimumZoomScale == 1.0)
        #expect(scrollView.maximumZoomScale >= 5.0)
        #expect(zoomTarget is AnimatedImageWebContainerView)
    }

    @Test("preview CSP blocks network and script by default")
    func previewCSPBlocksNetworkAndScriptByDefault() {
        let policy = ImagePreviewWebSecurity.contentSecurityPolicy

        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("img-src data:"))
        #expect(policy.contains("media-src data:"))
        #expect(!policy.contains("http:"))
        #expect(!policy.contains("https:"))
        #expect(!policy.contains("script-src"))
    }

    private static let svgData = Data("""
    <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"320\" height=\"180\">
      <rect width=\"320\" height=\"180\" fill=\"#111827\"/>
    </svg>
    """.utf8)
}
