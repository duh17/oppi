import Testing
import UIKit
@testable import Oppi

/// The graphical render cache backs synchronous reader rendering: reused cells
/// must not re-pay parse + layout + rasterize for identical blocks.
@Suite("Document render cache")
struct DocumentRenderCacheTests {
    private func makeConfig(width: CGFloat = 320) -> RenderConfiguration {
        RenderConfiguration(
            fontSize: 22,
            maxWidth: width,
            theme: ThemeID.dark.palette.renderTheme,
            displayMode: .document
        )
    }

    @Test func identicalLaTeXRendersReuseTheSameRaster() throws {
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
    }

    @Test func differentConfigRendersAreDistinct() throws {
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
        let hostile = String(repeating: "x", count: 600)
        #expect(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: hostile,
            config: makeConfig()
        ) == nil)
        #expect(DocumentRenderPipeline.renderLatexGraphicalImage(
            text: hostile,
            config: makeConfig()
        ) == nil)
    }
}
