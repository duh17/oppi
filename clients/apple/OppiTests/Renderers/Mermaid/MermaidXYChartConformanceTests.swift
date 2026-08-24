import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/xyChart.html
//
// Tests call the dedicated parser/renderer and the shared dispatcher.
//
// COVERAGE:
// [x] xychart and xychart-beta type detection
// [x] title (quoted, unquoted with spaces / parentheses)
// [x] categorical x-axis
// [x] numeric y-axis title + min --> max
// [x] unnamed bar + line
// [x] named series + legend only for named series
// [x] official simplest line example
// [x] decimal / signed / leading-dot numbers
// [x] comments and blank lines
// [x] three session plots parse and draw within 360pt
// [x] 320pt does not clip
// [x] values outside declared y-range clip (do not explode layout)
// [x] empty chart is a placeholder
// [x] long first/last x labels stay inside maxWidth without overlapping
// [x] y-tick labels sit against the plot (right-aligned)
//
// DEFERRED:
// [ ] YAML theme/config
// [ ] bar data labels
// [ ] line per-point text labels
// [ ] accTitle / accDescr

@Suite("XY Chart Conformance — Mermaid xychart")
struct MermaidXYChartConformanceTests {

    private static let issuesRemaining = """
        xychart-beta
            title Oracle issues remaining (crash counted as 10)
            x-axis [B, 1, 2, 3, 4, 5, 6, 7, 8]
            y-axis "issues" 0 --> 10
            bar [10, 9, 9, 9, 6, 1, 0, 0, 0]
            line [10, 9, 9, 9, 6, 1, 0, 0, 0]
        """

    private static let testTime = """
        xychart-beta
            title Actual test time when it finished (ms, log-ish)
            x-axis [B, 1, 2, 3, 4, 5, 6, 7, 8]
            y-axis "test ms" 0 --> 800
            bar [56000, 253, 360, 273, 325, 559, 538, 550, 550]
        """

    private static let fullLayout = """
        xychart-beta
            title Official full_layout_ms (measure.sh wall clock)
            x-axis [B, 1, 2, 3, 4, 5, 6, 7, 8]
            y-axis "ms" 0 --> 120000
            bar [120000, 120000, 120000, 120000, 120000, 120000, 19044, 19000, 19433]
        """

    // MARK: - Type detection

    @Test func detectsXYChartKeyword() {
        let result = MermaidParser().parse("xychart\n    line [1, 2, 3]")
        guard case .xyChart(let diagram) = result else {
            Issue.record("Expected xyChart, got \(result)")
            return
        }
        #expect(diagram.series.count == 1)
        #expect(diagram.series[0].kind == .line)
    }

    @Test func detectsXYChartBetaKeyword() {
        let result = MermaidParser().parse(Self.issuesRemaining)
        guard case .xyChart = result else {
            Issue.record("Expected xyChart for xychart-beta, got \(result)")
            return
        }
    }

    // MARK: - Parser

    @Test func officialSimplestLineExample() {
        let diagram = MermaidXYChartParser.parse(lines: [
            "xychart",
            "    line [+1.3, .6, 2.4, -.34]",
        ])
        #expect(diagram.title == nil)
        #expect(diagram.series.count == 1)
        #expect(diagram.series[0].kind == .line)
        #expect(diagram.series[0].name == nil)
        #expect(diagram.series[0].values == [1.3, 0.6, 2.4, -0.34])
    }

    @Test func unquotedTitleKeepsSpacesAndParentheses() {
        let diagram = MermaidXYChartParser.parse(lines: Self.issuesRemaining.components(separatedBy: "\n"))
        #expect(diagram.title == "Oracle issues remaining (crash counted as 10)")
    }

    @Test func quotedTitle() {
        let diagram = MermaidXYChartParser.parse(lines: [
            "xychart",
            "    title \"This is a simple example\"",
            "    line [1, 2]",
        ])
        #expect(diagram.title == "This is a simple example")
    }

