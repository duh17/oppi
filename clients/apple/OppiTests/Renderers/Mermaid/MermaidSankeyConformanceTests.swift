import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/sankey.html
//
// COVERAGE:
// [x] sankey and sankey-beta
// [x] 3-column CSV source,target,value
// [x] empty lines
// [x] quoted commas
// [x] escaped quotes
// [x] nodeAlignment / nodeWidth / nodePadding config
// [x] leftover alignment fails visibly
// [x] mermaid color theme does not paint a page
// [x] gallery fixtures layout inside 360pt
// [x] gallery plot uses almost all of maxWidth (360±8, plot ≥ 260)
// [x] right-side node labels stay inside maxWidth
// [x] every gallery source/target including Kanban stays on-canvas
// [x] nodes are 4pt-rounded rects, never stadium pills
// [x] ribbons stay thin, stacked, and quiet (~0.22 alpha)
// [x] malformed input does not crash
//
// DEFERRED:
// [ ] linkColor / nodeColors / labelStyle outlined
// [ ] width/height YAML (phone uses maxWidth)

@Suite("Sankey Conformance — Mermaid sankey")
struct MermaidSankeyConformanceTests {

    private static let galleryBeta = """
        sankey-beta
          %% source,target,value
          Rendered,Flowchart,10
          Rendered,Sequence,8
          Rendered,Other native,12
          Fallback,Journey,2
          Fallback,C4,5
          Fallback,Kanban,3
          Other native,Pie,3
          Other native,Gantt,3
          Other native,Mindmap,3
          Other native,XY,3
        """

    private static let galleryStable = """
        sankey
          A,B,20
          B,C,12
          B,D,8
        """

    @Test func detectsSankeyAndBeta() {
        let beta = MermaidParser().parse(Self.galleryBeta)
        let stable = MermaidParser().parse(Self.galleryStable)
        guard case .sankey = beta else {
            Issue.record("Expected sankey for sankey-beta, got \(beta)")
            return
        }
        guard case .sankey = stable else {
            Issue.record("Expected sankey, got \(stable)")
            return
        }
    }

    @Test func csvThreeColumns() {
        let diagram = MermaidSankeyParser.parse(
            lines: Self.galleryStable.components(separatedBy: "\n")
        )
        #expect(diagram.links.count == 3)
        #expect(diagram.links[0] == SankeyLink(source: "A", target: "B", value: 20))
        #expect(diagram.links[1] == SankeyLink(source: "B", target: "C", value: 12))
        #expect(diagram.links[2] == SankeyLink(source: "B", target: "D", value: 8))
    }

    @Test func emptyLinesQuotedCommasAndEscapedQuotes() {
        let diagram = MermaidSankeyParser.parse(lines: [
            "sankey",
            "A,B,1",
            "",
            "\"Source, Inc\",Target,2",
            "\"He said \"\"hi\"\"\",Next,3",
        ])
        #expect(diagram.links.count == 3)
        #expect(diagram.links[1].source == "Source, Inc")
        #expect(diagram.links[2].source == "He said \"hi\"")
        #expect(diagram.links[2].value == 3)
    }

