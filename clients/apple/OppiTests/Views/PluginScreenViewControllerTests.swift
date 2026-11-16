import Foundation
import Testing
import UIKit
@testable import Oppi

/// The generic plugin page drawn from `protocol/screens.json`'s real pages, in a window: each
/// row kind as the kit's own control under its scoped identifier, one accessibility element per
/// row, rows reused across updates, and a form's draft that no update disturbs.
@MainActor
@Suite("Plugin screen page")
struct PluginScreenViewControllerTests {
    private static let entry = "test.entry"

    private struct Fixture: Decodable { let pages: [String: JSONValue] }

    private static func page(_ name: String) throws -> JSONValue {
        let fixture = try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("screens.json"))
        return try #require(fixture.pages[name])
    }

    private func show(page: String) throws -> (PluginScreenViewController, UIWindow) {
        let screen = PluginScreenViewController(entry: Self.entry, page: page, title: "", root: makeTestAppRoot())
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        return (screen, window)
    }

    private func draw(_ screen: PluginScreenViewController, _ message: PluginScreenServerMessage) async {
        screen.receive(message)
        await settle(screen)
    }

    /// Runs the page's passes and lays the window out until the list shows rows.
    private func settle(_ screen: PluginScreenViewController) async {
        let shown = await waitForMainActorCondition(timeout: .seconds(2)) {
            screen.setNeedsUpdateProperties()
            screen.updatePropertiesIfNeeded()
            screen.view.window?.layoutIfNeeded()
            screen.collectionView.layoutIfNeeded()
            return !screen.collectionView.visibleCells.isEmpty
        }
        let cells = screen.collectionView.visibleCells
        let ids = cells.map { cell in
            ([cell] + Self.descendants(of: cell)).compactMap(\.accessibilityIdentifier).joined(separator: "|")
        }
        #expect(shown, """
            no rows: frame \(screen.collectionView.frame), window \(screen.view.window != nil), \
            items \(screen.dataSource?.snapshot().numberOfItems ?? -1), cells \(cells.count), ids \(ids)
            """)
    }

    private func id(_ page: String, _ section: String, _ row: String) -> String {
        "screen.\(Self.entry).\(page).\(section).\(row)"
    }

    /// The views a shown row carries `identifier` on; a removed row's pooled cell does not count.
    private func views<T: UIView>(_ type: T.Type, _ identifier: String, in screen: PluginScreenViewController) -> [T] {
        screen.collectionView.visibleCells.flatMap { cell in
            ([cell] + Self.descendants(of: cell)).compactMap { $0 as? T }.filter { $0.accessibilityIdentifier == identifier }
        }
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @Test("each row kind is the kit's control under its scoped identifier, one element per row")
    func rowKindsDrawAsTheirControls() async throws {
        let (screen, window) = try show(page: "server/remote")
        defer { hideTestWindow(window) }
        await draw(screen, .value(watch: "w", value: try Self.page("http")))
        let page = "server/remote"
        #expect(screen.title == "remote")

        // value: the cell is the element and says label and value.
        let status = try #require(views(UICollectionViewListCell.self, id(page, "info", "status"), in: screen).first)
        #expect(status.isAccessibilityElement)
        #expect(status.accessibilityLabel == "Status")
        #expect(status.accessibilityValue == "Needs sign-in")
        // text: one element with its words.
        let url = try #require(views(UICollectionViewListCell.self, id(page, "info", "url"), in: screen).first)
        #expect(url.isAccessibilityElement && url.accessibilityLabel == "https://example.test/mcp")
        // toggle: the switch carries the identifier, label and value.
        let enabled = try #require(views(UISwitch.self, id(page, "config", "enabled"), in: screen).first)
        #expect(enabled.isOn && enabled.accessibilityLabel == "Enabled")
        // choice with four options: a menu row, one button.
        #expect(views(UIButton.self, id(page, "config", "exposure"), in: screen).count == 1)
        // button: the row's one element is its button.
        let signIn = try #require(views(UIButton.self, id(page, "oauth", "login"), in: screen).first)
        #expect(signIn.accessibilityLabel == "Sign In")
        let cell = try #require(screen.collectionView.visibleCells.first { Self.descendants(of: $0).contains(signIn) })
        #expect(cell.accessibilityElements?.count == 1 && cell.isAccessibilityElement == false)
    }

    @Test("an item row opens its page from the row's own item, and says its subtitle and status")
    func itemRowsAreButtons() async throws {
        let (screen, window) = try show(page: "list")
        defer { hideTestWindow(window) }
        await draw(screen, .value(watch: "w", value: try Self.page("list")))
        let echo = try #require(views(UIButton.self, id("list", "servers", "server.echo"), in: screen).first)
        #expect(echo.accessibilityLabel == "echo")
        #expect(echo.accessibilityValue == "stdio · 1 tools · Code Mode, Connected")
        #expect(screen.navigationItem.rightBarButtonItems?.first?.accessibilityIdentifier == "screen.\(Self.entry).list.bar.add")
    }

    @Test("an update reuses each row: one switch per toggle cell, showing the page's new value")
    func updatesReuseRows() async throws {
        let (screen, window) = try show(page: "server/remote")
        defer { hideTestWindow(window) }
        let http = try Self.page("http")
        await draw(screen, .value(watch: "w", value: http))
        let before = try #require(views(UISwitch.self, id("server/remote", "config", "enabled"), in: screen).first)
        // The server turns Enabled off: one op on the toggle's value.
        await draw(screen, .ops(watch: "w", ops: [.set([.key("sections"), .index(1), .key("rows"), .index(0), .key("value")], .bool(false))]))
        let after = views(UISwitch.self, id("server/remote", "config", "enabled"), in: screen)
        #expect(after.count == 1)
        #expect(after.first === before)
        #expect(after.first?.isOn == false)
    }

    @Test("a form keeps the person's typing through updates, and its draft picks the sections it shows")
    func formDraftSurvivesUpdates() async throws {
        let (screen, window) = try show(page: "add")
        defer { hideTestWindow(window) }
        await draw(screen, .value(watch: "w", value: try Self.page("add")))
        #expect(screen.navigationItem.rightBarButtonItems?.first?.title == "Add")
        let name = try #require(views(UITextField.self, id("add", "configuration", "name"), in: screen).first)
        name.becomeFirstResponder()
        name.text = "docs"
        name.sendActions(for: .editingChanged)

        // The server changes the page while the person types: the field is the same one, still
        // focused, with what they typed.
        await draw(screen, .ops(watch: "w", ops: [.set([.key("sections"), .index(0), .key("header")], .string("Server"))]))
        let after = try #require(views(UITextField.self, id("add", "configuration", "name"), in: screen).first)
        #expect(after === name)
        #expect(after.isFirstResponder)
        #expect(after.text == "docs")

        // HTTP shows its fields; choosing stdio swaps them for the command's.
        #expect(!views(UITextField.self, id("add", "http", "url"), in: screen).isEmpty)
        let transport = try #require(views(UISegmentedControl.self, id("add", "configuration", "transport"), in: screen).first)
        transport.selectedSegmentIndex = 1
        transport.sendActions(for: .valueChanged)
        await settle(screen)
        #expect(views(UITextField.self, id("add", "http", "url"), in: screen).isEmpty)
        #expect(!views(UITextField.self, id("add", "stdio", "command"), in: screen).isEmpty)
        #expect(views(UITextField.self, id("add", "configuration", "name"), in: screen).first?.text == "docs")
        window.endEditing(true)
    }

    @Test("a row kind this app does not know says to update the app")
    func unknownKindAsksForAnUpdate() async throws {
        let (screen, window) = try show(page: "list")
        defer { hideTestWindow(window) }
        let page: JSONValue = .object([
            "title": .string("Things"),
            "sections": .array([.object([
                "id": .string("main"),
                "rows": .array([.object(["kind": .string("chart"), "id": .string("c")])]),
            ])]),
        ])
        await draw(screen, .value(watch: "w", value: page))
        let row = try #require(views(UICollectionViewListCell.self, id("list", "main", "c"), in: screen).first)
        #expect(row.accessibilityLabel == "Update Oppi to see this row.")
    }

    @Test("a searchable page filters its items on the device and drops the sections left empty")
    func searchFiltersItems() async throws {
        let (screen, window) = try show(page: "list")
        defer { hideTestWindow(window) }
        await draw(screen, .value(watch: "w", value: try Self.page("skills")))
        let search = try #require(ScreenSearchController.search(on: screen))
        let type = { (text: String) in
            search.searchBar.text = text
            search.searchResultsUpdater?.updateSearchResults(for: search)
        }
        // The page's own rows, not the page's state row (no server in this test).
        let items = {
            guard let snapshot = screen.dataSource?.snapshot() else { return -1 }
            return snapshot.sectionIdentifiers.filter { !$0.hasPrefix("\u{1}") }.map(snapshot.numberOfItems(inSection:)).reduce(0, +)
        }
        #expect(items() == 3)

        // Matches by subtitle (the package) as well as title; the other groups go.
        type("acme")
        await settle(screen)
        #expect(items() == 1)
        #expect(screen.dataSource?.snapshot().sectionIdentifiers.contains("disabled") == true)

        type("no such skill")
        await settle(screen)
        #expect(items() == 0)
        #expect(screen.dataSource?.snapshot().sectionIdentifiers.contains("\u{1}noResults") == true)

        // A new value keeps the query.
        await draw(screen, .value(watch: "w", value: try Self.page("skills")))
        #expect(screen.dataSource?.snapshot().sectionIdentifiers.contains("\u{1}noResults") == true)
        type("")
        await settle(screen)
        #expect(items() == 3)
    }
}