    @Test func categoricalXAxisWithoutTitle() {
        let diagram = MermaidXYChartParser.parse(lines: Self.issuesRemaining.components(separatedBy: "\n"))
        guard case .categorical(let title, let categories) = diagram.xAxis else {
            Issue.record("Expected categorical x-axis")
            return
        }
        #expect(title == nil)
        #expect(categories == ["B", "1", "2", "3", "4", "5", "6", "7", "8"])
    }

    @Test func categoricalXAxisWithQuotedTitleAndSpacedCategory() {
        let diagram = MermaidXYChartParser.parse(lines: [
            "xychart",
            #"    x-axis "title with space" [cat1, "cat2 with space", cat3]"#,
            "    bar [1, 2, 3]",
        ])
        guard case .categorical(let title, let categories) = diagram.xAxis else {
            Issue.record("Expected categorical x-axis")
            return
        }
        #expect(title == "title with space")
        #expect(categories == ["cat1", "cat2 with space", "cat3"])
    }

    @Test func numericYAxisQuotedTitleAndRange() {
        let diagram = MermaidXYChartParser.parse(lines: Self.issuesRemaining.components(separatedBy: "\n"))
        #expect(diagram.yAxis.title == "issues")
        #expect(diagram.yAxis.min == 0)
        #expect(diagram.yAxis.max == 10)
    }

    @Test func unnamedBarAndLinePreserveOrder() {
        let diagram = MermaidXYChartParser.parse(lines: Self.issuesRemaining.components(separatedBy: "\n"))
        #expect(diagram.series.count == 2)
        #expect(diagram.series[0].kind == .bar)
        #expect(diagram.series[0].name == nil)
        #expect(diagram.series[0].values == [10, 9, 9, 9, 6, 1, 0, 0, 0])
        #expect(diagram.series[1].kind == .line)
        #expect(diagram.series[1].name == nil)
        #expect(diagram.series[1].values == [10, 9, 9, 9, 6, 1, 0, 0, 0])
    }

    @Test func namedSeriesAreCaptured() {
        let diagram = MermaidXYChartParser.parse(lines: [
            "xychart",
            "    x-axis [A, B]",
            #"    bar "Revenue" [10, 20]"#,
            #"    line "Forecast" [12, 18]"#,
        ])
        #expect(diagram.series.map(\.name) == ["Revenue", "Forecast"])
        #expect(diagram.series.map(\.kind) == [.bar, .line])
    }

    @Test func parsesHorizontalAndVerticalHeaderOrientation() {
        let horizontal = MermaidXYChartParser.parse(lines: [
            "xychart horizontal",
            "    x-axis [A, B, C]",
            "    bar [1, 2, 3]",
        ])
        let betaHorizontal = MermaidXYChartParser.parse(lines: [
            "xychart-beta horizontal",
            "    x-axis [A, B]",
            "    line [4, 5]",
        ])
        let vertical = MermaidXYChartParser.parse(lines: [
            "xychart vertical",
            "    bar [1, 2]",
        ])
        let implicit = MermaidXYChartParser.parse(lines: [
            "xychart",
            "    bar [1, 2]",
        ])
        #expect(horizontal.orientation == .horizontal)
        #expect(betaHorizontal.orientation == .horizontal)
        #expect(vertical.orientation == .vertical)
        #expect(implicit.orientation == .vertical)
        #expect(horizontal.series.first?.values == [1, 2, 3])
    }

    @Test func sharedParserKeepsHorizontalOnXYChartBetaHeader() {
        let result = MermaidParser().parse("""
        xychart-beta horizontal
            x-axis [A, B, C]
            y-axis "n" 0 --> 10
            bar [1, 2, 3]
        """)
        guard case .xyChart(let diagram) = result else {
            Issue.record("Expected xyChart, got \(result)")
            return
        }
        #expect(diagram.orientation == .horizontal)
        #expect(diagram.series.first?.values == [1, 2, 3])
    }

