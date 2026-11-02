import Foundation
import Testing
import UIKit
@testable import Oppi

private func hostPathStatus(_ path: String, issue: String? = nil) -> HostPathStatus {
    HostPathStatus(
        path: path,
        resolvedPath: path,
        exists: issue != "missing",
        isDirectory: issue == nil,
        isFile: false,
        issue: issue,
        message: nil
    )
}

@Suite("Workspace folder check")
struct WorkspaceFolderCheckTests {
    @Test("an empty folder shows nothing, whatever else is known")
    func emptyFolderShowsNothing() {
        let check = WorkspaceFolderCheck(
            folder: "",
            status: hostPathStatus(""),
            validationMessage: "stale",
            isChecking: true
        )
        #expect(check == .none)
    }

    @Test("checking wins over a status that is already known")
    func checkingWins() {
        let check = WorkspaceFolderCheck(
            folder: "/tmp",
            status: hostPathStatus("/tmp"),
            validationMessage: nil,
            isChecking: true
        )
        #expect(check == .checking)
    }

    @Test("a missing folder offers to create it; a message shows as invalid; a good one is valid")
    func resolvedStates() {
        #expect(WorkspaceFolderCheck(
            folder: "/new", status: hostPathStatus("/new", issue: "missing"),
            validationMessage: "Path doesn’t exist", isChecking: false
        ) == .missing)
        #expect(WorkspaceFolderCheck(
            folder: "/file", status: nil, validationMessage: "Path is not a directory", isChecking: false
        ) == .invalid("Path is not a directory"))
        #expect(WorkspaceFolderCheck(
            folder: "/tmp", status: hostPathStatus("/tmp"), validationMessage: nil, isChecking: false
        ) == .valid)
    }

    @Test("a status for another path says nothing about this folder")
    func staleStatusIsIgnored() {
        let check = WorkspaceFolderCheck(
            folder: "/tmp/new",
            status: hostPathStatus("/tmp", issue: "missing"),
            validationMessage: nil,
            isChecking: false
        )
        #expect(check == .none)
    }
}

@Suite("Workspace create", .serialized)
@MainActor
struct WorkspaceCreateTests {
    /// How long a wait for the screen or model may take before the test fails. The waits
    /// return as soon as their condition holds, so this only bounds a failure. The shard these
    /// tests run in shares the main thread with a hundred other suites: the suggestion and Return
    /// tests took 5.1 s and 6.1 s in recorded loaded runs (0.4 s and 0.25 s when quiet), against the
    /// 5 s and 2 s deadlines that used to guard them.
    private static let patience: Duration = .seconds(30)

    // MARK: Rules

    @Test("Create needs a name, and a folder the server confirmed as a directory")
    func canCreateRules() {
        func can(_ name: String, creating: Bool = false, folder: String = "", status: HostPathStatus? = nil) -> Bool {
            WorkspaceCreateModel.canCreate(name: name, isCreating: creating, trimmedHostMount: folder, hostMountStatus: status)
        }
        #expect(!can(""))
        #expect(can("App"))
        #expect(!can("App", creating: true))
        // An empty folder lets Oppi create one.
        #expect(can("App", folder: ""))
        #expect(!can("App", folder: "/tmp"))
        #expect(!can("App", folder: "/tmp", status: hostPathStatus("/other")))
        #expect(!can("App", folder: "/new", status: hostPathStatus("/new", issue: "missing")))
        #expect(can("App", folder: "/tmp", status: hostPathStatus("/tmp")))
    }

    @Test("A deep link opens the review step with its name and folder")
    func prefillOpensConfigure() async throws {
        let fixture = try await Fixture()
        let linked = WorkspaceCreateModel(
            server: fixture.second, coordinator: fixture.coordinator, prefillName: "Deep", prefillPath: "/tmp"
        )
        #expect(linked.step == .configure)
        #expect(linked.navigationTitle == "New Workspace")
        #expect(linked.name == "Deep")
        #expect(linked.hostMount == "/tmp")
        #expect(!linked.isHostMountFromProjectPicker)

        let nameOnly = WorkspaceCreateModel(server: fixture.second, coordinator: fixture.coordinator, prefillName: "Only")
        #expect(nameOnly.step == .pickProject)
        #expect(nameOnly.navigationTitle == "Pick a Project")
        #expect(nameOnly.name == "Only")
    }

