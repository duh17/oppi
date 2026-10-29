import Foundation
import Testing
import UIKit
@testable import Oppi

/// What the Allowed Hosts editor says and saves.
@Suite("Workspace Allowed Hosts draft")
struct WorkspaceAllowedHostsDraftTests {
    @Test func aWorkspaceWithoutAListShowsAllHostsAndIsNotDirty() {
        let draft = WorkspaceAllowedHostsDraft(saved: nil)
        #expect(draft.text == "*")
        #expect(!draft.isDirty(against: nil))
    }

    @Test func linesAreTrimmedAndBlankOnesDropped() {
        var draft = WorkspaceAllowedHostsDraft(saved: ["api.github.com"])
        draft.text = "  api.github.com \n\n  registry.npmjs.org\n   \n"
        #expect(draft.hosts == ["api.github.com", "registry.npmjs.org"])
        #expect(draft.isDirty(against: ["api.github.com"]))
    }

    @Test func anEmptyDraftIsAnEmptyListThatBlocksTheNetwork() {
        var draft = WorkspaceAllowedHostsDraft(saved: nil)
        draft.text = ""
        #expect(draft.hosts.isEmpty)
        // An omitted list allows everything, so an empty one is a change.
        #expect(draft.isDirty(against: nil))
        #expect(!draft.isDirty(against: []))
    }
}

/// The Workspace Settings pages, mounted over a real model and a stubbed
/// transport: what a person types reaches the server, and a refused write
/// leaves the page, the draft, and the reason on screen.
@Suite("Workspace Settings pages", .serialized)
@MainActor
struct WorkspaceSettingsPagesTests {
    private static let serverId = "s1"

    private struct Mounted {
        let page: UIViewController
        let nav: RouterNavigationController
        let model: WorkspaceSettingsModel
        let connection: ServerConnection
        let window: UIWindow
    }

