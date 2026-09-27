import SwiftUI
import UIKit

/// Detail view for a paired oppi server.
///
/// Shows server metadata, stats, security info, and management actions.
/// Data is fetched on-demand from `GET /server/info`.
enum ServerDetailPresentation {
    case details
    case modelProviders
}

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

/// Opens Model Providers for the same visible host `ServerDetailView` shows.
///
/// Active host wins (`ServerSelection.resolveVisible`); frozen id is fallback.
@MainActor
enum ServerDetailModelProvidersNavigation {
    static func visibleServer(
        activeServerId: String?,
        frozenServer: PairedServer,
        servers: [PairedServer]
    ) -> PairedServer {
        ServerSelection.resolveVisible(
            activeId: activeServerId,
            frozenId: frozenServer.id,
            from: servers
        ) ?? servers.first { $0.id == frozenServer.id } ?? frozenServer
    }

    static func open(
        navigation: AppNavigation,
        activeServerId: String?,
        frozenServer: PairedServer,
        servers: [PairedServer]
    ) {
        let visible = visibleServer(
            activeServerId: activeServerId,
            frozenServer: frozenServer,
            servers: servers
        )
        navigation.openModelProviders(ModelProvidersNavTarget(serverId: visible.id))
    }
}

/// Settings drill-in for this server's model providers.
///
/// Keeps setup/status words and color, and uses a standard disclosure
/// indicator on the whole row so it does not read as a passive Status value.
struct ServerModelProvidersNavigationRow: View {
    let summary: String
    let summaryStyle: ThemeShapeStyle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(HostSwitcherDestination.modelProviders.menuTitle)
                    .foregroundStyle(.themeFg)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(summaryStyle)
                    .lineLimit(1)
                    .layoutPriority(0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.themeComment)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("server.modelProviders.open")
        .accessibilityLabel(HostSwitcherDestination.modelProviders.menuTitle)
        .accessibilityValue(summary)
    }
}

/// Provider sign-in calls for one flow. `APIClient` conforms; tests use a fake.
protocol ProviderAuthFlowClient: Sendable {
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot
    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot
    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot
    func cancelProviderAuthFlow(flowId: String, reason: String?) async throws -> ProviderAuthFlowSnapshot
}

extension APIClient: ProviderAuthFlowClient {}

enum ProviderAuthFlowPresentation {
    static func statusText(_ status: ProviderAuthFlowSnapshot.Status) -> String {
        switch status {
        case .pending: "Starting…"
        case .awaitingExternal: "Waiting for sign-in to finish"
        case .awaitingPrompt: "Needs your answer"
        case .awaitingManualCode: "Waiting for the authorization code"
        case .completed: "Signed in"
        case .failed: "Sign-in failed"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        }
    }

    /// Only https, or http on loopback, may be opened. Mirrors the server check.
    static func signInURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" { return url.host?.isEmpty == false ? url : nil }
        guard scheme == "http", let host = url.host?.lowercased() else { return nil }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) ? url : nil
    }
}

/// One provider sign-in attempt, bound to the server client that started it.
///
/// Every follow-up call (poll, prompt, manual code, cancel) uses `client`, so a
/// later active-server change cannot send a pasted code to a different server.
/// Dismissing the sheet only stops showing the attempt; only `cancel` ends it.
@MainActor @Observable
final class ProviderAuthFlowAttempt {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    static let pollInterval: Duration = .milliseconds(1200)
    static let maxRetryDelay: Duration = .seconds(15)

    let serverId: String
    let serverName: String
    let providerName: String
    private let client: any ProviderAuthFlowClient
    private let sleep: Sleep

    private(set) var flow: ProviderAuthFlowSnapshot
    /// The server no longer knows this flow (404); nothing is left to poll or cancel.
    private(set) var isGone = false
    private(set) var isCancelling = false
    private(set) var isSubmitting = false
    /// Last failed poll. Polling keeps retrying; cleared by the next good read.
    private(set) var refreshError: String?
    var input = ""
    var actionError: String?

    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0

    init(
        flow: ProviderAuthFlowSnapshot,
        client: any ProviderAuthFlowClient,
        serverId: String,
        serverName: String,
        providerName: String,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.flow = flow
        self.client = client
        self.serverId = serverId
        self.serverName = serverName
        self.providerName = providerName
        self.sleep = sleep
    }

    /// Terminal on the server, or gone from it.
    var isSettled: Bool { isGone || flow.status.isTerminal }
    var isPolling: Bool { pollTask != nil }

    static func retryDelay(afterFailures failures: Int) -> Duration {
        let scaled = pollInterval * (1 << min(max(failures, 0), 6))
        return min(scaled, maxRetryDelay)
    }

    /// Starts or restarts polling. Any earlier poll's late result is ignored.
    func startPolling() {
        stopPolling()
        guard !isSettled else { return }

        let generation = pollGeneration
        let flowId = flow.flowId
        let client = client
        let sleep = sleep
        pollTask = Task {
            var failures = 0
            while !Task.isCancelled {
                do {
                    let snapshot = try await client.getProviderAuthFlow(flowId: flowId)
                    guard generation == self.pollGeneration else { return }
                    failures = 0
                    self.refreshError = nil
                    self.apply(snapshot)
                } catch {
                    guard generation == self.pollGeneration else { return }
                    if Self.isNotFound(error) {
                        self.isGone = true
                    } else {
                        failures += 1
                        self.refreshError = "Could not refresh sign-in status: \(error.localizedDescription). Retrying…"
                    }
                }
                if self.isSettled { break }
                try? await sleep(failures == 0 ? Self.pollInterval : Self.retryDelay(afterFailures: failures))
            }
            // A newer poll may already own the handle; only clear our own.
            if generation == self.pollGeneration {
                self.pollTask = nil
            }
        }
    }

    func stopPolling() {
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }

    /// The sheet closed without Cancel Login. Never cancels the server flow.
    /// Returns whether to keep the attempt reachable: true while it is still live.
    func sheetDismissed() -> Bool {
        guard isSettled else { return true }
        stopPolling()
        return false
    }

