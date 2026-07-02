import Foundation
import Testing
@testable import Oppi

@Suite("Mac pending attachments")
struct MacPendingAttachmentTests {
    @Test func createsAttachmentMetadataFromLocalFile() throws {
        let file = try TemporaryFile(name: "note.txt", contents: Data("hello".utf8))

        let attachment = try MacPendingAttachment(url: file.url)

        #expect(attachment.url == file.url)
        #expect(attachment.displayName == "note.txt")
        #expect(attachment.mimeType == "text/plain")
        #expect(attachment.sizeBytes == 5)
    }

    @Test func rejectsDirectories() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mac-pending-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: MacPendingAttachmentError.notRegularFile) {
            _ = try MacPendingAttachment(url: directory)
        }
    }

    @Test func collectorAddsFilesDeduplicatesAndReportsRejectedURLs() throws {
        let file = try TemporaryFile(name: "note.txt", contents: Data("hello".utf8))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mac-pending-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = [try MacPendingAttachment(id: "existing", url: file.url)]
        let result = MacPendingAttachmentCollector.adding(urls: [file.url, directory], to: existing)

        #expect(result.attachments == existing)
        #expect(result.rejectedMessages.count == 1)
        #expect(result.rejectedMessages.first?.contains("Attachment must be a regular file.") == true)
    }

    @Test func collectorAppendsNewFilesInDropOrder() throws {
        let first = try TemporaryFile(name: "one.txt", contents: Data("one".utf8))
        let second = try TemporaryFile(name: "two.md", contents: Data("two".utf8))

        let result = MacPendingAttachmentCollector.adding(urls: [first.url, second.url], to: [])

        #expect(result.attachments.map(\.displayName) == ["one.txt", "two.md"])
        #expect(result.attachments.map(\.sizeBytes) == [3, 3])
        #expect(result.rejectedMessages.isEmpty)
    }

    @Test func attachedFilesDisplayBlockUsesWorkspacePathOrName() {
        let refs = [
            ChatAttachmentRef(
                type: "chat_attachment",
                id: "upload-1",
                source: .upload,
                name: "note.txt",
                mimeType: "text/plain",
                sizeBytes: 42,
                sha256: nil,
                kind: .text,
                workspacePath: ".pi/attachments/session/turn/note.txt"
            ),
            ChatAttachmentRef(
                type: "chat_attachment",
                id: "upload-2",
                source: .upload,
                name: "diagram.png",
                mimeType: "image/png",
                sizeBytes: 84,
                sha256: nil,
                kind: .image,
                workspacePath: nil
            ),
        ]

        let text = MacAttachmentDisplayFormatter.appendAttachedFilesBlock(to: " Review these ", attachments: refs)

        #expect(text == """
        Review these

        Attached files:
        - note.txt: .pi/attachments/session/turn/note.txt
        - diagram.png: diagram.png
        """)
    }
}

private struct TemporaryFile {
    let url: URL

    init(name: String, contents: Data) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mac-pending-attachment-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(name)
        try contents.write(to: url)
    }
}
