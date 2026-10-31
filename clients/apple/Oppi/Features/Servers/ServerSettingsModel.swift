import Foundation

/// Everything Server Settings loads from one server, owned in one place so the
/// root and its pushed pages read the same values instead of refetching.
///
/// A model belongs to one server for its whole life: the page that owns it is
/// pinned to that server, and a different server gets a different page with its
/// own model (`ServerSettingsRouteViewController`). So a response that lands
/// after the person switched servers settles into the model that asked for it,
/// and no other. A cancelled request is dropped, not reported as a failure.
///
/// Update polling is owned by the model and holds it weakly, so it ends when
/// the page (and with it the model) goes away. A returning user gets a fresh
/// model; `load()` resumes polling when the server still reports an install or
/// restart in progress, and the Update button is hidden while it does.
@MainActor @Observable
final class ServerSettingsModel {
    let serverId: String

    private(set) var info: ServerInfo?
    private(set) var isLoading = true
    /// Why the last load failed. Only a load writes it, so About This Server's
    /// Retry retries the load and an update's own failure keeps its own row.
    private(set) var loadError: String?
    /// Anything else this server's actions failed at: an update that could not
    /// start, and nothing the page's load row shows.
    private(set) var error: String?

    private(set) var providerSetupState: ProviderSetupState = .unknown
    private(set) var connectedProviderCount = 0

    private(set) var pairedDevices: [AuthDevice]?
    private(set) var isLoadingPairedDevices = false
    private(set) var pairedDevicesError: String?
    private(set) var isRevokingDevice = false
    /// How many Revokes the server has refused. A devices read that began before
    /// a refusal is not an answer to it: when it lands afterwards it keeps the
    /// list it brought and leaves the refusal — "Not allowed." is about the
    /// Revoke, not about the list.
    @ObservationIgnored private var revokeGeneration = 0

    private(set) var updateInFlight = false
    private(set) var updateDidNotReturn = false

    @ObservationIgnored private let coordinator: ConnectionCoordinator
    @ObservationIgnored private var updatePollTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored fileprivate var isFixture = false
    #endif

    /// A client prepared for one server, with the id it was prepared for.
    private struct Client {
        let api: APIClient
        let serverId: String
    }

    init(coordinator: ConnectionCoordinator, serverId: String) {
        self.coordinator = coordinator
        self.serverId = serverId
    }

    // MARK: - Derived values

    var providerSummary: String {
        ProviderConfigurationPresentation(state: providerSetupState)
            .summary(connectedCount: connectedProviderCount)
    }

    /// Whether About This Server has an update to offer or a notice to show.
    var hasUpdateNotice: Bool {
        guard let info else { return false }
        return info.update?.available == true
            || ServerReleaseVersion.isBelowMinimum(info.version)
    }

    /// Value beside About This Server: the update call to action when there is
    /// one, otherwise the running server version. A linked checkout rebuilds; an
    /// outdated server with nothing to install says so instead of offering one.
    var aboutSummary: String? {
        guard hasUpdateNotice else { return info?.version }
        guard let update = info?.update, update.available else { return "Server Outdated" }
        return update.isSourceLink ? "Rebuild Available" : "Update Available"
    }

    // MARK: - Loading

    /// The one reason every page of this server gives for a read that could not
    /// start, so the words never differ by page.
    static let offlineReason = String(localized: "Server is offline")

    func load() async {
        #if DEBUG
        if isFixture { return }
        #endif
        defer { isLoading = false }
        guard let client = await prepareClient() else {
            // A load this page cancelled on its way out is nobody's failure.
            guard !Task.isCancelled else { return }
            loadError = Self.offlineReason
            pairedDevicesError = Self.offlineReason
            return
        }

        do {
            let previousVersion = info?.version
            let next = try await client.api.serverInfo()
            info = next
            error = nil
            loadError = nil
            // The host answered, so a stale "did not come back" no longer applies;
            // its real update status is shown instead.
            if updateDidNotReturn {
                updateDidNotReturn = false
                if let previousVersion, next.version != previousVersion {
                    noteServerVersionAfterUpdate(next.version, serverId: client.serverId)
                }
            }
            if next.update?.isInstalling == true || next.update?.isRestarting == true,
               updatePollTask == nil {
                updateInFlight = true
                startUpdatePolling(client: client, previousVersion: next.version)
            }
        } catch {
            guard !error.isLoadCancellation else { return }
            loadError = error.localizedDescription
        }

        async let providers: () = loadProviderSummary(client)
        async let devices: () = loadPairedDevices(client)
        _ = await (providers, devices)
    }