    private func response(status: Int = 200, json: String) throws -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            try #require(HTTPURLResponse(
                url: URL(string: "http://localhost:7749")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
        )
    }

    private func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer.prefix(read))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func workspaceJSON(_ workspace: Workspace, name: String? = nil, updatedAt: Int64 = 1_800_000_000_000) -> String {
        """
        {"workspace":{"id":"\(workspace.id)","name":"\(name ?? workspace.name)","createdAt":0,"updatedAt":\(updatedAt)}}
        """
    }

    /// `make` builds the page over the model; the page is pushed over a root
    /// screen, as Workspace Settings pushes it.
    private func mount(
        workspace: Workspace,
        fixture: Bool = false,
        extensions: [ExtensionInfo] = [],
        sandboxMcpServers: [McpServerSummary] = [],
        _ make: (WorkspaceSettingsModel, ServerConnection, AppRootEnvironment) -> UIViewController
    ) throws -> Mounted {
        let config = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: config)
        let client = APIClient(
            environment: OppiClientEnvironment(baseURL: URL(string: "http://localhost:7749")!, bearerToken: "sk_test"),
            configuration: config
        )
        let connection = ServerConnection()
        connection.setAPIClientForTesting(client)
        connection.workspaceStore.setActiveServer(Self.serverId)
        connection.workspaceStore.upsert(workspace, serverId: Self.serverId)
        let model = fixture
            ? WorkspaceSettingsModel.screenshotFixture(
                workspace: workspace, skills: [], extensions: extensions,
                projectTrust: .trusted, sandboxMcpServers: sandboxMcpServers
            )
            : WorkspaceSettingsModel(seed: workspace)
        model.attach(connection: connection, workspace: workspace)

        let root = makeTestAppRoot()
        let page = make(model, connection, root)
        let rootScreen = UIViewController()
        let nav = RouterNavigationController(rootViewController: rootScreen)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1600)
        window.traitOverrides.appRootEnvironment = root
        window.rootViewController = nav
        window.makeKeyAndVisible()
        nav.pushViewController(page, animated: false)
        window.layoutIfNeeded()
        return Mounted(page: page, nav: nav, model: model, connection: connection, window: window)
    }

    private func close(_ mounted: Mounted) {
        mounted.window.isHidden = true
        mounted.window.rootViewController = nil
    }

    private func find<T: UIView>(_ type: T.Type, _ identifier: String, in view: UIView) -> T? {
        if let hit = view as? T, view.accessibilityIdentifier == identifier { return hit }
        for child in view.subviews { if let hit = find(type, identifier, in: child) { return hit } }
        return nil
    }

    /// The row's view, once the list has laid it out.
    private func waitFor<T: UIView>(_ type: T.Type, _ identifier: String, in mounted: Mounted) async throws -> T {
        for _ in 0..<60 {
            mounted.window.layoutIfNeeded()
            if let hit = find(type, identifier, in: mounted.page.view) { return hit }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestFailure("\(identifier) was not on screen")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<80 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func missing(_ identifier: String, in mounted: Mounted) -> Bool {
        mounted.window.layoutIfNeeded()
        return find(UIView.self, identifier, in: mounted.page.view) == nil
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// The bar's Save button.
    private func saveItem(of mounted: Mounted) throws -> UIBarButtonItem {
        try #require(mounted.page.navigationItem.rightBarButtonItems?.first)
    }

    private func tap(_ item: UIBarButtonItem) throws {
        try #require(item.primaryAction).performWithSender(item, target: nil)
    }

    // MARK: - Network Access

    @Test func savingAllowedHostsSendsTheTypedListAndLeavesThePage() async throws {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1")
        let mounted = try mount(workspace: workspace) { model, _, root in
            WorkspaceNetworkAccessViewController(model: model, root: root)
        }
        defer { close(mounted) }
        nonisolated(unsafe) var sent: [String: Any] = [:]
        TestURLProtocol.handler = { request in
            sent = self.body(of: request)
            return try self.response(json: self.workspaceJSON(workspace))
        }

        #expect(!(try saveItem(of: mounted)).isEnabled, "nothing changed yet")
        let editor = try await waitFor(UITextView.self, "workspace.edit.allowedHosts", in: mounted)
        editor.text = "api.github.com\n  registry.npmjs.org  \n"
        editor.delegate?.textViewDidChange?(editor)
        mounted.window.layoutIfNeeded()
        let save = try saveItem(of: mounted)
        #expect(save.isEnabled)
        try tap(save)
        try await waitUntil { mounted.nav.viewControllers.count == 1 }

        let config = sent["sandboxConfig"] as? [String: Any]
        #expect(config?["allowedHosts"] as? [String] == ["api.github.com", "registry.npmjs.org"])
        #expect(mounted.nav.viewControllers.count == 1, "a saved page closes")
    }

    @Test func aRefusedAllowedHostsSaveKeepsTheDraftAndSaysWhy() async throws {
        defer { TestURLProtocol.handler = nil }
        let mounted = try mount(workspace: makeTestWorkspace(id: "w1")) { model, _, root in
            WorkspaceNetworkAccessViewController(model: model, root: root)
        }
        defer { close(mounted) }
        TestURLProtocol.handler = { _ in try self.response(status: 500, json: "{\"error\":\"disk full\"}") }

        let editor = try await waitFor(UITextView.self, "workspace.edit.allowedHosts", in: mounted)
        editor.text = "example.com"
        editor.delegate?.textViewDidChange?(editor)
        try tap(try saveItem(of: mounted))

        _ = try await waitFor(UIButton.self, "workspace.edit.networkAccess.error", in: mounted)
        #expect(mounted.nav.viewControllers.count == 2, "a refused save stays on the page")
        #expect(editor.text == "example.com")
        #expect(try saveItem(of: mounted).isEnabled, "the person can try again")
    }

    // MARK: - Instructions

    @Test func savingInstructionsWritesTheTextAndLeavesThePage() async throws {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", systemPrompt: "Old")
        let mounted = try mount(workspace: workspace) { model, _, root in
            WorkspaceInstructionsViewController(model: model, root: root)
        }
        defer { close(mounted) }
        nonisolated(unsafe) var sent: [String: Any] = [:]
        TestURLProtocol.handler = { request in
            sent = self.body(of: request)
            return try self.response(json: self.workspaceJSON(workspace))
        }

        #expect(!(try saveItem(of: mounted)).isEnabled, "nothing changed yet")
        let editor = try await waitFor(UITextView.self, "workspace.edit.instructions.editor", in: mounted)
        editor.text = "Prefer small changes."
        editor.delegate?.textViewDidChange?(editor)
        mounted.window.layoutIfNeeded()
        try tap(try saveItem(of: mounted))
        try await waitUntil { mounted.nav.viewControllers.count == 1 }

        #expect(sent["systemPrompt"] as? String == "Prefer small changes.")
        #expect(mounted.nav.viewControllers.count == 1)
    }

    @Test func aRefusedInstructionsSaveShowsTheReasonAndStays() async throws {
        defer { TestURLProtocol.handler = nil }
        let mounted = try mount(workspace: makeTestWorkspace(id: "w1")) { model, _, root in
            WorkspaceInstructionsViewController(model: model, root: root)
        }
        defer { close(mounted) }
        TestURLProtocol.handler = { _ in try self.response(status: 500, json: "{\"error\":\"disk full\"}") }

        let editor = try await waitFor(UITextView.self, "workspace.edit.instructions.editor", in: mounted)
        editor.text = "Be brief."
        editor.delegate?.textViewDidChange?(editor)
        try tap(try saveItem(of: mounted))

        let error = try await waitFor(UILabel.self, "workspace.edit.instructions.error", in: mounted)
        try await waitUntil { !error.isHidden }
        #expect(!error.isHidden)
        #expect(mounted.nav.viewControllers.count == 2)
        #expect(editor.text == "Be brief.")
    }

    // MARK: - Details

    @Test func savingDetailsSendsOnlyTheChangedFields() async throws {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", name: "Notes")
        let mounted = try mount(workspace: workspace) { model, connection, root in
            WorkspaceDetailsViewController(settings: model, connection: connection, root: root)
        }
        defer { close(mounted) }
        nonisolated(unsafe) var sent: [String: Any] = [:]
        TestURLProtocol.handler = { request in
            if request.httpMethod == "PUT" { sent = self.body(of: request) }
            return try self.response(json: self.workspaceJSON(workspace, name: "Notes 2"))
        }

        #expect(!(try saveItem(of: mounted)).isEnabled)
        let name = try await waitFor(UITextField.self, "workspace.edit.name", in: mounted)
        name.text = "Notes 2"
        name.sendActions(for: .editingChanged)
        mounted.window.layoutIfNeeded()
        try tap(try saveItem(of: mounted))
        try await waitUntil { mounted.nav.viewControllers.count == 1 }

        #expect(sent.keys.sorted() == ["name"])
        #expect(sent["name"] as? String == "Notes 2")
        #expect(mounted.nav.viewControllers.count == 1)
    }

    // MARK: - Extensions and sandbox MCP

    @Test func switchingAnExtensionOffWritesPiSettingsAndShowsTheServersAnswer() async throws {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1")
        let todos = ExtensionInfo(name: "todos", path: "~/.pi/agent/extensions/todos", kind: "file", source: "pi")
        let mounted = try mount(workspace: workspace, fixture: true, extensions: [todos]) { model, _, root in
            WorkspaceExtensionsViewController(model: model, root: root)
        }
        defer { close(mounted) }
        nonisolated(unsafe) var sent: [String: Any] = [:]
        nonisolated(unsafe) var listed = 0
        TestURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                sent = self.body(of: request)
                return try self.response(json: "{}")
            }
            listed += 1
            return try self.response(json: """
            {"extensions":[{"name":"todos","path":"~/.pi/agent/extensions/todos","kind":"file","source":"pi","enabled":false}],"projectTrust":"trusted"}
            """)
        }

        let toggle = try await waitFor(UISwitch.self, "workspace.edit.extension.todos", in: mounted)
        #expect(toggle.isOn)
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        try await waitUntil { listed > 0 }
        try await waitUntil { mounted.model.extensions.first?.enabled == false }

        #expect(sent["type"] as? String == "extensions")
        #expect(sent["path"] as? String == "~/.pi/agent/extensions/todos")
        #expect(sent["enabled"] as? Bool == false)
        #expect(sent["workspaceId"] as? String == "w1")
        let shown = try await waitFor(UISwitch.self, "workspace.edit.extension.todos", in: mounted)
        try await waitUntil { !shown.isOn }
        #expect(!shown.isOn, "the switch shows what the server answered")
    }

    @Test func anEmptySandboxMcpListPointsToMcpServers() async throws {
        let workspace = makeTestWorkspace(id: "w1")
        let mounted = try mount(workspace: workspace, fixture: true, sandboxMcpServers: []) { model, _, root in
            WorkspaceSandboxMcpViewController(model: model, root: root)
        }
        defer { close(mounted) }

        _ = try await waitFor(UIButton.self, "workspace.edit.sandboxMcp.openServers", in: mounted)
    }

    @Test func aBlockedMcpServerCannotBeSwitchedOnButAStalePickCanBeCleared() async throws {
        let workspace = makeTestWorkspace(id: "w1")
        let blocked = McpServerSummary(
            name: "filesystem", transport: "stdio", config: McpServerConfig(command: "npx", args: ["server"]),
            enabled: true, exposure: .codemode, state: "blocked", tools: [], toolExposure: nil,
            error: "Its environment references host secrets.", supportsOAuth: false
        )
        var sandbox = workspace
        sandbox.runtime = .sandbox
        sandbox.sandboxConfig = SandboxConfig(allowedHosts: nil, env: nil, mcpServers: ["gone"])
        let mounted = try mount(workspace: sandbox, fixture: true, sandboxMcpServers: [blocked]) { model, _, root in
            WorkspaceSandboxMcpViewController(model: model, root: root)
        }
        defer { close(mounted) }

        let blockedSwitch = try await waitFor(UISwitch.self, "workspace.edit.sandboxMcp.filesystem", in: mounted)
        #expect(!blockedSwitch.isEnabled, "a blocked server cannot be newly enabled")
        let stale = try await waitFor(UISwitch.self, "workspace.edit.sandboxMcp.gone", in: mounted)
        #expect(stale.isOn)
        #expect(stale.isEnabled, "a pick the server no longer lists can still be cleared")
    }
}

