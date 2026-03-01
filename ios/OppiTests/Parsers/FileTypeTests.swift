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

    @Test func noExtensionShellShebangDetected() {
        let ft = FileType.detect(from: "scripts/run", content: "#!/bin/bash\necho hi")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for shebang shell script")
            return
        }
        #expect(lang == .shell)
    }

    @Test func noExtensionEnvShellShebangDetected() {
        let ft = FileType.detect(from: "scripts/run", content: "#!/usr/bin/env -S bash -eu\necho hi")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for env shebang shell script")
            return
        }
        #expect(lang == .shell)
    }

    @Test func noExtensionPythonShebangDetected() {
        let ft = FileType.detect(from: "scripts/run", content: "#!/usr/bin/env python3\nprint('hi')")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for python shebang script")
            return
        }
        #expect(lang == .python)
    }

    @Test func noExtensionRubyShebangDetected() {
        let ft = FileType.detect(from: "scripts/run", content: "#!/usr/bin/ruby\nputs 'hi'")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for ruby shebang script")
            return
        }
        #expect(lang == .ruby)
    }

    @Test func noExtensionNodeShebangDetected() {
        let ft = FileType.detect(from: "scripts/run", content: "#!/usr/bin/env node\nconsole.log('hi')")
        guard case .code(let lang) = ft else {
            Issue.record("Expected .code for node shebang script")
            return
        }
        #expect(lang == .javascript)
    }

    @Test func extensionTakesPrecedenceOverShebang() {
        #expect(FileType.detect(from: "README.md", content: "#!/bin/bash\necho hi") == .markdown)
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

@Suite("File content presentation policy")
struct FileContentPresentationPolicyTests {
    @Test func inlinePresentationUsesTimelineChrome() {
        #expect(FileContentPresentation.inline.usesInlineChrome)
        #expect(FileContentPresentation.inline.viewportMaxHeight == 500)
        #expect(FileContentPresentation.inline.allowsExpansionAffordance)
    }

    @Test func documentPresentationUsesNativeViewerLayout() {
        #expect(FileContentPresentation.document.usesInlineChrome == false)
        #expect(FileContentPresentation.document.viewportMaxHeight == nil)
        #expect(FileContentPresentation.document.allowsExpansionAffordance == false)
    }

    @MainActor
    @Test func skillFileViewIsPinnedToDocumentPresentation() {
        #expect(SkillFileView.contentPresentation == .document)
        #expect(SkillFileView.allowsNestedFullScreenExpansion == false)
    }

    @MainActor
    @Test func remoteFileViewIsPinnedToDocumentPresentation() {
        #expect(RemoteFileView.contentPresentation == .document)
        #expect(RemoteFileView.allowsNestedFullScreenExpansion == false)
    }
}
