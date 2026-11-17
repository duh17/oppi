import Foundation
import os
import Testing
import UIKit
@testable import Oppi

/// The Pinned section of the Home root and the launcher's Pinned group, in
/// real windows over a server that keeps pins.
@Suite("File Browser pins")
@MainActor
struct FileBrowserPinsTests {
    private nonisolated static func pin(_ id: String, _ path: String, _ kind: String, _ status: String, label: String? = nil) -> String {
        let label = label.map { #","label":"\#($0)""# } ?? ""
        let target = kind == "directory"
            ? #"{"kind":"files","origin":"host","path":"\#(path)"}"#
            : #"{"kind":"file","origin":"host","path":"\#(path)","line":null}"#
        return #"{"id":"\#(id)","target":\#(target),"createdAt":1,"status":"\#(status)"\#(label)}"#
    }

    private nonisolated static var pins: String {
        let pins = [
            pin("pin_Notebook0001", "~/notebook", "directory", "ok"),
            pin("pin_Reports00002", "~/Documents/reports", "directory", "ok", label: "Weekly reports"),
            pin("pin_Book00000003", "~/Books/The Left Hand of Darkness.epub", "file", "ok"),
            pin("pin_OldPlan00004", "~/Desktop/old-plan", "directory", "missing"),
        ]
        return #"{"revision":4,"pins":[\#(pins.joined(separator: ","))]}"#
    }

    private nonisolated static var home: String {
        let entries = ["Books", "Documents", "notebook"].map {
            #"{"name":"\#($0)","type":"directory","size":0,"modifiedAt":1790000000000}"#
        }
        return #"{"path":"/","entries":[\#(entries.joined(separator: ","))],"truncated":false}"#
    }

    private nonisolated static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// A paired server whose pins and home folder answer; everything else is a 404.
    /// `puts` collects the body of every `PUT /pins`.
    private static func makeServer(
        puts: OSAllocatedUnfairLock<[Data]> = OSAllocatedUnfairLock(initialState: [])
    ) async throws -> (root: AppRootEnvironment, serverId: String, scope: TestURLProtocol.RouteScope) {
        let scope = TestURLProtocol.routeScope { request in
            if request.httpMethod == "PUT" {
                let sent = Self.body(request)
                puts.withLock { $0.append(sent) }
            }
            let body: String? = switch request.url?.path ?? "" {
            case "/pins": Self.pins
            case "/host/contents", "/host/contents/": Self.home
            default: nil
            }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (Data((body ?? #"{"error":"Not found"}"#).utf8), response)
        }
        let client = makeTestURLProtocolClient()
        let serverId = "sha256:pins-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: client)
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.setSplitStreamCapabilitiesForTesting(pins: true)
        await connection.pins.refresh(api: client)
        return (root, serverId, scope)
    }

    private static func cell(_ identifier: String, in view: UIView) -> UICollectionViewListCell? {
        view.allSubviews.compactMap { $0 as? UICollectionViewListCell }
            .first { $0.accessibilityIdentifier == identifier && $0.window != nil && !$0.isHidden }
    }

    /// At 320 pt and the largest accessibility text: the section lists every pin,
    /// a missing one reads "Not found", and a row's menu offers Pin or Unpin by
    /// whether its folder is pinned.
    @Test func homeRootListsPinsAtTheNarrowestWidthAndLargestText() async throws {
        let server = try await Self.makeServer()
        defer { server.scope.end() }
        let files = FileBrowserViewController(
            root: server.root,
            target: FileBrowserNavTarget(serverId: server.serverId, scope: .hostHome, path: ""),
            showsSidebarToggle: false
        )
        let navigation = UINavigationController(rootViewController: files)
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 2_400))
        window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        let shown = await waitForMainActorCondition(timeout: .seconds(5)) {
            window.layoutIfNeeded()
            return Self.cell("fileBrowser.pin.~/Desktop/old-plan", in: window) != nil
        }
        #expect(shown, "the Pinned section shows the server's pins")
        for key in ["~/notebook", "~/Documents/reports", "~/Books/The Left Hand of Darkness.epub"] {
            let cell = try #require(Self.cell("fileBrowser.pin.\(key)", in: window), "\(key) has a row")
            #expect(cell.frame.width <= 320, "\(key) stays inside 320 pt")
        }
        let reports = try #require(Self.cell("fileBrowser.pin.~/Documents/reports", in: window))
        #expect(reports.accessibilityLabel?.hasPrefix("Weekly reports") == true, "a label replaces the folder name")
        let missing = try #require(Self.cell("fileBrowser.pin.~/Desktop/old-plan", in: window))
        #expect(missing.accessibilityLabel == "old-plan, Not found")
        // The largest text grows the row past its default height and still wraps inside it.
        let content = try #require(missing.contentView as? UIListContentView)
        #expect(missing.frame.height > 80, "the row grows with the text (\(missing.frame.height) pt)")
        #expect(content.frame.maxX <= missing.bounds.maxX)

        let section = try #require(files.pinsSection)
        #expect((section.rowMenuElement(rowPath: "notebook/") as? UIAction)?.title == "Unpin")
        #expect((section.rowMenuElement(rowPath: "Books/") as? UIAction)?.title == "Pin")
        let pinFolder = section.viewOptionsElements().compactMap { ($0 as? UIMenu)?.children.first as? UIAction }.first
        #expect(pinFolder?.title == "Pin This Folder", "Home itself is not pinned")
        // The screen's own reads (its appearance refresh) finish before the handler goes.
        _ = await server.scope.settle()
    }

    /// Edit mode moves a pin among the pins only, and Done saves the new
    /// order in one write.
    @Test func editModeSavesTheMovedOrderOnce() async throws {
        let puts = OSAllocatedUnfairLock(initialState: [Data]())
        let server = try await Self.makeServer(puts: puts)
        defer { server.scope.end() }
        let files = FileBrowserViewController(
            root: server.root,
            target: FileBrowserNavTarget(serverId: server.serverId, scope: .hostHome, path: ""),
            showsSidebarToggle: false
        )
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 1_400))
        window.rootViewController = UINavigationController(rootViewController: files)
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }
        let shown = await waitForMainActorCondition(timeout: .seconds(5)) {
            window.layoutIfNeeded()
            return Self.cell("fileBrowser.pin.~/Desktop/old-plan", in: window) != nil
        }
        #expect(shown, "the Pinned section shows")
        let edit = try #require(window.allSubviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "fileBrowser.pinned.edit" })
        let list = try #require(window.allSubviews.compactMap { $0 as? UICollectionView }.first)

