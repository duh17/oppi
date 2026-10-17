import SwiftUI

/// Token and cost usage for the selected host.
///
/// Data flow:
/// - Stats from `GET /server/stats?range=N` via per-server `APIClient`
/// - Reloads follow the pill's active host and the 7d / 30d / 90d / 1y / All range
/// - Server process and host resources live on Server Metrics, not here
struct ServerView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(AppNavigation.self) private var navigation

    @State private var stats: ServerStats?
    @State private var selectedRange: UsageRange = .week
    @State private var isLoading = true
    @State private var error: String?
    @State private var dailyDetail: DailyDetail?
    @State private var isLoadingDetail = false
    @State private var dailyDetailCache: [String: DailyDetail] = [:]
    @State private var selectedMetric: StatsMetric = .cost
    @State private var showAddServer = false
    @State private var providerStatuses: [ProviderAuthProviderStatus] = []

    /// Follows the pill's selected host.
    private var selectedServer: PairedServer? {
        Self.resolveServer(selectedId: coordinator.activeServerId, from: serverStore.servers)
    }

    /// Resolve the coordinator-owned client for the dashboard/provider path.
    private func apiClient(for server: PairedServer) async -> APIClient? {
        await coordinator.apiClientReady(for: server.id)
    }

    /// Metadata task identity — reloads only when the selected server changes.
    private var metadataTaskIdentity: String {
        Self.metadataTaskIdentity(selectedId: selectedServer?.id)
    }

    /// Combined stats task identity — reloads when server or range changes.
    private var taskIdentity: String {
        Self.taskIdentity(selectedId: selectedServer?.id, range: selectedRange)
    }

    // MARK: - Testable Logic

    /// Resolve the selected server by ID, falling back to the first server.
    static func resolveServer(selectedId: String?, from servers: [PairedServer]) -> PairedServer? {
        ServerSelection.resolve(selectedId: selectedId, from: servers)
    }

    /// Build task identity string for server-scoped metadata loads.
    static func metadataTaskIdentity(selectedId: String?) -> String {
        ServerSelection.metadataTaskIdentity(selectedId: selectedId)
    }

    /// Build task identity string from server ID and range.
    static func taskIdentity(selectedId: String?, range: UsageRange) -> String {
        ServerSelection.taskIdentity(selectedId: selectedId, range: range)
    }

    var body: some View {
        readingToolbarVerticalEdge { edge in
            serverRoot(railEdge: edge)
        }
    }

    @ViewBuilder
    private func serverRoot(railEdge: HorizontalEdge?) -> some View {
        let joinsRail = railEdge != nil
        Group {
            if serverStore.servers.isEmpty {
                emptyState
            } else if let selectedServer {
                dashboard
                    .id(selectedServer.id)
            } else {
                emptyState
            }
        }
        .navigationTitle(HostSwitcherDestination.usage.title)
        .toolbar {
            if let selectedServer {
                verticalRailToolbarItem(joinsVerticalRail: joinsRail) {
                    HostSwitcherMenu(
                        current: selectedServer,
                        destination: .usage,
                        fitsVerticalRail: joinsRail
                    )
                }
            }
        }
        .routerModal(isPresented: $showAddServer) {
            OnboardingView(mode: .addServer)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Servers", systemImage: "server.rack")
        } description: {
            Text("Pair a server to view usage.")
        } actions: {
            Button("Add Server") {
                showAddServer = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let selectedServer, shouldShowProviderSetupCard {
                    providerSetupCard(for: selectedServer)
                }

                rangePicker

                if isLoading, stats == nil {
                    loadingView
                } else if let error, stats == nil {
                    errorView(error)
                } else if let stats {
                    statsContent(stats)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .themedScrollSurface()
        .task(id: metadataTaskIdentity) {
            providerStatuses = []
            await loadProviderStatus()
        }
        .task(id: taskIdentity) {
            clearStatsState()
            await loadStats()
        }
        .refreshable {
            dailyDetailCache = [:]
            dailyDetail = nil
            async let s: () = loadStats()
            async let p: () = loadProviderStatus()
            _ = await (s, p)
        }
    }

    // MARK: - Provider Setup

    private var shouldShowProviderSetupCard: Bool {
        !providerStatuses.isEmpty && !providerStatuses.contains(where: \.authenticated)
    }

    private func providerSetupCard(for server: PairedServer) -> some View {
        ProviderSetupPromptCard(
            message: "Connect a model provider so new sessions can run on this server.",
            openAccessibilityIdentifier: "server.providerSetup.open"
        ) {
            navigation.openModelProviders(ModelProvidersNavTarget(serverId: server.id))
        }
    }

    // MARK: - Range Picker

    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            ForEach(UsageRange.allCases, id: \.self) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Loading / Error

    private var loadingView: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Spacer()
        }
        .padding(.vertical, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.themeOrange)
            Text("Unable to load usage")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)
            Text(message)
                .font(.caption)
                .foregroundStyle(.themeComment)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Stats Content

    @ViewBuilder
    private func statsContent(_ stats: ServerStats) -> some View {
        StatsHeroRow(totals: stats.totals, daily: stats.daily, selectedMetric: $selectedMetric)

        DailyCostChartView(daily: stats.daily, metric: selectedMetric, onDaySelected: { dateString in
            Task { await loadDailyDetail(date: dateString) }
        })

        if isLoadingDetail {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 8)
        }

        if let dailyDetail {
            DailyDetailView(detail: dailyDetail) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.dailyDetail = nil
                }
            }
        }

        ModelBreakdownSection(breakdown: stats.modelBreakdown, metric: selectedMetric)

        WorkspaceBreakdownSection(workspaces: stats.workspaceBreakdown)
    }

    // MARK: - State Management

    private func clearStatsState() {
        dailyDetail = nil
        dailyDetailCache = [:]
        isLoadingDetail = false
        stats = nil
        error = nil
        isLoading = true
    }

    // MARK: - Data Loading

    private func shouldApplyHostResult(requestedId: String, error: Error? = nil) -> Bool {
        ServerSelection.shouldApplyHostResult(
            requestedId: requestedId,
            visibleId: selectedServer?.id,
            error: error
        )
    }

    private func loadStats() async {
        guard let server = selectedServer else {
            error = "Not connected to a server"
            isLoading = false
            return
        }
        let requestedId = server.id
        guard let client = await apiClient(for: server) else {
            guard shouldApplyHostResult(requestedId: requestedId) else { return }
            error = "Not connected to a server"
            isLoading = false
            return
        }

        do {
            let result = try await client.fetchStats(range: selectedRange)
            guard shouldApplyHostResult(requestedId: requestedId) else { return }
            stats = result
            error = nil
        } catch {
            guard shouldApplyHostResult(requestedId: requestedId, error: error) else { return }
            if stats == nil {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func loadProviderStatus() async {
        guard let server = selectedServer else { return }
        let requestedId = server.id
        guard let client = await apiClient(for: server) else { return }

        do {
            let statuses = try await client.listProviderAuthStatus()
            guard shouldApplyHostResult(requestedId: requestedId) else { return }
            providerStatuses = statuses
        } catch {
            guard shouldApplyHostResult(requestedId: requestedId, error: error) else { return }
            // Non-fatal — the dashboard can still show stats without setup status.
            providerStatuses = []
        }
    }

    private func loadDailyDetail(date: String) async {
        guard let server = selectedServer else { return }
        let requestedId = server.id

        if let cached = dailyDetailCache[date] {
            guard shouldApplyHostResult(requestedId: requestedId) else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                dailyDetail = cached
            }
            return
        }

        guard let client = await apiClient(for: server) else { return }
        guard shouldApplyHostResult(requestedId: requestedId) else { return }

        isLoadingDetail = true

        do {
            let result = try await client.fetchDailyDetail(date: date)
            guard shouldApplyHostResult(requestedId: requestedId) else { return }
            dailyDetailCache[date] = result
            withAnimation(.easeInOut(duration: 0.2)) {
                dailyDetail = result
            }
        } catch {
            guard shouldApplyHostResult(requestedId: requestedId, error: error) else { return }
            // Silently fail — the tooltip still shows summary data
        }

        guard shouldApplyHostResult(requestedId: requestedId) else { return }
        isLoadingDetail = false
    }
}

/// Server Metrics: the SwiftUI shell (title, host pill) around the UIKit page,
/// `ServerMetricsViewController`. Follows the pill's active host like Usage.
struct ServerMetricsScreen: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(ConnectionCoordinator.self) private var coordinator
    @Environment(\.themeID) private var themeID

    private var selectedServer: PairedServer? {
        ServerSelection.resolve(selectedId: coordinator.activeServerId, from: serverStore.servers)
    }

    var body: some View {
        if let server = selectedServer {
            ServerMetricsControllerHost(
                source: ServerMetricsSource(
                    serverId: server.id,
                    client: { [coordinator] in await coordinator.apiClientReady(for: server.id) },
                    cachedEnabled: { [coordinator] in
                        coordinator.connection(for: server.id)?.serverMetricsEnabled
                    },
                    cacheEnabled: { [coordinator] in
                        coordinator.setServerMetricsEnabledCache($0, for: server.id)
                    }
                ),
                themeID: themeID
            )
            .ignoresSafeArea(.container, edges: .vertical)
            .navigationTitle(HostSwitcherDestination.serverMetrics.title)
            .hostSwitcherRailToolbar(server: server, destination: .serverMetrics)
        } else {
            ContentUnavailableView(
                "No Servers",
                systemImage: "server.rack",
                description: Text("Pair a server to view its metrics.")
            )
            .navigationTitle(HostSwitcherDestination.serverMetrics.title)
        }
    }
}

