import Foundation
import Testing
@testable import Oppi

@Suite("Host switcher destinations")
struct HostSwitcherDestinationTests {
    @Test func menuListsModelProvidersUsageAndServerSettings() {
        #expect(HostSwitcherDestination.menuItems == [
            .modelProviders,
            .usage,
            .serverSettings,
        ])
        #expect(HostSwitcherDestination.menuItems.map(\.menuTitle) == [
            "Model Providers",
            "Usage",
            "Server Settings",
        ])
    }

    @Test func titlesAreUsageServerAndModelProviders() {
        #expect(HostSwitcherDestination.usage.title == "Usage")
        #expect(HostSwitcherDestination.serverSettings.title == "Server")
        #expect(HostSwitcherDestination.modelProviders.title == "Model Providers")
        #expect(HostSwitcherDestination.inbox.title == "All Sessions")
    }

    @Test func titlesAvoidManageStatsAndConfig() {
        for destination in HostSwitcherDestination.menuItems {
            let title = destination.menuTitle.lowercased()
            #expect(!title.contains("manage"))
            #expect(!title.contains("stats"))
            #expect(!title.contains("config"))
        }
        #expect(!HostSwitcherDestination.serverSettings.title.lowercased().contains("detail"))
    }

    @Test func tappingCurrentDestinationDoesNotNavigate() {
        #expect(!HostSwitcherDestination.usage.shouldNavigate(from: .usage))
        #expect(!HostSwitcherDestination.modelProviders.shouldNavigate(from: .modelProviders))
        #expect(!HostSwitcherDestination.serverSettings.shouldNavigate(from: .serverSettings))
        #expect(HostSwitcherDestination.usage.shouldNavigate(from: .inbox))
        #expect(HostSwitcherDestination.serverSettings.shouldNavigate(from: .usage))
    }

    @Test func catalogShortcutUsesUsageCopy() {
        #expect(HostSwitcherDestination.usage.menuTitle == "Usage")
    }
}

@Suite("Host-scoped server follow")
struct HostScopedServerFollowTests {
    @Test func visibleServerPrefersActiveHostOverFrozenTarget() {
        let servers = makeServers("sha256:aaa", "sha256:bbb")
        let result = ServerSelection.resolveVisible(
            activeId: "sha256:bbb",
            frozenId: "sha256:aaa",
            from: servers
        )
        #expect(result?.id == "sha256:bbb")
    }

    @Test func visibleServerFallsBackToFrozenTargetWhenActiveMissing() {
        let servers = makeServers("sha256:aaa", "sha256:bbb")
        let result = ServerSelection.resolveVisible(
            activeId: nil,
            frozenId: "sha256:aaa",
            from: servers
        )
        #expect(result?.id == "sha256:aaa")
    }

    @Test func visibleServerFallsBackToFirstWhenBothMissing() {
        let servers = makeServers("sha256:aaa", "sha256:bbb")
        let result = ServerSelection.resolveVisible(
            activeId: "sha256:gone",
            frozenId: "sha256:missing",
            from: servers
        )
        #expect(result?.id == "sha256:aaa")
    }

    private func makeServers(_ ids: String...) -> [PairedServer] {
        ids.enumerated().map { index, id in
            PairedServer(
                from: ServerCredentials(
                    host: "host-\(index).local",
                    port: 7749,
                    token: "sk_test",
                    name: "Server \(index)",
                    serverFingerprint: id
                ),
                sortOrder: index
            )!
        }
    }
}

@Suite("Usage host-follow wiring")
struct UsageHostFollowWiringTests {
    @Test func dashboardIdentityResetsWithVisibleHost() throws {
        let source = try appleSource("Oppi/Features/Server/ServerView.swift")
        #expect(source.contains(".id(selectedServer.id)"))
        #expect(source.contains("shouldApplyHostResult"))
        #expect(source.contains("let requestedId = server.id") || source.contains("let requestedId = selectedServer?.id"))
    }

