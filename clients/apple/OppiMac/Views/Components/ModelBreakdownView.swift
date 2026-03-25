import SwiftUI

// MARK: - Aggregated model

/// Merges duplicate raw model names (e.g. "anthropic/claude-opus-4-6-20250514"
/// and "anthropic/claude-opus-4-6") into one row per display name.
private struct AggregatedModel: Identifiable {
    let displayName: String
    let representativeModel: String
    let sessions: Int
    let cost: Double
    let tokens: Int
    let cacheRead: Int
    let cacheWrite: Int
    var share: Double

    var id: String { displayName }

    var cacheHitRate: Double? {
        guard cacheRead > 0, tokens > 0 else { return nil }
        return Double(cacheRead) / Double(tokens)
    }
}

/// Number of models shown before "Show more" toggle.
private let topModelCount = 5

// MARK: - ModelBreakdownView

/// Model list with share bars, cache stats, and show-more toggle.
struct ModelBreakdownView: View {

    let breakdown: [StatsModelBreakdown]

    @State private var showAll = false

    // MARK: - Aggregation

    private var aggregated: [AggregatedModel] {
        var byName: [String: AggregatedModel] = [:]

        for item in breakdown {
            let name = displayModelName(item.model)
            if var existing = byName[name] {
                existing = AggregatedModel(
                    displayName: name,
                    representativeModel: existing.representativeModel,
                    sessions: existing.sessions + item.sessions,
                    cost: existing.cost + item.cost,
                    tokens: existing.tokens + item.tokens,
                    cacheRead: existing.cacheRead + (item.cacheRead ?? 0),
                    cacheWrite: existing.cacheWrite + (item.cacheWrite ?? 0),
                    share: existing.share + item.share
                )
                byName[name] = existing
            } else {
                byName[name] = AggregatedModel(
                    displayName: name,
                    representativeModel: item.model,
                    sessions: item.sessions,
                    cost: item.cost,
                    tokens: item.tokens,
                    cacheRead: item.cacheRead ?? 0,
                    cacheWrite: item.cacheWrite ?? 0,
                    share: item.share
                )
            }
        }

        return byName.values.sorted { $0.cost > $1.cost }
    }

    private var nonZeroModels: [AggregatedModel] {
        aggregated.filter { $0.cost > 0.005 }
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
        VStack(alignment: .leading, spacing: 4) {
            Text("Models")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(visibleModels) { item in
                modelRow(item)
            }

            if !showAll, hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAll = true }
                } label: {
                    Text("Show \(hiddenCount) more")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else if showAll, hiddenCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAll = false }
                } label: {
                    Text("Show less")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Row

    private func modelRow(_ item: AggregatedModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(modelColor(item.representativeModel))
                    .frame(width: 7, height: 7)

                Text(item.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 90, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.12))
                            .frame(height: 4)
                        Capsule()
                            .fill(modelColor(item.representativeModel).opacity(0.55))
                            .frame(width: max(2, geo.size.width * item.share), height: 4)
                    }
                }
                .frame(height: 4)

                Text(String(format: "$%.2f", item.cost))
                    .font(.caption2)
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)

                Text("\(Int((item.share * 100).rounded()))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .trailing)
            }

            // Cache stats
            if item.cacheRead > 0 || item.cacheWrite > 0 {
                HStack(spacing: 6) {
                    Color.clear.frame(width: 7)

                    if let hitRate = item.cacheHitRate {
                        Text("cache \(Int((hitRate * 100).rounded()))%")
                            .foregroundStyle(.green)
                    }

                    Text("R: \(formatTokens(item.cacheRead))")
                        .foregroundStyle(.secondary)

                    Text("W: \(formatTokens(item.cacheWrite))")
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .font(.system(size: 9))
                .padding(.leading, 5)
            }
        }
    }

    // MARK: - Formatting

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        } else if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.0fK", Double(value) / 1_000)
        }
        return "\(value)"
    }
}
