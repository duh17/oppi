import Foundation
import Observation
import UIKit

/// The Rexes the Terminal tab's tailnet list shows, once each: the ones saved by
/// name first, in the order they were added, then the rest discovery found, by
/// name. A Rex a listed SSH host already reaches (`listedBySSH`: its remembered
/// `RexDirectStore` address names it) is left out, because that host's own Rex
/// section lists it over one link.
extension Array where Element == RexTailnetHost {
    static func tailnet(
        saved: [RexTailnetHost],
        discovered: [RexTailnetHost],
        listedBySSH: (RexTailnetHost) -> Bool
    ) -> [RexTailnetHost] {
        var seen = Set<String>()
        var hosts: [RexTailnetHost] = []
        for host in saved where seen.insert(host.dnsName).inserted && !listedBySSH(host) {
            hosts.append(host)
        }
        let found = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for host in found where seen.insert(host.dnsName).inserted && !listedBySSH(host) {
            hosts.append(host)
        }
        return hosts
    }
}

/// Follows one Rex reached over Tailscale alone, for the Terminal tab: its
/// `RexMonitor` reads Rex straight over Tailscale while the tab shows, and a
/// tapped session or pane opens over the same route in a terminal of its own
/// (`SSHTerminalConnectSession.openTailnetRexPane`). There is no sign-in, so
/// nothing waits for a tap. The tab draws it like a saved host's Rex
/// (`SSHTerminalRexListFollowing`).
@MainActor @Observable
final class RexTailnetFollower: SSHTerminalRexListFollowing {
    let host: RexTailnetHost
    let monitor: RexMonitor
    let session: SSHTerminalConnectSession
    /// A change to Rex (new, rename, close) is in flight, or the last one's
    /// failure, shown under the heading until the next one or a visit.
    private(set) var managing = false
    private(set) var manageFailure: String?
    var expandedSessions: Set<String> = []
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(host: RexTailnetHost, monitor: RexMonitor? = nil, session: SSHTerminalConnectSession = SSHTerminalConnectSession()) {
        self.host = host
        let monitor = monitor ?? RexMonitor(tailnet: host)
        self.monitor = monitor
        self.session = session
        monitor.openPane = { [weak session] pane in session?.openTailnetRexPane(pane, on: host) }
        // The stream does not outlive the foreground, even while a terminal
        // covers the tab; it reads Rex again when the tab next shows.
        observers = [NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopReading() }
        }]
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        reader?.cancel()
        session.cancel()
    }

    var profile: SSHTerminalProfile { host.profile }

    var isOpening: Bool { session.connecting }

    var listState: SSHTerminalRexListState {
        SSHTerminalRexListState(
            connecting: session.connecting,
            opening: session.connecting,
            connectFailure: session.failure,
            snapshot: monitor.snapshot,
            absence: monitor.absence,
            failure: monitor.failure,
            needsYou: monitor.needsAttention,
            expanded: expandedSessions,
            canManage: monitor.canManage,
            managing: managing,
            manageFailure: manageFailure
        )
    }

    /// Starts reading while the tab is active. Not being active (a prompt, a
    /// form, or a terminal over the tab) does not stop it, as for a saved
    /// host's Rex: a Rename prompt submits over this stream. Leaving the tab
    /// (`stopReading`), the background, and `close` stop it.
    func sync(active: Bool) {
        _ = session.connecting
        if active { startReading() }
    }

    func manage(_ what: String, _ work: () async throws -> Void) async {
        guard !managing else { return }
        managing = true
        manageFailure = nil
        defer { managing = false }
        do {
            try await work()
        } catch is CancellationError {
        } catch {
            manageFailure = "\(what) \(error.localizedDescription)"
        }
    }

    func appeared() {
        manageFailure = nil
    }

    /// Nothing to connect: Rex admits this device by its Tailscale identity.
    func connect() {}

    /// Reads Rex once more, and again after a refusal or a failure.
    func refresh() async {
        monitor.retry()
        startReading()
        await monitor.resync()
    }

    private func startReading() {
        guard reader == nil, !monitor.gaveUp else { return }
        reader = Task { [weak self, monitor] in
            await monitor.runTailnet()
            guard !Task.isCancelled else { return }
            self?.reader = nil
        }
    }

    func stopReading() {
        reader?.cancel()
        reader = nil
    }

    func close() {
        stopReading()
    }
}

/// The Terminal tab's Rex on your tailnet: the nodes added by name and those
/// discovery finds, each with a `RexTailnetFollower` the tab lists as a Rex
/// section of its own, and the card that heads them (what limits the list, and
/// Add Rex by Tailscale Name).
@MainActor @Observable
final class RexTailnetSection {
    private(set) var entries: [RexTailnetHost] = []
    private(set) var reach: RexTailnetReach = .none
    /// Each listed node's follower, by name.
    private(set) var followers: [String: RexTailnetFollower] = [:]
    let discovery: RexTailnetDiscovery
    @ObservationIgnored private var discovering: Task<Void, Never>?
    @ObservationIgnored private var peers: [TailnetPeer] = []
    @ObservationIgnored private var selfDNSName: String?
    /// The tab has been active since it last showed: a machine that did not
    /// answer is asked again on the next visit, not after each prompt.
    @ObservationIgnored private var visiting = false
    /// The Tailscale names the listed SSH hosts' Rex said they serve at, read once
    /// for a given host list. The saved nodes themselves are read on every update:
    /// they are the store's own small array, and a cached copy would outlive a
    /// forget until the store's notification arrived (one update late).
    @ObservationIgnored private var sshNamesCache: (hosts: [SSHTerminalProfile], names: Set<String>)?
    /// Bumped when the store changes, so the tab runs another pass.
    private var storeRevision = 0
    @ObservationIgnored private var storeObserver: NSObjectProtocol?
    @ObservationIgnored private let store: RexDirectStore
    @ObservationIgnored private let makeFollower: @MainActor (RexTailnetHost) -> RexTailnetFollower
    /// How this device reaches the tailnet now; previews pin it.
    @ObservationIgnored private let reachNow: @MainActor () -> RexTailnetReach
    /// The experiments: Rex is discovered and read only while its switch is on.
    @ObservationIgnored private let access: @MainActor () -> SSHTerminalExperimentAccess

