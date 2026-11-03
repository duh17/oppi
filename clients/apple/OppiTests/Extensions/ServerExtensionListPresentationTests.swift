import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("Server Extensions presentation")
@MainActor
struct ServerExtensionListPresentationTests {
    @Test func groupsBuiltInFirstThenAttentionEnabledAndDisabled() {
        let rows = [
            extensionRow(id: "disabled", name: "Zulu", state: .off),
            extensionRow(id: "enabled", name: "Alpha", state: .on),
            extensionRow(id: "broken", name: "Broken", state: .error, loadError: "Import failed"),
            extensionRow(id: "other-built-in", name: "Another", kind: .builtIn, state: .on),
            // An owner plugin sits with the Pi extensions it can be turned on and off beside.
            extensionRow(id: "durable-only", name: "Durable", kind: .directory, state: .on, kinds: [.plugin], source: .owner),
            extensionRow(id: "working-words", name: "Words", kind: .builtIn, state: .on, kinds: [.plugin], source: .builtIn),
        ]

        let presentation = ServerExtensionListPresentation(extensions: rows, query: "")

        #expect(presentation.sections.map(\.kind) == [.builtIn, .needsAttention, .enabled, .disabled])
        #expect(presentation.sections[0].extensions.map(\.id) == ["other-built-in", "working-words"])
        #expect(presentation.sections[1].extensions.map(\.id) == ["broken"])
        #expect(presentation.sections[2].extensions.map(\.id) == ["enabled", "durable-only"])
        #expect(presentation.sections[3].extensions.map(\.id) == ["disabled"])
    }

