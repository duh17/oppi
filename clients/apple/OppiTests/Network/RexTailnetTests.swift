import Foundation
import LocalAuthentication
import Synchronization
import Testing
@testable import Oppi

@Suite("Rex on the tailnet without SSH", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RexTailnetTests {
    static let rex = RexTailnetHost(dnsName: "rex.tail0000.ts.net")!

    static func peer(_ name: String, dns: String, os: String? = "macOS", online: Bool = true) -> TailnetPeer {
        TailnetPeer(id: name, hostName: name, dnsName: dns, os: os, tailscaleIPs: ["100.64.0.1"], isOnline: online)
    }

    static func store() -> RexDirectStore {
        RexDirectStore(defaults: UserDefaults(suiteName: "rex-tailnet-tests-\(UUID().uuidString)")!)
    }

    private final class MemoryKeychain: SSHCredentialStoring {
        private let items = Mutex<[String: Data]>([:])
        func load(account: String, requirePresence: Bool, authenticationContext: LAContext?) throws -> Data? {
            items.withLock { $0[account] }
        }
        func save(_ data: Data, account: String, requirePresence: Bool) throws { items.withLock { $0[account] = data } }
        func delete(account: String) throws { items.withLock { $0[account] = nil } }
    }

    /// The SSH host list of one test.
    private static func profiles() -> @Sendable () -> SSHTerminalProfileStore {
        let suite = "rex-tailnet-tests-profiles-\(UUID().uuidString)"
        let keychain = MemoryKeychain()
        return { SSHTerminalProfileStore(defaults: UserDefaults(suiteName: suite)!, keychain: keychain) }
    }

    private static func registry() -> SSHTerminalRegistry {
        SSHTerminalRegistry(backgroundTasks: FakeBackgroundTasks(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    /// A Rex that refuses this device: every upgrade gets 403 and Rex's JSON reason.
    private static let refusing: RexLink.OpenDirect = { _, _, _, sink in
        SSHExecStream(
            send: { _ in
                sink(.data(Data("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\n\r\n{\"error\":\"tailscale user someone@else.com is not allowed\"}\n".utf8)))
            },
            close: { sink(.closed) }
        )
    }

    // MARK: - Opening a session without SSH

    /// A session of a Rex reached over Tailscale alone opens with no sign-in,
    /// prompt, or saved SSH host: Rex's control and data connections go to
    /// its Tailscale address, the pane switches over the same route, and
    /// Reconnect comes back the same way.
    @Test func aTailnetRexSessionOpensStraightOverTailscale() async throws {
        let fake = RexFakeSession(sessionID: "session:1", panes: [
            .init(block: "b1", label: "shell", title: "zsh", screen: "first pane"),
            .init(block: "b2", label: "shell", title: "pi", screen: "second pane"),
        ])
        let registry = Self.registry()
        defer { registry.closeAll(reason: "done") }
        let profiles = Self.profiles()
        let session = SSHTerminalConnectSession(registry: registry, profileStore: profiles, openRexDirect: fake.openDirect())
        let target = RexPaneTarget(sessionID: "session:1", blockID: "b1", label: "zsh")
        session.openTailnetRexPane(target, on: Self.rex)
        #expect(!session.passwordPrompt && session.hostFailure == nil)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { session.showsTerminal })

        let channel = try #require(session.channel)
        #expect(channel.rex?.route == .tailscale(Self.rex.url))
        #expect(registry.terminal(for: Self.rex.id, folder: nil, rexPane: target)?.channel === channel)
        #expect(profiles().load().isEmpty, "nothing is saved as an SSH host")
        #expect(fake.requests("session.attach").count == 1)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { fake.requests("data.connect").count == 1 })

        #expect(channel.rex?.show("b2") == true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) {
            fake.requests("data.connect").map { $0.string("block_id") } == ["b1", "b2"] && fake.dataHosts.count == 2
        })
        #expect(fake.directURLs.count == 3 && Set(fake.directURLs) == [Self.rex.url], "control, then a data connection per pane shown")

        channel.close(reason: "test")
        session.reconnect()
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { session.channel !== channel && session.channel?.connected == true })
        #expect(session.channel?.rex?.shownTarget.blockID == "b2", "a reconnect reopens the pane shown last")
        #expect(!session.passwordPrompt && profiles().load().isEmpty)
    }

    /// Without SSH there are no side commands: they fail at once with the
    /// reason instead of hanging, and the chat bar offers no attachments.
    @Test func featuresThatNeedSSHSayWhyInsteadOfRunning() async throws {
        let fake = RexFakeSession(sessionID: "session:1", panes: [.init(block: "b1", label: "shell", title: "zsh", screen: "pane")])
        let registry = Self.registry()
        defer { registry.closeAll(reason: "done") }
        let session = SSHTerminalConnectSession(registry: registry, profileStore: Self.profiles(), openRexDirect: fake.openDirect())
        session.openTailnetRexPane(RexPaneTarget(sessionID: "session:1", blockID: "b1", label: "zsh"), on: Self.rex)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { session.showsTerminal })
        let channel = try #require(session.channel)

        let reason = SSHTerminalSideCommandsUnavailable(reason: RexTailnetTransport.sideCommandsReason)
        #expect(channel.sideCommandsUnavailable == RexTailnetTransport.sideCommandsReason)
        await #expect(throws: reason) { _ = try await channel.run("true") }
        await #expect(throws: reason) { _ = try await channel.upload(Data("photo".utf8), fileExtension: "png") }
        await #expect(throws: reason) { _ = try await channel.openStream(command: "herdr", sink: { _ in }) }
        let composer = SSHTerminalComposerHost(
            channel: channel, connection: nil, draftStore: nil, themeID: ThemeRuntimeState.currentThemeID(), showRawKeyboard: {}
        )
        #expect(!composer.content.allowsAttachments)
        #expect(session.currentProfile?.rexTailnet == Self.rex.url, "the terminal knows it has no saved host to edit")
    }

    // MARK: - Refusal

    /// A Rex that does not admit this device's Tailscale identity says it lets
    /// in only the account that signed it in, which account Oppi is on, and
    /// Rex's own reason. Any other answer that is not an upgrade is not about
    /// identity, and a timeout is not a refusal.
    @Test func aRefusalNamesTheAccountRexWants() {
        let refused = RexWebSocketCodec.Failure.upgradeRefused(#"HTTP/1.1 403 Forbidden {"error":"tailscale user someone@else.com is not allowed"}"#)
        let message = RexTailnetAccess.refusal(refused, host: Self.rex, signedInAs: "me@example.com") ?? ""
        #expect(message.hasPrefix("This Rex only lets in the Tailscale account that signed it in."))
        #expect(message.contains("Oppi is on Tailscale as me@example.com."))
        #expect(message.contains("Rex said: tailscale user someone@else.com is not allowed"))
        let viaApp = RexTailnetAccess.refusal(refused, host: Self.rex, signedInAs: nil) ?? ""
        #expect(viaApp.contains("through this device's Tailscale app"))

        let notRex = RexTailnetAccess.refusal(
            RexWebSocketCodec.Failure.upgradeRefused("HTTP/1.1 404 Not Found 404 page not found"), host: Self.rex, signedInAs: nil
        ) ?? ""
        #expect(notRex.contains("answered HTTP/1.1 404 Not Found") && !notRex.contains("only lets in"))
        #expect(RexTailnetAccess.refusal(RexClientError.timedOut, host: Self.rex, signedInAs: nil) == nil)
    }

    /// A refusal stops the list for that Rex (asking again cannot help until
    /// the sign-in changes) and shows the message; opening a session there
    /// shows it instead of a terminal.
    @Test func aRefusingRexShowsWhyInTheListAndOnOpen() async {
        let monitor = RexMonitor(tailnet: Self.rex, openDirect: Self.refusing)
        let run = Task { await monitor.runTailnet() }
        defer { run.cancel() }
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { monitor.gaveUp })
        let expected = RexTailnetAccess.refusal(
            RexWebSocketCodec.Failure.upgradeRefused(#"HTTP/1.1 403 Forbidden {"error":"tailscale user someone@else.com is not allowed"}"#),
            host: Self.rex
        )
        #expect(monitor.absence == expected.map { .refused($0) })
        #expect(monitor.sections.first?.rows.first?.title == expected)

        let registry = Self.registry()
        defer { registry.closeAll(reason: "done") }
        let session = SSHTerminalConnectSession(registry: registry, profileStore: Self.profiles(), openRexDirect: Self.refusing)
        session.openTailnetRexPane(RexPaneTarget(sessionID: "s", blockID: "b", label: "zsh"), on: Self.rex)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !session.connecting })
        #expect(session.failure == expected && !session.showsTerminal)
    }
}