/// The Details draft's folder rules and the server's workspace list, over a
/// stubbed transport.
@Suite("Workspace details and list", .serialized)
@MainActor
struct WorkspaceDetailsAndListTests {
    private static let serverId = "s1"

    private func response(status: Int = 200, json: String) throws -> (Data, HTTPURLResponse) {
        (
            Data(json.utf8),
            try #require(HTTPURLResponse(
                url: URL(string: "http://localhost:7749")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
        )
    }

    private func makeConnection(_ workspaces: [Workspace]) -> ServerConnection {
        let config = URLSessionConfiguration.ephemeral
        TestURLProtocol.install(in: config)
        let client = APIClient(
            environment: OppiClientEnvironment(baseURL: URL(string: "http://localhost:7749")!, bearerToken: "sk_test"),
            configuration: config
        )
        let connection = ServerConnection()
        connection.setAPIClientForTesting(client)
        connection.setPreviewServerId(Self.serverId)
        connection.workspaceStore.setActiveServer(Self.serverId)
        for workspace in workspaces { connection.workspaceStore.upsert(workspace, serverId: Self.serverId) }
        return connection
    }

    private func statusJSON(path: String, exists: Bool) -> String {
        let issue = exists ? "null" : "\"missing\""
        return """
        {"path":"\(path)","resolvedPath":"\(path)","exists":\(exists),"isDirectory":\(exists),"isFile":false,"issue":\(issue),"message":null}
        """
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<80 where !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Details folder

    @Test func aChangedFolderCannotBeSavedUntilTheServerSaysItExists() async throws {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", name: "Notes", hostMount: "~/notes")
        let connection = makeConnection([workspace])
        let settings = WorkspaceSettingsModel(seed: workspace)
        settings.attach(connection: connection, workspace: workspace)
        let details = WorkspaceDetailsModel(settings: settings, debounce: .zero)
        nonisolated(unsafe) var exists = false
        TestURLProtocol.handler = { _ in
            try self.response(json: "{\"status\":\(self.statusJSON(path: "~/new", exists: exists))}")
        }

        details.setHostMount("~/new")
        #expect(!details.canSave, "an unchecked new folder is not saveable")
        try await waitUntil { details.folderCheck == .missing }
        #expect(details.folderCheck == .missing)
        #expect(!details.canSave, "a missing folder blocks Save")

        exists = true
        details.setHostMount("~/new ")
        details.setHostMount("~/new")
        try await waitUntil { details.folderCheck == .valid }
        #expect(details.folderCheck == .valid)
        #expect(details.canSave)
    }

    @Test func savingAFolderThatWasNeverCheckedIsRefusedWithAReason() async throws {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", hostMount: "~/notes")
        let connection = makeConnection([workspace])
        let settings = WorkspaceSettingsModel(seed: workspace)
        settings.attach(connection: connection, workspace: workspace)
        let details = WorkspaceDetailsModel(settings: settings, debounce: .seconds(60))
        TestURLProtocol.handler = { _ in throw URLError(.badServerResponse) }

        details.setHostMount("~/elsewhere")
        let outcome = await details.save()

        #expect(outcome == .failed("Folder doesn\u{2019}t exist"))
        #expect(details.error != nil)
        #expect(!details.isSaving)
    }

    @Test func creatingAMissingFolderAdoptsTheServersResolvedPath() async throws {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", hostMount: "~/notes")
        let connection = makeConnection([workspace])
        let settings = WorkspaceSettingsModel(seed: workspace)
        settings.attach(connection: connection, workspace: workspace)
        let details = WorkspaceDetailsModel(settings: settings, debounce: .zero)
        TestURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return try self.response(json: "{\"created\":true,\"status\":\(self.statusJSON(path: "/Users/me/new", exists: true))}")
            }
            return try self.response(json: "{\"status\":\(self.statusJSON(path: "~/new", exists: false))}")
        }