    func submitPromptResponse(_ value: String) async {
        guard flow.status == .awaitingPrompt, !isSubmitting, !isCancelling else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let snapshot = try await client.submitProviderAuthPromptResponse(flowId: flow.flowId, value: value)
            apply(snapshot)
            input = ""
            actionError = nil
        } catch {
            actionError = "Failed to submit response: \(error.localizedDescription)"
        }
    }

    func submitManualCode() async {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard flow.status == .awaitingManualCode, !code.isEmpty, !isSubmitting, !isCancelling else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let snapshot = try await client.submitProviderAuthManualCode(flowId: flow.flowId, input: code)
            apply(snapshot)
            input = ""
            actionError = nil
        } catch {
            actionError = "Failed to submit code: \(error.localizedDescription)"
        }
    }

    /// Returns true once the server acknowledged the cancel, or no longer has the flow.
    /// On failure the attempt stays live and `actionError` explains why.
    func cancel(reason: String) async -> Bool {
        guard !isSettled else { return true }
        guard !isCancelling else { return false }
        isCancelling = true
        actionError = nil
        defer { isCancelling = false }
        do {
            let snapshot = try await client.cancelProviderAuthFlow(flowId: flow.flowId, reason: reason)
            stopPolling()
            // The cancel reply is the server's latest word (it may say `completed`).
            if snapshot.flowId == flow.flowId { flow = snapshot }
            return true
        } catch {
            if Self.isNotFound(error) {
                stopPolling()
                isGone = true
                return true
            }
            actionError = "Failed to cancel login: \(error.localizedDescription)"
            return false
        }
    }

    /// Applies a server snapshot for this flow unless it is older than what is shown
    /// or the flow already settled.
    private func apply(_ snapshot: ProviderAuthFlowSnapshot) {
        guard snapshot.flowId == flow.flowId,
              !flow.status.isTerminal,
              snapshot.updatedAt >= flow.updatedAt else { return }
        flow = snapshot
    }

    private static func isNotFound(_ error: Error) -> Bool {
        switch error as? APIError {
        case .server(let status, _), .codedServer(let status, _, _):
            status == 404
        default:
            false
        }
    }
}

struct ServerDetailView: View {
    let server: PairedServer
    var presentation: ServerDetailPresentation = .details

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var info: ServerInfo?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showRemoveConfirmation = false
    @State private var mobileOutputGuide: MobileOutputGuideConfiguration?
    @State private var isLoadingMobileOutputGuide = false
    @State private var isSavingMobileOutputGuide = false
    @State private var mobileOutputGuideError: String?

    @State private var providerStatuses: [ProviderAuthProviderStatus] = []
    @State private var providerSetupState: ProviderSetupState = .unknown
    @State private var providerQuotas: ProviderQuotasInfo?
    @State private var isLoadingProviders = false
    @State private var providerError: String?
    @State private var providerActionInFlightId: String?

    /// Retained after the sheet is dismissed so a live login stays reachable.
    @State private var flowAttempt: ProviderAuthFlowAttempt?
    @State private var isFlowSheetPresented = false
    @State private var signInChoiceProvider: ProviderAuthProviderStatus?

    @State private var apiKeyEditorProvider: ProviderAuthProviderStatus?
    @State private var apiKeyDraft = ""
    @State private var showAddServer = false
    @State private var showUpdateConfirmation = false
    @State private var updateInFlight = false
    @State private var updateDidNotReturn = false
    @State private var copiedManualCommand = false
    @State private var updatePollTask: Task<Void, Never>?

    private var pairedServer: PairedServer {
        ServerDetailModelProvidersNavigation.visibleServer(
            activeServerId: coordinator.activeServerId,
            frozenServer: server,
            servers: serverStore.servers
        )
    }

    private var hostSwitcherDestination: HostSwitcherDestination {
        presentation == .modelProviders ? .modelProviders : .serverSettings
    }

