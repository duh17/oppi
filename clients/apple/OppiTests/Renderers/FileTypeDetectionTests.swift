import Testing
@testable import Oppi

/// Tests FileKind detection for document renderer file extensions.
@Suite("FileKind Detection — Document Renderers")
struct FileTypeDetectionTests {

    // MARK: - LaTeX

    @Test func detectTexExtension() {
        #expect(FileKind.detect(from: "document.tex") == .latex)
    }

    @Test func detectLatexExtension() {
        #expect(FileKind.detect(from: "paper.latex") == .latex)
    }

    @Test func detectTexInSubdirectory() {
        #expect(FileKind.detect(from: "src/math/equation.tex") == .latex)
    }

    // MARK: - Org Mode

    @Test func detectOrgExtension() {
        #expect(FileKind.detect(from: "notes.org") == .orgMode)
    }

    @Test func detectOrgInSubdirectory() {
        #expect(FileKind.detect(from: "docs/TODO.org") == .orgMode)
    }

    // MARK: - Mermaid

    @Test func detectMmdExtension() {
        #expect(FileKind.detect(from: "diagram.mmd") == .mermaid)
    }

    @Test func detectMermaidExtension() {
        #expect(FileKind.detect(from: "flow.mermaid") == .mermaid)
    }

    // MARK: - Graphviz

    @Test func detectDotExtension() {
        #expect(FileKind.detect(from: "graph.dot") == .graphviz)
    }

    @Test func detectGvExtension() {
        #expect(FileKind.detect(from: "tree.gv") == .graphviz)
    }

    // MARK: - CSV / TSV

    @Test func detectCsvExtension() {
        #expect(FileKind.detect(from: "export.csv") == .csv)
        #expect(FileKind.detect(from: "EXPORT.CSV") == .csv)
        #expect(FileKind.detect(from: "metrics/rides.csv") == .csv)
    }

    @Test func detectTsvExtension() {
        #expect(FileKind.detect(from: "export.tsv") == .tsv)
        #expect(FileKind.detect(from: "notes.TSV") == .tsv)
    }

    // MARK: - GeoJSON / TopoJSON

    @Test func detectGeojsonExtension() {
        #expect(FileKind.detect(from: "park.geojson") == .geojson)
        #expect(FileKind.detect(from: "PARK.GEOJSON") == .geojson)
    }

    @Test func detectTopojsonExtension() {
        #expect(FileKind.detect(from: "counties.topojson") == .topojson)
    }

    @Test func jsonBytesSniffGeographicCollections() {
        #expect(
            FileKind.detect(
                from: "places.json",
                content: #"{"type":"FeatureCollection","features":[]}"#
            ) == .geojson
        )
        #expect(
            FileKind.detect(
                from: "places.json",
                content: #"{"type":"GeometryCollection","geometries":[]}"#
            ) == .geojson
        )
        #expect(
            FileKind.detect(
                from: "places.json",
                content: #"{"type":"Topology","objects":{},"arcs":[]}"#
            ) == .topojson
        )
    }

    // MARK: - Display Labels

    @Test func displayLabels() {
        #expect(FileKind.latex.displayLabel == "LaTeX")
        #expect(FileKind.orgMode.displayLabel == "Org")
        #expect(FileKind.mermaid.displayLabel == "Mermaid")
        #expect(FileKind.graphviz.displayLabel == "Graphviz")
        #expect(FileKind.csv.displayLabel == "CSV")
        #expect(FileKind.tsv.displayLabel == "TSV")
        #expect(FileKind.geojson.displayLabel == "GeoJSON")
        #expect(FileKind.topojson.displayLabel == "TopoJSON")
        #expect(FileKind.usdz.displayLabel == "USDZ")
    }

    @Test func detectUSDZ() {
        #expect(FileKind.detect(from: "models/scene.usdz") == .usdz)
        #expect(FileKind.detect(from: "SCENE.USDZ") == .usdz)
        #expect(FileKind.detect(from: "models/scene.usdz").previewCategory == .usdz)
        #expect(FileKind.detect(from: "scene.glb") != .usdz)
        #expect(FileKind.detect(from: "scene.blend") != .usdz)
    }

    // MARK: - SyntaxLanguage Detection

    @Test func syntaxLanguageDetection() {
        #expect(SyntaxLanguage.detect("tex") == .latex)
        #expect(SyntaxLanguage.detect("latex") == .latex)
        #expect(SyntaxLanguage.detect("org") == .orgMode)
        #expect(SyntaxLanguage.detect("mmd") == .mermaid)
        #expect(SyntaxLanguage.detect("mermaid") == .mermaid)
        #expect(SyntaxLanguage.detect("dot") == .dot)
        #expect(SyntaxLanguage.detect("gv") == .dot)
    }

    @Test func syntaxLanguageDisplayNames() {
        #expect(SyntaxLanguage.latex.displayName == "LaTeX")
        #expect(SyntaxLanguage.orgMode.displayName == "Org")
        #expect(SyntaxLanguage.mermaid.displayName == "Mermaid")
        #expect(SyntaxLanguage.dot.displayName == "Graphviz")
    }

    @Test func syntaxLanguageCommentPrefixes() {
        // LaTeX uses % for line comments
        #expect(SyntaxLanguage.latex.lineCommentPrefix == ["%"])
        // Org uses #
        #expect(SyntaxLanguage.orgMode.lineCommentPrefix == ["#"])
        // Mermaid uses %%
        #expect(SyntaxLanguage.mermaid.lineCommentPrefix == ["%", "%"])
        // DOT uses //
        #expect(SyntaxLanguage.dot.lineCommentPrefix == ["/", "/"])
    }

    @Test func syntaxLanguageBlockComments() {
        // DOT supports /* */ block comments
        #expect(SyntaxLanguage.dot.hasBlockComments == true)
        // Others don't
        #expect(SyntaxLanguage.latex.hasBlockComments == false)
        #expect(SyntaxLanguage.orgMode.hasBlockComments == false)
        #expect(SyntaxLanguage.mermaid.hasBlockComments == false)
    }

    @Test func syntaxLanguageKeywordsNotEmpty() {
        #expect(!SyntaxLanguage.latex.keywords.isEmpty)
        #expect(!SyntaxLanguage.orgMode.keywords.isEmpty)
        #expect(!SyntaxLanguage.mermaid.keywords.isEmpty)
        #expect(!SyntaxLanguage.dot.keywords.isEmpty)
    }

    // MARK: - Existing Types Unaffected

    @Test func existingTypesUnchanged() {
        #expect(FileKind.detect(from: "file.md") == .markdown)
        #expect(FileKind.detect(from: "page.html") == .html)
        #expect(FileKind.detect(from: "app.swift") == .code(language: .swift))
        #expect(FileKind.detect(from: "data.json") == .json)
        #expect(FileKind.detect(from: "photo.png") == .image)
        #expect(FileKind.detect(from: "readme.txt") == .plain)
        #expect(FileKind.detect(from: "export.csv") != .plain)
        #expect(FileKind.detect(from: "export.tsv") != .plain)
    }
}
