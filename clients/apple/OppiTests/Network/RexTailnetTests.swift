import Foundation
import LocalAuthentication
import NIOCore
import NIOPosix
import Synchronization
import Testing
import UIKit
@testable import Oppi

@Suite("Rex on the tailnet without SSH", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RexTailnetTests {
    static let rex = testUnwrap(RexTailnetHost(address: "rex.tail0000.ts.net"))

    static func peer(_ name: String, dns: String, os: String? = "macOS", online: Bool = true) -> TailnetPeer {
        TailnetPeer(id: name, hostName: name, dnsName: dns, os: os, tailscaleIPs: ["100.64.0.1"], isOnline: online)
    }

    static func store() -> RexDirectStore {
        RexDirectStore(defaults: testDefaults(suite: "rex-tailnet-tests-\(UUID().uuidString)"))
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
        return { SSHTerminalProfileStore(defaults: testDefaults(suite: suite), keychain: keychain) }
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

    // MARK: - Listing once

    /// A Rex added by name and found again by discovery is listed once, as a
    /// Rex section of its own with the same rows as a saved host's. A saved SSH
    /// host reaching the same Rex does not take it off the tailnet list: the
    /// direct route wins (`RexListDedupe`).
    @Test func aRexKnownSeveralWaysIsListedOnce() async throws {
        let store = Self.store()
        store.saveTailnetHost(testUnwrap(RexTailnetHost(address: Self.rex.address, name: "Studio Rex")))
        let discovery = RexTailnetDiscovery { $0.hasPrefix("rex.") || $0.hasPrefix("box.") ? .rex : .notRex }
        let peers = [Self.peer("rex", dns: Self.rex.address), Self.peer("box", dns: "box.tail0000.ts.net")]
        let me = "oppi-ios.tail0000.ts.net"
        await discovery.discover(peers: peers, selfDNSName: me)
        let reach = RexTailnetReach.peers
        let section = RexTailnetSection(store: store, discovery: discovery, reach: { reach }, makeFollower: {
            RexTailnetFollower(host: $0, monitor: RexMonitor(tailnet: $0, openDirect: Self.refusing))
        }, findsTailnetRex: { true })
        section.update(peers: peers, selfDNSName: me, active: false)
        #expect(section.entries.map(\.address) == [Self.rex.address, "box.tail0000.ts.net"])
        #expect(section.listedFollowers.map(\.host.name) == ["Studio Rex", "box"])
        let rows = SSHTerminalRexListRow.rows(hostName: Self.rex.address, state: try #require(section.listedFollowers.first).listState)
        #expect(rows.map(\.id) == ["header", "loading"], "a node not read yet is a host's section, loading")

        // A saved SSH host that learned the same Rex's address leaves the tailnet list as it is.
        let ssh = SSHTerminalProfile(host: "mac-studio", username: "alex", opensRexSessions: true)
        let said = try #require(URL(string: "https://Rex.Tail0000.ts.net/"))
        store.apply(.available(url: said, hostID: "host-1"), for: RexDirectHost(profile: ssh))
        section.update(peers: peers, selfDNSName: me, active: false)
        #expect(section.entries.map(\.address) == [Self.rex.address, "box.tail0000.ts.net"])

        // Forgotten, the saved name goes with its follower on the next update. A node
        // discovery still sees stays listed (it is on the tailnet), so this update is
        // one where discovery no longer finds it: the peers list without it.
        store.forgetTailnetHost(address: Self.rex.address)
        section.update(peers: [Self.peer("box", dns: "box.tail0000.ts.net")], selfDNSName: me, active: false)
        #expect(!section.entries.contains { $0.address == Self.rex.address })
        #expect(section.follower(id: Self.rex.id) == nil)
    }

    /// Find Rex on Your Tailnet is off to start, as Rex's own apps connect only
    /// to the servers you add: the tab probes no computer, a pull to refresh asks
    /// none either, and only the Rex added by name is listed, even with Oppi's own
    /// machine list right there. Turned on, a pull asks them.
    @Test func theTailnetIsAskedOnlyOnceFindingIsTurnedOn() async throws {
        let store = Self.store()
        store.saveTailnetHost(Self.rex)
        let probed = Mutex<[String]>([])
        let discovery = RexTailnetDiscovery { name in
            probed.withLock { $0.append(name) }
            return .rex
        }
        let peers = [Self.peer("box", dns: "box.tail0000.ts.net")]
        let me = "oppi-ios.tail0000.ts.net"
        let finds = Mutex(false)
        let section = RexTailnetSection(store: store, discovery: discovery, reach: { .peers }, makeFollower: {
            RexTailnetFollower(host: $0, monitor: RexMonitor(tailnet: $0, openDirect: Self.refusing))
        }, findsTailnetRex: { finds.withLock { $0 } })
        #expect(!AppPreferenceStore.Terminal.findsTailnetRexDefault, "off unless someone turns it on")

        section.update(peers: peers, selfDNSName: me, active: true)
        await section.refresh()
        #expect(probed.withLock { $0 }.isEmpty, "no computer is asked")
        #expect(section.entries.map(\.address) == [Self.rex.address])

        finds.withLock { $0 = true }
        await section.refresh()
        #expect(probed.withLock { $0 } == ["box.tail0000.ts.net"])
        section.update(peers: peers, selfDNSName: me, active: true)
        #expect(section.entries.map(\.address) == [Self.rex.address, "box.tail0000.ts.net"])
        section.clear()
    }

    /// Turning Find Rex on Your Tailnet off stops a pass that is asking the
    /// tailnet's computers right now: no probe goes on after the switch.
    @Test func turningFindingOffStopsAPassUnderWay() async throws {
        let asked = Mutex(0)
        let discovery = RexTailnetDiscovery { _ in
            asked.withLock { $0 += 1 }
            try? await Task.sleep(for: .seconds(30))
            return .unreachable
        }
        let peers = (0..<8).map { Self.peer("m\($0)", dns: "m\($0).tail0000.ts.net") }
        let me = "oppi-ios.tail0000.ts.net"
        let finds = Mutex(true)
        let section = RexTailnetSection(store: Self.store(), discovery: discovery, reach: { .peers }, makeFollower: {
            RexTailnetFollower(host: $0, monitor: RexMonitor(tailnet: $0, openDirect: Self.refusing))
        }, findsTailnetRex: { finds.withLock { $0 } })
        section.update(peers: peers, selfDNSName: me, active: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { discovery.probing })

        finds.withLock { $0 = false }
        section.update(peers: peers, selfDNSName: me, active: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !discovery.probing }, "the pass stopped")
        #expect(asked.withLock { $0 } == RexTailnetProbe.concurrency, "no computer was asked after the switch")
        section.clear()
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

    // MARK: - A saved SSH host's Rex over Tailscale

    /// A Rex pane of a saved SSH host whose Rex serves on the tailnet opens
    /// there with no SSH sign-in at all, as Rex's own apps do: no password, no
    /// Face ID, no host-key trust, and nothing dialled over SSH (the host here
    /// cannot even be reached). Side commands wait to sign in until one runs.
    @Test func aSavedHostsRexPaneOverTailscaleNeedsNoSSHSignIn() async throws {
        let fake = RexFakeSession(sessionID: "session:1", panes: [.init(block: "b1", label: "shell", title: "zsh", screen: "pane")])
        let registry = Self.registry()
        defer { registry.closeAll(reason: "done") }
        let profiles = Self.profiles()
        let host = SSHTerminalProfile(host: "no-such-host.invalid", username: "alex", authentication: .password, opensRexSessions: true)
        try profiles().save(host, password: nil, sudoPassword: nil)
        profiles().rexDirect.apply(.available(url: Self.rex.url, hostID: "host-1"), for: RexDirectHost(profile: host))
        fake.setStatus(url: Self.rex.url, hostID: "host-1")
        let session = SSHTerminalConnectSession(
            registry: registry, profileStore: profiles, openRexDirect: fake.openDirect(), rexTailnetUsable: { true }
        )
        session.rexPane = RexPaneTarget(sessionID: "session:1", blockID: "b1", label: "zsh")
        session.connect(profile: host)
        #expect(!session.passwordPrompt, "a password host is not asked for its password")
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { session.showsTerminal })
        #expect(session.failure == nil && session.hostFailure == nil)
        let channel = try #require(session.channel)
        #expect(channel.rex?.route == .tailscale(Self.rex.url))
        #expect(channel.sideCommandsUnavailable == nil && channel.sideCommandsSignInPending, "side commands sign in when one runs")
        #expect(fake.requests("session.attach").count == 1)

        // A side command signs in then: here the host has no saved password, so
        // it says so, and the terminal carries on over Tailscale.
        await #expect(throws: SSHKeychainError.passwordRequired) { _ = try await channel.run("true") }
        #expect(channel.connected)
    }

    /// The Terminal tab reads a saved host's Rex over Tailscale with no SSH
    /// sign-in: a host that would need a password or Face ID shows its sessions,
    /// not Tap to connect.
    @Test func aSavedHostsRexListsOverTailscaleWithoutTapToConnect() async throws {
        let world = RexFakeWorld(sessions: [.init(id: "session:1", label: "work", serverLabel: "work", windows: [
            .init(id: "window:1", label: "Window 1", panes: [.init(block: "b1", title: "zsh")]),
        ])])
        let profile = SSHTerminalProfile(host: "mac-studio", username: "alex", authentication: .password, opensRexSessions: true)
        let store = Self.store()
        store.apply(.available(url: Self.rex.url, hostID: "host-1"), for: RexDirectHost(profile: profile))
        world.setStatus(url: Self.rex.url, hostID: "host-1")
        let plan = RexRoutePlan(
            host: RexDirectHost(profile: profile), store: store, tailnetUsable: { true }, isCurrent: { true },
            openDirect: { _, _, _, sink in world.host().open(sink: sink) }
        )
        let session = SSHTerminalConnectSession(registry: Self.registry(), profileStore: Self.profiles())
        let follower = SSHTerminalRexFollower(
            profile: profile, promptsAutomatically: false, session: session,
            signsInSilently: { _ in false }, tailnetPlan: { _ in plan }
        )
        defer { follower.close() }
        #expect(!follower.needsTap && !follower.wouldStartSignIn)
        follower.sync(active: true)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { follower.monitor.snapshot?.sessions.count == 1 })
        #expect(follower.isConnected && !follower.needsTap)
        #expect(!session.connecting && session.rexSessions == nil, "no SSH sign-in")
    }

    /// A pane tapped on a saved host's Rex list that was read over Tailscale,
    /// with no SSH sign-in, opens its terminal: the follower names the host,
    /// since the list's session has connected to none.
    @Test func aPaneOnASavedHostsRexListReadOverTailscaleOpens() async throws {
        let world = RexFakeWorld(sessions: [.init(id: "session:1", label: "work", serverLabel: "work", windows: [
            .init(id: "window:1", label: "Window 1", panes: [.init(block: "b1", title: "zsh")]),
        ])])
        let fake = RexFakeSession(sessionID: "session:1", panes: [.init(block: "b1", label: "shell", title: "zsh", screen: "pane")])
        let registry = Self.registry()
        defer { registry.closeAll(reason: "done") }
        let profiles = Self.profiles()
        let host = SSHTerminalProfile(host: "mac-studio", username: "alex", authentication: .password, opensRexSessions: true)
        try profiles().save(host, password: nil, sudoPassword: nil)
        profiles().rexDirect.apply(.available(url: Self.rex.url, hostID: "host-1"), for: RexDirectHost(profile: host))
        world.setStatus(url: Self.rex.url, hostID: "host-1")
        fake.setStatus(url: Self.rex.url, hostID: "host-1")
        let plan = RexRoutePlan(
            host: RexDirectHost(profile: host), store: profiles().rexDirect, tailnetUsable: { true }, isCurrent: { true },
            openDirect: { _, _, _, sink in world.host().open(sink: sink) }
        )
        let session = SSHTerminalConnectSession(
            registry: registry, profileStore: profiles, openRexDirect: fake.openDirect(), rexTailnetUsable: { true }
        )
        let follower = SSHTerminalRexFollower(
            profile: host, promptsAutomatically: false, session: session,
            signsInSilently: { _ in false }, tailnetPlan: { _ in plan }
        )
        defer { follower.close() }
        follower.sync(active: true)
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) { follower.monitor.snapshot?.sessions.count == 1 })
        #expect(session.currentProfile == nil, "the list signed in nowhere")

        #expect(follower.open(session: "session:1", pane: "b1"))
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { session.showsTerminal }, "the pane's terminal opens")
        #expect(session.failure == nil && !session.passwordPrompt)
        #expect(session.channel?.rex?.route == .tailscale(Self.rex.url))
    }

    /// Over Tailscale the SSH connection beside Rex carries only side commands:
    /// when it drops, Rex's own connection stays up and the terminal with it.
    @Test func anSSHDropDoesNotEndRexReachedOverTailscale() async throws {
        let fake = RexFakeSession(sessionID: "session:1", panes: [.init(block: "b1", label: "shell", title: "zsh", screen: "pane")])
        let profile = SSHTerminalProfile(host: "mac-studio", username: "alex", opensRexSessions: true)
        let store = Self.store()
        store.apply(.available(url: Self.rex.url, hostID: "host-1"), for: RexDirectHost(profile: profile))
        fake.setStatus(url: Self.rex.url, hostID: "host-1")
        let plan = RexRoutePlan(
            host: RexDirectHost(profile: profile), store: store, tailnetUsable: { true }, isCurrent: { true },
            openDirect: fake.openDirect()
        )
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { Darwin.close(fds[1]) }
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).withConnectedSocket(fds[0]).get()
        let (transport, control) = try await RexHostTransport.open(connection: SSHConnection(channel: channel), plan: plan)
        defer { transport.close() }
        #expect(transport.route == .tailscale(Self.rex.url))

        try await channel.close()
        _ = try await control.call("session.view", ["session_id": "session:1"])
        #expect(transport.sideCommandsSignInPending, "the next side command signs in again")
    }

    /// Without SSH there are no side commands: they fail at once with the
    /// reason instead of hanging, and a Rex that takes no uploads offers no
    /// attachments.
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
        // This Rex says no API revision, so it takes no uploads either: Attach is not offered.
        #expect(channel.attachRoute == .unavailable(RexTailnetTransport.sideCommandsReason))
        await #expect(throws: reason) { try await channel.attach([SSHTerminalUpload.File(data: Data("photo".utf8), fileExtension: "png")]) }
        await #expect(throws: reason) { _ = try await channel.openStream(command: "herdr", sink: { _ in }) }
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
        #expect(SSHTerminalRexSessionsContent.rexSections(monitor).first?.rows.first?.title == expected)

        let registry = Self.registry()
        defer { registry.closeAll(reason: "done") }
        let session = SSHTerminalConnectSession(registry: registry, profileStore: Self.profiles(), openRexDirect: Self.refusing)
        session.openTailnetRexPane(RexPaneTarget(sessionID: "s", blockID: "b", label: "zsh"), on: Self.rex)
        #expect(await waitForMainActorCondition(timeout: .seconds(5)) { !session.connecting })
        #expect(session.failure == expected && !session.showsTerminal)
    }

    // MARK: - The Terminal tab

    /// A Rex added by name is listed as a section of its own in the update the
    /// add asks for, with nothing else to set off another one.
    @Test func aRexAddedByNameIsListedInTheSameUpdate() throws {
        let store = Self.store()
        let section = RexTailnetSection(
            store: store, discovery: RexTailnetDiscovery { _ in .unreachable }, reach: { .systemOnly },
            makeFollower: { RexTailnetFollower(host: $0, monitor: RexMonitor(tailnet: $0, openDirect: Self.refusing)) }
        )
        let list = RexListViewController(profileStore: Self.profiles(), tailnetRex: section, startsTailnet: {})
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        window.rootViewController = RouterNavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        defer {
            section.listedFollowers.forEach { $0.close() }
            window.isHidden = true
            window.rootViewController = nil
        }
        list.updatePropertiesIfNeeded()
        list.view.layoutIfNeeded()
        let header = "sshTerminal.rexList.\(Self.rex.id.uuidString).header"
        #expect(!Self.cellIdentifiers(list).contains(header))

        // Add Rex by Tailscale Name is Settings › Terminal › Rex on Your Tailnet now;
        // what it writes is what the tab lists, in the next update.
        store.saveTailnetHost(try #require(RexTailnetHost.parse("https://Rex.tail0000.ts.net/")))
        list.updatePropertiesIfNeeded()
        list.view.layoutIfNeeded()
        #expect(Self.cellIdentifiers(list).contains(header), "the added Rex's section is listed in that update")
    }

    /// What a tailnet Rex's monitor dialed: a fresh fake Rex (two sessions) per
    /// connection, the latest one kept to send events and read requests.
    @MainActor private final class FakeRexes {
        private(set) var opened: [RexFakeHost] = []
        var latest: RexFakeHost? { opened.last }

        var openDirect: RexLink.OpenDirect {
            { [self] _, _, _, sink in
                await MainActor.run {
                    let host = RexFakeHost.preview()
                    opened.append(host)
                    return host.open(sink: sink)
                }
            }
        }
    }

    /// A Rename prompt (or Close's confirmation) over the tab covers it, but
    /// must not drop the tailnet Rex's stream: Rex changing meanwhile still
    /// reaches the list, and the change the prompt submits goes over the same
    /// control connection.
    @Test func aPromptOverTheTabKeepsTheTailnetRexConnected() async throws {
        let rexes = FakeRexes()
        let store = Self.store()
        store.saveTailnetHost(Self.rex)
        var made: RexTailnetFollower?
        let section = RexTailnetSection(
            store: store, discovery: RexTailnetDiscovery { _ in .unreachable }, reach: { .systemOnly },
            makeFollower: { host in
                let follower = RexTailnetFollower(
                    host: host,
                    monitor: RexMonitor(tailnet: host, openDirect: rexes.openDirect, publishDelay: .milliseconds(20))
                )
                made = follower
                return follower
            }
        )
        let list = RexListViewController(profileStore: Self.profiles(), tailnetRex: section, startsTailnet: {})
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.traitOverrides.appRootEnvironment = makeTestAppRoot()
        window.rootViewController = RouterNavigationController(rootViewController: list)
        window.makeKeyAndVisible()
        defer {
            section.listedFollowers.forEach { $0.close() }
            window.isHidden = true
            window.rootViewController = nil
        }
        let oppi = "session:01a18a26-6620-76be-b529-4d9ad2b36c63"
        try #require(await waitForMainActorCondition(timeout: .seconds(5)) {
            list.updatePropertiesIfNeeded()
            return made?.monitor.snapshot?.sessions.count == 2
        })
        let follower = try #require(made)

        // The prompt covers the tab, and a pass runs under it.
        let prompt = UIAlertController(title: "Rename Session", message: nil, preferredStyle: .alert)
        list.present(prompt, animated: false)
        list.setNeedsUpdateProperties()
        list.updatePropertiesIfNeeded()
        // Rex changes meanwhile; the list still follows it.
        rexes.latest?.viewChanged(oppi, revision: 9)
        try await Task.sleep(for: .milliseconds(100))
        await follower.rename(session: oppi, to: "renamed")
        #expect(follower.manageFailure == nil)
        #expect(rexes.opened.count == 1, "the same connection, not a new one")
        #expect(rexes.latest?.requests.contains { $0.method == "session.set_label" && $0.string("label") == "renamed" } == true)
        prompt.dismiss(animated: false)
    }

    private static func cellIdentifiers(_ list: UIViewController) -> [String] {
        func collection(in view: UIView) -> UICollectionView? {
            if let found = view as? UICollectionView { return found }
            return view.subviews.lazy.compactMap(collection).first
        }
        return collection(in: list.view)?.visibleCells.compactMap(\.accessibilityIdentifier) ?? []
    }
}
