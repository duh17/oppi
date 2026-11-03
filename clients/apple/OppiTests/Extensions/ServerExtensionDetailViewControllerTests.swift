import Foundation
import Testing
import UIKit
@testable import Oppi

/// The extension detail page in a real window: the rows it draws from a row's
/// protocol fields and its detail answer, found by their identifiers.
@Suite("Server extension detail page")
@MainActor
struct ServerExtensionDetailViewControllerTests {
    @Test func aBuiltInPluginsAboutCardSaysWhatItIsWhereItIsFromAndWhereItRuns() async throws {
        let row = summary(
            id: "ask", name: "ask", kind: .builtIn, provenance: .init(kind: .builtIn, label: "Oppi"),
            path: "/opt/oppi/plugins/ask/server.js", kinds: [.plugin], source: .builtIn,
            plugin: plugin(runtimes: ["host", "sandbox"], tools: ["ask"])
        )
        let page = try await mount(row: row, detail: ServerExtensionDetail(summary: row))
        defer { page.close() }

        #expect(await page.waitForCell("server.extension.about.type"))
        #expect(page.texts(in: "server.extension.about.type") == ["Type", "Built-in plugin"])
        #expect(page.texts(in: "server.extension.about.from") == ["From", "Oppi", "/opt/oppi/plugins/ask/server.js"],
                "the path is From's subtitle")
        #expect(page.texts(in: "server.extension.about.runsIn") == ["Runs In", "Host and sandbox"])
        #expect(page.texts(in: "server.extension.tool.plugin.ask") == ["ask"])
        #expect(page.controller.sections().compactMap(\.header).filter { $0.contains("Tools") } == ["Tools"],
                "one Tools section, without a Plugin prefix")
    }

    @Test func aPiExtensionsToolsShowTheFirstLineOfTheirDescriptions() async throws {
        let row = summary(
            id: "workflow", name: "workflow", kind: .file,
            provenance: .init(kind: .piAgent, label: "~/.pi/agent/extensions"),
            path: "/Users/alex/.pi/agent/extensions/workflow.ts", kinds: [.piExtension], source: .owner
        )
        let detail = ServerExtensionDetail(
            summary: row,
            contributedTools: ["workflow_run", "workflow_status"],
            contributedToolDetails: [
                ServerToolSummary(name: "workflow_run", description: "Runs a workflow.\nThen reports each step."),
                ServerToolSummary(name: "workflow_status"),
            ]
        )
        let page = try await mount(row: row, detail: detail)
        defer { page.close() }

        #expect(await page.waitForCell("server.extension.tool.piExtension.workflow_run"))
        #expect(page.texts(in: "server.extension.tool.piExtension.workflow_run") == ["workflow_run", "Runs a workflow."])
        #expect(page.texts(in: "server.extension.tool.piExtension.workflow_status") == ["workflow_status"])
        #expect(page.texts(in: "server.extension.about.type") == ["Type", "Owner Pi extension · File"])
        #expect(page.cell("server.extension.about.runsIn") == nil, "a classic extension has no runtimes")
    }

    @Test func aPackageThatIsBothKindsSplitsItsToolsByTheSessionsTheyReach() async throws {
        let row = summary(
            id: "webtools", name: "webtools", kind: .package,
            provenance: .init(kind: .package, label: "npm:@alex/webtools"),
            path: "/opt/node_modules/@alex/webtools/index.ts", packageName: "@alex/webtools",
            kinds: [.plugin, .piExtension], source: .owner,
            plugin: plugin(runtimes: ["host"], tools: ["web_search"])
        )
        let detail = ServerExtensionDetail(summary: row, contributedTools: ["web_search"])
        let page = try await mount(row: row, detail: detail)
        defer { page.close() }

        #expect(await page.waitForCell("server.extension.tool.piExtension.web_search"))
        #expect(page.cell("server.extension.tool.plugin.web_search") != nil, "one row per session kind")
        #expect(page.controller.sections().compactMap(\.header).filter { $0.contains("Tools") }
            == ["Tools in Durable Sessions", "Tools in Pi Sessions"])
        #expect(page.texts(in: "server.extension.about.type") == ["Type", "Owner plugin and Pi extension · Package"])
        #expect(page.texts(in: "server.extension.about.from") == ["From", "@alex/webtools", "/opt/node_modules/@alex/webtools/index.ts"])
    }

    // MARK: - Harness

    /// The page over `row` and its `detail`, in a window tall enough that every row
    /// is loaded.
    private func mount(row: ServerExtensionSummary, detail: ServerExtensionDetail) async throws -> MountedDetailPage {
        let answers = ExtensionDetailAnswers(
            catalog: ServerExtensionCatalog(extensions: [row]), detail: detail, enabled: row
        )
        let routes = TestURLProtocol.routeScope(mockPageRoutes { request in try answers.answer(for: request) })
        let root = try await makeTestAppRoot(
            readyServerId: ExtensionDetailAnswers.serverId,
            apiClient: makeTestURLProtocolClient(host: ExtensionDetailAnswers.host)
        )
        let connection = root.coordinator.activeConnection
        let api = try #require(connection.apiClient)
        connection.serverResourceStore.switchServer(to: ExtensionDetailAnswers.serverId)
        await connection.serverResourceStore.load(serverId: ExtensionDetailAnswers.serverId, api: api)
        let page = ServerExtensionDetailViewController(
            target: ServerResourceDetailNavTarget(serverId: ExtensionDetailAnswers.serverId, kind: .extension, resourceId: row.id),
            root: root,
            connection: connection
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2000)
        let navigation = UINavigationController(rootViewController: page)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        return MountedDetailPage(controller: page, navigation: navigation, window: window, routes: routes)
    }

    private func summary(
        id: String,
        name: String,
        kind: ServerExtensionKind,
        provenance: ServerResourceProvenance,
        path: String?,
        packageName: String? = nil,
        kinds: [ServerExtensionRowKind],
        source: ServerExtensionSource,
        plugin: ServerPluginSummary? = nil
    ) -> ServerExtensionSummary {
        ServerExtensionSummary(
            id: id, name: name, description: nil, kind: kind, provenance: provenance, path: path,
            packageName: packageName, state: .on, loadError: nil, warnings: [], isRemovable: false,
            kinds: kinds, source: source, plugin: plugin
        )
    }

    private func plugin(runtimes: [String], tools: [String], sections: [String] = []) -> ServerPluginSummary {
        ServerPluginSummary(
            extensionName: "plugin", required: false, enabled: true, runtimes: runtimes, tools: tools,
            hooks: [], sections: sections, wraps: [], tasks: [], loadError: nil, kept: false
        )
    }
}

