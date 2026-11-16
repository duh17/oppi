import Foundation
import Synchronization
import Testing
@testable import Oppi

@Suite("Rex over Tailscale", .serialized, .timeLimit(.minutes(1)))
struct RexDirectTests {
    static let rexName = "rex.tail0000.ts.net"
    static let rexURL = testUnwrap(URL(string: "https://\(rexName)"))

    static let rexHostID = "ae49134e-0000-4000-8000-000000000001"

    /// `server.status` as Rex 1642 answers it with Tailscale HTTPS serving on.
    static func status(
        https: String = #"{"state":"available","url":"https://rex.tail0000.ts.net"}"#, hostID: String = rexHostID
    ) -> String {
        #"{"pid":52834,"host_id":"\#(hostID)","session_count":3,"tailscale":{"state":"running","dns_name":"rex.tail0000.ts.net","account":{"login_name":"someone@example.com"},"allow_tailnet_members":false,"https":\#(https)},"api_revision":7}"#
    }

    static func profile(host: String = "mac-studio", port: UInt16 = 22, id: UUID = UUID()) -> SSHTerminalProfile {
        SSHTerminalProfile(id: id, host: host, port: port, username: "alex", opensRexSessions: true)
    }

    /// Waits for `condition` up to `timeout`; a busy simulator can be slow.
    static func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    static func store() -> RexDirectStore {
        let suite = "rex-direct-tests-\(UUID().uuidString)"
        return RexDirectStore(defaults: testDefaults(suite: suite))
    }

    /// A fake Rex on a byte stream: welcomes, answers `server.status`, and
    /// records what each stream's first write (the upgrade) said.
    final class FakeRex: Sendable {
        let host: RexFakeHost
        private let heads = Mutex<[String]>([])
        var upgrades: [String] { heads.withLock { $0 } }

        init(status: String = RexDirectTests.status()) {
            host = RexFakeHost { request in
                request.method == "server.status" ? .result(status) : .result("{}")
            }
        }

        func open(_ sink: @escaping SSHPTYByteSink) -> SSHExecStream {
            let stream = host.open(sink: sink)
            return SSHExecStream(
                send: { [self] bytes in
                    if let head = String(data: bytes, encoding: .utf8), head.hasPrefix("GET ") {
                        heads.withLock { $0.append(head) }
                    }
                    try await stream.send(bytes)
                },
                close: { stream.close() }
            )
        }
    }

