import Foundation

// The plain values behind the stats and model surfaces: model identity, the
// usage aggregations, and the provider labels and monograms. No SwiftUI and no
// Charts, so a UIKit screen reads them without the chart framework; the chart
// leaves and the model colors stay in ModelColorHelpers.swift.

// MARK: - Shared model presentation helpers

/// Shared model presentation helpers used by iOS and macOS stats surfaces.
///
/// Colors are derived from the stable model id, not the provider, so the same
/// model keeps the same color even when served through different providers.
struct ModelDisplayIdentity: Equatable {
    let provider: String?
    let providerDisplayName: String?
    let displayName: String
    let normalizedModelID: String

    /// Provider stays part of the grouping key so the UI can show provider and
    /// model separately without collapsing different providers together.
    var aggregationKey: String {
        let providerKey = provider ?? "unknown"
        return "\(providerKey)/\(normalizedModelID)"
    }
}

func modelDisplayIdentity(_ model: String?) -> ModelDisplayIdentity {
    let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let provider = normalizedProviderKey(from: raw)
    let displayName = cleanedModelDisplayName(from: raw)

    return ModelDisplayIdentity(
        provider: provider,
        providerDisplayName: provider.map(providerDisplayLabel),
        displayName: displayName,
        normalizedModelID: normalizedStableModelID(from: raw)
    )
}