    @Test func nodeAlignmentAndSizingFromFrontmatter() {
        let source = """
        ---
        config:
          sankey:
            nodeAlignment: left
            nodeWidth: 20
            nodePadding: 16
        ---
        sankey
          A,B,4
          B,C,4
        """
        let result = MermaidParser().parse(source)
        guard case .sankey(let diagram) = result else {
            Issue.record("Expected sankey, got \(result)")
            return
        }
        #expect(diagram.options.nodeAlignment == .left)
        #expect(diagram.options.nodeWidth == 20)
        #expect(diagram.options.nodePadding == 16)
        let layout = layoutSankey(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        #expect(layout.graphResult.nodePositions["node-A"] != nil)
        #expect(draw(layout) != nil)
    }

    @Test func leftoverAlignmentFailsVisibly() {
        let diagram = MermaidSankeyParser.parse(
            lines: ["sankey"],
            options: SankeyOptions(nodeAlignment: .unsupported("diagonal"))
        )
        let layout = layoutSankey(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder)
        #expect(layout.placeholderText?.localizedCaseInsensitiveContains("alignment") == true)
        #expect(layout.placeholderText?.localizedCaseInsensitiveContains("diagonal") == true)
    }

    @Test func galleryLayoutsWithin360() {
        for source in [Self.galleryBeta, Self.galleryStable] {
            let result = MermaidParser().parse(source)
            guard case .sankey(let diagram) = result else {
                Issue.record("Expected sankey")
                continue
            }
            let layout = layoutSankey(diagram, maxWidth: 360)
            #expect(layout.isPlaceholder == false)
            guard let size = layout.customSize else {
                Issue.record("Expected customSize")
                continue
            }
            #expect(size.width <= 360)
            #expect(size.height > 0)
            #expect(draw(layout) != nil)
        }
    }

    @Test func galleryPlotUsesAlmostAllOfMaxWidth() {
        for source in [Self.galleryBeta, Self.galleryStable] {
            let result = MermaidParser().parse(source)
            guard case .sankey(let diagram) = result else {
                Issue.record("Expected sankey")
                continue
            }
            let layout = layoutSankey(diagram, maxWidth: 360)
            guard let size = layout.customSize else {
                Issue.record("Expected customSize")
                continue
            }
            #expect(layout.isPlaceholder == false)
            #expect(
                abs(size.width - 360) <= 8,
                "gallery sankey size.width \(size.width) should sit within 8pt of 360"
            )
            guard let plot = layout.graphResult.nodePositions["plot"] else {
                Issue.record("Expected plot frame")
                continue
            }
            #expect(
                plot.width >= 260,
                "gallery sankey plot width \(plot.width) should be ≥ 260 so ribbons use the card"
            )
        }
    }

    @Test func galleryRightLabelsStayInsideMaxWidth() {
        let result = MermaidParser().parse(Self.galleryBeta)
        guard case .sankey(let diagram) = result else {
            Issue.record("Expected sankey")
            return
        }
        let layout = layoutSankey(diagram, maxWidth: 360)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(layout.isPlaceholder == false)
        #expect(size.width <= 360)

        let positions = layout.graphResult.nodePositions
        for name in ["Pie", "Gantt", "Mindmap", "XY", "Flowchart", "Sequence"] {
            guard let label = positions["label-\(name)"] else {
                Issue.record("Expected label-\(name) inside maxWidth")
                continue
            }
            #expect(label.minX >= -0.5, "label-\(name) clips left")
            #expect(label.maxX <= size.width + 0.5, "label-\(name) is truncated at the card edge")
            #expect(label.maxY <= size.height + 0.5, "label-\(name) overflows height")
            #expect((layout.nodeLabels["$label-\(name)"] ?? layout.nodeLabels["$node-\(name)"])?.contains(name) == true)
        }
        if let pieNode = positions["node-Pie"], let pieLabel = positions["label-Pie"] {
            #expect(pieLabel.minX + 0.5 >= pieNode.maxX, "Pie label should sit beside its node")
        }
        for (key, rect) in positions {
            #expect(rect.maxX <= size.width + 0.5, "\(key) overflows width")
            #expect(rect.minX >= -0.5, "\(key) clips left")
        }
        #expect(draw(layout) != nil)
    }

    @Test func galleryIncludesEverySinkInsideCanvas() {
        let result = MermaidParser().parse(Self.galleryBeta)
        guard case .sankey(let diagram) = result else {
            Issue.record("Expected sankey")
            return
        }
        let layout = layoutSankey(diagram, maxWidth: 360)
        guard let size = layout.customSize else {
            Issue.record("Expected customSize")
            return
        }
        #expect(layout.isPlaceholder == false)
        #expect(size.width <= 360)

        let positions = layout.graphResult.nodePositions
        let names = Set(
            diagram.links.flatMap { [$0.source, $0.target] }
        )
        #expect(names.contains("Kanban"), "gallery fixture must keep the Kanban sink")

        let inset: CGFloat = 8
        for name in names {
            let node = positions["node-\(name)"]
            let label = positions["label-\(name)"]
            guard let frame = node ?? label else {
                Issue.record("Expected node-\(name) or label-\(name) on canvas")
                continue
            }
            #expect(frame.minX + 0.5 >= inset, "\(name) clips left inset")
            #expect(frame.minY + 0.5 >= inset, "\(name) clips top inset")
            #expect(frame.maxX <= size.width - inset + 0.5, "\(name) overflows width")
            #expect(
                frame.maxY <= size.height - inset + 0.5,
                "\(name) is clipped by the 280pt plot cap (size \(size.height), frame \(frame))"
            )
            if let node {
                #expect(node.width > 0 && node.height > 0, "node-\(name) must have a real frame")
            }
        }

        guard let kanban = positions["node-Kanban"] ?? positions["label-Kanban"] else {
            Issue.record("Expected a Kanban frame fully inside the layout size")
            return
        }
        #expect(kanban.minY >= inset - 0.5)
        #expect(kanban.maxY <= size.height - inset + 0.5)
        #expect(kanban.maxX <= size.width + 0.5)
        #expect(size.height > 280, "gallery sinks need height from actual bounds, not a 280pt cap")
        #expect(draw(layout) != nil)
    }

    @Test func mermaidLinkColorDoesNotPaintPage() {
        let source = """
        ---
        config:
          theme: dark
          sankey:
            linkColor: "#ff00aa"
        ---
        sankey
          A,B,5
        """
        let result = MermaidParser().parse(source)
        guard case .sankey(let diagram) = result else {
            Issue.record("Expected sankey, got \(result)")
            return
        }
        let layout = MermaidRenderer().layout(.sankey(diagram), configuration: .default(maxWidth: 360))
        #expect(layout.isPlaceholder == false)
        guard let size = layout.customSize, let drawBlock = layout.customDraw else {
            Issue.record("Expected custom draw")
            return
        }
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        _ = bytes.withUnsafeMutableBytes { raw -> Bool in
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
        let offset = 0
        #expect(bytes[offset] == 0 && bytes[offset + 3] == 0)
    }

    @Test func galleryNodesAreRoundedRectsNotPills() {
        let result = MermaidParser().parse(Self.galleryBeta)
        guard case .sankey(let diagram) = result else {
            Issue.record("Expected sankey")
            return
        }
        let layout = layoutSankey(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        #expect(MermaidSankeyRenderer.nodeCornerRadius <= 4)
        #expect(MermaidSankeyRenderer.nodeCornerRadius < 8, "stadium pills used the old 8pt / half-side cap")

        let positions = layout.graphResult.nodePositions
        let names = Set(diagram.links.flatMap { [$0.source, $0.target] })
        for name in names {
            guard let frame = positions["node-\(name)"] else {
                Issue.record("Expected node-\(name)")
                continue
            }
            let corner = MermaidSankeyRenderer.cornerRadius(for: frame)
            #expect(corner <= 4, "node-\(name) corner \(corner) must stay a 4pt rect")
            #expect(corner + 0.01 < frame.height / 2, "node-\(name) is a vertical stadium")
            #expect(corner + 0.01 < frame.width / 2, "node-\(name) is a horizontal stadium")
        }
        #expect(draw(layout) != nil)
    }

    @Test func galleryRibbonsAreThinStackedAndQuiet() {
        let result = MermaidParser().parse(Self.galleryBeta)
        guard case .sankey(let diagram) = result else {
            Issue.record("Expected sankey")
            return
        }
        let layout = layoutSankey(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        #expect(abs(MermaidSankeyRenderer.ribbonAlpha - 0.22) < 0.005)
        #expect(MermaidSankeyRenderer.ribbonThicknessFactor < 0.75)

        let positions = layout.graphResult.nodePositions
        let ribbons = layout.graphResult.edgePaths
        #expect(ribbons.count == diagram.links.count, "each link must publish an inspectable ribbon")

        var sourceBands: [String: [CGRect]] = [:]
        for path in ribbons {
            #expect(path.points.count == 4, "\(path.from) → \(path.to) should stay a cubic ribbon")
            guard path.points.count == 4,
                  let from = positions["node-\(path.from)"],
                  let to = positions["node-\(path.to)"]
            else { continue }
            let start = path.points[0]
            let c1 = path.points[1]
            let c2 = path.points[2]
            let end = path.points[3]
            #expect(abs(c1.y - start.y) < 0.5, "\(path.from) → \(path.to) should leave in a parallel band")
            #expect(abs(c2.y - end.y) < 0.5, "\(path.from) → \(path.to) should arrive in a parallel band")
            #expect(c1.x > start.x, "ribbon control should stay between the nodes")
            #expect(c2.x < end.x)

            guard let band = positions["ribbon-\(path.from)-\(path.to)"] else {
                Issue.record("Expected ribbon-\(path.from)-\(path.to) thickness frame")
                continue
            }
            #expect(band.height + 0.01 < from.height, "\(path.from) ribbon should not fill its source")
            #expect(band.height + 0.01 < to.height, "\(path.to) ribbon should not fill its sink")
            #expect(abs(band.midY - start.y) < 0.5)
            sourceBands[path.from, default: []].append(band)
        }

        for (source, bands) in sourceBands {
            let sorted = bands.sorted { $0.minY < $1.minY }
            for (previous, next) in zip(sorted, sorted.dropFirst()) {
                #expect(
                    previous.maxY <= next.minY + 0.5,
                    "\(source) ribbons must stack instead of crossing at the node"
                )
            }
        }
        #expect(positions["node-Kanban"] != nil)
        #expect(draw(layout) != nil)
    }

    @Test func emptySankeyIsPlaceholder() {
        let layout = layoutSankey(.empty, maxWidth: 360)
        #expect(layout.isPlaceholder)
    }

    @Test func malformedDoesNotCrash() {
        _ = MermaidParser().parse("sankey\n  A,B")
        _ = MermaidSankeyParser.parse(lines: ["sankey", "not-csv"])
        _ = MermaidSankeyParser.parse(lines: ["sankey-beta", "A,B,-3"])
    }
}

private func layoutSankey(
    _ diagram: SankeyDiagram,
    maxWidth: CGFloat
) -> MermaidFlowchartRenderer.FlowchartLayout {
    MermaidSankeyRenderer.layout(diagram, configuration: .default(maxWidth: maxWidth))
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
