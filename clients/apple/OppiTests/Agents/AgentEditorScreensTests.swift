import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Edit Agent screens")
struct AgentEditorScreensTests {
    private static let serverId = "agent-editor-tests"

    private func makeConnection() -> ServerConnection {
        let connection = ServerConnection()
        connection.setPreviewServerId(Self.serverId)
        connection.serverResourceStore.replaceExtensions(
            [],
            builtInTools: [
                ServerToolSummary(name: "read", description: "Read files.", defaultEnabled: true),
                ServerToolSummary(name: "grep", description: "Search files.", defaultEnabled: true),
                ServerToolSummary(name: "browser", description: "Drive a browser.", defaultEnabled: false),
            ],
            serverId: Self.serverId
        )
        return connection
    }

    private func makeAgent(tools: [String]? = ["read"], skillPaths: [String]? = nil) -> StoredAgentDefinition {
        StoredAgentDefinition(
            id: "agent-editor-tests",
            name: "Design Reviewer",
            icon: .defaultValue,
            description: nil,
            status: .active,
            version: 1,
            definition: AgentDefinition(
                name: "Design Reviewer",
                icon: .defaultValue,
                resources: skillPaths.map { AgentResources(skillPaths: $0) },
                sessionDefaults: AgentSessionDefaults(tools: tools)
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            archivedAt: nil
        )
    }

    private func makeEditor(tools: [String]? = ["read"]) -> AgentNativeEditViewController {
        AgentNativeEditViewController(
            agent: makeAgent(tools: tools),
            apiClient: nil,
            connection: makeConnection(),
            serverName: "mac-studio"
        ) { _ in }
    }

    // MARK: - The editor

    @Test("Save waits for a name, and the custom prompt's rows and footer follow its switches")
    func saveAndPromptRows() async throws {
        let screen = try Screen(makeEditor())
        defer { screen.hide() }

        #expect(await screen.waitFor { screen.root.navigationItem.rightBarButtonItem != nil })
        let save = try #require(screen.root.navigationItem.rightBarButtonItem)
        #expect(await screen.waitFor { save.isEnabled }, "a named Agent can be saved")
        #expect(screen.footer("Uses the server's default system prompt."))
        #expect(screen.button("agent.nativeEdit.promptMode") == nil, "no custom prompt, no Append/Replace")

        let name = try #require(await screen.waitForTextView("agent.nativeEdit.name"))
        #expect(name.text == "Design Reviewer")
        Screen.type("  ", into: name)
        #expect(await screen.waitFor { !save.isEnabled }, "a blank name cannot be saved")
        Screen.type("Design Reviewer", into: name)
        #expect(await screen.waitFor { save.isEnabled })

        // The name is one line: Return ends editing and a pasted line break becomes a space.
        let delegate = try #require(name.delegate)
        let end = NSRange(location: name.text.utf16.count, length: 0)
        #expect(delegate.textView?(name, shouldChangeTextIn: end, replacementText: "\n") == false)
        #expect(delegate.textView?(name, shouldChangeTextIn: end, replacementText: "v2\nfinal") == false)
        #expect(name.text == "Design Reviewerv2 final")
        Screen.type("Design Reviewer", into: name)

        let toggle = try #require(await screen.waitForSwitch("agent.nativeEdit.customPrompt"))
        toggle.isOn = true
        toggle.sendActions(for: .valueChanged)
        #expect(await screen.waitFor {
            screen.footer("Adds these instructions after the server's default system prompt.")
        })
        #expect(!save.isEnabled, "a custom prompt needs text")

