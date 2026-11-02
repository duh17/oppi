import Charts
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Model colors and the shared daily chart
//
// The plain values these helpers read (model identity, the usage aggregations,
// the provider labels) live in ModelStatsValues.swift, which imports neither
// SwiftUI nor Charts. What stays here is the one Swift Charts leaf both
// platforms draw, the model colors, and the contrast rules its labels use.

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

    private static let monthAxisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yy"
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

    /// Days from the first to the last charted day. Past ~4 months (the 1y and
    /// All usage ranges) the axis labels months instead of days.
    private var spanDays: Int {
        let dates = chartData.map(\.date)
        guard let first = dates.min(), let last = dates.max() else { return 0 }
        return Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
    }

    private var xAxisValues: AxisMarkValues {
        let span = spanDays
        guard span > 120 else { return .stride(by: .day, count: axisStride) }
        return .stride(by: .month, count: span > 540 ? 3 : span > 240 ? 2 : 1)
    }

    private func xAxisLabel(_ date: Date) -> String {
        spanDays > 120
            ? Self.monthAxisFormatter.string(from: date)
            : Self.axisFormatter.string(from: date)
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
            .foregroundStyle(viewColor(modelColor(entry.model)))
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
            AxisMarks(values: xAxisValues) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xAxisLabel(date))
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
                    .foregroundStyle(viewColor(modelColor(entry.model)))
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

