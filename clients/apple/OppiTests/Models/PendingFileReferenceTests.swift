import Foundation
import Testing
@testable import Oppi

@Suite("PendingFileReference")
struct PendingFileReferenceTests {

    // MARK: - Construction & properties

    @Test func basicFileReference() {
        let ref = PendingFileReference(path: "src/main.swift", isDirectory: false)
        #expect(ref.path == "src/main.swift")
        #expect(ref.isDirectory == false)
    }

    @Test func basicDirectoryReference() {
        let ref = PendingFileReference(path: "src/", isDirectory: true)
        #expect(ref.path == "src/")
        #expect(ref.isDirectory == true)
    }

    // MARK: - ID (derived from path)

    @Test func idIsPath() {
        let ref = PendingFileReference(path: "foo/bar.txt", isDirectory: false)
        #expect(ref.id == "foo/bar.txt")
    }

    @Test func idIsPathForDirectory() {
        let ref = PendingFileReference(path: "foo/bar/", isDirectory: true)
        #expect(ref.id == "foo/bar/")
    }

    // MARK: - displayName

    @Test func displayNameIsLastPathComponent() {
        let ref = PendingFileReference(path: "src/core/utils.ts", isDirectory: false)
        #expect(ref.displayName == "utils.ts")
    }

    @Test func displayNameForRootFile() {
        let ref = PendingFileReference(path: "README.md", isDirectory: false)
        #expect(ref.displayName == "README.md")
    }

    @Test func displayNameStripsTrailingSlashForDirectory() {
        let ref = PendingFileReference(path: "src/components/", isDirectory: true)
        #expect(ref.displayName == "components")
    }

    @Test func displayNameForDirectoryWithoutTrailingSlash() {
        let ref = PendingFileReference(path: "src/components", isDirectory: true)
        #expect(ref.displayName == "components")
    }

    @Test func displayNameForRootDirectory() {
        let ref = PendingFileReference(path: "dist/", isDirectory: true)
        #expect(ref.displayName == "dist")
    }

    @Test func displayNameForSingleComponentNoSlash() {
        let ref = PendingFileReference(path: "Makefile", isDirectory: false)
        #expect(ref.displayName == "Makefile")
    }

    // MARK: - Edge cases: empty path

    @Test func emptyPathDisplayName() {
        let ref = PendingFileReference(path: "", isDirectory: false)
        // split(separator:) on empty string returns [], .last is nil → fallback to normalized
        #expect(ref.displayName == "")
    }

    @Test func emptyPathId() {
        let ref = PendingFileReference(path: "", isDirectory: false)
        #expect(ref.id == "")
    }

    // MARK: - Edge cases: slash-only path

    @Test func slashOnlyPathAsDirectory() {
        // path="/", isDirectory=true → dropLast → "", split → [], .last nil → fallback ""
        let ref = PendingFileReference(path: "/", isDirectory: true)
        #expect(ref.displayName == "")
    }

    @Test func slashOnlyPathAsFile() {
        // Not a directory, so no dropLast. split("/", separator: "/") → [], .last nil → fallback "/"
        let ref = PendingFileReference(path: "/", isDirectory: false)
        #expect(ref.displayName == "/")
    }

    // MARK: - Edge cases: paths with special characters

    @Test func pathWithSpaces() {
        let ref = PendingFileReference(path: "my project/hello world.txt", isDirectory: false)
        #expect(ref.displayName == "hello world.txt")
    }

    @Test func pathWithUnicode() {
        let ref = PendingFileReference(path: "项目/源代码/主文件.swift", isDirectory: false)
        #expect(ref.displayName == "主文件.swift")
    }

    @Test func pathWithEmoji() {
        let ref = PendingFileReference(path: "docs/🚀/launch.md", isDirectory: false)
        #expect(ref.displayName == "launch.md")
    }

    @Test func directoryNameWithUnicode() {
        let ref = PendingFileReference(path: "données/résultats/", isDirectory: true)
        #expect(ref.displayName == "résultats")
    }

    @Test func pathWithDots() {
        let ref = PendingFileReference(path: "src/.hidden/config.json", isDirectory: false)
        #expect(ref.displayName == "config.json")
    }

