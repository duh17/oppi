import AppKit
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

    @Test func imageFilesUseImagePreviewAndRealThumbnails() throws {
        let png = try TemporaryFile(name: "shot.png", contents: Self.oneByOnePNG)
        let note = try TemporaryFile(name: "note.txt", contents: Data("hello".utf8))

        let imageAttachment = try MacPendingAttachment(url: png.url)
        let fileAttachment = try MacPendingAttachment(url: note.url)

        #expect(imageAttachment.isImage)
        #expect(!fileAttachment.isImage)
        #expect(MacPendingAttachmentPreview.forAttachment(imageAttachment) == .image)
        #expect(MacPendingAttachmentPreview.forAttachment(fileAttachment) == .document)
        #expect(MacPendingAttachmentPreview.forAttachment(imageAttachment).systemImageFallback == "photo")
        #expect(MacPendingAttachmentThumbnail.image(for: imageAttachment) != nil)
        #expect(MacPendingAttachmentThumbnail.image(for: fileAttachment) == nil)
    }

    @Test func pasteboardParserPrefersFileURLsAndDedupes() throws {
        let file = try TemporaryFile(name: "note.txt", contents: Data("hello".utf8))
        let payload = MacComposerPasteboardParser.payload(
            fileURLs: [file.url, file.url],
            images: [
                MacComposerPasteboardImage(
                    data: Self.oneByOnePNG,
                    mimeType: "image/png",
                    suggestedName: "Pasted Image.png"
                )
            ]
        )

        #expect(payload.fileURLs == [file.url, file.url])
        #expect(payload.images.isEmpty)

        let result = MacComposerPasteboardParser.adding(payload, to: [])
        #expect(result.attachments.map(\.displayName) == ["note.txt"])
        #expect(result.rejectedMessages.isEmpty)
    }

    @Test func pasteboardParserStagesImageDataAsFileAttachment() throws {
        let payload = MacComposerPasteboardPayload(
            fileURLs: [],
            images: [
                MacComposerPasteboardImage(
                    data: Self.oneByOnePNG,
                    mimeType: "image/png",
                    suggestedName: "Pasted Image.png"
                )
            ]
        )

        let result = MacComposerPasteboardParser.adding(payload, to: [])
        defer {
            for attachment in result.attachments {
                try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
            }
        }

        let attachment = try #require(result.attachments.first)
        #expect(result.attachments.count == 1)
        #expect(attachment.displayName == "Pasted Image.png")
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.isImage)
        #expect(attachment.ownsTemporaryFile)
        #expect(MacPendingAttachmentPreview.forAttachment(attachment) == .image)
        #expect(MacPendingAttachmentThumbnail.image(for: attachment) != nil)
        #expect(result.rejectedMessages.isEmpty)
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))
    }

    @Test func pasteboardParserLeavesTextOnlyPasteUnstaged() {
        let payload = MacComposerPasteboardParser.payload(fileURLs: [], images: [])
        #expect(!payload.hasAttachments)
        #expect(MacComposerPasteboardParser.adding(payload, to: []).attachments.isEmpty)
    }

    @Test func pasteCommandStagesAttachmentsAndPastesTextWhenClipboardHasBoth() {
        let plan = MacComposerPasteCommand.plan(
            payload: MacComposerPasteboardPayload(
                fileURLs: [URL(fileURLWithPath: "/tmp/note.txt")],
                images: []
            ),
            string: "hello"
        )
        #expect(plan.action == .stageAttachmentsAndPasteText)
        #expect(plan.action.shouldStageAttachments)
        #expect(plan.action.shouldPasteText)
        #expect(plan.textToInsert == "hello")
    }

    @Test func pasteCommandDoesNotSwallowTextOnlyPaste() {
        let plan = MacComposerPasteCommand.plan(
            payload: MacComposerPasteboardPayload(fileURLs: [], images: []),
            string: "hello"
        )
        #expect(plan.action == .pasteTextOnly)
        #expect(!plan.action.shouldStageAttachments)
        #expect(plan.action.shouldPasteText)
        #expect(plan.textToInsert == "hello")
    }

    @Test func pasteCommandStagesImageOnlyWithoutInsertingText() {
        let plan = MacComposerPasteCommand.plan(
            payload: MacComposerPasteboardPayload(
                fileURLs: [],
                images: [
                    MacComposerPasteboardImage(
                        data: Self.oneByOnePNG,
                        mimeType: "image/png",
                        suggestedName: "Pasted Image.png"
                    )
                ]
            ),
            string: nil
        )
        #expect(plan.action == .stageAttachmentsOnly)
        #expect(plan.action.shouldStageAttachments)
        #expect(!plan.action.shouldPasteText)
        #expect(plan.textToInsert == nil)
    }

    @Test func pastedImageTempFileIsDeletedWhenPendingItemIsRemoved() throws {
        let payload = MacComposerPasteboardPayload(
            fileURLs: [],
            images: [
                MacComposerPasteboardImage(
                    data: Self.oneByOnePNG,
                    mimeType: "image/png",
                    suggestedName: "Pasted Image.png"
                )
            ]
        )
        let result = MacComposerPasteboardParser.adding(payload, to: [])
        let attachment = try #require(result.attachments.first)
        let directory = attachment.url.deletingLastPathComponent()
        #expect(attachment.ownsTemporaryFile)
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))

        MacPastedAttachmentFileStore.removeOwned(in: result.attachments, notIn: [])

        #expect(!FileManager.default.fileExists(atPath: attachment.url.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func removeOwnedLeavesUserChosenFilesOnDisk() throws {
        let file = try TemporaryFile(name: "note.txt", contents: Data("hello".utf8))
        let attachment = try MacPendingAttachment(url: file.url)
        #expect(!attachment.ownsTemporaryFile)

        MacPastedAttachmentFileStore.removeIfOwned(attachment)

        #expect(FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test func pastedAttachmentLifetimeDeletesOwnedFilesOnRelease() throws {
        let payload = MacComposerPasteboardPayload(
            fileURLs: [],
            images: [
                MacComposerPasteboardImage(
                    data: Self.oneByOnePNG,
                    mimeType: "image/png",
                    suggestedName: "Pasted Image.png"
                )
            ]
        )
        let result = MacComposerPasteboardParser.adding(payload, to: [])
        let attachment = try #require(result.attachments.first)
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))

        do {
            let lifetime = MacPastedAttachmentLifetime()
            lifetime.replace(with: result.attachments)
        }

        #expect(!FileManager.default.fileExists(atPath: attachment.url.path))
    }

    @Test func clearAllDeletesPastedAttachmentTempsAndReportsZeroSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-mac-pasted-attachments-tests-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("leftover.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("paste".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(MacPastedAttachmentFileStore.diskSize(rootDirectory: root) == 5)
        MacPastedAttachmentFileStore.clearAll(rootDirectory: root)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(MacPastedAttachmentFileStore.diskSize(rootDirectory: root) == 0)
    }

    @Test func uniquePasteboardReadsFileURLsAndPNGData() throws {
        let file = try TemporaryFile(name: "note.txt", contents: Data("hello".utf8))
        let pasteboard = NSPasteboard.withUniqueName()

        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([file.url as NSURL]))
        let filePayload = MacComposerPasteboardParser.payload(from: pasteboard)
        #expect(filePayload.fileURLs.map(\.standardizedFileURL.path) == [file.url.standardizedFileURL.path])
        #expect(filePayload.images.isEmpty)

        pasteboard.clearContents()
        #expect(pasteboard.setData(Self.oneByOnePNG, forType: .png))
        let imagePayload = MacComposerPasteboardParser.payload(from: pasteboard)
        #expect(imagePayload.fileURLs.isEmpty)
        #expect(imagePayload.images.map(\.mimeType) == ["image/png"])
        #expect(imagePayload.images.first?.data == Self.oneByOnePNG)
    }

    @Test func uniquePasteboardMixedFileAndStringStagesAndKeepsText() throws {
        let file = try TemporaryFile(name: "note.txt", contents: Data("hello".utf8))
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(file.url.absoluteString, forType: .fileURL)
        item.setString("keep this text", forType: .string)
        #expect(pasteboard.writeObjects([item]))

        let plan = MacComposerPasteCommand.plan(from: pasteboard)
        #expect(plan.action == .stageAttachmentsAndPasteText)
        #expect(plan.textToInsert == "keep this text")
        #expect(plan.payload.fileURLs.map(\.standardizedFileURL.path) == [file.url.standardizedFileURL.path])
    }

    @Test func composerPastePathUsesAppKitPasteNotEventMonitor() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let bar = try String(
            contentsOf: testsDir.appending(path: "OppiMac/Views/MacSessionComposerBar.swift"),
            encoding: .utf8
        )
        let input = try String(
            contentsOf: testsDir.appending(path: "OppiMac/Views/MacComposerInputView.swift"),
            encoding: .utf8
        )

        #expect(bar.contains("MacComposerInputView"))
        #expect(bar.contains(".keyboardShortcut(.return, modifiers: .command)"))
        #expect(bar.contains("MacPastedAttachmentFileStore.removeOwned"))
        #expect(bar.contains("pastedFileLifetime"))
        #expect(!bar.contains("NSEvent.addLocalMonitor"))
        #expect(!bar.contains("NSEvent.addGlobalMonitor"))
        #expect(!bar.contains("onPasteCommand"))
        #expect(!input.contains("NSEvent.addLocalMonitor"))
        #expect(!input.contains("NSEvent.addGlobalMonitor"))
        #expect(input.contains("override func paste"))
        #expect(input.contains("MacComposerPasteCommand"))
        #expect(input.contains("isCommandReturn"))
    }

    @Test func pendingStripPaintsNSImageThumbnailsNotOnlyPhotoSymbol() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "OppiMac/Views/MacSessionComposerBar.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let start = source.range(of: "private struct MacPendingAttachmentStrip") else {
            Issue.record("Missing MacPendingAttachmentStrip")
            return
        }
        guard let end = source.range(
            of: "private struct MacMessageQueueCard",
            range: start.upperBound..<source.endIndex
        ) else {
            Issue.record("Missing MacMessageQueueCard")
            return
        }
        let slice = String(source[start.lowerBound..<end.lowerBound])
        #expect(slice.contains("Image(nsImage:"))
        #expect(slice.contains("MacPendingAttachmentThumbnail"))
        #expect(slice.contains("systemImageFallback"))
    }

    private static let oneByOnePNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
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
