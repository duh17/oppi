import Foundation
import Testing
@testable import Oppi

@Suite("UnifiedPatchParser")
struct UnifiedPatchParserTests {

    struct ExpectedLine: Sendable {
        let kind: DiffLine.Kind
        let text: String
        let oldLineNumber: Int?
        let newLineNumber: Int?
    }

    enum ExpectedDocument: Sendable {
        case none
        case singleFile(path: String?, hunkStarts: [(Int, Int)], lines: [ExpectedLine])
        case multiFile(paths: [String], fileLineTexts: [[String]])
    }

    struct ParserCase: CustomTestStringConvertible, Sendable {
        let name: String
        let input: String
        let options: UnifiedPatchParser.Options
        let expected: ExpectedDocument

        var testDescription: String { name }
    }

    private static let cases: [ParserCase] = [
        ParserCase(
            name: "one hunk with absolute starts",
            input: """
            --- App.swift
            +++ App.swift
            @@ -314,3 +314,4 @@
             var body: some View {
                 HStack(spacing: 5) {
            +        Image(systemName: "terminal.fill")
                 if isAnimated {
            """,
            options: .strict,
            expected: .singleFile(
                path: "App.swift",
                hunkStarts: [(314, 314)],
                lines: [
                    .init(kind: .context, text: "var body: some View {", oldLineNumber: 314, newLineNumber: 314),
                    .init(kind: .context, text: "    HStack(spacing: 5) {", oldLineNumber: 315, newLineNumber: 315),
                    .init(kind: .added, text: "        Image(systemName: \"terminal.fill\")", oldLineNumber: nil, newLineNumber: 316),
                    .init(kind: .context, text: "    if isAnimated {", oldLineNumber: 316, newLineNumber: 317),
                ]
            )
        ),
        ParserCase(
            name: "several hunks in one file",
            input: """
            --- a/File.swift
            +++ b/File.swift
            @@ -10,2 +10,2 @@
             keep-a
            -old-a
            +new-a
            @@ -40,2 +40,2 @@
             keep-b
            -old-b
            +new-b
            """,
            options: .strict,
            expected: .singleFile(
                path: "File.swift",
                hunkStarts: [(10, 10), (40, 40)],
                lines: [
                    .init(kind: .context, text: "keep-a", oldLineNumber: 10, newLineNumber: 10),
                    .init(kind: .removed, text: "old-a", oldLineNumber: 11, newLineNumber: nil),
                    .init(kind: .added, text: "new-a", oldLineNumber: nil, newLineNumber: 11),
                    .init(kind: .context, text: "keep-b", oldLineNumber: 40, newLineNumber: 40),
                    .init(kind: .removed, text: "old-b", oldLineNumber: 41, newLineNumber: nil),
                    .init(kind: .added, text: "new-b", oldLineNumber: nil, newLineNumber: 41),
                ]
            )
        ),
        ParserCase(
            name: "CRLF input",
            input: "--- a/crlf.txt\r\n+++ b/crlf.txt\r\n@@ -1,2 +1,2 @@\r\n context\r\n-old\r\n+new\r\n",
            options: .strict,
            expected: .singleFile(
                path: "crlf.txt",
                hunkStarts: [(1, 1)],
                lines: [
                    .init(kind: .context, text: "context", oldLineNumber: 1, newLineNumber: 1),
                    .init(kind: .removed, text: "old", oldLineNumber: 2, newLineNumber: nil),
                    .init(kind: .added, text: "new", oldLineNumber: nil, newLineNumber: 2),
                ]
            )
        ),
        ParserCase(
            name: "/dev/null add",
            input: """
            --- /dev/null
            +++ b/New.swift
            @@ -0,0 +1,2 @@
            +one
            +two
            """,
            options: .strict,
            expected: .singleFile(
                path: "New.swift",
                hunkStarts: [(0, 1)],
                lines: [
                    .init(kind: .added, text: "one", oldLineNumber: nil, newLineNumber: 1),
                    .init(kind: .added, text: "two", oldLineNumber: nil, newLineNumber: 2),
                ]
            )
        ),
        ParserCase(
            name: "/dev/null delete",
            input: """
            --- a/Old.swift
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -one
            -two
            """,
            options: .strict,
            expected: .singleFile(
                path: "Old.swift",
                hunkStarts: [(1, 0)],
                lines: [
                    .init(kind: .removed, text: "one", oldLineNumber: 1, newLineNumber: nil),
                    .init(kind: .removed, text: "two", oldLineNumber: 2, newLineNumber: nil),
                ]
            )
        ),
        ParserCase(
            name: "timestamps after paths",
            input: """
            --- a/App.swift	2024-01-15 12:00:00.000000000 +0000
            +++ b/App.swift	2024-01-15 12:01:00.000000000 +0000
            @@ -1 +1 @@
            -old
            +new
            """,
            options: .strict,
            expected: .singleFile(
                path: "App.swift",
                hunkStarts: [(1, 1)],
                lines: [
                    .init(kind: .removed, text: "old", oldLineNumber: 1, newLineNumber: nil),
                    .init(kind: .added, text: "new", oldLineNumber: nil, newLineNumber: 1),
                ]
            )
        ),
        ParserCase(
            name: "space-separated timestamps after paths",
            input: """
            --- a/App.swift 2024-01-15 12:00:00
            +++ b/App.swift 2024-01-15 12:01:00
            @@ -1 +1 @@
            -old
            +new
            """,
            options: .strict,
            expected: .singleFile(
                path: "App.swift",
                hunkStarts: [(1, 1)],
                lines: [
                    .init(kind: .removed, text: "old", oldLineNumber: 1, newLineNumber: nil),
                    .init(kind: .added, text: "new", oldLineNumber: nil, newLineNumber: 1),
                ]
            )
        ),
        ParserCase(
            name: "malformed hunk headers",
            input: """
            --- a/App.swift
            +++ b/App.swift
            @@ not-a-header @@
            -old
            +new
            @@ -abc +1 @@
            -still-old
            +still-new
            """,
            options: .strict,
            expected: .none
        ),
        ParserCase(
            name: "headerless single-file lenient",
            input: """
            -old line
            +new line
            """,
            options: .lenient,
            expected: .singleFile(
                path: nil,
                hunkStarts: [(0, 0)],
                lines: [
                    .init(kind: .removed, text: "old line", oldLineNumber: nil, newLineNumber: nil),
                    .init(kind: .added, text: "new line", oldLineNumber: nil, newLineNumber: nil),
                ]
            )
        ),
        ParserCase(
            name: "headerless replacement with file headers in lenient mode",
            input: """
            --- a/foo.swift
            +++ b/foo.swift
            -old
            +new
            """,
            options: .lenient,
            expected: .singleFile(
                path: "foo.swift",
                hunkStarts: [(0, 0)],
                lines: [
                    .init(kind: .removed, text: "old", oldLineNumber: nil, newLineNumber: nil),
                    .init(kind: .added, text: "new", oldLineNumber: nil, newLineNumber: nil),
                ]
            )
        ),
        ParserCase(
            name: "headerless rejected in strict mode",
            input: """
            -old line
            +new line
            """,
            options: .strict,
            expected: .none
        ),
        ParserCase(
            name: "multi-file stays non-rich",
            input: """
            --- a/A.swift
            +++ b/A.swift
            @@ -1 +1 @@
            -old-a
            +new-a
            --- a/B.swift
            +++ b/B.swift
            @@ -1 +1 @@
            -old-b
            +new-b
            """,
            options: .lenient,
            expected: .multiFile(
                paths: ["A.swift", "B.swift"],
                fileLineTexts: [
                    ["old-a", "new-a"],
                    ["old-b", "new-b"],
                ]
            )
        ),
        ParserCase(
            name: "no-newline marker",
            input: """
            --- a/eof.txt
            +++ b/eof.txt
            @@ -1,2 +1,2 @@
             keep
            -old
            \\ No newline at end of file
            +new
            \\ No newline at end of file
            """,
            options: .strict,
            expected: .singleFile(
                path: "eof.txt",
                hunkStarts: [(1, 1)],
                lines: [
                    .init(kind: .context, text: "keep", oldLineNumber: 1, newLineNumber: 1),
                    .init(kind: .removed, text: "old", oldLineNumber: 2, newLineNumber: nil),
                    .init(kind: .added, text: "new", oldLineNumber: nil, newLineNumber: 2),
                ]
            )
        ),
        ParserCase(
            name: "plus/minus outside hunk",
            input: """
            --- a/App.swift
            +++ b/App.swift
            -orphan-old
            +orphan-new
            @@ -5,2 +5,2 @@
             keep
            -old
            +new
            """,
            options: .strict,
            expected: .singleFile(
                path: "App.swift",
                hunkStarts: [(5, 5)],
                lines: [
                    .init(kind: .context, text: "keep", oldLineNumber: 5, newLineNumber: 5),
                    .init(kind: .removed, text: "old", oldLineNumber: 6, newLineNumber: nil),
                    .init(kind: .added, text: "new", oldLineNumber: nil, newLineNumber: 6),
                ]
            )
        ),
    ]

