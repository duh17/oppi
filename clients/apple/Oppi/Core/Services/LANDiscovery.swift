import Foundation
import OSLog

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "LANDiscovery")

/// Discovers oppi servers on the local network via Bonjour (`_oppi._tcp`).
///
/// Uses `NetServiceBrowser` for discovery and `NetService` resolve for TXT
/// record retrieval. NWBrowser has a known issue where TXT records arrive
/// as `.none` metadata for `dns-sd -R` registrations — NetService handles
/// this correctly.
@MainActor @Observable
final class LANDiscovery: NSObject {
    typealias UpdateHandler = ([LANDiscoveredEndpoint]) -> Void

    private(set) var endpoints: [LANDiscoveredEndpoint] = []

    var onUpdate: UpdateHandler?

    private var netServiceBrowser: NetServiceBrowser?
    private var discoveredServices: [NetService] = []
    private(set) var browseStartedAt: ContinuousClock.Instant?
    private var waiters: [UUID: (select: UpdateSelection, continuation: CheckedContinuation<LANDiscoveredEndpoint?, Never>)] = [:]
    typealias UpdateSelection = @MainActor ([LANDiscoveredEndpoint]) -> LANDiscoveredEndpoint?

    /// Event-driven first-result wait; the deadline also owns cancellation.
    func waitForEndpoint(
        deadline: APIClient.BootstrapDeadline,
        select: @escaping UpdateSelection
    ) async -> LANDiscoveredEndpoint? {
        if let endpoint = select(endpoints) { return endpoint }
        let id = UUID()
        let expiry = Task { @MainActor [weak self] in
            do { try await deadline.waitForExpiry() } catch { return }
            self?.finishWaiter(id, endpoint: nil)
        }
        defer { expiry.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiters[id] = (select, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishWaiter(id, endpoint: nil) }
        }
    }

    private func finishWaiter(_ id: UUID, endpoint: LANDiscoveredEndpoint?) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: endpoint)
    }

    /// Tests that inject endpoints via `publishForTesting` pass `false` so a real
    /// Bonjour browser on the host network cannot replace the synthetic list.
    private let browsesBonjour: Bool

    init(browsesBonjour: Bool = true) {
        self.browsesBonjour = browsesBonjour
        super.init()
    }

    func start() {
        guard netServiceBrowser == nil else { return }
        browseStartedAt = .now
        guard browsesBonjour else { return }

        let browser = NetServiceBrowser()
        browser.delegate = self
        netServiceBrowser = browser

        logger.info("Starting NetServiceBrowser for _oppi._tcp")
        browser.searchForServices(ofType: "_oppi._tcp.", inDomain: "local.")
    }

    func stop() {
        netServiceBrowser?.stop()
        netServiceBrowser = nil
        for service in discoveredServices {
            service.stop()
        }
        discoveredServices.removeAll()
        publish([])
        for id in Array(waiters.keys) { finishWaiter(id, endpoint: nil) }
    }

    private func publish(_ next: [LANDiscoveredEndpoint]) {
        guard next != endpoints else { return }
        endpoints = next
        logger.debug("LAN endpoints changed: count=\(next.count)")
        onUpdate?(next)
        reevaluateWaiters()
    }

    func reevaluateWaiters() {
        for (id, waiter) in waiters {
            if let endpoint = waiter.select(endpoints) { finishWaiter(id, endpoint: endpoint) }
        }
    }

    #if DEBUG
    func publishForTesting(_ endpoints: [LANDiscoveredEndpoint]) { publish(endpoints) }
    #endif

    /// Rebuild the endpoint list from all resolved services.
    private func rebuildEndpoints() {
        var deduped: [String: LANDiscoveredEndpoint] = [:]

        for service in discoveredServices {
            guard let txtData = service.txtRecordData() else { continue }
            let txt = Self.parseTXTRecordData(txtData)
            guard let endpoint = Self.endpoint(fromTXTRecord: txt) else { continue }
            deduped[endpoint.serverFingerprintPrefix] = endpoint
        }

        let next = deduped.values.sorted {
            if $0.serverFingerprintPrefix == $1.serverFingerprintPrefix {
                return $0.host < $1.host
            }
            return $0.serverFingerprintPrefix < $1.serverFingerprintPrefix
        }

        publish(next)
    }

    // MARK: - NetService Delegate Trampolines

    fileprivate func handleServiceFound(_ service: NetService) {
        logger.debug("Service found: \(service.name, privacy: .public)")

        service.delegate = self
        discoveredServices.append(service)
        service.resolve(withTimeout: 5.0)
        service.startMonitoring()
    }

    fileprivate func handleServiceRemoved(_ service: NetService) {
        logger.debug("Service removed: \(service.name, privacy: .public)")
        service.stop()
        discoveredServices.removeAll { $0 == service }
        rebuildEndpoints()
    }

    fileprivate func handleServiceResolved(_ service: NetService) {
        guard service.txtRecordData() != nil else {
            logger.warning("Resolved but no TXT data: \(service.name, privacy: .public)")
            return
        }
        logger.debug("Service resolved: \(service.name, privacy: .public) host=\(service.hostName ?? "nil", privacy: .public)")
        rebuildEndpoints()
    }

    fileprivate func handleTXTRecordUpdate(_: Data, name: String) {
        logger.debug("TXT record updated: \(name, privacy: .public)")
        rebuildEndpoints()
    }

    // MARK: - Parsing

    nonisolated static func endpoint(fromTXTRecord txt: [String: String]) -> LANDiscoveredEndpoint? {
        guard let sid = txt["sid"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sid.isEmpty,
              let host = txt["ip"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty,
              let rawPort = txt["p"],
              let port = Int(rawPort),
              (1...65_535).contains(port) else {
            return nil
        }

        let tfp = txt["tfp"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        return LANDiscoveredEndpoint(
            host: host,
            port: port,
            serverFingerprintPrefix: sid,
            tlsCertFingerprintPrefix: tfp?.isEmpty == true ? nil : tfp
        )
    }

    nonisolated static func parseTXTRecordData(_ data: Data) -> [String: String] {
        let rawMap = NetService.dictionary(fromTXTRecord: data)
        var map: [String: String] = [:]
        map.reserveCapacity(rawMap.count)

        for (key, value) in rawMap {
            guard let text = String(data: value, encoding: .utf8) else {
                continue
            }
            map[key] = text
        }

        return map
    }
}

// MARK: - NetServiceBrowserDelegate

extension LANDiscovery: @preconcurrency NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        handleServiceFound(service)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        handleServiceRemoved(service)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        logger.error("Search failed with code \(code)")
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        logger.info("Search stopped")
    }
}

// MARK: - NetServiceDelegate

extension LANDiscovery: @preconcurrency NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        handleServiceResolved(sender)
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        logger.error("Resolve failed for \(sender.name, privacy: .public) code=\(code)")
    }

    func netService(
        _ sender: NetService,
        didUpdateTXTRecord data: Data
    ) {
        handleTXTRecordUpdate(data, name: sender.name)
    }
}
