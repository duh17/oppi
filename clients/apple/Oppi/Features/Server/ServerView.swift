import SwiftUI

/// Main Server tab view showing stats dashboard and health info
/// for paired servers.
///
/// Data flow:
/// - Stats from `GET /server/stats?range=N` via per-server `APIClient`
/// - Server info from `GET /server/info` via per-server `APIClient`
/// - Pull-to-refresh + `.task(id:)` keyed on server + range
/// - Multi-server picker when 2+ servers are paired
struct ServerView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(ConnectionCoordinator.self) private var coordinator

    @State private var selectedServerId: String?
    @State private var stats: ServerStats?
    @State private var serverInfo: ServerInfo?
    @State private var selectedRange: Int = 7
    @State private var isLoading = true
    @State private var error: String?
    @State private var dailyDetail: DailyDetail?
    @State private var isLoadingDetail = false
    @State private var dailyDetailCache: [String: DailyDetail] = [:]
    @State private var selectedMetric: StatsMetric = .cost
    @State private var showAddServer = false

    /// Resolves selected server, falling back to first available.
    private var selectedServer: PairedServer? {
        Self.resolveServer(selectedId: selectedServerId, from: serverStore.servers)
    }

    /// Build an `APIClient` for a specific server, or nil if URL is invalid.
    private func apiClient(for server: PairedServer) -> APIClient? {
        guard let baseURL = server.baseURL else { return nil }
        return APIClient(baseURL: baseURL, token: server.token, tlsCertFingerprint: server.tlsCertFingerprint)
    }

    /// Combined task identity — reloads when server or range changes.
    private var taskIdentity: String {
        Self.taskIdentity(selectedId: selectedServerId, range: selectedRange)
    }

    // MARK: - Testable Logic

    /// Resolve the selected server by ID, falling back to the first server.
    static func resolveServer(selectedId: String?, from servers: [PairedServer]) -> PairedServer? {
        ServerSelection.resolve(selectedId: selectedId, from: servers)
    }

    /// Build task identity string from server ID and range.
    static func taskIdentity(selectedId: String?, range: Int) -> String {
        ServerSelection.taskIdentity(selectedId: selectedId, range: range)
    }

    var body: some View {
        Group {
            if serverStore.servers.isEmpty {
                emptyState
            } else {
                dashboard
            }
        }
        .navigationTitle(selectedServer?.name ?? "Server")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let server = selectedServer {
                        NavigationLink(value: server) {
                            Label("Server Details", systemImage: "info.circle")
                        }
                    }
                    Button {
                        showAddServer = true
                    } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .navigationDestination(for: PairedServer.self) { server in
            ServerDetailView(server: server)
        }
        .sheet(isPresented: $showAddServer) {
            OnboardingView(mode: .addServer)
        }
        .onChange(of: serverStore.servers) { _, newServers in
            // If selected server was removed, reset to first
            if let selectedServerId,
               !newServers.contains(where: { $0.id == selectedServerId })
            {
                self.selectedServerId = newServers.first?.id
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Servers", systemImage: "server.rack")
        } description: {
            Text("Pair a server to view stats and health information.")
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
                if serverStore.servers.count > 1 {
                    serverPicker
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
        .task(id: taskIdentity) {
            clearStatsState()
            async let s: () = loadStats()
            async let i: () = loadServerInfo()
            _ = await (s, i)
        }
        .refreshable {
            dailyDetailCache = [:]
            dailyDetail = nil
            async let s: () = loadStats()
            async let i: () = loadServerInfo()
            _ = await (s, i)
        }
    }

    // MARK: - Server Picker

    private var serverPicker: some View {
        let servers = serverStore.servers
        let binding = Binding<String>(
            get: { selectedServer?.id ?? "" },
            set: { selectedServerId = $0 }
        )

        return Group {
            if servers.count <= 3 {
                Picker("Server", selection: binding) {
                    ForEach(servers) { server in
                        Text(server.name).tag(server.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Picker("Server", selection: binding) {
                    ForEach(servers) { server in
                        Text(server.name).tag(server.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Range Picker

    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            Text("7d").tag(7)
            Text("30d").tag(30)
            Text("90d").tag(90)
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
            Text("Unable to load stats")
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

        ModelBreakdownSection(breakdown: stats.modelBreakdown)

        WorkspaceBreakdownSection(workspaces: stats.workspaceBreakdown)

        if let serverInfo {
            ServerHealthSection(
                memory: stats.memory,
                uptime: serverInfo.uptimeLabel,
                platform: serverInfo.platformLabel,
                activeSessionCount: serverInfo.stats.activeSessionCount
            )
        }
    }

    // MARK: - State Management

    private func clearStatsState() {
        dailyDetail = nil
        dailyDetailCache = [:]
        stats = nil
        serverInfo = nil
        error = nil
        isLoading = true
    }

    // MARK: - Data Loading

    private func loadStats() async {
        guard let server = selectedServer,
              let client = apiClient(for: server)
        else {
            error = "Not connected to a server"
            isLoading = false
            return
        }

        do {
            let result = try await client.fetchStats(range: selectedRange)
            stats = result
            error = nil
        } catch {
            if stats == nil {
                self.error = error.localizedDescription
            }
        }

        isLoading = false
    }

    private func loadServerInfo() async {
        guard let server = selectedServer,
              let client = apiClient(for: server)
        else { return }

        do {
            serverInfo = try await client.serverInfo()
        } catch {
            // Non-fatal — stats still show without server info
        }
    }

    private func loadDailyDetail(date: String) async {
        if let cached = dailyDetailCache[date] {
            withAnimation(.easeInOut(duration: 0.2)) {
                dailyDetail = cached
            }
            return
        }

        guard let server = selectedServer,
              let client = apiClient(for: server)
        else { return }

        isLoadingDetail = true

        do {
            let result = try await client.fetchDailyDetail(date: date)
            dailyDetailCache[date] = result
            withAnimation(.easeInOut(duration: 0.2)) {
                dailyDetail = result
            }
        } catch {
            // Silently fail — the tooltip still shows summary data
        }

        isLoadingDetail = false
    }
}