    @Test func usageTrailingChromeHasNoSettingsGear() throws {
        let source = try appleSource("Oppi/Features/Server/ServerView.swift")
        #expect(!source.contains("server.settings.gear"))
        #expect(!source.contains("Image(systemName: \"gearshape\")"))
    }
}

@Suite("Inbox host-change local state")
@MainActor
struct SessionInboxHostChangeTests {
    @Test func hostChangeClearsSearchTextStoreAndExpansion() {
        defer { TestURLProtocol.handler = nil }
        TestURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        var searchText = "usage from host A"
        var expanded: Set<String> = ["today"]
        var collapsed: Set<String> = ["yesterday"]
        let store = SessionSearchStore()
        store.search(query: "usage-query", workspaceId: "ws-1", apiClient: makeSearchClient())

        #expect(store.isSearching)
        #expect(store.activeServerQuery == "usage-query")

        let reset = SessionInboxHostChange.reset(
            searchText: searchText,
            expandedStoppedGroupIDs: expanded,
            collapsedStoppedGroupIDs: collapsed,
            searchStore: store
        )
        searchText = reset.searchText
        expanded = reset.expandedStoppedGroupIDs
        collapsed = reset.collapsedStoppedGroupIDs

        #expect(searchText.isEmpty)
        #expect(expanded.isEmpty)
        #expect(collapsed.isEmpty)
        #expect(!store.isSearching)
        #expect(store.results.isEmpty)
        #expect(store.activeServerQuery == nil)
        #expect(store.completedServerQuery == nil)
    }

    @Test func inboxResetsLocalStateWhenActiveServerChangesWithoutPopping() throws {
        let source = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        #expect(source.contains("SessionInboxHostChange.reset"))
        #expect(source.contains(".task(id: activeServerId)"))

        let taskSlice = try sourceSlice(
            source,
            start: ".task(id: activeServerId) {",
            end: ".task(id: selectedWorkspace?.workspace.id)"
        )
        #expect(taskSlice.contains("resetLocalHostState") || taskSlice.contains("SessionInboxHostChange.reset"))
        #expect(!taskSlice.contains("showAllWorkspaceSessions"))
    }

    @Test func inboxOnSwitchStillPopsToAllSessions() throws {
        let source = try appleSource("Oppi/Features/Workspaces/SessionInboxView.swift")
        let slice = try sourceSlice(
            source,
            start: "private func switchVisibleServer(to server: PairedServer) async {",
            end: "private func refreshVisibleServer() async {"
        )
        #expect(slice.contains("showAllWorkspaceSessions()"))
    }

    private func makeSearchClient() -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "http://localhost:7749")!,
            token: "sk_test",
            configuration: config
        )
    }
}

@Suite("Host-job compact switch")
@MainActor
struct HostJobCompactSwitchTests {
    @Test func defaultHostSwitchPathDoesNotPopToAllSessions() throws {
        let source = try appleSource("Oppi/Features/Workspaces/WorkspaceHomeView.swift")
        let slice = try sourceSlice(
            source,
            start: "private func switchHost(_ server: PairedServer) async {",
            end: "private func menuTitle(for server: PairedServer) -> String {"
        )
        #expect(slice.contains("switchToServerReady(server)"))
        #expect(!slice.contains("showAllWorkspaceSessions"))
    }

    @Test func showAllWorkspaceSessionsWouldPopAHostJob() {
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        navigation.openHostSwitcherDestination(.usage, serverId: "server-a")
        #expect(navigation.visibleHostSwitcherDestination == .usage)

        navigation.showAllWorkspaceSessions()
        #expect(navigation.visibleHostSwitcherDestination == .inbox)
        #expect(navigation.workspacePath.count == 0)
    }
}

private func appleSource(_ relativePath: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func sourceSlice(_ source: String, start: String, end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
        Issue.record("Missing source start \(start)")
        throw SourceSliceError.missingMarker(start)
    }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
        Issue.record("Missing source end \(end)")
        throw SourceSliceError.missingMarker(end)
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private enum SourceSliceError: Error {
    case missingMarker(String)
}
