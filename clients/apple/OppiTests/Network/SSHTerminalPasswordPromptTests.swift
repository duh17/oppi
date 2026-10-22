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

    @Test func matchesThroughTheMarkAPromptEchoesForEachKey() {
        // `sudo-rs` with pwfeedback, `sudo -S`, and some `ssh` builds echo a
        // mark for each key typed after the prompt.
        for line in [
            "Password: *",
            "Password: **",
            "Password: ••",
            "Password: ●",
            "[sudo] password for duh: ***",
            "│ Password: *",
        ] {
            #expect(SSHTerminalPasswordPrompt.matches(lineBeforeCursor: line, atShellPrompt: false), "\(line)")
            #expect(SSHTerminalPasswordPrompt.trimmingEcho(line).hasSuffix(":"), "\(line)")
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
            // Echoed input that is not a key mark: the prompt is no longer the
            // last thing on the line.
            "Password: hunter2",
            "Password: *hunter2",
            "[sudo] password for duh: hunter2",
            "Passphrase for key '/x/id': typed",
        ] {
            #expect(!SSHTerminalPasswordPrompt.matches(lineBeforeCursor: line, atShellPrompt: false), "\(line)")
        }
    }

    @Test func neverMatchesWhileTheShellWaitsAtItsOwnInput() {
        for line in ["Password:", "[sudo] password for duh:", "echo Password: ", "Password: *"] {
            #expect(!SSHTerminalPasswordPrompt.matches(lineBeforeCursor: line, atShellPrompt: true), "\(line)")
        }
    }

    @Test func theEngineReadsThePromptTextOnlyFromAPaintedSnapshot() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 40, rows: 6)) { _ in }
        engine.receive(Data("$ sudo ls\r\n[sudo] password for duh: ".utf8))
        // No frame has drawn this output yet: the row is stale, not empty.
        #expect(engine.cursorLineBeforeCursor == nil)

        _ = engine.frame()
        // The row keeps its empty cells past the cursor's space; the matcher trims.
        let prompt = try #require(engine.cursorLineBeforeCursor)
        #expect(prompt.hasPrefix("[sudo] password for duh: "))
        #expect(SSHTerminalPasswordPrompt.matches(lineBeforeCursor: prompt, atShellPrompt: engine.cursorAtPrompt))
        #expect(!engine.cursorAtPrompt)
        #expect(SSHTerminalPasswordPrompt.prompt(inLineBeforeCursor: prompt, atShellPrompt: false) == prompt.trimmingCharacters(in: .whitespaces))

        // The shell's own prompt input (OSC 133) is a command line, not a secret.
        engine.receive(Data("\u{1b}]133;A\u{7}\u{1b}]133;B\u{7}$ ".utf8))
        _ = engine.frame()
        #expect(engine.cursorAtPrompt)
        engine.receive(Data("echo Password: ".utf8))
        _ = engine.frame()
        let typed = try #require(engine.cursorLineBeforeCursor)
        #expect(typed.hasPrefix("$ echo Password: "))
        #expect(!SSHTerminalPasswordPrompt.matches(lineBeforeCursor: typed, atShellPrompt: engine.cursorAtPrompt))

        // Herdr draws a pane border before the text, on the alternate screen,
        // where libghostty reports no shell prompt at all.
        engine.receive(Data("\u{1b}[?1049h│ │ Password: ".utf8))
        _ = engine.frame()
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

    @Test func theGridAsksForSecureEntryWhileAPromptShowsAndShowsTheCue() async throws {
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
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        #expect(!cue.isHidden, "the keyboard bar says why the keyboard changed")
        #expect(reported == [true])

        // Return: the shell answers, the cursor moves, and the prompt is gone.
        // One frame that no longer matches is not enough; the second picture
        // agreeing is what changes the keyboard.
        channel.engine.receive(Data("\r\n$ ".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry, "a single off frame keeps the latch")
        channel.engine.receive(Data("\r\n".utf8))
        try await Self.draw(grid)
        #expect(!grid.isSecureTextEntry)
        #expect(cue.isHidden)
        #expect(reported == [true, false])

        // A dropped connection ends it too, however the screen was left.
        channel.engine.receive(Data("Password: ".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        channel.close(reason: "done")
        try await Self.draw(grid)
        #expect(!grid.isSecureTextEntry)
        #expect(reported == [true, false, true, false])
    }

    @Test func oneFrameWithTheCursorElsewhereDoesNotEndThePrompt() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedPasswordPromptGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        var reported: [Bool] = []
        grid.secureInputChanged = { reported.append($0) }

        channel.engine.receive(Data("Password: ".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)

        // A repaint in a neighbouring pane moves the cursor for one frame.
        channel.engine.receive(Data("\u{1b}[2;1H".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry, "one frame off the row changes nothing")
        channel.engine.receive(Data("\u{1b}[1;11H".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry, "back on the prompt row")

        // A hidden cursor is a half-drawn frame too: no row, no decision.
        channel.engine.receive(Data("\u{1b}[?25l".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        channel.engine.receive(Data("\u{1b}[?25h".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        #expect(reported == [true], "nothing flipped to the chat bar in between")

        // Two consecutive off pictures on different change counts release it.
        channel.engine.receive(Data("\u{1b}[2;1H".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        channel.engine.receive(Data("\u{1b}[3;1H".utf8))
        try await Self.draw(grid)
        #expect(!grid.isSecureTextEntry)
        #expect(reported == [true, false])
    }

    @Test func aPromptThatArrivedWhileTheSceneWasInactiveIsSecureBeforeAnyKeyCanLand() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedPasswordPromptGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        var reported: [Bool] = []
        grid.secureInputChanged = { reported.append($0) }

        // Face ID, Control Center, the notification pull-down: the scene goes
        // inactive, the display link stops, and the prompt arrives unseen.
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        channel.engine.receive(Data("$ sudo ls\r\nPassword: ".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry, "the live line decides without a paint")
        #expect(reported == [true])

        // Coming back changes nothing: the latch holds through the repaint.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(grid.isSecureTextEntry)
        #expect(reported == [true])
    }

    @Test func secureEntryDoesNotWaitForAPaintAndHistoryStillLeavesItAlone() throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        // Never in a window: presentIfNeeded returns false, so no snapshot is taken.
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        defer { channel.close(reason: "done") }
        var reported: [Bool] = []
        grid.secureInputChanged = { reported.append($0) }

        channel.engine.receive(Data("$ sudo ls\r\nPassword: ".utf8))
        #expect(channel.engine.cursorLineBeforeCursor == nil, "no frame has painted this output")
        grid.drawFrame()
        #expect(channel.engine.cursorLineBeforeCursor == nil, "and none could")
        #expect(grid.isSecureTextEntry)
        #expect(reported == [true])

        // Reading history is not the live screen: output arriving there decides nothing.
        channel.engine.scroll(rows: -1)
        channel.engine.receive(Data("\r\n$ ".utf8))
        grid.drawFrame()
        channel.engine.receive(Data("\r\n".utf8))
        grid.drawFrame()
        #expect(grid.isSecureTextEntry)
        #expect(reported == [true])

        // Back on the live screen the prompt is gone, but unpainted ticks only
        // ever turn secure entry on: releasing waits for two painted frames.
        channel.engine.backToLive()
        grid.drawFrame()
        channel.engine.receive(Data("x\r\n".utf8))
        grid.drawFrame()
        channel.engine.receive(Data("y\r\n".utf8))
        grid.drawFrame()
        #expect(grid.isSecureTextEntry, "live reads never release the latch")
        #expect(reported == [true])
    }

    @Test func aHeldRedrawWithNoPaintsDoesNotReleaseTheLatch() throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        // Never in a window, so every paint bails, as with a full GPU ring.
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        defer { channel.close(reason: "done") }
        var reported: [Bool] = []
        grid.secureInputChanged = { reported.append($0) }

        channel.engine.receive(Data("Password: ".utf8))
        grid.drawFrame()
        #expect(grid.isSecureTextEntry)

        // A synchronized update redraws another pane: the cursor passes through
        // rows that are not the prompt, across several chunks, before it returns.
        channel.engine.receive(Data("\u{1b}[?2026h".utf8))
        #expect(channel.engine.renderHeld)
        channel.engine.receive(Data("\u{1b}[3;1Hother pane".utf8))
        grid.drawFrame()
        channel.engine.receive(Data("\u{1b}[4;1Hmore".utf8))
        grid.drawFrame()
        channel.engine.receive(Data("\u{1b}[5;1H".utf8))
        grid.drawFrame()
        #expect(grid.isSecureTextEntry, "a held screen is half drawn, and nothing painted")
        channel.engine.receive(Data("\u{1b}[1;11H\u{1b}[?2026l".utf8))
        grid.drawFrame()
        #expect(grid.isSecureTextEntry)
        #expect(reported == [true])
    }

    @Test func aHeldRedrawParkingTheCursorAfterAnotherPanesPromptTurnsNothingOn() throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        // Never in a window, so every paint bails and only the live line could answer.
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        defer { channel.close(reason: "done") }
        var reported: [Bool] = []
        grid.secureInputChanged = { reported.append($0) }

        channel.engine.receive(Data("$ ls\r\n".utf8))
        grid.drawFrame()
        #expect(!grid.isSecureTextEntry)

        // Mid-update, the cursor stops right after another pane's prompt text.
        channel.engine.receive(Data("\u{1b}[?2026h\u{1b}[5;1HPassword: ".utf8))
        #expect(channel.engine.renderHeld)
        grid.drawFrame()
        #expect(!grid.isSecureTextEntry, "a held, half-drawn screen does not turn secure entry on")
        #expect(reported.isEmpty)
    }

    @Test func aSecretTypedAtAPromptDoesNotOutliveItWhenThePromptEndsWithoutReturn() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedPasswordPromptGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        let blank = SSHTerminalTextInputStorage()

        // Text typed before the prompt does not carry into it.
        grid.insertText("ls")
        #expect(grid.textInputStorage != blank)
        channel.engine.receive(Data("Password: ".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        #expect(grid.textInputStorage == blank)

        // Part of a secret, then the prompt ends (Ctrl-C, timeout) with no Return.
        grid.insertText("hunt")
        #expect(grid.textInputStorage.text.contains("hunt"))
        channel.engine.receive(Data("\r\n$ ".utf8))
        try await Self.draw(grid)
        channel.engine.receive(Data("\r\n".utf8))
        try await Self.draw(grid)
        #expect(!grid.isSecureTextEntry)
        #expect(grid.textInputStorage == blank, "no secret characters stay for prediction or a revision")
        #expect(grid.textInputStorage.markedText == nil)
    }

    @Test func aDifferentPromptLatchedAfterTheTapIsNotTheOneConfirmed() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedPasswordPromptGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }

        #expect(grid.passwordFillPrompt() == nil, "no prompt, nothing to confirm")
        channel.engine.receive(Data("Password: ".utf8))
        try await Self.draw(grid)
        let first = try #require(grid.passwordFillPrompt())
        #expect(grid.passwordPromptIsLive(matching: first))

        // Another program's prompt takes the same row while the check was up.
        channel.engine.receive(Data("\u{1b}[2J\u{1b}[HEnter Password: ".utf8))
        try await Self.draw(grid)
        let second = try #require(grid.passwordFillPrompt())
        #expect(second != first)
        #expect(grid.passwordPromptIsLive(matching: second), "the new prompt is live, and is the new one")
        #expect(!grid.passwordPromptIsLive(matching: first), "the prompt that was confirmed is gone")
    }

    /// A frame with the terminal's newest output. `drawFrame` only snapshots
    /// when it can paint, and the renderer keeps three frames in flight, so a
    /// back-to-back burst is retried across display refreshes.
    private static func draw(_ grid: SSHTerminalGridView) async throws {
        for _ in 0..<3 {
            grid.drawFrame()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    @Test func thePromptStaysSecureWhileTheSecretIsTypedAndHistoryDoesNotEndIt() async throws {
        let channel = try SSHTerminalChannel()
        channel.opened(PasswordPromptStubConnection())
        let grid = SSHTerminalGridView(channel: channel, paste: { _ in }, followChanged: { _ in })
        let mounted = try MountedPasswordPromptGrid(grid)
        defer { mounted.dismiss(); channel.close(reason: "done") }
        var reported: [Bool] = []
        grid.secureInputChanged = { reported.append($0) }

        channel.engine.receive(Data("Password: ".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)

        // pwfeedback: one `*` per key. The prompt still has to hold, or the
        // rest of the password would land on a normal keyboard.
        channel.engine.receive(Data("*".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        channel.engine.receive(Data("*".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        #expect(reported == [true], "the echo of the secret is not a new prompt")

        // Reading local history is not the live screen: it must not end it.
        channel.engine.scroll(rows: -1)
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        channel.engine.backToLive()
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        #expect(reported == [true])

        // Return leaves the row: the shell's next line is no prompt. Two
        // frames have to agree before the keyboard changes back.
        channel.engine.receive(Data("\r\n$ ls\r\n".utf8))
        try await Self.draw(grid)
        #expect(grid.isSecureTextEntry)
        channel.engine.receive(Data("$ ".utf8))
        try await Self.draw(grid)
        #expect(!grid.isSecureTextEntry)
        #expect(reported == [true, false])
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
        // Detection reads the snapshot a paint took, so the grid needs its
        // Metal renderer before a frame can report the terminal's own row.
        _ = try SSHTerminalMetalPipeline.shared()
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
        // The grid only paints while its scene is foreground-active, and a system
        // alert on the simulator (the notification permission prompt) leaves the
        // test host inactive. These tests exercise the screen, not scene
        // activation, so say the app is active, as OrbMetalTests does.
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    func dismiss() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
