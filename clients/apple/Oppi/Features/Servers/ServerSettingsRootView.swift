import SwiftUI

/// Server Settings root: a read-only summary of the visible server, one index
/// row per focused page, the Mobile Output Guide toggle, and Remove Server.
///
/// Follows the active host (`ServerSelection.resolveVisible`). Data for every
/// page comes from one `ServerSettingsModel`, so pushed pages never refetch.
struct ServerSettingsRootView: View {
    let server: PairedServer

    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation
    @Environment(ServerStore.self) private var serverStore
    @Environment(\.dismiss) private var dismiss

    @State private var model = ServerSettingsModel()
    @State private var verticalBarActive = false
    @State private var showRemoveConfirmation = false

    init(server: PairedServer) {
        self.server = server
    }

    #if DEBUG
    /// Screenshot harness entry: renders a fixture model without a server.
    init(server: PairedServer, model: ServerSettingsModel) {
        self.server = server
        _model = State(initialValue: model)
    }
    #endif

    private var pairedServer: PairedServer {
        ServerDetailModelProvidersNavigation.visibleServer(
            activeServerId: coordinator.activeServerId,
            frozenServer: server,
            servers: serverStore.servers
        )
    }

    var body: some View {
        List {
            summarySection

            Section {
                ServerModelProvidersNavigationRow(
                    summary: model.providerSummary,
                    summaryStyle: model.providerSetupState == .needsConfiguration ? .themeOrange : .themeComment
                ) {
                    ServerDetailModelProvidersNavigation.open(
                        navigation: navigation,
                        activeServerId: coordinator.activeServerId,
                        frozenServer: server,
                        servers: serverStore.servers
                    )
                }
                SettingsIndexRow("Workspaces", systemImage: "square.grid.2x2", value: workspaceCount) {
                    WorkspaceListView(server: pairedServer)
                }
                .accessibilityIdentifier("server.manageWorkspaces")
                SettingsIndexRow("Dictionary", systemImage: "text.book.closed") {
                    DictationDictionaryView(workspaceId: nil)
                }
                .accessibilityIdentifier("server.dictationDictionary")
                SettingsIndexRow("Paired Devices", systemImage: "iphone.gen3", value: pairedDeviceCount) {
                    ServerPairedDevicesPage(model: model, server: pairedServer)
                }
                .accessibilityIdentifier("server.row.pairedDevices")
                SettingsIndexRow("About This Server", systemImage: "info.circle", value: model.aboutSummary) {
                    ServerAboutPage(model: model, server: pairedServer)
                }
                .accessibilityIdentifier("server.row.about")
                SettingsIndexRow("Badge Icon", systemImage: "app.badge") {
                    ServerBadgePage(server: pairedServer)
                }
                .accessibilityIdentifier("server.row.badge")
            }

            Section {
                mobileOutputGuideRow
            } footer: {
                Text("Appends Oppi's link and rich-content rendering guide to new and explicitly reloaded managed Pi sessions, including Pi Control. Terminal-owned Mirror sessions are unchanged.")
            }

            Section {
                Button(role: .destructive) {
                    showRemoveConfirmation = true
                } label: {
                    Label {
                        Text("Remove Server")
                    } icon: {
                        Image(systemName: "trash")
                            .foregroundStyle(.themeRed)
                    }
                }
                .tint(.themeRed)
            } footer: {
                Text("This only removes pairing from this iPhone. It does not delete the server or its data.")
            }
        }
        .settingsPage(HostSwitcherDestination.serverSettings.title)
        .accessibilityIdentifier("server.details.list")
        .toolbar {
            verticalRailToolbarItem(joinsVerticalRail: verticalBarActive) {
                HostSwitcherMenu(
                    current: pairedServer,
                    destination: .serverSettings
                )
            }
        }
        .readVerticalBarActivity($verticalBarActive)
        .refreshable {
            await model.load()
        }
        .task(id: pairedServer.id) {
            model.attach(coordinator: coordinator, serverId: pairedServer.id)
            await model.load()
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
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section {
            let state = HostSwitcherBadgeState.make(for: pairedServer, coordinator: coordinator)
            HStack(spacing: 12) {
                RuntimeBadge(icon: pairedServer.resolvedBadgeIcon, tint: state.tintColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pairedServer.name)
                        .foregroundStyle(.themeFg)
                    Text(Self.connectionStatusTitle(for: pairedServer, coordinator: coordinator))
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }
                Spacer(minLength: 8)
                if model.isLoading {
                    ProgressView()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("server.summary")

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.themeOrange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("server.summary.error")
            }
        }
    }

    /// Shared with About This Server so both read the same connection line.
    static func connectionStatusTitle(for server: PairedServer, coordinator: ConnectionCoordinator) -> String {
        let state = HostSwitcherBadgeState.make(for: server, coordinator: coordinator)
        return ServerConnectionLanePresentation.title(
            server: server,
            connection: coordinator.connection(for: server.id),
            state: state,
            isPreparing: coordinator.preparingServerIds.contains(server.id)
        )
    }

    // MARK: - Index values

    private var workspaceCount: String? {
        coordinator.connection(for: pairedServer.id)
            .map { String($0.workspaceStore.workspaces.count) }
    }

    private var pairedDeviceCount: String? {
        let state = model.pairedDevicesState(currentDeviceId: pairedServer.deviceCredential?.deviceId)
        guard case .loaded(let rows, _) = state else { return nil }
        return String(rows.count)
    }

    // MARK: - Mobile Output Guide

    @ViewBuilder
    private var mobileOutputGuideRow: some View {
        switch model.mobileOutputGuideState {
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
                            Task { await model.setMobileOutputGuide(newValue) }
                        }
                    )
                )
                .disabled(model.isSavingMobileOutputGuide)
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
                    Task { await model.reloadMobileOutputGuide() }
                }
            }
            .accessibilityIdentifier("server.mobileOutputGuide.error")
        }
    }

    // MARK: - Remove Server

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
}

/// Settings drill-in for this server's model providers.
///
/// The push goes through `AppNavigation` so the host switcher tracks the
/// route, which a plain `NavigationLink` would not do, so this is the
/// `SettingsIndexActionRow` variant of a level-1 row. Keeps setup/status words
/// and color.
struct ServerModelProvidersNavigationRow: View {
    let summary: String
    let summaryStyle: ThemeShapeStyle
    let action: () -> Void

    var body: some View {
        SettingsIndexActionRow(value: summary, valueStyle: summaryStyle, action: action) {
            SettingsRowLabel(
                HostSwitcherDestination.modelProviders.menuTitle,
                systemImage: HostSwitcherDestination.modelProviders.systemImage
            )
        }
        .accessibilityIdentifier("server.modelProviders.open")
        .accessibilityLabel(HostSwitcherDestination.modelProviders.menuTitle)
        .accessibilityValue(summary)
    }
}
