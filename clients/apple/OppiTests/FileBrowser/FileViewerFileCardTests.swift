import Foundation
import Testing
import UIKit
@testable import Oppi

/// A file the viewer cannot draw opens as a file card, never as a load error
/// with a Retry that cannot succeed; only a failure that could pass on a
/// second read offers Retry.
@Suite("File viewer file card")
@MainActor
struct FileViewerFileCardTests {
    @Test func archiveOverTheTextLimitOpensAsACardWithoutReadingIt() async throws {
        let byteCount = 12_345_678
        let wholeReads = RequestCounter()
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path == "/files/current" else { return nil }
            if request.httpMethod == "HEAD" {
                return try headResponse(byteCount: byteCount, for: request)
            }
            wholeReads.increment()
            return try mockJSONResponse(status: 413, json: #"{"error":"File too large (max 10MB)"}"#, for: request)
        })
        defer { routes.end() }

        let (viewer, window) = try showViewer(path: "exports/archive-sample.zip", size: byteCount)
        defer { window.isHidden = true }

        let card = await mountedCard(in: viewer, window: window)
        #expect(card != nil, "A zip must open as the file card")
        #expect(label("fileViewer.card.summary", in: viewer.view)?.text?.contains("12.3 MB") == true)
        #expect(button("fileViewer.card.share", in: viewer.view) != nil)
        #expect(button("fileViewer.card.save", in: viewer.view) != nil)
        #expect(stateView(in: viewer.view) == nil, "No load error under the card")
        #expect(wholeReads.total == 0, "The card reads no bytes until an action asks")
    }

    @Test func textOverTheLimitOpensAsACardThatSaysWhy() async throws {
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path == "/files/current" else { return nil }
            if request.httpMethod == "HEAD" {
                return try headResponse(byteCount: 48_000_000, for: request)
            }
            return try mockJSONResponse(status: 413, json: #"{"error":"File too large (max 10MB)"}"#, for: request)
        })
        defer { routes.end() }

        let (viewer, window) = try showViewer(path: "logs/server.log", size: nil)
        defer { window.isHidden = true }

        let card = await mountedCard(in: viewer, window: window)
        #expect(card != nil, "Text the server will not send whole must open as the file card")
        #expect(allLabels(in: viewer.view).contains { $0.text?.hasPrefix("Too large to show here") == true })
        #expect(button("fileViewer.card.share", in: viewer.view) != nil)
    }

    @Test(arguments: [(403, false), (500, true)])
    func retryIsOfferedOnlyWhenAnotherReadCouldSucceed(status: Int, offersRetry: Bool) async throws {
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            guard request.url?.path == "/files/current" else { return nil }
            return try mockJSONResponse(status: status, json: #"{"error":"Refused"}"#, for: request)
        })
        defer { routes.end() }

        let (viewer, window) = try showViewer(path: "notes/plan.md", size: nil)
        defer { window.isHidden = true }

        // Wait for the built view's words, so its button (or none) is laid out too.
        let failed = await waitForMainActorCondition(timeout: .seconds(5)) {
            window.layoutIfNeeded()
            return allLabels(in: viewer.view).contains { $0.text == "Unable to Load" }
        }
        #expect(failed)
        let retry = allButtons(in: viewer.view).first { $0.configuration?.title == "Retry" }
        #expect((retry != nil) == offersRetry)
    }

    // MARK: Helpers

    private func showViewer(path: String, size: Int?) throws -> (FileViewerViewController, UIWindow) {
        let client = makeTestURLProtocolClient(host: "file-viewer-card.test")
        let viewer = FileViewerViewController(
            configuration: .init(
                workspaceId: "ws-card",
                serverId: "srv-card-\(UUID().uuidString)",
                filePath: path,
                fileName: (path as NSString).lastPathComponent,
                fileSize: size,
                chromeMode: .pushed
            ),
            services: .init(apiClient: client)
        )
        let navigation = UINavigationController(rootViewController: viewer)
        let window = makeSceneWindow()
        window.frame = CGRect(x: 0, y: 0, width: 744, height: 1133)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        navigation.loadViewIfNeeded()
        return (viewer, window)
    }

    private func mountedCard(in viewer: FileViewerViewController, window: UIWindow) async -> FileCardView? {
        _ = await waitForMainActorCondition(timeout: .seconds(5)) {
            window.layoutIfNeeded()
            return find(FileCardView.self, in: viewer.view) != nil || stateView(in: viewer.view) != nil
        }
        return find(FileCardView.self, in: viewer.view)
    }
}

private func headResponse(byteCount: Int, for request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let response = try #require(HTTPURLResponse(
        url: request.url ?? URL(fileURLWithPath: "/"),
        statusCode: 200,
        httpVersion: nil,
        headerFields: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(byteCount)",
            "Last-Modified": "Wed, 04 Mar 2026 05:06:07 GMT",
        ]
    ))
    return (Data(), response)
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var total: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

@MainActor
private func find<View: UIView>(_ type: View.Type, in root: UIView) -> View? {
    if let match = root as? View { return match }
    for subview in root.subviews {
        if let match = find(type, in: subview) { return match }
    }
    return nil
}

@MainActor
private func all<View: UIView>(_ type: View.Type, in root: UIView) -> [View] {
    ((root as? View).map { [$0] } ?? []) + root.subviews.flatMap { all(type, in: $0) }
}

@MainActor
private func allLabels(in root: UIView) -> [UILabel] { all(UILabel.self, in: root) }

@MainActor
private func allButtons(in root: UIView) -> [UIButton] { all(UIButton.self, in: root) }

@MainActor
private func label(_ identifier: String, in root: UIView) -> UILabel? {
    allLabels(in: root).first { $0.accessibilityIdentifier == identifier }
}

@MainActor
private func button(_ identifier: String, in root: UIView) -> UIButton? {
    allButtons(in: root).first { $0.accessibilityIdentifier == identifier }
}

@MainActor
private func stateView(in root: UIView) -> UIContentUnavailableView? {
    find(UIContentUnavailableView.self, in: root)
}