    var body: some View {
        List {
            if presentation == .modelProviders {
                providerManagementSections
            } else {
                serverSettingsSections
            }
        }
        .iPadReadableContent(maxWidth: IPadReadableContentWidth.detail)
        .themedListSurface()
        .accessibilityIdentifier(
            presentation == .modelProviders ? "server.modelProviders.list" : "server.details.list"
        )
        .navigationTitle(
            presentation == .modelProviders
                ? HostSwitcherDestination.modelProviders.title
                : HostSwitcherDestination.serverSettings.title
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HostSwitcherMenu(current: pairedServer, destination: hostSwitcherDestination)
            }
        }
        .refreshable {
            if presentation == .modelProviders {
                await loadProviderConfiguration()
            } else {
                await load()
            }
        }
        .task(id: pairedServer.id) {
            if presentation == .modelProviders {
                // Host-local state resets on a host switch. A live `flowAttempt`
                // stays: it is bound to its own server's client and keeps polling.
                providerStatuses = []
                providerSetupState = .unknown
                providerQuotas = nil
                providerError = nil
                apiKeyEditorProvider = nil
                apiKeyDraft = ""
                signInChoiceProvider = nil
                await loadProviderConfiguration()
            } else {
                info = nil
                error = nil
                isLoading = true
                mobileOutputGuide = nil
                mobileOutputGuideError = nil
                await load()
            }
        }
        .sheet(isPresented: $showAddServer) {
            OnboardingView(mode: .addServer)
        }
        .onAppear {
            resumeFlowPollingIfLive()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                resumeFlowPollingIfLive()
            }
        }
        .onChange(of: flowAttempt?.isSettled) { _, settled in
            if settled == true {
                reloadProvidersAfterSignIn()
            }
        }
        .onDisappear {
            flowAttempt?.stopPolling()
            updatePollTask?.cancel()
            updatePollTask = nil
        }
        .confirmationDialog(
            removeDialogTitle,
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(removeDialogButtonTitle, role: .destructive) {
                removeServer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeDialogMessage)
        }
        .confirmationDialog(
            updateConfirmationTitle,
            isPresented: $showUpdateConfirmation,
            titleVisibility: .visible
        ) {
            Button("Update") {
                Task { await startServerUpdate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ServerUpdatePresentation.confirmationMessage)
        }
        .confirmationDialog(
            signInChoiceTitle,
            isPresented: Binding(
                get: { signInChoiceProvider != nil },
                set: { if !$0 { signInChoiceProvider = nil } }
            ),
            titleVisibility: .visible,
            presenting: signInChoiceProvider
        ) { provider in
            Button("On this iPhone") {
                startProviderFlow(provider: provider, launchMode: .phoneBrowser)
            }
            .keyboardShortcut(.defaultAction)
            Button("On server") {
                startProviderFlow(provider: provider, launchMode: .serverBrowser)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Choose where the sign-in page opens. On server opens a browser on the server's own desktop.")
        }
        .sheet(isPresented: $isFlowSheetPresented, onDismiss: handleFlowSheetDismissed) {
            providerFlowSheet
        }
        .sheet(item: $apiKeyEditorProvider) { provider in
            apiKeyEditorSheet(provider: provider)
        }
    }

    @ViewBuilder
    private var providerManagementSections: some View {
        if let attempt = flowAttempt, !isFlowSheetPresented {
            Section {
                Button {
                    isFlowSheetPresented = true
                } label: {
                    HStack(spacing: 12) {
                        ProviderIcon(provider: attempt.flow.providerId, size: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sign in to \(attempt.providerName)")
                                .foregroundStyle(.themeFg)
                            Text(flowAttemptSummary(attempt))
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                        Spacer(minLength: 8)
                        Text(attempt.isSettled ? "View" : "Return")
                            .font(.subheadline)
                            .foregroundStyle(.tint)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("server.modelProviders.signInAttempt")
            }
        }

        if providerPresentation.showsLoading {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Loading providers…")
                    Spacer()
                }
            }
        } else if providerPresentation.showsProviderSections {
            Section("Connected") {
                if connectedProviders.isEmpty {
                    providerOnboardingCard
                } else {
                    ForEach(connectedProviders) { provider in
                        providerManagerRow(provider, quota: providerQuota(for: provider))
                    }
                }
            }

            Section("Available") {
                if availableProviders.isEmpty {
                    Text("All providers are currently connected")
                        .foregroundStyle(.themeComment)
                } else {
                    ForEach(availableProviders) { provider in
                        providerManagerRow(provider, quota: nil)
                    }
                }
            }
        }

        if let providerError {
            Section {
                Text(providerError)
                    .foregroundStyle(.themeRed)
            }
        }
    }

    private var providerPresentation: ProviderConfigurationPresentation {
        ProviderConfigurationPresentation(state: providerSetupState)
    }

    private var providerConfigurationSummary: String {
        providerPresentation.summary(connectedCount: connectedProviders.count)
    }

    private var providerConfigurationSummaryStyle: ThemeShapeStyle {
        providerSetupState == .needsConfiguration ? .themeOrange : .themeComment
    }

    @ViewBuilder
    private var serverSettingsSections: some View {
        Section {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let error, info == nil {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.themeOrange)
                    .font(.footnote)
            }

            LabeledContent("Connection", value: connectionStatusTitle)
            if let info {
                LabeledContent("Uptime", value: info.uptimeLabel)
                LabeledContent("Pi SDK", value: info.piVersion)
                if let piCliVersion = info.piCliVersion, !piCliVersion.isEmpty {
                    LabeledContent("Pi TUI", value: piCliVersion)
                }
                LabeledContent("Server", value: info.version)
            }
        } header: {
            Text("Status")
        } footer: {
            Text("Pi SDK is the embedded Pi coding-agent package that runs Oppi sessions. Pi TUI is the installed pi CLI on this host.")
        }

        if info != nil {
            serverUpdateSection
        }

        Section {
            ServerModelProvidersNavigationRow(
                summary: providerConfigurationSummary,
                summaryStyle: providerConfigurationSummaryStyle
            ) {
                ServerDetailModelProvidersNavigation.open(
                    navigation: navigation,
                    activeServerId: coordinator.activeServerId,
                    frozenServer: server,
                    servers: serverStore.servers
                )
            }
        }

        Section {
            NavigationLink {
                WorkspaceListView(server: pairedServer)
            } label: {
                Label("Manage Workspaces", systemImage: "square.grid.2x2")
            }
            .accessibilityIdentifier("server.manageWorkspaces")
        } header: {
            Text("Workspaces")
        }

        Section {
            NavigationLink {
                DictationDictionaryView(workspaceId: nil)
            } label: {
                Label("Dictation Dictionary", systemImage: "text.book.closed")
            }
            .accessibilityIdentifier("server.dictationDictionary")
        } header: {
            Text("Dictation")
        } footer: {
            Text("Edit All Workspaces jargon for this paired server. Workspace-specific phrases are in workspace settings.")
        }

        Section {
            mobileOutputGuideRow
        } footer: {
            Text("Appends Oppi's link and rich-content rendering guide to new and explicitly reloaded managed Pi sessions, including Pi Control. Terminal-owned Mirror sessions are unchanged.")
        }

        Section {
            HStack {
                Text("Preview")
                Spacer()
                RuntimeBadge(
                    compact: false,
                    icon: pairedServer.resolvedBadgeIcon,
                    tint: badgePreviewConnectionState.tintColor
                )
            }

            BadgeIconGrid(selection: badgeIconSelection, tint: .themeBlue)
        } header: {
            Text("Badge")
        } footer: {
            Text("Badge color reflects connection status: green connected, blue connecting, red disconnected.")
        }

        Section {
            Button {
                showAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
            .accessibilityIdentifier("server.addServer")

            Button(role: .destructive) {
                showRemoveConfirmation = true
            } label: {
                Label("Remove Server", systemImage: "trash")
            }
        } footer: {
            Text("This only removes pairing from this iPhone. It does not delete the server or its data.")
        }
    }

    private var updateConfirmationTitle: String {
        let version = info?.update?.latestVersion ?? info?.update?.targetVersion ?? "the latest version"
        return ServerUpdatePresentation.confirmationTitle(version: version)
    }

    @ViewBuilder
    private var serverUpdateSection: some View {
        let update = info?.update
        let belowMinimum = ServerReleaseVersion.isBelowMinimum(info?.version)
        if belowMinimum || update?.available == true || update?.isInstalling == true
            || update?.isRestarting == true || update?.isRestartNeeded == true
            || update?.isFailed == true || updateInFlight || updateDidNotReturn
            || (update != nil && update?.isAppUpdatable == false) {
        Section {
            if updateDidNotReturn {
                Label("Server did not come back. Nothing was rolled back — check the host.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.themeOrange)
                    .accessibilityIdentifier("server.update.didNotReturn")
            } else if let update {
                if update.isInstalling || update.isRestarting || updateInFlight {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            ServerUpdatePresentation.progressLabel(
                                status: update.status,
                                restartMode: update.restartMode
                            )
                        )
                    }
                    .accessibilityIdentifier("server.update.progress")
                } else if update.isRestartNeeded {
                    Label("Installed. Restart this Oppi server on the host to use the new version.",
                          systemImage: "arrow.clockwise")
                        .accessibilityIdentifier("server.update.restartNeeded")
                } else if update.isFailed, let message = update.error, !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.themeOrange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("server.update.error")
                }

                if update.available, update.isAppUpdatable, !update.isInstalling,
                   !update.isRestarting, !update.isRestartNeeded, !updateDidNotReturn {
                    if let latest = update.latestVersion {
                        Text(ServerUpdatePresentation.availableTitle(latestVersion: latest))
                            .accessibilityIdentifier("server.update.available")
                    }
                    Button("Update") {
                        showUpdateConfirmation = true
                    }
                    .disabled(updateInFlight)
                    .accessibilityIdentifier("server.update.button")
                } else if !update.isAppUpdatable {
                    Text(update.manualCommand)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("server.update.manualCommand")
                    Button(copiedManualCommand ? "Copied" : "Copy Command") {
                        UIPasteboard.general.string = update.manualCommand
                        copiedManualCommand = true
                    }
                    .accessibilityIdentifier("server.update.manualCopy")
                }
            } else if belowMinimum {
                Text(ServerUpdatePresentation.minimumVersionNoticeTitle)
                    .accessibilityIdentifier("server.update.available")
                Text(ServerUpdatePresentation.fallbackManualCommand)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("server.update.manualCommand")
                Button(copiedManualCommand ? "Copied" : "Copy Command") {
                    UIPasteboard.general.string = ServerUpdatePresentation.fallbackManualCommand
                    copiedManualCommand = true
                }
                .accessibilityIdentifier("server.update.manualCopy")
            }
        } header: {
            Text("Update")
        } footer: {
            if update?.isAppUpdatable == true {
                Text("Updating installs a new oppi-server from npm and restarts this host. Running sessions are interrupted.")
            } else {
                Text("This install cannot be updated from the app. Run the command on the host, then restart the server.")
            }
        }
        }
    }

    private var connectionStatusTitle: String {
        let state = HostSwitcherBadgeState.make(for: pairedServer, coordinator: coordinator)
        return ServerConnectionLanePresentation.title(
            server: pairedServer,
            connection: coordinator.connection(for: pairedServer.id),
            state: state,
            isPreparing: coordinator.preparingServerIds.contains(pairedServer.id)
        )
    }

    @ViewBuilder
    private var mobileOutputGuideRow: some View {
        switch ServerDetailMobileOutputGuideState.resolve(
            configuration: mobileOutputGuide,
            isLoading: isLoadingMobileOutputGuide,
            error: mobileOutputGuideError
        ) {
        case .loading:
            HStack {
                Text("Mobile Output Guide")
                Spacer()
                ProgressView()
                    .controlSize(.small)
            }
            .accessibilityIdentifier("server.mobileOutputGuide.loading")
        case .available(let enabled, _, let error):
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "Mobile Output Guide",
                    isOn: Binding(
                        get: { enabled },
                        set: { newValue in
                            Task { await setMobileOutputGuide(newValue) }
                        }
                    )
                )
                .disabled(isSavingMobileOutputGuide)
                .accessibilityIdentifier("server.mobileOutputGuide.enabled")
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.themeOrange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("server.mobileOutputGuide.error")
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Mobile Output Guide")
                    Spacer()
                    Text("Unavailable")
                        .foregroundStyle(.themeOrange)
                }
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.themeOrange)
                Button("Retry") {
                    Task {
                        guard let api = await prepareAPIClient() else { return }
                        await loadMobileOutputGuide(api: api)
                    }
                }
            }
            .accessibilityIdentifier("server.mobileOutputGuide.error")
        }
    }

    private func providerQuota(for provider: ProviderAuthProviderStatus) -> ProviderQuota? {
        guard let quota = providerQuotas?.quota(forProviderId: provider.id),
              quota.hasAnyUsageWindow || quota.error != nil || quota.planLabel != nil
        else { return nil }
        return quota
    }

    private var badgeIconSelection: Binding<ServerBadgeIcon> {
        Binding(
            get: { pairedServer.resolvedBadgeIcon },
            set: { serverStore.setBadgeIcon(id: pairedServer.id, to: $0) }
        )
    }

    private var badgePreviewConnectionState: ServerBadgeConnectionState {
        if info != nil || !providerStatuses.isEmpty || providerQuotas != nil {
            return .connected
        }
        if isLoading || isLoadingProviders {
            return .connecting
        }
        return .disconnected
    }

    private var removingLastServer: Bool {
        serverStore.servers.count == 1 && serverStore.servers.first?.id == pairedServer.id
    }

    private var removeDialogTitle: String {
        if removingLastServer {
            return "Remove only paired server?"
        }
        return "Remove \(pairedServer.name)?"
    }

    private var removeDialogButtonTitle: String {
        removingLastServer ? "Remove Last Server" : "Remove Server"
    }

    private var removeDialogMessage: String {
        if removingLastServer {
            return "This is the only paired server on this device. Removing it will disconnect Oppi and return you to onboarding. You'll need to pair again before using the app."
        }
        return "This removes the server from this iPhone only. It does not delete anything on the server, and you can pair it again later."
    }

    private var connectedProviders: [ProviderAuthProviderStatus] {
        providerStatuses
            .filter(\.authenticated)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var availableProviders: [ProviderAuthProviderStatus] {
        providerStatuses
            .filter { !$0.authenticated }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder
    private var providerOnboardingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect a model provider", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.themeFg)

            Text("Finish setup by signing in or adding an API key. This unlocks model selection for sessions on this server.")
                .font(.footnote)
                .foregroundStyle(.themeComment)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func providerManagerRow(
        _ provider: ProviderAuthProviderStatus,
        quota: ProviderQuota?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIcon(provider: provider.id, size: 16)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                    Text(providerStatusText(provider))
                        .font(.caption)
                        .foregroundStyle(providerStatusColor(provider))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if providerActionInFlightId == provider.id {
                    ProgressView()
                        .controlSize(.small)
                } else if provider.authenticated {
                    providerManageMenu(provider)
                } else {
                    providerConnectButtons(provider)
                }
            }

            if let quota {
                ProviderQuotaDetails(quota: quota, providerName: provider.name)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func providerConnectButtons(
        _ provider: ProviderAuthProviderStatus
    ) -> some View {
        if provider.oauth != nil, provider.supportsApiKey {
            Menu {
                Button(provider.authenticated ? "Reauthenticate" : "Sign In") {
                    startProviderOAuthAction(provider: provider)
                }
                .disabled(hasLiveSignIn)

                Button(apiKeyButtonTitle(provider)) {
                    startProviderAPIKeyAction(provider: provider)
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Connect")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline)
            .disabled(providerActionInFlightId != nil)
        } else if provider.oauth != nil {
            Button(provider.authenticated ? "Reauthenticate" : "Sign In") {
                startProviderOAuthAction(provider: provider)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline)
            .disabled(providerActionInFlightId != nil || hasLiveSignIn)
        } else if provider.supportsApiKey {
            Button(apiKeyButtonTitle(provider)) {
                startProviderAPIKeyAction(provider: provider)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.subheadline)
            .disabled(providerActionInFlightId != nil)
        }
    }

    /// Asks where the sign-in page should open before any flow starts.
    private func startProviderOAuthAction(provider: ProviderAuthProviderStatus) {
        DispatchQueue.main.async {
            signInChoiceProvider = provider
        }
    }

    /// One sign-in at a time, so a live attempt is never replaced out of sight.
    private var hasLiveSignIn: Bool {
        flowAttempt.map { !$0.isSettled } ?? false
    }

    private var signInChoiceTitle: String {
        signInChoiceProvider.map { "Sign in to \($0.name)" } ?? "Sign In"
    }

    private func flowAttemptSummary(_ attempt: ProviderAuthFlowAttempt) -> String {
        let status = attempt.isGone
            ? "No longer on the server"
            : ProviderAuthFlowPresentation.statusText(attempt.flow.status)
        return attempt.serverId == pairedServer.id ? status : "\(status) \u{00B7} \(attempt.serverName)"
    }

    private func startProviderAPIKeyAction(
        provider: ProviderAuthProviderStatus
    ) {
        DispatchQueue.main.async {
            beginApiKeyEntry(for: provider)
        }
    }

    @ViewBuilder
    private func providerManageMenu(_ provider: ProviderAuthProviderStatus) -> some View {
        Menu {
            if provider.oauth != nil {
                Button("Reauthenticate") {
                    startProviderOAuthAction(provider: provider)
                }
                .disabled(hasLiveSignIn)
            }

            if provider.supportsApiKey {
                Button(apiKeyButtonTitle(provider)) {
                    DispatchQueue.main.async {
                        beginApiKeyEntry(for: provider)
                    }
                }
            }

            Button("Disconnect", role: .destructive) {
                disconnectProvider(provider)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.themeComment)
        }
    }

    @ViewBuilder
    private var providerFlowSheet: some View {
        NavigationStack {
            List {
                if let attempt = flowAttempt {
                    let flow = attempt.flow
                    let isBusy = attempt.isCancelling || attempt.isSubmitting
                    Section("Provider") {
                        LabeledContent("Provider", value: attempt.providerName)
                        LabeledContent(
                            "Status",
                            value: attempt.isGone
                                ? "No longer on the server"
                                : ProviderAuthFlowPresentation.statusText(flow.status)
                        )
                        if attempt.serverId != pairedServer.id {
                            LabeledContent("Server", value: attempt.serverName)
                        }
                    }

                    if let auth = flow.auth {
                        Section("Sign In") {
                            if let url = ProviderAuthFlowPresentation.signInURL(auth.url) {
                                Link(destination: url) {
                                    Label("Open sign-in page on iPhone", systemImage: "safari")
                                }
                            } else {
                                Text("This sign-in link cannot be opened on iPhone.")
                                    .font(.footnote)
                                    .foregroundStyle(.themeComment)
                            }

                            if let instructions = auth.instructions, !instructions.isEmpty {
                                Text(instructions)
                                    .font(.footnote)
                            }
                        }
                    }

                    if flow.status == .awaitingPrompt, let prompt = flow.prompt {
                        Section(prompt.message) {
                            if let options = prompt.options, !options.isEmpty {
                                ForEach(options) { option in
                                    Button(option.label) {
                                        Task { await attempt.submitPromptResponse(option.id) }
                                    }
                                    .disabled(isBusy)
                                }
                            } else {
                                TextField(prompt.placeholder ?? "Enter response", text: Bindable(attempt).input)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .disabled(isBusy)

                                Button("Submit") {
                                    let value = attempt.input
                                    Task { await attempt.submitPromptResponse(value) }
                                }
                                .disabled(isBusy || (attempt.input.isEmpty && prompt.allowEmpty != true))
                            }
                        }
                    }

                    if flow.status == .awaitingManualCode {
                        Section("Manual Code Input") {
                            TextField("Paste authorization code or redirect URL", text: Bindable(attempt).input)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(isBusy)

                            Button("Submit") {
                                Task { await attempt.submitManualCode() }
                            }
                            .disabled(
                                isBusy ||
                                    attempt.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }

                    if let progress = flow.lastProgress, !progress.isEmpty {
                        Section("Progress") {
                            Text(progress)
                                .font(.footnote)
                        }
                    }

                    if let error = flow.error, !error.isEmpty {
                        Section {
                            Text(error)
                                .foregroundStyle(.themeRed)
                        } header: {
                            Text("Error")
                        }
                    }

                    if attempt.isGone {
                        Section {
                            Text("The server no longer has this sign-in attempt. It may have expired or the server restarted.")
                                .font(.footnote)
                        }
                    }

                    if let refreshError = attempt.refreshError, !attempt.isSettled {
                        Section {
                            Text(refreshError)
                                .font(.footnote)
                                .foregroundStyle(.themeOrange)
                        }
                    }

                    if let actionError = attempt.actionError, !actionError.isEmpty {
                        Section {
                            Text(actionError)
                                .foregroundStyle(.themeRed)
                        }
                    }

                    Section {
                        if attempt.isSettled {
                            Button("Done") {
                                closeFlowSheet()
                            }
                        } else {
                            Button(role: .destructive) {
                                cancelFlowAttempt(attempt)
                            } label: {
                                if attempt.isCancelling {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Cancelling…")
                                    }
                                } else {
                                    Text("Cancel Login")
                                }
                            }
                            .disabled(attempt.isCancelling)
                        }
                    }
                }
            }
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
            .themedListSurface()
            .navigationTitle(flowAttempt.map { "Sign in to \($0.providerName)" } ?? "Provider Sign In")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(flowAttempt?.isCancelling ?? false)
    }

    @ViewBuilder
    private func apiKeyEditorSheet(provider: ProviderAuthProviderStatus) -> some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    HStack(spacing: 12) {
                        ProviderIcon(provider: provider.id, size: 16)
                        Text(provider.name)
                    }
                }

                Section("API Key") {
                    SecureField("Paste API key", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("The key is sent directly to your server over the existing Oppi connection and saved there.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }
            }
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.form)
            .navigationTitle("Set API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        apiKeyEditorProvider = nil
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAPIKey(provider: provider)
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func removeServer() {
        Task { @MainActor in
            await coordinator.removeServer(id: pairedServer.id)

            if serverStore.servers.isEmpty {
                navigation.showOnboarding = true
                return
            }

            dismiss()
        }
    }

    private func startServerUpdate() async {
        guard let version = info?.update?.latestVersion, !version.isEmpty else { return }
        guard let api = await prepareAPIClient() else {
            error = "Unable to prepare server transport"
            return
        }
        let previousVersion = info?.version
        updateInFlight = true
        updateDidNotReturn = false
        do {
            let started = try await api.startServerUpdate(version: version)
            if var current = info {
                current.update = started
                info = current
            }
            await pollUpdateUntilSettled(api: api, previousVersion: previousVersion)
        } catch {
            self.error = error.localizedDescription
            updateInFlight = false
        }
    }

    private func pollUpdateUntilSettled(api: APIClient, previousVersion: String?) async {
        updatePollTask?.cancel()
        let task = Task { @MainActor in
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
                if Task.isCancelled { break }
                do {
                    var next = try await api.serverInfo()
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
                        updateInFlight = false
                        return
                    }
                    if let previousVersion, next.version != previousVersion {
                        coordinator.connection(for: pairedServer.id)?.noteServerVersionAfterUpdate(next.version)
                        updateInFlight = false
                        return
                    }
                    if next.update?.isRestartNeeded == true {
                        updateInFlight = false
                        return
                    }
                    // The host answered idle on the same version: it is serving
                    // normally, so show its real state rather than "did not come back".
                    if reported?.isIdle == true {
                        updateInFlight = false
                        return
                    }
                } catch {
                    // Connection drop during restart is expected.
                    if notSettlingSince == nil { notSettlingSince = Date() }
                }
            }
            if !Task.isCancelled {
                updateDidNotReturn = true
            }
            updateInFlight = false
        }
        updatePollTask = task
        await task.value
    }

    private func load() async {
        guard let api = await prepareAPIClient() else {
            error = "Unable to prepare server transport"
            isLoading = false
            return
        }

        do {
            let previousVersion = info?.version
            let next = try await api.serverInfo()
            info = next
            error = nil
            // The host answered, so a stale "did not come back" no longer applies;
            // its real update status is shown instead.
            if updateDidNotReturn {
                updateDidNotReturn = false
                if let previousVersion, next.version != previousVersion {
                    coordinator.connection(for: pairedServer.id)?.noteServerVersionAfterUpdate(next.version)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }

        async let providers: () = loadProviderConfiguration(api: api)
        async let guide: () = loadMobileOutputGuide(api: api)
        _ = await (providers, guide)
        isLoading = false
    }

    private func prepareAPIClient() async -> APIClient? {
        await coordinator.apiClientReady(for: pairedServer.id)
    }

    private func makeAPIClient() -> APIClient? {
        coordinator.apiClient(for: pairedServer.id)
    }

    private func loadProviderConfiguration(api: APIClient? = nil) async {
        isLoadingProviders = true
        defer { isLoadingProviders = false }

        let client: APIClient
        if let api {
            client = api
        } else if let prepared = await prepareAPIClient() {
            client = prepared
        } else {
            providerSetupState = .unavailable
            providerError = "Unable to prepare server transport"
            return
        }

        async let quotas = loadProviderQuotas(api: client)

        do {
            providerStatuses = try await client.listProviderAuthStatus()
            providerSetupState = ProviderSetupState(providerStatuses: providerStatuses)
            providerError = nil
        } catch {
            providerStatuses = []
            providerSetupState = .unavailable
            providerError = "Failed to load provider status: \(error.localizedDescription)"
        }

        providerQuotas = await quotas
    }

    private func loadMobileOutputGuide(api: APIClient) async {
        isLoadingMobileOutputGuide = mobileOutputGuide == nil
        defer { isLoadingMobileOutputGuide = false }
        do {
            mobileOutputGuide = try await api.getMobileOutputGuideConfiguration()
            mobileOutputGuideError = nil
        } catch {
            mobileOutputGuideError = error.localizedDescription
        }
    }

    private func setMobileOutputGuide(_ enabled: Bool) async {
        guard let current = mobileOutputGuide,
              let api = await prepareAPIClient() else { return }
        isSavingMobileOutputGuide = true
        defer { isSavingMobileOutputGuide = false }
        do {
            mobileOutputGuide = try await api.setMobileOutputGuideConfiguration(
                enabled: enabled,
                baseRevision: current.revision
            )
            mobileOutputGuideError = nil
        } catch let APIError.codedServer(status, _, code)
            where status == 409 && code == "revision_conflict" {
            await loadMobileOutputGuide(api: api)
        } catch {
            mobileOutputGuideError = error.localizedDescription
        }
    }

    private func loadProviderQuotas(api: APIClient) async -> ProviderQuotasInfo? {
        do {
            return try await api.fetchProviderQuotas()
        } catch {
            return nil
        }
    }

    private func providerStatusText(_ provider: ProviderAuthProviderStatus) -> String {
        guard provider.authenticated else { return "Not connected" }

        switch provider.credentialType {
        case .apiKey:
            if let masked = provider.maskedKey {
                return "API key · \(masked)"
            }
            return "API key connected"
        case .oauth:
            if let expiry = provider.expiresAtDate {
                return "OAuth · expires \(expiry.formatted(date: .abbreviated, time: .shortened))"
            }
            return "OAuth connected"
        case .none:
            return "Connected"
        }
    }

    private func providerStatusColor(_ provider: ProviderAuthProviderStatus) -> Color {
        provider.authenticated ? .themeGreen : .themeComment
    }

    private func apiKeyButtonTitle(_ provider: ProviderAuthProviderStatus) -> String {
        if provider.credentialType == .apiKey {
            return "Replace API Key"
        }
        return "Set API Key"
    }

    private func beginApiKeyEntry(for provider: ProviderAuthProviderStatus) {
        apiKeyDraft = ""
        apiKeyEditorProvider = provider
    }

    private func saveAPIKey(provider: ProviderAuthProviderStatus) {
        guard let api = makeAPIClient() else {
            providerError = "Invalid server address"
            return
        }

        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            providerError = "API key cannot be empty"
            return
        }

        providerActionInFlightId = provider.id
        Task {
            do {
                try await api.setProviderAPIKey(providerId: provider.id, key: key)
                providerError = nil
                apiKeyEditorProvider = nil
                apiKeyDraft = ""
                await loadProviderConfiguration(api: api)
            } catch {
                providerError = "Failed to save API key: \(error.localizedDescription)"
            }
            providerActionInFlightId = nil
        }
    }

    private func disconnectProvider(_ provider: ProviderAuthProviderStatus) {
        guard let api = makeAPIClient() else {
            providerError = "Invalid server address"
            return
        }

        providerActionInFlightId = provider.id
        Task {
            do {
                try await api.removeProviderCredential(providerId: provider.id)
                providerError = nil
                await loadProviderConfiguration(api: api)
            } catch {
                providerError = "Failed to remove credential: \(error.localizedDescription)"
            }
            providerActionInFlightId = nil
        }
    }

    private func startProviderFlow(
        provider: ProviderAuthProviderStatus,
        launchMode: ProviderAuthFlowSnapshot.LaunchMode
    ) {
        guard !hasLiveSignIn else { return }
        let server = pairedServer
        guard let api = makeAPIClient() else {
            providerError = "Invalid server address"
            return
        }

        providerActionInFlightId = provider.id
        Task {
            do {
                let flow = try await api.startProviderAuthFlow(
                    providerId: provider.id,
                    launchMode: launchMode
                )
                flowAttempt?.stopPolling()
                let attempt = ProviderAuthFlowAttempt(
                    flow: flow,
                    client: api,
                    serverId: server.id,
                    serverName: server.name,
                    providerName: provider.name
                )
                flowAttempt = attempt
                providerError = nil
                isFlowSheetPresented = true
                attempt.startPolling()
            } catch {
                providerError = "Failed to start login: \(error.localizedDescription)"
            }
            providerActionInFlightId = nil
        }
    }

    private func resumeFlowPollingIfLive() {
        guard let attempt = flowAttempt, !attempt.isSettled else { return }
        attempt.startPolling()
    }

    /// Provider rows reflect the visible server, so only reload when the attempt ran there.
    private func reloadProvidersAfterSignIn() {
        guard let attempt = flowAttempt else { return }
        reloadProviders(ifServerId: attempt.serverId)
    }

    private func reloadProviders(ifServerId serverId: String) {
        guard presentation == .modelProviders, serverId == pairedServer.id else { return }
        Task { await loadProviderConfiguration() }
    }

    /// Cancel Login is the only way to end a live attempt. The sheet closes only after
    /// the server acknowledges; on failure it stays open with the error.
    private func cancelFlowAttempt(_ attempt: ProviderAuthFlowAttempt) {
        Task {
            guard await attempt.cancel(reason: "Cancelled by user") else { return }
            // A login can commit just before the cancel lands; show the real state.
            reloadProviders(ifServerId: attempt.serverId)
            if flowAttempt === attempt {
                closeFlowSheet()
            }
        }
    }

    private func closeFlowSheet() {
        flowAttempt?.stopPolling()
        flowAttempt = nil
        isFlowSheetPresented = false
    }

    /// Dismissing never cancels. A live attempt keeps polling and stays reachable
    /// from the provider list; a settled one is cleared.
    private func handleFlowSheetDismissed() {
        guard let attempt = flowAttempt, !attempt.sheetDismissed() else { return }
        flowAttempt = nil
    }
}

fileprivate struct ProviderQuotaDetails: View {
    let quota: ProviderQuota
    let providerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = quota.planLabel {
                Text(plan)
                    .font(.caption.bold())
                    .foregroundStyle(.themeBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.themeBlue.opacity(0.14), in: Capsule())
                    .accessibilityLabel("\(providerName) plan \(plan)")
                    .accessibilityIdentifier("provider.quota.\(quota.providerId).plan")
            }

            ForEach(quota.detailWindows) { window in
                usageRow(window: window)
            }

            if let error = quota.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(providerName) quota error: \(error)")
            }
        }
    }

    @ViewBuilder
    private func usageRow(window: ProviderQuota.Window) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.themeComment)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(Int(window.remainingPercent.rounded()))% left")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(remainingStyle(window.remainingPercent))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.themeComment.opacity(0.18))
                        .frame(height: 6)

                    Capsule()
                        .fill(remainingStyle(window.remainingPercent))
                        .frame(
                            width: geo.size.width * max(0, min(1, window.remainingPercent / 100)),
                            height: 6
                        )
                }
            }
            .frame(height: 6)

            Text(window.pacing?.compactLabel ?? "Not enough data to calculate")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.themeComment)

            if let resetDate = window.resetDate {
                Text(resetLabel(for: resetDate, window: window))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.themeComment)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(providerName) \(window.title) quota")
        .accessibilityValue(accessibilityValue(for: window))
        .accessibilityIdentifier("provider.quota.\(quota.providerId).\(window.key)")
    }

    private func accessibilityValue(for window: ProviderQuota.Window) -> String {
        let remaining = "\(Int(window.remainingPercent.rounded()))% left"
        let pacing = window.pacing?.accessibilityLabel ?? "Not enough data to calculate"
        guard let resetDate = window.resetDate else { return "\(remaining), \(pacing)" }
        return "\(remaining), \(pacing), \(resetLabel(for: resetDate, window: window))"
    }

    private func remainingStyle(_ remainingPercent: Double) -> ThemeShapeStyle {
        switch ProviderQuota.badgeTone(for: remainingPercent) {
        case .green:
            .themeGreen
        case .orange:
            .themeOrange
        case .red:
            .themeRed
        }
    }

    private func resetLabel(for date: Date, window: ProviderQuota.Window) -> String {
        let secondsUntilReset = date.timeIntervalSinceNow
        let formatted: String = if secondsUntilReset <= 36 * 60 * 60, !window.includeWeekdayInReset {
            // Short windows (e.g. Codex 5h): time-of-day is enough.
            date.formatted(.dateTime.hour().minute())
        } else if secondsUntilReset <= 8 * 24 * 60 * 60 {
            // Within about a week: weekday + time.
            date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        } else {
            // Farther out (monthly): calendar day + time.
            date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return "resets \(formatted)"
    }
}