/// A detail page on screen, and what a test reads off it.
@MainActor
struct MountedDetailPage {
    let controller: ServerExtensionDetailViewController
    let navigation: UINavigationController
    let window: UIWindow
    let routes: TestURLProtocol.RouteScope

    func close() {
        hideTestWindow(window)
        window.rootViewController = nil
        routes.end()
    }

    /// Waits for the row `identifier` once the detail has landed.
    func waitForCell(_ identifier: String) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            controller.view.layoutIfNeeded()
            return cell(identifier) != nil
        }
    }

    /// The loaded row or row button whose identifier is `identifier`.
    func cell(_ identifier: String) -> UIView? {
        controller.view.layoutIfNeeded()
        return Self.view(identifier, in: controller.collectionView)
    }

    /// The row's text in reading order: every label and text view under it.
    func texts(in identifier: String) -> [String] {
        guard let row = cell(identifier) else { return [] }
        let cellView = sequence(first: row, next: \.superview).first { $0 is UICollectionViewCell } ?? row
        return Self.texts(in: cellView)
    }

    private static func view(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier, !view.isHidden { return view }
        for subview in view.subviews {
            if let found = Self.view(identifier, in: subview) { return found }
        }
        return nil
    }

    private static func texts(in view: UIView) -> [String] {
        if view.isHidden { return [] }
        if let label = view as? UILabel { return label.text.map { [$0] } ?? [] }
        if let text = view as? UITextView { return [text.text] }
        return view.subviews.flatMap(texts(in:))
    }
}