    /// Official orientation tokens are only `horizontal` / `vertical` on
    /// the header line. Leftovers must not silently render vertical.
    @Test func leftoverXYOrientationFailsVisibly() {
        let diagonal = MermaidXYChartParser.parse(lines: [
            "xychart diagonal",
            "    x-axis [A, B]",
            "    bar [1, 2]",
        ])
        let extra = MermaidXYChartParser.parse(lines: [
            "xychart-beta horizontal sideways",
            "    bar [1, 2, 3]",
        ])
        #expect(diagonal.orientation == .unsupported("diagonal"))
        guard case .unsupported(let leftover) = extra.orientation else {
            Issue.record("Expected unsupported leftover after horizontal, got \(extra.orientation)")
            return
        }
        #expect(leftover.localizedCaseInsensitiveContains("sideways"))

        let diagonalLayout = layoutXY(diagonal, maxWidth: 360)
        let extraLayout = layoutXY(extra, maxWidth: 360)
        #expect(diagonalLayout.isPlaceholder)
        #expect(extraLayout.isPlaceholder)
        #expect(diagonalLayout.placeholderText?.localizedCaseInsensitiveContains("orientation") == true)
        #expect(diagonalLayout.placeholderText?.localizedCaseInsensitiveContains("diagonal") == true)
        #expect(extraLayout.placeholderText?.localizedCaseInsensitiveContains("orientation") == true)
    }

    @Test func commentsAndBlanksIgnored() {
        let diagram = MermaidXYChartParser.parse(lines: [
            "%% comment",
            "",
            "xychart-beta",
            "    %% another",
            "    title Demo",
            "",
            "    bar [1, 2]",
        ])
        #expect(diagram.title == "Demo")
        #expect(diagram.series.first?.values == [1, 2])
    }

    @Test func sessionPlotsParse() {
        let issues = MermaidParser().parse(Self.issuesRemaining)
        let time = MermaidParser().parse(Self.testTime)
        let layout = MermaidParser().parse(Self.fullLayout)
        guard case .xyChart(let issuesChart) = issues,
              case .xyChart(let timeChart) = time,
              case .xyChart(let layoutChart) = layout
        else {
            Issue.record("Expected all three session plots to parse as xyChart")
            return
        }
        #expect(issuesChart.series.count == 2)
        #expect(timeChart.series.first?.values.first == 56_000)
        #expect(layoutChart.yAxis.max == 120_000)
        #expect(timeChart.yAxis.title == "test ms")
        #expect(layoutChart.title == "Official full_layout_ms (measure.sh wall clock)")
    }

    // MARK: - Renderer

    @Test func sessionPlotsDrawWithin360() {
        for source in [Self.issuesRemaining, Self.testTime, Self.fullLayout] {
            let diagram = MermaidParser().parse(source)
            guard case .xyChart(let chart) = diagram else {
                Issue.record("Expected xyChart for session plot")
                continue
            }
            let layout = layoutXY(chart, maxWidth: 360)
            #expect(layout.isPlaceholder == false)
            #expect(layout.customDraw != nil)
            guard let size = layout.customSize else {
                Issue.record("Expected non-nil customSize")
                continue
            }
            #expect(size.width > 0)
            #expect(size.height > 0)
            #expect(size.width <= 360)
            #expect(draw(layout) != nil)
        }
    }

    @Test func sessionPlotsStayWithin320WithoutClipping() {
        for source in [Self.issuesRemaining, Self.testTime, Self.fullLayout] {
            let diagram = MermaidParser().parse(source)
            guard case .xyChart(let chart) = diagram else {
                Issue.record("Expected xyChart")
                continue
            }
            let layout = layoutXY(chart, maxWidth: 320)
            #expect(layout.isPlaceholder == false)
            guard let size = layout.customSize else {
                Issue.record("Expected customSize")
                continue
            }
            #expect(size.width <= 320)
            #expect(size.height > 0)
            for (key, rect) in layout.graphResult.nodePositions {
                #expect(rect.maxX <= size.width + 0.5, "\(key) overflows width")
                #expect(rect.maxY <= size.height + 0.5, "\(key) overflows height")
                #expect(rect.minX >= -0.5, "\(key) clips left")
                #expect(rect.minY >= -0.5, "\(key) clips top")
            }
            #expect(draw(layout) != nil)
        }
    }

