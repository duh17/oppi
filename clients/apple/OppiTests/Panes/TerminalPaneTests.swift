import Testing
import UIKit
@testable import Oppi

/// A terminal inside a split pane, in a real window: it goes quiet while its
/// pane is hidden, and a terminal another pane already draws is focused there
/// rather than drawn a second time.
@MainActor
@Suite("Terminal panes", .serialized, .timeLimit(.minutes(1)))
struct TerminalPaneTests {
    private final class QuietConnection: SSHTerminalConnection {
        func close() {}
        func send(_ bytes: Data) async throws {}
        func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
        func openStream(command: String, sink: @escaping SSHPTYByteSink) async throws -> SSHExecStream {
            throw SSHConnectionError.notConnected
        }
        func run(_ command: String, input: Data) async throws -> SSHExecResult {
            throw SSHConnectionError.commandRequestRejected
        }
        func checkAlive() async throws {}
        func cancel() async {}
    }

    /// The mini in landscape with a split beside the routed pane: the split's id
    /// and its stack.
    private func splitHost() throws -> (host: PaneTestHost, split: PaneID, stack: UINavigationController) {
        let host = PaneTestHost(width: 1133, height: 744, inNavigation: true)
        host.act { host.panes.split(axis: .row) }
        let split = try #require(host.scenePanes.splitLeaves.first?.id)
        let stack = try #require(host.panes.children.compactMap { $0 as? UINavigationController }.first {
            host.panes.cell(holding: $0.topViewController ?? $0) == split
        })
        // The grid paints only while the scene is active (`MountedTerminalTestController`).
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        return (host, split, stack)
    }

    /// The terminal's takes of `block` so far (`session.own_block`, take).
    private func takes(of block: String, in rig: RexSessionTerminalTests.Rig) -> Int {
        rig.fake.requests("session.own_block").filter {
            $0.payload.contains(block) && $0.payload.contains(#""mode":"take""#)
        }.count
    }

    /// Another pane's zoom parks the terminal's pane: its Rex session stops
    /// keeping neighbours live and leaves a pane the Mac app took to the Mac,
    /// and takes it back once the pane shows again.
    @Test func aHiddenPaneLeavesItsRexPaneToTheMacUntilItShowsAgain() async throws {
        let rig = try await RexSessionTerminalTests().open(["a", "b", "c"])
        let (host, split, stack) = try splitHost()
        defer {
            host.hide()
        }
        let terminal = SSHTerminalViewController(channel: rig.channel, reconnect: {}, editHost: {})
        host.act { stack.pushViewController(terminal, animated: false) }
        host.panes.updateVisibility()
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { rig.model.isWarming },
                     "the shown pane keeps its neighbours live")
        let a = RexSessionTerminalTests.block("a")

        host.act { host.panes.zoom(host.scenePanes.routedLeafID) }
        #expect(host.panes.cellPresentation?.frames[split] == nil, "the zoom hides the terminal's pane")
        #expect(!rig.model.isWarming, "a hidden pane keeps no neighbours live")
        #expect(!rig.channel.isViewed, "nor takes the host's clipboard writes")
        let before = takes(of: a, in: rig)
        rig.fake.takeAsAnotherClient(a, columns: 120, rows: 40)
        _ = await waitForMainActorCondition(timeout: .milliseconds(400)) { false }
        #expect(takes(of: a, in: rig) == before, "the pane stays the Mac's while hidden")
        #expect(rig.fake.size(of: a) == RexFakeSession.Size(columns: 120, rows: 40))

        host.act { host.panes.zoom(nil) }
        #expect(rig.model.isWarming, "shown again, it keeps its neighbours live")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { takes(of: a, in: rig) > before },
                "and takes its pane back")
        await rig.stop()
    }

    /// A terminal one pane draws, opened from another pane's list, focuses the
    /// pane that draws it: one screen per shell. One no pane draws opens in
    /// the list's own pane.
    @Test func openingATerminalAnotherPaneDrawsFocusesThatPane() async throws {
        let registry = SSHTerminalRegistry(
            backgroundTasks: FakeBackgroundTasks(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )
        let profile = SSHTerminalProfile(host: "mac-studio", username: "alex")
        let channel = try SSHTerminalChannel()
        channel.opened(QuietConnection())
        registry.adopt(channel, profile: profile, queue: SSHTerminalEventQueue())
        let (host, split, stack) = try splitHost()
        defer {
            host.hide()
            registry.closeAll(reason: "done")
        }
        // The routed pane draws the terminal.
        let routedStack = try #require(host.screen.navigationController)
        host.act { routedStack.pushViewController(SSHTerminalViewController(channel: channel, reconnect: {}, editHost: {}), animated: false) }
        let list = try #require(stack.topViewController)
        host.act { host.panes.focus(cell: split) }

        let session = SSHTerminalConnectSession(registry: registry)
        let chrome = SSHTerminalConnectChrome(
            host: list, session: session, profile: { profile }, setProfile: { _ in },
            editHost: {}, submitPassword: { _ in }, onSaved: { _ in }
        )
        session.show(try #require(registry.terminal(for: profile.id)))
        chrome.sync()
        _ = await waitForMainActorCondition(timeout: .milliseconds(200)) { false }
        host.window.layoutIfNeeded()
        #expect(host.panes.focusedLeaf == .primary, "the pane that draws the terminal takes focus")
        #expect(stack.topViewController === list, "no second terminal in the list's pane")
        #expect(!session.showsTerminal)

        // Once no pane draws it, the list's pane opens it.
        host.act { routedStack.popViewController(animated: false) }
        host.act { host.panes.focus(cell: split) }
        chrome.sync()
        session.show(try #require(registry.terminal(for: profile.id)))
        chrome.sync()
        #expect(await waitForMainActorCondition(timeout: .seconds(2)) {
            (stack.topViewController as? SSHTerminalViewController)?.channel === channel
        }, "the terminal opens in the list's pane")
    }
}