    private func loadProviderSummary(_ client: Client) async {
        do {
            let statuses = try await client.api.listProviderAuthStatus()
            providerSetupState = ProviderSetupState(providerStatuses: statuses)
            connectedProviderCount = statuses.filter(\.authenticated).count
        } catch {
            guard !error.isLoadCancellation else { return }
            providerSetupState = .unavailable
            connectedProviderCount = 0
        }
    }

    /// Retry for the Paired Devices page.
    func reloadPairedDevices() async {
        guard let client = await prepareClient() else {
            guard !Task.isCancelled else { return }
            pairedDevicesError = Self.offlineReason
            return
        }
        await loadPairedDevices(client)
    }

    private func loadPairedDevices(_ client: Client) async {
        let generation = revokeGeneration
        isLoadingPairedDevices = true
        defer { isLoadingPairedDevices = false }

        do {
            let devices = try await client.api.listAuthDevices()
            pairedDevices = devices
            if generation == revokeGeneration { pairedDevicesError = nil }
        } catch {
            guard !error.isLoadCancellation else { return }
            pairedDevicesError = error.localizedDescription
        }
    }

    func revokeDevice(_ row: PairedDeviceRoster.Row) async {
        guard row.canRevoke else { return }
        // Resolve the client once: a host switch while this runs must not
        // send the DELETE to a different server.
        guard let client = await prepareClient() else {
            guard !Task.isCancelled else { return }
            pairedDevicesError = Self.offlineReason
            return
        }
        isRevokingDevice = true
        defer { isRevokingDevice = false }
        do {
            try await client.api.revokeAuthDevice(id: row.id)
            pairedDevices = (pairedDevices ?? []).filter { $0.id != row.id }
            pairedDevicesError = nil
            await loadPairedDevices(client)
        } catch {
            guard !error.isLoadCancellation else { return }
            // Another device may have revoked it first; refresh so no stale row stays.
            await loadPairedDevices(client)
            revokeGeneration &+= 1
            pairedDevicesError = error.localizedDescription
        }
    }

    // MARK: - Update

    func startServerUpdate() async {
        guard let version = info?.update?.latestVersion, !version.isEmpty,
              !updateInFlight else { return }
        guard let client = await prepareClient() else {
            guard !Task.isCancelled else { return }
            error = Self.offlineReason
            return
        }
        let previousVersion = info?.version
        updateInFlight = true
        updateDidNotReturn = false
        do {
            let started = try await client.api.startServerUpdate(version: version)
            if var current = info {
                current.update = started
                info = current
            }
            startUpdatePolling(client: client, previousVersion: previousVersion)
        } catch {
            guard !(error is CancellationError) else { return }
            self.error = error.localizedDescription
            updateInFlight = false
        }
    }

