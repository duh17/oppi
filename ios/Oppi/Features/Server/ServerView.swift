import SwiftUI

/// Main Server tab view showing stats dashboard and health info
/// for the currently connected server.
///
/// Data flow:
/// - Stats from `GET /server/stats?range=N` via `APIClient.fetchStats(range:)`
/// - Server info from `GET /server/info` via `APIClient.serverInfo()`
/// - Pull-to-refresh + `.task(id: selectedRange)` (no background polling)
struct ServerView: View {
    @Environment(\.apiClient) private var apiClient
    @Environment(ServerStore.self) private var serverStore
    @Environment(ConnectionCoordinator.self) private var coordinator

    @State private var stats: ServerStats?
    @State private var serverInfo: ServerInfo?
    @State private var selectedRange: Int = 7
    @State private var isLoading = true
    @State private var error: String?

    private var activeServer: PairedServer? {
        serverStore.servers.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
        .navigationTitle(activeServer?.name ?? "Server")
        .task(id: selectedRange) {
            await loadStats()
        }
        .task {
            await loadServerInfo()
        }
        .refreshable {
            async let s: () = loadStats()
            async let i: () = loadServerInfo()
            _ = await (s, i)
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
        StatsHeroRow(totals: stats.totals, daily: stats.daily)

        DailyCostChartView(daily: stats.daily)

        ModelBreakdownSection(breakdown: stats.modelBreakdown)

        if selectedRange != 7 {
            ActivityHeatmapView(daily: stats.daily)
        }

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

    // MARK: - Data Loading

    private func loadStats() async {
        guard let apiClient else {
            error = "Not connected to a server"
            isLoading = false
            return
        }

        do {
            let result = try await apiClient.fetchStats(range: selectedRange)
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
        guard let apiClient else { return }

        do {
            serverInfo = try await apiClient.serverInfo()
        } catch {
            // Non-fatal — stats still show without server info
        }
    }
}
