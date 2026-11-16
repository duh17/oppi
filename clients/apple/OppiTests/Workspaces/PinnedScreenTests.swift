import Foundation
import os
import Testing
import UIKit
@testable import Oppi

/// The Pinned screen in the real workspace shell (the iPad mini's split
/// layout and the iPhone's drawer), and the session rows' Pin and Unpin, over
/// a server that keeps pins.
@Suite("Pinned screen", .serialized)
@MainActor
struct PinnedScreenTests {
    private nonisolated static func place(_ id: String, _ path: String, _ kind: String, _ status: String, label: String? = nil) -> String {
        let label = label.map { #","label":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","target":{"origin":"host","path":"\#(path)"},"kind":"\#(kind)","createdAt":1,"status":"\#(status)"\#(label)}"#
    }

    private nonisolated static func session(_ id: String, _ sessionId: String, _ status: String) -> String {
        #"{"id":"\#(id)","target":{"origin":"session","sessionId":"\#(sessionId)"},"kind":"session","createdAt":1,"status":"\#(status)"}"#
    }

    /// Saved in a mixed order; the screen groups them.
    private nonisolated static let pins: String = {
        let pins = [
            place("pin_Notebook0001", "~/notebook", "directory", "ok"),
            session("pin_Release00002", "sess-release", "ok"),
            place("pin_Book00000003", "~/Books/The Left Hand of Darkness.epub", "file", "ok"),
            place("pin_OldPlan00004", "~/Desktop/old-plan", "directory", "missing"),
            session("pin_OldChat00005", "sess-deleted", "missing"),
            session("pin_Review000006", "sess-review", "ok"),
        ]
        return #"{"revision":6,"pins":[\#(pins.joined(separator: ","))]}"#
    }()

    /// The shell over a server whose pins answer; everything else is a 404.
    /// `requests` records every pins write as `METHOD body`.
    private static func makeShell(
        size: CGSize,
        regular: Bool,
        pinsAvailable: Bool = true,
        requests: OSAllocatedUnfairLock<[String]> = OSAllocatedUnfairLock(initialState: [])
    ) async throws -> ShellWindow {
        let scope = TestURLProtocol.routeScope { request in try Self.answer(request, requests: requests) }
        let client = makeTestURLProtocolClient()
        let serverId = "sha256:pinned-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: client)
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.setSplitStreamCapabilitiesForTesting(pins: pinsAvailable)
        connection.sessionStore.upsert(makeTestSession(id: "sess-release", name: "Write the release notes", status: .busy))
        connection.sessionStore.upsert(makeTestSession(id: "sess-review", name: "Review the pins change", status: .ready))
        if pinsAvailable { await connection.pins.refresh(api: client) }
        return try ShellWindow(root: root, serverId: serverId, scope: scope, size: size, regular: regular)
    }

    /// The server's side: `/pins` answers the list (a POST adds the added
    /// pin's id); everything else is a 404. Runs off the main actor.
    private nonisolated static func answer(
        _ request: URLRequest,
        requests: OSAllocatedUnfairLock<[String]>
    ) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        if url.path == "/pins", request.httpMethod != "GET" {
            let body = String(decoding: Self.body(request), as: UTF8.self)
            requests.withLock { $0.append("\(request.httpMethod ?? "") \(body)") }
        }
        var body: String? = url.path == "/pins" ? Self.pins : nil
        if request.httpMethod == "POST" {
            body = body?.replacingOccurrences(of: #"{"revision""#, with: #"{"pinId":"pin_Release00002","revision""#)
        }
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data((body ?? #"{"error":"Not found"}"#).utf8), response)
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

    // MARK: The sidebar's Pinned row

    /// Pinned leads the sidebar's destinations and opens the screen in the
    /// detail column; the sidebar lists no pins of its own.
    @Test func theSidebarsPinnedRowOpensTheScreen() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 744), regular: true)
        defer { shell.end() }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.element("workspace.pinned.open", in: sidebar) != nil })
        let order = shell.elementOrder(in: sidebar)
        #expect(order.first == "workspace.pinned.open", "Pinned comes first: \(order)")
        #expect(!order.contains { $0.contains(".pin.") }, "the sidebar lists no pins: \(order)")

