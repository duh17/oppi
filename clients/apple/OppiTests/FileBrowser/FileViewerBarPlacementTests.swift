import Foundation
import Testing
import UIKit
@testable import Oppi

/// Where a file viewer's own buttons go: Edit, Share, the previous and next
/// file, and the … menu's Open in Pane and Pin. A pushed reader draws the
/// screen's one bar and carries them; beside the Files list and for a host
/// file the viewer's bar does, and the reader adds only its own buttons
/// there. A pushed file the reader does not show (an image) keeps the stack's
/// bar with Share and the previous and next file, and no … menu.
@Suite("File viewer bar placement")
@MainActor
struct FileViewerBarPlacementTests {
    /// One bar as the test reads it: the viewer's placed actions, then
    /// `menu:N` for the … menu's document actions (Open in Pane and Pin).
    struct Placement: Equatable, CustomStringConvertible {
        var hidesStackBar: Bool
        var viewerBar: [String]
        /// Nil when no reader is mounted (an image).
        var readerBar: [String]?

        var description: String {
            "hidesStackBar \(hidesStackBar); viewer \(viewerBar); reader \(readerBar.map(\.description) ?? "none")"
        }
    }

    private static let placed: [ReaderBarAction] = [.edit, .share, .previousFile, .nextFile]

    private static func read(_ bar: ReaderBar) -> [String] {
        placed.filter { bar.offers[$0] != nil }.map(\.rawValue)
            + (bar.documentActions.isEmpty ? [] : ["menu:\(bar.documentActions.count)"])
    }

    private static func placement(of viewer: FileViewerViewController) -> Placement {
        Placement(
            hidesStackBar: viewer.hidesNavigationBar,
            viewerBar: read(viewer.bar.reader),
            readerBar: viewer.reader.map { read($0.readerBar) }
        )
    }

    @Test func pushedTextPutsEverythingOnTheReadersBar() async throws {
        try await expectPlacement(
            path: "docs/b.md", chromeMode: .pushed,
            Placement(
                hidesStackBar: true,
                viewerBar: [],
                readerBar: ["edit", "share", "previousFile", "nextFile", "menu:2"]
            )
        )
    }

    @Test func pushedImageKeepsTheStackBarWithoutTheMenu() async throws {
        try await expectPlacement(
            path: "docs/b.png", chromeMode: .pushed,
            Placement(hidesStackBar: false, viewerBar: ["share", "previousFile", "nextFile"], readerBar: nil)
        )
    }

    @Test func textBesideTheListPutsEverythingOnTheViewersBar() async throws {
        try await expectPlacement(
            path: "docs/b.md", chromeMode: .treePane,
            Placement(
                hidesStackBar: false,
                viewerBar: ["edit", "share", "previousFile", "nextFile", "menu:2"],
                readerBar: []
            )
        )
    }

    @Test func imageBesideTheListHasTheMenu() async throws {
        try await expectPlacement(
            path: "docs/b.png", chromeMode: .treePane,
            Placement(hidesStackBar: false, viewerBar: ["share", "previousFile", "nextFile", "menu:2"], readerBar: nil)
        )
    }

    /// This server offers no host-file editing, so there is no Edit to place.
    @Test func pushedHostFileKeepsTheStackBar() async throws {
        try await expectPlacement(
            path: "~/notes/b.md", chromeMode: .pushed, source: .hostFile,
            Placement(
                hidesStackBar: false,
                viewerBar: ["share", "previousFile", "nextFile", "menu:2"],
                readerBar: []
            )
        )
    }

    // MARK: Helpers

    private func expectPlacement(
        path: String,
        chromeMode: FileBrowserContentChromeMode,
        source: FileBrowserContentSource = .workspaceFile,
        _ expected: Placement
    ) async throws {
        let pngData = try makePNG()
        let routes = TestURLProtocol.routeScope(mockPageRoutes(placementRoutes(png: pngData)))
        defer { routes.end() }
        let client = makeTestURLProtocolClient(host: "file-viewer-bar.test")
        _ = try await client.serverInfo()

        let directory = (path as NSString).deletingLastPathComponent
        let siblings = ["a.md", (path as NSString).lastPathComponent, "c.md"].map { name in
            let sibling = (directory as NSString).appendingPathComponent(name)
            return FileBrowserSelection(path: sibling, name: name, size: nil)
        }
        let viewer = FileViewerViewController(
            configuration: .init(
                workspaceId: "ws-bar",
                serverId: "srv-bar-\(UUID().uuidString)",
                filePath: path,
                fileName: (path as NSString).lastPathComponent,
                source: source,
                chromeMode: chromeMode,
                navigationContext: FileBrowserNavigationContext(files: siblings)
            ),
            services: .init(apiClient: client, pins: PinStore())
        )
        let navigation = UINavigationController(rootViewController: viewer)
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        let settled = await waitForMainActorCondition(timeout: .seconds(5)) {
            window.layoutIfNeeded()
            return Self.placement(of: viewer) == expected
        }
        // Stays so: no later pass moves a button.
        let held = await waitForMainActorConditionToStayTrue(for: .milliseconds(300)) {
            window.layoutIfNeeded()
            return Self.placement(of: viewer) == expected
        }
        #expect(settled && held, "expected \(expected), got \(Self.placement(of: viewer))")
    }
}

private func makePNG() throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
    let image = renderer.image { context in
        UIColor.systemBlue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
    }
    return try #require(image.pngData())
}

/// Off the main actor: the URL loading system calls it on its own thread.
private func placementRoutes(png: Data) -> @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)? {
    { request in
        switch request.url?.path {
        case "/server/info":
            return try mockJSONResponse(json: placementServerInfo, for: request)
        case "/files/current":
            let asked = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value ?? ""
            if asked.hasSuffix(".png") {
                return try mockBinaryResponse(contentType: "image/png", body: png, for: request)
            }
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: [
                    "Content-Type": "text/markdown; charset=utf-8",
                    "ETag": "\"sha256-\(String(repeating: "a", count: 64))\"",
                ]
            ))
            return (Data("# Notes\n- first\n".utf8), response)
        default:
            return nil
        }
    }
}

private let placementServerInfo = """
    {"name":"Test","version":"1.0","uptime":1,"os":"darwin","arch":"arm64","hostname":"test","nodeVersion":"22","piVersion":"1","configVersion":1,"capabilities":{"currentFiles":{"version":1},"workspaceFileEditing":{"version":1,"maxBytes":1048576}},"stats":{"workspaceCount":0,"activeSessionCount":0,"totalSessionCount":0,"skillCount":0,"modelCount":0}}
    """
