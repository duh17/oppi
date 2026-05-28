import SwiftUI

struct DailyCostChartView: View {
    let daily: [StatsDailyEntry]

    /// Which metric to chart. Defaults to cost.
    var metric: StatsMetric = .cost

    /// Called when the user selects a day (date string "YYYY-MM-DD").
    var onDaySelected: ((String) -> Void)?

    var body: some View {
        StatsDailyChart(
            daily: daily,
            metric: metric,
            style: Self.style,
            onDaySelected: onDaySelected
        )
    }

    private static let style = StatsDailyChartStyle(
        containerSpacing: 6,
        titleFont: .subheadline.weight(.semibold),
        titleColor: .themeFg,
        emptyCornerRadius: 6,
        emptyBackground: Color.themeComment.opacity(0.08),
        emptyHeight: 240,
        emptyTextFont: .caption,
        emptyTextColor: .themeComment,
        chartHeight: 240,
        axisLabelFont: .caption2,
        axisLabelColor: .themeComment,
        tooltipSpacing: 6,
        tooltipPadding: 8,
        tooltipCornerRadius: 8,
        tooltipBackground: Color.themeComment.opacity(0.1),
        tooltipTitleFont: .caption.weight(.semibold),
        tooltipTitleColor: .themeFg,
        tooltipRowSpacing: 8,
        providerGlyphSize: 11,
        providerGlyphColor: .themeComment,
        modelFont: .caption,
        providerFont: .caption2,
        valueFont: .caption,
        providerColor: .themeComment,
        valueColor: .themeComment
    )
}
