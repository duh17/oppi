import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/quadrantChart.html
//
// COVERAGE:
// [x] quadrantChart type detection
// [x] title
// [x] x-axis left / left --> right
// [x] y-axis bottom / bottom --> top
// [x] quadrant-1..4
// [x] points Name: [x, y] in 0...1
// [x] empty vs populated label placement
// [x] gallery fixture layouts inside 360pt
// [x] title, axes, and plot stay separated at 360pt
// [x] mermaid theme config does not paint a page
// [x] malformed input does not crash
//
// DEFERRED:
// [ ] point radius/color/classDef styling
// [ ] chartWidth/chartHeight YAML (phone uses maxWidth)

@Suite("Quadrant Conformance — Mermaid quadrantChart")
struct MermaidQuadrantConformanceTests {

    private static let gallery = """
        quadrantChart
          title Reach and engagement of campaigns
          x-axis Low Reach --> High Reach
          y-axis Low Engagement --> High Engagement
          quadrant-1 We should expand
          quadrant-2 Need to promote
          quadrant-3 Re-evaluate
          quadrant-4 May be improved
          Campaign A: [0.3, 0.6]
          Campaign B: [0.45, 0.23]
          Campaign C: [0.57, 0.69]
          Campaign D: [0.78, 0.34]
          Campaign E: [0.40, 0.34]
          Campaign F: [0.35, 0.78]
        """

