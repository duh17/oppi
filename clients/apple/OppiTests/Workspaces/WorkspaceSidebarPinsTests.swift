import Foundation
import os
import Testing
import UIKit
@testable import Oppi

/// The sidebar's Pinned section in the real workspace shell: the iPad mini's
/// split sidebar and the iPhone's drawer, over a server that keeps pins.
@Suite("Sidebar pins", .serialized)
@MainActor
struct WorkspaceSidebarPinsTests {
    private nonisolated static func pin(_ id: String, _ path: String, _ kind: String, _ status: String, label: String? = nil) -> String {
        let label = label.map { #","label":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","target":{"origin":"host","path":"\#(path)"},"kind":"\#(kind)","createdAt":1,"status":"\#(status)"\#(label)}"#
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

    /// A landscape window tall enough that the sidebar's list shows every row
    /// without scrolling, so a row's cell exists to be found.
    private static let tallLandscape = CGSize(width: 1400, height: 1100)

    /// The shell over a server whose pins answer; everything else is a 404.
    /// `pinReads` counts every `GET /pins`.
    private static func makeShell(
        size: CGSize,
        regular: Bool,
        pinsAvailable: Bool = true,
        pinReads: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)
    ) async throws -> ShellWindow {
        let scope = TestURLProtocol.routeScope { request in
            let url = try #require(request.url)
            if url.path == "/pins", request.httpMethod == "GET" { pinReads.withLock { $0 += 1 } }
            let body: String? = url.path == "/pins" ? Self.pins : nil
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (Data((body ?? #"{"error":"Not found"}"#).utf8), response)
        }
        let client = makeTestURLProtocolClient()
        let serverId = "sha256:sidebar-pins-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: client)
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.setSplitStreamCapabilitiesForTesting(pins: pinsAvailable)
        await connection.pins.refresh(api: client)
        FileBrowserViewOptionsStore.shared.setSidebarPinsCollapsed(false)
        return try ShellWindow(root: root, serverId: serverId, scope: scope, size: size, regular: regular)
    }

    /// Between the destinations and Workspaces, the section lists every pin
    /// with its breadcrumb; a missing one reads "Not found". The header
    /// collapses it, and that is remembered on the device.
    @Test func theSplitSidebarListsEveryPinAndCollapses() async throws {
        let shell = try await Self.makeShell(size: Self.tallLandscape, regular: true)
        defer { shell.end() }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.pin("~/Desktop/old-plan", in: sidebar) != nil },
                "the section shows the server's pins: \(shell.elementOrder(in: sidebar))")

        let order = shell.elementOrder(in: sidebar)
        let header = try #require(order.firstIndex(of: "workspace.sidebar.pinned.header"))
        let notebook = try #require(order.firstIndex(of: "workspace.sidebar.pin.~/notebook"))
        let disclosure = try #require(order.firstIndex(of: "workspace.sidebar.disclosure"))
        #expect(order.prefix(header).allSatisfy { !$0.hasPrefix("workspace.sidebar.pin") }, "the destinations come first")
        #expect(header < notebook && notebook < disclosure, "the pins sit above Workspaces: \(order)")
        #expect(order.filter { $0.hasPrefix("workspace.sidebar.pin.") }.count == 4)

        let reports = try #require(shell.pin("~/Documents/reports", in: sidebar))
        #expect(reports.accessibilityLabel == "Weekly reports, Home \u{203A} Documents")
        #expect(reports.isAccessibilityElement && reports.accessibilityTraits.contains(.button), "the row is its own button element")
        let book = try #require(shell.pin("~/Books/The Left Hand of Darkness.epub", in: sidebar))
        #expect(book.accessibilityLabel == "The Left Hand of Darkness.epub, Home \u{203A} Books")
        let missing = try #require(shell.pin("~/Desktop/old-plan", in: sidebar))
        #expect(missing.accessibilityLabel == "old-plan, Not found")

        try #require(shell.element("workspace.sidebar.pinned.header", in: sidebar)).sendActions(for: .touchUpInside)
        #expect(await shell.settles { shell.pin("~/notebook", in: sidebar) == nil }, "collapsed")
        #expect(FileBrowserViewOptionsStore.shared.sidebarPinsCollapsed, "kept on the device")
        #expect(shell.element("workspace.sidebar.pinned.header", in: sidebar)?.accessibilityValue == "Collapsed")

        try #require(shell.element("workspace.sidebar.pinned.header", in: sidebar)).sendActions(for: .touchUpInside)
        #expect(await shell.settles { shell.pin("~/notebook", in: sidebar) != nil }, "expanded")
        #expect(!FileBrowserViewOptionsStore.shared.sidebarPinsCollapsed)
        _ = await shell.scope.settle()
    }

    /// A server without pins shows no section.
    @Test func aServerWithoutPinsShowsNoSection() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 744), regular: true, pinsAvailable: false)
        defer { shell.end() }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.element("workspace.sidebar.disclosure", in: sidebar) != nil })
        #expect(!shell.elementOrder(in: sidebar).contains { $0.hasPrefix("workspace.sidebar.pin") })
        _ = await shell.scope.settle()
    }

    /// On a wide window a tapped pin opens beside the main pane, as a pane
    /// link does, and the main pane keeps what it showed.
    @Test func aTappedPinOpensBesideTheMainPaneOnAWideWindow() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 744), regular: true)
        defer { shell.end() }
        let panes = shell.root.navigation.panes
        panes.splitsEnabled = true
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.pin("~/notebook", in: sidebar) != nil })

        try shell.tapPin("~/notebook", in: sidebar)
        let opened = await shell.settles {
            panes.splitLeaves.contains { panes.topEntry(of: $0.id).route == .hostFiles(path: "~/notebook") }
        }
        #expect(opened, "a pane beside shows ~/notebook: \(panes.splitLeaves.map { panes.topEntry(of: $0.id).route })")
        #expect(!shell.root.navigation.workspaceStackRouteElements.contains { if case .fileBrowser = $0 { true } else { false } },
                "the main pane keeps its screen")
        _ = await shell.scope.settle()
    }

    /// On iPhone the drawer's pin opens in the main stack, as the File
    /// Browser at that folder, and the drawer closes.
    @Test func aTappedPinOpensInTheMainStackFromTheDrawer() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 402, height: 874), regular: false)
        defer { shell.end() }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.pin("~/notebook", in: sidebar) != nil }, "the drawer lists the pins")

        try shell.tapPin("~/notebook", in: sidebar)
        let target = FileBrowserNavTarget(serverId: shell.serverId, scope: .hostHome, path: "notebook/")
        #expect(await shell.settles { shell.root.navigation.workspaceStackRouteElements.last == .fileBrowser(target) },
                "the File Browser at ~/notebook: \(shell.root.navigation.workspaceStackRouteElements)")
        _ = await shell.scope.settle()
    }

    /// The drawer's sidebar never appears again after it loads, and a pinned
    /// place deleted on disk sends no event: opening the drawer reads the
    /// pins again, so a moved folder shows Not found.
    @Test func openingTheDrawerReadsThePinsAgain() async throws {
        let pinReads = OSAllocatedUnfairLock(initialState: 0)
        let shell = try await Self.makeShell(size: CGSize(width: 402, height: 874), regular: false, pinReads: pinReads)
        defer { shell.end() }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.pin("~/notebook", in: sidebar) != nil })
        _ = await shell.scope.settle()
        let drawer = try #require(shell.drawer)
        let before = pinReads.withLock { $0 }

        drawer.toggleSidebar()
        #expect(drawer.isSidebarOpen)
        let read = await waitForMainActorCondition(timeout: .seconds(3)) { pinReads.withLock { $0 } > before }
        #expect(read, "opening the drawer reads the pins again")

        // Closing reads nothing.
        _ = await shell.scope.settle()
        let afterOpen = pinReads.withLock { $0 }
        drawer.toggleSidebar()
        _ = await shell.scope.settle()
        #expect(pinReads.withLock { $0 } == afterOpen)
    }

    /// A missing pin opens nothing: its tap offers Remove Pin.
    @Test func aMissingPinOffersRemovalInsteadOfOpening() async throws {
        let shell = try await Self.makeShell(size: Self.tallLandscape, regular: true)
        defer { shell.end() }
        var opened: [AppOpenRequest] = []
        shell.root.opener._openRequestObserverForTesting = { request in
            opened.append(request)
            return true
        }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.pin("~/Desktop/old-plan", in: sidebar) != nil })

        try shell.tapPin("~/Desktop/old-plan", in: sidebar)
        var alert: UIAlertController?
        _ = await shell.settles {
            alert = shell.controller.presentedViewController as? UIAlertController
            return alert != nil
        }
        #expect(alert?.actions.map(\.title) == ["Remove Pin", "Cancel"], "the missing pin asks to remove it")
        #expect(opened.isEmpty, "nothing opens")
        alert?.dismiss(animated: false)
        _ = await shell.scope.settle()
    }
}

