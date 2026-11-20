import Foundation
import Testing
@testable import Oppi

/// This device's sidebar layout (Edit Sidebar) as the sidebar draws it: the
/// places the server offers, in the device's order, without the ones it hid.
@Suite("Workspace sidebar layout")
@MainActor
struct WorkspaceSidebarLayoutTests {
    private static let skills = PluginScreenSidebarEntry(id: "oppi-skills-screen", title: "Skills", icon: "sparkles", order: 30, scopes: ["server"])
    private static let mcp = PluginScreenSidebarEntry(id: "oppi-mcp-screen", title: "MCP Servers", icon: "server.rack", order: 50, scopes: ["server"])

    private func places(
        _ layout: WorkspaceSidebarLayout,
        plugins: [PluginScreenSidebarEntry] = [],
        offers: (ServerFeature) -> Bool = { _ in true }
    ) -> [NavigationPlace] {
        WorkspaceSidebarPlaces.items(plugins: plugins, pinsAvailable: true, layout: layout, offers: offers).map(\.place)
    }

    /// A saved layout (Terminal hidden, Rex dragged above Agents) meets two
    /// plugin places it has never seen: each arrives shown, after the place
    /// before it in the default order. A bar's new button keeps the bars' rule:
    /// it arrives hidden, at the end.
    @Test func aNewPluginPlaceArrivesShownInItsDefaultSpotWhileABarsNewButtonArrivesHiddenAtTheEnd() {
        let defaults = testDefaults(suite: "WorkspaceSidebarLayoutTests.\(UUID().uuidString)")
        let preference = WorkspaceSidebarPlaces.layoutPreference
        defaults.set(["pinned", "rex", "agents", "schedules", "extensions", "terminal"], forKey: preference.orderKey)
        defaults.set(["pinned", "rex", "agents", "schedules", "extensions"], forKey: preference.shownKey)
        let saved = preference.layout(in: defaults)

        #expect(places(saved, plugins: [Self.skills, Self.mcp]) == [
            .allSessions, .utility(.pinned), .utility(.rex), .utility(.agents), .utility(.schedules),
            .utility(.pluginScreen("oppi-skills-screen")), .utility(.extensions),
            .utility(.pluginScreen("oppi-mcp-screen")),
        ])

        let savedBeforeFind = ReaderBarAction.allCases.filter { $0 != .find }.map(\.rawValue)
        let readerBar = BarLayout<ReaderBarAction>(storedOrder: savedBeforeFind, storedShown: savedBeforeFind)
        #expect(readerBar.order.last == .find)
        #expect(!readerBar.isShown(.find))
    }

    /// Once saved, a plugin place keeps the person's choice: hidden stays
    /// hidden. A place the server stops offering is not drawn, and comes back
    /// to the spot and switch it had.
    @Test func aSavedPluginPlaceKeepsItsSwitchAndAnUnofferedPlaceKeepsItsSpot() {
        let mcpID = WorkspaceSidebarPlaceID.plugin("oppi-mcp-screen")
        let ids = WorkspaceSidebarPlaces.layoutIDs(WorkspaceSidebarPlaces.offered(plugins: [Self.mcp], pinsAvailable: true) { _ in true })
        let layout = WorkspaceSidebarLayout.defaultValue.placingUnseen(ids)
            .reordering([.terminal, .pinned, .agents, .schedules, .extensions, mcpID, .rex])
            .setting(mcpID, shown: false)
        let stored = WorkspaceSidebarLayout(storedOrder: layout.storedOrder, storedShown: layout.storedShown)
        #expect(stored.storedOrder.contains("plugin.oppi-mcp-screen"))

        #expect(places(stored, plugins: [Self.mcp]) == [
            .allSessions, .utility(.sshTerminal), .utility(.pinned), .utility(.agents), .utility(.schedules),
            .utility(.extensions), .utility(.rex),
        ])
        // Terminal off on the server: no row, and the layout keeps its spot for when it is back.
        #expect(!places(stored, plugins: [Self.mcp]) { $0 != .terminal }.contains(.utility(.sshTerminal)))
        #expect(stored.order.first == .terminal)
    }

    /// All Sessions is not in the layout: a plugin place ordered before every
    /// built-in one arrives after it, and hiding every place leaves it.
    @Test func allSessionsStaysFirstAndCannotBeHidden() {
        let early = PluginScreenSidebarEntry(id: "acme.early", title: "Early", icon: "network", order: -5, scopes: ["server"])
        #expect(places(.defaultValue, plugins: [early]).prefix(2) == [.allSessions, .utility(.pluginScreen("acme.early"))])

        let hidden = WorkspaceSidebarPlaceID.allCases.reduce(WorkspaceSidebarLayout.defaultValue) { $0.setting($1, shown: false) }
        #expect(places(hidden) == [.allSessions])
    }
}
