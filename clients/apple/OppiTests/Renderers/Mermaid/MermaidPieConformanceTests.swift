import CoreGraphics
import Testing
@testable import Oppi

// SPEC: https://mermaid.js.org/syntax/pie.html (tagged v11.17.0)
//
// Tests call the dedicated parser/renderer directly. The shared
// dispatcher (MermaidParser / MermaidFlowchartRenderer.layout) is not
// wired to `pie` until the one-line integrator lands, so the conformance
// suite exercises MermaidPieParser and MermaidPieRenderer in isolation.
//
// COVERAGE:
// [x] pie keyword + dataset
// [x] showData flag (on pie line and as own line)
// [x] title (quoted, unquoted, and on the pie header line)
// [x] official `pie title Pets adopted by volunteers` example
// [x] quoted labels containing colons
// [x] slice order preserved (declaration order)
// [x] values parsed and summed
// [x] huge showData values format without Int overflow
// [x] non-positive values skipped without crashing
// [x] non-numeric values skipped without crashing
// [x] renderer produces a non-placeholder layout with non-empty size
// [x] renderer draws showData values, wraps long labels, stacks at
//     narrow widths, and keeps slice text readable in light and dark

@Suite("Pie Conformance — Mermaid v11.17.0")
struct MermaidPieConformanceTests {

    /// Official v11.17 example from the pie syntax page.
    private static let officialPetsLines = [
        "pie title Pets adopted by volunteers",
        "    \"Dogs\" : 386",
        "    \"Cats\" : 85",
        "    \"Rats\" : 15",
    ]

    // MARK: - Parser

