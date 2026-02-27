import Testing
@testable import Oppi

@Suite("FileType")
struct FileTypeTests {

    @Test func detectSwift() {
        let ft = FileType.detect(from: "Sources/main.swift")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code, got \(ft)")
            return
        }
        #expect(lang == .swift)
    }

    @Test func detectTypeScript() {
        let ft = FileType.detect(from: "src/index.ts")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code")
            return
        }
        #expect(lang == .typescript)
    }

    @Test func detectMarkdown() {
        #expect(FileType.detect(from: "README.md") == .markdown)
        #expect(FileType.detect(from: "docs/guide.mdx") == .markdown)
    }

    @Test func detectJSON() {
        #expect(FileType.detect(from: "config.json") == .json)
    }

    @Test func detectImage() {
        #expect(FileType.detect(from: "logo.png") == .image)
        #expect(FileType.detect(from: "photo.jpg") == .image)
        #expect(FileType.detect(from: "anim.gif") == .image)
        #expect(FileType.detect(from: "icon.webp") == .image)
        #expect(FileType.detect(from: "icon.svg") == .image)
    }

    @Test func detectDockerfile() {
        let ft = FileType.detect(from: "Dockerfile")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for Dockerfile")
            return
        }
        #expect(lang == .shell)
    }

    @Test func detectContainerfile() {
        let ft = FileType.detect(from: "Containerfile")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for Containerfile")
            return
        }
        #expect(lang == .shell)
    }

    @Test func detectMakefile() {
        let ft = FileType.detect(from: "Makefile")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for Makefile")
            return
        }
        #expect(lang == .shell)
    }

    @Test func nilPathIsPlain() {
        #expect(FileType.detect(from: nil) == .plain)
    }

    @Test func unknownExtensionIsPlain() {
        #expect(FileType.detect(from: "file.xyz") == .plain)
    }

    @Test func noExtensionIsPlain() {
        #expect(FileType.detect(from: "LICENSE") == .plain)
    }

    @Test func audioExtensionDetected() {
        #expect(FileType.detect(from: "voice.wav") == .audio)
        #expect(FileType.detect(from: "voice.mp3") == .audio)
    }

    @Test func displayLabels() {
        #expect(FileType.markdown.displayLabel == "Markdown")
        #expect(FileType.json.displayLabel == "JSON")
        #expect(FileType.image.displayLabel == "Image")
        #expect(FileType.audio.displayLabel == "Audio")
        #expect(FileType.plain.displayLabel == "Text")
        #expect(FileType.code(language: .swift).displayLabel == "Swift")
    }
}