    @Test func dotfile() {
        let ref = PendingFileReference(path: ".gitignore", isDirectory: false)
        #expect(ref.displayName == ".gitignore")
    }

    // MARK: - Edge cases: long paths

    @Test func veryLongPath() {
        let components = (0..<50).map { "dir\($0)" }
        let path = components.joined(separator: "/") + "/file.txt"
        let ref = PendingFileReference(path: path, isDirectory: false)
        #expect(ref.displayName == "file.txt")
        #expect(ref.id == path)
    }

    // MARK: - Edge cases: multiple trailing slashes and double slashes

    @Test func doubleSlashInPath() {
        // split(separator: "/") omits empty subsequences by default
        let ref = PendingFileReference(path: "src//utils.ts", isDirectory: false)
        #expect(ref.displayName == "utils.ts")
    }

    @Test func trailingSlashOnFile() {
        // isDirectory is false, so trailing slash is NOT stripped
        let ref = PendingFileReference(path: "src/file.txt/", isDirectory: false)
        // split on "/" → ["src", "file.txt", ""] — last is "" → empty display name?
        // Actually, split(separator:) omits empty subsequences, so → ["src", "file.txt"]
        #expect(ref.displayName == "file.txt")
    }

    // MARK: - Equatable

    @Test func equalWhenSamePathAndIsDirectory() {
        let a = PendingFileReference(path: "foo/bar.txt", isDirectory: false)
        let b = PendingFileReference(path: "foo/bar.txt", isDirectory: false)
        #expect(a == b)
    }

    @Test func notEqualWhenDifferentPath() {
        let a = PendingFileReference(path: "foo/bar.txt", isDirectory: false)
        let b = PendingFileReference(path: "foo/baz.txt", isDirectory: false)
        #expect(a != b)
    }

    @Test func notEqualWhenDifferentIsDirectory() {
        let a = PendingFileReference(path: "src", isDirectory: false)
        let b = PendingFileReference(path: "src", isDirectory: true)
        #expect(a != b)
    }

    @Test func equalDirectories() {
        let a = PendingFileReference(path: "src/core/", isDirectory: true)
        let b = PendingFileReference(path: "src/core/", isDirectory: true)
        #expect(a == b)
    }

    // MARK: - Hashable (via Identifiable id)

    @Test func identifiableDedupInDictionary() {
        let a = PendingFileReference(path: "a.txt", isDirectory: false)
        let b = PendingFileReference(path: "b.txt", isDirectory: false)
        let c = PendingFileReference(path: "a.txt", isDirectory: false)
        // Since id == path, keying by id deduplicates a and c
        let dict = Dictionary([(a.id, a), (b.id, b), (c.id, c)], uniquingKeysWith: { _, new in new })
        #expect(dict.count == 2)
    }

    @Test func samePathDifferentIsDirectoryShareId() {
        // Equatable considers isDirectory, so these are not equal
        let file = PendingFileReference(path: "src", isDirectory: false)
        let dir = PendingFileReference(path: "src", isDirectory: true)
        #expect(file != dir)
        // But id is the same (both "src") — this is a potential footgun in
        // ForEach or any id-keyed collection.
        #expect(file.id == dir.id)
    }

    // MARK: - Sendable conformance (compile-time only)

    @Test func sendableConformance() {
        // This test verifies at compile time that PendingFileReference is Sendable.
        // If it weren't, the explicit type annotation would fail to compile.
        let ref = PendingFileReference(path: "test.txt", isDirectory: false)
        let sendable: any Sendable = ref
        #expect(sendable is PendingFileReference)
    }

    @Test func attachmentPresentationSeparatesUploadsFromRepoPointers() {
        let display = UserMessageAttachmentPresentation.makeDisplayText(
            text: "Please check these",
            pendingAttachments: [
                PendingAttachment.localFile(name: "error.log", data: Data("oops".utf8), mimeType: "text/plain")
            ],
            pendingRepoPointers: [
                PendingFileReference(path: "Sources/App.swift", isDirectory: false, kind: .workspaceFile),
                PendingFileReference(path: "Tests/AppTests.swift", isDirectory: false, kind: .reviewFile)
            ]
        )

        let parsed = UserMessageAttachmentPresentation.parse(rawText: display)
        #expect(parsed.visibleText == "Please check these")
        #expect(parsed.badges.map { $0.label } == ["1 upload"])
        #expect(parsed.pathPills.map { $0.label } == ["Sources/App.swift", "Tests/AppTests.swift"])
    }

