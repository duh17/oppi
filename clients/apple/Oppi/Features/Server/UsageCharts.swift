import Charts
import SwiftUI

// The three charts Usage draws. Swift Charts is SwiftUI-only, so each is a leaf that
// `UsageViewController` hosts through `UsageChartHost`: every input is a value
// (data, palette colors, fonts, a callback), and a leaf reads no `@Environment` of its
// own: it takes every value as a parameter. The screen, the lists, and every other
// control around them are UIKit.
//
// This is the framework-required Swift Charts file. It is the old `ModelBreakdownSection.swift`
// (its import-SwiftUI baseline entry moved here) now holding only the chart leaves that came
// out of the SwiftUI Usage views deleted with it (`ServerView`, `DailyDetailView`,
// `DailyCostChartView`, and the rest): six SwiftUI files became this one, a net drop of five.

/// The colors a chart leaf draws with, resolved from the theme's palette by the screen.
struct UsageChartColors: Equatable {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    /// A wash for an empty chart and the day tooltip.
    let washEmpty: Color
    let washTooltip: Color
    /// Changes with the theme, so the chart redraws when it does.
    let themeKey: String

    init(palette: ThemePalette, themeKey: String) {
        primary = Color(uiColor: palette.fg)
        secondary = Color(uiColor: palette.fgDim)
        tertiary = Color(uiColor: palette.comment)
        washEmpty = Color(uiColor: palette.comment.multiplyingAlpha(0.08))
        washTooltip = Color(uiColor: palette.comment.multiplyingAlpha(0.1))
        self.themeKey = themeKey
    }
}

/// The daily stacked bars (`StatsDailyChart`, shared with the Mac): tap a bar to pick a day.
struct UsageDailyChartLeaf: View {
    let daily: [StatsDailyEntry]
    let metric: StatsMetric
    let colors: UsageChartColors
    let onDaySelected: (String) -> Void

    var body: some View {
        StatsDailyChart(
            daily: daily,
            metric: metric,
            style: StatsDailyChartStyle(
                containerSpacing: 6,
                titleFont: .subheadline.weight(.semibold),
                titleColor: colors.primary,
                emptyCornerRadius: 6,
                emptyBackground: colors.washEmpty,
                emptyHeight: 240,
                emptyTextFont: .caption,
                emptyTextColor: colors.tertiary,
                chartHeight: 240,
                axisLabelFont: .caption2,
                axisLabelColor: colors.tertiary,
                tooltipSpacing: 6,
                tooltipPadding: 8,
                tooltipCornerRadius: 8,
                tooltipBackground: colors.washTooltip,
                tooltipTitleFont: .caption.weight(.semibold),
                tooltipTitleColor: colors.primary,
                tooltipRowSpacing: 8,
                providerGlyphSize: 11,
                providerGlyphColor: colors.tertiary,
                modelFont: .caption,
                providerFont: .caption2,
                valueFont: .caption,
                providerColor: colors.tertiary,
                valueColor: colors.tertiary
            ),
            onDaySelected: onDaySelected
        )
        .id(colors.themeKey)
    }
}

/// The identifiers of the slots that hold the chart leaves (semantic groups in the UIKit page).
enum UsageChartIdentifier {
    static let prefix = "server.usage.chart."
    static let daily = prefix + "daily"
    static let hourly = prefix + "hourly"
}

extension UIView {
    /// Makes this slot visible to the accessibility tree as a group with `identifier`, so its
    /// frame names the area a chart leaf's own nodes sit in.
    func markAsChartSlot(_ identifier: String) {
        accessibilityContainerType = .semanticGroup
        accessibilityIdentifier = identifier
    }
}

/// The models' share of the metric as a donut, hidden from accessibility: the page gives its
/// slot one element that speaks the shares (`UsageModel.donutSummary`). Its total is a UIKit
/// label over (or under) it, so the number follows Dynamic Type instead of shrinking into the ring.
struct UsageModelDonutLeaf: View {
    let models: [AggregatedStatsModel]
    let metric: StatsMetric
    let colors: UsageChartColors

    var body: some View {
        Chart(models) { item in
            SectorMark(
                angle: .value(metric.chartTitle, item.value(for: metric)),
                innerRadius: .ratio(0.6),
                angularInset: 1.5
            )
            .foregroundStyle(modelColor(item.representativeModel))
        }
        .chartLegend(.hidden)
        .frame(width: 140, height: 140)
        .frame(maxWidth: .infinity)
        .id(colors.themeKey)
        // One element for the whole ring is the page's (`UsageViewController`'s donut slot); the
        // model list below carries each slice, so the chart's per-slice nodes only add noise.
        .accessibilityHidden(true)
    }
}

/// One day's cost by hour, stacked by model.
struct UsageHourlyChartLeaf: View {
    let entries: [StatsHourlyCost]
    let colors: UsageChartColors

    var body: some View {
        Chart(entries) { entry in
            BarMark(
                x: .value("Hour", entry.hour),
                y: .value("Cost", entry.cost)
            )
            .foregroundStyle(modelColor(entry.model))
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(statsHourLabel(hour))
                            .font(.caption2)
                            .foregroundStyle(colors.tertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let cost = value.as(Double.self) {
                        Text(SessionFormatting.costString(cost))
                            .font(.caption2)
                            .foregroundStyle(colors.tertiary)
                    }
                }
            }
        }
        .chartXScale(domain: 0...23)
        .frame(height: 160)
        .id(colors.themeKey)
    }
}

// MARK: - Hosting

/// A chart leaf as UIKit. This file's one `UIHostingController` (allowed by
/// `scripts/uikit-structure-guard.ts`): the guard has no other hosting seam left.
/// It publishes no app environment; a leaf takes values only.
@MainActor
private final class UsageChartLeafHost<Leaf: View>: UIHostingController<Leaf> {
    init(_ leaf: Leaf) {
        super.init(rootView: leaf)
    }

    @available(*, unavailable)
    required init?(coder aDecoder: NSCoder) {
        return nil
    }

    /// New content for the same slot: the chart redraws with the new values.
    func show(_ leaf: Leaf) {
        rootView = leaf
    }
}

/// One chart leaf embedded in a UIKit slot: installed on first use, then given new
/// content as the data changes. The hosting view reports its own height (a daily chart
/// grows by a tooltip), so the stack around it re-lays out.
@MainActor
final class UsageChartHost<Leaf: View> {
    private var host: UsageChartLeafHost<Leaf>?

    func show(_ leaf: Leaf, in slot: UIView, parent: UIViewController) {
        if let host {
            host.show(leaf)
            return
        }
        let host = UsageChartLeafHost(leaf)
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        parent.addChild(host)
        slot.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: slot.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
        ])
        host.didMove(toParent: parent)
        self.host = host
    }
}
