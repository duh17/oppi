import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal password prompts", .serialized)
@MainActor
struct SSHTerminalPasswordPromptTests {
    @Test func matchesWhatShellsAndSudoPrint() {
        for line in [
            "Password:",
            "[sudo] password for duh:",
            "duh@host's password:",
            "Enter passphrase for key '/Users/duh/.ssh/id_ed25519':",
            "Passphrase:",
            "PIN:",
            "PASSWORD:",
            "  Password:   ",
            // A Herdr pane draws its border before the text.
            "│ Password:",
            "│ Enter passphrase for key '/x/id':",
        ] {
            #expect(SSHTerminalPasswordPrompt.matches(lineBeforeCursor: line, atShellPrompt: false), "\(line)")
        }
    }

    @Test func ignoresOrdinaryLinesAndTextAfterThePrompt() {
        for line in [
            "",
            ":",
            "Password",
            "$ ls",
            "Verification code:",
            "spin:",
            "shipping:",
            "pinned:",
            // Echoed input: the prompt is no longer the last thing on the line.
            "Password: hunter2",
            "[sudo] password for duh: hunter2",
            "Passphrase for key '/x/id': typed",
        ] {
            #expect(!SSHTerminalPasswordPrompt.matches(lineBeforeCursor: line, atShellPrompt: false), "\(line)")
        }
    }

    @Test func neverMatchesWhileTheShellWaitsAtItsOwnInput() {
        for line in ["Password:", "[sudo] password for duh:", "echo Password: "] {
            #expect(!SSHTerminalPasswordPrompt.matches(lineBeforeCursor: line, atShellPrompt: true), "\(line)")
        }
    }

    @Test func theEngineReportsThePromptTextLeftOfTheCursor() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 40, rows: 6)) { _ in }
        engine.receive(Data("$ sudo ls\r\n[sudo] password for duh: ".utf8))
        // The row keeps its empty cells past the cursor's space; the matcher trims.
        let prompt = try #require(engine.cursorLineBeforeCursor)
        #expect(prompt.hasPrefix("[sudo] password for duh: "))
        #expect(SSHTerminalPasswordPrompt.matches(lineBeforeCursor: prompt, atShellPrompt: engine.cursorAtPrompt))
        #expect(!engine.cursorAtPrompt)

        // The shell's own prompt input (OSC 133) is a command line, not a secret.
        engine.receive(Data("\u{1b}]133;A\u{7}\u{1b}]133;B\u{7}$ ".utf8))
        #expect(engine.cursorAtPrompt)
        engine.receive(Data("echo Password: ".utf8))
        let typed = try #require(engine.cursorLineBeforeCursor)
        #expect(typed.hasPrefix("$ echo Password: "))
        #expect(!SSHTerminalPasswordPrompt.matches(lineBeforeCursor: typed, atShellPrompt: engine.cursorAtPrompt))

        // Herdr draws a pane border before the text, on the alternate screen,
        // where libghostty reports no shell prompt at all.
        engine.receive(Data("\u{1b}[?1049h│ │ Password: ".utf8))
        let bordered = try #require(engine.cursorLineBeforeCursor)
        #expect(bordered.hasPrefix("│ │ Password: "))
        #expect(!engine.cursorAtPrompt)
        #expect(SSHTerminalPasswordPrompt.matches(lineBeforeCursor: bordered, atShellPrompt: engine.cursorAtPrompt))

        // Reading history is not the live screen.
        engine.scroll(rows: -1)
        #expect(engine.cursorLineBeforeCursor == nil)
        engine.backToLive()
        engine.close()
        #expect(engine.cursorLineBeforeCursor == nil)
    }

    @Test func theGridAsksForSecureEntryWhileAPromptShowsAndShowsTheCue() throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedPasswordPromptGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        var reported: [Bool] = []
        grid.secureInputChanged = { reported.append($0) }
        let bar = try #require(grid.inputAccessoryView)
        let cue = try #require(Self.find(identifier: "sshTerminal.secureInput", in: bar))
        #expect(!grid.isSecureTextEntry)
        #expect(cue.isHidden)

        channel.engine.receive(Data("$ sudo ls\r\nPassword: ".utf8))
        grid.drawFrame()
        #expect(grid.isSecureTextEntry)
        #expect(!cue.isHidden, "the keyboard bar says why the keyboard changed")
        #expect(reported == [true])

        // Return: the shell answers, the cursor moves, and the prompt is gone.
        channel.engine.receive(Data("\r\n$ ".utf8))
        grid.drawFrame()
        #expect(!grid.isSecureTextEntry)
        #expect(cue.isHidden)
        #expect(reported == [true, false])

        // A dropped connection ends it too, however the screen was left.
        channel.engine.receive(Data("Password: ".utf8))
        grid.drawFrame()
        #expect(grid.isSecureTextEntry)
        channel.close(reason: "done")
        grid.drawFrame()
        #expect(!grid.isSecureTextEntry)
        #expect(reported == [true, false, true, false])
    }

    private static func find(identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let match = find(identifier: identifier, in: child) { return match }
        }
        return nil
    }
}

private actor PasswordPromptStubConnection: SSHTerminalConnection {
    func send(_ bytes: Data) async throws {}
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func run(_ command: String, input: Data) async throws -> SSHExecResult {
        SSHExecResult(output: Data(), errorOutput: Data(), exitStatus: 0)
    }
    func checkAlive() async throws {}
    nonisolated func close() {}
    func cancel() async {}
}

/// A grid in a key window: `drawFrame` needs one before it paints, and the
/// secure prompt check reads the terminal's own cursor line.
@MainActor
private final class MountedPasswordPromptGrid {
    let window: UIWindow
    let grid: SSHTerminalGridView

    init(_ grid: SSHTerminalGridView) throws {
        self.grid = grid
        let host = UIViewController()
        grid.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: host.view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
        ])
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
    }

    func dismiss() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