    /// Polls `/server/info` until the update settles. The task holds the model
    /// weakly, so it ends with the page instead of polling a server nobody is
    /// looking at.
    private func startUpdatePolling(client: Client, previousVersion: String?) {
        updatePollTask?.cancel()
        let serverId = client.serverId
        let api = client.api
        updatePollTask = Task { @MainActor [weak self] in
            // The server allows npm install -g up to 5 minutes, so an answering
            // `installing` host is still working. "Did not come back" means it
            // stopped answering, or sat in `restarting`, for the restart grace.
            let hardDeadline = Date().addingTimeInterval(7 * 60)
            let restartGrace: TimeInterval = 120
            var notSettlingSince: Date?
            while !Task.isCancelled, Date() < hardDeadline {
                if let notSettlingSince, Date().timeIntervalSince(notSettlingSince) > restartGrace {
                    break
                }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                do {
                    var next = try await api.serverInfo()
                    guard !Task.isCancelled, let self else { return }
                    let reported = next.update
                    // A same-version replacement server (failed exec) omits `update`
                    // until its install lookup resolves; keep the in-flight snapshot
                    // instead of blanking it. A new version means the update landed.
                    if next.update == nil, next.version == previousVersion {
                        next.update = info?.update
                    }
                    info = next
                    error = nil
                    if reported?.isInstalling == true {
                        notSettlingSince = nil
                    } else if notSettlingSince == nil {
                        notSettlingSince = Date()
                    }
                    if next.update?.isFailed == true {
                        finishUpdatePolling()
                        return
                    }
                    if let previousVersion, next.version != previousVersion {
                        noteServerVersionAfterUpdate(next.version, serverId: serverId)
                        finishUpdatePolling()
                        return
                    }
                    if next.update?.isRestartNeeded == true {
                        finishUpdatePolling()
                        return
                    }
                    // The host answered idle on the same version: it is serving
                    // normally, so show its real state rather than "did not come back".
                    if reported?.isIdle == true {
                        finishUpdatePolling()
                        return
                    }
                } catch {
                    // Connection drop during restart is expected.
                    if notSettlingSince == nil { notSettlingSince = Date() }
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.updateDidNotReturn = true
            self.finishUpdatePolling()
        }
    }

    private func finishUpdatePolling() {
        updateInFlight = false
        updatePollTask = nil
    }

    // MARK: - Transport

    private func noteServerVersionAfterUpdate(_ version: String, serverId: String) {
        coordinator.connection(for: serverId)?.noteServerVersionAfterUpdate(version)
    }

    /// Reads the id before awaiting so the client and its id always agree.
    private func prepareClient() async -> Client? {
        guard let api = await coordinator.apiClientReady(for: serverId) else { return nil }
        return Client(api: api, serverId: serverId)
    }
}

#if DEBUG
extension ServerSettingsModel {
    /// Fixture for the screenshot harness: a server whose first load never answers,
    /// so the page shows its summary and loading rows.
    static func screenshotLoading(coordinator: ConnectionCoordinator, serverId: String) -> ServerSettingsModel {
        let model = ServerSettingsModel(coordinator: coordinator, serverId: serverId)
        model.isFixture = true
        return model
    }

    /// Fixture for the screenshot harness: `load()` leaves it untouched, so pages
    /// render without a server.
    static func screenshotFixture(
        coordinator: ConnectionCoordinator,
        serverId: String,
        currentDeviceId: String,
        updateAvailable: Bool
    ) -> ServerSettingsModel {
        let model = ServerSettingsModel(coordinator: coordinator, serverId: serverId)
        model.isFixture = true
        model.info = ServerInfo(
            name: "mac-studio",
            version: "1.4.2",
            uptime: 2 * 86_400 + 4 * 3_600,
            os: "darwin",
            arch: "arm64",
            hostname: "mac-studio.local",
            nodeVersion: "24.1.0",
            piVersion: "0.85.1",
            piCliVersion: "0.85.1",
            configVersion: 1,
            identity: nil,
            uploadProtocol: nil,
            images: nil,
            capabilities: nil,
            stats: .init(workspaceCount: 3, activeSessionCount: 1, totalSessionCount: 42, skillCount: 12, modelCount: 9),
            update: updateAvailable
                ? .init(
                    installKind: "npm-global",
                    latestVersion: "1.5.0",
                    available: true,
                    manualCommand: "npm install -g oppi-server@latest",
                    status: "idle",
                    restartMode: "automatic"
                )
                : nil,
            voiceBackends: [
                .init(feature: "dictation", label: "Dictation", state: "ready", target: "http://127.0.0.1:7936"),
                .init(
                    feature: "readAloud", label: "Read aloud", state: "unreachable",
                    target: "http://127.0.0.1:7937", detail: "connect ECONNREFUSED 127.0.0.1:7937"
                ),
                .init(feature: "liveVoice", label: "Live Voice", state: "needs_credentials", detail: "Sign in to xAI to start calls."),
            ]
        )
        model.isLoading = false
        model.providerSetupState = .configured
        model.connectedProviderCount = 2
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        model.pairedDevices = [
            AuthDevice(
                id: currentDeviceId,
                name: "Chen's iPhone",
                scope: "device",
                createdAt: now - 9 * 86_400_000,
                lastUsedAt: now,
                revokedAt: nil,
                keyEnrolled: true,
                pairingMethod: "invite",
                pairingSource: "100.64.0.7"
            ),
            AuthDevice(
                id: "dev-ipad",
                name: "Chen's iPad",
                scope: "device",
                createdAt: now - 30 * 86_400_000,
                lastUsedAt: now - 3 * 3_600_000,
                revokedAt: nil,
                keyEnrolled: true,
                pairingMethod: "tailscale",
                pairingSource: "chen@github"
            ),
            AuthDevice(
                id: "dev-script",
                name: "oppi CLI",
                scope: "device",
                createdAt: now - 60 * 86_400_000,
                lastUsedAt: nil,
                revokedAt: nil,
                keyEnrolled: false
            ),
        ]
        return model
    }
}
#endif