    init(
        store: RexDirectStore = RexDirectStore(),
        discovery: RexTailnetDiscovery = .shared,
        reach: @escaping @MainActor () -> RexTailnetReach = { .current },
        makeFollower: @escaping @MainActor (RexTailnetHost) -> RexTailnetFollower = { RexTailnetFollower(host: $0) },
        access: @escaping @MainActor () -> SSHTerminalExperimentAccess = { .current }
    ) {
        self.store = store
        self.discovery = discovery
        self.reachNow = reach
        self.access = access
        self.makeFollower = makeFollower
        // A host saved, or an SSH host learning or forgetting its Rex's
        // address, changes what is listed.
        let changes = store.changes
        storeObserver = NotificationCenter.default.addObserver(forName: changes.name, object: changes.object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
    }

    isolated deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        discovering?.cancel()
    }

    private func storeChanged() {
        sshNamesCache = nil
        storeRevision += 1
    }

    /// The tab shows the tailnet nodes once it lists one, or there is a way onto a tailnet.
    var isShown: Bool { !entries.isEmpty || reach != .none }

    /// The listed nodes' followers, in list order.
    var listedFollowers: [RexTailnetFollower] { entries.compactMap { followers[$0.dnsName] } }

    /// Takes what the tab knows now: the node's machine list and its own name,
    /// the SSH hosts whose Rex the tab already lists (one of them reaching the
    /// same Rex lists it instead), and whether the tab shows. Reads how this
    /// device reaches the tailnet, and probes machines not asked yet while
    /// `active`; the tab syncs each follower itself.
    func update(peers: [TailnetPeer], selfDNSName: String?, sshRexHosts: [SSHTerminalProfile], active: Bool) {
        _ = storeRevision
        let reach = reachNow()
        self.peers = peers
        self.selfDNSName = selfDNSName
        if self.reach != reach { self.reach = reach }
        let saved = store.tailnetHosts()
        let sshNames: Set<String>
        if let cached = sshNamesCache, cached.hosts == sshRexHosts {
            sshNames = cached.names
        } else {
            sshNames = store.tailnetNames(among: sshRexHosts)
            sshNamesCache = (sshRexHosts, sshNames)
        }
        let next = [RexTailnetHost].tailnet(
            saved: saved,
            discovered: reach == .peers ? discovery.found(among: peers, selfDNSName: selfDNSName) : [],
            listedBySSH: { sshNames.contains($0.dnsName) }
        )
        if next != entries { entries = next }
        let wanted = Set(entries.map(\.dnsName))
        for name in followers.keys where !wanted.contains(name) {
            followers[name]?.close()
            followers[name] = nil
        }
        for host in entries where followers[host.dnsName] == nil {
            followers[host.dnsName] = makeFollower(host)
        }
        // Like the followers, a prompt over the tab does not stop discovery;
        // leaving the tab does (`stop`).
        guard active else { return }
        if !visiting {
            visiting = true
            // A machine that did not answer is asked again on the next visit.
            discovery.forgetUnanswered()
        }
        if reach == .peers, discovering == nil,
           !discovery.pendingNames(peers: peers, selfDNSName: selfDNSName).isEmpty {
            startDiscovery(force: false)
        }
    }

    /// The experiment was off when this last looked: nothing is listed, read, or
    /// offered (the saved nodes stay in the store, so turning it on lists them).
    func clear() {
        stop()
        for follower in followers.values { follower.close() }
        followers = [:]
        entries = []
        reach = .none
        peers = []
    }

    /// The tab is gone (another screen, or Oppi left the foreground): discovery
    /// stops, and the next visit asks again what did not answer.
    func stop() {
        visiting = false
        discovering?.cancel()
        discovering = nil
    }

    /// A pull to refresh: probes every machine again (through `discovering`,
    /// so leaving the tab cancels it and `update` starts no second pass beside it).
    func refresh() async {
        guard access().rex, reach == .peers else { return }
        startDiscovery(force: true)
        await discovering?.value
    }

    /// The listed node that registers terminals under `id`.
    func follower(id: UUID) -> RexTailnetFollower? {
        followers.values.first { $0.host.id == id }
    }

    /// One discovery pass at a time; a new one replaces the one running.
    private func startDiscovery(force: Bool) {
        guard access().rex else { return }
        discovering?.cancel()
        discovering = Task { [weak self, discovery, peers, selfDNSName] in
            await discovery.discover(peers: peers, selfDNSName: selfDNSName, force: force)
            // A cancelled pass was replaced or stopped by whoever cancelled it.
            guard !Task.isCancelled else { return }
            self?.discovering = nil
        }
    }
}