    @Test func valuesOutsideDeclaredYRangeDoNotExplodeLayout() {
        let overflowing = MermaidParser().parse(Self.testTime)
        let inRange = MermaidXYChartParser.parse(lines: [
            "xychart-beta",
            "    title Actual test time when it finished (ms, log-ish)",
            "    x-axis [B, 1, 2, 3, 4, 5, 6, 7, 8]",
            "    y-axis \"test ms\" 0 --> 800",
            "    bar [800, 253, 360, 273, 325, 559, 538, 550, 550]",
        ])
        guard case .xyChart(let overflowChart) = overflowing else {
            Issue.record("Expected overflowing session plot")
            return
        }
        #expect(overflowChart.series.first?.values.first == 56_000)
        #expect(inRange.yAxis.max == 800)

        let overflowLayout = layoutXY(overflowChart, maxWidth: 360)
        let inRangeLayout = layoutXY(inRange, maxWidth: 360)
        guard let overflowPlot = overflowLayout.graphResult.nodePositions["plot"],
              let inRangePlot = inRangeLayout.graphResult.nodePositions["plot"],
              let overflowSize = overflowLayout.customSize
        else {
            Issue.record("Expected plot frames")
            return
        }
        #expect(overflowPlot.height == inRangePlot.height)
        #expect(overflowSize.width <= 360)
        #expect(overflowPlot.height <= 200)
        #expect(MermaidXYChartRenderer.clipY(56_000, min: 0, max: 800) == 800)
        #expect(draw(overflowLayout) != nil)
    }

    @Test func emptyDiagramYieldsPlaceholder() {
        let layout = layoutXY(.empty, maxWidth: 360)
        #expect(layout.isPlaceholder == true)
        #expect(layout.customDraw == nil)
    }

    @Test func legendOnlyForNamedSeries() {
        let named = MermaidXYChartParser.parse(lines: [
            "xychart",
            "    x-axis [A, B]",
            #"    bar "Revenue" [10, 20]"#,
            #"    line "Forecast" [12, 18]"#,
        ])
        let unnamed = MermaidXYChartParser.parse(lines: Self.issuesRemaining.components(separatedBy: "\n"))
        let namedLayout = layoutXY(named, maxWidth: 360)
        let unnamedLayout = layoutXY(unnamed, maxWidth: 360)
        #expect(namedLayout.graphResult.nodePositions["legend"] != nil)
        #expect(namedLayout.nodeLabels["$legend-0"] == "Revenue")
        #expect(namedLayout.nodeLabels["$legend-1"] == "Forecast")
        #expect(unnamedLayout.graphResult.nodePositions["legend"] == nil)
        #expect(draw(namedLayout) != nil)
        #expect(draw(unnamedLayout) != nil)
    }

    @Test func titleAndYAxisSurviveIntoLayout() {
        let diagram = MermaidParser().parse(Self.issuesRemaining)
        guard case .xyChart(let chart) = diagram else {
            Issue.record("Expected xyChart")
            return
        }
        let layout = layoutXY(chart, maxWidth: 360)
        #expect(layout.nodeLabels["$title"]?.contains("Oracle issues remaining") == true)
        #expect(layout.nodeLabels["$yTitle"] == "issues")
        #expect(layout.graphResult.nodePositions["title"] != nil)
        #expect(layout.graphResult.nodePositions["plot"] != nil)
        #expect(draw(layout) != nil)
    }