    @Test func badgesNameTheRowsKindsAndSourceFromItsFieldsAlone() {
        func badges(_ row: ServerExtensionSummary) -> [String] {
            ServerExtensionListPresentation.badges(for: row).map(\.label)
        }
        #expect(badges(extensionRow(
            id: "control", name: "anything", kind: .builtIn, state: .on,
            kinds: [.plugin], source: .builtIn, plugin: plugin(required: true)
        )) == ["Plugin", "Built-in", "Required"])
        #expect(badges(extensionRow(
            id: "both", name: "both", kind: .directory, state: .on,
            kinds: [.plugin, .piExtension], source: .owner, plugin: plugin()
        )) == ["Plugin", "Pi extension"])
        #expect(badges(extensionRow(
            id: "project", name: "project", kind: .directory, state: .on, kinds: [.plugin], source: .project
        )) == ["Plugin", "Project"])
        #expect(badges(extensionRow(
            id: "classic", name: "classic", state: .on, kinds: [.piExtension], source: .owner
        )) == ["Pi extension"])
        // A name says nothing: a row called like Oppi Control without the fields has no badge.
        #expect(badges(extensionRow(id: "old", name: "oppi-control", state: .on)).isEmpty)
    }

    @Test func aRequiredBuiltInCannotBeTurnedOffAndABrokenOneNeedsAttention() {
        let required = extensionRow(
            id: "control", name: "control", kind: .builtIn, state: .on,
            kinds: [.plugin], source: .builtIn, plugin: plugin(required: true)
        )
        let optional = extensionRow(
            id: "sql", name: "sql", kind: .builtIn, state: .on,
            kinds: [.plugin], source: .builtIn, plugin: plugin()
        )
        let broken = extensionRow(
            id: "words", name: "words", kind: .builtIn, state: .error, loadError: "Unexpected token",
            kinds: [.plugin], source: .builtIn, plugin: plugin(required: true, loadError: "Unexpected token", kept: true)
        )
        #expect(!required.canToggleServerDefault)
        #expect(optional.canToggleServerDefault)
        #expect(!broken.canToggleServerDefault)

        let presentation = ServerExtensionListPresentation(extensions: [required, optional, broken], query: "")
        #expect(presentation.sections.map(\.kind) == [.builtIn, .needsAttention])
        #expect(presentation.sections[1].extensions.map(\.id) == ["words"])
        // A kept plugin's status says its previous code still runs; a healthy one's does not.
        #expect(ServerExtensionListPresentation.statusLabel(for: broken).contains("previous code"))
        #expect(!ServerExtensionListPresentation.statusLabel(for: required).contains("previous code"))
        let label = ServerExtensionListPresentation.accessibilityLabel(for: broken)
        #expect(["Plugin", "Required", "Error", "previous code"].allSatisfy(label.contains))
        #expect(ServerExtensionListPresentation(extensions: [required], query: "required").visibleExtensions.map(\.id) == ["control"])
    }

    @Test func aKeptPluginsSwitchStaysOnAndCanBeTurnedOffUnlessRequired() {
        func kept(required: Bool, state: ServerExtensionState = .error) -> ServerExtensionSummary {
            extensionRow(
                id: "both", name: "both", kind: .directory, state: state, loadError: "ParseError",
                kinds: [.plugin, .piExtension], source: .owner,
                plugin: plugin(required: required, loadError: "ParseError", kept: true)
            )
        }
        // Its reload failed, but its plugin is on and its previous code runs.
        #expect(kept(required: false).isServerDefaultOn)
        #expect(kept(required: false).canToggleServerDefault)
        #expect(kept(required: true).isServerDefaultOn)
        #expect(!kept(required: true).canToggleServerDefault)
        // Switching it off shows off while the save runs.
        #expect(!kept(required: false, state: .off).isServerDefaultOn)

        // A plugin that never loaded has nothing running and nothing to switch.
        let neverLoaded = extensionRow(
            id: "broken", name: "broken", kind: .directory, state: .error, loadError: "ParseError",
            kinds: [.plugin], source: .owner, plugin: plugin(loadError: "ParseError")
        )
        #expect(!neverLoaded.isServerDefaultOn)
        #expect(!neverLoaded.canToggleServerDefault)
    }

    @Test func aReloadErrorNamesItsFileOnce() {
        let entry = "/plugins/broken/server.ts"
        let lines = ServerPluginReloadPresentation.lines(for: .finished(ServerPluginReloadReport(
            loaded: [], kept: [], removed: [], skipped: [],
            errors: [
                .init(entry: entry, message: "ParseError: Unexpected token \(entry):2:0", plugin: "broken"),
                .init(entry: "/plugins/thief/server.ts", message: "Task \"x\" is taken", plugin: "thief"),
            ]
        )))
        #expect(lines.map(\.detail) == [nil, "/plugins/thief/server.ts"])
    }

    @Test func aPluginsDetailListsWhatItContributesWithHooksByTask() {
        let sections = ServerExtensionListPresentation.pluginSections(for: ServerPluginSummary(
            extensionName: "webtools", required: false, enabled: true,
            runtimes: ["host"],
            tools: ["web_search", "web_fetch"],
            hooks: [
                ServerPluginHook(task: "pi.generation", handlers: ["beforeRequest"]),
                ServerPluginHook(task: "pi.tool", handlers: ["beforeTool"]),
                ServerPluginHook(task: "pi.generation", handlers: ["beforeProviderRequest", "beforeRequest"]),
            ],
            sections: [],
            wraps: [ServerPluginWrap(tool: "read"), ServerPluginWrap(section: "guide")],
            tasks: [],
            loadError: nil,
            kept: false
        ))

        // Empty groups are left out.
        #expect(sections.map(\.title) == ["Tools", "Hooks", "Wraps", "Runtimes"])
        #expect(sections[0].lines == ["web_search", "web_fetch"])
        #expect(sections[1].lines == [
            "pi.generation: beforeRequest, beforeProviderRequest",
            "pi.tool: beforeTool",
        ])
        #expect(sections[2].lines == ["Tool read", "Prompt section guide"])
        #expect(sections[3].lines == ["host"])
    }

    @Test func searchMatchesCapabilityProvenanceKindAndState() {
        let rows = [
            extensionRow(id: "review", name: "Review", description: "Checks pull requests", state: .on),
            extensionRow(id: "package", name: "Package", kind: .package, provenance: "npm:@scope/tools", state: .off),
        ]

        #expect(ServerExtensionListPresentation(extensions: rows, query: "pull requests").visibleExtensions.map(\.id) == ["review"])
        #expect(ServerExtensionListPresentation(extensions: rows, query: "npm:@scope").visibleExtensions.map(\.id) == ["package"])
        #expect(ServerExtensionListPresentation(extensions: rows, query: "package").visibleExtensions.map(\.id) == ["package"])
        #expect(ServerExtensionListPresentation(extensions: rows, query: "disabled").visibleExtensions.map(\.id) == ["package"])
    }

    @Test func packageNameIsSearchableAndAppearsBeforeProvenanceInAccessibility() throws {
        let resource = try JSONDecoder().decode(ServerExtensionSummary.self, from: Data("""
        {"id":"review-tools","name":"Review tools","kind":"package","provenance":{"kind":"package","label":"Configured package source"},"path":"/private/var/folders/package/index.ts","packageName":"@scope/review-tools","state":"on","warnings":[],"isRemovable":false}
        """.utf8))

        #expect(ServerExtensionListPresentation(extensions: [resource], query: "@scope/review-tools").visibleExtensions.map(\.id) == ["review-tools"])
        #expect(ServerExtensionListPresentation.accessibilityLabel(for: resource) == "Review tools, @scope/review-tools, Configured package source, Enabled")
    }

    @Test func noPiExtensionsAndFilteredNoResultsRemainDistinct() {
        let builtIn = extensionRow(id: "built-in", name: "Built-in", kind: .builtIn, state: .off)

        let unfiltered = ServerExtensionListPresentation(extensions: [builtIn], query: "")
        let filtered = ServerExtensionListPresentation(extensions: [builtIn], query: "missing")

        #expect(unfiltered.hasNoPiExtensions)
        #expect(!unfiltered.isFilteredNoResults)
        #expect(filtered.isFilteredNoResults)
    }

    @Test func rowAccessibilityIncludesNameProvenanceAndState() {
        let row = extensionRow(id: "broken", name: "Broken", provenance: "Pi user settings", state: .error)

        #expect(ServerExtensionListPresentation.accessibilityLabel(for: row) == "Broken, Pi user settings, Error")
    }

    @Test func aFailedDetailReloadAfterASaveKeepsTheSummaryAndTheContents() async throws {
        let resourceId = "review"
        let answers = ExtensionDetailAnswers(
            catalog: ServerExtensionCatalog(extensions: [extensionRow(id: resourceId, name: "Review", state: .off)]),
            detail: ServerExtensionDetail(
                summary: extensionRow(id: resourceId, name: "Review", state: .off),
                contributedTools: ["review"],
                contributedCommands: ["review"]
            ),
            enabled: extensionRow(id: resourceId, name: "Review", state: .on)
        )
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            try answers.answer(for: request)
        })
        defer { routes.end() }
        let root = try await makeTestAppRoot(
            readyServerId: ExtensionDetailAnswers.serverId,
            apiClient: makeTestURLProtocolClient(host: ExtensionDetailAnswers.host)
        )
        let connection = root.coordinator.activeConnection
        // The list that opens a detail loads the catalog first: the page reads its
        // summary from the store.
        let api = try #require(connection.apiClient)
        connection.serverResourceStore.switchServer(to: ExtensionDetailAnswers.serverId)
        await connection.serverResourceStore.load(serverId: ExtensionDetailAnswers.serverId, api: api)
        #expect(!connection.serverResourceStore.extensions(forServer: ExtensionDetailAnswers.serverId).isEmpty,
                "the catalog the page draws its summary from")

        let page = ServerExtensionDetailViewController(
            target: ServerResourceDetailNavTarget(
                serverId: ExtensionDetailAnswers.serverId, kind: .extension, resourceId: resourceId
            ),
            root: root,
            connection: connection
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer { hideTestWindow(window); window.rootViewController = nil }

        // The detail landed: the page lists what the extension contributes.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return page.sections().contains { $0.id == .tools }
        }, "the detail's contributions are listed")

        // Enable saves, and the detail request that follows it fails: the
        // catalog's answer stays authoritative, and the contributions stay.
        answers.failDetail = true
        let toggle = try #require(Self.switchWithIdentifier("server.extension.enabled", in: page.view))
        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { answers.enableRequests == 1 })
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { page.loadFailure != nil },
                "the reload after the save failed")

        page.view.layoutIfNeeded()
        let summary = try #require(page.state?.summary)
        #expect(summary.isServerDefaultOn, "the catalog's saved answer survives the failed reload")
        #expect(page.sections().contains { $0.id == .tools }, "a failed reload keeps the contents it found")
        #expect(page.sections().contains { $0.id == .commands })
    }

    /// A switch inside one of the page's rows, by the identifier the row gave it.
    private static func switchWithIdentifier(_ identifier: String, in view: UIView) -> UISwitch? {
        if let toggle = view as? UISwitch, toggle.accessibilityIdentifier == identifier { return toggle }
        for subview in view.subviews {
            if let found = switchWithIdentifier(identifier, in: subview) { return found }
        }
        return nil
    }

    /// The precedence lives in `ServerResourceDetailScreenController`, so both
    /// pages share it; this page is the harness.
    @Test func aHealthyDetailAnswerSupersedesAStaleCatalogErrorForRenderingAndToggle() async throws {
        let resourceId = "review"
        let healthy = extensionRow(id: resourceId, name: "Review", state: .on)
        let answers = ExtensionDetailAnswers(
            catalog: ServerExtensionCatalog(extensions: [
                extensionRow(id: resourceId, name: "Review", state: .error, loadError: "Stale catalog failure"),
            ]),
            detail: ServerExtensionDetail(summary: healthy, contributedTools: ["review"], contributedCommands: nil),
            enabled: healthy
        )
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in
            try answers.answer(for: request)
        })
        defer { routes.end() }
        let root = try await makeTestAppRoot(
            readyServerId: ExtensionDetailAnswers.serverId,
            apiClient: makeTestURLProtocolClient(host: ExtensionDetailAnswers.host)
        )
        let connection = root.coordinator.activeConnection
        let api = try #require(connection.apiClient)
        connection.serverResourceStore.switchServer(to: ExtensionDetailAnswers.serverId)
        await connection.serverResourceStore.load(serverId: ExtensionDetailAnswers.serverId, api: api)
        #expect(connection.serverResourceStore.extensions(forServer: ExtensionDetailAnswers.serverId).first?.state == .error,
                "the page opens on the stale catalog row")

        let page = ServerExtensionDetailViewController(
            target: ServerResourceDetailNavTarget(
                serverId: ExtensionDetailAnswers.serverId, kind: .extension, resourceId: resourceId
            ),
            root: root,
            connection: connection
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer { hideTestWindow(window); window.rootViewController = nil }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return page.sections().contains { $0.id == .tools }
        }, "the detail landed")

        let summary = try #require(page.state?.summary)
        #expect(summary == healthy, "the detail's answer beats the stale catalog row")
        #expect(summary.loadError == nil)
        let toggle = try #require(Self.switchWithIdentifier("server.extension.enabled", in: page.view))
        #expect(toggle.isOn, "the switch shows the detail's state")
        #expect(toggle.isEnabled, "a stale error row no longer blocks the switch")
    }

    @Test func aRequiredPluginsDetailListsWhatItContributesAndKeepsItsSwitchOn() async throws {
        let resourceId = "control"
        let row = extensionRow(
            id: resourceId, name: "oppi-control", kind: .builtIn, state: .on,
            kinds: [.plugin], source: .builtIn,
            plugin: ServerPluginSummary(
                extensionName: "control", required: true, enabled: true, runtimes: ["host"],
                tools: ["oppi_control"], hooks: [ServerPluginHook(task: "pi.tool", handlers: ["beforeTool"])],
                sections: ["control"], wraps: [], tasks: [], loadError: nil, kept: false
            )
        )
        // A plugin-only row's detail is its summary: its contributions come with it.
        let answers = ExtensionDetailAnswers(
            catalog: ServerExtensionCatalog(extensions: [row]),
            detail: ServerExtensionDetail(summary: row),
            enabled: row
        )
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in try answers.answer(for: request) })
        defer { routes.end() }
        let root = try await makeTestAppRoot(
            readyServerId: ExtensionDetailAnswers.serverId,
            apiClient: makeTestURLProtocolClient(host: ExtensionDetailAnswers.host)
        )
        let connection = root.coordinator.activeConnection
        let api = try #require(connection.apiClient)
        connection.serverResourceStore.switchServer(to: ExtensionDetailAnswers.serverId)
        await connection.serverResourceStore.load(serverId: ExtensionDetailAnswers.serverId, api: api)

        let page = ServerExtensionDetailViewController(
            target: ServerResourceDetailNavTarget(
                serverId: ExtensionDetailAnswers.serverId, kind: .extension, resourceId: resourceId
            ),
            root: root,
            connection: connection
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer { hideTestWindow(window); window.rootViewController = nil }

        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.view.layoutIfNeeded()
            return Self.switchWithIdentifier("server.extension.enabled", in: page.view) != nil
        })
        let sections = page.sections()
        #expect(sections.map(\.id).prefix(3) == [.summary, .status, .serverDefault], "status first")
        #expect(sections.first { $0.id == .plugin("Tools") }?.items == [.pluginLine("Tools", "oppi_control")])
        #expect(sections.first { $0.id == .plugin("Hooks") }?.items == [.pluginLine("Hooks", "pi.tool: beforeTool")])
        #expect(sections.first { $0.id == .plugin("Prompt Sections") } != nil)
        #expect(sections.first { $0.id == .source }?.items.contains(.detail("Source")) == true)
        let toggle = try #require(Self.switchWithIdentifier("server.extension.enabled", in: page.view))
        #expect(toggle.isOn)
        #expect(!toggle.isEnabled, "a required built-in cannot be turned off")
    }

    @Test func theOppiBarNeedsAUserOwnedEntryFile() {
        let path = "/Users/alex/.pi/agent/extensions/workflow.ts"

        #expect(ServerExtensionListPresentation.editablePath(
            for: extensionRow(id: "workflow", name: "workflow", state: .on, path: path)
        ) == path)
        // A disabled or broken extension is still a file the user can revise.
        #expect(ServerExtensionListPresentation.editablePath(
            for: extensionRow(id: "broken", name: "broken", state: .error, path: path)
        ) == path)

        let hidden: [(String, ServerExtensionSummary)] = [
            ("package", extensionRow(id: "p", name: "p", kind: .package, state: .on, path: "/opt/node_modules/p/index.js")),
            ("package provenance", extensionRow(id: "q", name: "q", provenanceKind: .package, state: .on, path: path)),
            ("built-in", extensionRow(id: "b", name: "b", kind: .builtIn, state: .on, path: "builtin:b")),
            ("directory", extensionRow(id: "d", name: "d", kind: .directory, state: .on, path: "/Users/alex/.pi/agent/extensions/d")),
            ("unknown kind", extensionRow(id: "u", name: "u", kind: .unknown, state: .on, path: path)),
            ("no path", extensionRow(id: "n", name: "n", state: .on, path: nil)),
            ("relative path", extensionRow(id: "r", name: "r", state: .on, path: "extensions/r.ts")),
            ("multi-line path", extensionRow(id: "m", name: "m", state: .on, path: "/a.ts\n/b.ts")),
        ]
        for (reason, row) in hidden {
            #expect(ServerExtensionListPresentation.editablePath(for: row) == nil, "\(reason)")
        }
    }

    private func extensionRow(
        id: String,
        name: String,
        description: String? = nil,
        kind: ServerExtensionKind = .file,
        provenance: String? = nil,
        provenanceKind: ServerResourceProvenanceKind? = nil,
        state: ServerExtensionState,
        loadError: String? = nil,
        path: String? = nil,
        kinds: [ServerExtensionRowKind]? = nil,
        source: ServerExtensionSource? = nil,
        plugin: ServerPluginSummary? = nil
    ) -> ServerExtensionSummary {
        ServerExtensionSummary(
            id: id,
            name: name,
            description: description,
            kind: kind,
            provenance: ServerResourceProvenance(
                kind: provenanceKind ?? (kind == .builtIn ? .builtIn : (kind == .package ? .package : .userSettings)),
                label: provenance ?? (kind == .builtIn ? "Built-in extension" : "Pi user settings")
            ),
            path: path,
            state: state,
            loadError: loadError,
            warnings: [],
            isRemovable: false,
            kinds: kinds,
            source: source,
            plugin: plugin
        )
    }

    private func plugin(required: Bool = false, loadError: String? = nil, kept: Bool = false) -> ServerPluginSummary {
        ServerPluginSummary(
            extensionName: loadError == nil || kept ? "plugin" : nil, required: required,
            enabled: loadError == nil || kept,
            runtimes: ["host"], tools: [], hooks: [], sections: [], wraps: [], tasks: [],
            loadError: loadError, kept: kept
        )
    }
}