/// Shared model colors.
///
/// The base hue comes from the stable model family. Version numbers increase
/// saturation/brightness so newer stable versions read a bit louder without any
/// manual per-release updates. Provider does not affect the color.
///
/// Grok/xAI is the exception: the vendor mark is monochrome, so those models
/// stay gray and flip with the theme — near-white on dark, near-black on light.
///
/// The result is a `ThemeColor` (`UIColor` on iOS), so a UIKit call site paints
/// it as it is; a SwiftUI leaf, the `StatsDailyChart` and the Mac's model rows,
/// wraps it in `viewColor(_:)`.
func modelColor(_ model: String) -> ThemeColor {
    let identity = modelDisplayIdentity(model)
    let normalized = identity.normalizedModelID

    guard !normalized.isEmpty, normalized != "unknown", normalized != "other" else {
        return unknownModelColor
    }

    if normalized.contains("grok") {
        return grokModelColor(normalizedModelID: normalized)
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

    return srgbToken(hue: hue, saturation: saturation, brightness: brightness)
}

/// The color of a model the palette does not know: the platform's own secondary
/// content color, which is what `Color.secondary` resolved to on iOS.
private var unknownModelColor: ThemeColor {
    #if canImport(UIKit)
    .secondaryLabel
    #else
    .secondary
    #endif
}

/// An sRGB token from hue/saturation/brightness: the model colors' one
/// constructor, so both platforms build the same color.
private func srgbToken(hue: Double, saturation: Double, brightness: Double) -> ThemeColor {
    #if canImport(UIKit)
    UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    #else
    Color(hue: hue, saturation: saturation, brightness: brightness)
    #endif
}

/// A provider's logo or monogram at `size` for the SwiftUI chrome that draws it:
/// the `StatsDailyChart` tooltip on both platforms (inside Swift Charts, where
/// `EntityIcon`'s UIKit image cannot go) and the Mac's model rows.
struct ProviderGlyph: View {
    let provider: String?
    var size: CGFloat = 11
    var color: Color = .secondary

    var body: some View {
        let resolvedColor = viewColor(providerIconTint(themeToken(color)))

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
    var bg: ThemeColor { get }
    var bgDark: ThemeColor { get }
    var bgHighlight: ThemeColor { get }
    var fg: ThemeColor { get }
    var fgDim: ThemeColor { get }
}

private struct DefaultProviderIconTintPalette: ProviderIconTintPalette {
    let bg = ThemeColor.themeSRGB(0.08, 0.09, 0.11)
    let bgDark = ThemeColor.themeSRGB(0.05, 0.06, 0.07)
    let bgHighlight = ThemeColor.themeSRGB(0.14, 0.16, 0.19)
    let fg = ThemeColor.themeSRGB(0.86, 0.88, 0.90)
    let fgDim = ThemeColor.themeSRGB(0.62, 0.66, 0.70)
}

/// A theme token as the SwiftUI color a SwiftUI leaf draws with: the
/// `StatsDailyChart` on both platforms and the Mac's model rows. A UIKit call
/// site paints the token itself, so it converts nothing.
func viewColor(_ token: ThemeColor) -> Color {
    #if canImport(UIKit)
    Color(uiColor: token)
    #else
    token
    #endif
}

/// A SwiftUI color as the token type the contrast rules read. `ProviderGlyph`'s
/// callers hand it SwiftUI colors (the chart's style, a Mac theme token), and a
/// token is already a `Color` on the Mac.
func themeToken(_ color: Color) -> ThemeColor {
    #if canImport(UIKit)
    UIColor(color)
    #else
    color
    #endif
}

func providerIconTint(
    _ preferred: ThemeColor,
    palette: any ProviderIconTintPalette = DefaultProviderIconTintPalette(),
    minimumContrast: Double = 3.0
) -> ThemeColor {
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

func contrastRatio(between foreground: ThemeColor, and background: ThemeColor) -> Double? {
    guard let foreground = resolvedSRGB(foreground),
          let background = resolvedSRGB(background) else {
        return nil
    }
    return contrastRatio(between: foreground, and: background)
}

func minimumContrastRatio(of foreground: ThemeColor, on backgrounds: [ThemeColor]) -> Double? {
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

    var color: ThemeColor {
        #if canImport(UIKit)
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
        #else
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
        #endif
    }
}

private func modelFamilyKey(from normalizedModelID: String) -> String {
    let tokens = normalizedModelID.split(separator: "-").map(String.init)
    guard !tokens.isEmpty else { return normalizedModelID }

    var family: [String] = []
    for token in tokens {
        if isVersionToken(token) || ModelToken.isTimestamp(token) {
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

/// xAI's mark is black/white. Flagship Grok sits nearest the extreme; other
/// families step toward mid-gray. Newer versions move a bit closer to white
/// on dark themes and black on light themes.
private func grokModelColor(normalizedModelID: String) -> ThemeColor {
    let familyKey = modelFamilyKey(from: normalizedModelID)
    let familyStep = grokFamilyShadeStep(for: familyKey)
    let versionOffset = grokVersionBrightnessOffset(for: normalizedModelID)
    let variantOffset = grokVariantBrightnessOffset(for: normalizedModelID)

    let darkBrightness = clamp(
        0.82 + versionOffset + variantOffset - familyStep,
        lower: 0.64,
        upper: 0.98
    )
    let lightBrightness = clamp(
        0.22 - versionOffset - variantOffset + familyStep,
        lower: 0.08,
        upper: 0.40
    )

    return themeAdaptiveGray(darkBrightness: darkBrightness, lightBrightness: lightBrightness)
}

private func grokFamilyShadeStep(for familyKey: String) -> Double {
    if familyKey == "grok" {
        return 0
    }
    if familyKey.contains("code") {
        return 0.10
    }
    if familyKey.contains("vision") || familyKey.contains("image") || familyKey.contains("imagine") {
        return 0.16
    }

    let bucket = Int(stableHash(familyKey) % 3)
    return 0.08 + (Double(bucket) * 0.04)
}

private func grokVersionBrightnessOffset(for normalizedModelID: String) -> Double {
    let components = modelVersionComponents(from: normalizedModelID)
    var offset = 0.0
    if components.indices.contains(0) {
        offset += Double(min(components[0], 9)) * 0.006
    }
    if components.indices.contains(1) {
        offset += Double(min(components[1], 9)) * 0.018
    }
    if components.indices.contains(2) {
        offset += Double(min(components[2], 9)) * 0.008
    }
    return min(0.16, offset)
}

private func grokVariantBrightnessOffset(for normalizedModelID: String) -> Double {
    let tokens = Set(normalizedModelID.split(separator: "-").map(String.init))
    var offset = 0.0
    if !tokens.isDisjoint(with: ["mini", "nano", "lite", "flash", "small", "fast"]) {
        offset -= 0.06
    }
    if !tokens.isDisjoint(with: ["pro", "max", "ultra"]) {
        offset += 0.02
    }
    return offset
}

private func themeAdaptiveGray(darkBrightness: Double, lightBrightness: Double) -> ThemeColor {
    #if canImport(UIKit)
    return UIColor { traits in
        let brightness = traits.userInterfaceStyle == .light ? lightBrightness : darkBrightness
        return UIColor(hue: 0, saturation: 0, brightness: brightness, alpha: 1)
    }
    #elseif canImport(AppKit)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let isLight = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        let brightness = isLight ? lightBrightness : darkBrightness
        return NSColor(calibratedHue: 0, saturation: 0, brightness: brightness, alpha: 1)
    })
    #else
    return srgbToken(hue: 0, saturation: 0, brightness: darkBrightness)
    #endif
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
    guard !token.isEmpty, !ModelToken.isTimestamp(token) else { return false }
    let allowed = CharacterSet(charactersIn: "0123456789.")
    return token.unicodeScalars.allSatisfy { allowed.contains($0) }
}

private func resolvedSRGB(_ color: ThemeColor) -> SRGBColor? {
    #if canImport(UIKit)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
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