    /// SPEC: basic `pie` with quoted labels and positive values.
    @Test func basicPie() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "\"Dogs\" : 50",
            "\"Cats\" : 30",
            "\"Birds\" : 20",
        ])
        #expect(diagram.title == nil)
        #expect(diagram.showData == false)
        #expect(diagram.slices.count == 3)
        #expect(diagram.slices[0] == PieSlice(label: "Dogs", value: 50))
        #expect(diagram.slices[1] == PieSlice(label: "Cats", value: 30))
        #expect(diagram.slices[2] == PieSlice(label: "Birds", value: 20))
    }

    /// SPEC: `pie showData` renders the actual data values after the legend text.
    @Test func showDataOnHeaderLine() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie showData",
            "\"A\" : 1",
            "\"B\" : 2",
        ])
        #expect(diagram.showData == true)
        #expect(diagram.slices.count == 2)
    }

    /// A bare `showData` line in the body is also accepted.
    @Test func showDataAsOwnLine() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "showData",
            "\"A\" : 1",
        ])
        #expect(diagram.showData == true)
    }

    /// SPEC: optional `title` followed by its value.
    @Test func titleUnquoted() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "title Pets in a household",
            "\"Dogs\" : 50",
        ])
        #expect(diagram.title == "Pets in a household")
        #expect(diagram.slices.count == 1)
    }

    /// `title` value may be quoted.
    @Test func titleQuoted() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "title \"Pets\"",
            "\"Dogs\" : 1",
        ])
        #expect(diagram.title == "Pets")
    }

    /// SPEC official example: `pie title Pets adopted by volunteers`.
    @Test func officialExampleKeepsTitleOnHeaderLine() {
        let diagram = MermaidPieParser.parse(lines: Self.officialPetsLines)
        #expect(diagram.title == "Pets adopted by volunteers")
        #expect(diagram.showData == false)
        #expect(diagram.slices.map(\.label) == ["Dogs", "Cats", "Rats"])
        #expect(diagram.slices.map(\.value) == [386, 85, 15])
    }

    /// SPEC: `pie showData title ...` on one line keeps both the flag and title.
    @Test func showDataAndTitleOnOneLine() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie showData title Pets adopted by volunteers",
            "\"Dogs\" : 386",
            "\"Cats\" : 85",
            "\"Rats\" : 15",
        ])
        #expect(diagram.showData == true)
        #expect(diagram.title == "Pets adopted by volunteers")
        #expect(diagram.slices.count == 3)
    }

    /// Quoted labels may contain colons. Split after the closing quote.
    @Test func quotedLabelContainingColon() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "\"HTTP: 5xx\" : 10",
            "\"HTTP: 4xx\" : 20",
        ])
        #expect(diagram.slices.count == 2)
        #expect(diagram.slices[0] == PieSlice(label: "HTTP: 5xx", value: 10))
        #expect(diagram.slices[1] == PieSlice(label: "HTTP: 4xx", value: 20))
    }

    /// SPEC: slice order is declaration order (Mermaid draws clockwise in label order).
    @Test func sliceOrderPreserved() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "\"First\" : 10",
            "\"Second\" : 20",
            "\"Third\" : 30",
            "\"Fourth\" : 40",
        ])
        let labels = diagram.slices.map(\.label)
        #expect(labels == ["First", "Second", "Third", "Fourth"])
        let values = diagram.slices.map(\.value)
        #expect(values == [10, 20, 30, 40])
    }

    /// SPEC: values support up to two decimal places.
    @Test func decimalValues() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "\"A\" : 12.5",
            "\"B\" : 0.25",
            "\"C\" : 87.25",
        ])
        #expect(diagram.slices.map(\.value) == [12.5, 0.25, 87.25])
    }

    /// Finite values above Int.max stay parseable. Formatting must not
    /// trap on `Int(rounded)`.
    @Test func hugePositiveValueParsesAndFormats() {
        let raw = "100000000000000000000"
        let diagram = MermaidPieParser.parse(lines: [
            "pie showData",
            "\"Huge\" : \(raw)",
        ])
        #expect(diagram.slices.count == 1)
        #expect(diagram.slices[0].label == "Huge")
        #expect(diagram.slices[0].value.isFinite)
        #expect(diagram.slices[0].value > Double(Int.max))
        #expect(MermaidPieRenderer.formatDataValue(diagram.slices[0].value) == raw)
        #expect(MermaidPieRenderer.formatDataValue(12.5) == "12.5")
        #expect(MermaidPieRenderer.formatDataValue(15) == "15")
    }

    /// SPEC: pie values must be positive numbers greater than zero.
    /// Negative values are not allowed and would error upstream. We skip
    /// them without crashing.
    @Test func nonPositiveValuesSkipped() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "\"A\" : 10",
            "\"B\" : 0",
            "\"C\" : -5",
            "\"D\" : 20",
        ])
        #expect(diagram.slices.count == 2)
        #expect(diagram.slices[0].label == "A")
        #expect(diagram.slices[1].label == "D")
    }

    /// Non-numeric values are skipped without crashing.
    @Test func nonNumericValuesSkipped() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "\"A\" : 10",
            "\"B\" : not-a-number",
            "\"C\" : 20",
        ])
        #expect(diagram.slices.count == 2)
        #expect(diagram.slices.map(\.label) == ["A", "C"])
    }

    /// `%%` comments and blank lines are ignored.
    @Test func commentsAndBlanksIgnored() {
        let diagram = MermaidPieParser.parse(lines: [
            "%% a comment",
            "",
            "pie",
            "%% another comment",
            "\"A\" : 1",
            "",
            "\"B\" : 2",
        ])
        #expect(diagram.slices.count == 2)
        #expect(diagram.slices.map(\.label) == ["A", "B"])
    }

    /// Empty body yields an empty diagram, not a crash.
    @Test func emptyBody() {
        let diagram = MermaidPieParser.parse(lines: ["pie"])
        #expect(diagram.slices.isEmpty)
        #expect(diagram.showData == false)
        #expect(diagram.title == nil)
    }

    // MARK: - Renderer

    /// Renderer produces a non-placeholder layout with a non-empty size
    /// for a real diagram.
    @Test func rendererProducesNonPlaceholderLayout() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "title Pets",
            "\"Dogs\" : 50",
            "\"Cats\" : 30",
            "\"Birds\" : 20",
        ])
        let layout = layoutPie(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        #expect(layout.customDraw != nil)
        guard let size = layout.customSize else {
            Issue.record("Expected non-nil customSize")
            return
        }
        #expect(size.width > 0)
        #expect(size.height > 0)
    }

    /// Empty diagram yields a placeholder layout, not a crash.
    @Test func emptyDiagramYieldsPlaceholder() {
        let layout = layoutPie(.empty, maxWidth: 360)
        #expect(layout.isPlaceholder == true)
        #expect(layout.customDraw == nil)
    }

    /// Renderer respects maxWidth and stays readable on a ~360pt bubble.
    @Test func rendererStaysWithinBoundedWidth() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie",
            "\"A\" : 10",
            "\"B\" : 20",
            "\"C\" : 30",
        ])
        let layout = layoutPie(diagram, maxWidth: 360)
        guard let size = layout.customSize else {
            Issue.record("Expected non-nil customSize")
            return
        }
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(size.width <= 360)
    }

    /// Official example keeps the title in layout facts and on the canvas.
    @Test func officialExampleRendersTitle() {
        let diagram = MermaidPieParser.parse(lines: Self.officialPetsLines)
        #expect(diagram.title == "Pets adopted by volunteers")
        let layout = layoutPie(diagram, maxWidth: 360)
        #expect(layout.nodeLabels["$title"]?.contains("Pets adopted by volunteers") == true
            || layout.nodeLabels["$title"]?.contains("Pets adopted") == true)
        #expect(layout.graphResult.nodePositions["title"] != nil)
        guard let size = layout.customSize, let title = layout.graphResult.nodePositions["title"] else {
            Issue.record("Expected titled layout")
            return
        }
        #expect(title.maxX <= size.width + 0.5)
        #expect(title.width <= 360)
        #expect(draw(layout) != nil)
    }

    /// `showData` draws the actual values after the legend labels.
    @Test func rendererDrawsShowDataText() {
        let withData = MermaidPieParser.parse(lines: [
            "pie showData",
            "title Sales",
            "\"Dogs\" : 386",
            "\"Cats\" : 85",
        ])
        let withoutData = PieDiagram(
            title: withData.title,
            slices: withData.slices,
            showData: false
        )
        #expect(withData.showData == true)

        let shown = layoutPie(withData, maxWidth: 360)
        let hidden = layoutPie(withoutData, maxWidth: 360)
        #expect(shown.nodeLabels["Dogs"]?.contains("386") == true)
        #expect(shown.nodeLabels["Cats"]?.contains("85") == true)
        #expect(shown.nodeLabels["Dogs"]?.contains("Dogs") == true)
        #expect(hidden.nodeLabels["Dogs"] == "Dogs")

        guard let shownPaint = draw(shown),
              let hiddenPaint = draw(hidden),
              let legend = shown.graphResult.nodePositions["legend"]
        else {
            Issue.record("Expected painted showData / legend layouts")
            return
        }
        let shownInk = shownPaint.nonBackgroundCount(in: legend, background: shown.theme.background)
        let hiddenInk = hiddenPaint.nonBackgroundCount(in: legend, background: hidden.theme.background)
        #expect(shownInk > hiddenInk)
    }

    /// Long titles and legend labels wrap/truncate inside maxWidth.
    @Test func longLabelsWrapWithinMaxWidth() {
        let longTitle = "This is an extremely long pie chart title that would overflow a phone bubble if the renderer never wrapped or truncated it"
        let longLabel = "This is an extremely long legend label about volunteer adoption statistics across several regions"
        let longDiagram = MermaidPieParser.parse(lines: [
            "pie title \(longTitle)",
            "\"\(longLabel)\" : 10",
            "\"Cats\" : 5",
        ])
        #expect(longDiagram.title == longTitle)
        #expect(longDiagram.slices[0].label == longLabel)

        let shortDiagram = MermaidPieParser.parse(lines: [
            "pie title Pets",
            "\"Dogs\" : 10",
            "\"Cats\" : 5",
        ])

        let longLayout = layoutPie(longDiagram, maxWidth: 360)
        let shortLayout = layoutPie(shortDiagram, maxWidth: 360)
        guard let longSize = longLayout.customSize,
              let shortSize = shortLayout.customSize,
              let titleRect = longLayout.graphResult.nodePositions["title"],
              let legendRect = longLayout.graphResult.nodePositions["legend"]
        else {
            Issue.record("Expected long-label layout facts")
            return
        }
        #expect(longSize.width <= 360)
        #expect(titleRect.width <= 360)
        #expect(titleRect.maxX <= longSize.width + 0.5)
        #expect(legendRect.maxX <= longSize.width + 0.5)
        #expect(longSize.height > shortSize.height)

        let wrappedTitle = longLayout.nodeLabels["$title"] ?? ""
        #expect(wrappedTitle.contains("\n") || wrappedTitle.contains("…"))
        #expect(wrappedTitle.contains("extremely long pie chart title"))

        let wrappedLegend = longLayout.nodeLabels[longLabel] ?? ""
        #expect(wrappedLegend.contains("\n") || wrappedLegend.contains("…"))
        // Wrapping inserts newlines; flatten before checking the source phrase.
        let flattenedLegend = wrappedLegend.replacingOccurrences(of: "\n", with: " ")
        #expect(flattenedLegend.contains("extremely long legend label"))
        #expect(draw(longLayout) != nil)
    }

    /// At narrow widths the legend stacks below the pie instead of clipping.
    @Test func stackedLegendAtNarrowWidth() {
        let diagram = MermaidPieParser.parse(lines: Self.officialPetsLines)
        let wide = layoutPie(diagram, maxWidth: 360)
        let narrow = layoutPie(diagram, maxWidth: 200)
        guard let widePie = wide.graphResult.nodePositions["pie"],
              let wideLegend = wide.graphResult.nodePositions["legend"],
              let narrowPie = narrow.graphResult.nodePositions["pie"],
              let narrowLegend = narrow.graphResult.nodePositions["legend"],
              let narrowSize = narrow.customSize
        else {
            Issue.record("Expected pie/legend frames")
            return
        }
        #expect(wideLegend.minX >= widePie.maxX - 1)
        #expect(narrowLegend.minY >= narrowPie.maxY - 1)
        #expect(narrowSize.width <= 200)
        #expect((narrow.customSize?.height ?? 0) > (wide.customSize?.height ?? 0))
    }

    /// Quoted colon labels survive into the drawn legend.
    @Test func colonLabelAppearsInLegend() {
        let diagram = MermaidPieParser.parse(lines: [
            "pie showData",
            "\"HTTP: 5xx\" : 10",
            "\"OK\" : 90",
        ])
        #expect(diagram.slices[0].label == "HTTP: 5xx")
        let layout = layoutPie(diagram, maxWidth: 360)
        let text = layout.nodeLabels["HTTP: 5xx"] ?? ""
        #expect(text.contains("HTTP: 5xx"))
        #expect(text.contains("10"))
        #expect(draw(layout) != nil)
    }

    /// Huge `showData` values draw without trapping on Int conversion.
    @Test func hugeShowDataValueDoesNotTrap() {
        let raw = "100000000000000000000"
        let diagram = MermaidPieParser.parse(lines: [
            "pie showData",
            "\"Huge\" : \(raw)",
            "\"Small\" : 1",
        ])
        let wide = layoutPie(diagram, maxWidth: 800)
        #expect(wide.nodeLabels["Huge"]?.contains(raw) == true)
        let narrow = layoutPie(diagram, maxWidth: 360)
        #expect(narrow.isPlaceholder == false)
        #expect(draw(narrow) != nil)
        #expect(draw(wide) != nil)
    }

    /// Slice percentage text stays readable on every accent in light and dark.
    @Test func slicePercentagesHaveContrastInLightAndDark() {
        let themes: [RenderTheme] = [.fallback, .light]
        for theme in themes {
            let palette = [
                theme.accentBlue,
                theme.accentGreen,
                theme.accentOrange,
                theme.accentPurple,
                theme.accentRed,
                theme.accentYellow,
                theme.accentCyan,
            ]
            for fill in palette {
                let label = MermaidPieRenderer.sliceLabelColor(on: fill, theme: theme)
                #expect(contrastRatio(label, fill) >= 3.0)
            }

            let diagram = MermaidPieParser.parse(lines: [
                "pie",
                "\"Only\" : 1",
            ])
            let config = RenderConfiguration(
                fontSize: 14,
                maxWidth: 360,
                theme: theme,
                displayMode: .document
            )
            let layout = MermaidPieRenderer.layout(diagram, configuration: config)
            guard let paint = draw(layout),
                  let pie = layout.graphResult.nodePositions["pie"]
            else {
                Issue.record("Expected painted pie for contrast check")
                continue
            }
            // One 100% slice: label sits at textPosition toward the bottom.
            let labelPoint = CGPoint(x: pie.midX, y: pie.midY + pie.height * 0.36)
            let window = CGRect(x: labelPoint.x - 16, y: labelPoint.y - 10, width: 32, height: 20)
            let fill = theme.accentBlue
            let distinct = paint.distinctFromFill(in: window, fill: fill)
            #expect(distinct > 0)
            #expect(paint.maxContrast(in: window, against: fill) >= 3.0)
        }
    }

    /// Renderer with many slices still produces a usable layout.
    @Test func rendererWithManySlices() {
        var lines = ["pie"]
        for i in 1...12 {
            lines.append("\"S\(i)\" : \(i)")
        }
        let diagram = MermaidPieParser.parse(lines: lines)
        #expect(diagram.slices.count == 12)
        let layout = layoutPie(diagram, maxWidth: 360)
        #expect(layout.isPlaceholder == false)
        guard let size = layout.customSize else {
            Issue.record("Expected non-nil customSize")
            return
        }
        #expect(size.width > 0)
        #expect(size.height > 0)
        #expect(size.width <= 360)
        #expect(draw(layout) != nil)
    }

    /// Fullscreen 800pt must keep the chat pie ratio. Padding the canvas
    /// to maxWidth produces an 800×~220 strip that aspect-fit flattens.
    @Test func documentWidthKeepsInlinePieRatio() {
        let diagram = MermaidPieParser.parse(lines: Self.officialPetsLines)
        let inline = layoutPie(diagram, maxWidth: 360)
        let document = layoutPie(diagram, maxWidth: 800)
        guard let inlineSize = inline.customSize,
              let documentSize = document.customSize,
              let inlinePie = inline.graphResult.nodePositions["pie"],
              let inlineLegend = inline.graphResult.nodePositions["legend"],
              let documentPie = document.graphResult.nodePositions["pie"],
              let documentLegend = document.graphResult.nodePositions["legend"]
        else {
            Issue.record("Expected pie/legend frames at 360 and 800")
            return
        }
        #expect(inlineLegend.minX >= inlinePie.maxX - 1)
        #expect(documentLegend.minX >= documentPie.maxX - 1)
        #expect(inlineSize.width <= 360)
        #expect(
            documentSize.width < 800 - 1,
            "Pie must size to content, not pad to the 800pt document canvas, got \(documentSize)"
        )
        #expect(inlineSize.width > 0 && documentSize.width > 0)
        let inlineRatio = inlineSize.height / inlineSize.width
        let documentRatio = documentSize.height / documentSize.width
        #expect(
            abs(inlineRatio - documentRatio) < 0.06,
            "360 vs 800 pie ratios diverged: inline=\(inlineRatio) document=\(documentRatio) sizes=\(inlineSize) / \(documentSize)"
        )
        #expect(draw(document) != nil)
    }
}

