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
        ]

        let presentation = ServerExtensionListPresentation(extensions: rows, query: "")

        #expect(presentation.sections.map(\.kind) == [
            .builtIn,
            .needsAttention,
            .enabledPiExtensions,
            .disabledPiExtensions,
        ])
        #expect(presentation.sections[0].extensions.map(\.id) == ["other-built-in"])
        #expect(presentation.sections[1].extensions.map(\.id) == ["broken"])
        #expect(presentation.sections[2].extensions.map(\.id) == ["enabled"])
        #expect(presentation.sections[3].extensions.map(\.id) == ["disabled"])
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
        let root = try makeTestAppRoot(
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

    @Test func healthyDetailRetrySupersedesStaleCatalogErrorForRenderingAndToggle() {
        let staleCatalog = extensionRow(
            id: "review",
            name: "Review",
            state: .error,
            loadError: "Stale catalog failure"
        )
        let healthyDetail = ServerExtensionDetail(
            summary: extensionRow(id: "review", name: "Review", state: .on),
            contributedTools: nil,
            contributedCommands: nil
        )

        let rendered = resolvedServerExtensionDetailSummary(
            catalogSummary: staleCatalog,
            freshDetail: healthyDetail
        )

        #expect(rendered == healthyDetail.summary)
        #expect(rendered?.state == .on)
    }

    @Test func theOppiBarNeedsAUserOwnedEntryFile() {
        let path = "/Users/chen/.pi/agent/extensions/workflow.ts"

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
            ("directory", extensionRow(id: "d", name: "d", kind: .directory, state: .on, path: "/Users/chen/.pi/agent/extensions/d")),
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
        path: String? = nil
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
            isRemovable: false
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

    init(catalog: ServerExtensionCatalog, detail: ServerExtensionDetail, enabled: ServerExtensionSummary) {
        self.catalog = catalog
        self.detail = detail
        self.enabled = enabled
    }

    var enableRequests: Int { lock.withLock { enables } }

    /// Fails every detail request, as the reload after a save can fail.
    var failDetail = false

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

