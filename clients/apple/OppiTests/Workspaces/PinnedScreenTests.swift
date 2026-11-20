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
        let target = kind == "directory"
            ? #"{"kind":"files","origin":"host","path":"\#(path)"}"#
            : #"{"kind":"file","origin":"host","path":"\#(path)","line":null}"#
        return route(id, target, status, extra: label)
    }

    private nonisolated static func session(_ id: String, _ sessionId: String, _ status: String) -> String {
        route(id, #"{"kind":"session","id":"\#(sessionId)"}"#, status)
    }

    private nonisolated static func route(_ id: String, _ target: String, _ status: String, extra: String = "") -> String {
        #"{"id":"\#(id)","target":\#(target),"createdAt":1,"status":"\#(status)"\#(extra)}"#
    }

    /// A worktree's opaque id: a pin's line must never show it.
    private nonisolated static let worktreeId = "wt_feature-aQRrdvpH"

    /// Saved in a mixed order; the screen puts the sessions first.
    private nonisolated static let pins: String = {
        let pins = [
            place("pin_Notebook0001", "~/notebook", "directory", "ok"),
            session("pin_Release00002", "sess-release", "ok"),
            place("pin_Book00000003", "~/Books/The Left Hand of Darkness.epub", "file", "ok"),
            place("pin_OldPlan00004", "~/Desktop/old-plan", "directory", "missing"),
            session("pin_OldChat00005", "sess-deleted", "missing"),
            session("pin_Review000006", "sess-review", "ok"),
            route("pin_SwordLab0007", #"{"kind":"godot","project":"sword-lab-3fa9c2b1"}"#, "ok", extra: #","name":"Sword Lab""#),
            route("pin_OldGame00008", #"{"kind":"godot","project":"tide-7c01d2e4"}"#, "missing"),
            // An address that never answers: the page's own title never replaces its host here.
            route("pin_GodotDocs010", #"{"kind":"browser","url":"https://docs.example.invalid/en/stable/"}"#, "ok"),
            place("pin_Report000011", "~/Books/report.pdf", "file", "ok"),
            route("pin_AppTs0000012", #"{"kind":"file","origin":"workspace","workspace":"ws-oppi","worktree":"\#(worktreeId)","path":"src/app.ts","line":null}"#, "ok"),
        ]
        return #"{"revision":12,"pins":[\#(pins.joined(separator: ","))]}"#
    }()

    /// `~/notebook`: two folders, a file, and a hidden folder.
    private nonisolated static let notebook = #"""
    {"path":"notebook/","truncated":false,"entries":[
    {"name":"inbox","type":"directory","size":0,"modifiedAt":1},
    {"name":".git","type":"directory","size":0,"modifiedAt":1},
    {"name":"index.org","type":"file","size":120,"modifiedAt":1},
    {"name":"archive","type":"directory","size":0,"modifiedAt":1}]}
    """#

    /// `~/Books/report.pdf`: two portrait pages.
    private nonisolated static let report: Data = {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            for text in ["Quarterly report", "Appendix"] {
                context.beginPage()
                (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
    }()

    /// The shell over a server whose pins answer; everything else is a 404.
    /// `requests` records every pins write as `METHOD body`.
    private static func makeShell(
        size: CGSize,
        regular: Bool,
        pinsAvailable: Bool = true,
        godot: Bool = false,
        requests: OSAllocatedUnfairLock<[String]> = OSAllocatedUnfairLock(initialState: [])
    ) async throws -> ShellWindow {
        let scope = TestURLProtocol.routeScope { request in try Self.answer(request, requests: requests) }
        let client = makeTestURLProtocolClient()
        let serverId = "sha256:pinned-\(UUID().uuidString)"
        let root = try await makeTestAppRoot(readyServerId: serverId, apiClient: client)
        let connection = try #require(root.coordinator.connection(for: serverId))
        connection.setSplitStreamCapabilitiesForTesting(
            pins: pinsAvailable,
            features: godot ? nil : [ServerFeature.godotPane.rawValue: false]
        )
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
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.path == "/files/current", query.contains(where: { $0.name == "path" && $0.value == "~/Books/report.pdf" }) {
            requests.withLock { $0.append("\(request.httpMethod ?? "") report.pdf") }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "application/pdf", "Content-Length": "\(Self.report.count)",
                "Last-Modified": "Mon, 16 Nov 2026 18:00:00 GMT",
            ]))
            return (request.httpMethod == "HEAD" ? Data() : Self.report, response)
        }
        if url.path == "/godot/sword-lab-3fa9c2b1" {
            let body = #"{"id":"sword-lab-3fa9c2b1","name":"Sword Lab","engine":{"name":"godot","version":"4.7"},"release":{"v":1,"seq":72,"createdAt":1794893569822,"origin":"discovery","engine":{"name":"godot","version":"4.7"},"packs":[],"reload":"scene"},"players":[],"releases":[],"logNext":0}"#
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
        if url.path == "/host/contents/notebook" {
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            return (Data(Self.notebook.utf8), response)
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

    /// Pinned follows All Sessions at the top of the sidebar's places and opens
    /// the screen in the detail column; the sidebar lists no pins of its own.
    @Test func theSidebarsPinnedRowOpensTheScreen() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 744), regular: true)
        defer { shell.end() }
        let sidebar = try #require(shell.sidebar)
        #expect(await shell.settles { shell.element("workspace.pinned.open", in: sidebar) != nil })
        let order = shell.elementOrder(in: sidebar)
        #expect(Array(order.prefix(2)) == ["workspace.allSessions.open", "workspace.pinned.open"], "All Sessions, then Pinned: \(order)")
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

    /// Sessions first, as cards, then every other pin as a tile, each in its
    /// saved order. A session this device has draws as its session row (its
    /// live status included); a deleted one reads Not found. A game shows the
    /// name the server read, and says it is off where the server offers no
    /// Godot Pane; a web page whose title can't be read shows its host and path.
    @Test func theScreenShowsSessionCardsThenTiles() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 900), regular: true)
        defer { shell.end() }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.items(in: .places).count == 8 })

        let screen = try #require(shell.pinned)
        let list = try #require(shell.list(in: screen))
        #expect(list.numberOfSections == 2)
        #expect(shell.items(in: .sessions) == ["pin_Release00002", "pin_OldChat00005", "pin_Review000006"])
        #expect(shell.items(in: .places) == [
            "pin_Notebook0001", "pin_Book00000003", "pin_OldPlan00004", "pin_SwordLab0007",
            "pin_OldGame00008", "pin_GodotDocs010", "pin_Report000011", "pin_AppTs0000012",
        ])
        #expect(shell.cell("pin_Notebook0001") is PinTileCell)
        // This server turns the Godot Pane off, so no game plays here.
        let swordLab = try #require(shell.cell("pin_SwordLab0007"))
        #expect(swordLab.accessibilityLabel == "Sword Lab, Godot Pane is off")
        #expect(swordLab.accessibilityIdentifier == "pinned.pin.game:sword-lab-3fa9c2b1")
        #expect(try #require(shell.cell("pin_OldGame00008")).accessibilityLabel == "Game, Not found")
        #expect(try #require(shell.cell("pin_GodotDocs010")).accessibilityLabel == "docs.example.invalid, /en/stable/")

        let release = try #require(shell.cell("pin_Release00002") as? UICollectionViewListCell)
        #expect(release.contentConfiguration is SessionListEntryConfiguration, "a live session is its session row")
        #expect(shell.descendants(of: release).contains { $0.accessibilityIdentifier == "session.nav.sess-release" })
        let deleted = try #require(shell.cell("pin_OldChat00005") as? UICollectionViewListCell)
        #expect(!(deleted.contentConfiguration is SessionListEntryConfiguration))
        #expect(deleted.accessibilityLabel == "Session, Not found")
        let missingFolder = try #require(shell.cell("pin_OldPlan00004"))
        #expect(missingFolder.accessibilityLabel == "old-plan, Not found")
        let book = try #require(shell.cell("pin_Book00000003"))
        #expect(book.accessibilityLabel == "The Left Hand of Darkness.epub, Home \u{203A} Books")
        // A worktree's file says it is in a worktree, never the worktree's id.
        let worktreeFile = try #require(shell.cell("pin_AppTs0000012")).accessibilityLabel ?? ""
        #expect(worktreeFile == "app.ts, Workspace \u{203A} Worktree \u{203A} src")
        #expect(!worktreeFile.contains(Self.worktreeId))
        _ = await shell.scope.settle()
    }

    /// Too narrow for two 160 pt tiles (365 pt and under on a phone's
    /// margins), the places draw as the File Browser's pin rows, with the
    /// tiles' identifiers, actions, and taps. Widening the window brings the
    /// tiles back and narrowing it turns them into rows again, in Edit too.
    @Test func placesTurnIntoPinRowsWhereTwoTilesDontFit() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 365, height: 874), regular: false)
        defer { shell.end() }
        var opened: [AppOpenRequest] = []
        shell.root.opener._openRequestObserverForTesting = { request in
            opened.append(request)
            return true
        }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.cell("pin_Notebook0001") is UICollectionViewListCell })
        let row = try #require(shell.cell("pin_Notebook0001") as? UICollectionViewListCell)
        #expect((row.contentConfiguration as? UIListContentConfiguration)?.text == "notebook")
        #expect(row.accessibilityIdentifier == "pinned.pin.~/notebook")
        #expect(row.accessibilityTraits.contains(.button))
        let rowActions = row.accessibilityCustomActions?.map(\.name)
        #expect(shell.items(in: .places).allSatisfy { shell.cell($0) == nil || shell.cell($0) is UICollectionViewListCell })

        for id in ["pin_SwordLab0007", "pin_GodotDocs010"] { try shell.tap(id) }
        let docs = try #require(URL(string: "https://docs.example.invalid/en/stable/"))
        #expect(opened == [
            .pane(PaneLink(server: shell.serverId, route: .godot(project: "sword-lab-3fa9c2b1")), sourceServerID: shell.serverId),
            .pane(PaneLink(server: shell.serverId, route: .browser(docs)), sourceServerID: shell.serverId),
        ], "a row opens as its tile does")

        shell.window.frame.size.width = 366
        #expect(await shell.settles { shell.cell("pin_Notebook0001") is PinTileCell }, "two tiles fit at 366 pt")
        let tile = try #require(shell.cell("pin_Notebook0001"))
        #expect(tile.accessibilityIdentifier == "pinned.pin.~/notebook")
        #expect(tile.accessibilityCustomActions?.map(\.name) == rowActions)

        let screen = try #require(shell.pinned)
        let list = try #require(shell.list(in: screen))
        let edit = try #require(screen.navigationItem.rightBarButtonItems?.first { $0.accessibilityIdentifier == "pinned.edit" })
        edit.primaryAction?.performWithSender(nil, target: nil)
        #expect(await shell.settles { list.isEditing })
        shell.window.frame.size.width = 365
        #expect(await shell.settles { shell.cell("pin_Notebook0001") is UICollectionViewListCell }, "rows again at 365 pt")
        #expect(list.isEditing && edit.title == "Done", "the switch keeps Edit")
        let editingRow = try #require(shell.cell("pin_Notebook0001") as? UICollectionViewListCell)
        #expect(editingRow.accessories.count >= 2, "an editing row shows its delete and reorder controls")
        edit.primaryAction?.performWithSender(nil, target: nil)
        _ = await shell.scope.settle()
    }

    /// A tile shows what it opens: a PDF's first page with its page count
    /// and size, a folder's item count (hidden items aside) and first items.
    /// Coming back reads the PDF's version again but not its bytes when it
    /// has not changed.
    @Test func tilesPreviewAPDFAndAFolderAndKeepAnUnchangedThumbnail() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let shell = try await Self.makeShell(size: CGSize(width: 744, height: 1133), regular: true, requests: requests)
        defer { shell.end() }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        let size = SessionFormatting.byteCount(Self.report.count)
        #expect(await shell.settles {
            shell.cell("pin_Report000011")?.accessibilityLabel == "report.pdf, PDF \u{00B7} 2 pages \u{00B7} \(size)"
        })
        let page = shell.descendants(of: try #require(shell.cell("pin_Report000011")))
            .compactMap { ($0 as? UIImageView)?.image }.first { $0.size.height > $0.size.width }
        #expect(page != nil, "the tile shows the PDF's portrait first page")
        #expect(await shell.settles { shell.cell("pin_Notebook0001")?.accessibilityLabel == "notebook, 3 items \u{00B7} Home" })
        let names = shell.descendants(of: try #require(shell.cell("pin_Notebook0001"))).compactMap { ($0 as? UILabel)?.text }
        #expect(names.filter { ["archive", "inbox", "index.org", ".git"].contains($0) } == ["archive", "inbox", "index.org"],
                "folders first, hidden ones left out: \(names)")
        #expect(requests.withLock { $0 } == ["HEAD report.pdf", "GET report.pdf"])

        // Away and back: the version is read again, the unchanged bytes are not.
        let screen = try #require(shell.pinned)
        screen.beginAppearanceTransition(false, animated: false)
        screen.endAppearanceTransition()
        screen.beginAppearanceTransition(true, animated: false)
        screen.endAppearanceTransition()
        #expect(await shell.settles { requests.withLock { $0.count } == 3 })
        #expect(requests.withLock { $0 } == ["HEAD report.pdf", "GET report.pdf", "HEAD report.pdf"])
        _ = await shell.scope.settle()
    }

    /// A game this device played shows the frame its Godot pane kept and the
    /// build the server has.
    @Test func aGameTileShowsTheFrameThePaneKeptAndItsBuild() async throws {
        let experiment = AppPreferenceStore.Experiments.godotPaneKey
        let before = UserDefaults.standard.object(forKey: experiment)
        UserDefaults.standard.set(true, forKey: experiment)
        defer { UserDefaults.standard.set(before, forKey: experiment) }
        let shell = try await Self.makeShell(size: CGSize(width: 402, height: 874), regular: false, godot: true)
        defer { shell.end() }
        let poster = GodotFolders.poster(for: GodotSlot(serverId: shell.serverId, project: "sword-lab-3fa9c2b1"))
        try FileManager.default.createDirectory(at: poster.deletingLastPathComponent(), withIntermediateDirectories: true)
        let frame = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        try frame.write(to: poster)
        defer { try? FileManager.default.removeItem(at: poster) }

        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles {
            shell.cell("pin_SwordLab0007")?.accessibilityLabel == "Sword Lab, Godot 4.7 \u{00B7} Build 72"
        })
        let shown = shell.descendants(of: try #require(shell.cell("pin_SwordLab0007")))
            .compactMap { ($0 as? UIImageView)?.image }.first { $0.size.width > $0.size.height }
        #expect(shown != nil, "the tile shows the kept frame")
        _ = await shell.scope.settle()
    }

    /// In Edit, a pin moves only within its section, and a tile's remove
    /// button takes it off the screen; Done saves the rest in their order.
    @Test func editMovesAPinWithinItsSectionAndRemovesATile() async throws {
        let requests = OSAllocatedUnfairLock(initialState: [String]())
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 900), regular: true, requests: requests)
        defer { shell.end() }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.items(in: .places).count == 8 })
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
        let tile = IndexPath(item: 3, section: 1)
        let intoSessions = delegate.collectionView?(list, targetIndexPathForMoveOfItemFromOriginalIndexPath: tile,
                                                    atCurrentIndexPath: tile, toProposedIndexPath: IndexPath(item: 1, section: 0))
        #expect(intoSessions == IndexPath(item: 0, section: 1), "a tile dropped among the sessions stays first among the tiles")

        let oldPlan = try #require(shell.cell("pin_OldPlan00004"))
        let remove = try #require(shell.descendants(of: oldPlan)
            .compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "pinned.pin.remove.~/Desktop/old-plan" })
        #expect(!remove.isHidden, "Edit shows the tile's remove button")
        remove.sendActions(for: .touchUpInside)
        #expect(await shell.settles { !shell.items(in: .places).contains("pin_OldPlan00004") })

        edit.primaryAction?.performWithSender(nil, target: nil)
        #expect(await shell.settles { !list.isEditing })
        #expect(await waitForMainActorCondition(timeout: .seconds(3)) { requests.withLock { $0.contains { $0.hasPrefix("PUT ") } } })
        let put = try #require(requests.withLock { $0.first { $0.hasPrefix("PUT ") } })
        #expect(!put.contains("pin_OldPlan00004") && put.contains("pin_Notebook0001") && put.contains("pin_Review000006"),
                "only the removed pin goes: \(put)")
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

    /// In the landscape split a session opened from Pinned is pushed over
    /// Pinned, as in portrait: Back returns to Pinned, the sidebar hides and
    /// the chat, with the sidebar button, takes the whole window rather than
    /// the frame it started its push in.
    @Test func aSessionOpenedFromPinnedInTheSplitIsPushedOverPinned() async throws {
        let size = CGSize(width: 1133, height: 744)
        let shell = try await Self.makeShell(size: size, regular: true)
        defer { shell.end() }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles {
            shell.cell("pin_Review000006") != nil && shell.split?.displayMode == .oneBesideSecondary
        }, "Pinned shows beside the sidebar")

        try shell.tap("pin_Review000006")
        #expect(await shell.settles {
            guard case .session(let target)? = shell.root.navigation.workspaceStackRouteElements.last else { return false }
            return target.sessionId == "sess-review" && shell.split?.displayMode == .secondaryOnly
                && shell.routedStack?.transitionCoordinator == nil
        }, "the chat opens with the sidebar hidden: \(shell.root.navigation.workspaceStackRouteElements)")
        #expect(shell.root.navigation.workspaceStackRouteElements.first == .utility(.pinned), "the chat sits on Pinned")
        let stack = try #require(shell.routedStack)
        #expect(stack.viewControllers.count == 2 && stack.viewControllers.first is PinnedViewController, "Back leads to Pinned")
        let chat = try #require(stack.viewControllers.last as? ChatRouteViewController)
        #expect(chat.navigationItem.mainPaneSidebarItem != nil, "the pushed chat keeps the sidebar button")
        let frame = chat.view.convert(chat.view.bounds, to: shell.window)
        #expect(frame == CGRect(origin: .zero, size: size), "the chat fills the window: \(frame)")

        stack.popViewController(animated: false)
        #expect(await shell.settles {
            shell.root.navigation.workspaceStackRouteElements == [.utility(.pinned)] && shell.split?.displayMode == .oneBesideSecondary
        }, "Back shows Pinned beside the sidebar again: \(shell.root.navigation.workspaceStackRouteElements)")
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

    /// Every pin opens as its link does: a game and a web page reach the
    /// opener as their pane links (the opener puts them beside the chat or
    /// pushes them).
    @Test func gameAndWebPinsOpenAsTheirLinks() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 402, height: 874), regular: false)
        defer { shell.end() }
        var opened: [AppOpenRequest] = []
        shell.root.opener._openRequestObserverForTesting = { request in
            opened.append(request)
            return true
        }
        shell.root.navigation.openWorkspaceUtility(.pinned)
        #expect(await shell.settles { shell.cell("pin_GodotDocs010") != nil })

        for id in ["pin_SwordLab0007", "pin_GodotDocs010"] { try shell.tap(id) }
        let docs = try #require(URL(string: "https://docs.example.invalid/en/stable/"))
        #expect(opened == [
            .pane(PaneLink(server: shell.serverId, route: .godot(project: "sword-lab-3fa9c2b1")), sourceServerID: shell.serverId),
            .pane(PaneLink(server: shell.serverId, route: .browser(docs)), sourceServerID: shell.serverId),
        ])
        _ = await shell.scope.settle()
    }

    /// On a wide window a pinned folder opens beside the main pane, as a pane
    /// link does, and the main pane keeps the Pinned screen.
    @Test func aTappedFolderOpensBesideTheMainPaneOnAWideWindow() async throws {
        let shell = try await Self.makeShell(size: CGSize(width: 1133, height: 744), regular: true)
        defer { shell.end() }
        let panes = shell.root.navigation.panes
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
        #expect(body == ["target": ["kind": "session", "id": "sess-other"]] as NSDictionary)

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
        let titles = (pin: "Pin Session", unpin: "Unpin Session")
        let pinned = PinMenu.toggle(
            route: .session("sess-release"), titles: titles, identifiers: ("chat.toolbar.menu.pin", "chat.toolbar.menu.unpin"),
            pins: connection.pins, api: api, view: view
        )
        #expect((pinned.title, pinned.identifier) == ("Unpin Session", "chat.toolbar.menu.unpin"))
        let other = PinMenu.toggle(
            route: .session("sess-other"), titles: titles, identifiers: ("chat.toolbar.menu.pin", "chat.toolbar.menu.unpin"),
            pins: connection.pins, api: api, view: view
        )
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

    var split: UISplitViewController? {
        Self.first(UISplitViewController.self, in: controller)
    }

    /// The window's pane area, the split's detail column.
    var host: PaneHostController? {
        Self.first(PaneHostController.self, in: controller)
    }

    /// The routed stack inside the pane area.
    var routedStack: ShellNavigationController? {
        host.flatMap { Self.first(ShellNavigationController.self, in: $0) }
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

    /// The pin ids the Pinned screen lists in `section`.
    func items(in section: PinnedViewController.Section) -> [String] {
        guard let screen = pinned, let list = list(in: screen),
              let source = list.dataSource as? UICollectionViewDiffableDataSource<PinnedViewController.Section, String>,
              source.snapshot().sectionIdentifiers.contains(section) else { return [] }
        return source.snapshot().itemIdentifiers(inSection: section)
    }

    /// The Pinned screen's cell for pin `id` (a session card or a tile), on screen.
    func cell(_ id: String) -> UICollectionViewCell? {
        guard let screen = pinned, let list = list(in: screen),
              let source = list.dataSource as? UICollectionViewDiffableDataSource<PinnedViewController.Section, String>,
              let indexPath = source.indexPath(for: id) else { return nil }
        list.layoutIfNeeded()
        return list.cellForItem(at: indexPath)
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