/// Answers one extension's page: its catalog, its detail, and its Enable save.
/// The detail request can be made to fail after a save, as a server that answers
/// the catalog and then refuses the detail does. Counts the saves.
private final class ExtensionDetailAnswers: @unchecked Sendable {
    static let host = "extension-detail.test"
    static let serverId = "extension-detail-server"

    private let catalog: ServerExtensionCatalog
    private let detail: ServerExtensionDetail
    private let enabled: ServerExtensionSummary
    private let lock = NSLock()
    private var enables = 0
    private var failsDetail = false

    init(catalog: ServerExtensionCatalog, detail: ServerExtensionDetail, enabled: ServerExtensionSummary) {
        self.catalog = catalog
        self.detail = detail
        self.enabled = enabled
    }

    var enableRequests: Int { lock.withLock { enables } }

    /// Fails every detail request, as the reload after a save can fail.
    var failDetail: Bool {
        get { lock.withLock { failsDetail } }
        set { lock.withLock { failsDetail = newValue } }
    }

    func answer(for request: URLRequest) throws -> (Data, HTTPURLResponse)? {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        if method == "PUT", path.hasSuffix("/enabled") {
            lock.withLock { enables += 1 }
            return try mockJSONResponse(encoding: enabled, for: request)
        }
        guard method == "GET" else { return nil }
        // The catalog, then one extension's detail. The detail route answers
        // first in the page's life, so the exact catalog path is matched first.
        if path.hasSuffix("/server/resources/extensions") {
            return try mockJSONResponse(encoding: catalog, for: request)
        }
        guard path.contains("/server/resources/extensions/") else { return nil }
        if failDetail { throw URLError(.cannotConnectToHost) }
        return try mockJSONResponse(encoding: detail, for: request)
    }
}

