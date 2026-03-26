import Testing
@testable import Oppi

/// Tests FileType detection for notebook renderer file extensions.
@Suite("FileType Detection — Notebook Renderers")
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

    // MARK: - Display Labels

    @Test func displayLabels() {
        #expect(FileType.latex.displayLabel == "LaTeX")
        #expect(FileType.orgMode.displayLabel == "Org")
        #expect(FileType.mermaid.displayLabel == "Mermaid")
        #expect(FileType.graphviz.displayLabel == "Graphviz")
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
    }
}
