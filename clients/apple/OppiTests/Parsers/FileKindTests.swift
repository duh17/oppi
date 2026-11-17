import Foundation
import Testing
@testable import Oppi

@Suite("FileKind")
struct FileKindTests {

    @Test func detectsSourceLanguagesFromExtensionsAndWellKnownNames() {
        let expectations: [(path: String, language: SyntaxLanguage)] = [
            ("Sources/main.swift", .swift),
            ("src/index.ts", .typescript),
            ("Dockerfile", .shell),
            ("Containerfile", .shell),
            ("Makefile", .shell),
            ("config.xml", .xml),
            ("Info.plist", .xml),
            ("schema.proto", .protobuf),
            ("queries.graphql", .graphql),
            ("schema.gql", .graphql),
            ("changes.diff", .diff),
            ("fix.patch", .diff),
            (".gitignore", .shell),
            (".dockerignore", .shell),
            (".env", .shell),
            (".env.local", .shell),
            ("swordlab/sfx.gd", .gdscript),
            ("scenes/main.tscn", .godotResource),
            ("themes/ui.tres", .godotResource),
            ("project.godot", .godotResource),
            ("icon.svg.import", .godotResource),
            ("export_presets.cfg", .godotResource),
            ("shaders/water.gdshader", .gdshader),
            ("shaders/common.gdshaderinc", .gdshader),
        ]
        for (path, language) in expectations {
            let kind = FileKind.detect(from: path)
            #expect(kind == .code(language: language), "\(path) detected as \(kind.displayLabel)")
            #expect(kind.codeLanguage == language)
            #expect(kind.previewCategory == .text)
        }
    }

    /// The document renderers and text formats the server's media contract
    /// (`protocol/file-kinds.json`, below) does not list, in any case and
    /// under any directory.
    @Test(arguments: [
        ("README.md", FileKind.markdown),
        ("docs/guide.mdx", .markdown),
        ("page.html", .html),
        ("index.htm", .html),
        ("REPORT.HTML", .html),
        ("config.json", .json),
        (".prettierrc", .json),
        (".eslintrc", .json),
        ("document.tex", .latex),
        ("paper.latex", .latex),
        ("src/math/equation.tex", .latex),
        ("notes.org", .orgMode),
        ("docs/TODO.org", .orgMode),
        ("diagram.mmd", .mermaid),
        ("flow.mermaid", .mermaid),
        ("graph.dot", .graphviz),
        ("tree.gv", .graphviz),
        ("export.csv", .csv),
        ("EXPORT.CSV", .csv),
        ("metrics/rides.csv", .csv),
        ("export.tsv", .tsv),
        ("notes.TSV", .tsv),
        ("park.geojson", .geojson),
        ("PARK.GEOJSON", .geojson),
        ("counties.topojson", .topojson),
        ("IMG_0001.HEIC", .image),
        ("models/SCENE.USDZ", .usdz),
    ])
    func detectsDocumentKinds(path: String, kind: FileKind) {
        #expect(FileKind.detect(from: path) == kind)
    }

    @Test func jsonBytesSniffFeatureCollectionGeometryCollectionAndTopology() {
        let collection = #"{"type":"FeatureCollection","features":[]}"#
        let geometries = #"{"type":"GeometryCollection","geometries":[]}"#
        let topology = #"{"type":"Topology","objects":{},"arcs":[]}"#
        #expect(FileKind.detect(from: "places.json", content: collection) == .geojson)
        #expect(FileKind.detect(from: "places.json", content: geometries) == .geojson)
        #expect(FileKind.detect(from: "places.json", content: topology) == .topojson)
        #expect(FileKind.detect(from: "places.json") == .json)
        #expect(FileKind.detect(from: "package.json", content: #"{"name":"oppi"}"#) == .json)
    }