    @Test(arguments: Self.cases)
    func parsesTableDrivenCases(_ parserCase: ParserCase) throws {
        let document = UnifiedPatchParser.parse(parserCase.input, options: parserCase.options)

        switch parserCase.expected {
        case .none:
            #expect(document == nil, "Expected no document for \(parserCase.name)")

        case .singleFile(let path, let hunkStarts, let expectedLines):
            let parsed = try #require(document, "Expected a document for \(parserCase.name)")
            #expect(!parsed.isMultiFile, "Expected a single-file document for \(parserCase.name)")
            #expect(parsed.files.count == 1, "Expected one file for \(parserCase.name)")
            let file = try #require(parsed.files.first)
            #expect(file.displayPath == path, "Path mismatch for \(parserCase.name)")
            #expect(file.hunks.map { ($0.oldStart, $0.newStart) }.elementsEqual(hunkStarts, by: ==))
            #expect(file.lines.count == expectedLines.count, "Line count mismatch for \(parserCase.name)")
            for (index, expected) in expectedLines.enumerated() {
                let line = file.lines[index]
                #expect(line.kind == expected.kind, "Kind mismatch at \(index) for \(parserCase.name)")
                #expect(line.text == expected.text, "Text mismatch at \(index) for \(parserCase.name)")
                #expect(line.oldLineNumber == expected.oldLineNumber, "Old line mismatch at \(index) for \(parserCase.name)")
                #expect(line.newLineNumber == expected.newLineNumber, "New line mismatch at \(index) for \(parserCase.name)")
            }

        case .multiFile(let paths, let fileLineTexts):
            let parsed = try #require(document, "Expected a multi-file document for \(parserCase.name)")
            #expect(parsed.isMultiFile, "Expected multi-file document for \(parserCase.name)")
            #expect(parsed.files.count == paths.count)
            #expect(parsed.files.count > 1, "Multi-file input must not collapse to one file")
            #expect(parsed.files.map(\.displayPath) == paths.map(Optional.some))
            for (index, expectedTexts) in fileLineTexts.enumerated() {
                #expect(parsed.files[index].lines.map(\.text) == expectedTexts)
            }
            let flattenedWouldMix = parsed.files.flatMap { $0.lines.map(\.text) }
            #expect(flattenedWouldMix == fileLineTexts.flatMap { $0 })
            #expect(parsed.files.count != 1)
        }
    }

