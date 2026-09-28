import Foundation
import ObjectiveC
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

        let rendererCreated = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
            timelineFirstView(ofType: ReviewCommentWKWebView.self, in: view) != nil
        }
        #expect(rendererCreated, "SVG should create a WKWebView renderer")

        let renderer = try #require(timelineFirstView(ofType: ReviewCommentWKWebView.self, in: view))
        #expect(renderer.isHidden, "SVG WKWebView should not show a blank renderer before it has a window")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.addSubview(view)
        window.makeKeyAndVisible()

        let renderedAfterAttach = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
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

        let rendered = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
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

        let reloaded = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
            window.layoutIfNeeded()
            return !renderer.isHidden
        }
        #expect(reloaded, "SVG should reload after WebKit terminates its content process")
        window.resignKey()
    }

    @Test func loadedRendererIsAnAltLabeledImageButtonAndAccessibilityActivationOpensPreview() async throws {
        let host = UIViewController()
        let view = NativeMarkdownImageView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 180)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        window.rootViewController = host
        host.view.addSubview(view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true }

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
            alt: "System architecture diagram",
            fetchWorkspaceFile: { _, _ in svgData },
            fetchSessionFile: nil
        )

        let rendered = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
            window.layoutIfNeeded()
            return view.subviews.contains {
                String(describing: type(of: $0)).contains("WKWebView") && !$0.isHidden
            }
        }
        #expect(rendered)
        #expect(view.isAccessibilityElement)
        #expect(view.accessibilityLabel == "System architecture diagram")
        #expect(view.accessibilityHint?.localizedCaseInsensitiveContains("full screen") == true)
        #expect(view.accessibilityTraits.contains(.image))
        #expect(view.accessibilityTraits.contains(.button))
        #expect(view.accessibilityElementsHidden, "SVG implementation views must not duplicate the media element")

        #expect(view.accessibilityActivate())
        let previewOpened = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            guard let navigation = host.presentedViewController as? UINavigationController else { return false }
            return navigation.topViewController is FullScreenImageDataPreviewViewController
        }
        #expect(previewOpened, "VoiceOver activation must open the SVG preview used by tap")
    }

    /// Regression: an inline transcript SVG paints, then a timeline scroll that
    /// lays the row out, detaches it from the window, and redisplays the same
    /// image must not leave a blank hole. The hole can be a hidden WKWebView
    /// or a visible transparent renderer showing the chat background. Animation
    /// may pause; the painted graphic must remain.
    @Test func inlineSVGStaysPaintedAfterScrollOffscreenAndReturn() async throws {
        NativeMarkdownImageView.debugResetPreparedArtifactsForTesting()
        defer { NativeMarkdownImageView.debugResetPreparedArtifactsForTesting() }

        let hostBackground = UIColor(red: 1, green: 0, blue: 1, alpha: 1)
        let hostSize = CGSize(width: 390, height: 700)
        let host = UIViewController()
        host.view.frame = CGRect(origin: .zero, size: hostSize)
        host.view.backgroundColor = hostBackground

        let scrollView = UIScrollView(frame: host.view.bounds)
        scrollView.backgroundColor = hostBackground
        scrollView.clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: hostSize.width, height: 2_400)
        host.view.addSubview(scrollView)

        let imageView = NativeMarkdownImageView()
        let imageFrame = CGRect(x: 16, y: 24, width: 340, height: 200)
        imageView.frame = imageFrame
        scrollView.addSubview(imageView)

        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.backgroundColor = hostBackground
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let svgData = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" width="340" height="180" viewBox="0 0 340 180">
          <rect width="340" height="180" fill="#00ff00">
            <animate attributeName="opacity" values="1;0.92;1" dur="0.8s" repeatCount="indefinite"/>
          </rect>
        </svg>
        """.utf8)
        let url = try #require(WorkspaceFileURL.make(
            baseURL: URL(string: "https://example.com/api")!,
            workspaceID: "workspace-scroll",
            filePath: "images/scroll-return.svg"
        ))
        let applyImage = {
            imageView.apply(
                url: url,
                alt: "Scroll return",
                fetchWorkspaceFile: { _, _ in svgData },
                fetchSessionFile: nil,
                preferredDisplayWidth: imageFrame.width
            )
        }
        applyImage()

        let documentReady = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
            await Self.svgDocumentReady(imageView, layingOut: window)
        }
        let readyRenderer = timelineFirstView(ofType: ReviewCommentWKWebView.self, in: imageView)
        try #require(
            documentReady && readyRenderer?.isHidden == false,
            "SVG should be on screen before scroll pressure. ready=\(documentReady) hidden=\(readyRenderer?.isHidden ?? true) loading=\(readyRenderer?.isLoading ?? true)"
        )

        // Timeline scroll moves the row out of the visible rect while the
        // collection view also lays the cell out. Far enough, the cell leaves
        // the window and comes back through the same image view.
        scrollView.setContentOffset(CGPoint(x: 0, y: 1_800), animated: false)
        imageView.setNeedsLayout()
        imageView.layoutIfNeeded()
        window.layoutIfNeeded()

        let restoredFrame = imageView.frame
        imageView.removeFromSuperview()
        scrollView.setContentOffset(.zero, animated: false)
        scrollView.addSubview(imageView)
        imageView.frame = restoredFrame.width > 1 ? restoredFrame : imageFrame
        window.layoutIfNeeded()
        applyImage()

        let paintedAfterReturn = await waitForTimelineCondition(timeoutMs: 10_000) { @MainActor in
            await Self.svgIsVisiblyPainted(imageView, layingOut: nil, preservingLayout: false)
        }
        let after = await Self.svgPaintDiagnostic(imageView, host: host.view, preservingLayout: false)
        #expect(
            paintedAfterReturn,
            "Inline SVG left a blank hole after scroll offscreen and back. \(after)"
        )
    }

    private static func svgDocumentReady(
        _ imageView: NativeMarkdownImageView,
        layingOut window: UIWindow
    ) async -> Bool {
        let renderer = timelineFirstView(ofType: ReviewCommentWKWebView.self, in: imageView)
        if renderer == nil || renderer?.bounds.width ?? 0 < 1 || imageView.bounds.width < 1 {
            window.layoutIfNeeded()
            return false
        }
        guard let renderer, !renderer.isHidden, !renderer.isLoading, renderer.window != nil else {
            return false
        }
        return (try? await renderer.evaluateJavaScript(
            "document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0"
        ) as? Bool) == true
    }

    /// On-screen WKWebView whose host bitmap contains the SVG fill. A hidden
    /// renderer and a visible transparent bitmap both fail.
    private static func svgIsVisiblyPainted(
        _ imageView: NativeMarkdownImageView,
        layingOut window: UIWindow?,
        preservingLayout: Bool
    ) async -> Bool {
        let renderer = timelineFirstView(ofType: ReviewCommentWKWebView.self, in: imageView)
        if renderer == nil || renderer?.bounds.width ?? 0 < 1 || imageView.bounds.width < 1 {
            window?.layoutIfNeeded()
            return false
        }
        guard let renderer, !renderer.isHidden, !renderer.isLoading, renderer.window != nil else {
            return false
        }
        let imageReady = (try? await renderer.evaluateJavaScript(
            "document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0"
        ) as? Bool) == true
        guard imageReady else { return false }
        let paint = preservingLayout
            ? withoutImageLayout { hostPaint(of: imageView) }
            : hostPaint(of: imageView)
        return paint.greenPixels >= 40 && !renderer.isHidden
    }

    private static func svgPaintDiagnostic(
        _ imageView: NativeMarkdownImageView,
        host: UIView,
        preservingLayout: Bool
    ) async -> String {
        guard let renderer = timelineFirstView(ofType: ReviewCommentWKWebView.self, in: imageView) else {
            return "renderer=missing"
        }
        let hiddenBefore = renderer.isHidden
        let paint = preservingLayout
            ? withoutImageLayout { hostPaint(of: imageView) }
            : hostPaint(of: imageView)
        return "hiddenBefore=\(hiddenBefore) hiddenAfter=\(renderer.isHidden) loading=\(renderer.isLoading) inWindow=\(renderer.window != nil) webBounds=\(renderer.bounds) paint=\(paint) hostBounds=\(host.bounds)"
    }

    private struct PaintRead: CustomStringConvertible {
        var greenPixels: Int
        var hostBackgroundPixels: Int
        var center: String
        var description: String {
            "green=\(greenPixels) hostBackground=\(hostBackgroundPixels) center=\(center)"
        }
    }

    /// Composite of the image view in its host. Magenta pixels are the blank
    /// hole; green pixels are the SVG fill.
    private static func hostPaint(of imageView: UIView) -> PaintRead {
        guard let host = imageView.window?.rootViewController?.view ?? imageView.superview,
              host.bounds.width > 1,
              host.bounds.height > 1,
              imageView.bounds.width > 1,
              imageView.bounds.height > 1 else {
            return PaintRead(greenPixels: 0, hostBackgroundPixels: 0, center: "no-host")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = imageView.window?.screen.scale ?? 2
        let snapshot = UIGraphicsImageRenderer(size: host.bounds.size, format: format).image { _ in
            host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = snapshot.cgImage else {
            return PaintRead(greenPixels: 0, hostBackgroundPixels: 0, center: "nil")
        }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return PaintRead(greenPixels: 0, hostBackgroundPixels: 0, center: "no-context")
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let frame = imageView.convert(imageView.bounds, to: host)
        let scaleX = CGFloat(width) / max(snapshot.size.width, 1)
        let scaleY = CGFloat(height) / max(snapshot.size.height, 1)
        let minX = max(0, Int((frame.minX + frame.width * 0.2) * scaleX))
        let maxX = min(width, Int((frame.maxX - frame.width * 0.2) * scaleX))
        let minY = max(0, Int((frame.minY + frame.height * 0.2) * scaleY))
        let maxY = min(height, Int((frame.maxY - frame.height * 0.2) * scaleY))
        guard minX < maxX, minY < maxY else {
            return PaintRead(greenPixels: 0, hostBackgroundPixels: 0, center: "offscreen \(frame)")
        }
        let centerX = min(width - 1, max(0, (minX + maxX) / 2))
        let centerY = min(height - 1, max(0, (minY + maxY) / 2))
        let centerOffset = centerY * bytesPerRow + centerX * 4
        var green = 0
        var hostBackground = 0
        for y in Swift.stride(from: minY, to: maxY, by: 4) {
            for x in Swift.stride(from: minX, to: maxX, by: 4) {
                let offset = y * bytesPerRow + x * 4
                let red = pixels[offset]
                let greenChannel = pixels[offset + 1]
                let blue = pixels[offset + 2]
                let alpha = pixels[offset + 3]
                if alpha > 200, greenChannel > 180, red < 80, blue < 80 {
                    green += 1
                } else if alpha > 200, red > 200, blue > 200, greenChannel < 80 {
                    hostBackground += 1
                }
            }
        }
        return PaintRead(
            greenPixels: green,
            hostBackgroundPixels: hostBackground,
            center: "\(pixels[centerOffset]),\(pixels[centerOffset + 1]),\(pixels[centerOffset + 2]),\(pixels[centerOffset + 3])"
        )
    }

    /// `drawHierarchy(afterScreenUpdates:)` lays the image view out. That layout
    /// pass hides an already painted SVG, so the pre-scroll read skips it.
    private static func withoutImageLayout<T>(_ body: () -> T) -> T {
        let selector = #selector(UIView.layoutSubviews)
        let skip = #selector(NativeMarkdownImageView.oppiSVGScrollTestSkipLayout)
        guard let originalMethod = class_getInstanceMethod(NativeMarkdownImageView.self, selector),
              let skipMethod = class_getInstanceMethod(NativeMarkdownImageView.self, skip) else {
            return body()
        }
        method_exchangeImplementations(originalMethod, skipMethod)
        defer { method_exchangeImplementations(originalMethod, skipMethod) }
        return body()
    }

    private static func layoutSwizzleOwner() -> String {
        let selector = #selector(UIView.layoutSubviews)
        var owner = "missing"
        var cursor: AnyClass? = NativeMarkdownImageView.self
        while let current = cursor {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(current, &count) {
                for index in 0..<Int(count) {
                    if method_getName(methods[index]) == selector {
                        owner = NSStringFromClass(current)
                    }
                }
                free(methods)
            }
            cursor = class_getSuperclass(current)
        }
        let skipFound = class_getInstanceMethod(
            NativeMarkdownImageView.self,
            #selector(NativeMarkdownImageView.oppiSVGScrollTestSkipLayout)
        ) != nil
        return "layoutOwner=\(owner) skipFound=\(skipFound)"
    }
}

extension NativeMarkdownImageView {
    @objc func oppiSVGScrollTestSkipLayout() {}
}
