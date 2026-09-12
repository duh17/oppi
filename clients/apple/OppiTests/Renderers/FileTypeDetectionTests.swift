import Testing
@testable import Oppi

/// Tests FileType detection for document renderer file extensions.
@Suite("FileType Detection — Document Renderers")
struct FileTypeDetectionTests {

    // MARK: - LaTeX

    @Test func detectTexExtension() {
        #expect(FileType.detect(from: "document.tex") == .latex)
    }

    @Test func detectLatexExtension() {
        #expect(FileType.detect(from: "paper.latex") == .latex)
    }

    @Test func detectTexInSubdirectory() {
        #expect(FileType.detect(from: "src/math/equation.tex") == .latex)
    }

    // MARK: - Org Mode

    @Test func detectOrgExtension() {
        #expect(FileType.detect(from: "notes.org") == .orgMode)
    }

    @Test func detectOrgInSubdirectory() {
        #expect(FileType.detect(from: "docs/TODO.org") == .orgMode)
    }

    // MARK: - Mermaid

    @Test func detectMmdExtension() {
        #expect(FileType.detect(from: "diagram.mmd") == .mermaid)
    }

    @Test func detectMermaidExtension() {
        #expect(FileType.detect(from: "flow.mermaid") == .mermaid)
    }

    // MARK: - Graphviz

    @Test func detectDotExtension() {
        #expect(FileType.detect(from: "graph.dot") == .graphviz)
    }

    @Test func detectGvExtension() {
        #expect(FileType.detect(from: "tree.gv") == .graphviz)
    }

    // MARK: - CSV / TSV

    @Test func detectCsvExtension() {
        #expect(FileType.detect(from: "export.csv") == .csv)
        #expect(FileType.detect(from: "EXPORT.CSV") == .csv)
        #expect(FileType.detect(from: "metrics/rides.csv") == .csv)
    }

    @Test func detectTsvExtension() {
        #expect(FileType.detect(from: "export.tsv") == .tsv)
        #expect(FileType.detect(from: "notes.TSV") == .tsv)
    }

    // MARK: - GeoJSON / TopoJSON

    @Test func detectGeojsonExtension() {
        #expect(FileType.detect(from: "park.geojson") == .geojson)
        #expect(FileType.detect(from: "PARK.GEOJSON") == .geojson)
    }

    @Test func detectTopojsonExtension() {
        #expect(FileType.detect(from: "counties.topojson") == .topojson)
    }

    @Test func jsonBytesSniffGeographicCollections() {
        #expect(
            FileType.detect(
                from: "places.json",
                content: #"{"type":"FeatureCollection","features":[]}"#
            ) == .geojson
        )
        #expect(
            FileType.detect(
                from: "places.json",
                content: #"{"type":"GeometryCollection","geometries":[]}"#
            ) == .geojson
        )
        #expect(
            FileType.detect(
                from: "places.json",
                content: #"{"type":"Topology","objects":{},"arcs":[]}"#
            ) == .topojson
        )
    }

    // MARK: - Display Labels

    @Test func displayLabels() {
        #expect(FileType.latex.displayLabel == "LaTeX")
        #expect(FileType.orgMode.displayLabel == "Org")
        #expect(FileType.mermaid.displayLabel == "Mermaid")
        #expect(FileType.graphviz.displayLabel == "Graphviz")
        #expect(FileType.csv.displayLabel == "CSV")
        #expect(FileType.tsv.displayLabel == "TSV")
        #expect(FileType.geojson.displayLabel == "GeoJSON")
        #expect(FileType.topojson.displayLabel == "TopoJSON")
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
        #expect(FileType.detect(from: "file.md") == .markdown)
        #expect(FileType.detect(from: "page.html") == .html)
        #expect(FileType.detect(from: "app.swift") == .code(language: .swift))
        #expect(FileType.detect(from: "data.json") == .json)
        #expect(FileType.detect(from: "photo.png") == .image)
        #expect(FileType.detect(from: "readme.txt") == .plain)
        #expect(FileType.detect(from: "export.csv") != .plain)
        #expect(FileType.detect(from: "export.tsv") != .plain)
    }
}
