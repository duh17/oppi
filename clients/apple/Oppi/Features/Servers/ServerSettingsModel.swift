import Foundation

enum ServerDetailMobileOutputGuideState: Equatable {
    case loading
    case available(enabled: Bool, revision: Int, error: String?)
    case failed(String)

    static func resolve(
        configuration: MobileOutputGuideConfiguration?,
        isLoading: Bool,
        error: String?
    ) -> Self {
        if let configuration {
            return .available(
                enabled: configuration.enabled,
                revision: configuration.revision,
                error: error
            )
        }
        if isLoading { return .loading }
        return .failed(error ?? "Mobile Output Guide setting is unavailable")
    }
}

/// Everything Server Settings loads from one server, owned in one place so the
/// root and its pushed pages read the same values instead of refetching.
///
/// The root view owns the model and calls `attach` when the visible host
/// changes; pages receive the model and call its actions. `serverId` is the
/// visible host: every async result is applied only while the server it was
/// requested for is still `serverId` (`ServerSelection.shouldApplyHostResult`),
/// so a late response never paints another host.
///
/// Update polling is owned by the model and holds it weakly, so it ends when
/// the root view (and with it the model) goes away or the host changes. A
/// returning user gets a fresh model; `load()` resumes polling when the server
/// still reports an install or restart in progress, and the Update button is
/// hidden while it does.
@MainActor @Observable
final class ServerSettingsModel {
    private(set) var serverId: String?

    private(set) var info: ServerInfo?
    private(set) var isLoading = true
    private(set) var error: String?

    private(set) var providerSetupState: ProviderSetupState = .unknown
    private(set) var connectedProviderCount = 0

    private(set) var mobileOutputGuide: MobileOutputGuideConfiguration?
    private(set) var isLoadingMobileOutputGuide = false
    private(set) var isSavingMobileOutputGuide = false
    private(set) var mobileOutputGuideError: String?

    private(set) var pairedDevices: [AuthDevice]?
    private(set) var isLoadingPairedDevices = false
    private(set) var pairedDevicesError: String?
    private(set) var isRevokingDevice = false

    private(set) var updateInFlight = false
    private(set) var updateDidNotReturn = false

    @ObservationIgnored private var coordinator: ConnectionCoordinator?
    @ObservationIgnored private var updatePollTask: Task<Void, Never>?
    #if DEBUG
    @ObservationIgnored fileprivate var isFixture = false
    #endif

    /// A client prepared for one server, with the id it was prepared for.
    private struct Client {
        let api: APIClient
        let serverId: String
    }