// MARK: - Helpers

private func layoutPie(
    _ diagram: PieDiagram,
    maxWidth: CGFloat
) -> MermaidFlowchartRenderer.FlowchartLayout {
    MermaidPieRenderer.layout(diagram, configuration: .default(maxWidth: maxWidth))
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
        let minX = max(Int(floor(rect.minX)), 0)
        let maxX = min(Int(ceil(rect.maxX)), width)
        let minY = max(Int(floor(rect.minY)), 0)
        let maxY = min(Int(ceil(rect.maxY)), height)
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let px = pixel(x, y) else { continue }
                if distance(px, bg) > 0.08 { count += 1 }
            }
        }
        return count
    }

    func distinctFromFill(in rect: CGRect, fill: CGColor) -> Int {
        guard let fillRGB = sRGB(fill) else { return 0 }
        var count = 0
        visit(rect) { px in
            if distance(px, fillRGB) > 0.12 { count += 1 }
        }
        return count
    }

    func maxContrast(in rect: CGRect, against fill: CGColor) -> CGFloat {
        guard let fillRGB = sRGB(fill) else { return 1 }
        var best: CGFloat = 1
        visit(rect) { px in
            if distance(px, fillRGB) > 0.12 {
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

private func contrastRatio(_ a: CGColor, _ b: CGColor) -> CGFloat {
    guard let lhs = sRGB(a), let rhs = sRGB(b) else { return 1 }
    return contrastRatio(lhs, rhs)
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
