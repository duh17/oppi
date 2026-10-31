import Foundation
import Synchronization
import Testing
@testable import Oppi

@Suite("Rex over Tailscale", .serialized, .timeLimit(.minutes(1)))
struct RexDirectTests {
    static let rexName = "rex.tail0000.ts.net"
    static let rexURL = URL(string: "https://\(rexName)")!

    /// `server.status` as Rex 1642 answers it with Tailscale HTTPS serving on.
    static func status(https: String = #"{"state":"available","url":"https://rex.tail0000.ts.net"}"#) -> String {
        #"{"pid":52834,"session_count":3,"tailscale":{"state":"running","dns_name":"rex.tail0000.ts.net","account":{"login_name":"someone@example.com"},"allow_tailnet_members":false,"https":\#(https)},"api_revision":7}"#
    }

    static func profile(host: String = "mac-studio", port: UInt16 = 22, id: UUID = UUID()) -> SSHTerminalProfile {
        SSHTerminalProfile(id: id, host: host, port: port, username: "chen", opensRexSessions: true)
    }

    static func store() -> RexDirectStore {
        let suite = "rex-direct-tests-\(UUID().uuidString)"
        return RexDirectStore(defaults: UserDefaults(suiteName: suite)!)
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

    /// Only an HTTPS URL on a tailnet name, with serving available, is taken;
    /// serving off forgets what was remembered; an answer that is not a status
    /// changes nothing.
    @Test func serverStatusSaysWhereRexServesOverTailscale() {
        let available = RexDirectDiscovery.outcome(statusJSON: Data(Self.status().utf8))
        #expect(available == .available(url: Self.rexURL, dnsName: Self.rexName))
        for https in [#"{"state":"unavailable"}"#, #"{"state":"available","url":"https://rex.example.com"}"#,
                      #"{"state":"available","url":"http://rex.tail0000.ts.net"}"#,
                      #"{"state":"available","url":"https://rex.tail0000.ts.net/elsewhere"}"#] {
            #expect(RexDirectDiscovery.outcome(statusJSON: Data(Self.status(https: https).utf8)) == .unavailable, "\(https)")
        }
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
        store.apply(.available(url: Self.rexURL, dnsName: nil), for: host)
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
        store.apply(.available(url: url, dnsName: nil), for: host)
        #expect(RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { false }).directCandidate() == nil)
        #expect(RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }).directCandidate() == url)
    }

    /// The first open has no address: it goes over the bridge, which reads
    /// `server.status` and remembers where Rex serves. The next open goes
    /// straight to Rex over Tailscale, upgrading with Rex's own name, and
    /// speaks the same control protocol there.
    @Test func theBridgeLearnsTheAddressAndTheNextOpenGoesDirect() async throws {
        let store = Self.store()
        let host = RexDirectHost(profile: Self.profile())
        let bridge = FakeRex()
        let direct = FakeRex()
        let opened = Mutex<[URL]>([])
        func plan() -> RexRoutePlan {
            RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }) { url, _, _, sink in
                opened.withLock { $0.append(url) }
                return direct.open(sink)
            }
        }

        let (first, firstControl) = try await RexLink.connect(
            plan: plan(), openStream: { _, _, sink in bridge.open(sink) }, run: nil
        )
        #expect(first.route == .ssh)
        for _ in 0..<200 where store.url(for: host) == nil { try await Task.sleep(for: .milliseconds(5)) }
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
        let answer = try await control.call("server.status", [:])
        #expect(RexDirectDiscovery.outcome(statusJSON: answer) == .available(url: Self.rexURL, dnsName: Self.rexName))
        control.close()
    }

    /// A direct attempt that fails (here refused, as Rex refuses another
    /// tailnet user) falls back to the bridge in the same open. That open and
    /// any other open of the host for the hold do not try it again; the bridge
    /// is what they use.
    @Test func aFailedDirectAttemptFallsBackAndIsNotRetriedRightAway() async throws {
        let store = Self.store()
        let host = RexDirectHost(profile: Self.profile())
        store.apply(.available(url: Self.rexURL, dnsName: nil), for: host)
        let attempts = Mutex(0)
        let plan = RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }) { _, _, _, _ in
            attempts.withLock { $0 += 1 }
            throw RexWebSocketCodec.Failure.upgradeRefused("HTTP/1.1 403 Forbidden")
        }
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
        let plan = RexRoutePlan(host: host, store: store, tailnetUsable: { true }, isCurrent: { true }) { _, _, _, sink in
            direct.open(sink)
        }
        let noNc = RexFakeHost { _ in .hold }
        let (link, control) = try await RexLink.connect(
            plan: plan,
            openStream: { _, _, sink in
                let stream = noNc.open(sink: sink)
                Task { noNc.end(status: 126) }
                return stream
            },
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
        let offPlan = RexRoutePlan(host: host, store: off, tailnetUsable: { true }, isCurrent: { true }) { _, _, _, sink in direct.open(sink) }
        await #expect(throws: RexClientError.bridgeMissing) {
            _ = try await RexLink.connect(
                plan: offPlan,
                openStream: { _, _, sink in
                    let stream = noNc.open(sink: sink)
                    Task { noNc.end(status: 126) }
                    return stream
                },
                run: { _ in SSHExecResult(output: Data(Self.status(https: #"{"state":"unavailable"}"#).utf8), errorOutput: Data(), exitStatus: 0) }
            )
        }
    }

    @Test func aTailscaleAddressIsOneInTheCGNATRange() {
        #expect(RexTailnetPath.isTailscaleAddress(0x6464_0102)) // 100.100.1.2
        #expect(RexTailnetPath.isTailscaleAddress(0x647F_FFFF)) // 100.127.255.255
        #expect(!RexTailnetPath.isTailscaleAddress(0x6480_0000)) // 100.128.0.0
        #expect(!RexTailnetPath.isTailscaleAddress(0xC0A8_0001)) // 192.168.0.1
    }
}
