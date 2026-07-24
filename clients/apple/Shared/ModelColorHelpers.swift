import Charts
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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

struct StatsDailyChartStyle {
    let containerSpacing: CGFloat
    let titleFont: Font
    let titleColor: Color
    let emptyCornerRadius: CGFloat
    let emptyBackground: Color
    let emptyHeight: CGFloat
    let emptyTextFont: Font
    let emptyTextColor: Color
    let chartHeight: CGFloat
    let axisLabelFont: Font
    let axisLabelColor: Color
    let tooltipSpacing: CGFloat
    let tooltipPadding: CGFloat
    let tooltipCornerRadius: CGFloat
    let tooltipBackground: Color
    let tooltipTitleFont: Font
    let tooltipTitleColor: Color
    let tooltipRowSpacing: CGFloat
    let providerGlyphSize: CGFloat
    let providerGlyphColor: Color
    let modelFont: Font
    let providerFont: Font
    let valueFont: Font
    let providerColor: Color
    let valueColor: Color
}

struct StatsDailyChart: View {
    let daily: [StatsDailyEntry]
    var metric: StatsMetric = .cost
    let style: StatsDailyChartStyle
    var onDaySelected: ((String) -> Void)?

    @State private var selectedDate: Date?

    private static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let dateStringFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var chartData: [StatsModelDayValue] {
        metric.modelDayValues(from: daily)
    }

    private var selectedDayData: [StatsModelDayValue] {
        guard let selectedDate else { return [] }
        return chartData
            .filter { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }
            .sorted { $0.value > $1.value }
    }