    @Test func xLabelsSkipInsteadOfOverlapping() {
        let labels = (0..<20).map { "Label\($0)" }
        let widths = Array(repeating: CGFloat(48), count: 20)
        let centers = (0..<20).map { CGFloat($0) * 18 + 24 }
        let shown = MermaidXYChartRenderer.xLabelsToShow(
            labels: labels,
            widths: widths,
            slotCenters: centers,
            minGap: 6
        ).map(\.index)
        #expect(shown.first == 0)
        #expect(shown.last == 19)
        #expect(shown.count < labels.count)

        for pair in zip(shown, shown.dropFirst()) {
            let left = centers[pair.0] + widths[pair.0] / 2
            let right = centers[pair.1] - widths[pair.1] / 2
            #expect(right + 0.01 >= left)
        }
    }

    @Test func longFirstAndLastXLabelsStayInsideMaxWidthWithoutOverlapping() {
        let diagram = MermaidXYChartParser.parse(lines: [
            "xychart-beta",
            "    title Sales Revenue",
            #"    x-axis ["January", Feb, Mar, Apr, May, Jun, Jul, Aug, Sep, Oct, Nov, "December closing"]"#,
            #"    y-axis "Revenue (in $)" 4000 --> 11000"#,
            "    bar [5000, 6000, 7500, 8200, 9500, 10500, 11000, 10200, 9200, 8500, 7000, 6000]",
        ])
        guard case .categorical(_, let categories) = diagram.xAxis else {
            Issue.record("Expected categorical x-axis")
            return
        }
        #expect(categories.first == "January")
        #expect(categories.last == "December closing")

        let layout = layoutXY(diagram, maxWidth: 360)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(size.width <= 360)

        let xFrames = numberedFrames(layout.graphResult.nodePositions, prefix: "x-")
        #expect(!xFrames.isEmpty)
        #expect(xFrames.contains { $0.index == 0 }, "first category should stay visible")

        for (keyIndex, frame) in xFrames {
            #expect(frame.minX >= -0.5, "x-\(keyIndex) clips left")
            #expect(frame.maxX <= 360 + 0.5, "x-\(keyIndex) paints past maxWidth")
            #expect(frame.maxX <= size.width + 0.5, "x-\(keyIndex) paints past customSize.width")
        }
        for pair in zip(xFrames, xFrames.dropFirst()) {
            #expect(
                pair.1.frame.minX + 0.01 >= pair.0.frame.maxX,
                "x-\(pair.0.index) overlaps x-\(pair.1.index)"
            )
        }
        if let first = xFrames.first(where: { $0.index == 0 }),
           let last = xFrames.first(where: { $0.index == categories.count - 1 }) {
            #expect(last.frame.minX + 0.01 >= first.frame.maxX + 6 - 0.5)
        }
        #expect(draw(layout) != nil)
    }

    @Test func compactYLabelsForLargeRange() {
        #expect(MermaidXYChartRenderer.formatAxisNumber(0) == "0")
        #expect(MermaidXYChartRenderer.formatAxisNumber(800) == "800")
        #expect(MermaidXYChartRenderer.formatAxisNumber(120_000) == "120k")
        #expect(MermaidXYChartRenderer.formatAxisNumber(50_000) == "50k")
        let ticks = MermaidXYChartRenderer.niceTicks(min: 0, max: 120_000)
        #expect(ticks.first == 0)
        #expect(ticks.last == 120_000)
        #expect(ticks.count >= 2)
        #expect(ticks.count <= 7)
    }

    @Test func yTickLabelsSitAgainstPlotNotLeftPadded() {
        let diagram = MermaidXYChartParser.parse(lines: Self.fullLayout.components(separatedBy: "\n"))
        let layout = layoutXY(diagram, maxWidth: 360)
        guard let yAxis = layout.graphResult.nodePositions["yAxis"],
              let plot = layout.graphResult.nodePositions["plot"]
        else {
            Issue.record("Expected yAxis and plot frames")
            return
        }

        #expect(yAxis.maxX <= plot.minX + 0.5)
        #expect(plot.minX - yAxis.maxX <= 8.5, "yAxis should sit against the plot left edge")

        let yFrames = numberedFrames(layout.graphResult.nodePositions, prefix: "y-")
        #expect(!yFrames.isEmpty, "expected per-tick y frames")

        for (index, frame) in yFrames {
            #expect(frame.maxX <= plot.minX + 0.5, "y-\(index) is not against the plot")
            #expect(abs(frame.maxX - yAxis.maxX) < 0.6, "y-\(index) is not right-aligned")
            #expect(frame.minX >= yAxis.minX - 0.5)
        }

        let zeroLabel = layout.nodeLabels.first { $0.key.hasPrefix("$y-") && $0.value == "0" }
        if let zeroLabel {
            let frameKey = String(zeroLabel.key.dropFirst())
            guard let zeroFrame = layout.graphResult.nodePositions[frameKey] else {
                Issue.record("Expected frame for \(zeroLabel.key)")
                return
            }
            #expect(zeroFrame.width + 1 < yAxis.width, "0 should be narrower than the y column")
            #expect(zeroFrame.minX > yAxis.minX + 1, "0 should not be left-padded in the y column")
            #expect(abs(zeroFrame.maxX - yAxis.maxX) < 0.6)
        } else {
            Issue.record("Expected a 0 y-tick label")
        }
        #expect(draw(layout) != nil)
    }

    @Test func longTitleWrapsWithinMaxWidth() {
        let longTitle = "This is an extremely long XY chart title that would overflow a phone bubble if the renderer never wrapped or truncated it"
        let diagram = MermaidXYChartParser.parse(lines: [
            "xychart",
            "    title \(longTitle)",
            "    x-axis [A, B, C]",
            "    bar [1, 2, 3]",
        ])
        #expect(diagram.title == longTitle)
        let layout = layoutXY(diagram, maxWidth: 360)
        guard let size = layout.customSize,
              let titleRect = layout.graphResult.nodePositions["title"]
        else {
            Issue.record("Expected titled layout")
            return
        }
        #expect(size.width <= 360)
        #expect(titleRect.maxX <= size.width + 0.5)
        let wrapped = layout.nodeLabels["$title"] ?? ""
        #expect(wrapped.contains("\n") || wrapped.contains("…"))
        #expect(draw(layout) != nil)
    }

    @Test func documentWidthKeepsInlinePlotRatio() {
        let diagram = MermaidParser().parse(Self.issuesRemaining)
        guard case .xyChart(let chart) = diagram else {
            Issue.record("Expected xyChart")
            return
        }
        let inline = layoutXY(chart, maxWidth: 360)
        let document = layoutXY(chart, maxWidth: 800)
        guard let inlinePlot = inline.graphResult.nodePositions["plot"],
              let documentPlot = document.graphResult.nodePositions["plot"]
        else {
            Issue.record("Expected plot frames")
            return
        }
        #expect(abs(inlinePlot.height - 168) < 0.5)
        #expect(abs(documentPlot.height - 168 * 800 / 360) < 0.5)
        #expect(documentPlot.height > inlinePlot.height + 80)
        let inlineRatio = inlinePlot.height / 360
        let documentRatio = documentPlot.height / 800
        #expect(abs(inlineRatio - documentRatio) < 0.01)
        #expect(draw(document) != nil)
    }

    @Test func dispatcherRendersXYChartWithoutPlaceholder() {
        let diagram = MermaidParser().parse(Self.issuesRemaining)
        let layout = MermaidRenderer().layout(diagram, configuration: .default(maxWidth: 360))
        #expect(layout.isPlaceholder == false)
        let size = MermaidRenderer().boundingBox(layout)
        #expect(size.width > 0)
        #expect(size.width <= 360)
        #expect(size.height > 0)
    }

    /// Official horizontal orientation: categorical x-axis sits on the
    /// left, numeric y-axis runs along the top, bars grow sideways.
    @Test func horizontalChartIsNotASilentVerticalChart() {
        let diagram = MermaidXYChartParser.parse(lines: [
            "xychart horizontal",
            "    title Sales",
            "    x-axis [A, B, C]",
            "    y-axis \"n\" 0 --> 10",
            "    bar [2, 5, 9]",
        ])
        #expect(diagram.orientation == .horizontal)
        let layout = layoutXY(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        guard let plot = layout.graphResult.nodePositions["plot"],
              let size = layout.customSize
        else {
            Issue.record("Expected horizontal plot")
            return
        }
        #expect(size.width <= 360)

        let categoryFrames = numberedFrames(layout.graphResult.nodePositions, prefix: "x-")
        let valueFrames = numberedFrames(layout.graphResult.nodePositions, prefix: "y-")
        #expect(categoryFrames.count >= 2)
        #expect(valueFrames.count >= 2)

        for pair in zip(categoryFrames, categoryFrames.dropFirst()) {
            #expect(pair.0.frame.midY < pair.1.frame.midY, "categories must stack top-down")
        }
        for pair in zip(valueFrames, valueFrames.dropFirst()) {
            #expect(pair.0.frame.midX < pair.1.frame.midX, "value ticks must run left-to-right")
        }
        if let firstCategory = categoryFrames.first?.frame {
            #expect(firstCategory.maxX <= plot.minX + 0.5, "categories belong on the left")
            #expect(firstCategory.midY >= plot.minY - 8)
        }
        if let firstValue = valueFrames.first?.frame {
            #expect(firstValue.maxY <= plot.minY + 0.5, "numeric axis belongs above the plot")
        }
        #expect(draw(layout) != nil)
    }

    @Test func horizontalBetaChartDrawsSidewaysBars() {
        let diagram = MermaidXYChartParser.parse(lines: [
            "xychart-beta horizontal",
            "    x-axis [Q1, Q2]",
            "    bar [3, 8]",
        ])
        let layout = layoutXY(diagram, maxWidth: 360)
        guard let plot = layout.graphResult.nodePositions["plot"] else {
            Issue.record("Expected plot")
            return
        }
        let categories = numberedFrames(layout.graphResult.nodePositions, prefix: "x-")
        #expect(categories.count == 2)
        #expect(categories[0].frame.midY < categories[1].frame.midY)
        #expect(plot.width > 40)
        #expect(draw(layout) != nil)
    }

    /// Negative-only range: bars must grow from the zero-adjacent edge
    /// (`yMax`), not invert from `yMin` as the baseline.
    @Test func negativeOnlyBarsGrowFromZeroAdjacentEdge() {
        let plot = CGRect(x: 0, y: 0, width: 100, height: 100)
        let rect = MermaidXYChartRenderer.barRectForValue(
            -4, x: 10, width: 10, yMin: -10, yMax: -1, plot: plot
        )
        // yMax (-1) is the top of the plot; yMin (-10) is the bottom.
        #expect(rect.minY < 8, "bar should start at the zero-adjacent top edge")
        #expect(rect.maxY < 55, "bar must not grow from yMin at the plot bottom")
        #expect(rect.maxY > 20)
        #expect(rect.height > 20)

        let positive = MermaidXYChartRenderer.barRectForValue(
            4, x: 10, width: 10, yMin: 1, yMax: 10, plot: plot
        )
        #expect(positive.maxY > 92, "positive-only bars still grow from yMin")
        #expect(positive.minY > 40)
    }

    @Test func contrastHoldsInLightAndDark() {
        let themes: [RenderTheme] = [.fallback, .light]
        for theme in themes {
            let config = RenderConfiguration(
                fontSize: 14,
                maxWidth: 360,
                theme: theme,
                displayMode: .document
            )
            let diagram = MermaidParser().parse(Self.issuesRemaining)
            guard case .xyChart(let chart) = diagram else {
                Issue.record("Expected xyChart")
                continue
            }
            let layout = MermaidXYChartRenderer.layout(chart, configuration: config)
            guard let paint = draw(layout),
                  let plot = layout.graphResult.nodePositions["plot"]
            else {
                Issue.record("Expected painted XY chart")
                continue
            }
            let ink = paint.nonBackgroundCount(in: plot, background: theme.background)
            #expect(ink > 80)
            #expect(paint.maxContrast(in: plot, against: theme.background) >= 3.0)
        }
    }
}

