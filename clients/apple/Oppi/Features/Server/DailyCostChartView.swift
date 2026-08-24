import SwiftUI

struct DailyCostChartView: View {
    let daily: [StatsDailyEntry]

    /// Which metric to chart. Defaults to cost.
    var metric: StatsMetric = .cost

    /// Called when the user selects a day (date string "YYYY-MM-DD").
    var onDaySelected: ((String) -> Void)?

    @Environment(\.theme) private var theme
    @Environment(\.themeID) private var themeID

    var body: some View {
        StatsDailyChart(
            daily: daily,
            metric: metric,
            style: style,
            onDaySelected: onDaySelected
        )
        .id(themeID)
    }

    private var style: StatsDailyChartStyle {
        StatsDailyChartStyle(
            containerSpacing: 6,
            titleFont: .subheadline.weight(.semibold),
            titleColor: theme.text.primary,
            emptyCornerRadius: 6,
            emptyBackground: theme.text.tertiary.opacity(0.08),
            emptyHeight: 240,
            emptyTextFont: .caption,
            emptyTextColor: theme.text.tertiary,
            chartHeight: 240,
            axisLabelFont: .caption2,
            axisLabelColor: theme.text.tertiary,
            tooltipSpacing: 6,
            tooltipPadding: 8,
            tooltipCornerRadius: 8,
            tooltipBackground: theme.text.tertiary.opacity(0.1),
            tooltipTitleFont: .caption.weight(.semibold),
            tooltipTitleColor: theme.text.primary,
            tooltipRowSpacing: 8,
            providerGlyphSize: 11,
            providerGlyphColor: theme.text.tertiary,
            modelFont: .caption,
            providerFont: .caption2,
            valueFont: .caption,
            providerColor: theme.text.tertiary,
            valueColor: theme.text.tertiary
        )
    }
}
