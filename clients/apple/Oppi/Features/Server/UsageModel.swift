import Foundation

/// What Usage reads from one server. `APIClient` is the app's; a test brings its own.
protocol UsageStatsClient: Sendable {
    func fetchStats(range: UsageRange) async throws -> ServerStats
    func fetchDailyDetail(date: String) async throws -> DailyDetail
    func listProviderAuthStatus() async throws -> [ProviderAuthProviderStatus]
}

extension APIClient: UsageStatsClient {}

/// Token and cost usage of one server: the state `UsageViewController` draws.
///
/// A model belongs to one server for its whole life: the page that owns it is pinned
/// to that server (`UsageRouteViewController` replaces the page when the visible
/// server changes), so an answer that lands late settles into the model that asked and
/// no other. Within one model, an answer is dropped when it is for a range the person
/// has left or a day they have since replaced, and a cancelled request is not a failure.
///
/// Stats load when the model starts and again whenever the range changes (the old
/// range's numbers never sit under the new range's axis). A pull reloads the stats and
/// the provider status but keeps what is shown until the new numbers arrive.
@MainActor @Observable
final class UsageModel {
    /// The most models listed before "Show more".
    nonisolated static let topModelCount = 5
    /// The most sessions listed under a day.
    nonisolated static let detailSessionCount = 10

    let serverId: String

    private(set) var range: UsageRange = .week
    private(set) var metric: StatsMetric = .cost
    private(set) var stats: ServerStats?
    private(set) var isLoading = true
    private(set) var error: String?
    /// The day opened under the chart, and the day being fetched for it.
    private(set) var detail: DailyDetail?
    private(set) var isLoadingDetail = false
    private(set) var showsAllModels = false
    private(set) var providerStatuses: [ProviderAuthProviderStatus] = []

    @ObservationIgnored private let client: @MainActor () async -> (any UsageStatsClient)?
    @ObservationIgnored private var detailCache: [String: DailyDetail] = [:]
    @ObservationIgnored private var requestedDay: String?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var providerTask: Task<Void, Never>?

    /// `client` resolves the server's client when a request starts; nil is "not connected".
    init(serverId: String, client: @escaping @MainActor () async -> (any UsageStatsClient)?) {
        self.serverId = serverId
        self.client = client
    }

    /// The model of a paired server, reading through its connection's client.
    convenience init(serverId: String, coordinator: ConnectionCoordinator) {
        self.init(serverId: serverId) { [weak coordinator] in
            await coordinator?.apiClientReady(for: serverId)
        }
    }

    // MARK: - Derived

    /// Nothing is authenticated yet, so Usage offers to connect a model provider.
    var showsProviderSetup: Bool {
        !providerStatuses.isEmpty && !providerStatuses.contains(where: \.authenticated)
    }

    var aggregatedModels: [AggregatedStatsModel] {
        guard let stats else { return [] }
        return aggregateStatsModels(stats.modelBreakdown, sortedBy: metric).nonZeroStatsModels(for: metric)
    }

    var visibleModels: [AggregatedStatsModel] {
        let models = aggregatedModels
        return showsAllModels || models.count <= Self.topModelCount ? models : Array(models.prefix(Self.topModelCount))
    }

    var hiddenModelCount: Int { max(0, aggregatedModels.count - Self.topModelCount) }

    var totalMetricValue: Double { aggregatedModels.reduce(0) { $0 + $1.value(for: metric) } }

    // MARK: - Loading

    /// The first load: stats for the current range, and the provider status.
    func start() {
        loadStats(clearing: true)
        loadProviderStatus()
    }

    /// A pull: new numbers for the same range, shown over the old ones until they arrive.
    func refresh() async {
        detailCache = [:]
        detail = nil
        requestedDay = nil
        isLoadingDetail = false
        loadStats(clearing: false)
        loadProviderStatus()
        await statsTask?.value
        await providerTask?.value
    }

    func selectRange(_ next: UsageRange) {
        guard next != range else { return }
        range = next
        loadStats(clearing: true)
    }