        let mode = try #require(await screen.waitForButton("agent.nativeEdit.promptMode"))
        #expect(mode.accessibilityValue == "Append")
        try Screen.choose("Replace", in: mode)
        #expect(await screen.waitFor {
            screen.footer("Uses these instructions instead of the server's default system prompt.")
        })
        #expect(screen.button("agent.nativeEdit.promptMode")?.accessibilityValue == "Replace")
    }

    @Test("a choice made on the Tools page shows on the editor's Tools row")
    func toolsPageEditsTheDraft() async throws {
        let screen = try Screen(makeEditor())
        defer { screen.hide() }

        let row = try #require(await screen.waitForButton("agent.nativeEdit.tools"))
        #expect(row.accessibilityValue == "1 selected")
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentToolSelectionViewController.self))

        let mode = try #require(await screen.waitForButton("agent.nativeEdit.toolMode", in: page.view))
        #expect(mode.accessibilityValue == "Choose tools")
        #expect(screen.button("agent.nativeEdit.tool.grep", in: page.view)?.accessibilityValue == "Not selected")

        // Choosing a tool changes the draft at once.
        let grep = try #require(await screen.waitForButton("agent.nativeEdit.tool.grep", in: page.view))
        grep.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.tool.grep", in: page.view)?.accessibilityValue == "Selected" })
        #expect(screen.button("agent.nativeEdit.tool.grep", in: page.view)?.accessibilityTraits.contains(.selected) == true)

        // Back to Pi defaults, and the editor's row says so.
        try Screen.choose("Pi defaults", in: mode)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.tool.grep", in: page.view) == nil }, "defaults list no tools")
        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.tools")?.accessibilityValue == "Pi defaults"
        })
    }

    @Test("Choose tools starts the list from the defaults, and Select None empties it")
    func chooseToolsStartsFromDefaults() async throws {
        let screen = try Screen(makeEditor(tools: nil))
        defer { screen.hide() }
        let row = try #require(await screen.waitForButton("agent.nativeEdit.tools"))
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentToolSelectionViewController.self))

        let mode = try #require(await screen.waitForButton("agent.nativeEdit.toolMode", in: page.view))
        #expect(mode.accessibilityValue == "Pi defaults")
        try Screen.choose("Choose tools", in: mode)
        // `read` and `grep` are on by default, `browser` is not.
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.tool.read", in: page.view)?.accessibilityValue == "Selected"
                && screen.button("agent.nativeEdit.tool.grep", in: page.view)?.accessibilityValue == "Selected"
                && screen.button("agent.nativeEdit.tool.browser", in: page.view)?.accessibilityValue == "Not selected"
        })

        let actions = try #require(page.navigationItem.rightBarButtonItem)
        #expect(actions.accessibilityLabel == "Tool selection actions")
        try Screen.perform("Select None", in: actions)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.tool.read", in: page.view)?.accessibilityValue == "Not selected"
        })
        try Screen.perform("Select All", in: actions)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.tool.browser", in: page.view)?.accessibilityValue == "Selected"
        })
    }

    @Test("a saved tool the catalog no longer lists stays deselectable under Unavailable Selections")
    func unavailableToolStaysDeselectable() async throws {
        let screen = try Screen(makeEditor(tools: ["read", "retired-tool"]))
        defer { screen.hide() }
        let row = try #require(await screen.waitForButton("agent.nativeEdit.tools"))
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentToolSelectionViewController.self))

        let retired = try #require(await screen.waitForButton("agent.nativeEdit.tool.retired-tool", in: page.view))
        #expect(retired.accessibilityValue == "Selected, Unavailable")
        #expect(retired.isEnabled, "a chosen tool can always be removed")
        retired.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.tool.retired-tool", in: page.view) == nil
        })
    }

    @Test("the Skills page lists the catalog, refuses a Skill that cannot load, and keeps a saved path the server dropped")
    func skillsPageChoices() async throws {
        let connection = makeConnection()
        let provenance = ServerResourceProvenance(kind: .piAgent, label: "~/.pi/agent/skills")
        connection.serverResourceStore.replaceSkills([
            ServerSkillSummary(
                id: "release", name: "release", description: "Review release readiness.", provenance: provenance,
                path: "/skills/release/SKILL.md", state: .enabled, loadError: nil, warnings: [], editable: true
            ),
            ServerSkillSummary(
                id: "broken", name: "broken", description: "Invalid frontmatter.", provenance: provenance,
                path: "/skills/broken/SKILL.md", state: .error, loadError: "Missing description.", warnings: [], editable: true
            ),
        ], serverId: Self.serverId)
        let editor = AgentNativeEditViewController(
            agent: makeAgent(skillPaths: ["/skills/retired/SKILL.md"]),
            apiClient: nil, connection: connection, serverName: "mac-studio"
        ) { _ in }
        let screen = try Screen(editor)
        defer { screen.hide() }

        let row = try #require(await screen.waitForButton("agent.nativeEdit.skills"))
        #expect(row.accessibilityValue == "1")
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentResourceSelectionViewController.self))

        let release = try #require(await screen.waitForButton("agent.nativeEdit.skill./skills/release/SKILL.md", in: page.view))
        #expect(release.accessibilityValue == "Not selected")
        let broken = try #require(screen.button("agent.nativeEdit.skill./skills/broken/SKILL.md", in: page.view))
        #expect(broken.accessibilityValue == "Not selected, Missing description.")
        #expect(!broken.isEnabled, "a Skill that cannot load cannot be chosen")
        let retired = try #require(screen.button("agent.nativeEdit.skill./skills/retired/SKILL.md", in: page.view))
        #expect(retired.accessibilityValue == "Selected, Unavailable")
        #expect(retired.isEnabled, "a saved path can always be deselected")

        release.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.skill./skills/release/SKILL.md", in: page.view)?.accessibilityValue == "Selected"
        })
        retired.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.skill./skills/retired/SKILL.md", in: page.view) == nil
        }, "deselecting an unavailable path removes its row")
        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.skills")?.accessibilityValue == "1" })
    }

    @Test("an unlisted workspace stays choosable when it is already chosen, and the runtime filters the rest")
    func workspacePageFiltersByRuntime() async throws {
        let connection = makeConnection()
        connection.workspaceStore.workspacesByServer[Self.serverId] = [
            Workspace(id: "ws-host", name: "On the host", runtime: .host, createdAt: .now, updatedAt: .now),
            Workspace(id: "ws-box", name: "In a sandbox", runtime: .sandbox, createdAt: .now, updatedAt: .now),
        ]
        let editor = AgentNativeEditViewController(
            agent: makeAgent(), apiClient: nil, connection: connection, serverName: "mac-studio"
        ) { _ in }
        let screen = try Screen(editor)
        defer { screen.hide() }

        // Constrain the Agent to host workspaces and to a list.
        let runtime = try #require(await screen.waitForButton("agent.nativeEdit.requiredRuntime"))
        try Screen.choose("Host", in: runtime)
        let mode = try #require(await screen.waitForButton("agent.nativeEdit.workspaceMode"))
        try Screen.choose("Allowed list", in: mode)
        let row = try #require(await screen.waitForButton("agent.nativeEdit.workspaces"))
        #expect(await screen.waitFor { row.accessibilityValue == "None" })
        row.sendActions(for: .touchUpInside)
        let page = try #require(await screen.waitForPushedPage(AgentWorkspaceSelectionViewController.self))

        #expect(await screen.waitForButton("agent.nativeEdit.workspace.ws-host", in: page.view) != nil)
        #expect(screen.button("agent.nativeEdit.workspace.ws-box", in: page.view) == nil, "a sandbox workspace does not fit")
        let host = try #require(screen.button("agent.nativeEdit.workspace.ws-host", in: page.view))
        host.sendActions(for: .touchUpInside)
        #expect(await screen.waitFor {
            screen.button("agent.nativeEdit.workspace.ws-host", in: page.view)?.accessibilityValue == "Selected"
        })
        screen.navigation.popViewController(animated: false)
        #expect(await screen.waitFor { screen.button("agent.nativeEdit.workspaces")?.accessibilityValue == "1" })
        let save = try #require(screen.root.navigationItem.rightBarButtonItem)
        #expect(save.isEnabled, "a compatible workspace is chosen")
    }
}