    @Test func plainWhenNothingIdentifiesTheFile() {
        #expect(FileKind.detect(from: nil) == .plain)
        #expect(FileKind.detect(from: "file.xyz") == .plain)
        #expect(FileKind.detect(from: "LICENSE") == .plain)
        #expect(FileKind.detect(from: "readme.txt") == .plain)
        #expect(FileKind.detect(from: "scene.glb") == .plain)
        #expect(FileKind.detect(from: "scene.blend") == .plain)
    }

    @Test func extensionlessScriptsAreDetectedFromTheirShebang() {
        let expectations: [(content: String, language: SyntaxLanguage)] = [
            ("#!/bin/bash\necho hi", .shell),
            ("#!/usr/bin/env -S bash -eu\necho hi", .shell),
            ("#!/usr/bin/env python3\nprint('hi')", .python),
            ("#!/usr/bin/ruby\nputs 'hi'", .ruby),
            ("#!/usr/bin/env node\nconsole.log('hi')", .javascript),
        ]
        for (content, language) in expectations {
            #expect(FileKind.detect(from: "scripts/run", content: content) == .code(language: language), "\(content)")
        }
    }

    @Test func extensionTakesPrecedenceOverShebang() {
        #expect(FileKind.detect(from: "README.md", content: "#!/bin/bash\necho hi") == .markdown)
    }

    @Test func displayLabels() {
        #expect(FileKind.markdown.displayLabel == "Markdown")
        #expect(FileKind.html.displayLabel == "HTML")
        #expect(FileKind.json.displayLabel == "JSON")
        #expect(FileKind.image.displayLabel == "Image")
        #expect(FileKind.audio.displayLabel == "Audio")
        #expect(FileKind.plain.displayLabel == "Text")
        #expect(FileKind.csv.displayLabel == "CSV")
        #expect(FileKind.tsv.displayLabel == "TSV")
        #expect(FileKind.geojson.displayLabel == "GeoJSON")
        #expect(FileKind.topojson.displayLabel == "TopoJSON")
        #expect(FileKind.latex.displayLabel == "LaTeX")
        #expect(FileKind.orgMode.displayLabel == "Org")
        #expect(FileKind.mermaid.displayLabel == "Mermaid")
        #expect(FileKind.graphviz.displayLabel == "Graphviz")
        #expect(FileKind.video.displayLabel == "Video")
        #expect(FileKind.pdf.displayLabel == "PDF")
        #expect(FileKind.usdz.displayLabel == "USDZ")
        #expect(FileKind.binary.displayLabel == "Binary")
        #expect(FileKind.code(language: .swift).displayLabel == "Swift")
        #expect(FileKind.code(language: .xml).displayLabel == "XML")
        #expect(FileKind.code(language: .protobuf).displayLabel == "Protobuf")
        #expect(FileKind.code(language: .graphql).displayLabel == "GraphQL")
        #expect(FileKind.code(language: .diff).displayLabel == "Diff")
    }

    @Test func detectBinary() {
        for path in [
            "archive.gz", "bundle.zip", "blob.bin", "disk.dmg", "assets.car", "view.nib",
            "cert.mobileprovision", "lib.dylib", "font.woff2",
        ] {
            #expect(FileKind.detect(from: path) == .binary, "\(path)")
        }
    }

