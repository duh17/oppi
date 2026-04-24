import Charts
import SwiftUI

// MARK: - Aggregated model (deduped by provider + stable model id)

private struct AggregatedModel: Identifiable {
    let aggregationKey: String
    let displayName: String
    let provider: String?
    let providerDisplayName: String?
    /// Any raw model name from this group (for color lookup).
    let representativeModel: String
    let sessions: Int
    let cost: Double
    let tokens: Int
    let inputTokens: Int
    let cacheRead: Int
    let cacheWrite: Int
    var share: Double

    var id: String { aggregationKey }

    /// Prompt-cache effectiveness: cacheRead / (cacheRead + uncachedInput + cacheWrite).
    /// Excludes output tokens, but counts cache writes against the total.
    var cacheRate: Double? {
        computePromptCacheRate(
            cacheRead: cacheRead,
            inputTokens: inputTokens,
            cacheWrite: cacheWrite
        )
    }
}

/// Number of models shown before "Show more" disclosure.
private let topModelCount = 5

struct ModelBreakdownSection: View {

    let breakdown: [StatsModelBreakdown]

    @State private var showAll = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Aggregation

    private var aggregated: [AggregatedModel] {
        var byKey: [String: AggregatedModel] = [:]

        for item in breakdown {
            let identity = modelDisplayIdentity(item.model)
            let key = identity.aggregationKey
            let cacheRead = item.cacheRead ?? 0
            let cacheWrite = item.cacheWrite ?? 0
            let inputTokens = item.inputTokens

            if var existing = byKey[key] {
                existing = AggregatedModel(
                    aggregationKey: key,
                    displayName: existing.displayName,
                    provider: existing.provider,
                    providerDisplayName: existing.providerDisplayName,
                    representativeModel: existing.representativeModel,
                    sessions: existing.sessions + item.sessions,
                    cost: existing.cost + item.cost,
                    tokens: existing.tokens + item.tokens,
                    inputTokens: existing.inputTokens + inputTokens,
                    cacheRead: existing.cacheRead + cacheRead,
                    cacheWrite: existing.cacheWrite + cacheWrite,
                    share: existing.share + item.share
                )
                byKey[key] = existing
            } else {
                byKey[key] = AggregatedModel(
                    aggregationKey: key,
                    displayName: identity.displayName,
                    provider: identity.provider,
                    providerDisplayName: identity.providerDisplayName,
                    representativeModel: item.model,
                    sessions: item.sessions,
                    cost: item.cost,
                    tokens: item.tokens,
                    inputTokens: inputTokens,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite,
                    share: item.share
                )
            }
        }

        return byKey.values.sorted {
            if $0.cost != $1.cost {
                return $0.cost > $1.cost
            }
            if $0.displayName != $1.displayName {
                return $0.displayName < $1.displayName
            }
            return ($0.providerDisplayName ?? "") < ($1.providerDisplayName ?? "")
        }
    }

    /// Models with non-zero cost, sorted by cost descending.
    private var nonZeroModels: [AggregatedModel] {
        aggregated.filter { $0.cost > 0.005 }
    }

    private var totalCost: Double {
        aggregated.reduce(0) { $0 + $1.cost }
    }

    private var visibleModels: [AggregatedModel] {
        let models = nonZeroModels
        if showAll || models.count <= topModelCount {
            return models
        }
        return Array(models.prefix(topModelCount))
    }

    private var hiddenCount: Int {
        max(0, nonZeroModels.count - topModelCount)
    }

    // MARK: - Body

    var body: some View {
        let models = nonZeroModels
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Models")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)

                donutChart(models)

                modelList
            }
        }
    }

    // MARK: - Donut chart

    @ViewBuilder
    private func donutChart(_ models: [AggregatedModel]) -> some View {
        if totalCost <= 0 {
            EmptyView()
        } else {
            ZStack {
                Chart(models) { item in
                    SectorMark(
                        angle: .value("Cost", item.cost),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .foregroundStyle(modelColor(item.representativeModel))
                }
                .chartLegend(.hidden)
                .frame(width: 140, height: 140)

                VStack(spacing: 2) {
                    Text(SessionFormatting.costString(totalCost))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(.themeFg)
                    Text("total")
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                }
                .frame(width: 80)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Model list

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(visibleModels) { item in
                modelRow(item)
            }

            if !showAll, hiddenCount > 0 {
                Button {
                    withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
                        showAll = true
                    }
                } label: {
                    Text("Show \(hiddenCount) more")
                        .font(.caption)
                        .foregroundStyle(.themeBlue)
                }
                .padding(.top, 2)
            } else if showAll, hiddenCount > 0 {
                Button {
                    withAnimation(ThemeMotion.easeInOut(duration: 0.2, reduceMotion: reduceMotion)) {
                        showAll = false
                    }
                } label: {
                    Text("Show less")
                        .font(.caption)
                        .foregroundStyle(.themeBlue)
                }
                .padding(.top, 2)
            }
        }
    }

    private func modelRow(_ item: AggregatedModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                leadingIdentity(item)
                    .frame(width: 126, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.themeComment.opacity(0.12))
                            .frame(height: 5)
                        Capsule()
                            .fill(modelColor(item.representativeModel).opacity(0.55))
                            .frame(width: max(2, geo.size.width * item.share), height: 5)
                    }
                }
                .frame(height: 5)

                Text(SessionFormatting.costString(item.cost))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.themeComment)
                    .frame(width: 56, alignment: .trailing)

                Text("\(Int((item.share * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.themeComment)
                    .frame(width: 30, alignment: .trailing)
            }

            if item.cacheRead > 0 || item.cacheWrite > 0 {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 18)

                    if let cacheRate = item.cacheRate {
                        Text("cache \(Int((cacheRate * 100).rounded()))%")
                            .foregroundStyle(.themeGreen)
                    }

                    Text("R: \(item.cacheRead.formattedTokenCount())")
                        .foregroundStyle(.themeComment)

                    Text("W: \(item.cacheWrite.formattedTokenCount())")
                        .foregroundStyle(.themeComment)

                    Spacer()
                }
                .font(.caption2)
                .padding(.leading, 6)
            }
        }
    }

    private func leadingIdentity(_ item: AggregatedModel) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ProviderGlyph(provider: item.provider, size: 12, color: .themeComment)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.caption)
                    .foregroundStyle(modelColor(item.representativeModel))
                    .lineLimit(1)

                if let providerDisplayName = item.providerDisplayName {
                    Text(providerDisplayName)
                        .font(.caption2)
                        .foregroundStyle(.themeComment)
                        .lineLimit(1)
                }
            }
        }
    }
}
