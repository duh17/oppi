import Foundation
import Synchronization
import Testing
@testable import Oppi

@Suite("Finding Rex on the tailnet", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RexTailnetDiscoveryTests {
    static let rex = testUnwrap(RexTailnetHost(address: "rex.tail0000.ts.net"))
    static let rexBody = Data("WebSocket protocol violation: Connection header \"\" does not contain Upgrade\n".utf8)

    static func peer(_ name: String, dns: String, os: String? = "macOS", online: Bool = true) -> TailnetPeer {
        TailnetPeer(id: name, hostName: name, dnsName: dns, os: os, tailscaleIPs: ["100.64.0.1"], isOnline: online)
    }

    static func store() -> RexDirectStore {
        RexDirectStore(defaults: testDefaults(suite: "rex-tailnet-tests-\(UUID().uuidString)"))
    }

    // MARK: - Probe

    /// Only Rex's own answer to a plain GET of its control endpoint is Rex: a
    /// 426 whose body is Go's WebSocket protocol violation. A 404 (a web
    /// server without the endpoint), a refusal, or another 426 is not.
    @Test func onlyRexsUpgradeRequiredAnswerIsRex() async {
        #expect(RexTailnetProbe.classify(status: 426, body: Self.rexBody) == .rex)
        #expect(RexTailnetProbe.classify(status: 426, body: Data("Upgrade Required".utf8)) == .notRex)
        #expect(RexTailnetProbe.classify(status: 404, body: Data("404 page not found\n".utf8)) == .notRex)
        #expect(RexTailnetProbe.classify(status: 200, body: Self.rexBody) == .notRex)
        #expect(RexTailnetProbe.classify(status: 403, body: Data(#"{"error":"not allowed"}"#.utf8)) == .notRex)
        #expect(await RexTailnetProbe.probe(address: "rex") == .notRex, "something that is no address is never dialed")
    }

    /// Probes run a few at a time, and every name gets exactly one verdict.
    @Test func probesRunAFewAtATimeAndEachNameOnce() async {
        let inFlight = Mutex((now: 0, most: 0))
        let names = (0..<10).map { "m\($0).tail0000.ts.net" }
        var seen: [String] = []
        await RexTailnetProbe.probeAll(names, probe: { _ in
            inFlight.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
            try? await Task.sleep(for: .milliseconds(30))
            inFlight.withLock { $0.now -= 1 }
            return .unreachable
        }, onVerdict: { name, verdict, _ in
            #expect(verdict == .unreachable)
            seen.append(name)
        })
        #expect(inFlight.withLock { $0.most } == RexTailnetProbe.concurrency)
        #expect(seen.sorted() == names.sorted())
    }

    // MARK: - Discovery

    /// The node's online computers on its own tailnet are asked once each
    /// (phones, offline or nameless machines, and machines shared in from
    /// another tailnet, such as Mullvad exit nodes, are not); only Rex is
    /// listed, named by its device name. An answer lasts for the app's run; a
    /// machine that did not answer is asked again on the next visit; a forced
    /// pass (pull to refresh) asks every one.
    @Test func discoveryAsksEachComputerOnceAndListsOnlyRex() async {
        let probed = Mutex<[String]>([])
        let discovery = RexTailnetDiscovery { name in
            probed.withLock { $0.append(name) }
            if name.hasPrefix("rex.") { return .rex }
            return name.hasPrefix("web.") ? .notRex : .unreachable
        }
        let peers = [
            Self.peer("rex", dns: "rex.tail0000.ts.net."),
            Self.peer("web", dns: "Web.tail0000.ts.net"),
            Self.peer("mac-mini", dns: "mac-mini.tail0000.ts.net"),
            Self.peer("iphone", dns: "iphone.tail0000.ts.net", os: "iOS"),
            Self.peer("old", dns: "old.tail0000.ts.net", online: false),
            Self.peer("printer", dns: ""),
            Self.peer("us-lax-wg-402", dns: "us-lax-wg-402.mullvad.ts.net.", os: nil),
        ]
        let me = "oppi-ios.tail0000.ts.net"
        await discovery.discover(peers: peers, selfDNSName: me)
        #expect(Set(probed.withLock { $0 }) == ["rex.tail0000.ts.net", "web.tail0000.ts.net", "mac-mini.tail0000.ts.net"])
        #expect(discovery.found(among: peers, selfDNSName: me) == [testUnwrap(RexTailnetHost(address: "rex.tail0000.ts.net", name: "rex"))])

        await discovery.discover(peers: peers, selfDNSName: me)
        #expect(probed.withLock { $0.count } == 3, "nothing is asked twice in a visit")
        #expect(discovery.pendingNames(peers: peers, selfDNSName: me).isEmpty)
        discovery.forgetUnanswered()
        await discovery.discover(peers: peers, selfDNSName: me)
        #expect(Array(probed.withLock { $0 }.dropFirst(3)) == ["mac-mini.tail0000.ts.net"], "the next visit asks only the one that did not answer")
        await discovery.discover(peers: peers, selfDNSName: me, force: true)
        #expect(probed.withLock { $0.count } == 7, "a refresh asks every one")
        #expect(discovery.found(among: peers.filter { $0.hostName != "rex" }, selfDNSName: me).isEmpty, "a Rex that left is not listed")
        #expect(RexTailnetDiscovery.candidates(peers, selfDNSName: nil).isEmpty, "no own name, no tailnet to ask")
    }

    // MARK: - Add by name

    /// Add Rex by Tailscale Name takes a tailnet name over HTTPS, a
    /// Headscale tailnet's as well as `ts.net`, or a tailnet address or
    /// `*.ts.net` name with a port over plain HTTP (Rex's `tailnet://`
    /// listener), typed as it comes (scheme, slash, root dot, capitals). Plain
    /// HTTP goes to nothing else, and nothing else is taken.
    @Test func addingByNameTakesATailnetNameOrAddress() {
        for typed in ["rex.tail1234.ts.net", "https://Rex.Tail1234.ts.net/", " rex.tail1234.ts.net. ", "https://rex.tail1234.ts.net:443"] {
            let host = RexTailnetHost.parse(typed)
            #expect(host?.address == "rex.tail1234.ts.net", "\(typed)")
            #expect(host?.name == "rex")
            #expect(host?.url == URL(string: "https://rex.tail1234.ts.net"))
        }
        let accepted: [(String, String, String)] = [
            ("rex.hs.example.com", "rex.hs.example.com", "https://rex.hs.example.com"),
            ("https://rex.tail0.ts.net:8443", "rex.tail0.ts.net:8443", "https://rex.tail0.ts.net:8443"),
            ("rex.beta.tailscale.net", "rex.beta.tailscale.net", "https://rex.beta.tailscale.net"),
            ("tailnet://100.101.102.103:7297", "100.101.102.103:7297", "http://100.101.102.103:7297"),
            ("100.64.0.1:7297", "100.64.0.1:7297", "http://100.64.0.1:7297"),
            ("http://[FD7A:115C:A1E0::1]:7297/", "[fd7a:115c:a1e0::1]:7297", "http://[fd7a:115c:a1e0::1]:7297"),
            // Rex's own example for a `tailnet://` listener: plain HTTP to the MagicDNS name.
            ("http://Build.tail0.ts.net:7297", "http://build.tail0.ts.net:7297", "http://build.tail0.ts.net:7297"),
            // Other spellings of a tailnet address reach the address that was checked.
            ("1681915905:7297", "100.64.0.1:7297", "http://100.64.0.1:7297"),
            ("100.64.1:7297", "100.64.0.1:7297", "http://100.64.0.1:7297"),
            ("[fd7a:115c:a1e0:0:0:0:0:1]:7297", "[fd7a:115c:a1e0::1]:7297", "http://[fd7a:115c:a1e0::1]:7297"),
        ]
        for (typed, address, url) in accepted {
            let host = RexTailnetHost.parse(typed)
            #expect(host?.address == address, "\(typed)")
            #expect(host?.url == URL(string: url), "\(typed)")
        }
        #expect(RexTailnetHost.parse("100.101.102.103:7297")?.name == "100.101.102.103", "an address is its own name")
        for typed in ["", "rex", "https://rex.tail0.ts.net/api", "user@rex.tail0.ts.net", "rex .tail0.ts.net",
                      "-rex.tail0.ts.net", "ftp://rex.tail0.ts.net", "rex.tail0.ts.net:0", "rex.tail0.ts.net:70000",
                      // Plain HTTP only to a tailnet address or a ts.net name, each with its port.
                      "http://rex.tail0.ts.net", "http://rex.hs.example.com:7297", "100.64.0.1", "https://100.64.0.1:7297",
                      "192.168.1.5:7297", "100.128.0.1:7297", "[fd00::1]:7297", "http://[fd7a:115c:a1e0::1]",
                      // A zone binds to a local interface; one scheme only; a port is digits.
                      "[fd7a:115c:a1e0::1%en0]:7297", "[fd7a:115c:a1e0::1%25en0]:7297",
                      "https://http://100.64.0.1:7297", "https://tailnet://100.64.0.1:7297",
                      "rex.tail0.ts.net:+443", "100.64.0.1:+7297", "100.64.0.1:07297x"] {
            #expect(RexTailnetHost.parse(typed) == nil, "\(typed)")
        }
        let store = Self.store()
        store.saveTailnetHost(Self.rex)
        store.saveTailnetHost(testUnwrap(RexTailnetHost(address: Self.rex.address, name: "Studio")))
        #expect(store.tailnetHosts().map(\.name) == ["Studio"], "the same name twice is one Rex")
        store.forgetTailnetHost(address: Self.rex.address)
        #expect(store.tailnetHosts().isEmpty)
    }
}