    /// Binds the model to a server. Switching servers drops everything loaded
    /// for the previous one; re-attaching the same server keeps it so a page
    /// pop does not flash a loading state.
    func attach(coordinator: ConnectionCoordinator, serverId: String) {
        self.coordinator = coordinator
        guard self.serverId != serverId else { return }
        updatePollTask?.cancel()
        updatePollTask = nil
        self.serverId = serverId
        info = nil
        error = nil
        isLoading = true
        providerSetupState = .unknown
        connectedProviderCount = 0
        mobileOutputGuide = nil
        mobileOutputGuideError = nil
        isLoadingMobileOutputGuide = false
        isSavingMobileOutputGuide = false
        pairedDevices = nil
        pairedDevicesError = nil
        isLoadingPairedDevices = false
        isRevokingDevice = false
        updateInFlight = false
        updateDidNotReturn = false
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
    /// one, otherwise the running server version.
    var aboutSummary: String? {
        if hasUpdateNotice { return "Update Available" }
        return info?.version
    }

    func pairedDevicesState(currentDeviceId: String?) -> ServerDetailPairedDevicesState {
        ServerDetailPairedDevicesState.resolve(
            devices: pairedDevices,
            currentDeviceId: currentDeviceId,
            isLoading: isLoadingPairedDevices,
            error: pairedDevicesError
        )
    }

    var mobileOutputGuideState: ServerDetailMobileOutputGuideState {
        ServerDetailMobileOutputGuideState.resolve(
            configuration: mobileOutputGuide,
            isLoading: isLoadingMobileOutputGuide,
            error: mobileOutputGuideError
        )
    }

    // MARK: - Loading

    func load() async {
        #if DEBUG
        if isFixture { return }
        #endif
        let requestedId = serverId
        guard let client = await prepareClient() else {
            guard let requestedId, shouldApply(requestedId) else { return }
            error = "Unable to prepare server transport"
            pairedDevicesError = "Unable to prepare server transport"
            isLoading = false
            return
        }
        guard shouldApply(client.serverId) else { return }

        do {
            let previousVersion = info?.version
            let next = try await client.api.serverInfo()
            guard shouldApply(client.serverId) else { return }
            info = next
            error = nil
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
            guard shouldApply(client.serverId, error: error) else { return }
            self.error = error.localizedDescription
        }

        async let providers: () = loadProviderSummary(client)
        async let guide: () = loadMobileOutputGuide(client)
        async let devices: () = loadPairedDevices(client)
        _ = await (providers, guide, devices)
        guard shouldApply(client.serverId) else { return }
        isLoading = false
    }

    private func loadProviderSummary(_ client: Client) async {
        do {
            let statuses = try await client.api.listProviderAuthStatus()
            guard shouldApply(client.serverId) else { return }
            providerSetupState = ProviderSetupState(providerStatuses: statuses)
            connectedProviderCount = statuses.filter(\.authenticated).count
        } catch {
            guard shouldApply(client.serverId, error: error) else { return }
            providerSetupState = .unavailable
            connectedProviderCount = 0
        }
    }

    /// Retry for the Paired Devices page.
    func reloadPairedDevices() async {
        let requestedId = serverId
        guard let client = await prepareClient() else {
            guard let requestedId, shouldApply(requestedId) else { return }
            pairedDevicesError = "Unable to prepare server transport"
            return
        }
        await loadPairedDevices(client)
    }

    private func loadPairedDevices(_ client: Client) async {
        guard shouldApply(client.serverId) else { return }
        isLoadingPairedDevices = true
        defer { if shouldApply(client.serverId) { isLoadingPairedDevices = false } }

        do {
            let devices = try await client.api.listAuthDevices()
            guard shouldApply(client.serverId) else { return }
            pairedDevices = devices
            pairedDevicesError = nil
        } catch {
            guard shouldApply(client.serverId, error: error) else { return }
            pairedDevicesError = error.localizedDescription
        }
    }

    func revokeDevice(_ row: PairedDeviceRoster.Row) async {
        guard row.canRevoke else { return }
        // Resolve the client once: a host switch while this runs must not
        // send the DELETE to a different server.
        let requestedId = serverId
        guard let client = await prepareClient() else {
            guard let requestedId, shouldApply(requestedId) else { return }
            pairedDevicesError = "Unable to prepare server transport"
            return
        }
        guard shouldApply(client.serverId) else { return }
        isRevokingDevice = true
        defer { if shouldApply(client.serverId) { isRevokingDevice = false } }
        do {
            try await client.api.revokeAuthDevice(id: row.id)
            guard shouldApply(client.serverId) else { return }
            pairedDevices = (pairedDevices ?? []).filter { $0.id != row.id }
            pairedDevicesError = nil
            await loadPairedDevices(client)
        } catch {
            guard shouldApply(client.serverId, error: error) else { return }
            // Another device may have revoked it first; refresh so no stale row stays.
            await loadPairedDevices(client)
            guard shouldApply(client.serverId) else { return }
            pairedDevicesError = error.localizedDescription
        }
    }

    /// Retry for the Mobile Output Guide row.
    func reloadMobileOutputGuide() async {
        let requestedId = serverId
        guard let client = await prepareClient() else {
            guard let requestedId, shouldApply(requestedId) else { return }
            mobileOutputGuideError = "Unable to prepare server transport"
            return
        }
        await loadMobileOutputGuide(client)
    }

    private func loadMobileOutputGuide(_ client: Client) async {
        guard shouldApply(client.serverId) else { return }
        isLoadingMobileOutputGuide = mobileOutputGuide == nil
        defer { if shouldApply(client.serverId) { isLoadingMobileOutputGuide = false } }
        do {
            let guide = try await client.api.getMobileOutputGuideConfiguration()
            guard shouldApply(client.serverId) else { return }
            mobileOutputGuide = guide
            mobileOutputGuideError = nil
        } catch {
            guard shouldApply(client.serverId, error: error) else { return }
            mobileOutputGuideError = error.localizedDescription
        }
    }

    func setMobileOutputGuide(_ enabled: Bool) async {
        guard let current = mobileOutputGuide,
              let client = await prepareClient(),
              shouldApply(client.serverId) else { return }
        isSavingMobileOutputGuide = true
        defer { if shouldApply(client.serverId) { isSavingMobileOutputGuide = false } }
        do {
            let saved = try await client.api.setMobileOutputGuideConfiguration(
                enabled: enabled,
                baseRevision: current.revision
            )
            guard shouldApply(client.serverId) else { return }
            mobileOutputGuide = saved
            mobileOutputGuideError = nil
        } catch let APIError.codedServer(status, _, code)
            where status == 409 && code == "revision_conflict" {
            await loadMobileOutputGuide(client)
        } catch {
            guard shouldApply(client.serverId, error: error) else { return }
            mobileOutputGuideError = error.localizedDescription
        }
    }

    // MARK: - Update

    func startServerUpdate() async {
        guard let version = info?.update?.latestVersion, !version.isEmpty,
              !updateInFlight else { return }
        let requestedId = serverId
        guard let client = await prepareClient() else {
            guard let requestedId, shouldApply(requestedId) else { return }
            error = "Unable to prepare server transport"
            return
        }
        guard shouldApply(client.serverId) else { return }
        let previousVersion = info?.version
        updateInFlight = true
        updateDidNotReturn = false
        do {
            let started = try await client.api.startServerUpdate(version: version)
            guard shouldApply(client.serverId) else { return }
            if var current = info {
                current.update = started
                info = current
            }
            startUpdatePolling(client: client, previousVersion: previousVersion)
        } catch {
            guard shouldApply(client.serverId, error: error) else { return }
            self.error = error.localizedDescription
            updateInFlight = false
        }
    }

    /// Polls `/server/info` until the update settles. The task holds the model
    /// weakly and re-checks the host after every await, so it ends with the
    /// view or a host switch instead of polling a server nobody is looking at.
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
                guard !Task.isCancelled, self?.shouldApply(serverId) == true else { return }
                do {
                    var next = try await api.serverInfo()
                    guard !Task.isCancelled, let self, shouldApply(serverId) else { return }
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
            guard !Task.isCancelled, let self, shouldApply(serverId) else { return }
            updateDidNotReturn = true
            finishUpdatePolling()
        }
    }

