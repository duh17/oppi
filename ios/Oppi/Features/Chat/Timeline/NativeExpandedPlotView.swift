import SwiftUI
import Charts
import UIKit

final class NativeExpandedPlotView: UIView {
    private var hostingController: UIHostingController<PlotChartContainerView>?
    private var renderSignature: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(spec: PlotChartSpec, fallbackText: String?, themeID: ThemeID) {
        var hasher = Hasher()
        hasher.combine(spec)
        hasher.combine(fallbackText)
        hasher.combine(themeID.rawValue)
        let signature = hasher.finalize()

        guard signature != renderSignature else { return }
        renderSignature = signature

        let rootView = PlotChartContainerView(spec: spec, fallbackText: fallbackText)
        if let hostingController {
            hostingController.rootView = rootView
            return
        }

        let hostingController = UIHostingController(rootView: rootView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear

        addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        self.hostingController = hostingController
    }
}

private struct PlotChartContainerView: View {
    let spec: PlotChartSpec
    let fallbackText: String?

    @State private var selectedX: Double?
    @State private var selectedXRange: ClosedRange<Double>?

    private var chartHeight: CGFloat {
        let preferred = spec.preferredHeight ?? 220
        return min(320, max(160, CGFloat(preferred)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = spec.title, !title.isEmpty {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.themeFg)
                    .lineLimit(2)
            }

            chartView

            if let selectedX {
                Text("x: \(selectedX.formatted(.number.precision(.fractionLength(0...3))))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.themeComment)
            } else if let selectedXRange {
                Text(
                    "range: \(selectedXRange.lowerBound.formatted(.number.precision(.fractionLength(0...3))))"
                    + " → "
                    + "\(selectedXRange.upperBound.formatted(.number.precision(.fractionLength(0...3))))"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.themeComment)
            }

            if let fallbackText,
               !fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(fallbackText)
                    .font(.caption2)
                    .foregroundStyle(.themeComment)
                    .lineLimit(3)
            }
        }
        .padding(8)
    }

    @ViewBuilder
    private var chartView: some View {
        let base = Chart {
            ForEach(spec.marks) { mark in
                markContent(mark)
            }
        }
        .frame(height: chartHeight)
        .chartLegend(.visible)
        .chartYScale(domain: .automatic(reversed: spec.yAxis.invert ? true : nil))
        .chartXAxisLabel(spec.xAxis.label ?? "")
        .chartYAxisLabel(spec.yAxis.label ?? "")

        if spec.interaction.scrollableX {
            if let length = spec.interaction.xVisibleDomainLength,
               length > 0 {
                applyXSelectionIfNeeded(
                    base
                        .chartScrollableAxes(.horizontal)
                        .chartXVisibleDomain(length: length)
                )
            } else {
                applyXSelectionIfNeeded(base.chartScrollableAxes(.horizontal))
            }
        } else {
            applyXSelectionIfNeeded(base)
        }
    }

    @ViewBuilder
    private func applyXSelectionIfNeeded<Content: View>(_ view: Content) -> some View {
        if spec.interaction.xSelection {
            if spec.interaction.xRangeSelection {
                view.chartXSelection(range: $selectedXRange)
            } else {
                view.chartXSelection(value: $selectedX)
            }
        } else {
            view
        }
    }

    // MARK: - Mark rendering

    @ChartContentBuilder
    private func markContent(_ mark: PlotChartSpec.Mark) -> some ChartContent {
        switch mark.type {
        case .line: lineMarkContent(mark)
        case .area: areaMarkContent(mark)
        case .bar: barMarkContent(mark)
        case .point: pointMarkContent(mark)
        case .rectangle: rectangleMarkContent(mark)
        case .rule: ruleMarkContent(mark)
        case .sector: sectorMarkContent(mark)
        }
    }

    // MARK: Line