    /// Rex's own Tailscale HTTPS serving is taken at any name it gives (a
    /// Headscale tailnet's too); without it, a `tailnet://` listener on the
    /// host's own Tailscale is taken at its first tailnet address, over plain
    /// HTTP. A listener that admits anyone, or one off the tailnet, is not.
    /// Serving off forgets what was remembered; an answer that is not a status
    /// changes nothing.
    @Test func serverStatusSaysWhereRexServesOnTheTailnet() {
        let available = RexDirectDiscovery.outcome(statusJSON: Data(Self.status().utf8))
        #expect(available == .available(url: Self.rexURL, hostID: Self.rexHostID))
        let headscale = Self.status(https: #"{"state":"available","url":"https://rex.hs.example.com/"}"#)
        #expect(RexDirectDiscovery.outcome(statusJSON: Data(headscale.utf8))
            == .available(url: testUnwrap(URL(string: "https://rex.hs.example.com")), hostID: Self.rexHostID))
        for https in [#"{"state":"unavailable"}"#, #"{"state":"available","url":"http://rex.tail0000.ts.net"}"#,
                      #"{"state":"available","url":"https://rex.tail0000.ts.net/elsewhere"}"#] {
            #expect(RexDirectDiscovery.outcome(statusJSON: Data(Self.status(https: https).utf8)) == .unavailable, "\(https)")
        }

        func listening(_ listeners: String) -> RexDirectDiscovery.Outcome? {
            RexDirectDiscovery.outcome(statusJSON: Data(#"{"pid":1,"host_id":"h","listeners":\#(listeners)}"#.utf8))
        }
        let unix = #"{"endpoint":"unix:///tmp/rex.sock","addresses":["/tmp/rex.sock"],"transport":"unix","admission":"peer_credentials","primary":true}"#
        let tailnet = #"{"endpoint":"tailnet://:7297","addresses":["100.101.102.103:7297","[fd7a:115c:a1e0::1]:7297"],"transport":"tailscale","admission":"tailscale_owner"}"#
        #expect(listening("[\(unix),\(tailnet)]") == .available(url: testUnwrap(URL(string: "http://100.101.102.103:7297")), hostID: "h"))
        let anonymous = #"{"endpoint":"0.0.0.0:7297","addresses":["100.101.102.103:7297"],"transport":"tcp","admission":"anonymous"}"#
        let offTailnet = #"{"endpoint":"tailnet://:7297","addresses":["192.168.1.5:7297"],"transport":"tailscale"}"#
        #expect(listening("[\(unix),\(anonymous),\(offTailnet)]") == .unavailable)

        #expect(RexDirectDiscovery.outcome(statusJSON: Data(#"{"pid":1}"#.utf8)) == .unavailable, "a Rex without Tailscale")
        #expect(RexDirectDiscovery.outcome(statusJSON: Data("{}".utf8)) == nil)
        #expect(RexDirectDiscovery.outcome(statusJSON: Data("rex: command not found".utf8)) == nil)
    }

    /// The URL belongs to the sign-in target it was learned through: the same
    /// saved host edited to another machine or user does not reuse it.
    @Test func aRememberedAddressIsBoundToTheHostItWasLearnedThrough() {
        let store = Self.store()
        let profile = Self.profile()
        let host = RexDirectHost(profile: profile)
        store.apply(.available(url: Self.rexURL, hostID: Self.rexHostID), for: host)
        #expect(store.url(for: host) == Self.rexURL)
        var moved = profile
        moved.host = "build-box"
        #expect(store.url(for: RexDirectHost(profile: moved)) == nil)
        var otherUser = profile
        otherUser.username = "root"
        #expect(store.url(for: RexDirectHost(profile: otherUser)) == nil)
        store.apply(nil, for: host)
        #expect(store.url(for: host) == Self.rexURL, "an unreadable answer keeps it")
        store.apply(.unavailable, for: host)
        #expect(store.url(for: host) == nil, "serving off forgets it")
    }

    /// Direct only with a remembered URL and a tailnet route, not again in an
    /// open that already failed, and not for any open of the host while the
    /// failure is held.
    @Test func directIsTriedOnlyWithAnAddressARouteAndNoRecentFailure() {
        let now = ContinuousClock.now
        let url = Self.rexURL
        #expect(RexRoutePlan.choose(remembered: url, tailnetUsable: true, failedThisOpen: false, heldUntil: nil, now: now) == url)
        #expect(RexRoutePlan.choose(remembered: nil, tailnetUsable: true, failedThisOpen: false, heldUntil: nil, now: now) == nil)
        #expect(RexRoutePlan.choose(remembered: url, tailnetUsable: false, failedThisOpen: false, heldUntil: nil, now: now) == nil)
        #expect(RexRoutePlan.choose(remembered: url, tailnetUsable: true, failedThisOpen: true, heldUntil: nil, now: now) == nil)
        #expect(RexRoutePlan.choose(remembered: url, tailnetUsable: true, failedThisOpen: false, heldUntil: now + .seconds(1), now: now) == nil)
        #expect(RexRoutePlan.choose(remembered: url, tailnetUsable: true, failedThisOpen: false, heldUntil: now - .seconds(1), now: now) == url)

        // A host edited after the screen opened does not reach the old Rex.
        let store = Self.store()
        let host = RexDirectHost(profile: Self.profile())
        store.apply(.available(url: url, hostID: Self.rexHostID), for: host)
        #expect(RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { false }).directCandidate() == nil)
        #expect(RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }).directCandidate() == url)
    }

    /// The first open has no address: it goes over the bridge, which reads
    /// `server.status` and remembers where Rex serves. The next open goes
    /// straight to Rex over Tailscale, upgrading with Rex's own name (and port,
    /// when the URL has one), and speaks the same control protocol there.
    @Test func theBridgeLearnsTheAddressAndTheNextOpenGoesDirect() async throws {
        let store = Self.store()
        let host = RexDirectHost(profile: Self.profile())
        let bridge = FakeRex()
        let direct = FakeRex()
        let opened = Mutex<[URL]>([])
        func plan() -> RexRoutePlan {
            RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }, openDirect: { url, _, _, sink in
                opened.withLock { $0.append(url) }
                return direct.open(sink)
            })
        }

        let (first, firstControl) = try await RexLink.connect(
            plan: plan(), openStream: { _, _, sink in bridge.open(sink) }, run: nil
        )
        #expect(first.route == .ssh)
        #expect(try await Self.eventually { store.url(for: host) != nil })
        #expect(store.url(for: host) == Self.rexURL)
        #expect(bridge.host.requests.map(\.method) == ["server.status"])
        firstControl.close()

        let (second, control) = try await RexLink.connect(
            plan: plan(), openStream: { _, _, _ in throw SSHConnectionError.notConnected }, run: nil
        )
        #expect(second.route == .tailscale(Self.rexURL))
        #expect(opened.withLock { $0 } == [Self.rexURL])
        let head = try #require(direct.upgrades.first)
        #expect(head.hasPrefix("GET /api/control HTTP/1.1\r\n") && head.contains("\r\nHost: \(Self.rexName)\r\n"))
        #expect(try await Self.eventually { direct.host.requests.contains { $0.method == "server.status" } })
        #expect(store.url(for: host) == Self.rexURL, "the same Rex answered: the address stays")
        control.close()
        #expect(RexLink.hostHeader(testUnwrap(URL(string: "https://\(Self.rexName):8443"))) == "\(Self.rexName):8443")
        #expect(RexLink.hostHeader(Self.rexURL) == Self.rexName)

    }

