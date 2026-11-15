import Foundation
import Observation
import os

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Rex")

/// Whether a tailnet machine serves Rex's API, asked without SSH and without
/// a sign-in: a plain `GET https://<name>/api/control` through the tailnet
/// route (`TailnetTransportRoute`: Oppi's node's SOCKS proxy, else the system
/// network). Rex answers a GET that is not a WebSocket upgrade with
/// `426 Upgrade Required` and a body that starts with Go's
/// `WebSocket protocol violation`; a web server without that endpoint answers
/// 404, and a Rex that does not admit this device answers 403. Only the 426
/// with that body is Rex: nothing is matched by machine name.
enum RexTailnetProbe {
    enum Verdict: Equatable, Sendable {
        case rex
        /// It answered, but not as Rex.
        case notRex
        /// Refused, timed out, or no route.
        case unreachable
    }

    static let timeout: Duration = .seconds(2)
    /// Probes in flight at once.
    static let concurrency = 4
    static let signature = "WebSocket protocol violation"

    static func classify(status: Int, body: Data) -> Verdict {
        guard status == 426 else { return .notRex }
        return String(decoding: body.prefix(256), as: UTF8.self).hasPrefix(signature) ? .rex : .notRex
    }

    /// One probe, at most `timeout`. Redirects are not followed: a machine
    /// that sends this one elsewhere is not Rex.
    static func probe(dnsName: String, timeout: Duration = timeout) async -> Verdict {
        guard let host = RexTailnetHost(dnsName: dnsName) else { return .notRex }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        configuration.urlCache = nil
        TailnetTransportRoute.apply(to: configuration, proxy: TailnetTransportRoute.Snapshot.forHost(host.dnsName).proxy)
        let session = URLSession(configuration: configuration, delegate: RexProbeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: host.url.appending(path: "api/control"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .notRex }
            return classify(status: http.statusCode, body: data)
        } catch {
            return .unreachable
        }
    }

    /// Probes each name once, `concurrency` at a time, and reports each
    /// verdict (with how long it took) as it lands. Cancelling the caller
    /// cancels the probes; a cancelled probe reports nothing.
    static func probeAll(
        _ names: [String],
        concurrency: Int = concurrency,
        isolation: isolated (any Actor)? = #isolation,
        probe: @escaping @Sendable (String) async -> Verdict,
        onVerdict: (String, Verdict, Duration) -> Void
    ) async {
        await withTaskGroup(of: (String, Verdict, Duration).self) { group in
            var pending = names[...]
            for _ in 0..<max(1, concurrency) {
                guard let name = pending.popFirst() else { break }
                group.addTask { await timed(name, probe) }
            }
            while let (name, verdict, elapsed) = await group.next() {
                if !Task.isCancelled { onVerdict(name, verdict, elapsed) }
                if let name = pending.popFirst(), !Task.isCancelled {
                    group.addTask { await timed(name, probe) }
                }
            }
        }
    }

    private static func timed(_ name: String, _ probe: @Sendable (String) async -> Verdict) async -> (String, Verdict, Duration) {
        let started = ContinuousClock.now
        let verdict = await probe(name)
        return (name, verdict, .now - started)
    }
}

private final class RexProbeRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Finds Rex on the tailnet from the machine list of Oppi's own Tailscale node
/// (`TailnetNodeController.onlinePeers`, the list Set Up a Computer shows):
/// every online machine of this device's own tailnet (its MagicDNS suffix;
/// machines shared in from elsewhere, such as hundreds of Mullvad exit nodes,
/// are not asked) that can run a server (phones and tablets cannot) is
/// probed once (`RexTailnetProbe`). An answer (Rex or not) is kept for the
/// app's run, so coming back to the Terminal tab does not probe again; a
/// machine that did not answer is asked again on the next visit, and a pull to
/// refresh asks every one. With only the Tailscale app's VPN, Oppi has no
/// machine list, and a Rex is added by its name instead.
@MainActor @Observable
final class RexTailnetDiscovery {
    static let shared = RexTailnetDiscovery()

