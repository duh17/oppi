import Foundation

/// Generation is the lock for invite overlay pairing. A new invite cancels the
/// previous task and must run even if the previous attempt's in-flight flag is
/// still set.
struct InvitePairingGate {
    private(set) var generation: UInt64 = 0
    private(set) var inFlight = false

    mutating func beginIncoming() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        inFlight = false
    }

    func shouldRun(_ attempt: UInt64) -> Bool {
        attempt == generation
    }

    mutating func markStarted(_ attempt: UInt64) {
        guard shouldRun(attempt) else { return }
        inFlight = true
    }

    mutating func markFinished(_ attempt: UInt64) {
        guard shouldRun(attempt) else { return }
        inFlight = false
    }
}

// Pairing from an invite link. An invite keeps its own generation: pairing is
// a long modal wait, and a session tap must not cancel it. Other opens park
// while it runs and drain when it finishes.
extension AppOpener {
    func cancelInvitePairing() {
        invitePairingGate.cancel()
        invitePairingTask?.cancel()
        invitePairingTask = nil
        invitePairingWaitExpiresAt = nil
    }

    /// The launch invite is launch: it runs in place instead of waiting for
    /// launch to finish.
    func runInviteForLaunch(_ url: URL) async {
        invitePairingTask?.cancel()
        let attempt = invitePairingGate.beginIncoming()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runInviteBootstrap(url, attempt: attempt)
        }
        invitePairingTask = task
        await task.value
    }

    func startInvite(_ url: URL, generation: UInt64) {
        guard generation == self.generation else { return }
        invitePairingTask?.cancel()
        let attempt = invitePairingGate.beginIncoming()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runInviteBootstrap(url, attempt: attempt)
        }
        invitePairingTask = task
    }

    func runInviteBootstrap(_ url: URL, attempt: UInt64) async {
        // An invite that cold-launched the app arrives before launch has read
        // the pairing list; enrolling against an unread store would fail.
        await awaitPairedServers()
#if DEBUG
        // The E2E launch passes its invite both through the environment and,
        // on a relaunch, as a URL. Pair once per process.
        guard Self.claimE2ELaunchInvite(url) else { return }
#endif
        guard invitePairingGate.shouldRun(attempt) else { return }
        guard let credentials = ServerCredentials.decodeInviteURL(url) else {
            if InAppInviteLink.claims(url) {
                toast("Unsupported invite link format")
            }
            return
        }
        invitePairingGate.markStarted(attempt)
        defer {
            invitePairingGate.markFinished(attempt)
            if invitePairingGate.shouldRun(attempt) {
                invitePairingWaitExpiresAt = nil
            }
            // A session or workspace request that arrived during pairing is
            // still parked; it opens now.
            drainParkedIfPossible()
        }
#if DEBUG
        let isE2EInviteLaunch = ProcessInfo.processInfo.environment["PI_E2E_INVITE_URL"] != nil
            || ProcessInfo.processInfo.environment["OPPI_E2E_LAUNCH_INVITE"] != nil
#endif
        do {
            let enrollment: InviteEnrollment
#if DEBUG
            if isE2EInviteLaunch {
                enrollment = try await E2EAppAuthBootstrap.enroll(
                    credentials: credentials,
                    serverStore: serverStore,
                    coordinator: coordinator
                )
            } else {
                enrollment = try await enrollInvite(credentials, attempt: attempt)
            }
#else
            enrollment = try await enrollInvite(credentials, attempt: attempt)
#endif
            // A newer invite only takes over the UI; this pairing is saved.
            guard invitePairingGate.shouldRun(attempt), !Task.isCancelled else { return }
            // A newer selection owns the active connection; pairing still succeeded.
            guard enrollment.selected else { return }

            // Reset the newly selected connection. The environment connection
            // can still point at the previous server during deep-link handling.
            let selectedConnection = coordinator.activeConnection
            selectedConnection.disconnectSession()
            selectedConnection.sessionStore.sessions.removeAll()
            selectedConnection.sessionStore.activeSessionId = nil

            selectedConnection.sessionStore.markSyncStarted()
            selectedConnection.sessionStore.applyServerSnapshot(enrollment.sessions, preserveRecentWindow: 0)
            selectedConnection.sessionStore.markSyncSucceeded()
            selectedConnection.syncLiveActivityState()
            navigation.showOnboarding = false
            // The reset clears focus under any on-screen chat; landing on the
            // inbox dismisses it, so its claim release is a no-op and the
            // re-synced list shows.
            navigation.showAllWorkspaceSessions()
            if let api = selectedConnection.apiClient {
                MetricKitService.shared.setUploadClient(api)
                await selectedConnection.refreshWorkspaceCatalog(force: true)
            }
#if DEBUG
            if !isE2EInviteLaunch {
                selectedConnection.extensionToast = "Connected to \(enrollment.name)"
            }
#else
            selectedConnection.extensionToast = "Connected to \(enrollment.name)"
#endif
        } catch is CancellationError {
            guard invitePairingGate.shouldRun(attempt) else { return }
            activeConnection.sessionStore.markSyncFailed()
        } catch {
            guard invitePairingGate.shouldRun(attempt) else { return }
            activeConnection.sessionStore.markSyncFailed()
#if DEBUG
            if isE2EInviteLaunch, !serverStore.servers.isEmpty {
                navigation.showOnboarding = false
                navigation.launchPhase = .ready
                return
            }
#endif
            if AppLaunchPairingPolicy.route(
                loadState: serverStore.loadState,
                pairedServerCount: serverStore.servers.count
            ) == .onboarding {
                navigation.showOnboarding = true
            }
            toast("Invite link failed: \(error.localizedDescription)")
        }
    }

    func enrollInvite(
        _ credentials: ServerCredentials,
        attempt: UInt64
    ) async throws -> InviteEnrollment {
        try await InviteBootstrapService.enroll(
            credentials: credentials,
            serverStore: serverStore,
            coordinator: coordinator,
            onWaitingForApproval: { [self] expiresAt in
                guard invitePairingGate.shouldRun(attempt) else { return }
                invitePairingWaitExpiresAt = expiresAt
            },
            confirmTrust: { reason in
                await BiometricService.shared.authenticate(reason: reason)
            }
        )
    }
}

/// True only for invite-shaped connect/pair routes (host or path form).
/// Failed leftover `oppi://` URLs must not use the invite-format toast.
enum InAppInviteLink {
    static func claims(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "oppi" else { return false }
        let route = url.host?.lowercased()
            ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return route == "connect" || route == "pair"
    }
}
