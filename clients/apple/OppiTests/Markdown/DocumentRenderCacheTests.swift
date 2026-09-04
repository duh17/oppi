import Testing
import UIKit
@testable import Oppi

/// The graphical render cache backs synchronous reader rendering: reused cells
/// must not re-pay parse + layout + rasterize for identical blocks.
/// Parse/layout are cached separately from rasters so a 1 pt width retry and a
/// theme-stable scale redraw do not re-parse.
@Suite("Document render cache", .serialized)
struct DocumentRenderCacheTests {
    private func makeConfig(width: CGFloat = 320, theme: RenderTheme = ThemeID.dark.palette.renderTheme) -> RenderConfiguration {
        RenderConfiguration(
            fontSize: 22,
            maxWidth: width,
            theme: theme,
            displayMode: .document
        )
    }

    private func makeMermaidConfig(
        width: CGFloat,
        theme: RenderTheme = ThemeID.dark.palette.renderTheme
    ) -> RenderConfiguration {
        RenderConfiguration(
            fontSize: 13,
            maxWidth: width,
            theme: theme,
            displayMode: .inline
        )
    }

    private static let flowchart = """
    flowchart TD
        A[Start] --> B[Done]
    """

    @Test func identicalLaTeXRendersReuseTheSameRaster() throws {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let first = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "\\frac{1}{2}H",
            config: makeConfig()
        ))
        let second = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "\\frac{1}{2}H",
            config: makeConfig()
        ))
        #expect(first.image === second.image, "identical input should hit the render cache")
        #expect(first.size == second.size)
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1)
        #expect(DocumentRenderPipeline.debugLayoutCountForTesting == 1)
    }

    @Test func differentConfigRendersAreDistinct() throws {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let narrow = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "\\frac{1}{2}H",
            config: makeConfig(width: 200)
        ))
        let wide = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "\\frac{1}{2}H",
            config: makeConfig(width: 340)
        ))
        #expect(narrow.image !== wide.image, "different widths must not share a raster")
    }

    @Test func differentSourceRendersAreDistinct() throws {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let a = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "\\frac{1}{2}",
            config: makeConfig()
        ))
        let b = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "\\frac{3}{4}",
            config: makeConfig()
        ))
        #expect(a.image !== b.image, "different sources must not share a raster")
    }

    @Test func unrenderableSourceCachesItsNegativeResult() {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let hostile = String(repeating: "x", count: 600)
        #expect(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: hostile,
            config: makeConfig()
        ) == nil)
        #expect(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: hostile,
            config: makeConfig()
        ) == nil)
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1)
    }

    @Test func onePointWidthRetryDoesNotReparseLaTeX() throws {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let first = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "\\frac{1}{2}H",
            config: makeConfig(width: 320)
        ))
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1)
        let layoutsAfterFirst = DocumentRenderPipeline.debugLayoutCountForTesting
        let second = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "\\frac{1}{2}H",
            config: makeConfig(width: 321)
        ))
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1, "1 pt width retry must reuse the TeX AST")
        #expect(first.image !== second.image, "rounded width still owns its own raster")
        #expect(DocumentRenderPipeline.debugLayoutCountForTesting >= layoutsAfterFirst)
    }

    @Test func onePointWidthRetryDoesNotReparseMermaid() throws {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let first = try #require(DocumentRenderPipeline.renderInlineGraphicalImage(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: Self.flowchart,
            config: makeMermaidConfig(width: 320)
        ))
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1)
        let second = try #require(DocumentRenderPipeline.renderInlineGraphicalImage(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: Self.flowchart,
            config: makeMermaidConfig(width: 321)
        ))
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1, "1 pt width retry must reuse the Mermaid AST")
        #expect(first.image !== second.image, "rounded width still owns its own raster")
        #expect(first.size.width > 0 && first.size.height > 0)
        #expect(second.size.width > 0 && second.size.height > 0)
    }

    @Test func themeStableScaleRedrawReusesLayoutWithoutReparse() throws {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let config = makeConfig()
        let first = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "E = mc^2",
            config: config,
            scale: 2
        ))
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1)
        #expect(DocumentRenderPipeline.debugLayoutCountForTesting == 1)
        let second = try #require(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: "E = mc^2",
            config: config,
            scale: 3
        ))
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1)
        #expect(DocumentRenderPipeline.debugLayoutCountForTesting == 1, "scale is raster-only; CPU layout must be reused")
        #expect(first.image !== second.image)
        #expect(first.size == second.size)
    }

    @Test func themeChangeDoesNotReparseMermaid() throws {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let dark = try #require(DocumentRenderPipeline.renderInlineGraphicalImage(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: Self.flowchart,
            config: makeMermaidConfig(width: 360, theme: ThemeID.dark.palette.renderTheme)
        ))
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1)
        let light = try #require(DocumentRenderPipeline.renderInlineGraphicalImage(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: Self.flowchart,
            config: makeMermaidConfig(width: 360, theme: ThemeID.light.palette.renderTheme)
        ))
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1, "theme-stable AST; theme change still rasters")
        #expect(dark.image !== light.image)
        #expect(DocumentRenderPipeline.debugLayoutCountForTesting == 2)
    }

    @Test func layoutGraphicalHitSkipsParseOnSecondCall() {
        DocumentRenderPipeline.debugRemoveAllCachedRendersForTesting()
        let config = makeMermaidConfig(width: 400)
        let first = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: Self.flowchart,
            config: config
        )
        let second = DocumentRenderPipeline.layoutGraphical(
            parser: MermaidParser(),
            renderer: MermaidRenderer(),
            text: Self.flowchart,
            config: config
        )
        #expect(DocumentRenderPipeline.debugParseCountForTesting == 1)
        #expect(DocumentRenderPipeline.debugLayoutCountForTesting == 1)
        #expect(first.size == second.size)
        #expect(first.size.height > 0)
    }
}
