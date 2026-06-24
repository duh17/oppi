import Foundation
import Testing
import UIKit
import WebKit
@testable import Oppi

// MARK: - NativeMarkdownImageView SVG rendering

@Suite("NativeMarkdownImageView SVG rendering")
@MainActor
struct NativeMarkdownImageViewSVGTests {
    @Test func rendererStaysHiddenUntilWindowReady() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
        view.layoutIfNeeded()

        let svgData = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10">
          <rect x="0" y="0" width="10" height="10" fill="red"/>
          <rect x="10" y="0" width="10" height="10" fill="green"/>
        </svg>
        """.utf8)
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://example.com/api")!,
            workspaceID: "workspace-1",
            filePath: "images/red-green.svg"
        ))

        view.apply(
            url: url,
            alt: "Red green",
            fetchWorkspaceFile: { _, _ in svgData },
            fetchSessionFile: nil
        )

        let rendererCreated = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            timelineFirstView(ofType: ReviewCommentWKWebView.self, in: view) != nil
        }
        #expect(rendererCreated, "SVG should create a WKWebView renderer")

        let renderer = try #require(timelineFirstView(ofType: ReviewCommentWKWebView.self, in: view))
        #expect(renderer.isHidden, "SVG WKWebView should not show a blank renderer before it has a window")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.addSubview(view)
        window.makeKeyAndVisible()

        let renderedAfterAttach = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            window.layoutIfNeeded()
            return !renderer.isHidden
        }

        #expect(renderedAfterAttach, "SVG renderer should appear after the view is attached and loadable")
        window.resignKey()
    }

    @Test func contentProcessTerminationShowsLoadingStateBeforeReload() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.addSubview(view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let svgData = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10">
          <rect x="0" y="0" width="10" height="10" fill="red"/>
          <rect x="10" y="0" width="10" height="10" fill="green"/>
        </svg>
        """.utf8)
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://example.com/api")!,
            workspaceID: "workspace-1",
            filePath: "images/reload.svg"
        ))

        view.apply(
            url: url,
            alt: "Reload",
            fetchWorkspaceFile: { _, _ in svgData },
            fetchSessionFile: nil
        )

        let rendered = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            window.layoutIfNeeded()
            return timelineFirstView(ofType: ReviewCommentWKWebView.self, in: view).map { !$0.isHidden } ?? false
        }
        #expect(rendered, "SVG should render before simulating WebKit process termination")

        let renderer = try #require(timelineFirstView(ofType: ReviewCommentWKWebView.self, in: view))
        let delegate = try #require(renderer.navigationDelegate)
        delegate.webViewWebContentProcessDidTerminate?(renderer)

        let spinnerVisible = timelineAllViews(in: view).contains { candidate in
            guard let spinner = candidate as? UIActivityIndicatorView else { return false }
            return !spinner.isHidden && spinner.isAnimating
        }
        #expect(renderer.isHidden, "Terminated SVG web content should not leave a blank WKWebView visible")
        #expect(spinnerVisible, "Terminated SVG web content should show a loading state while reloading")

        let reloaded = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            window.layoutIfNeeded()
            return !renderer.isHidden
        }
        #expect(reloaded, "SVG should reload after WebKit terminates its content process")
        window.resignKey()
    }

    @Test func loadedRendererIsFocusable() async throws {
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.addSubview(view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()

        let svgData = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 60">
          <rect width="100" height="60" fill="red"/>
        </svg>
        """.utf8)
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://example.com/api")!,
            workspaceID: "workspace-1",
            filePath: "images/diagram.svg"
        ))

        view.apply(
            url: url,
            alt: "Diagram",
            fetchWorkspaceFile: { _, _ in svgData },
            fetchSessionFile: nil
        )

        var visibleWebRenderer: UIView?
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            window.layoutIfNeeded()
            visibleWebRenderer = view.subviews.first {
                String(describing: type(of: $0)).contains("WKWebView") && !$0.isHidden
            }
            if visibleWebRenderer != nil { break }
        }

        let renderer = try #require(visibleWebRenderer)
        let hasTapGesture = renderer.gestureRecognizers?.contains { $0 is UITapGestureRecognizer } == true
        #expect(hasTapGesture, "SVG markdown images should be focusable just like raster images")
        window.resignKey()
    }
}