/// The real workspace shell in a window of its own: the split layout at a
/// regular width, the drawer at a compact one.
@MainActor
private struct ShellWindow {
    let root: AppRootEnvironment
    let serverId: String
    let scope: TestURLProtocol.RouteScope
    let window: UIWindow
    let controller: WorkspaceShellController

    init(root: AppRootEnvironment, serverId: String, scope: TestURLProtocol.RouteScope, size: CGSize, regular: Bool) throws {
        self.root = root
        self.serverId = serverId
        self.scope = scope
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.traitOverrides.horizontalSizeClass = regular ? .regular : .compact
        window.traitOverrides.verticalSizeClass = .regular
        window.traitOverrides.appRootEnvironment = root
        // New Panes settings of the test's own: the simulator's saved sides never reach it.
        root.navigation.panes.preferences = UserDefaults(suiteName: "WorkspaceSidebarPinsTests-\(UUID().uuidString)") ?? .standard
        root.navigation.window = window
        root.opener.launchDidFinish()
        controller = WorkspaceShellController(root: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    /// The compact shell's drawer.
    var drawer: WorkspaceDrawerController? {
        Self.first(WorkspaceDrawerController.self, in: controller)
    }

    /// The shell's sidebar: the split's primary column, or the drawer's.
    var sidebar: WorkspaceSidebarViewController? {
        Self.first(WorkspaceSidebarViewController.self, in: controller)
    }

    /// The row button with `identifier`, on screen.
    func element(_ identifier: String, in sidebar: WorkspaceSidebarViewController) -> SidebarRowElement? {
        cells(in: sidebar).map(\.element).first { $0.accessibilityIdentifier == identifier && !$0.isHidden }
    }

    /// The pin row for Home path `key`, on screen: a list cell that is its own element.
    func pin(_ key: String, in sidebar: WorkspaceSidebarViewController) -> SidebarListCell? {
        cells(in: sidebar).first { $0.isAccessibilityElement && $0.accessibilityIdentifier == "workspace.sidebar.pin.\(key)" }
    }

    /// A tap on a pin row, as the list delivers it: it may select, then it selects.
    func tapPin(_ key: String, in sidebar: WorkspaceSidebarViewController) throws {
        let list = try #require(list(in: sidebar))
        let cell = try #require(pin(key, in: sidebar))
        let indexPath = try #require(list.indexPath(for: cell))
        try #require(list.delegate?.collectionView?(list, shouldSelectItemAt: indexPath) == true, "a pin row selects")
        list.delegate?.collectionView?(list, didSelectItemAt: indexPath)
    }

    /// Row identifiers from top to bottom: a button row's button, a pin row's cell.
    func elementOrder(in sidebar: WorkspaceSidebarViewController) -> [String] {
        cells(in: sidebar).sorted { $0.frame.minY < $1.frame.minY }.compactMap {
            $0.element.isHidden ? $0.accessibilityIdentifier : $0.element.accessibilityIdentifier
        }
    }

    private func list(in sidebar: WorkspaceSidebarViewController) -> UICollectionView? {
        Self.descendants(of: sidebar.view).compactMap { $0 as? UICollectionView }
            .first { $0.accessibilityIdentifier == "workspace.sidebar.scroll" }
    }

    private func cells(in sidebar: WorkspaceSidebarViewController) -> [SidebarListCell] {
        guard let list = list(in: sidebar) else { return [] }
        return list.visibleCells.compactMap { $0 as? SidebarListCell }.filter { !$0.isHidden }
    }

    /// Lays the window out until `condition` holds.
    func settles(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            controller.updatePropertiesIfNeeded()
            sidebar?.loadViewIfNeeded()
            sidebar?.updatePropertiesIfNeeded()
            window.layoutIfNeeded()
            sidebar?.view.layoutIfNeeded()
            return condition()
        }
    }

    func end() {
        FileBrowserViewOptionsStore.shared.setSidebarPinsCollapsed(false)
        hideTestWindow(window)
        window.rootViewController = nil
        scope.end()
    }

    private static func first<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        (controller as? T) ?? controller.children.lazy.compactMap { first(type, in: $0) }.first
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