    @Test func textFilePlusNonHunkSecondSectionIsMultiFile() throws {
        let patch = """
        --- a/A.swift
        +++ b/A.swift
        @@ -1 +1 @@
        -old-a
        +new-a
        diff --git a/photo.png b/photo.png
        index 1111111..2222222 100644
        Binary files a/photo.png and b/photo.png differ
        """

        let document = try #require(UnifiedPatchParser.parse(patch, options: .lenient))
        #expect(document.isMultiFile)
        #expect(document.files.count == 1)
        #expect(document.files[0].displayPath == "A.swift")
        #expect(document.files[0].lines.map(\.text) == ["old-a", "new-a"])
    }

    @Test func strictKeepsDashedHunkLinesAsContent() throws {
        let patch = """
        --- a/App.swift
        +++ b/App.swift
        @@ -10,3 +10,3 @@
         keep
        --- not a file header
        +++ not a new file
        """

        let document = try #require(UnifiedPatchParser.parse(patch, options: .strict))
        #expect(!document.isMultiFile)
        #expect(document.files.count == 1)
        let file = try #require(document.files.first)
        #expect(file.displayPath == "App.swift")
        #expect(file.lines.map(\.kind) == [.context, .removed, .added])
        #expect(file.lines.map(\.text) == ["keep", "-- not a file header", "++ not a new file"])
        #expect(file.lines[1].oldLineNumber == 11)
        #expect(file.lines[1].newLineNumber == nil)
        #expect(file.lines[2].oldLineNumber == nil)
        #expect(file.lines[2].newLineNumber == 11)
    }

    @Test func strictKeepsPathLikeDashedHunkLinesAsContent() throws {
        let patch = """
        --- a/App.swift
        +++ b/App.swift
        @@ -10,3 +10,3 @@
         keep
        --- a/example
        +++ b/example
        """

        let document = try #require(UnifiedPatchParser.parse(patch, options: .strict))
        #expect(!document.isMultiFile)
        #expect(document.files.count == 1)
        let file = try #require(document.files.first)
        #expect(file.displayPath == "App.swift")
        #expect(file.lines.map(\.kind) == [.context, .removed, .added])
        #expect(file.lines.map(\.text) == ["keep", "-- a/example", "++ b/example"])
        #expect(file.lines[1].oldLineNumber == 11)
        #expect(file.lines[1].newLineNumber == nil)
        #expect(file.lines[2].oldLineNumber == nil)
        #expect(file.lines[2].newLineNumber == 11)
    }

    @Test func lenientPlainHeadersWithoutGitPrefixesAreMultiFile() throws {
        let patch = """
        --- A.swift
        +++ A.swift
        @@ -1 +1 @@
        -old-a
        +new-a
        --- B.swift
        +++ B.swift
        @@ -1 +1 @@
        -old-b
        +new-b
        """

        let document = try #require(UnifiedPatchParser.parse(patch, options: .lenient))
        #expect(document.isMultiFile)
        #expect(document.files.count == 2)
        #expect(document.files.map(\.displayPath) == ["A.swift", "B.swift"])
        #expect(document.files[0].lines.map(\.text) == ["old-a", "new-a"])
        #expect(document.files[1].lines.map(\.text) == ["old-b", "new-b"])
    }

    @Test func piNumberedDiffStaysOutsideUnifiedParser() {
        let piNumbered = """
          314 var body: some View {
          315     HStack(spacing: 5) {
        + 316         Image(systemName: "terminal.fill")
          317         if isAnimated {
        """

        #expect(UnifiedPatchParser.parse(piNumbered, options: .strict) == nil)
    }
}