    @Test func syntaxLanguageProjectionCoversFencesAndPaths() {
        #expect(FileKind.detect(from: "a.swift").syntaxLanguage == .swift)
        #expect(FileKind.detect(from: "config.json").syntaxLanguage == .json)
        #expect(FileKind.detect(from: "rows.jsonl").syntaxLanguage == .json)
        #expect(FileKind.json.syntaxLanguage == .json)
        #expect(FileKind.json != .code(language: .json))
        #expect(FileKind.detect(from: "page.html").syntaxLanguage == .html)
        #expect(FileKind.detect(from: "Makefile").syntaxLanguage == .shell)
        #expect(FileKind.detect(from: "scripts/run", content: "#!/bin/bash\necho hi").syntaxLanguage == .shell)
        #expect(FileKind.detect(from: "LICENSE").syntaxLanguage == nil)
        #expect(FileKind.detect(from: "graph.dot").syntaxLanguage == .dot)
        #expect(FileKind.detect(from: "README.md").syntaxLanguage == nil)
        #expect(FileKind.detect(from: "notes.org").syntaxLanguage == .orgMode)
        #expect(FileKind.detect(from: "export.csv").syntaxLanguage == nil)
        #expect(FileKind.detect(from: "export.tsv").syntaxLanguage == nil)
        #expect(FileKind.detect(from: "park.geojson").syntaxLanguage == .json)
        #expect(FileKind.detect(from: "arcs.topojson").syntaxLanguage == .json)
        #expect(FileKind.detect(from: "scene.usdz").syntaxLanguage == nil)
        #expect(FileKind.latex.syntaxLanguage == .latex)
        #expect(FileKind.mermaid.syntaxLanguage == .mermaid)
        #expect(FileKind.html.syntaxLanguage == .html)
    }
}

@Suite("File preview category")
struct FilePreviewCategoryTests {
    @Test func textLikeFilesStayText() {
        for path in [
            "runtime-update.ts", "README.md", "index.html", "data.json", "diagram.mmd",
            "export.csv", "export.tsv", "park.geojson", "arcs.topojson",
        ] {
            #expect(FileKind.detect(from: path).previewCategory == .text, "\(path)")
        }
    }
}

@Suite("File kind table")
struct FileKindTableTests {
    /// `protocol/file-kinds.json`, the extensions the server must serve as the same kind
    /// (`server/tests/file-kinds-contract.test.ts` holds the other half).
    @Test func everyExtensionTheServerContractListsOpensAsThatKind() throws {
        let fixture = try JSONDecoder().decode(
            [String: [String]].self,
            from: ProtocolFixtures.data("file-kinds.json")
        )
        let kinds: [String: FileKind] = [
            "image": .image, "audio": .audio, "video": .video, "pdf": .pdf, "usdz": .usdz, "book": .book,
        ]
        #expect(Set(fixture.keys) == Set(kinds.keys))
        for (name, extensions) in fixture {
            for ext in extensions {
                #expect(FileKind.detect(from: "file.\(ext)") == kinds[name], "\(ext)")
            }
        }
    }

    @Test func onlyHTMLAndSVGLoadAsWebStrings() {
        #expect(FileKindTable.rendersAsWebString(path: "page.html"))
        #expect(FileKindTable.rendersAsWebString(path: "PAGE.HTM"))
        #expect(FileKindTable.rendersAsWebString(path: "shape.svg"))
        #expect(!FileKindTable.rendersAsWebString(path: "photo.png"))
        #expect(!FileKindTable.rendersAsWebString(path: "notes.md"))
        #expect(!FileKindTable.rendersAsWebString(path: "Makefile"))
    }

    @Test func mimeTypesAreAnsweredPerPlayerCategory() {
        #expect(FileKindTable.mimeType(forExtension: "M4A", prefix: "audio/") == "audio/mp4")
        #expect(FileKindTable.mimeType(forExtension: "m4v", prefix: "video/") == "video/mp4")
        #expect(FileKindTable.mimeType(forExtension: "jpeg", prefix: "image/") == "image/jpeg")
        // Asking for another category's extension answers nothing.
        #expect(FileKindTable.mimeType(forExtension: "mp4", prefix: "audio/") == nil)
        #expect(FileKindTable.mimeType(forExtension: "swift", prefix: "image/") == nil)
        #expect(FileKindTable.mimeType(forExtension: nil, prefix: "image/") == nil)
    }

    @Test func everyExtensionIsListedOnce() {
        let all = FileKindTable.rows.flatMap(\.extensions)
        #expect(Set(all).count == all.count)
        #expect(all.allSatisfy { $0 == $0.lowercased() && !$0.hasPrefix(".") })
    }
}