    @Test("The sandbox footer names the folder Oppi will create from the name")
    func sandboxFolderPreview() async throws {
        let fixture = try await Fixture()
        let model = WorkspaceCreateModel(server: fixture.second, coordinator: fixture.coordinator)
        model.sandboxMode = true
        model.name = "My Project"
        #expect(model.folderFooter.hasSuffix("~/sandbox/my-project/"))
        model.setHostMount("/tmp")
        #expect(!model.folderFooter.contains("~/sandbox/"))
    }

    @Test("Picking a project fills the form and skips the folder check's suggestions")
    func selectProjectFillsForm() async throws {
        let fixture = try await Fixture()
        let model = WorkspaceCreateModel(server: fixture.second, coordinator: fixture.coordinator)
        model.selectProject(Fixture.project)
        #expect(model.step == .configure)
        #expect(model.name == "oppi")
        #expect(model.hostMount == "~/workspace/oppi")
        #expect(model.isHostMountFromProjectPicker)
        #expect(model.gitStatusEnabled)
        #expect(model.canCreate)
        model.changeProject()
        #expect(model.step == .pickProject)
        model.selectBlank()
        #expect(model.name.isEmpty && model.hostMount.isEmpty && !model.gitStatusEnabled)
    }

    // MARK: Server scope

    @Test("Oppi and create work on the sheet's server, not the active one")
    func createsOnTheSheetsServer() async throws {
        let fixture = try await Fixture()
        #expect(fixture.coordinator.activeServerId == fixture.first.id)
        let model = WorkspaceCreateModel(server: fixture.second, coordinator: fixture.coordinator)
        #expect(model.oppiConnection === fixture.coordinator.connection(for: fixture.second.id))
        #expect(model.oppiConnection !== fixture.coordinator.connection(for: fixture.first.id))

        model.name = "Fresh"
        let workspace = try #require(await model.create())
        #expect(workspace.id == "w-new")
        let second = try #require(fixture.coordinator.connection(for: fixture.second.id))
        #expect(second.workspaceStore.workspacesByServer[fixture.second.id]?.map(\.id) == ["w-new"])
        #expect(WorkspaceCreateURLProtocol.requests.contains { $0.method == "POST" && $0.host == Fixture.secondHost })
        #expect(!WorkspaceCreateURLProtocol.requests.contains { $0.host == Fixture.firstHost })
    }

    @Test("A typed folder is checked on the server before Create is allowed")
    func typedFolderIsChecked() async throws {
        let fixture = try await Fixture()
        let model = WorkspaceCreateModel(server: fixture.second, coordinator: fixture.coordinator)
        model.start()
        defer { model.stop() }
        model.selectManual()
        model.name = "Tmp"
        model.setHostMount("/tmp")
        #expect(!model.canCreate)
        #expect(await waitForMainActorCondition(timeout: Self.patience) { model.canCreate })
        #expect(model.folderCheck == .valid)

        model.setHostMount("/nope")
        #expect(!model.canCreate)
        #expect(await waitForMainActorCondition(timeout: Self.patience) { model.folderCheck == .missing })
        #expect(!model.canCreate)
    }

    // MARK: Screen

