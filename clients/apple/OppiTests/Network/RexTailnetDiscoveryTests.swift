import Foundation
import Synchronization
import Testing
@testable import Oppi

@Suite("Finding Rex on the tailnet", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RexTailnetDiscoveryTests {
    static let rex = RexTailnetHost(dnsName: "rex.tail0000.ts.net")!
    static let rexBody = Data("WebSocket protocol violation: Connection header \"\" does not contain Upgrade\n".utf8)

    static func peer(_ name: String, dns: String, os: String? = "macOS", online: Bool = true) -> TailnetPeer {
        TailnetPeer(id: name, hostName: name, dnsName: dns, os: os, tailscaleIPs: ["100.64.0.1"], isOnline: online)
    }

    static func store() -> RexDirectStore {
        RexDirectStore(defaults: UserDefaults(suiteName: "rex-tailnet-tests-\(UUID().uuidString)")!)
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
        #expect(await RexTailnetProbe.probe(dnsName: "rex.example.com") == .notRex, "a name off the tailnet is never dialed")
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
        #expect(discovery.found(among: peers, selfDNSName: me) == [RexTailnetHost(dnsName: "rex.tail0000.ts.net", name: "rex")!])

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

    /// Add Rex by Tailscale Name takes a MagicDNS name on `ts.net`, typed as
    /// it comes (scheme, slash, root dot, capitals), and nothing else.
    @Test func addingByNameTakesOnlyATailnetName() {
        for typed in ["rex.tail1234.ts.net", "https://Rex.Tail1234.ts.net/", " rex.tail1234.ts.net. "] {
            let host = RexTailnetHost.parse(typed)
            #expect(host?.dnsName == "rex.tail1234.ts.net", "\(typed)")
            #expect(host?.name == "rex")
            #expect(host?.url == URL(string: "https://rex.tail1234.ts.net"))
        }
        for typed in ["", "rex", "ts.net", "tail.ts.net", "rex.example.com", "http://rex.tail0.ts.net",
                      "https://rex.tail0.ts.net:8443", "https://rex.tail0.ts.net/api", "100.64.0.1",
                      "user@rex.tail0.ts.net", "rex .tail0.ts.net", "rex.tail0.ts.net.example.com", "-rex.tail0.ts.net",
                      "rex.beta.tailscale.net"] {
            #expect(RexTailnetHost.parse(typed) == nil, "\(typed)")
        }
        let store = Self.store()
        store.saveTailnetHost(Self.rex)
        store.saveTailnetHost(RexTailnetHost(dnsName: Self.rex.dnsName, name: "Studio")!)
        #expect(store.tailnetHosts().map(\.name) == ["Studio"], "the same name twice is one Rex")
        store.forgetTailnetHost(dnsName: Self.rex.dnsName)
        #expect(store.tailnetHosts().isEmpty)
    }
}