    @ChartContentBuilder
    private func lineMarkContent(_ mark: PlotChartSpec.Mark) -> some ChartContent {
        let interp = mark.interpolation?.toSwiftCharts ?? .linear
        if !spec.columnIsNumeric(mark.x) {
            ForEach(spec.rows) { row in
                if let x = row.seriesLabel(for: mark.x),
                   let y = row.number(for: mark.y) {
                    LineMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .interpolationMethod(interp)
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        } else if !spec.columnIsNumeric(mark.y) {
            ForEach(spec.rows) { row in
                if let x = row.number(for: mark.x),
                   let y = row.seriesLabel(for: mark.y) {
                    LineMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .interpolationMethod(interp)
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        } else {
            ForEach(spec.rows) { row in
                if let x = row.number(for: mark.x),
                   let y = row.number(for: mark.y) {
                    LineMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .interpolationMethod(interp)
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        }
    }

    // MARK: Area

    @ChartContentBuilder
    private func areaMarkContent(_ mark: PlotChartSpec.Mark) -> some ChartContent {
        if !spec.columnIsNumeric(mark.x) {
            ForEach(spec.rows) { row in
                if let x = row.seriesLabel(for: mark.x),
                   let y = row.number(for: mark.y) {
                    AreaMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        } else if !spec.columnIsNumeric(mark.y) {
            ForEach(spec.rows) { row in
                if let x = row.number(for: mark.x),
                   let y = row.seriesLabel(for: mark.y) {
                    AreaMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        } else {
            ForEach(spec.rows) { row in
                if let x = row.number(for: mark.x),
                   let y = row.number(for: mark.y) {
                    AreaMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        }
    }

    // MARK: Bar

    @ChartContentBuilder
    private func barMarkContent(_ mark: PlotChartSpec.Mark) -> some ChartContent {
        if !spec.columnIsNumeric(mark.x) {
            ForEach(spec.rows) { row in
                if let x = row.seriesLabel(for: mark.x),
                   let y = row.number(for: mark.y) {
                    BarMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        } else if !spec.columnIsNumeric(mark.y) {
            ForEach(spec.rows) { row in
                if let x = row.number(for: mark.x),
                   let y = row.seriesLabel(for: mark.y) {
                    BarMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        } else {
            ForEach(spec.rows) { row in
                if let x = row.number(for: mark.x),
                   let y = row.number(for: mark.y) {
                    BarMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        }
    }

    // MARK: Point

    @ChartContentBuilder
    private func pointMarkContent(_ mark: PlotChartSpec.Mark) -> some ChartContent {
        if !spec.columnIsNumeric(mark.x) {
            ForEach(spec.rows) { row in
                if let x = row.seriesLabel(for: mark.x),
                   let y = row.number(for: mark.y) {
                    PointMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        } else if !spec.columnIsNumeric(mark.y) {
            ForEach(spec.rows) { row in
                if let x = row.number(for: mark.x),
                   let y = row.seriesLabel(for: mark.y) {
                    PointMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        } else {
            ForEach(spec.rows) { row in
                if let x = row.number(for: mark.x),
                   let y = row.number(for: mark.y) {
                    PointMark(x: .value(mark.x ?? "x", x), y: .value(mark.y ?? "y", y))
                        .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
                }
            }
        }
    }

    // MARK: Rectangle / Rule / Sector (always numeric)

    @ChartContentBuilder
    private func rectangleMarkContent(_ mark: PlotChartSpec.Mark) -> some ChartContent {
        ForEach(spec.rows) { row in
            if let xStart = row.number(for: mark.xStart),
               let xEnd = row.number(for: mark.xEnd),
               let yStart = row.number(for: mark.yStart),
               let yEnd = row.number(for: mark.yEnd) {
                RectangleMark(
                    xStart: .value(mark.xStart ?? "xStart", xStart),
                    xEnd: .value(mark.xEnd ?? "xEnd", xEnd),
                    yStart: .value(mark.yStart ?? "yStart", yStart),
                    yEnd: .value(mark.yEnd ?? "yEnd", yEnd)
                )
                .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
            }
        }
    }

    @ChartContentBuilder
    private func ruleMarkContent(_ mark: PlotChartSpec.Mark) -> some ChartContent {
        if let xValue = mark.xValue {
            RuleMark(x: .value(mark.label ?? "rule", xValue))
                .foregroundStyle(.themeYellow)
        }
        if let yValue = mark.yValue {
            RuleMark(y: .value(mark.label ?? "rule", yValue))
                .foregroundStyle(.themeYellow)
        }
    }

    @ChartContentBuilder
    private func sectorMarkContent(_ mark: PlotChartSpec.Mark) -> some ChartContent {
        ForEach(spec.rows) { row in
            if let angle = row.number(for: mark.angle) {
                SectorMark(angle: .value(mark.angle ?? "angle", angle))
                    .foregroundStyle(by: .value("series", seriesLabel(mark: mark, row: row)))
            }
        }
    }

    private func seriesLabel(mark: PlotChartSpec.Mark, row: PlotChartSpec.Row) -> String {
        if let value = row.seriesLabel(for: mark.series), !value.isEmpty {
            return value
        }
        if let label = mark.label, !label.isEmpty {
            return label
        }
        return mark.id
    }
}

private extension PlotChartSpec.Interpolation {
    var toSwiftCharts: InterpolationMethod {
        switch self {
        case .linear: return .linear
        case .cardinal: return .cardinal
        case .catmullRom: return .catmullRom
        case .monotone: return .monotone
        case .stepStart: return .stepStart
        case .stepCenter: return .stepCenter
        case .stepEnd: return .stepEnd
        }
    }
}
