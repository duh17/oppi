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

        let hasNonzeroWebView = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
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

@Suite("HTML content security")
struct HTMLContentSecurityTests {
    @MainActor
    @Test("HTML preview WebKit configuration disables persistent state and popups")
    func htmlPreviewConfigurationDisablesPersistentStateAndPopups() {
        let configuration = HTMLContentSecurity.makeConfiguration()

        #expect(configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(configuration.userContentController.userScripts.isEmpty)
    }

    @Test("HTML preview CSP blocks remote fetch but allows inline rendering")
    func htmlPreviewCSPBlocksRemoteFetchButAllowsInlineRendering() {
        let policy = HTMLContentSecurity.contentSecurityPolicy

        #expect(policy.contains("default-src 'none'"))
        #expect(policy.contains("script-src 'unsafe-inline'"))
        #expect(policy.contains("style-src 'unsafe-inline'"))
        #expect(policy.contains("connect-src 'none'"))
        #expect(policy.contains("img-src data: blob:"))
        #expect(policy.contains("media-src data: blob:"))
        #expect(!policy.contains("http:"))
        #expect(!policy.contains("https:"))
    }

    @Test("HTML preview injects CSP into existing head")
    func htmlPreviewInjectsCSPIntoExistingHead() {
        let html = "<html><head><title>Report</title></head><body>Hello</body></html>"
        let secured = HTMLContentSecurity.injectContentSecurityPolicy(into: html)

        #expect(secured.contains("<meta http-equiv=\"Content-Security-Policy\""))
        #expect(secured.contains("<title>Report</title>"))
    }

    @Test("HTML preview injects CSP into fragments without a head")
    func htmlPreviewInjectsCSPIntoFragmentsWithoutAHead() {
        let html = "<div>Hello</div>"
        let secured = HTMLContentSecurity.injectContentSecurityPolicy(into: html)

        #expect(secured.contains("<head><meta http-equiv=\"Content-Security-Policy\""))
        #expect(secured.contains("<div>Hello</div>"))
    }

    @Test("HTML preview only allows embedded local navigations")
    func htmlPreviewOnlyAllowsEmbeddedLocalNavigations() throws {
        #expect(HTMLContentSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "about:blank"))))
        #expect(HTMLContentSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "data:text/html,hi"))))
        #expect(HTMLContentSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "blob:https://example.com/id"))))
        #expect(!HTMLContentSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "file:///tmp/report.html"))))
        #expect(!HTMLContentSecurity.allowsEmbeddedNavigation(to: try #require(URL(string: "https://example.com"))))
    }
}
