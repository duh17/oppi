import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import Oppi

@Suite("Mermaid theme and canvas contract")
struct MermaidThemeContractTests {
    /// Test-only registry. The exhaustive switch below makes a new parser case
    /// a compiler-visible contract change without adding test support to production.
    private enum NativeDiagramKind: String, CaseIterable, Hashable, Sendable {
        case flowchart
        case sequence
        case gantt
        case mindmap
        case state
        case pie
        case timeline
        case classDiagram
        case erDiagram
        case xyChart
        case gitGraph
        case quadrantChart
        case sankey
        case kanban
        case journey
    }

    private static let fixtures: [NativeDiagramKind: String] = [
        .flowchart: "flowchart TD\n A[Start] --> B[Done]",
        .sequence: "sequenceDiagram\n Alice->>Bob: Hello",
        .gantt: "gantt\n section Build\n Task :done, task, 2026-08-01, 2d",
        .mindmap: "mindmap\n root((Oppi))\n  Mermaid",
        .state: "stateDiagram-v2\n [*] --> Ready\n Ready --> [*]",
        .pie: "pie title Pets\n \"Dogs\" : 3\n \"Cats\" : 2",
        .timeline: "timeline\n 2025 : Start\n 2026 : Ship",
        .classDiagram: "classDiagram\n Animal <|-- Cat",
        .erDiagram: "erDiagram\n CUSTOMER ||--o{ ORDER : places",
        .xyChart: "xychart-beta\n x-axis [A, B]\n y-axis 0 --> 10\n line [2, 8]",
        .gitGraph: "gitGraph\n commit id: \"a\"\n commit id: \"b\"",
        .quadrantChart: "quadrantChart\n title Reach\n x-axis Low --> High\n y-axis Low --> High\n Campaign A: [0.3, 0.6]",
        .sankey: "sankey\n A,B,4\n B,C,2",
        .kanban: "kanban\n todo[Todo]\n  task1[Ship it]",
        .journey: "journey\n title Day\n section Work\n  Make tea: 5: Me",
    ]

    @Test func registryCoversEveryNativeDiagramKind() throws {
        let registered = Set(Self.fixtures.keys)
        #expect(registered == Set(NativeDiagramKind.allCases))

        let parser = MermaidParser()
        for kind in NativeDiagramKind.allCases {
            let source = try #require(Self.fixtures[kind])
            #expect(Self.nativeKind(of: parser.parse(source)) == kind)
        }
    }