#if DEBUG
struct ModelProvidersQuotaPreview: View {
    private static let sampleNow = Date()

    private static let codexQuota = ProviderQuota(
        providerId: "openai-codex",
        displayName: "Codex",
        authenticated: true,
        planType: "prolite",
        windows: [
            ProviderQuota.Window(
                key: "five_hour",
                shortLabel: "5h",
                title: "5-hour",
                usedPercent: 28,
                remainingPercent: 72,
                limitWindowSeconds: 18_000,
                resetAt: Int(sampleNow.addingTimeInterval(2 * 60 * 60).timeIntervalSince1970),
                includeWeekdayInReset: false,
                pacing: .init(
                    source: "snapshot",
                    status: "on_pace",
                    timeRemainingSeconds: 7_200,
                    supplyRatio: 1.02,
                    targetBurnPercentPerHour: 36,
                    recentBurnPercentPerHour: nil,
                    paceRatio: nil,
                    projectedExhaustionAt: nil,
                    projectedRemainingPercent: nil
                )
            ),
            ProviderQuota.Window(
                key: "weekly",
                shortLabel: "7d",
                title: "Weekly",
                usedPercent: 44,
                remainingPercent: 56,
                limitWindowSeconds: 604_800,
                resetAt: Int(sampleNow.addingTimeInterval(5 * 24 * 60 * 60).timeIntervalSince1970),
                includeWeekdayInReset: true,
                pacing: .init(
                    source: "snapshot",
                    status: "plenty",
                    timeRemainingSeconds: 432_000,
                    supplyRatio: 1.35,
                    targetBurnPercentPerHour: 4.67,
                    recentBurnPercentPerHour: nil,
                    paceRatio: nil,
                    projectedExhaustionAt: nil,
                    projectedRemainingPercent: nil
                )
            ),
        ],
        credits: nil,
        prepaidBalanceCents: nil,
        fetchedAt: Int(sampleNow.timeIntervalSince1970),
        error: nil
    )