    func selectMetric(_ next: StatsMetric) {
        guard next != metric else { return }
        metric = next
        showsAllModels = false
    }

    func toggleShowAllModels() {
        showsAllModels.toggle()
    }

    /// Opens a day under the chart: from the cache when it was fetched, else from the
    /// server. Picking another day, or closing, drops an answer still on its way.
    func selectDay(_ date: String) {
        detailTask?.cancel()
        requestedDay = date
        if let cached = detailCache[date] {
            detail = cached
            isLoadingDetail = false
            return
        }
        isLoadingDetail = true
        detailTask = Task { [weak self] in
            guard let self else { return }
            guard let client = await client(), requestedDay == date, !Task.isCancelled else {
                if requestedDay == date { isLoadingDetail = false }
                return
            }
            do {
                let result = try await client.fetchDailyDetail(date: date)
                guard requestedDay == date, !Task.isCancelled else { return }
                detailCache[date] = result
                detail = result
            } catch {
                // The chart's tooltip still shows the day's summary.
            }
            if requestedDay == date { isLoadingDetail = false }
        }
    }

    func closeDetail() {
        detailTask?.cancel()
        requestedDay = nil
        detail = nil
        isLoadingDetail = false
    }

    /// Stops what is in flight; the page that owned this model is gone.
    func stop() {
        statsTask?.cancel()
        detailTask?.cancel()
        providerTask?.cancel()
    }

    private func loadStats(clearing: Bool) {
        statsTask?.cancel()
        if clearing {
            detail = nil
            detailCache = [:]
            requestedDay = nil
            isLoadingDetail = false
            stats = nil
            error = nil
            isLoading = true
        }
        let requested = range
        statsTask = Task { [weak self] in
            guard let self else { return }
            guard let client = await client() else {
                if requested == range, !Task.isCancelled {
                    error = "Not connected to a server"
                    isLoading = false
                }
                return
            }
            do {
                let result = try await client.fetchStats(range: requested)
                guard requested == range, !Task.isCancelled else { return }
                stats = result
                error = nil
            } catch {
                guard requested == range, !Task.isCancelled, !(error is CancellationError) else { return }
                // A pull that fails keeps the numbers already shown.
                if stats == nil { self.error = error.localizedDescription }
            }
            if requested == range, !Task.isCancelled { isLoading = false }
        }
    }

    private func loadProviderStatus() {
        providerTask?.cancel()
        providerTask = Task { [weak self] in
            guard let self, let client = await client() else { return }
            do {
                let statuses = try await client.listProviderAuthStatus()
                guard !Task.isCancelled else { return }
                providerStatuses = statuses
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                // Not fatal: Usage still shows the stats without the setup card.
                providerStatuses = []
            }
        }
    }
}

// MARK: - Formatting

extension StatsMetric {
    /// How `value` of this metric reads in a total, a row, or a chart's center.
    func formatted(_ value: Double) -> String {
        switch self {
        case .sessions: String(format: "%.0f", value)
        case .cost: SessionFormatting.costString(value)
        case .tokens: Int(value.rounded()).formattedTokenCount()
        }
    }

    var title: String {
        switch self {
        case .sessions: String(localized: "Sessions")
        case .cost: String(localized: "Cost")
        case .tokens: String(localized: "Tokens")
        }
    }
}

/// The change from the first half of a range to the second, shown under a hero total.
struct UsageTrend: Equatable {
    let isRising: Bool
    /// "12%".
    let label: String

    /// Nothing when there are fewer than two days, nothing to compare against, or the
    /// change is under 5%.
    static func make(values: [Double]) -> UsageTrend? {
        guard values.count >= 2 else { return nil }
        let mid = values.count / 2
        let firstHalf = values.prefix(mid).reduce(0, +)
        let secondHalf = values.suffix(from: mid).reduce(0, +)
        guard firstHalf > 0 else { return nil }
        let delta = (secondHalf - firstHalf) / firstHalf
        guard abs(delta) >= 0.05 else { return nil }
        return UsageTrend(isRising: delta > 0, label: String(format: "%.0f%%", abs(delta) * 100))
    }
}
