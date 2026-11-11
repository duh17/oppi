import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Oppi

/// The share sheet is handed each file under the type the file-kind table
/// gives its name, so the receiving app knows what it is.
@Suite("File share content types")
@MainActor
struct FileShareContentTypeTests {
    private func sharedType(named fileName: String) throws -> UTType {
        let url = URL(fileURLWithPath: "/tmp/oppi-share-types/\(fileName)")
        let source = try #require(FileShareService.ShareItem.file(url).activityItems.first as? FileActivityItemSource)
        #expect(source.url == url)
        let sheet = UIActivityViewController(activityItems: [], applicationActivities: nil)
        #expect(source.activityViewController(sheet, dataTypeIdentifierForActivityType: nil) == source.contentType.identifier)
        return source.contentType
    }

    @Test func everyExtensionInTheTableSharesAsItsKind() throws {
        for row in FileKindTable.rows {
            let base = row.kind.previewCategory.baseContentType
            let tableMIMEType = row.mimeType.flatMap { UTType(mimeType: $0) }
            for ext in row.extensions {
                let type = try sharedType(named: "sample.\(ext)")
                #expect(type.isDeclared, "\(ext) shares as the undeclared \(type.identifier)")
                // A row the app opens as text but tells players about (AIFF)
                // shares as the type of its MIME type.
                #expect(
                    type.conforms(to: base) || type == tableMIMEType,
                    "\(ext) shares as \(type.identifier), which is not \(base.identifier)"
                )
            }
        }
    }

    @Test(arguments: [
        ("clip.mp4", UTType.mpeg4Movie),
        ("clip.mov", UTType.quickTimeMovie),
        ("scene.usdz", UTType.usdz),
        ("novel.epub", UTType.epub),
        ("photo.png", UTType.png),
        ("photo.jpg", UTType.jpeg),
        ("paper.pdf", UTType.pdf),
        ("song.mp3", UTType.mp3),
        ("bundle.zip", UTType.zip),
    ])
    func aFileTheTargetAppMustRecogniseSharesAsExactlyItsType(fileName: String, expected: UTType) throws {
        #expect(try sharedType(named: fileName) == expected)
    }

    @Test func theTableDecidesWhereTheSystemDisagrees() throws {
        // `.ts` is a transport stream to the system and TypeScript to the app.
        let typeScript = try sharedType(named: "main.ts")
        #expect(typeScript.conforms(to: .text))
        #expect(!typeScript.conforms(to: .audiovisualContent))
        // The table opens AIFF as text and names its audio MIME type.
        #expect(try sharedType(named: "take.aiff").conforms(to: .audio))
        // No extension, an unknown one, and Markdown are all text.
        #expect(try sharedType(named: "Makefile").conforms(to: .text))
        #expect(try sharedType(named: "notes.unknownext").conforms(to: .text))
        #expect(try sharedType(named: "README.md").conforms(to: .text))
    }
}