    private static let xaiQuota = ProviderQuota(
        providerId: "xai",
        displayName: "xAI",
        authenticated: true,
        planType: "supergrok",
        windows: [
            ProviderQuota.Window(
                key: "monthly",
                shortLabel: "30d",
                title: "Monthly",
                usedPercent: 61,
                remainingPercent: 39,
                limitWindowSeconds: 2_592_000,
                resetAt: Int(sampleNow.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970),
                includeWeekdayInReset: false,
                pacing: .init(
                    source: "snapshot",
                    status: "conserve",
                    timeRemainingSeconds: 604_800,
                    supplyRatio: 0.58,
                    targetBurnPercentPerHour: 1.93,
                    recentBurnPercentPerHour: nil,
                    paceRatio: nil,
                    projectedExhaustionAt: nil,
                    projectedRemainingPercent: nil
                )
            ),
        ],
        credits: nil,
        prepaidBalanceCents: nil,
        fetchedAt: Int(sampleNow.timeIntervalSince1970),
        error: nil
    )

    var body: some View {
        NavigationStack {
            List {
                Section("Connected") {
                    connectedProviderRow(
                        providerID: "openai-codex",
                        name: "OpenAI Codex",
                        status: "OAuth connected",
                        quota: Self.codexQuota
                    )
                    connectedProviderRow(
                        providerID: "xai",
                        name: "xAI",
                        status: "OAuth connected",
                        quota: Self.xaiQuota
                    )
                    connectedProviderRow(
                        providerID: "deepseek",
                        name: "DeepSeek",
                        status: "API key connected"
                    )
                }

                Section("Available") {
                    HStack(alignment: .top, spacing: 12) {
                        ProviderIcon(provider: "anthropic", size: 16)
                            .padding(.top, 3)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Anthropic")
                            Text("Not connected")
                                .font(.caption)
                                .foregroundStyle(.themeComment)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Connect")
                            .font(.subheadline)
                            .foregroundStyle(.themeBlue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.themeBlue.opacity(0.14), in: Capsule())
                    }
                }
            }
            .iPadReadableContent(maxWidth: IPadReadableContentWidth.detail)
            .themedListSurface()
            .navigationTitle("Model Providers")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.light)
        .accessibilityIdentifier("screenshot.ready")
    }

