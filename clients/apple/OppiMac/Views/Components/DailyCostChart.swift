import SwiftUI

struct DailyCostChart: View {
    let daily: [StatsDailyEntry]
    var metric: StatsMetric = .cost
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
        containerSpacing: 4,
        titleFont: .caption,
        titleColor: .secondary,
        emptyCornerRadius: 4,
        emptyBackground: Color.secondary.opacity(0.08),
        emptyHeight: 180,
        emptyTextFont: .caption2,
        emptyTextColor: Color(nsColor: .tertiaryLabelColor),
        chartHeight: 180,
        axisLabelFont: .system(size: 9),
        axisLabelColor: .secondary,
        tooltipSpacing: 4,
        tooltipPadding: 6,
        tooltipCornerRadius: 6,
        tooltipBackground: Color.secondary.opacity(0.1),
        tooltipTitleFont: .caption2.weight(.semibold),
        tooltipTitleColor: .primary,
        tooltipRowSpacing: 6,
        providerGlyphSize: 10,
        providerGlyphColor: .secondary,
        modelFont: .caption2,
        providerFont: .system(size: 9),
        valueFont: .caption2,
        providerColor: .secondary,
        valueColor: .primary
    )
}