    private func finishUpdatePolling() {
        updateInFlight = false
        updatePollTask = nil
    }

    // MARK: - Transport

    /// Whether a result requested for `requestedId` may still be shown.
    private func shouldApply(_ requestedId: String, error: Error? = nil) -> Bool {
        ServerSelection.shouldApplyHostResult(
            requestedId: requestedId,
            visibleId: serverId,
            error: error
        )
    }

    private func noteServerVersionAfterUpdate(_ version: String, serverId: String) {
        coordinator?.connection(for: serverId)?.noteServerVersionAfterUpdate(version)
    }

    /// Reads the id before awaiting so the client and its id always agree.
    private func prepareClient() async -> Client? {
        guard let coordinator, let serverId else { return nil }
        guard let api = await coordinator.apiClientReady(for: serverId) else { return nil }
        return Client(api: api, serverId: serverId)
    }
}

#if DEBUG
extension ServerSettingsModel {
    /// Fixture for the screenshot harness: `load()` leaves it untouched and
    /// `attach` keeps it for the same server id, so pages render without a server.
    static func screenshotFixture(
        serverId: String,
        currentDeviceId: String,
        updateAvailable: Bool
    ) -> ServerSettingsModel {
        let model = ServerSettingsModel()
        model.isFixture = true
        model.serverId = serverId
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
                : nil
        )
        model.isLoading = false
        model.providerSetupState = .configured
        model.connectedProviderCount = 2
        model.mobileOutputGuide = MobileOutputGuideConfiguration(enabled: true, revision: 3)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        model.pairedDevices = [
            AuthDevice(id: currentDeviceId, name: "Chen's iPhone", scope: "device", createdAt: now - 9 * 86_400_000, lastUsedAt: now, revokedAt: nil, keyEnrolled: true),
            AuthDevice(id: "dev-ipad", name: "Chen's iPad", scope: "device", createdAt: now - 30 * 86_400_000, lastUsedAt: now - 3 * 3_600_000, revokedAt: nil, keyEnrolled: true),
            AuthDevice(id: "dev-script", name: "oppi CLI", scope: "device", createdAt: now - 60 * 86_400_000, lastUsedAt: nil, revokedAt: nil, keyEnrolled: false),
        ]
        return model
    }
}
#endif