    @ViewBuilder
    private func connectedProviderRow(
        providerID: String,
        name: String,
        status: String,
        quota: ProviderQuota? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ProviderIcon(provider: providerID, size: 16)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.themeGreen)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.themeComment)
            }

            if let quota {
                ProviderQuotaDetails(quota: quota, providerName: name)
                    .padding(.leading, 28)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Isolated 320pt Server Settings row that uses the production providers row
/// and `ServerDetailModelProvidersNavigation` / `AppNavigation` owner.
///
/// Does not mount `ServerDetailView`: `ServerStore.init()` always loads the
/// Keychain index, so a real settings view would resolve against whatever the
/// pool simulator already has instead of the fixture hosts.
struct ServerProviderNavigationRegressionPreview: View {
    static let proofWidth: CGFloat = 320
    static let sourceServerID = "sha256:source-server"
    static let otherServerID = "sha256:other-server"

    @State private var navigation: AppNavigation

    private let sourceServer: PairedServer
    private let otherServer: PairedServer
    private let servers: [PairedServer]
    private let themeID: ThemeID = .light

    init() {
        ThemeRuntimeState.setThemeID(.light)
        let other = Self.makeServer(id: Self.otherServerID, name: "Other Host", host: "other.local")
        let source = Self.makeServer(id: Self.sourceServerID, name: "Source Host", host: "source.local")
        otherServer = other
        sourceServer = source
        servers = [other, source]
        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showOnboarding = false
        _navigation = State(initialValue: navigation)
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.workspacePath) {
            settingsList
                .navigationTitle(HostSwitcherDestination.serverSettings.title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: ModelProvidersNavTarget.self) { target in
                    openedProviders(target)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ServerSwitcherPill(
                            server: sourceServer,
                            connectionState: .connected
                        )
                        .accessibilityLabel("Current server: \(sourceServer.name)")
                    }
                }
        }
        .preferredColorScheme(.light)
        .environment(\.theme, themeID.appTheme)
        .environment(\.themeID, themeID)
        .accessibilityIdentifier(
            ProcessInfo.processInfo.environment["SCREENSHOT_READY_ID"] ?? "screenshot.ready"
        )
    }

    private var settingsList: some View {
        List {
            Section {
                LabeledContent("Connection", value: "Connected via paired HTTPS")
                LabeledContent("Uptime", value: "2d 4h")
            } header: {
                Text("Status")
            } footer: {
                Text("Also paired: \(otherServer.name)")
                    .accessibilityIdentifier("server.modelProviders.otherServer")
            }

            Section {
                ServerModelProvidersNavigationRow(
                    summary: "Needs setup",
                    summaryStyle: .themeOrange
                ) {
                    ServerDetailModelProvidersNavigation.open(
                        navigation: navigation,
                        activeServerId: sourceServer.id,
                        frozenServer: sourceServer,
                        servers: servers
                    )
                }
            }
        }
        .frame(width: Self.proofWidth)
        .accessibilityIdentifier("server.details.list")
    }

    @ViewBuilder
    private func openedProviders(_ target: ModelProvidersNavTarget) -> some View {
        List {
            LabeledContent("Opened server", value: target.serverId)
                .accessibilityIdentifier("server.modelProviders.openedServerId")
        }
        .navigationTitle(HostSwitcherDestination.modelProviders.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("server.modelProviders.list")
    }

    private static func makeServer(id: String, name: String, host: String) -> PairedServer {
        let credentials = ServerCredentials(
            host: host,
            port: 7749,
            token: "sk_preview",
            name: name,
            serverFingerprint: id
        )
        guard let server = PairedServer(from: credentials, sortOrder: 0) else {
            preconditionFailure("ServerProviderNavigationRegressionPreview requires a server fingerprint")
        }
        return server
    }
}