// MARK: - Helpers

private func layoutXY(
    _ diagram: XYChartDiagram,
    maxWidth: CGFloat
) -> MermaidFlowchartRenderer.FlowchartLayout {
    MermaidXYChartRenderer.layout(diagram, configuration: .default(maxWidth: maxWidth))
}

private func numberedFrames(
    _ positions: [String: CGRect],
    prefix: String
) -> [(index: Int, frame: CGRect)] {
    positions.compactMap { key, rect -> (Int, CGRect)? in
        guard key.hasPrefix(prefix) else { return nil }
        let suffix = key.dropFirst(prefix.count)
        guard let index = Int(suffix) else { return nil }
        return (index, rect)
    }
    .sorted { $0.0 < $1.0 }
}

private func draw(_ layout: MermaidFlowchartRenderer.FlowchartLayout) -> PaintedBitmap? {
    guard let size = layout.customSize, let draw = layout.customDraw else { return nil }
    let width = max(Int(ceil(size.width)), 1)
    let height = max(Int(ceil(size.height)), 1)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx, .zero)
        return true
    }
    guard ok else { return nil }
    return PaintedBitmap(width: width, height: height, bytes: bytes)
}

private struct PaintedBitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func pixel(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let offset = (y * width + x) * 4
        return (
            r: CGFloat(bytes[offset]) / 255,
            g: CGFloat(bytes[offset + 1]) / 255,
            b: CGFloat(bytes[offset + 2]) / 255
        )
    }

    func nonBackgroundCount(in rect: CGRect, background: CGColor) -> Int {
        guard let bg = sRGB(background) else { return 0 }
        var count = 0
        visit(rect) { px in
            if distance(px, bg) > 0.08 { count += 1 }
        }
        return count
    }

    func maxContrast(in rect: CGRect, against fill: CGColor) -> CGFloat {
        guard let fillRGB = sRGB(fill) else { return 1 }
        var best: CGFloat = 1
        visit(rect) { px in
            if distance(px, fillRGB) > 0.08 {
                best = max(best, contrastRatio(px, fillRGB))
            }
        }
        return best
    }

    private func visit(_ rect: CGRect, _ body: ((r: CGFloat, g: CGFloat, b: CGFloat)) -> Void) {
        let minX = max(Int(floor(rect.minX)), 0)
        let maxX = min(Int(ceil(rect.maxX)), width)
        let minY = max(Int(floor(rect.minY)), 0)
        let maxY = min(Int(ceil(rect.maxY)), height)
        for y in minY..<maxY {
            for x in minX..<maxX {
                if let px = pixel(x, y) { body(px) }
            }
        }
    }
}

private func sRGB(_ color: CGColor) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
    let converted = color.converted(
        to: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        intent: .defaultIntent,
        options: nil
    ) ?? color
    guard let components = converted.components else { return nil }
    if components.count >= 3 {
        return (components[0], components[1], components[2])
    }
    if components.count >= 1 {
        return (components[0], components[0], components[0])
    }
    return nil
}

private func distance(
    _ a: (r: CGFloat, g: CGFloat, b: CGFloat),
    _ b: (r: CGFloat, g: CGFloat, b: CGFloat)
) -> CGFloat {
    let dr = a.r - b.r
    let dg = a.g - b.g
    let db = a.b - b.b
    return (dr * dr + dg * dg + db * db).squareRoot()
}

private func contrastRatio(
    _ a: (r: CGFloat, g: CGFloat, b: CGFloat),
    _ b: (r: CGFloat, g: CGFloat, b: CGFloat)
) -> CGFloat {
    let lighter = max(luminance(a), luminance(b))
    let darker = min(luminance(a), luminance(b))
    return (lighter + 0.05) / (darker + 0.05)
}

private func luminance(_ color: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
    func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearized(color.r) + 0.7152 * linearized(color.g) + 0.0722 * linearized(color.b)
}