    @Test func attachmentPresentationHidesReferenceBlockFromVisibleText() {
        let raw = "Question about these files\n\nReferenced workspace files:\n- src/main.swift\n- README.md"
        let parsed = UserMessageAttachmentPresentation.parse(rawText: raw)

        #expect(parsed.visibleText == "Question about these files")
        #expect(parsed.badges.isEmpty)
        #expect(parsed.pathPills.map { $0.label } == ["src/main.swift", "README.md"])
    }

    @Test func attachmentPresentationExtractsMaterializedAttachmentPaths() {
        let raw = "testing\n\nAttached files:\n- image-1.jpg: .pi/attachments/s1/t1/image-1.jpg\n  MIME: image/jpeg\n  Size: 1 MB"
        let parsed = UserMessageAttachmentPresentation.parse(rawText: raw)

        #expect(parsed.visibleText == "testing")
        #expect(parsed.pathPills.map { $0.label } == ["image-1.jpg"])
    }

    @Test func attachmentPresentationAppendsUploadedAttachmentPathsToDisplayText() {
        let display = UserMessageAttachmentPresentation.makeDisplayText(
            text: "Look at this",
            pendingAttachments: [
                PendingAttachment.localFile(name: "image-1.jpg", data: Data("jpg".utf8), mimeType: "image/jpeg")
            ],
            pendingRepoPointers: [],
            uploadedAttachments: [
                ChatAttachmentRef(
                    type: "attachment",
                    id: "att-1",
                    source: .upload,
                    name: "image-1.jpg",
                    mimeType: "image/jpeg",
                    sizeBytes: 3,
                    sha256: nil,
                    kind: nil,
                    workspacePath: ".pi/attachments/s1/t1/image-1.jpg"
                )
            ]
        )

        let parsed = UserMessageAttachmentPresentation.parse(rawText: display)
        #expect(parsed.visibleText == "Look at this")
        #expect(parsed.pathPills.map { $0.path } == [".pi/attachments/s1/t1/image-1.jpg"])
        #expect(parsed.pathPills.first?.supportsInlinePreview == true)
    }

    @Test func attachmentPresentationShowsNonImageUploadNameBeforeServerMaterializesPath() {
        let display = UserMessageAttachmentPresentation.makeDisplayText(
            text: "Read this log",
            pendingAttachments: [
                PendingAttachment.localFile(name: "error.log", data: Data("oops".utf8), mimeType: "text/plain")
            ],
            pendingRepoPointers: [],
            uploadedAttachments: [
                ChatAttachmentRef(
                    type: "attachment",
                    id: "att-log",
                    source: .upload,
                    name: "error.log",
                    mimeType: "text/plain",
                    sizeBytes: 4,
                    sha256: nil,
                    kind: nil,
                    workspacePath: nil
                )
            ]
        )

        let parsed = UserMessageAttachmentPresentation.parse(rawText: display)
        #expect(parsed.visibleText == "Read this log")
        #expect(parsed.badges.map { $0.label } == ["1 upload"])
        #expect(parsed.pathPills.map { $0.label } == ["error.log"])
        #expect(parsed.pathPills.map { $0.path } == ["error.log"])
        #expect(parsed.pathPills.first?.supportsInlinePreview == false)
    }

    @Test func referenceBlockBuilderPreservesQuickSessionRepoPointers() {
        let transport = PendingFileReference.appendReferenceBlock(
            to: "Please inspect",
            files: [
                PendingFileReference(path: "Sources/App.swift", isDirectory: false),
                PendingFileReference(path: "Tests/AppTests.swift", isDirectory: false)
            ]
        )

        let parsed = UserMessageAttachmentPresentation.parse(rawText: transport)
        #expect(parsed.visibleText == "Please inspect")
        #expect(parsed.pathPills.map { $0.path } == ["Sources/App.swift", "Tests/AppTests.swift"])
    }
}