    /// Each name that answered, Rex or not, for this run of the app.
    private(set) var verdicts: [String: RexTailnetProbe.Verdict] = [:]
    /// Names that did not answer, not asked again until `forgetUnanswered`.
    @ObservationIgnored private var unanswered: Set<String> = []
    /// Passes running; a cancelled one can still be winding down beside its replacement.
    private var passes = 0
    /// Probes are running.
    var probing: Bool { passes > 0 }
    @ObservationIgnored private let probe: @Sendable (String) async -> RexTailnetProbe.Verdict

    init(probe: @escaping @Sendable (String) async -> RexTailnetProbe.Verdict = { await RexTailnetProbe.probe(dnsName: $0) }) {
        self.probe = probe
    }

    /// The machines worth asking: online, able to run a server, and on the
    /// tailnet `selfDNSName` (this node's own name) is on.
    static func candidates(_ peers: [TailnetPeer], selfDNSName: String?) -> [TailnetPeer] {
        guard let own = RexTailnetHost.normalizedName(selfDNSName ?? "") else { return [] }
        let suffix = own.drop { $0 != "." }
        return peers.filter {
            $0.isOnline && $0.canHostOppi && RexTailnetHost.normalizedName($0.dnsName)?.hasSuffix(suffix) == true
        }
    }

    /// Probes the candidates among `peers` that have no verdict yet (all of
    /// them with `force`), and returns when they have answered or the caller
    /// was cancelled.
    func discover(peers: [TailnetPeer], selfDNSName: String?, force: Bool = false) async {
        let names = pendingNames(peers: peers, selfDNSName: selfDNSName, force: force)
        guard !names.isEmpty else { return }
        passes += 1
        defer { passes -= 1 }
        await RexTailnetProbe.probeAll(names, probe: probe, onVerdict: { name, verdict, elapsed in
            if verdict == .unreachable {
                verdicts[name] = nil
                unanswered.insert(name)
            } else {
                verdicts[name] = verdict
                unanswered.remove(name)
            }
            let ms = Int(elapsed / .milliseconds(1))
            logger.info("Rex probe \(name, privacy: .private) verdict=\(String(describing: verdict), privacy: .public) ms=\(ms, privacy: .public)")
        })
    }

    /// The candidates `discover` would ask now: those with no answer and not
    /// already unanswered this visit, or every one with `force`.
    func pendingNames(peers: [TailnetPeer], selfDNSName: String?, force: Bool = false) -> [String] {
        Self.candidates(peers, selfDNSName: selfDNSName).compactMap { RexTailnetHost.normalizedName($0.dnsName) }
            .filter { force || (verdicts[$0] == nil && !unanswered.contains($0)) }
    }

    /// A new visit: machines that did not answer are asked again.
    func forgetUnanswered() {
        unanswered = []
    }

    /// The Rex nodes among `peers`, named by their Tailscale device name.
    func found(among peers: [TailnetPeer], selfDNSName: String?) -> [RexTailnetHost] {
        Self.candidates(peers, selfDNSName: selfDNSName).compactMap { peer in
            guard let host = RexTailnetHost(dnsName: peer.dnsName, name: peer.hostName.isEmpty ? nil : peer.hostName),
                  verdicts[host.dnsName] == .rex else { return nil }
            return host
        }
    }
}

/// How this device reaches the tailnet, for what the Terminal tab can list.
enum RexTailnetReach: Equatable, Sendable {
    /// Oppi's own Tailscale node runs: its machine list is there to probe.
    case peers
    /// Only the Tailscale app's VPN: a Rex is reachable, but Oppi cannot list
    /// the machines, so it is added by name.
    case systemOnly
    /// No route onto a tailnet.
    case none

    @MainActor
    static var current: Self {
        if TailnetNodeController.shared.state == .running, TailnetTransportRoute.proxy != nil { return .peers }
        return RexTailnetPath.hasTailscaleAddress() ? .systemOnly : .none
    }
}