        try #require(shell.element("workspace.pinned.open", in: sidebar)).sendActions(for: .touchUpInside)
        #expect(await shell.settles { shell.pinned != nil }, "the Pinned screen shows")
        #expect(shell.root.navigation.workspaceStackRouteElements == [.utility(.pinned)])
        _ = await shell.scope.settle()
    }

    @Test func aServerWithoutPinsShowsNoPinnedRow() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 744), regular: true, pinsAvailable: false)
        defer { shell.end() }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.element("workspace.agents.open", in: sidebar) != nil })
        #expect(shell.element("workspace.pinned.open", in: sidebar) == nil)
        _ = await shell.scope.settle()
    }

    // MARK: The screen

    /// Sessions, Folders, Files, each in its saved order. A session this
    /// device has draws as its session row (its live status included); a
    /// deleted one reads Not found.
    @Test func theScreenGroupsSessionsFoldersAndFiles() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 900), regular: true)
        defer { shell.end() }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.items(in: .files) == ["pin_Book00000003"] })

        let screen = try #require(shell.pinned)
        let list = try #require(shell.list(in: screen))
        #expect(list.numberOfSections == 3)
        #expect(shell.items(in: .sessions) == ["pin_Release00002", "pin_OldChat00005", "pin_Review000006"])
        #expect(shell.items(in: .folders) == ["pin_Notebook0001", "pin_OldPlan00004"])

        let release = try #require(shell.cell("pin_Release00002"))
        #expect(release.contentConfiguration is SessionListEntryConfiguration, "a live session is its session row")
        #expect(shell.descendants(of: release).contains { $0.accessibilityIdentifier == "session.nav.sess-release" })
        let deleted = try #require(shell.cell("pin_OldChat00005"))
        #expect(!(deleted.contentConfiguration is SessionListEntryConfiguration))
        #expect(deleted.accessibilityLabel == "Session, Not found")
        let missingFolder = try #require(shell.cell("pin_OldPlan00004"))
        #expect(missingFolder.accessibilityLabel == "old-plan, Not found")
        let book = try #require(shell.cell("pin_Book00000003"))
        #expect(book.accessibilityLabel == "The Left Hand of Darkness.epub, Home \u{203A} Books")
        _ = await shell.scope.settle()
    }

    /// In Edit, a pin moves only within its group.
    @Test func editMovesAPinOnlyWithinItsGroup() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 900), regular: true)
        defer { shell.end() }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.items(in: .files) == ["pin_Book00000003"] })
        let screen = try #require(shell.pinned)
        let list = try #require(shell.list(in: screen))
        let edit = try #require(screen.navigationItem.rightBarButtonItems?.first { $0.accessibilityIdentifier == "pinned.edit" })
        edit.primaryAction?.performWithSender(nil, target: nil)
        #expect(await shell.settles { list.isEditing }, "Edit puts the list in edit mode")
        #expect(edit.title == "Done")

        let delegate = try #require(list.delegate)
        let session = IndexPath(item: 0, section: 0)
        let intoFolders = delegate.collectionView?(list, targetIndexPathForMoveOfItemFromOriginalIndexPath: session,
                                                   atCurrentIndexPath: session, toProposedIndexPath: IndexPath(item: 1, section: 1))
        #expect(intoFolders == IndexPath(item: 2, section: 0), "a session dropped among the folders stays last among the sessions")
        let within = delegate.collectionView?(list, targetIndexPathForMoveOfItemFromOriginalIndexPath: session,
                                              atCurrentIndexPath: session, toProposedIndexPath: IndexPath(item: 2, section: 0))
        #expect(within == IndexPath(item: 2, section: 0))

        edit.primaryAction?.performWithSender(nil, target: nil)
        #expect(await shell.settles { !list.isEditing })
        _ = await shell.scope.settle()
    }

    /// A pinned session opens its chat as a session link does, over the screen.
    @Test func aTappedSessionPinOpensItsChat() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 900), regular: true)
        defer { shell.end() }
        var opened: [AppOpenRequest] = []
        shell.root.opener._openRequestObserverForTesting = { request in
            opened.append(request)
            return true
        }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.cell("pin_Review000006") != nil })

        try shell.tap("pin_Review000006")
        #expect(opened == [.session(SessionOpen(serverId: shell.serverId, sessionId: "sess-review", origin: .inAppHyperlink))])
        _ = await shell.scope.settle()
    }

    /// A deleted session opens nothing: its tap offers Remove Pin.
    @Test func aDeletedSessionOffersRemoval() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 900), regular: true)
        defer { shell.end() }
        var opened: [AppOpenRequest] = []
        shell.root.opener._openRequestObserverForTesting = { request in
            opened.append(request)
            return true
        }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.cell("pin_OldChat00005") != nil })

        try shell.tap("pin_OldChat00005")
        var alert: UIAlertController?
        _ = await shell.settles {
            alert = shell.controller.presentedViewController as? UIAlertController
            return alert != nil
        }
        #expect(alert?.message == "The session was deleted.")
        #expect(alert?.actions.map(\.title) == ["Remove Pin", "Cancel"])
        #expect(opened.isEmpty, "nothing opens")
        alert?.dismiss(animated: false)
        _ = await shell.scope.settle()
    }

    /// On a wide window a pinned folder opens beside the main pane, as a pane
    /// link does, and the main pane keeps the Pinned screen.
    @Test func aTappedFolderOpensBesideTheMainPaneOnAWideWindow() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 744), regular: true)
        defer { shell.end() }
        let panes = shell.root.navigation.panes
        panes.splitsEnabled = true
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.cell("pin_Notebook0001") != nil })

        try shell.tap("pin_Notebook0001")
        let opened = await shell.settles {
            panes.splitLeaves.contains { panes.topEntry(of: $0.id).route == .hostFiles(path: "~/notebook") }
        }
        #expect(opened, "a pane beside shows ~/notebook: \(panes.splitLeaves.map { panes.topEntry(of: $0.id).route })")
        #expect(shell.root.navigation.workspaceStackRouteElements == [.utility(.pinned)], "the main pane keeps Pinned")
        _ = await shell.scope.settle()
    }

    /// On iPhone the drawer's Pinned row pushes the screen, and a pinned
    /// folder opens in the main stack as the File Browser at that folder.
    @Test func onIPhoneTheDrawerOpensPinnedAndAFolderOpensInTheStack() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 402, height: 874), regular: false)
        defer { shell.end() }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.element("workspace.pinned.open", in: sidebar) != nil }, "the drawer offers Pinned")
        try #require(shell.element("workspace.pinned.open", in: sidebar)).sendActions(for: .touchUpInside)
        #expect(await shell.settles { shell.cell("pin_Notebook0001") != nil })

        try shell.tap("pin_Notebook0001")
        let target = FileBrowserNavTarget(serverId: shell.serverId, scope: .hostHome, path: "notebook/")
        #expect(await shell.settles { shell.root.navigation.workspaceStackRouteElements.last == .fileBrowser(target) },
                "the File Browser at ~/notebook: \(shell.root.navigation.workspaceStackRouteElements)")
        _ = await shell.scope.settle()
    }

    // MARK: Pin and Unpin on session rows

    /// A session row's menu and swipe say Pin for a session not pinned, and
    /// Pin saves that one session; a pinned one says Unpin, which removes it.
    @Test func aSessionRowPinsAndUnpinsItsSession() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let shell = try await Self.makeShell(size: CGSize(width: 402, height: 874), regular: false, requests: requests)
        defer { shell.end() }
        let connection = try #require(shell.root.coordinator.connection(for: shell.serverId))
        let view = shell.controller.view!
        let actions = SessionListRowActions(
            open: { _ in }, toggleThread: { _ in }, toggleStoppedMembers: { _ in },
            stop: { _ in }, resume: { _ in }, delete: { _ in nil }, lockTarget: { _ in nil },
            pin: { PinMenu.sessionRowToggle($0, connection: connection, view: view) }
        )
        let palette = ThemeID.dark.palette

        let other = makeTestSession(id: "sess-other", name: "Not pinned", status: .ready)
        let menu = SessionListRowMenus.menu(for: other, actions: actions, in: view)
        let pin = try #require(Self.actions(in: menu).first { $0.accessibilityIdentifier == "session.pin.sess-other" })
        #expect(pin.title == "Pin")
        let swipe = SessionListRowMenus.trailingSwipe(for: other, actions: actions, palette: palette)
        #expect(swipe.actions.map(\.title) == ["Stop", "Pin"], "Stop stays the full swipe")
        pin.performWithSender(nil, target: nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { requests.withLock { !$0.isEmpty } })
        let post = try #require(requests.withLock { $0.first })
        #expect(post.hasPrefix("POST "))
        let body = try JSONSerialization.jsonObject(with: Data(post.dropFirst(5).utf8)) as? NSDictionary
        #expect(body == ["target": ["origin": "session", "sessionId": "sess-other"]] as NSDictionary)

        let pinned = try #require(connection.sessionStore.session(id: "sess-release"))
        let unpin = try #require(Self.actions(in: SessionListRowMenus.menu(for: pinned, actions: actions, in: view))
            .first { $0.accessibilityIdentifier == "session.unpin.sess-release" })
        #expect(unpin.title == "Unpin")
        unpin.performWithSender(nil, target: nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { requests.withLock { $0.count == 2 } })
        let put = try #require(requests.withLock { $0.last })
        #expect(put.hasPrefix("PUT "))
        #expect(!put.contains("pin_Release00002") && put.contains("pin_Review000006"), "only that session's pin goes: \(put)")
        _ = await shell.scope.settle()
    }

    /// The chat's … menu names the session: Pin Session, or Unpin Session once pinned.
    @Test func theChatMenuSaysPinSessionOrUnpinSession() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 402, height: 874), regular: false)
        defer { shell.end() }
        let connection = try #require(shell.root.coordinator.connection(for: shell.serverId))
        let api = try #require(connection.apiClient)
        let view = shell.controller.view!
        let pinned = PinMenu.sessionToggle(sessionId: "sess-release", namesSession: true, pins: connection.pins, api: api, view: view)
        #expect((pinned.title, pinned.identifier) == ("Unpin Session", "chat.toolbar.menu.unpin"))
        let other = PinMenu.sessionToggle(sessionId: "sess-other", namesSession: true, pins: connection.pins, api: api, view: view)
        #expect((other.title, other.identifier) == ("Pin Session", "chat.toolbar.menu.pin"))
        _ = await shell.scope.settle()
    }

    private static func actions(in menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let menu = element as? UIMenu { return actions(in: menu) }
            return []
        }
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
        root.navigation.panes.preferences = UserDefaults(suiteName: "PinnedScreenTests-\(UUID().uuidString)") ?? .standard
        root.navigation.window = window
        root.opener.launchDidFinish()
        controller = WorkspaceShellController(root: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
    }

    /// The shell's sidebar: the split's primary column, or the drawer's.
    var sidebar: WorkspaceSidebarViewController? {
        Self.first(WorkspaceSidebarViewController.self, in: controller)
    }

    var pinned: PinnedViewController? {
        Self.first(PinnedViewController.self, in: controller)
    }

    /// The sidebar row button with `identifier`, on screen.
    func element(_ identifier: String, in sidebar: WorkspaceSidebarViewController) -> SidebarRowElement? {
        sidebarCells(sidebar).map(\.element).first { $0.accessibilityIdentifier == identifier && !$0.isHidden }
    }

    /// Sidebar row identifiers from top to bottom.
    func elementOrder(in sidebar: WorkspaceSidebarViewController) -> [String] {
        sidebarCells(sidebar).sorted { $0.frame.minY < $1.frame.minY }.compactMap {
            $0.element.isHidden ? $0.accessibilityIdentifier : $0.element.accessibilityIdentifier
        }
    }

    func list(in screen: PinnedViewController) -> UICollectionView? {
        descendants(of: screen.view).compactMap { $0 as? UICollectionView }.first { $0.accessibilityIdentifier == "pinned.list" }
    }

    /// The pin ids the Pinned screen lists in `group`.
    func items(in group: PinnedViewController.Group) -> [String] {
        guard let screen = pinned, let list = list(in: screen),
              let source = list.dataSource as? UICollectionViewDiffableDataSource<PinnedViewController.Group, String>,
              source.snapshot().sectionIdentifiers.contains(group) else { return [] }
        return source.snapshot().itemIdentifiers(inSection: group)
    }

    /// The Pinned screen's cell for pin `id`, on screen.
    func cell(_ id: String) -> UICollectionViewListCell? {
        guard let screen = pinned, let list = list(in: screen),
              let source = list.dataSource as? UICollectionViewDiffableDataSource<PinnedViewController.Group, String>,
              let indexPath = source.indexPath(for: id) else { return nil }
        return list.cellForItem(at: indexPath) as? UICollectionViewListCell
    }

    /// A tap on a pin row, as the list delivers it.
    func tap(_ id: String) throws {
        let screen = try #require(pinned)
        let list = try #require(list(in: screen))
        let cell = try #require(cell(id))
        let indexPath = try #require(list.indexPath(for: cell))
        list.delegate?.collectionView?(list, didSelectItemAt: indexPath)
    }

    private func sidebarCells(_ sidebar: WorkspaceSidebarViewController) -> [SidebarListCell] {
        guard let list = descendants(of: sidebar.view).compactMap({ $0 as? UICollectionView })
            .first(where: { $0.accessibilityIdentifier == "workspace.sidebar.scroll" }) else { return [] }
        return list.visibleCells.compactMap { $0 as? SidebarListCell }.filter { !$0.isHidden }
    }

    /// Lays the window out until `condition` holds.
    func settles(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            controller.updatePropertiesIfNeeded()
            sidebar?.loadViewIfNeeded()
            sidebar?.updatePropertiesIfNeeded()
            pinned?.updatePropertiesIfNeeded()
            window.layoutIfNeeded()
            sidebar?.view.layoutIfNeeded()
            pinned?.view.layoutIfNeeded()
            return condition()
        }
    }

    func end() {
        hideTestWindow(window)
        window.rootViewController = nil
        scope.end()
    }

    func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private static func first<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        (controller as? T) ?? (controller.presentedViewController.flatMap { first(type, in: $0) })
            ?? controller.children.lazy.compactMap { first(type, in: $0) }.first
    }
}
