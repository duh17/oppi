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

    @Test func aToolWithADefinitionOpensItsPageWithItsParametersAndSchema() async throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "timeout": .object(["type": .string("number")]),
                "questions": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("object")]),
                    "description": .string("What to ask"),
                ]),
            ]),
            "required": .array([.string("questions")]),
        ])
        let row = askRow(sections: [])
        let detail = ServerExtensionDetail(
            summary: row,
            toolDefinitions: [ServerToolDefinition(
                name: "ask", description: "Asks the user structured questions.\nBundle them.",
                parameters: schema, from: .plugin
            )],
            promptSections: []
        )
        let page = try await mount(row: row, detail: detail)
        defer { page.close() }

        // The catalog row already names the tool, as a plain row: it opens once the
        // detail brings its definition.
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            page.cell("server.extension.tool.plugin.ask") is UIControl
        }, "the tool row becomes a button once the detail lands")
        #expect(page.texts(in: "server.extension.tool.plugin.ask") == ["ask", "Asks the user structured questions."])
        let toolPage: ServerExtensionToolViewController = try await page.activate("server.extension.tool.plugin.ask")

        #expect(await RowProbe.waitForRow("server.extensionTool.schema", in: toolPage.view))
        #expect(toolPage.shownItems == [.description, .parameter("questions"), .parameter("timeout"), .schema],
                "required parameters first, then the rest by name")
        #expect(RowProbe.texts(in: "server.extensionTool.description", of: toolPage.view)
            == ["Asks the user structured questions.\nBundle them."])
        #expect(RowProbe.texts(in: "server.extensionTool.parameter.questions", of: toolPage.view)
            == ["questions", "array of object · Required", "What to ask"])
        #expect(RowProbe.texts(in: "server.extensionTool.parameter.timeout", of: toolPage.view) == ["timeout", "number"])

        let reader: ServerExtensionReaderViewController = try await page.activate("server.extensionTool.schema", in: toolPage)
        guard case .code(let json, let language, _, _) = reader.content else {
            Issue.record("the schema opens as code")
            return
        }
        #expect(language == "json")
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) == schema, "the whole schema, as JSON")
    }

    @Test func aSectionWithTextOpensTheReaderWithTheWrapFooter() async throws {
        let text = "Call ask at most once per turn.\n\n- Bundle questions."
        let row = askRow(sections: ["ask-guidelines"])
        let detail = ServerExtensionDetail(
            summary: row,
            toolDefinitions: [],
            promptSections: [ServerPromptSection(name: "ask-guidelines", text: text, perConversation: false)]
        )
        let page = try await mount(row: row, detail: detail)
        defer { page.close() }

        #expect(await page.waitForCell("server.extension.section.ask-guidelines"))
        #expect(page.texts(in: "server.extension.section.ask-guidelines") == ["ask-guidelines", "Call ask at most once per turn."])
        let reader: ServerExtensionReaderViewController = try await page.activate("server.extension.section.ask-guidelines")

        guard case .markdown(let content, _, _, let raw, _) = reader.content else {
            Issue.record("a section opens as Markdown")
            return
        }
        #expect(content.hasPrefix(text))
        #expect(content.contains("a wrapping plugin can change what a session sees"), "the footer says wraps may change it")
        #expect(raw == text, "Raw is the section's own text")
        #expect(reader.hidesNavigationBar, "the reader draws its own Back")
    }

    @Test func aSectionWrittenPerConversationSaysSoAndOpensNothing() async throws {
        let row = askRow(sections: ["project_context"])
        let detail = ServerExtensionDetail(
            summary: row,
            toolDefinitions: [],
            promptSections: [ServerPromptSection(name: "project_context", perConversation: true)]
        )
        let page = try await mount(row: row, detail: detail)
        defer { page.close() }

        #expect(await page.waitForCell("server.extension.section.project_context"))
        let element = try #require(page.cell("server.extension.section.project_context"))
        #expect(element is SidebarListCell, "a read-only row: the cell is the element, no button")
        #expect((element as? SidebarListCell)?.element.isHidden == true)
        #expect((element as? SidebarListCell)?.accessories.isEmpty == true, "no chevron")
        #expect(page.texts(in: "server.extension.section.project_context")
            == ["project_context", "Written for each conversation from its workspace."])
        #expect(page.controller.sections().compactMap(\.header).filter { $0 == "Prompt Sections" }.count == 1,
                "listed once, from the detail rather than the plugin's names")
    }

    // MARK: - Harness

    private func askRow(sections: [String]) -> ServerExtensionSummary {
        summary(
            id: "ask", name: "ask", kind: .builtIn, provenance: .init(kind: .builtIn, label: "Oppi"),
            path: nil, kinds: [.plugin], source: .builtIn,
            plugin: plugin(runtimes: ["host"], tools: ["ask"], sections: sections)
        )
    }

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
        await RowProbe.waitForRow(identifier, in: controller.view)
    }

    /// The loaded row or row button whose identifier is `identifier`.
    func cell(_ identifier: String) -> UIView? {
        RowProbe.row(identifier, in: controller.view)
    }

    /// The row's text in reading order.
    func texts(in identifier: String) -> [String] {
        RowProbe.texts(in: identifier, of: controller.view)
    }

    /// Taps the row button `identifier` on `screen` (the detail page by default) and
    /// returns the page it pushed.
    func activate<Pushed: UIViewController>(
        _ identifier: String,
        in screen: UIViewController? = nil
    ) async throws -> Pushed {
        let host = screen ?? controller
        let button = try #require(RowProbe.row(identifier, in: host.view) as? UIControl, "\(identifier) is a button")
        button.sendActions(for: .touchUpInside)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { navigation.topViewController is Pushed },
                "\(identifier) pushes its page")
        let pushed = try #require(navigation.topViewController as? Pushed)
        pushed.loadViewIfNeeded()
        return pushed
    }
}

/// Finds a list's rows by identifier and reads what they draw.
@MainActor
enum RowProbe {
    /// Waits until the row `identifier` is loaded under `root`.
    static func waitForRow(_ identifier: String, in root: UIView) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) { row(identifier, in: root) != nil }
    }

    /// The visible view under `root` whose identifier is `identifier`: a read-only
    /// row's cell or a row's button.
    static func row(_ identifier: String, in root: UIView) -> UIView? {
        root.layoutIfNeeded()
        return find(identifier, in: root)
    }

    /// The row's text in reading order: every label and text view in its cell.
    static func texts(in identifier: String, of root: UIView) -> [String] {
        guard let row = row(identifier, in: root) else { return [] }
        let cell = sequence(first: row, next: \.superview).first { $0 is UICollectionViewCell } ?? row
        return texts(in: cell)
    }

    private static func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier, !view.isHidden { return view }
        for subview in view.subviews {
            if let found = find(identifier, in: subview) { return found }
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