    @Test("With no workspaces, Create with Oppi sends from the guided composer, closes both sheets, and opens the control session")
    func createWithOppiSendsWithNoWorkspaces() async throws {
        let fixture = try await Fixture()
        for server in [fixture.first, fixture.second] {
            let store = try #require(fixture.coordinator.connection(for: server.id)).workspaceStore
            #expect(store.workspaces.isEmpty)
        }
        let presenter = UIViewController()
        let window = try showInWindow(presenter)
        defer { hide(window) }
        let screen = WorkspaceCreateViewController(root: fixture.root, server: fixture.second)
        Router.present(screen, presentation: .sheet.inNavigation(), from: presenter, theme: fixture.root.themeStore)
        #expect(await waitForMainActorCondition(timeout: Self.patience) { isSettled(presenter.presentedViewController) })

        let row = try #require(await findButton("workspace.create.createWithOppi", in: screen.view))
        #expect(row.accessibilityLabel == "Create with Oppi")
        row.sendActions(for: .touchUpInside)

        let createSheet = try #require(presenter.presentedViewController)
        #expect(await waitForMainActorCondition(timeout: Self.patience) {
            isSettled(createSheet.presentedViewController)
        })
        let guided = try #require(
            (createSheet.presentedViewController as? UINavigationController)?.viewControllers.first
                as? GuidedControlSessionViewController
        )
        #expect(guided.title == "Create Workspace")

        // The composer's own setup and send, as the Send button runs them.
        let model = try #require(guided.children.compactMap { $0 as? GuidedControlComposerController }.first).model
        model.appear()
        #expect(await waitForMainActorCondition(timeout: Self.patience) { model.isInitialized })
        #expect(model.selectedWorkspace == nil)
        #expect(model.acceptsInput)
        model.request = "A workspace for my notes"
        // This device already allowed the server's default model provider, so Send goes out.
        let consentServerId = try #require(fixture.coordinator.connection(for: fixture.second.id)?.currentServerId)
        let provider = try #require(AISharingConsent.Recipient.modelProvider("anthropic"))
        AISharingConsent.device.grant(provider, serverId: consentServerId)
        defer { AISharingConsent.device.withdraw(provider, serverId: consentServerId) }
        model.send()

        let target = WorkspaceSessionNavTarget(serverId: fixture.second.id, sessionId: "control-1", routeScope: .control)
        #expect(await waitForMainActorCondition(timeout: Self.patience) {
            presenter.presentedViewController == nil
                && fixture.root.navigation.workspaceStackRouteElements.contains(.session(target))
        })
        let posts = WorkspaceCreateURLProtocol.requests.filter { $0.method == "POST" && $0.path == "/control-sessions" }
        #expect(posts.map(\.host) == [Fixture.secondHost])
    }

    @Test("Both steps offer Create with Oppi, and a server with no connection does not")
    func createWithOppiShowsInBothSteps() async throws {
        let fixture = try await Fixture()
        let pick = WorkspaceCreateViewController(root: fixture.root, server: fixture.second)
        let configure = WorkspaceCreateViewController(
            root: fixture.root, server: fixture.second, prefillName: "A", prefillPath: "/tmp"
        )
        for screen in [pick, configure] {
            let window = try showInWindow(screen)
            defer { hide(window) }
            #expect(await findButton("workspace.create.createWithOppi", in: screen.view) != nil)
        }

        let offline = try PairedServer(from: makeTestCredentials(host: "offline.test", fingerprint: "sha256:offline"), sortOrder: 9)
        let screen = WorkspaceCreateViewController(root: fixture.root, server: try #require(offline))
        let window = try showInWindow(screen)
        defer { hide(window) }
        #expect(await findButton("workspace.create.manual", in: screen.view) != nil)
        #expect(await findButton("workspace.create.createWithOppi", in: screen.view, timeout: .milliseconds(300)) == nil)
    }

    @Test("Tapping a suggestion replaces the text being typed, in the field and in the model")
    func suggestionReplacesTypedText() async throws {
        let fixture = try await Fixture()
        let screen = WorkspaceCreateViewController(
            root: fixture.root, server: fixture.second, prefillName: "App", prefillPath: "/tmp"
        )
        let window = try showInWindow(screen)
        defer { hide(window) }
        let field = try #require(await findTextField("workspace.create.hostMount", in: screen.view))

        // The user is mid-edit: the field is first responder with a prefix typed.
        #expect(field.becomeFirstResponder())
        field.text = "~/wo"
        field.sendActions(for: .editingChanged)
        #expect(screen.model.hostMount == "~/wo")

        let suggestion = try #require(await findButton("workspace.create.suggestion.~/workspace", in: screen.view, timeout: Self.patience))
        suggestion.sendActions(for: .touchUpInside)

        #expect(screen.model.hostMount == "~/workspace")
        #expect(await waitForMainActorCondition(timeout: Self.patience) { field.text == "~/workspace" })
        #expect(field.text == screen.model.hostMount)
    }

    @Test("Return in Name moves to the folder field; Return in the folder field closes the keyboard")
    func returnKeyMovesThroughFields() async throws {
        let fixture = try await Fixture()
        let screen = WorkspaceCreateViewController(
            root: fixture.root, server: fixture.second, prefillName: "App", prefillPath: "/tmp"
        )
        let window = try showInWindow(screen)
        defer { hide(window) }
        let name = try #require(await findTextField("workspace.create.name", in: screen.view))
        let folder = try #require(await findTextField("workspace.create.hostMount", in: screen.view))

        #expect(name.becomeFirstResponder())
        #expect(name.returnKeyType == .next)
        name.sendActions(for: .editingDidEndOnExit)
        #expect(folder.isFirstResponder)
        #expect(!name.isFirstResponder)

        #expect(folder.returnKeyType == .done)
        folder.sendActions(for: .editingDidEndOnExit)
        #expect(await waitForMainActorCondition(timeout: Self.patience) { !folder.isFirstResponder })
    }

    /// The kit redraws only the rows whose `inputs(of:)` changed, so the form
    /// keys the Name row by what it draws and never by its text: typing leaves
    /// that row alone — focus, caret, and the text the person typed — while the
    /// rows that follow the name still change. With the base's per-pass key (or a
    /// key holding the name) the field is configured again on each pass, which is
    /// what the probe below fails on.
    @Test("Typing in a field never configures its row again, and the form still follows it")
    func typingInAFieldLeavesItsRowAlone() async throws {
        let fixture = try await Fixture()
        let screen = WorkspaceCreateViewController(
            root: fixture.root, server: fixture.second, prefillName: "App", prefillPath: "/tmp"
        )
        let window = try showInWindow(screen, height: 2400)
        defer { hide(window) }
        let name = try #require(await findTextField("workspace.create.name", in: screen.view))
        let submit = try #require(await findButton("workspace.create.submit.form", in: screen.view))
        // The server confirms the folder before Create is offered at all.
        #expect(await waitForMainActorCondition(timeout: Self.patience) { submit.isEnabled })

        #expect(name.becomeFirstResponder())
        // A field's configure restores its placeholder, so the test stamps its own:
        // a placeholder that survives a pass is a row the kit left alone.
        let probe = "typed-row-probe"
        name.placeholder = probe

        name.text = "App Two"
        name.sendActions(for: .editingChanged)
        #expect(screen.model.name == "App Two")
        // A pass of its own (a theme repaint, a scan landing) leaves the field
        // where the person left it; the form's own rows still read the name.
        screen.setNeedsUpdateProperties()
        try await Task.sleep(for: .milliseconds(200))
        screen.view.layoutIfNeeded()
        #expect(name.placeholder == probe, "a pass configured the field's row again")
        #expect(name.isFirstResponder, "a pass took the keyboard from the field")
        #expect(name.text == "App Two", "a pass rewrote what the person typed")

        // The submit row follows the name: an empty one cannot create.
        name.text = ""
        name.sendActions(for: .editingChanged)
        #expect(await waitForMainActorCondition(timeout: Self.patience) {
            screen.view.layoutIfNeeded()
            return !submit.isEnabled
        })
        #expect(name.placeholder == probe, "the submit row's redraw configured the field again")
        #expect(name.isFirstResponder, "the submit row's redraw took the keyboard from the field")
    }

    /// The other step opens at its top. The pass that swaps the rows does not lay
    /// the screen out, so a reset that waits for the next layout lands whenever
    /// something else moves the view — the keyboard rising, at the form's own
    /// scroll position, is the case that hurts. Two long lists make the case: a
    /// short new step would be clamped to the top by the list itself.
    @Test("Changing the step puts the form back at its top")
    func changingTheStepScrollsToTheTop() async throws {
        let fixture = try await Fixture()
        let screen = WorkspaceCreateViewController(root: fixture.root, server: fixture.second)
        let window = try showInWindow(screen, height: 600)
        defer { hide(window) }
        let list = screen.collectionView
        let top = { -list.adjustedContentInset.top }

        // The person scrolled the project picker down.
        #expect(await waitForMainActorCondition(timeout: Self.patience) {
            screen.view.layoutIfNeeded()
            return list.contentSize.height > list.bounds.height
        })
        list.setContentOffset(CGPoint(x: 0, y: top() + 120), animated: false)
        #expect(list.contentOffset.y > top())

        // Picking a project swaps that list for the form's. Nothing lays the
        // screen out here, so only the page's own reset can put it back at the top.
        screen.model.selectProject(Fixture.project)
        var reset = false
        for _ in 0..<40 {
            if abs(list.contentOffset.y - top()) < 1 { reset = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(reset, "the other step opens at its top")
    }

    // MARK: Helpers

    private func findTextField(
        _ identifier: String,
        in view: UIView,
        timeout: Duration = Self.patience
    ) async -> UITextField? {
        var found: UITextField?
        _ = await waitForMainActorCondition(timeout: timeout) {
            view.layoutIfNeeded()
            found = Self.subviews(of: UITextField.self, in: view).first { $0.accessibilityIdentifier == identifier }
            return found != nil
        }
        return found
    }

    private func findButton(
        _ identifier: String,
        in view: UIView,
        timeout: Duration = Self.patience
    ) async -> UIButton? {
        var found: UIButton?
        _ = await waitForMainActorCondition(timeout: timeout) {
            view.layoutIfNeeded()
            found = Self.subviews(of: UIButton.self, in: view).first { $0.accessibilityIdentifier == identifier }
            return found != nil
        }
        return found
    }

    private static func subviews<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        var all: [T] = []
        view.layoutIfNeeded()
        for subview in view.subviews {
            if let match = subview as? T { all.append(match) }
            all += subviews(of: type, in: subview)
        }
        return all
    }

    private func showInWindow(_ controller: UIViewController, height: CGFloat = 844) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    private func hide(_ window: UIWindow) {
        window.rootViewController?.dismiss(animated: false)
        hideTestWindow(window)
        window.rootViewController = nil
    }

    private func isSettled(_ presented: UIViewController?) -> Bool {
        guard let presented else { return false }
        return !presented.isBeingPresented && presented.viewIfLoaded?.window != nil
    }

    /// Two paired servers whose API clients answer from `WorkspaceCreateURLProtocol`;
    /// the first is active, the second is the one the sheet creates on.
    @MainActor
    struct Fixture {
        static let firstHost = "create-first.test"
        static let secondHost = "create-second.test"
        static let project = HostDirectory(
            path: "~/workspace/oppi", name: "oppi", isGitRepo: true, gitRemote: nil,
            hasAgentsMd: true, projectType: "swift", language: "Swift"
        )

        let coordinator: ConnectionCoordinator
        let root: AppRootEnvironment
        let first: PairedServer
        let second: PairedServer

        init() async throws {
            WorkspaceCreateURLProtocol.reset()
            func server(_ host: String, _ order: Int) throws -> PairedServer {
                let credentials = makeTestCredentials(host: host, name: host, fingerprint: "sha256:\(host)")
                return try #require(PairedServer(from: credentials, sortOrder: order))
            }
            first = try server(Self.firstHost, 0)
            second = try server(Self.secondHost, 1)
            let serverStore = ServerStore()
            serverStore.replaceServersForPreview([first, second])
            coordinator = ConnectionCoordinator(serverStore: serverStore)
            for server in [first, second] {
                await coordinator.ensureTestConnectionReady(for: server).setAPIClientForTesting(
                    WorkspaceCreateURLProtocol.makeClient(host: server.credentials.host)
                )
            }
            #expect(coordinator.restoreActiveServer(first.id))
            root = makeTestAppRoot(coordinator: coordinator)
        }
    }
}