    /// With no SSH sign-in beside it, a direct connection is handed out only
    /// once the Rex there says it is this host's: the same address and the
    /// same `host_id`. Another Rex at that address, or an address learned with
    /// no `host_id` to check, is asked nothing else, its address is dropped,
    /// and the open goes over SSH.
    @Test func aDirectConnectionIsUsedOnlyOnceRexSaysItIsThisHostsOwn() async throws {
        for (learned, answering) in [(Self.rexHostID, "another-rex"), (nil, Self.rexHostID)] as [(String?, String)] {
            // A host of its own each time: a failed attempt holds its host off Tailscale for a while.
            let host = RexDirectHost(profile: Self.profile())
            let store = Self.store()
            store.apply(.available(url: Self.rexURL, hostID: learned), for: host)
            let impostor = FakeRex(status: Self.status(hostID: answering))
            let bridge = FakeRex()
            let (link, control) = try await RexLink.connect(
                plan: RexRoutePlan(
                    host: host, store: store, tailnetUsable: { true }, isCurrent: { true },
                    openDirect: { _, _, _, sink in impostor.open(sink) }
                ),
                openStream: { _, _, sink in bridge.open(sink) }, run: nil
            )
            #expect(link.route == .ssh, "learned \(learned ?? "no host id"): falls back to SSH")
            #expect(impostor.host.requests.map(\.method) == ["server.status"], "nothing but who it is was asked of it")
            control.close()
        }
    }