private struct ServerMetricsControllerHost: UIViewControllerRepresentable {
    let source: ServerMetricsSource
    let themeID: ThemeID

    func makeUIViewController(context: Context) -> ServerMetricsViewController {
        ServerMetricsViewController(source: source, themeID: themeID)
    }

    func updateUIViewController(_ controller: ServerMetricsViewController, context: Context) {
        controller.applyThemeIfNeeded(themeID)
        controller.setSource(source)
    }
}

#if DEBUG
struct UsageChromePreview: View {
    private let themeID: ThemeID

    init() {
        themeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" ? .light : .dark
        ThemeRuntimeState.setThemeID(themeID)
    }

    var body: some View {
        readingToolbarVerticalEdge { edge in
            usagePreview(railEdge: edge)
        }
    }

    private func usagePreview(railEdge: HorizontalEdge?) -> some View {
        let joinsRail = railEdge != nil
        return NavigationStack {
            VStack(spacing: 16) {
                Picker("Range", selection: .constant(UsageRange.week)) {
                    ForEach(UsageRange.allCases, id: \.self) { range in
                        Text(range.label).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                Spacer()
            }
            .padding()
            .navigationTitle(HostSwitcherDestination.usage.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                verticalRailToolbarItem(joinsVerticalRail: joinsRail) {
                    Menu {
                        Button(HostSwitcherPreviewData.server.name, systemImage: "checkmark.circle.fill") {}
                    } label: {
                        ServerSwitcherPill(
                            server: HostSwitcherPreviewData.server,
                            connectionState: .connected,
                            fitsVerticalRail: joinsRail
                        )
                    }
                    .accessibilityLabel("Current server: \(HostSwitcherPreviewData.server.name)")
                }
            }
        }
        .environment(\.theme, themeID.appTheme)
        .environment(\.themeID, themeID)
        .preferredColorScheme(themeID == .light ? .light : .dark)
        .accessibilityIdentifier(
            ProcessInfo.processInfo.environment["SCREENSHOT_READY_ID"] ?? "screenshot.ready"
        )
    }
}
#endif
