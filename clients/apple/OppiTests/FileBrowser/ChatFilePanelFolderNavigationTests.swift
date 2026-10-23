import Foundation
import Testing
import UIKit
@testable import Oppi

/// The chat Files panel's All tab: Back and Forward sit trailing in the bar
/// and retrace the folder trail.
@Suite("Chat file panel folder Back and Forward")
@MainActor
struct ChatFilePanelFolderNavigationTests {
    @Test func backAndForwardRetraceTheFolderTrailUntilANewFolderOpens() async throws {
        defer { FolderListingURLProtocol.handler = nil }
        FolderListingURLProtocol.handler = Self.listing(for:)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FolderListingURLProtocol.self]
        let api = APIClient(
            baseURL: try #require(URL(string: "http://folders.test:7749")),
            token: "sk_test",
            configuration: configuration
        )
        let inputs = ChatFilePanelInputs(
            sessionId: "session-1",
            workspaceId: "ws-1",
            changedFiles: [],
            serverId: "server-1",
            worktreeId: nil,
            reviewCommentSelectionScope: nil,
            connection: ServerConnection(),
            apiClient: api,
            fileIndexStore: FileIndexStore(),
            gitStatusStore: GitStatusStore(),
            navigation: AppNavigation(),
            closePanel: {}
        )
        let panel = ChatFilePanelViewController(
            root: makeTestAppRoot(),
            inputs: { inputs },
            tab: { .all },
            setTab: { _ in },
            onClose: {}
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: panel)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        // Done alone leads; Back then Forward trail, both off at the root.
        _ = await waitForMainActorCondition(timeout: .seconds(2)) {
            window.layoutIfNeeded()
            return panel.navigationItem.rightBarButtonItems != nil
        }
        #expect(panel.navigationItem.leftBarButtonItems?.map(\.title) == ["Done"])
        #expect(panel.navigationItem.rightBarButtonItems?.map(\.accessibilityIdentifier)
            == [Self.forwardID, Self.backID])
        #expect(try enabled(in: panel) == [false, false])

        try await openFolder("src", in: panel)
        try await openFolder("lib", in: panel)
        #expect(try enabled(in: panel) == [true, false])

        // Back climbs one folder at a time; Forward comes back down the same trail.
        try await tap(Self.backID, in: panel, expecting: "src")
        try await tap(Self.backID, in: panel, expecting: "Files")
        #expect(try enabled(in: panel) == [false, true])
        try await tap(Self.forwardID, in: panel, expecting: "src")
        try await tap(Self.forwardID, in: panel, expecting: "lib")
        #expect(try enabled(in: panel) == [true, false])

        // A folder off the trail starts a new one: nothing ahead of it.
        try await tap(Self.backID, in: panel, expecting: "src")
        try await tap(Self.backID, in: panel, expecting: "Files")
        try await openFolder("docs", in: panel)
        #expect(try enabled(in: panel) == [true, false])
    }

    private static let backID = "fileBrowser.inlineBack"
    private static let forwardID = "fileBrowser.inlineForward"

    /// The bar's item with `id`, read fresh each time.
    private func barItem(_ id: String, in panel: UIViewController) throws -> UIBarButtonItem {
        try #require(panel.navigationItem.rightBarButtonItems?.first { $0.accessibilityIdentifier == id })
    }

    /// Whether Back, then Forward, is enabled.
    private func enabled(in panel: UIViewController) throws -> [Bool] {
        [try barItem(Self.backID, in: panel).isEnabled, try barItem(Self.forwardID, in: panel).isEnabled]
    }

    private func tap(_ id: String, in panel: UIViewController, expecting title: String) async throws {
        let item = try barItem(id, in: panel)
        try #require(item.isEnabled)
        try #require(item.primaryAction).performWithSender(nil, target: nil)
        try await waitForTitle(title, in: panel)
    }

    /// Selects the folder row named `name` once its listing shows.
    private func openFolder(_ name: String, in panel: UIViewController) async throws {
        var indexPath: IndexPath?
        var list: UICollectionView?
        _ = await waitForMainActorCondition(timeout: .seconds(2)) {
            panel.view.layoutIfNeeded()
            list = Self.browserList(in: panel.view)
            indexPath = list.flatMap { Self.indexPath(ofRowNamed: name, in: $0) }
            return indexPath != nil
        }
        let found = try #require(indexPath, "Folder row \(name) never showed")
        let collectionView = try #require(list)
        collectionView.delegate?.collectionView?(collectionView, didSelectItemAt: found)
        try await waitForTitle(name, in: panel)
    }

    private func waitForTitle(_ title: String, in panel: UIViewController) async throws {
        let shown = await waitForMainActorCondition(timeout: .seconds(2)) {
            panel.view.layoutIfNeeded()
            return panel.navigationItem.title == title
        }
        try #require(shown, "Expected title \(title), saw \(panel.navigationItem.title ?? "nil")")
    }

    private static func browserList(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView, list.delegate is FileBrowserViewController { return list }
        for subview in view.subviews {
            if let list = browserList(in: subview) { return list }
        }
        return nil
    }

    private static func indexPath(ofRowNamed name: String, in list: UICollectionView) -> IndexPath? {
        for section in 0..<list.numberOfSections {
            for item in 0..<list.numberOfItems(inSection: section) {
                let indexPath = IndexPath(item: item, section: section)
                let cell = list.cellForItem(at: indexPath) as? UICollectionViewListCell
                if (cell?.contentConfiguration as? UIListContentConfiguration)?.text == name {
                    return indexPath
                }
            }
        }
        return nil
    }

    /// Root holds `src/` and `docs/`; `src/` holds `lib/`; deeper folders are
    /// empty. Runs on URLSession's loading thread, off the main actor.
    nonisolated private static func listing(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        let prefix = "/workspaces/ws-1/contents/"
        let path = url.path(percentEncoded: false)
        let folder = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : ""
        let children: [String] = switch folder {
        case "": ["src", "docs"]
        case "src/": ["lib"]
        default: []
        }
        let entries = children.map {
            #"{"name":"\#($0)","type":"directory","size":0,"modifiedAt":0,"path":"\#(folder)\#($0)/"}"#
        }
        let body = #"{"path":"\#(folder)","entries":[\#(entries.joined(separator: ","))],"truncated":false}"#
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(body.utf8), response)
    }
}

/// This suite's own stub, so a parallel suite's `TestURLProtocol` handler
/// never answers these listings.
private final class FolderListingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