// MARK: - Harness

/// A screen in a navigation controller in a window tall enough to lay out the
/// whole form, with what the tests ask of its rows.
@MainActor
private final class Screen {
    let window: UIWindow
    let navigation: UINavigationController
    let root: UIViewController

    init(_ root: UIViewController) throws {
        self.root = root
        navigation = UINavigationController(rootViewController: root)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 2600)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
    }

    func hide() {
        window.isHidden = true
        window.rootViewController = nil
    }

    func waitFor(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        await waitForMainActorCondition(timeout: .seconds(5)) {
            self.window.layoutIfNeeded()
            return predicate()
        }
    }

    func waitForButton(_ identifier: String, in view: UIView? = nil) async -> UIButton? {
        _ = await waitFor { self.button(identifier, in: view) != nil }
        return button(identifier, in: view)
    }

    func waitForTextView(_ identifier: String) async -> UITextView? {
        _ = await waitFor { self.visibleViews(of: UITextView.self).contains { $0.accessibilityIdentifier == identifier } }
        return visibleViews(of: UITextView.self).first { $0.accessibilityIdentifier == identifier }
    }

    /// What typing does to a text view: its text changes and its delegate hears of it.
    static func type(_ text: String, into textView: UITextView) {
        textView.text = text
        textView.delegate?.textViewDidChange?(textView)
    }

    func waitForSwitch(_ identifier: String) async -> UISwitch? {
        _ = await waitFor { self.visibleViews(of: UISwitch.self).contains { $0.accessibilityIdentifier == identifier } }
        return visibleViews(of: UISwitch.self).first { $0.accessibilityIdentifier == identifier }
    }

    func waitForPushedPage<Page: UIViewController>(_ type: Page.Type) async -> Page? {
        _ = await waitFor { self.navigation.topViewController is Page && self.navigation.transitionCoordinator == nil }
        return navigation.topViewController as? Page
    }

    /// A button in a row the list shows now; a pooled cell is not one.
    func button(_ identifier: String, in view: UIView? = nil) -> UIButton? {
        visibleViews(of: UIButton.self, in: view).first { $0.accessibilityIdentifier == identifier }
    }

    /// Whether a section footer on the top page says `text`.
    func footer(_ text: String) -> Bool {
        guard let list = (navigation.topViewController?.view).flatMap({ $0.firstSubview(of: UICollectionView.self) }) else { return false }
        let kind = UICollectionView.elementKindSectionFooter
        return list.indexPathsForVisibleSupplementaryElements(ofKind: kind).contains { indexPath in
            let view = list.supplementaryView(forElementKind: kind, at: indexPath) as? UICollectionViewListCell
            return (view?.contentConfiguration as? UIListContentConfiguration)?.text?.contains(text) == true
        }
    }

    func visibleViews<T: UIView>(of type: T.Type, in view: UIView? = nil) -> [T] {
        let top = view ?? navigation.topViewController?.view ?? window
        guard let list = top.firstSubview(of: UICollectionView.self) else { return [] }
        return list.visibleCells.flatMap { $0.allSubviews(of: type) }
    }

    /// Runs the menu item `title` of a button's menu.
    static func choose(_ title: String, in button: UIButton) throws {
        let menu = try #require(button.menu, "the button has no menu")
        try run(title, in: menu)
    }

    static func perform(_ title: String, in item: UIBarButtonItem) throws {
        let menu = try #require(item.menu, "the bar item has no menu")
        try run(title, in: menu)
    }

    private static func run(_ title: String, in menu: UIMenu) throws {
        let action = try #require(menu.children.compactMap { $0 as? UIAction }.first { $0.title == title }, "no menu item \(title)")
        action.performWithSender(nil, target: nil)
    }
}

private extension UIView {
    func firstSubview<T: UIView>(of type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let found = subview.firstSubview(of: type) { return found }
        }
        return nil
    }

    func allSubviews<T: UIView>(of type: T.Type) -> [T] {
        var found = (self as? T).map { [$0] } ?? []
        for subview in subviews { found += subview.allSubviews(of: type) }
        return found
    }
}