        edit.sendActions(for: .primaryActionTriggered)
        #expect(list.isEditing)
        #expect(files.pinsSection?.isEditing == true)
        // A move onto the header row lands below it.
        let moved = list.delegate?.collectionView?(
            list, targetIndexPathForMoveOfItemFromOriginalIndexPath: IndexPath(item: 1, section: 0),
            atCurrentIndexPath: IndexPath(item: 1, section: 0), toProposedIndexPath: IndexPath(item: 0, section: 0)
        )
        #expect(moved == IndexPath(item: 1, section: 0))
        // Notebook, the first pin, goes last.
        list.dataSource?.collectionView?(list, moveItemAt: IndexPath(item: 1, section: 0), to: IndexPath(item: 4, section: 0))
        #expect(puts.withLock { $0.isEmpty }, "nothing is saved before Done")
        edit.sendActions(for: .primaryActionTriggered)

        let saved = await waitForMainActorCondition(timeout: .seconds(5)) { puts.withLock { $0.count } == 1 }
        #expect(saved, "Done saves once")
        struct Sent: Decodable {
            struct Entry: Decodable { let id: String }
            let baseRevision: Int
            let pins: [Entry]
        }
        let sent = try JSONDecoder().decode(Sent.self, from: try #require(puts.withLock { $0.first }))
        #expect(sent.baseRevision == 4)
        #expect(sent.pins.map(\.id) == ["pin_Reports00002", "pin_Book00000003", "pin_OldPlan00004", "pin_Notebook0001"])
        #expect(!list.isEditing)
        _ = await server.scope.settle()
    }

    /// A workspace folder pin (or link) names its folder without the slash;
    /// the browser it opens lists that folder, whose rows join onto `reports/`.
    @Test func aWorkspaceFolderEntryOpensItsFolder() async throws {
        let serverId = "sha256:pins-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: makeTestURLProtocolClient())
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.workspaceStore.upsert(makeTestWorkspace(id: "ws-1", name: "garden-site"), serverId: serverId)
        let entry = PaneStackEntry(serverId: serverId, route: .files(workspace: "ws-1", path: "reports"))
        guard case .fileBrowser(let target)? = PaneEntries.element(for: entry, coordinator: root.coordinator) else {
            Issue.record("the entry opens no File Browser")
            return
        }
        #expect(target.path == "reports/")
    }

    /// The launcher's Pinned group opens a pinned Home folder as that
    /// folder's File Browser.
    @Test func launcherOpensAPinnedHomeFolder() async throws {
        let server = try await Self.makeServer()
        defer { server.scope.end() }
        var chosen: PaneStackEntry?
        let launcher = PaneLauncherViewController(serverId: server.serverId, workspaceId: nil, root: server.root) { chosen = $0 }
        let window = makeTestWindow(frame: CGRect(x: 0, y: 0, width: 744, height: 1_133))
        window.rootViewController = launcher
        window.makeKeyAndVisible()
        defer { hideTestWindow(window) }

        var button: UIButton?
        let shown = await waitForMainActorCondition(timeout: .seconds(5)) {
            launcher.setNeedsUpdateProperties()
            launcher.updatePropertiesIfNeeded()
            window.layoutIfNeeded()
            button = window.allSubviews.compactMap { $0 as? UIButton }
                .first { $0.accessibilityIdentifier == "pane.launcher.pin.~/notebook" }
            return button != nil
        }
        #expect(shown, "the launcher lists the pins")
        let missing = window.allSubviews.compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "pane.launcher.pin.~/Desktop/old-plan" }
        #expect(missing?.isEnabled == false, "a missing pin cannot open")

        try #require(button).sendActions(for: .primaryActionTriggered)
        let entry = try #require(chosen)
        #expect(entry == PaneStackEntry(serverId: server.serverId, route: .hostFiles(path: "~/notebook")))
        guard case .fileBrowser(let target)? = PaneEntries.element(for: entry, coordinator: server.root.coordinator) else {
            Issue.record("the entry opens no File Browser")
            return
        }
        #expect(target.scope == .hostHome)
        #expect(target.path == "notebook/")
        _ = await server.scope.settle()
    }
}

private extension UIView {
    /// This view and every view under it.
    var allSubviews: [UIView] {
        [self] + subviews.flatMap(\.allSubviews)
    }
}