    @Test func detectsQuadrantChartKeyword() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .quadrantChart = result else {
            Issue.record("Expected quadrantChart, got \(result)")
            return
        }
    }

    @Test func officialAxisAndPoints() {
        let diagram = MermaidQuadrantParser.parse(lines: Self.gallery.components(separatedBy: "\n"))
        #expect(diagram.title == "Reach and engagement of campaigns")
        #expect(diagram.xAxisLeft == "Low Reach")
        #expect(diagram.xAxisRight == "High Reach")
        #expect(diagram.yAxisBottom == "Low Engagement")
        #expect(diagram.yAxisTop == "High Engagement")
        #expect(diagram.quadrant1 == "We should expand")
        #expect(diagram.quadrant2 == "Need to promote")
        #expect(diagram.quadrant3 == "Re-evaluate")
        #expect(diagram.quadrant4 == "May be improved")
        #expect(diagram.points.count == 6)
        #expect(diagram.points[0].name == "Campaign A")
        #expect(diagram.points[0].x == 0.3)
        #expect(diagram.points[0].y == 0.6)
    }

    @Test func xAxisLeftOnlyAndYAxisBottomOnly() {
        let diagram = MermaidQuadrantParser.parse(lines: [
            "quadrantChart",
            "    x-axis Reach",
            "    y-axis Engagement",
        ])
        #expect(diagram.xAxisLeft == "Reach")
        #expect(diagram.xAxisRight == nil)
        #expect(diagram.yAxisBottom == "Engagement")
        #expect(diagram.yAxisTop == nil)
    }

    @Test func emptyChartCentersQuadrantLabels() {
        let diagram = MermaidQuadrantParser.parse(lines: [
            "quadrantChart",
            "    title Empty",
            "    x-axis Low --> High",
            "    y-axis Bottom --> Top",
            "    quadrant-1 Q1",
            "    quadrant-2 Q2",
            "    quadrant-3 Q3",
            "    quadrant-4 Q4",
        ])
        #expect(diagram.points.isEmpty)
        let layout = layoutQuadrant(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        guard let q1 = layout.graphResult.nodePositions["quadrant-1"],
              let q1Text = layout.graphResult.nodePositions["quadrant-1-label"],
              let xAxis = layout.graphResult.nodePositions["x-axis"]
        else {
            Issue.record("Expected empty-chart frames")
            return
        }
        #expect(abs(q1Text.midX - q1.midX) < 8)
        #expect(abs(q1Text.midY - q1.midY) < 12)
        #expect(xAxis.maxY <= q1.minY + 1, "empty chart keeps x-axis above/outside top")
        #expect(draw(layout) != nil)
    }

    @Test func populatedChartPutsXAxisAtBottomAndQuadrantLabelsAtTop() {
        let diagram = MermaidQuadrantParser.parse(lines: Self.gallery.components(separatedBy: "\n"))
        let layout = layoutQuadrant(diagram, maxWidth: 360)
        guard let q1 = layout.graphResult.nodePositions["quadrant-1"],
              let q1Text = layout.graphResult.nodePositions["quadrant-1-label"],
              let xAxis = layout.graphResult.nodePositions["x-axis"],
              let plot = layout.graphResult.nodePositions["plot"]
        else {
            Issue.record("Expected populated frames")
            return
        }
        #expect(q1Text.minY <= q1.minY + 16)
        #expect(q1Text.maxY < q1.midY)
        #expect(xAxis.minY >= plot.maxY - 1)
        #expect(layout.graphResult.nodePositions["point-0"] != nil)
        #expect(draw(layout) != nil)
    }

    @Test func galleryLayoutsWithin360() {
        let result = MermaidParser().parse(Self.gallery)
        guard case .quadrantChart(let diagram) = result else {
            Issue.record("Expected quadrantChart")
            return
        }
        let layout = layoutQuadrant(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(size.width <= 360)
        #expect(size.height > 0)
        #expect(draw(layout) != nil)
    }

    @Test func galleryTitleAxesAndPlotDoNotOverlap() {
        let diagram = MermaidQuadrantParser.parse(lines: Self.gallery.components(separatedBy: "\n"))
        let layout = layoutQuadrant(diagram, maxWidth: 360)
        guard let size = layout.customSize,
              let title = layout.graphResult.nodePositions["title"],
              let plot = layout.graphResult.nodePositions["plot"],
              let yAxis = layout.graphResult.nodePositions["y-axis"],
              let yTop = layout.graphResult.nodePositions["y-axis-top"],
              let yBottom = layout.graphResult.nodePositions["y-axis-bottom"],
              let xAxis = layout.graphResult.nodePositions["x-axis"]
        else {
            Issue.record("Expected title, axes, and plot frames")
            return
        }
        #expect(size.width <= 360)
        #expect(title.maxY <= plot.minY - 1, "title must sit above the plot")
        #expect(title.maxY <= yTop.minY - 1, "title overlaps the rotated Y-axis label")
        #expect(!title.intersects(yTop.insetBy(dx: 0.5, dy: 0.5)), "title collides with High Engagement")
        #expect(!title.intersects(plot.insetBy(dx: 0.5, dy: 0.5)), "title collides with the plot")
        #expect(yAxis.maxX <= plot.minX + 1, "Y-axis must sit left of the plot")
        #expect(yTop.maxX <= plot.minX + 1, "Y-axis top label must sit left of the plot")
        #expect(yBottom.maxY <= plot.maxY + 1)
        #expect(yTop.minY >= title.maxY + 1)
        #expect(xAxis.minY >= plot.maxY - 1, "populated X-axis stays below the plot")
        #expect(layout.nodeLabels["$y-axis-top"] == "High Engagement")
        #expect(layout.nodeLabels["$y-axis-bottom"] == "Low Engagement")
        for (key, rect) in layout.graphResult.nodePositions {
            #expect(rect.minX >= -0.5, "\(key) clips left")
            #expect(rect.minY >= -0.5, "\(key) clips top")
            #expect(rect.maxX <= size.width + 0.5, "\(key) overflows width")
            #expect(rect.maxY <= size.height + 0.5, "\(key) overflows height")
        }
        #expect(draw(layout) != nil)
    }

    @Test func mermaidThemeDoesNotPaintPageBackground() {
        let source = """
        ---
        config:
          theme: forest
          themeVariables:
            quadrant1Fill: "#ff0000"
        ---
        quadrantChart
          title Theme should not paint the page
          x-axis L --> R
          y-axis B --> T
          Campaign A: [0.2, 0.8]
        """
        let result = MermaidParser().parse(source)
        guard case .quadrantChart(let diagram) = result else {
            Issue.record("Expected quadrantChart, got \(result)")
            return
        }
        let layout = MermaidRenderer().layout(.quadrantChart(diagram), configuration: .default(maxWidth: 360))
        #expect(layout.isPlaceholder == false)
        guard let size = layout.customSize, let drawBlock = layout.customDraw else {
            Issue.record("Expected custom draw")
            return
        }
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
            drawBlock(ctx, .zero)
            return true
        }
        #expect(ok)
        let corners = [
            (0, 0),
            (width - 1, 0),
            (0, height - 1),
            (width - 1, height - 1),
        ]
        for (x, y) in corners {
            let offset = (y * width + x) * 4
            #expect(bytes[offset] == 0 && bytes[offset + 1] == 0
                    && bytes[offset + 2] == 0 && bytes[offset + 3] == 0)
        }
    }

    @Test func emptyDiagramIsPlaceholder() {
        let layout = layoutQuadrant(.empty, maxWidth: 360)
        #expect(layout.isPlaceholder)
    }

    @Test func malformedDoesNotCrash() {
        _ = MermaidParser().parse("quadrantChart\n    Campaign A: [nope]")
        _ = MermaidQuadrantParser.parse(lines: ["quadrantChart", "    x-axis"])
        _ = MermaidQuadrantParser.parse(lines: ["quadrantChart", "    Point: [2, 2]"])
    }
}

private func layoutQuadrant(
    _ diagram: QuadrantChartDiagram,
    maxWidth: CGFloat
) -> MermaidFlowchartRenderer.FlowchartLayout {
    MermaidQuadrantRenderer.layout(diagram, configuration: .default(maxWidth: maxWidth))
}

private func draw(_ layout: MermaidFlowchartRenderer.FlowchartLayout) -> Bool? {
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
    return ok ? true : nil
}
