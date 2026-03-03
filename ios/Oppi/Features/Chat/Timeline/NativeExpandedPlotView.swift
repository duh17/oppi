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

    private var chartView: some View {
        GeometryReader { proxy in
            let viewportWidth = max(proxy.size.width, 1)
            let renderPolicy = PlotRenderPolicy(spec: spec, viewportWidth: viewportWidth)
            chartView(renderPolicy: renderPolicy)
                .frame(width: proxy.size.width, height: chartHeight, alignment: .leading)
        }
        .frame(height: chartHeight)
    }

    @ViewBuilder
    private func chartView(renderPolicy: PlotRenderPolicy) -> some View {
        let base = Chart {
            ForEach(spec.marks) { mark in
                markContent(mark)
            }
        }
        .chartLegend(renderPolicy.legendVisible ? .visible : .hidden)
        .chartYScale(domain: .automatic(reversed: spec.yAxis.invert ? true : nil))
        .chartXAxisLabel(spec.xAxis.label ?? "")
        .chartYAxisLabel(spec.yAxis.label ?? "")
        .chartXAxis {
            xAxisContent(renderPolicy: renderPolicy)
        }
        .chartYAxis {
            yAxisContent(renderPolicy: renderPolicy)
        }
        .frame(height: chartHeight)

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

    @AxisContentBuilder
    private func xAxisContent(renderPolicy: PlotRenderPolicy) -> some AxisContent {
        switch renderPolicy.xTickValues {
        case .automatic:
            AxisMarks(values: .automatic(desiredCount: renderPolicy.xTickBudget)) { _ in
                if renderPolicy.showVerticalGridlines {
                    AxisGridLine()
                }
                AxisTick()
                AxisValueLabel()
            }
        case .numeric(let values):
            AxisMarks(values: values) { _ in
                if renderPolicy.showVerticalGridlines {
                    AxisGridLine()
                }
                AxisTick()
                AxisValueLabel()
            }
        case .category(let values):
            AxisMarks(values: values) { _ in
                if renderPolicy.showVerticalGridlines {
                    AxisGridLine()
                }
                AxisTick()
                AxisValueLabel()
            }
        }
    }

    @AxisContentBuilder
    private func yAxisContent(renderPolicy: PlotRenderPolicy) -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: renderPolicy.yTickCount)) { _ in
            if renderPolicy.showHorizontalGridlines {
                AxisGridLine()
            }
            AxisTick()
            AxisValueLabel()
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

struct PlotRenderPolicy: Sendable, Equatable {
    enum XTickValues: Sendable, Equatable {
        case automatic
        case numeric([Double])
        case category([String])
    }

    let xTickBudget: Int
    let yTickCount: Int
    let xTickValues: XTickValues
    let showVerticalGridlines: Bool
    let showHorizontalGridlines: Bool
    let legendVisible: Bool

    init(spec: PlotChartSpec, viewportWidth: CGFloat) {
        xTickBudget = Self.tickBudget(for: viewportWidth)
        yTickCount = viewportWidth < 340 ? 4 : 5

        let decimatedXTicks = Self.decimatedXTickValues(spec: spec, budget: xTickBudget)
        xTickValues = decimatedXTicks.values
        showVerticalGridlines = decimatedXTicks.domainCount > 0 && decimatedXTicks.domainCount <= xTickBudget
        showHorizontalGridlines = true

        let seriesCount = Self.legendSeriesCount(spec: spec)
        legendVisible = seriesCount >= 2 && seriesCount <= 3
    }

    static func tickBudget(for viewportWidth: CGFloat) -> Int {
        let raw = Int(floor(max(0, viewportWidth) / 56))
        return max(4, min(6, raw))
    }

    private static func decimatedXTickValues(spec: PlotChartSpec, budget: Int) -> (values: XTickValues, domainCount: Int) {
        guard let xKey = primaryXKey(spec: spec) else {
            return (.automatic, 0)
        }

        if spec.columnIsNumeric(xKey) {
            let uniqueValues = orderedUnique(spec.rows.compactMap { $0.number(for: xKey) })
            let decimated = decimate(uniqueValues, targetCount: budget)
            guard !decimated.isEmpty else {
                return (.automatic, 0)
            }
            return (.numeric(decimated), uniqueValues.count)
        }

        let labels: [String] = orderedUnique(
            spec.rows.compactMap { row -> String? in
                guard let raw = row.seriesLabel(for: xKey) else {
                    return nil
                }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        )

        let decimated: [String] = decimate(labels, targetCount: budget)
        guard !decimated.isEmpty else {
            return (.automatic, 0)
        }
        return (.category(decimated), labels.count)
    }

    private static func primaryXKey(spec: PlotChartSpec) -> String? {
        for mark in spec.marks {
            switch mark.type {
            case .line, .area, .bar, .point:
                if let x = mark.x, !x.isEmpty {
                    return x
                }
            case .rectangle, .rule, .sector:
                continue
            }
        }
        return nil
    }

    private static func legendSeriesCount(spec: PlotChartSpec) -> Int {
        var seen = Set<String>()

        for mark in spec.marks where markContributesLegend(mark.type) {
            if let seriesKey = mark.series {
                for row in spec.rows {
                    let label = row.seriesLabel(for: seriesKey) ?? legendFallbackLabel(mark)
                    if seen.insert(label).inserted && seen.count > 3 {
                        return seen.count
                    }
                }
            } else {
                let label = legendFallbackLabel(mark)
                if seen.insert(label).inserted && seen.count > 3 {
                    return seen.count
                }
            }
        }

        return seen.count
    }

    private static func markContributesLegend(_ type: PlotChartSpec.MarkType) -> Bool {
        switch type {
        case .rule:
            return false
        case .line, .area, .bar, .point, .rectangle, .sector:
            return true
        }
    }

    private static func legendFallbackLabel(_ mark: PlotChartSpec.Mark) -> String {
        if let label = mark.label, !label.isEmpty {
            return label
        }
        return mark.id
    }

    private static func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        var ordered: [T] = []
        ordered.reserveCapacity(values.count)

        for value in values where seen.insert(value).inserted {
            ordered.append(value)
        }

        return ordered
    }

    private static func decimate<T>(_ values: [T], targetCount: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        guard targetCount > 0 else { return [] }
        guard values.count > targetCount else { return values }

        let indices = decimatedIndices(totalCount: values.count, targetCount: targetCount)
        return indices.map { values[$0] }
    }

    private static func decimatedIndices(totalCount: Int, targetCount: Int) -> [Int] {
        guard totalCount > 0 else { return [] }
        guard targetCount < totalCount else {
            return Array(0..<totalCount)
        }
        guard targetCount > 1 else {
            return [0]
        }

        let span = totalCount - 1
        let steps = targetCount - 1
        var seen = Set<Int>()
        var indices: [Int] = []
        indices.reserveCapacity(targetCount)

        for step in 0...steps {
            let ratio = Double(step) / Double(steps)
            let index = Int((ratio * Double(span)).rounded())
            if seen.insert(index).inserted {
                indices.append(index)
            }
        }

        if indices.first != 0 {
            indices.insert(0, at: 0)
        }
        if indices.last != span {
            indices.append(span)
        }

        return indices.sorted()
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
