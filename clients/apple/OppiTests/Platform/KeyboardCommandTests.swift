import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("App keyboard commands")
struct KeyboardCommandTests {
    private func chord(_ input: String, _ modifiers: UIKeyModifierFlags) -> String {
        "\(input)|\(modifiers.intersection([.command, .control, .alternate, .shift]).rawValue)"
    }

    /// The code editor's keys with the standard keybindings, in a Markdown file
    /// (its largest set).
    private func editorChords() throws -> [String] {
        let defaults = try #require(UserDefaults(suiteName: "keyboard-command-keys-\(UUID().uuidString)"))
        let preferences = CodeEditorPreferences(defaults: defaults)
        preferences.keybindings = .standard
        let session = try #require(WorkspaceFileEditSession(
            identity: WorkspaceFileEditIdentity(serverId: "srv", workspaceId: "w1", worktreeId: nil, path: "notes.md"),
            disk: WorkspaceFileDiskSnapshot(bytes: Data("x".utf8), etag: "\"sha256-\(String(repeating: "a", count: 64))\""),
            maxBytes: 4_000_000,
            transport: WorkspaceFileEditTransport(read: { _ in .failed }, write: { _, _, _ in .notSent }),
            draftStore: WorkspaceFileDraftStore(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-command-keys-\(UUID().uuidString)")
            ),
            idleDelay: .seconds(600)
        ))
        let editor = WorkspaceFileEditorViewController(session: session, themeID: .dark, preferences: preferences) { _ in UIViewController() }
        return editor.codeEditorKeyCommands(editor.textView).compactMap { command in
            command.input.map { chord($0, command.modifierFlags) }
        }
    }

    @Test("No app key shadows the editor's or the terminal's, except the one the app yields")
    func keysAreDistinct() throws {
        let app = KeyboardCommand.all.compactMap { $0.key.map { chord($0.input, $0.modifiers) } }
        #expect(Set(app).count == app.count)

        let terminal = SSHTerminalHardwareShortcut.allCases.map { chord($0.input, .command) }
        let editor = try editorChords()
        #expect(Set(app).isDisjoint(with: terminal))
        // Cmd-L is Go to Line, Cmd-D Duplicate Line and Shift-Cmd-Return Insert
        // Line Above in the editor. The editor's key commands sit ahead of the
        // menu, and Focus Composer, Split Right and Zoom Pane are withdrawn
        // while the editor has focus (`LiveKeyboardCommandSurface`), so the
        // two are never both on.
        #expect(Set(app).intersection(editor) == [
            chord("l", .command), chord("d", .command), chord("\r", [.command, .shift]),
        ])
        // Cmd-Return and Option-Return send from the composer.
        #expect(!app.contains { $0 == chord("\r", .command) || $0 == chord("\r", .alternate) })
    }

    @Test("A menu item's property list names its command")
    func menuItemsRoundTrip() {
        for command in KeyboardCommand.all {
            let item = command.makeMenuCommand(action: #selector(UIResponder.becomeFirstResponder))
            #expect(item.propertyList as? String == command.id)
            #expect(KeyboardCommand(id: item.propertyList as? String ?? "") == command)
        }
    }

    @Test("Next and previous session wrap and never land on the current one")
    func sessionAdjacency() {
        let ids = ["a", "b", "c"]
        #expect(SessionAdjacency.neighbor(of: "a", in: ids, offset: 1) == "b")
        #expect(SessionAdjacency.neighbor(of: "c", in: ids, offset: 1) == "a")
        #expect(SessionAdjacency.neighbor(of: "a", in: ids, offset: -1) == "c")
        #expect(SessionAdjacency.neighbor(of: "stopped", in: ids, offset: 1) == "a")
        #expect(SessionAdjacency.neighbor(of: nil, in: ids, offset: -1) == "c")
        #expect(SessionAdjacency.neighbor(of: "a", in: ["a"], offset: 1) == nil)
        #expect(SessionAdjacency.neighbor(of: "a", in: [], offset: 1) == nil)
    }
}