    /// A control connection whose hello Rex never answers is closed, not left
    /// open behind the failure: a monitor that retries must not pile up
    /// bridges or streams.
    @Test func aHelloThatIsNeverWelcomedClosesItsStream() async throws {
        let silent = SilentRex()
        await #expect(throws: RexClientError.timedOut) {
            _ = try await RexLink(openStream: { _, _, sink in silent.open(sink) }).connect(timeout: .milliseconds(200))
        }
        #expect(silent.sawHello && silent.isClosed)
    }

    /// A direct attempt that has not reached Rex's welcome by the deadline
    /// falls back to SSH at the deadline, without waiting for the attempt,
    /// and the stream that comes in late is closed.
    @Test func aDirectAttemptPastTheDeadlineFallsBackAndItsLateStreamIsClosed() async throws {
        let store = Self.store()
        let host = RexDirectHost(profile: Self.profile())
        store.apply(.available(url: Self.rexURL, hostID: Self.rexHostID), for: host)
        let late = FakeRex()
        // The production deadline is `RexRoutePlan.directTimeout`; a short one keeps the test fast.
        let deadline = Duration.milliseconds(400)
        let plan = RexRoutePlan(
            host: host, store: store, tailnetUsable: { true }, isCurrent: { true }, directDeadline: deadline,
            openDirect: { _, _, _, sink in
                // A stream that ignores cancellation and arrives after the deadline.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1500)) { continuation.resume() }
                }
                return late.open(sink)
            }
        )
        let bridge = FakeRex()
        let started = ContinuousClock.now
        let (link, control) = try await RexLink.connect(plan: plan, openStream: { _, _, sink in bridge.open(sink) }, run: nil)
        let elapsed = ContinuousClock.now - started
        #expect(link.route == .ssh)
        #expect(elapsed >= deadline && elapsed < deadline + .seconds(1), "\(elapsed)")
        #expect(try await Self.eventually(.seconds(5)) { late.host.isOpen && late.host.isClosed }, "the late stream is closed")
        control.close()
    }

    /// A direct attempt that fails (here refused, as Rex refuses another
    /// tailnet user) falls back to the bridge in the same open. That open and
    /// any other open of the host for the hold do not try it again; the bridge
    /// is what they use.
    @Test func aFailedDirectAttemptFallsBackAndIsNotRetriedRightAway() async throws {
        let store = Self.store()
        let host = RexDirectHost(profile: Self.profile())
        store.apply(.available(url: Self.rexURL, hostID: Self.rexHostID), for: host)
        let attempts = Mutex(0)
        let plan = RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }, openDirect: { _, _, _, _ in
            attempts.withLock { $0 += 1 }
            throw RexWebSocketCodec.Failure.upgradeRefused("HTTP/1.1 403 Forbidden")
        })
        let bridge = FakeRex()
        let (link, control) = try await RexLink.connect(plan: plan, openStream: { _, _, sink in bridge.open(sink) }, run: nil)
        #expect(link.route == .ssh)
        #expect(attempts.withLock { $0 } == 1)
        _ = try await control.call("session.list", [:])
        control.close()

        // The same open reconnecting (a dropped Rex list stream) stays on the bridge.
        let reconnect = FakeRex()
        let (again, againControl) = try await RexLink.connect(plan: plan, openStream: { _, _, sink in reconnect.open(sink) }, run: nil)
        #expect(again.route == .ssh && attempts.withLock { $0 } == 1)
        againControl.close()
        // Another open of the same host while the failure is held does too.
        #expect(RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }).directCandidate() == nil)
    }

    /// A host whose bridge cannot run (no `nc` that speaks Unix sockets)
    /// still says where Rex serves through Rex's CLI, and is reached over
    /// Tailscale without `nc`.
    @Test func aHostWithoutNcIsReachedOverTailscaleThroughRexsCLI() async throws {
        let store = Self.store()
        let host = RexDirectHost(profile: Self.profile())
        let direct = FakeRex()
        let commands = Mutex<[String]>([])
        let plan = RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }, openDirect: { _, _, _, sink in
            direct.open(sink)
        })
        // A host whose bridge is already gone: the exit status and the close reach the client
        // on its own first write, in the order SSH reports them, instead of from a task that
        // races that write.
        let noNc: @Sendable (@escaping SSHPTYByteSink) -> SSHExecStream = { sink in
            SSHExecStream(
                send: { _ in
                    sink(.exitStatus(126))
                    sink(.closed)
                },
                close: {}
            )
        }
        let (link, control) = try await RexLink.connect(
            plan: plan,
            openStream: { _, _, sink in noNc(sink) },
            run: { command in
                commands.withLock { $0.append(command) }
                return SSHExecResult(output: Data(Self.status().utf8), errorOutput: Data(), exitStatus: 0)
            }
        )
        #expect(commands.withLock { $0 } == [RexBridge.statusCommand])
        #expect(link.route == .tailscale(Self.rexURL))
        control.close()

        // Without Tailscale serving, the host still has no way in.
        let off = Self.store()
        let offPlan = RexRoutePlan(host: host, store: off, tailnetUsable: { true }, isCurrent: { true }, openDirect: { _, _, _, sink in direct.open(sink) })
        await #expect(throws: RexClientError.bridgeMissing) {
            _ = try await RexLink.connect(
                plan: offPlan,
                openStream: { _, _, sink in noNc(sink) },
                run: { _ in SSHExecResult(output: Data(Self.status(https: #"{"state":"unavailable"}"#).utf8), errorOutput: Data(), exitStatus: 0) }
            )
        }
    }

    /// Upgrades the WebSocket and then says nothing: a Rex that never
    /// welcomes the hello.
    final class SilentRex: Sendable {
        private struct State {
            var sink: SSHPTYByteSink?
            var writes = 0
            var closed = false
        }

        private let state = Mutex(State())
        var sawHello: Bool { state.withLock { $0.writes >= 2 } }
        var isClosed: Bool { state.withLock { $0.closed } }

        func open(_ sink: @escaping SSHPTYByteSink) -> SSHExecStream {
            state.withLock { $0.sink = sink }
            return SSHExecStream(
                send: { [self] bytes in
                    let sink = state.withLock { state -> SSHPTYByteSink? in
                        state.writes += 1
                        return state.writes == 1 ? state.sink : nil
                    }
                    guard let sink, let head = String(data: bytes, encoding: .utf8),
                          let key = head.split(separator: "\r\n").first(where: { $0.hasPrefix("Sec-WebSocket-Key: ") })?.dropFirst(19) else { return }
                    sink(.data(Data("HTTP/1.1 101 Switching Protocols\r\nSec-Websocket-Accept: \(RexWebSocketCodec.accept(for: String(key)))\r\nSec-Websocket-Protocol: rex.control.v1\r\n\r\n".utf8)))
                },
                close: { [self] in state.withLock { $0.closed = true } }
            )
        }
    }

    /// A Rex at an IPv6 tailnet address is named in brackets in the upgrade's `Host`.
    @Test func anUpgradeToAnIPv6AddressBracketsIt() {
        #expect(RexLink.hostHeader(testUnwrap(URL(string: "http://[fd7a:115c:a1e0::1]:7297"))) == "[fd7a:115c:a1e0::1]:7297")
        #expect(RexLink.hostHeader(testUnwrap(URL(string: "http://100.101.102.103:7297"))) == "100.101.102.103:7297")
        #expect(RexLink.hostHeader(Self.rexURL) == Self.rexName)
    }

    /// Plain HTTP to Rex is safe only inside WireGuard: with no route onto the
    /// tailnet nothing is dialled. HTTPS checks its certificate and is not
    /// held to the route.
    @Test func plainHTTPToRexNeedsARouteOntoTheTailnet() async throws {
        let dialed = Mutex<[URL]>([])
        func link(_ url: URL) -> RexLink {
            RexLink(route: .tailscale(url), openStream: RexTailnetTransport.noBridge, openDirect: { url, _, _, _ in
                dialed.withLock { $0.append(url) }
                throw RexClientError.connectionClosed
            }, tailnetUsable: { false })
        }
        let plain = testUnwrap(URL(string: "http://100.101.102.103:7297"))
        await #expect(throws: RexClientError.noTailnetRoute) { _ = try await link(plain).connect() }
        #expect(dialed.withLock { $0 }.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await link(Self.rexURL).connect() }
        #expect(dialed.withLock { $0 } == [Self.rexURL])
    }

    /// Rex's route through Oppi's Tailscale never fails over to the device's
    /// own network, where 100.64.0.0/10 can be a carrier's; other tailnet
    /// traffic keeps failing over to a system Tailscale VPN.
    @Test func rexsTailnetRouteNeverFailsOverToTheDevicesOwnNetwork() throws {
        let proxy = TailnetSOCKSProxy(host: "127.0.0.1", port: 1080, credential: "secret")
        #expect(try #require(TailnetTransportRoute.socksConfiguration(proxy, everyHost: true)).allowFailover == false)
        #expect(try #require(TailnetTransportRoute.socksConfiguration(proxy)).allowFailover == true)
    }

    @Test func aTailscaleAddressIsOneInTheCGNATRange() {
        #expect(RexTailnetPath.isTailscaleAddress(0x6464_0102)) // 100.100.1.2
        #expect(RexTailnetPath.isTailscaleAddress(0x647F_FFFF)) // 100.127.255.255
        #expect(!RexTailnetPath.isTailscaleAddress(0x6480_0000)) // 100.128.0.0
        #expect(!RexTailnetPath.isTailscaleAddress(0xC0A8_0001)) // 192.168.0.1
    }
}
