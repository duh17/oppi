import Foundation
import Testing
@testable import Oppi

/// Usage's state for one server: range switching, day selection, and answers that
/// arrive after the person moved on.
@Suite("Usage model", .serialized)
@MainActor
struct UsageModelTests {
    private func stats(sessions: Int, cost: Double = 1, models: [StatsModelBreakdown] = []) -> ServerStats {
        ServerStats(
            memory: StatsMemory(heapUsed: 0, heapTotal: 0, rss: 0, external: 0),
            activeSessions: [],
            daily: [StatsDailyEntry(date: "2026-10-27", sessions: sessions, cost: cost, tokens: 100, byModel: nil)],
            modelBreakdown: models,
            workspaceBreakdown: [],
            totals: StatsTotals(sessions: sessions, cost: cost, tokens: 100)
        )
    }

    private func detail(_ date: String, sessions: Int = 1) -> DailyDetail {
        DailyDetail(date: date, totals: StatsTotals(sessions: sessions, cost: 1, tokens: 1), hourly: [], sessions: [])
    }

    private func make(_ client: ScriptedUsageClient?) -> UsageModel {
        UsageModel(serverId: "usage-server") { client }
    }

    @Test("It loads the week first, then the range the person picks, and clears the old numbers while it loads")
    func rangeSwitching() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 7), .month: stats(sessions: 30)]
        let model = make(client)

        model.start()
        #expect(model.isLoading)
        #expect(await waitForMainActorCondition { model.stats?.totals.sessions == 7 })
        #expect(!model.isLoading)

        client.holdStats(for: .month)
        model.selectRange(.month)
        // The week's numbers must not sit under the month's axis.
        #expect(model.stats == nil)
        #expect(model.isLoading)
        client.releaseStats(for: .month)
        #expect(await waitForMainActorCondition { model.stats?.totals.sessions == 30 })
        #expect(client.requestedRanges == [.week, .month])
    }

    @Test("A slow answer for a range the person left never lands")
    func staleRangeAnswerIsDropped() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 7), .year: stats(sessions: 365)]
        client.holdStats(for: .week)
        let model = make(client)

        model.start()
        model.selectRange(.year)
        #expect(await waitForMainActorCondition { model.stats?.totals.sessions == 365 })
        // The week's answer arrives last and is not the range on screen.
        client.releaseStats(for: .week)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(model.range == .year)
        #expect(model.stats?.totals.sessions == 365)
        #expect(!model.isLoading)
    }

    @Test("Choosing the range already shown does nothing")
    func sameRangeIsIgnored() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 7)]
        let model = make(client)
        model.start()
        #expect(await waitForMainActorCondition { model.stats != nil })

        model.selectRange(.week)

        #expect(model.stats != nil)
        #expect(client.requestedRanges == [.week])
    }

    @Test("A load that fails says why, and a pull that fails keeps the numbers shown")
    func failures() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 7)]
        client.failStats = true
        let model = make(client)

        model.start()
        #expect(await waitForMainActorCondition { model.error != nil && !model.isLoading })
        #expect(model.stats == nil)

        client.failStats = false
        model.selectRange(.month)
        model.selectRange(.week)
        #expect(await waitForMainActorCondition { model.stats?.totals.sessions == 7 })

        client.failStats = true
        await model.refresh()
        #expect(model.stats?.totals.sessions == 7)
    }

    @Test("No connection is a failure the page can show")
    func notConnected() async {
        let model = make(nil)
        model.start()
        #expect(await waitForMainActorCondition { !model.isLoading })
        #expect(model.error == "Not connected to a server")
    }

    @Test("A day is fetched once, shown from the cache after, and closed")
    func daySelectionCaches() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 7)]
        client.details = ["2026-10-26": detail("2026-10-26", sessions: 2), "2026-10-27": detail("2026-10-27", sessions: 3)]
        let model = make(client)
        model.start()
        #expect(await waitForMainActorCondition { model.stats != nil })

        model.selectDay("2026-10-26")
        #expect(model.isLoadingDetail)
        #expect(await waitForMainActorCondition { model.detail?.date == "2026-10-26" })
        #expect(!model.isLoadingDetail)

        model.selectDay("2026-10-27")
        #expect(await waitForMainActorCondition { model.detail?.date == "2026-10-27" })
        model.selectDay("2026-10-26")
        // From the cache: at once, with no second request.
        #expect(model.detail?.date == "2026-10-26")
        #expect(client.requestedDays == ["2026-10-26", "2026-10-27"])

        model.closeDetail()
        #expect(model.detail == nil)
    }

    @Test("Picking another day while one loads drops the first day's answer")
    func latestDayWins() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 7)]
        client.details = ["2026-10-26": detail("2026-10-26"), "2026-10-27": detail("2026-10-27")]
        client.holdDetail(for: "2026-10-26")
        let model = make(client)
        model.start()
        #expect(await waitForMainActorCondition { model.stats != nil })

        model.selectDay("2026-10-26")
        model.selectDay("2026-10-27")
        #expect(await waitForMainActorCondition { model.detail?.date == "2026-10-27" })
        client.releaseDetail(for: "2026-10-26")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(model.detail?.date == "2026-10-27")
        #expect(!model.isLoadingDetail)
    }

    @Test("Closing a day while it loads drops its answer")
    func closingDropsTheAnswer() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 7)]
        client.details = ["2026-10-26": detail("2026-10-26")]
        client.holdDetail(for: "2026-10-26")
        let model = make(client)
        model.start()
        #expect(await waitForMainActorCondition { model.stats != nil })

        model.selectDay("2026-10-26")
        model.closeDetail()
        client.releaseDetail(for: "2026-10-26")
        try? await Task.sleep(for: .milliseconds(100))

        #expect(model.detail == nil)
        #expect(!model.isLoadingDetail)
    }

    @Test("Another range or a pull forgets the days it had open")
    func rangeAndPullForgetTheDay() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 7), .month: stats(sessions: 30)]
        client.details = ["2026-10-26": detail("2026-10-26")]
        let model = make(client)
        model.start()
        #expect(await waitForMainActorCondition { model.stats != nil })
        model.selectDay("2026-10-26")
        #expect(await waitForMainActorCondition { model.detail != nil })

        await model.refresh()
        #expect(model.detail == nil)
        // A pull keeps the numbers while it reloads, and drops the cache: the day is asked for again.
        model.selectDay("2026-10-26")
        #expect(await waitForMainActorCondition { model.detail != nil })
        #expect(client.requestedDays == ["2026-10-26", "2026-10-26"])

        model.selectRange(.month)
        #expect(model.detail == nil)
    }

    @Test("The provider card shows only when providers are listed and none is signed in")
    func providerSetup() async {
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 1)]
        client.providers = []
        let model = make(client)
        model.start()
        #expect(await waitForMainActorCondition { !model.isLoading })
        #expect(!model.showsProviderSetup)

        client.providers = [Self.provider("a", authenticated: false)]
        await model.refresh()
        #expect(model.showsProviderSetup)

        client.providers = [Self.provider("a", authenticated: false), Self.provider("b", authenticated: true)]
        await model.refresh()
        #expect(!model.showsProviderSetup)

        client.failProviders = true
        await model.refresh()
        #expect(!model.showsProviderSetup)
    }

    @Test("Seven models show five; Show more shows all, and a new metric starts over")
    func modelList() async {
        let models = (1...7).map { index in
            StatsModelBreakdown(
                model: "anthropic/claude-model-\(index)", sessions: index, cost: Double(index), tokens: index * 10,
                inputTokens: index, cacheRead: nil, cacheWrite: nil, share: 0
            )
        }
        let client = ScriptedUsageClient()
        client.statsByRange = [.week: stats(sessions: 1, models: models)]
        let model = make(client)
        model.start()
        #expect(await waitForMainActorCondition { model.stats != nil })

        #expect(model.aggregatedModels.count == 7)
        #expect(model.visibleModels.count == UsageModel.topModelCount)
        #expect(model.hiddenModelCount == 2)
        model.toggleShowAllModels()
        #expect(model.visibleModels.count == 7)
        model.selectMetric(.tokens)
        #expect(model.visibleModels.count == UsageModel.topModelCount)
        #expect(model.metric == .tokens)
    }

    @Test("The trend compares the second half of the range with the first, and says nothing for a small change")
    func trend() {
        #expect(UsageTrend.make(values: [1]) == nil)
        #expect(UsageTrend.make(values: [0, 5]) == nil)
        #expect(UsageTrend.make(values: [10, 10.2]) == nil)
        #expect(UsageTrend.make(values: [10, 15]) == UsageTrend(isRising: true, label: "50%"))
        #expect(UsageTrend.make(values: [10, 10, 5, 5]) == UsageTrend(isRising: false, label: "50%"))
    }

    private static func provider(_ id: String, authenticated: Bool) -> ProviderAuthProviderStatus {
        ProviderAuthProviderStatus(
            id: id, name: id, supportsApiKey: true, oauth: nil, authenticated: authenticated, credentialType: nil,
            expiresAt: nil, maskedKey: nil
        )
    }
}