extension StatsMetric {
    /// Aggregate by provider + stable model id so timestamp-only variants merge.
    func modelDayValues(from daily: [StatsDailyEntry]) -> [StatsModelDayValue] {
        var result: [StatsModelDayValue] = []
        for entry in daily {
            guard let date = StatsModelDayValue.dateParser.date(from: entry.date) else { continue }
            if let byModel = entry.byModel, !byModel.isEmpty {
                var byIdentity: [String: (raw: String, sortKey: String, value: Double)] = [:]
                for (model, data) in byModel {
                    let value = value(from: data)
                    guard value > 0 else { continue }
                    let identity = modelDisplayIdentity(model)
                    let key = identity.aggregationKey
                    let sortKey = "\(identity.displayName)|\(identity.providerDisplayName ?? "")"
                    if let existing = byIdentity[key] {
                        byIdentity[key] = (existing.raw, existing.sortKey, existing.value + value)
                    } else {
                        byIdentity[key] = (model, sortKey, value)
                    }
                }
                for (_, item) in byIdentity.sorted(by: { $0.value.sortKey < $1.value.sortKey }) {
                    result.append(StatsModelDayValue(date: date, model: item.raw, value: item.value))
                }
            } else {
                let value = value(from: entry)
                if value > 0 {
                    result.append(StatsModelDayValue(date: date, model: "other", value: value))
                }
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}

// MARK: - Shared stats aggregations

/// Hourly per-model cost used by the iOS, iPad, and Mac daily drill-down views.
struct StatsHourlyCost: Identifiable {
    let hour: Int
    let model: String
    let cost: Double

    var id: String { "\(hour)-\(model)" }
}

extension DailyDetail {
    var displayDayTitle: String {
        guard let date = StatsDailyDetailFormatters.dateParser.date(from: self.date) else {
            return self.date
        }
        return StatsDailyDetailFormatters.dayFormatter.string(from: date)
    }

    var hourlyCostValues: [StatsHourlyCost] {
        var result: [StatsHourlyCost] = []
        for entry in hourly {
            if let byModel = entry.byModel, !byModel.isEmpty {
                var byIdentity: [String: (raw: String, sortKey: String, cost: Double)] = [:]
                for (model, data) in byModel where data.cost > 0 {
                    let identity = modelDisplayIdentity(model)
                    let key = identity.aggregationKey
                    let sortKey = "\(identity.displayName)|\(identity.providerDisplayName ?? "")"
                    if let existing = byIdentity[key] {
                        byIdentity[key] = (existing.raw, existing.sortKey, existing.cost + data.cost)
                    } else {
                        byIdentity[key] = (model, sortKey, data.cost)
                    }
                }
                for (_, value) in byIdentity.sorted(by: { $0.value.sortKey < $1.value.sortKey }) {
                    result.append(StatsHourlyCost(hour: entry.hour, model: value.raw, cost: value.cost))
                }
            } else if entry.cost > 0 {
                result.append(StatsHourlyCost(hour: entry.hour, model: "other", cost: entry.cost))
            }
        }
        return result.sorted { $0.hour < $1.hour }
    }
}

func statsHourLabel(_ hour: Int) -> String {
    if hour == 0 { return "12a" }
    if hour < 12 { return "\(hour)a" }
    if hour == 12 { return "12p" }
    return "\(hour - 12)p"
}

func statsTimeLabel(epochMilliseconds: Double) -> String {
    let date = Date(timeIntervalSince1970: epochMilliseconds / 1000)
    return StatsDailyDetailFormatters.timeFormatter.string(from: date)
}

private enum StatsDailyDetailFormatters {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    static let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

/// Model stats deduped by provider + stable model id.
struct AggregatedStatsModel: Identifiable, Equatable {
    let aggregationKey: String
    let displayName: String
    let provider: String?
    let providerDisplayName: String?
    /// Any raw model name from this group, used for stable color lookup.
    let representativeModel: String
    let sessions: Int
    let cost: Double
    let tokens: Int
    let inputTokens: Int
    let cacheRead: Int
    /// nil when the provider has no cache-write counter (for example xAI Grok).
    let cacheWrite: Int?
    var share: Double

    var id: String { aggregationKey }

    func value(for metric: StatsMetric) -> Double {
        switch metric {
        case .sessions: return Double(sessions)
        case .cost: return cost
        case .tokens: return Double(tokens)
        }
    }

    /// Prompt-cache effectiveness: cacheRead / (cacheRead + uncachedInput + cacheWrite).
    /// Excludes output tokens, but counts cache writes against the total.
    /// Unsupported write counters (nil) contribute 0 to the denominator.
    var cacheRate: Double? {
        computePromptCacheRate(
            cacheRead: cacheRead,
            inputTokens: inputTokens,
            cacheWrite: cacheWrite ?? 0
        )
    }
}

func aggregateStatsModels(
    _ breakdown: [StatsModelBreakdown],
    sortedBy metric: StatsMetric = .cost
) -> [AggregatedStatsModel] {
    var byKey: [String: AggregatedStatsModel] = [:]

    for item in breakdown {
        let identity = modelDisplayIdentity(item.model)
        let key = identity.aggregationKey
        let cacheRead = item.cacheRead ?? 0
        let cacheWrite = item.cacheWrite
        let inputTokens = item.inputTokens

        if let existing = byKey[key] {
            byKey[key] = AggregatedStatsModel(
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
                cacheWrite: mergeOptionalTokenCounts(existing.cacheWrite, cacheWrite),
                share: existing.share + item.share
            )
        } else {
            byKey[key] = AggregatedStatsModel(
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

    return byKey.values.sorted { lhs, rhs in
        let lhsValue = lhs.value(for: metric)
        let rhsValue = rhs.value(for: metric)
        if lhsValue != rhsValue {
            return lhsValue > rhsValue
        }
        if lhs.cost != rhs.cost {
            return lhs.cost > rhs.cost
        }
        if lhs.displayName != rhs.displayName {
            return lhs.displayName < rhs.displayName
        }
        return (lhs.providerDisplayName ?? "") < (rhs.providerDisplayName ?? "")
    }
}

extension Array where Element == AggregatedStatsModel {
    func nonZeroStatsModels(for metric: StatsMetric) -> [AggregatedStatsModel] {
        filter { item in
            switch metric {
            case .cost: return item.cost > 0.005
            case .sessions, .tokens: return item.value(for: metric) > 0
            }
        }
    }
}

// MARK: - Model labels

/// Shorten model names for display.
/// `anthropic/claude-sonnet-4-6-20250514` → `sonnet-4-6`
func displayModelName(_ model: String) -> String {
    modelDisplayIdentity(model).displayName
}

func modelProviderKey(_ model: String?) -> String? {
    modelDisplayIdentity(model).provider
}

func modelProviderLabel(_ model: String?) -> String? {
    modelDisplayIdentity(model).providerDisplayName
}

func providerLogoAssetName(_ provider: String?) -> String? {
    guard let provider = normalizedProviderKey(provider), !provider.isEmpty else {
        return nil
    }

    let canonical = canonicalProviderBrandKey(provider)
    guard providersWithLogoAsset.contains(canonical) else {
        return nil
    }
    return "provider-\(canonical)"
}

func providerMonogram(_ provider: String?) -> String {
    guard let provider = normalizedProviderKey(provider), !provider.isEmpty else {
        return "?"
    }

    switch canonicalProviderBrandKey(provider) {
    case "anthropic": return "A"
    case "openai", "azure": return "O"
    case "google", "google-vertex": return "G"
    case "deepseek", "ds4": return "D"
    case "openrouter": return "R"
    case "amazon-bedrock": return "B"
    case "mistral", "minimax": return "M"
    case "xai": return "X"
    case "zai": return "Z"
    case "github-copilot", "cerebras": return "C"
    case "groq": return "Q"
    case "huggingface": return "H"
    case "kimi-coding": return "K"
    case "qwen": return "Q"
    case "vercel-ai-gateway": return "V"
    case "lmstudio": return "L"
    case "omlx", "ollama", "opencode": return "O"
    default:
        return provider.first.map { String($0).uppercased() } ?? "?"
    }
}

// MARK: - Model identity parsing

private func cleanedModelDisplayName(from model: String) -> String {
    let raw = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "unknown" }

    let last = String(raw.split(separator: "/").last ?? Substring(raw))
    let withoutClaudePrefix = last.replacingOccurrences(of: "claude-", with: "")
    let parts = withoutClaudePrefix.split(separator: "-")

    if let tail = parts.last, ModelToken.isTimestamp(String(tail)) {
        let cleaned = parts.dropLast().joined(separator: "-")
        return cleaned.isEmpty ? withoutClaudePrefix : cleaned
    }

    return withoutClaudePrefix
}

private func normalizedStableModelID(from model: String) -> String {
    cleanedModelDisplayName(from: model)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

private func normalizedProviderKey(from model: String) -> String? {
    let parts = model.split(separator: "/", maxSplits: 1)
    guard parts.count >= 2 else { return nil }
    return normalizedProviderKey(String(parts[0]))
}

/// Rules for reading a model id. Both the label parser here and the color
/// family key in `ModelColorHelpers` read them.
enum ModelToken {
    /// A trailing all-digit run of 8 or more is a release timestamp, not a
    /// version.
    static func isTimestamp(_ token: String) -> Bool {
        token.count >= 8 && token.allSatisfy(\.isNumber)
    }
}

private let providersWithLogoAsset: Set<String> = [
    "anthropic",
    "cerebras",
    "cursor",
    "deepseek",
    "ds4",
    "fireworks",
    "github-copilot",
    "google",
    "huggingface",
    "kimi-coding",
    "lmstudio",
    "meta",
    "minimax",
    "mistral",
    "mlx-serve",
    "ollama",
    "omlx",
    "openai",
    "opencode",
    "openrouter",
    "qwen",
    "vercel-ai-gateway",
    "xai",
    "zai",
]