/// Answers the workspace-creation endpoints, and records who was asked.
final class WorkspaceCreateURLProtocol: URLProtocol, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let host: String
        let path: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Request] = []

    static var requests: [Request] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = [] } }

    static func makeClient(host: String) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkspaceCreateURLProtocol.self]
        return APIClient(
            baseURL: URL(string: "https://\(host)") ?? URL(fileURLWithPath: "/"),
            token: "test-token",
            configuration: config
        )
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasPrefix("create-") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock {
            Self.recorded.append(Request(method: request.httpMethod ?? "GET", host: url.host ?? "", path: url.path))
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body: String
        switch url.path {
        case "/host/directories":
            // A folder's worth of projects, so the picker step is a list a person
            // scrolls: a step change that swaps one long list for another is where
            // the form's scroll position matters.
            let projects = (1...8).map { index -> String in
                let name = index == 1 ? "oppi" : "project-\(index)"
                let fields = "\"path\":\"~/workspace/\(name)\",\"name\":\"\(name)\","
                    + "\"isGitRepo\":true,\"gitRemote\":null,\"hasAgentsMd\":false,"
                    + "\"projectType\":\"swift\",\"language\":\"Swift\""
                return "{\(fields)}"
            }
            body = "{\"directories\":[\(projects.joined(separator: ","))]}"
        case "/host/path/status":
            let path = query.first { $0.name == "path" }?.value ?? ""
            let missing = path == "/nope"
            body = """
            {"status":{"path":"\(path)","resolvedPath":"\(path)","exists":\(!missing),"isDirectory":\(!missing),"isFile":false,"issue":\(missing ? "\"missing\"" : "null"),"message":null}}
            """
        case "/host/path/completions":
            let prefix = query.first { $0.name == "prefix" }?.value ?? ""
            body = prefix == "~/wo"
                ? #"{"completions":[{"path":"~/workspace","name":"workspace"}]}"#
                : #"{"completions":[]}"#
        case "/skills":
            body = #"{"skills":[]}"#
        case "/models":
            body = #"{"models":[{"id":"claude","name":"Claude","provider":"anthropic","contextWindow":200000,"isDefault":true}]}"#
        case "/control-sessions":
            body = #"{"session":{"id":"control-1","status":"ready","createdAt":0,"lastActivity":0,"messageCount":0,"tokens":{"input":0,"output":0},"cost":0,"engine":"durable","serverDurable":{"role":"control"}},"prompted":true}"#
        case "/workspaces":
            body = #"{"workspace":{"id":"w-new","name":"Fresh","skills":[],"createdAt":0,"updatedAt":0}}"#
        default:
            body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