    @Test func everyNativeDiagramLeavesItsCanvasCornersTransparent() throws {
        let parser = MermaidParser()
        let renderer = MermaidRenderer()
        let config = RenderConfiguration.default(maxWidth: 360)

        for kind in NativeDiagramKind.allCases {
            let source = try #require(Self.fixtures[kind])
            let layout = renderer.layout(parser.parse(source), configuration: config)
            #expect(!layout.isPlaceholder, "\(kind.rawValue) must use a native renderer")
            let bitmap = try #require(rasterize(layout, renderer: renderer))

            for corner in bitmap.cornerPixels {
                #expect(
                    corner.allSatisfy { $0 == 0 },
                    "\(kind.rawValue) paints the containing surface's canvas (corner bytes \(corner))"
                )
            }
        }
    }

    @Test func everyNativeDiagramInkStaysInsideTheThemePalette() throws {
        let parser = MermaidParser()
        let renderer = MermaidRenderer()

        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            let config = RenderConfiguration(
                fontSize: 14,
                maxWidth: 360,
                theme: palette.renderTheme,
                displayMode: .document
            )
            let surface = UIColor(palette.bgHighlight).cgColor

            for kind in NativeDiagramKind.allCases {
                let source = try #require(Self.fixtures[kind])
                let layout = renderer.layout(parser.parse(source), configuration: config)
                let bitmap = try #require(rasterize(layout, renderer: renderer, background: surface))
                let foreign = bitmap.foreignInkRatio(
                    surface: surface,
                    theme: palette.renderTheme
                )
                let percent = (foreign * 1000).rounded() / 10
                #expect(
                    foreign < 0.02,
                    "\(kind.rawValue) painted non-theme ink on \(themeID.rawValue) (\(percent)%)"
                )
            }
        }
    }

    @Test func everyBuiltinThemeKeepsVisibleInkOnItsOwnedSurface() throws {
        let parser = MermaidParser()
        let renderer = MermaidRenderer()

        for themeID in ThemeID.builtins {
            let palette = themeID.palette
            let config = RenderConfiguration(
                fontSize: 14,
                maxWidth: 360,
                theme: palette.renderTheme,
                displayMode: .document
            )
            let surface = UIColor(palette.bgHighlight).cgColor

            for kind in NativeDiagramKind.allCases {
                let source = try #require(Self.fixtures[kind])
                let layout = renderer.layout(parser.parse(source), configuration: config)
                let bitmap = try #require(rasterize(layout, renderer: renderer, background: surface))
                let surfacePixel = bitmap.cornerPixels[0]

                #expect(
                    bitmap.cornerPixels.allSatisfy { $0 == surfacePixel },
                    "\(kind.rawValue) must not replace the \(themeID.rawValue) containing surface"
                )
                #expect(
                    bitmap.pixelCount(differentFrom: surfacePixel) > 40,
                    "\(kind.rawValue) must retain semantic ink on \(themeID.rawValue)"
                )
                #expect(
                    bitmap.maximumContrast(against: surfacePixel) >= 3,
                    "\(kind.rawValue) semantic ink needs visible contrast on \(themeID.rawValue)"
                )
            }
        }
    }

    @Test @MainActor func inlineReuseUsesTheSuppliedPaletteAndInvalidatesForThemeChanges() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()

        let source = "flowchart TD\n A[Start] --> B[Done]"
        let view = NativeMermaidBlockView()
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 300)

        ThemeRuntimeState.setThemeID(.light)
        view.applyAsDiagramSync(code: source, palette: ThemePalettes.dark)
        let suppliedDarkImage = try #require(view.debugRenderedImageForTesting)
        #expect(view.debugRenderCountForTesting == 1)

        view.applyAsDiagramSync(code: source, palette: ThemePalettes.dark)
        #expect(view.debugRenderCountForTesting == 1, "Identical theme and source should reuse the raster")

        view.applyAsDiagramSync(code: source, palette: ThemePalettes.light)
        let suppliedLightImage = try #require(view.debugRenderedImageForTesting)
        #expect(view.debugRenderCountForTesting == 2, "A palette change must invalidate render reuse")
        #expect(
            suppliedDarkImage.pngData() != suppliedLightImage.pngData(),
            "The graphical cache must keep theme-specific rasters separate"
        )

        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        ThemeRuntimeState.setThemeID(.dark)
        let control = NativeMermaidBlockView()
        control.frame = view.frame
        control.applyAsDiagramSync(code: source, palette: ThemePalettes.dark)
        let runtimeDarkImage = try #require(control.debugRenderedImageForTesting)

        #expect(
            suppliedDarkImage.pngData() == runtimeDarkImage.pngData(),
            "Raster colors must come from the supplied palette, not stale runtime theme state"
        )
    }

    @Test @MainActor func rapidThemeReversalCannotCommitTheCancelledRaster() async throws {
        let initial = NativeMermaidBlockView.RasterResult(
            image: Self.solidImage(color: .red),
            size: CGSize(width: 120, height: 80)
        )
        let stale = NativeMermaidBlockView.RasterResult(
            image: Self.solidImage(color: .green),
            size: CGSize(width: 120, height: 80)
        )
        let controlled = ControlledMermaidRasterizer()
        let view = NativeMermaidBlockView(rasterizer: .init(
            renderSync: { _, _, _ in initial },
            renderAsync: { _, _, _ in await controlled.render() }
        ))
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 200)

        view.applyAsDiagramSync(code: "flowchart TD\n A --> B", palette: ThemePalettes.dark)
        let expected = try #require(view.debugRenderedImageForTesting?.pngData())

        view.applyAsDiagram(code: "flowchart TD\n A --> B", palette: ThemePalettes.light)
        await controlled.waitUntilRequested()
        view.applyAsDiagram(code: "flowchart TD\n A --> B", palette: ThemePalettes.dark)
        await controlled.finish(with: stale)
        await Task.yield()
        await Task.yield()

        #expect(
            view.debugRenderedImageForTesting?.pngData() == expected,
            "Completing a cancelled light render must not replace the desired dark raster"
        )
    }

    private static func nativeKind(of diagram: MermaidDiagram) -> NativeDiagramKind? {
        switch diagram {
        case .flowchart: .flowchart
        case .sequence: .sequence
        case .gantt: .gantt
        case .mindmap: .mindmap
        case .state: .state
        case .pie: .pie
        case .timeline: .timeline
        case .classDiagram: .classDiagram
        case .erDiagram: .erDiagram
        case .xyChart: .xyChart
        case .gitGraph: .gitGraph
        case .quadrantChart: .quadrantChart
        case .sankey: .sankey
        case .kanban: .kanban
        case .journey: .journey
        case .unsupported: nil
        }
    }

    private static func solidImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private func rasterize(
        _ layout: MermaidFlowchartRenderer.FlowchartLayout,
        renderer: MermaidRenderer,
        background: CGColor? = nil
    ) -> PaintedBitmap? {
        let size = renderer.boundingBox(layout)
        let width = max(Int(ceil(size.width)), 1)
        let height = max(Int(ceil(size.height)), 1)
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            if let background {
                context.setFillColor(background)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            renderer.draw(layout, in: context, at: .zero)
            return true
        }
        return drew ? PaintedBitmap(pixels: pixels, width: width, height: height) : nil
    }

    private struct PaintedBitmap {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        var cornerPixels: [[UInt8]] {
            [
                pixel(x: 0, y: 0),
                pixel(x: width - 1, y: 0),
                pixel(x: 0, y: height - 1),
                pixel(x: width - 1, y: height - 1),
            ]
        }

        func pixelCount(differentFrom reference: [UInt8]) -> Int {
            var count = 0
            for y in 0..<height {
                for x in 0..<width where pixel(x: x, y: y) != reference {
                    count += 1
                }
            }
            return count
        }

        func maximumContrast(against reference: [UInt8]) -> CGFloat {
            let background = luminance(reference)
            var maximum: CGFloat = 1
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    let foreground = luminance(pixel(x: x, y: y))
                    let lighter = max(foreground, background)
                    let darker = min(foreground, background)
                    maximum = max(maximum, (lighter + 0.05) / (darker + 0.05))
                }
            }
            return maximum
        }

        /// Share of sampled opaque pixels that are not a theme ink or a blend
        /// of two theme/surface inks. Author `style` hex is out of scope;
        /// these fixtures never set it.
        func foreignInkRatio(surface: CGColor, theme: RenderTheme) -> Double {
            var allowed = theme.paletteInks.compactMap(sRGB)
            if let surfaceRGB = sRGB(surface) {
                allowed.append(surfaceRGB)
            }
            var foreign = 0
            var sampled = 0
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    let sample = pixel(x: x, y: y)
                    guard sample.count == 4, sample[3] > 8 else { continue }
                    sampled += 1
                    if !isThemeInk(sample, allowed: allowed) {
                        foreign += 1
                    }
                }
            }
            return sampled == 0 ? 1 : Double(foreign) / Double(sampled)
        }

        private func isThemeInk(_ pixel: [UInt8], allowed: [(CGFloat, CGFloat, CGFloat)]) -> Bool {
            let sample = (
                CGFloat(pixel[0]) / 255,
                CGFloat(pixel[1]) / 255,
                CGFloat(pixel[2]) / 255
            )
            let slop: CGFloat = 0.09
            if allowed.contains(where: { distance(sample, $0) <= slop }) {
                return true
            }
            for i in allowed.indices {
                for j in allowed.indices where j > i {
                    if distanceToSegment(sample, allowed[i], allowed[j]) <= slop {
                        return true
                    }
                }
            }
            return false
        }

        private func sRGB(_ color: CGColor) -> (CGFloat, CGFloat, CGFloat)? {
            guard
                let space = CGColorSpace(name: CGColorSpace.sRGB),
                let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
                let c = converted.components, c.count >= 3
            else { return nil }
            return (c[0], c[1], c[2])
        }

        private func distance(
            _ a: (CGFloat, CGFloat, CGFloat),
            _ b: (CGFloat, CGFloat, CGFloat)
        ) -> CGFloat {
            let dr = a.0 - b.0
            let dg = a.1 - b.1
            let db = a.2 - b.2
            return (dr * dr + dg * dg + db * db).squareRoot()
        }

        private func distanceToSegment(
            _ p: (CGFloat, CGFloat, CGFloat),
            _ a: (CGFloat, CGFloat, CGFloat),
            _ b: (CGFloat, CGFloat, CGFloat)
        ) -> CGFloat {
            let ab = (b.0 - a.0, b.1 - a.1, b.2 - a.2)
            let ap = (p.0 - a.0, p.1 - a.1, p.2 - a.2)
            let denom = ab.0 * ab.0 + ab.1 * ab.1 + ab.2 * ab.2
            guard denom > 0.0001 else { return distance(p, a) }
            let t = min(1, max(0, (ap.0 * ab.0 + ap.1 * ab.1 + ap.2 * ab.2) / denom))
            return distance(p, (a.0 + ab.0 * t, a.1 + ab.1 * t, a.2 + ab.2 * t))
        }

        private func pixel(x: Int, y: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return Array(pixels[offset..<(offset + 4)])
        }

        private func luminance(_ pixel: [UInt8]) -> CGFloat {
            func linearized(_ value: UInt8) -> CGFloat {
                let component = CGFloat(value) / 255
                return component <= 0.03928
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linearized(pixel[0])
                + 0.7152 * linearized(pixel[1])
                + 0.0722 * linearized(pixel[2])
        }
    }
}

private actor ControlledMermaidRasterizer {
    private var pending: CheckedContinuation<NativeMermaidBlockView.RasterResult?, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?

    func render() async -> NativeMermaidBlockView.RasterResult? {
        await withCheckedContinuation { continuation in
            pending = continuation
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }

    func waitUntilRequested() async {
        guard pending == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiter = continuation
        }
    }

    func finish(with result: NativeMermaidBlockView.RasterResult?) {
        pending?.resume(returning: result)
        pending = nil
    }
}