        details.setHostMount("~/new")
        try await waitUntil { details.folderCheck == .missing }
        details.hostPathPendingCreation = "~/new"
        await details.createHostDirectoryFromPendingPath()

        #expect(details.draft.hostMount == "/Users/me/new")
        #expect(details.hostPathPendingCreation == nil)
        #expect(details.folderCheck == .valid)
        #expect(details.canSave)
    }

    @Test func editingTheFolderDropsAnUnconfirmedCreation() async throws {
        defer { TestURLProtocol.handler = nil }
        let workspace = makeTestWorkspace(id: "w1", hostMount: "~/notes")
        let connection = makeConnection([workspace])
        let settings = WorkspaceSettingsModel(seed: workspace)
        settings.attach(connection: connection, workspace: workspace)
        let details = WorkspaceDetailsModel(settings: settings, debounce: .zero)
        TestURLProtocol.handler = { _ in
            try self.response(json: "{\"status\":\(self.statusJSON(path: "~/a", exists: false))}")
        }

        details.setHostMount("~/a")
        try await waitUntil { details.folderCheck == .missing }
        details.hostPathPendingCreation = "~/a"
        details.setHostMount("~/b")
        try await waitUntil { details.hostPathPendingCreation == nil }

        #expect(details.hostPathPendingCreation == nil, "the confirmation was for another folder")
    }

    // MARK: - List

    private func mountList(
        _ workspaces: [Workspace],
        size: CGSize = CGSize(width: 390, height: 1200)
    ) throws -> (WorkspaceListViewController, ServerConnection, UIWindow) {
        let connection = makeConnection(workspaces)
        let root = makeTestAppRoot()
        let credentials = ServerCredentials(
            host: "studio.test", port: 7749, token: "sk_test", name: "Studio", serverFingerprint: Self.serverId
        )
        let server = try #require(PairedServer(from: credentials, sortOrder: 0))
        root.coordinator.serverStore.replaceServersForPreview([server])
        root.coordinator.installPreviewConnection(connection, serverId: server.id)
        connection.workspaceStore.setActiveServer(server.id)
        for workspace in workspaces { connection.workspaceStore.upsert(workspace, serverId: server.id) }
        let list = WorkspaceListViewController(server: server, root: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.traitOverrides.appRootEnvironment = root
        window.rootViewController = RouterNavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (list, connection, window)
    }

    private func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews { if let hit = find(identifier, in: child) { return hit } }
        return nil
    }

    @Test func theListShowsOneButtonPerWorkspaceAndSaysWhenThereAreNone() async throws {
        defer { TestURLProtocol.handler = nil }
        TestURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let first = makeTestWorkspace(id: "w1", name: "Notes", hostMount: "~/notes")
        let second = makeTestWorkspace(id: "w2", name: "Scratch")
        let (list, connection, window) = try mountList([first, second])
        defer { window.isHidden = true; window.rootViewController = nil }

        try await waitUntil { window.layoutIfNeeded(); return self.find("server.workspace.w2", in: list.view) != nil }
        #expect(find("server.workspace.w1", in: list.view) is UIButton)
        #expect(find("server.workspace.w2", in: list.view) is UIButton)
        #expect(list.contentUnavailableConfiguration == nil)

        connection.workspaceStore.remove(id: "w1", serverId: connection.workspaceStore.activeServerId ?? "")
        connection.workspaceStore.remove(id: "w2", serverId: connection.workspaceStore.activeServerId ?? "")
        try await waitUntil { list.contentUnavailableConfiguration != nil }
        #expect(list.contentUnavailableConfiguration != nil, "an empty server says so")
    }

    /// Closes the error alert; the list shows one at a time.
    private func dismissAlert(in window: UIWindow) async throws {
        let alert = try #require(window.rootViewController?.presentedViewController as? UIAlertController)
        alert.dismiss(animated: false)
        try await waitUntil { window.rootViewController?.presentedViewController == nil }
    }

    @Test func deletingAWorkspaceRemovesItsRecordAndARefusedDeleteKeepsIt() async throws {
        defer { TestURLProtocol.handler = nil }
        let keep = makeTestWorkspace(id: "w1", name: "Notes")
        let (list, connection, window) = try mountList([keep])
        defer { window.isHidden = true; window.rootViewController = nil }
        let serverId = try #require(connection.workspaceStore.activeServerId)

        // A request that cannot reach the server.
        TestURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await list.deleteWorkspace(keep)
        #expect(connection.workspaceStore.workspacesByServer[serverId]?.map(\.id) == ["w1"], "an unreachable server keeps the workspace")
        try await dismissAlert(in: window)

        // A server that answers 500: the answer is a refusal, not a delete.
        TestURLProtocol.handler = { _ in try self.response(status: 500, json: "{\"error\":\"disk full\"}") }
        await list.deleteWorkspace(keep)
        #expect(connection.workspaceStore.workspacesByServer[serverId]?.map(\.id) == ["w1"], "a 500 keeps the workspace")
        let alert = try #require(window.rootViewController?.presentedViewController as? UIAlertController)
        #expect(alert.message == "disk full", "the refusal is shown")
        try await dismissAlert(in: window)

        TestURLProtocol.handler = { _ in try self.response(json: "{}") }
        await list.deleteWorkspace(keep)
        #expect(connection.workspaceStore.workspacesByServer[serverId]?.isEmpty == true)
    }

    @Test func aSecondFailureWhileTheAlertIsUpReplacesItsMessage() async throws {
        defer { TestURLProtocol.handler = nil }
        let keep = makeTestWorkspace(id: "w1", name: "Notes")
        let (list, _, window) = try mountList([keep])
        defer { window.isHidden = true; window.rootViewController = nil }

        TestURLProtocol.handler = { _ in try self.response(status: 500, json: "{\"error\":\"disk full\"}") }
        await list.deleteWorkspace(keep)
        try await waitUntil { window.rootViewController?.presentedViewController != nil }
        TestURLProtocol.handler = { _ in try self.response(status: 500, json: "{\"error\":\"quota exceeded\"}") }
        await list.deleteWorkspace(keep)

        let alert = try #require(window.rootViewController?.presentedViewController as? UIAlertController)
        #expect(alert.message == "quota exceeded", "the newer failure is the one the person reads")
    }

    @Test func aFailureWhileTheListIsCoveredShowsWhenTheListIsBack() async throws {
        defer { TestURLProtocol.handler = nil }
        let keep = makeTestWorkspace(id: "w1", name: "Notes")
        let (list, _, window) = try mountList([keep])
        defer { window.isHidden = true; window.rootViewController = nil }
        let navigation = try #require(list.navigationController)
        navigation.pushViewController(UIViewController(), animated: false)
        try await waitUntil { list.view.window == nil }

        TestURLProtocol.handler = { _ in try self.response(status: 500, json: "{\"error\":\"disk full\"}") }
        await list.deleteWorkspace(keep)
        navigation.popViewController(animated: false)

        try await waitUntil { window.rootViewController?.presentedViewController != nil }
        let alert = try #require(window.rootViewController?.presentedViewController as? UIAlertController)
        #expect(alert.message == "disk full", "an error that landed off screen is held, not dropped")
    }

    /// A swipe or VoiceOver action can outlive its row's cell: the row scrolled
    /// away, so the sheet has no row to point at. On iPad (iOS 27.1) a sheet
    /// with no popover source still presents, but with an infinite source rect
    /// and nothing to point at; it must fall back to the screen.
    @Test func theDeleteSheetOfAnOffscreenRowStillHasAPopoverSource() async throws {
        let workspaces = (0..<40).map { makeTestWorkspace(id: "w\($0)", name: "Workspace \($0)") }
        let (list, _, window) = try mountList(workspaces, size: CGSize(width: 1024, height: 700))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { window.layoutIfNeeded(); return self.find("server.workspace.w0", in: list.view) != nil }
        let swipe = try #require(list.trailingSwipeActions(for: .workspace("w0")))
        list.collectionView.setContentOffset(
            CGPoint(x: 0, y: list.collectionView.contentSize.height - list.collectionView.bounds.height),
            animated: false
        )
        window.layoutIfNeeded()
        let row = try #require(list.dataSource?.indexPath(for: .workspace("w0")))
        try #require(list.collectionView.cellForItem(at: row) == nil, "the first row is offscreen")

        try #require(swipe.actions.first).handler(try #require(swipe.actions.first), list.view) { _ in }

        try await waitUntil { window.rootViewController?.presentedViewController != nil }
        let sheet = try #require(window.rootViewController?.presentedViewController as? UIAlertController)
        #expect(sheet.preferredStyle == .actionSheet)
        let source = try #require(sheet.popoverPresentationController?.sourceView, "a popover with no source has nowhere to point on iPad")
        #expect(source.window != nil, "the fallback source is a view on screen, not the scrolled-away row")
        #expect(sheet.popoverPresentationController?.permittedArrowDirections.isEmpty == true, "with no row to point at, no arrow")

    }
}