struct ServerSettingsChromePreview: View {
    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "dark"
            ? .dark
            : .light
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Connection", value: "Connected via paired HTTPS")
                    LabeledContent("Uptime", value: "2d 4h")
                    LabeledContent("Pi SDK", value: "0.85.1")
                    LabeledContent("Pi TUI", value: "0.85.1")
                    LabeledContent("Server", value: "oppi")
                } header: {
                    Text("Status")
                } footer: {
                    Text("Pi SDK is the embedded Pi coding-agent package that runs Oppi sessions. Pi TUI is the installed pi CLI on this host.")
                }

                Section {
                    ServerModelProvidersNavigationRow(
                        summary: "Needs setup",
                        summaryStyle: .themeOrange,
                        action: {}
                    )
                }

                Section {
                    Toggle("Mobile Output Guide", isOn: .constant(true))
                        .accessibilityIdentifier("server.mobileOutputGuide.enabled")
                } footer: {
                    Text("Appends Oppi's link and rich-content rendering guide to new and explicitly reloaded managed Pi sessions, including Pi Control. Terminal-owned Mirror sessions are unchanged.")
                }

                Section("Badge") {
                    Text("Preview")
                }

                Section {
                    Label("Add Server", systemImage: "plus")
                        .accessibilityIdentifier("server.addServer")
                    Label("Remove Server", systemImage: "trash")
                }
            }
            .navigationTitle(HostSwitcherDestination.serverSettings.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ServerSwitcherPill(
                        server: HostSwitcherPreviewData.server,
                        connectionState: .connected
                    )
                    .accessibilityLabel("Current server: \(HostSwitcherPreviewData.server.name)")
                }
            }
        }
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .environment(\.theme, themeID.appTheme)
        .environment(\.themeID, themeID)
        .accessibilityIdentifier(
            ProcessInfo.processInfo.environment["SCREENSHOT_READY_ID"] ?? "screenshot.ready"
        )
    }
}
#endif