    private var axisStride: Int {
        let count = daily.count
        if count <= 7 { return 1 }
        if count <= 14 { return 2 }
        if count <= 30 { return 7 }
        return 14
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.containerSpacing) {
            Text(metric.chartTitle)
                .font(style.titleFont)
                .foregroundStyle(style.titleColor)

            if chartData.isEmpty {
                emptyPlaceholder
            } else {
                chartView
                if !selectedDayData.isEmpty {
                    tooltipView
                        .transition(.opacity)
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        RoundedRectangle(cornerRadius: style.emptyCornerRadius)
            .fill(style.emptyBackground)
            .frame(height: style.emptyHeight)
            .overlay {
                Text("No data for this range")
                    .font(style.emptyTextFont)
                    .foregroundStyle(style.emptyTextColor)
            }
    }

    private func isSelected(_ entry: StatsModelDayValue) -> Bool {
        guard let selectedDate else { return false }
        return Calendar.current.isDate(entry.date, inSameDayAs: selectedDate)
    }

    @ViewBuilder
    private var chartView: some View {
        Chart(chartData) { entry in
            BarMark(
                x: .value("Date", entry.date, unit: .day),
                y: .value(metric.chartTitle, entry.value)
            )
            .foregroundStyle(modelColor(entry.model))
            .opacity(selectedDate == nil || isSelected(entry) ? 1.0 : 0.3)
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        let plotOrigin = geo[plotFrame].origin
                        let x = location.x - plotOrigin.x
                        guard let tappedDate: Date = proxy.value(atX: x) else { return }

                        if let current = selectedDate,
                           Calendar.current.isDate(current, inSameDayAs: tappedDate) {
                            selectedDate = nil
                        } else {
                            selectedDate = tappedDate
                            onDaySelected?(Self.dateStringFormatter.string(from: tappedDate))
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: selectedDate)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: axisStride)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.axisFormatter.string(from: date))
                            .font(style.axisLabelFont)
                            .foregroundStyle(style.axisLabelColor)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(metric.axisLabel(v))
                            .font(style.axisLabelFont)
                            .foregroundStyle(style.axisLabelColor)
                    }
                }
            }
        }
        .frame(height: style.chartHeight)
    }

    private var tooltipView: some View {
        VStack(alignment: .leading, spacing: style.tooltipSpacing) {
            if let first = selectedDayData.first {
                Text(Self.axisFormatter.string(from: first.date))
                    .font(style.tooltipTitleFont)
                    .foregroundStyle(style.tooltipTitleColor)
            }
            ForEach(selectedDayData) { entry in
                tooltipRow(for: entry)
            }
        }
        .padding(style.tooltipPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.tooltipBackground, in: RoundedRectangle(cornerRadius: style.tooltipCornerRadius))
    }

    private func tooltipRow(for entry: StatsModelDayValue) -> some View {
        HStack(spacing: style.tooltipRowSpacing) {
            ProviderGlyph(provider: modelProviderKey(entry.model), size: style.providerGlyphSize, color: style.providerGlyphColor)

            VStack(alignment: .leading, spacing: 0) {
                Text(displayModelName(entry.model))
                    .font(style.modelFont)
                    .foregroundStyle(modelColor(entry.model))
                    .lineLimit(1)

                if let provider = modelProviderLabel(entry.model) {
                    Text(provider)
                        .font(style.providerFont)
                        .foregroundStyle(style.providerColor)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(metric.displayValue(entry.value))
                .font(style.valueFont)
                .monospacedDigit()
                .foregroundStyle(style.valueColor)
        }
    }
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

/// Shared model colors.
///
/// The base hue comes from the stable model family. Version numbers increase
/// saturation/brightness so newer stable versions read a bit louder without any
/// manual per-release updates. Provider does not affect the color.
func modelColor(_ model: String) -> Color {
    let identity = modelDisplayIdentity(model)
    let normalized = identity.normalizedModelID

    guard !normalized.isEmpty, normalized != "unknown", normalized != "other" else {
        return .secondary
    }

    let familyKey = modelFamilyKey(from: normalized)
    let baseHue = baseHue(for: familyKey, normalizedModelID: normalized)
    let salience = versionSalience(for: normalized)
    let adjustment = variantAdjustment(for: normalized)
    let versionHueOffset = versionColorHueOffset(for: normalized)
    let variantSeedOffset = variantSeedHueOffset(for: normalized, familyKey: familyKey)

    let hue = wrappedHue(baseHue + versionHueOffset + variantSeedOffset + adjustment.hue)
    let saturation = clamp(0.58 + (salience * 1.15) + adjustment.saturation, lower: 0.44, upper: 0.96)
    let brightness = clamp(0.68 + (salience * 1.05) + adjustment.brightness, lower: 0.54, upper: 0.98)

    return Color(hue: hue, saturation: saturation, brightness: brightness)
}

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

func modelAggregationKey(_ model: String?) -> String {
    modelDisplayIdentity(model).aggregationKey
}

func providerDisplayLabel(_ provider: String?) -> String {
    guard let provider = normalizedProviderKey(provider), !provider.isEmpty else {
        return "Unknown"
    }

    if let label = knownProviderDisplayNames[provider] {
        return label
    }

    let canonical = canonicalProviderBrandKey(provider)
    if let label = knownProviderDisplayNames[canonical] {
        return label
    }

    return humanizedProviderName(provider)
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
    case "openai", "azure-openai-responses": return "O"
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
    case "vercel-ai-gateway": return "V"
    case "lmstudio": return "L"
    case "omlx", "ollama", "opencode": return "O"
    default:
        return provider.first.map { String($0).uppercased() } ?? "?"
    }
}

struct ProviderGlyph: View {
    let provider: String?
    var size: CGFloat = 11
    var color: Color = .secondary

    var body: some View {
        let resolvedColor = providerIconTint(color)

        Group {
            if let provider = normalizedProviderKey(provider) {
                if let assetName = providerLogoAssetName(provider) {
                    Image(assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(resolvedColor)
                } else {
                    Text(providerMonogram(provider))
                        .font(.system(size: max(8, size * 0.8), weight: .heavy, design: .rounded))
                        .foregroundStyle(resolvedColor)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size, alignment: .center)
    }
}

protocol ProviderIconTintPalette {
    var bg: Color { get }
    var bgDark: Color { get }
    var bgHighlight: Color { get }
    var fg: Color { get }
    var fgDim: Color { get }
}

private struct DefaultProviderIconTintPalette: ProviderIconTintPalette {
    let bg = Color(red: 0.08, green: 0.09, blue: 0.11)
    let bgDark = Color(red: 0.05, green: 0.06, blue: 0.07)
    let bgHighlight = Color(red: 0.14, green: 0.16, blue: 0.19)
    let fg = Color(red: 0.86, green: 0.88, blue: 0.90)
    let fgDim = Color(red: 0.62, green: 0.66, blue: 0.70)
}

func providerIconTint(
    _ preferred: Color,
    palette: any ProviderIconTintPalette = DefaultProviderIconTintPalette(),
    minimumContrast: Double = 3.0
) -> Color {
    let backgrounds = [palette.bg, palette.bgDark, palette.bgHighlight]
    let fallbackCandidates = [palette.fg, palette.fgDim, palette.bgDark]

    guard let preferredComponents = resolvedSRGB(preferred) else {
        return preferred
    }

    let resolvedBackgrounds = backgrounds.compactMap(resolvedSRGB)
    guard resolvedBackgrounds.count == backgrounds.count else {
        return preferred
    }

    if minimumContrastRatio(of: preferred, on: backgrounds) ?? 0 >= minimumContrast {
        return preferred
    }

    let resolvedFallbacks = fallbackCandidates.compactMap(resolvedSRGB)
    let bestFallback = resolvedFallbacks.max { lhs, rhs in
        minimumContrastRatio(of: lhs, on: resolvedBackgrounds) < minimumContrastRatio(of: rhs, on: resolvedBackgrounds)
    }

    guard let bestFallback else {
        return preferred
    }

    var bestCandidate = preferredComponents
    var bestScore = minimumContrastRatio(of: preferredComponents, on: resolvedBackgrounds)

    for amount in stride(from: 0.16, through: 1.0, by: 0.12) {
        let candidate = mix(preferredComponents, bestFallback, amount: amount)
        let score = minimumContrastRatio(of: candidate, on: resolvedBackgrounds)
        if score > bestScore {
            bestScore = score
            bestCandidate = candidate
        }
        if score >= minimumContrast {
            return candidate.color
        }
    }

    return bestCandidate.color
}

func contrastRatio(between foreground: Color, and background: Color) -> Double? {
    guard let foreground = resolvedSRGB(foreground),
          let background = resolvedSRGB(background) else {
        return nil
    }
    return contrastRatio(between: foreground, and: background)
}

func minimumContrastRatio(of foreground: Color, on backgrounds: [Color]) -> Double? {
    let resolvedBackgrounds = backgrounds.compactMap(resolvedSRGB)
    guard let foreground = resolvedSRGB(foreground),
          resolvedBackgrounds.count == backgrounds.count else {
        return nil
    }
    return minimumContrastRatio(of: foreground, on: resolvedBackgrounds)
}

private struct ModelColorAdjustment {
    var hue: Double = 0
    var saturation: Double = 0
    var brightness: Double = 0
}

private struct SRGBColor {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

private func cleanedModelDisplayName(from model: String) -> String {
    let raw = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return "unknown" }

    let last = String(raw.split(separator: "/").last ?? Substring(raw))
    let withoutClaudePrefix = last.replacingOccurrences(of: "claude-", with: "")
    let parts = withoutClaudePrefix.split(separator: "-")

    if let tail = parts.last, isTimestampToken(String(tail)) {
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

private func normalizedProviderKey(_ provider: String?) -> String? {
    guard let provider else { return nil }
    let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.isEmpty ? nil : normalized
}

private func normalizedProviderKey(from model: String) -> String? {
    let parts = model.split(separator: "/", maxSplits: 1)
    guard parts.count >= 2 else { return nil }
    return normalizedProviderKey(String(parts[0]))
}

private func canonicalProviderBrandKey(_ provider: String) -> String {
    providerAliases[provider] ?? provider
}

private func humanizedProviderName(_ provider: String) -> String {
    let tokens = provider.split(whereSeparator: { $0 == "-" || $0 == "_" })
    return tokens
        .map { token in
            let value = String(token)
            if acronymProviderTokens.contains(value) {
                return value.uppercased()
            }
            return value.prefix(1).uppercased() + value.dropFirst()
        }
        .joined(separator: " ")
}

private func modelFamilyKey(from normalizedModelID: String) -> String {
    let tokens = normalizedModelID.split(separator: "-").map(String.init)
    guard !tokens.isEmpty else { return normalizedModelID }

    var family: [String] = []
    for token in tokens {
        if isVersionToken(token) || isTimestampToken(token) {
            break
        }
        if !family.isEmpty, variantTokens.contains(token) {
            break
        }
        family.append(token)
    }

    if family.isEmpty {
        return tokens[0]
    }

    return family.joined(separator: "-")
}

private func baseHue(for familyKey: String, normalizedModelID: String) -> Double {
    if normalizedModelID.hasPrefix("gpt") || normalizedModelID.hasPrefix("o1") || normalizedModelID.hasPrefix("o3") || normalizedModelID.hasPrefix("o4") || normalizedModelID.contains("codex") {
        return 0.36
    }
    if normalizedModelID.contains("sonnet") || normalizedModelID.contains("opus") || normalizedModelID.contains("haiku") || normalizedModelID.contains("claude") {
        // Anthropic/Claude should stay in the warm clay-orange band. Letting
        // version offsets push Sonnet 4.6 toward yellow-green made the Server
        // tab hard to read on the light theme.
        return 0.055
    }
    if normalizedModelID.contains("deepseek") {
        return 0.58
    }
    if normalizedModelID.contains("gemini") {
        return 0.55
    }
    if normalizedModelID.contains("glm") {
        return 0.52
    }
    if normalizedModelID.contains("grok") {
        return 0.14
    }
    if normalizedModelID.contains("mistral") || normalizedModelID.contains("magistral") {
        return 0.0
    }
    if normalizedModelID.contains("llama") {
        return 0.74
    }

    let anchors: [Double] = [0.0, 0.08, 0.14, 0.22, 0.32, 0.40, 0.52, 0.60, 0.72, 0.82]
    let index = Int(stableHash(familyKey) % UInt64(anchors.count))
    return anchors[index]
}

private func versionSalience(for normalizedModelID: String) -> Double {
    let components = modelVersionComponents(from: normalizedModelID)
    let weights: [Double] = [0.008, 0.028, 0.010]

    var salience = 0.0
    for (index, component) in components.enumerated() where index < weights.count {
        salience += Double(min(component, 9)) * weights[index]
    }
    return min(0.24, salience)
}

private func versionColorHueOffset(for normalizedModelID: String) -> Double {
    let components = modelVersionComponents(from: normalizedModelID)
    guard !components.isEmpty else { return 0 }

    var offset = 0.0
    if components.indices.contains(0) {
        offset += Double((components[0] % 5) - 2) * 0.012
    }
    if components.indices.contains(1) {
        offset += Double((components[1] % 7) - 3) * 0.030
    }
    if components.indices.contains(2) {
        offset += Double((components[2] % 5) - 2) * 0.012
    }

    if normalizedModelID.contains("sonnet") || normalizedModelID.contains("opus") || normalizedModelID.contains("haiku") || normalizedModelID.contains("claude") {
        return clamp(offset, lower: -0.03, upper: 0.03)
    }

    return clamp(offset, lower: -0.10, upper: 0.10)
}

private func variantSeedHueOffset(for normalizedModelID: String, familyKey: String) -> Double {
    let suffix = normalizedModelID
        .replacingOccurrences(of: familyKey, with: "", options: [.anchored])
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

    guard !suffix.isEmpty else { return 0 }
    let bucket = Double(Int(stableHash(suffix) % 5) - 2)
    return bucket * 0.009
}

private func modelVersionComponents(from normalizedModelID: String) -> [Int] {
    let tokens = normalizedModelID.split(separator: "-").map(String.init)
    var components: [Int] = []

    for token in tokens {
        let tokenComponents = versionComponents(in: token)
        if !tokenComponents.isEmpty {
            components.append(contentsOf: tokenComponents)
        }
    }

    return components
}

private func variantAdjustment(for normalizedModelID: String) -> ModelColorAdjustment {
    let tokens = Set(normalizedModelID.split(separator: "-").map(String.init))
    var adjustment = ModelColorAdjustment()

    if !tokens.isDisjoint(with: ["mini", "nano", "lite", "flash", "small"]) {
        adjustment.saturation -= 0.14
        adjustment.brightness += 0.04
    }

    if !tokens.isDisjoint(with: ["codex", "coder"]) {
        adjustment.hue += 0.045
        adjustment.saturation += 0.08
        adjustment.brightness -= 0.03
    }

    if !tokens.isDisjoint(with: ["pro", "max", "ultra", "opus"]) {
        adjustment.saturation += 0.04
        adjustment.brightness -= 0.01
    }

    if !tokens.isDisjoint(with: ["preview", "experimental", "beta"] ) {
        adjustment.saturation += 0.03
        adjustment.brightness += 0.02
    }

    return adjustment
}

private func versionComponents(in token: String) -> [Int] {
    var candidate = token
    if token.count > 1, token.first == "v" {
        let remainder = String(token.dropFirst())
        if isVersionToken(remainder) {
            candidate = remainder
        }
    }

    guard isVersionToken(candidate) else {
        return []
    }

    return candidate
        .split(separator: ".")
        .compactMap { Int($0) }
}

private func isVersionToken(_ token: String) -> Bool {
    guard !token.isEmpty, !isTimestampToken(token) else { return false }
    let allowed = CharacterSet(charactersIn: "0123456789.")
    return token.unicodeScalars.allSatisfy { allowed.contains($0) }
}

private func isTimestampToken(_ token: String) -> Bool {
    token.count >= 8 && token.allSatisfy(\.isNumber)
}

private func resolvedSRGB(_ color: Color) -> SRGBColor? {
    #if canImport(UIKit)
    let uiColor = UIColor(color)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return nil
    }
    return SRGBColor(red: red, green: green, blue: blue, alpha: alpha)
    #elseif canImport(AppKit)
    let nsColor = NSColor(color)
    guard let converted = nsColor.usingColorSpace(.sRGB) else {
        return nil
    }
    return SRGBColor(
        red: converted.redComponent,
        green: converted.greenComponent,
        blue: converted.blueComponent,
        alpha: converted.alphaComponent
    )
    #else
    return nil
    #endif
}

private func minimumContrastRatio(of foreground: SRGBColor, on backgrounds: [SRGBColor]) -> Double {
    backgrounds
        .map { contrastRatio(between: foreground, and: $0) }
        .min() ?? 0
}

private func contrastRatio(between foreground: SRGBColor, and background: SRGBColor) -> Double {
    let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
    let darker = min(relativeLuminance(foreground), relativeLuminance(background))
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(_ color: SRGBColor) -> Double {
    0.2126 * linearize(color.red) + 0.7152 * linearize(color.green) + 0.0722 * linearize(color.blue)
}

private func linearize(_ component: Double) -> Double {
    if component <= 0.03928 {
        return component / 12.92
    }
    return pow((component + 0.055) / 1.055, 2.4)
}

private func mix(_ source: SRGBColor, _ target: SRGBColor, amount: Double) -> SRGBColor {
    SRGBColor(
        red: source.red + ((target.red - source.red) * amount),
        green: source.green + ((target.green - source.green) * amount),
        blue: source.blue + ((target.blue - source.blue) * amount),
        alpha: source.alpha + ((target.alpha - source.alpha) * amount)
    )
}

private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func wrappedHue(_ hue: Double) -> Double {
    let wrapped = hue.truncatingRemainder(dividingBy: 1)
    return wrapped >= 0 ? wrapped : wrapped + 1
}

private func stableHash(_ text: String) -> UInt64 {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

private let variantTokens: Set<String> = [
    "beta",
    "codex",
    "coder",
    "experimental",
    "flash",
    "lite",
    "max",
    "mini",
    "nano",
    "preview",
    "pro",
    "small",
    "ultra",
]

private let providerAliases: [String: String] = [
    "openai-codex": "openai",
    "google-gemini-cli": "google",
    "google-antigravity": "google",
    "minimax-cn": "minimax",
    "opencode-go": "opencode",
]

private let providersWithLogoAsset: Set<String> = [
    "anthropic",
    "cerebras",
    "deepseek",
    "ds4",
    "fireworks",
    "github-copilot",
    "huggingface",
    "kimi-coding",
    "minimax",
    "mistral",
    "omlx",
    "openai",
    "openrouter",
    "vercel-ai-gateway",
    "xai",
    "zai",
]

private let knownProviderDisplayNames: [String: String] = [
    "amazon-bedrock": "Amazon Bedrock",
    "anthropic": "Anthropic",
    "azure-openai-responses": "Azure OpenAI",
    "cerebras": "Cerebras",
    "deepseek": "DeepSeek",
    "ds4": "DS4 Dwarf Star",
    "github-copilot": "GitHub Copilot",
    "google": "Google",
    "google-antigravity": "Google Antigravity",
    "google-gemini-cli": "Gemini CLI",
    "google-vertex": "Google Vertex AI",
    "groq": "Groq",
    "huggingface": "Hugging Face",
    "kimi-coding": "Kimi Coding",
    "lmstudio": "LM Studio",
    "minimax": "MiniMax",
    "minimax-cn": "MiniMax CN",
    "ollama": "Ollama",
    "omlx": "OMLX",
    "mistral": "Mistral",
    "openai": "OpenAI",
    "openai-codex": "OpenAI Codex",
    "opencode": "OpenCode",
    "opencode-go": "OpenCode Go",
    "openrouter": "OpenRouter",
    "vercel-ai-gateway": "Vercel AI Gateway",
    "xai": "xAI",
    "zai": "Z.AI",
]

private let acronymProviderTokens: Set<String> = ["ai", "api", "cli", "cn", "llm", "ml"]
