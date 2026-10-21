import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal working directory")
struct SSHTerminalWorkingDirectoryTests {
    @Test func osc7FileURLKeepsOnlyThePath() {
        #expect(SSHTerminalWorkingDirectory.path(from: "file://mac-studio/Users/duh/workspace") == "/Users/duh/workspace")
        #expect(SSHTerminalWorkingDirectory.path(from: "file:///Users/duh") == "/Users/duh")
        #expect(SSHTerminalWorkingDirectory.path(from: "FILE://Host/tmp/x") == "/tmp/x")
        #expect(SSHTerminalWorkingDirectory.path(from: "file://host/a%20b/c") == "/a b/c")
        #expect(SSHTerminalWorkingDirectory.path(from: "file://host/Users/duh/") == "/Users/duh")
        #expect(SSHTerminalWorkingDirectory.path(from: "file://host/") == "/")
        #expect(SSHTerminalWorkingDirectory.path(from: "  file://host/tmp  ") == "/tmp")
    }

    @Test func theReportedHostDecidesWhetherTheFolderIsUsable() {
        let first = SSHTerminalWorkingDirectory.report(from: "file://mac-studio/Users/duh/workspace")
        #expect(first == .init(host: "mac-studio", path: "/Users/duh/workspace"))
        #expect(first?.folder(firstHost: nil) == "/Users/duh/workspace")
        #expect(first?.folder(firstHost: "mac-studio") == "/Users/duh/workspace")
        #expect(first?.folder(firstHost: "other-box") == nil, "a nested shell on another host is unknown here")
        // A host that says nothing about the machine is always usable.
        #expect(SSHTerminalWorkingDirectory.report(from: "file:///tmp/x")?.isLocal == true)
        #expect(SSHTerminalWorkingDirectory.report(from: "file://localhost/tmp/x")?.folder(firstHost: "mac-studio") == "/tmp/x")
        #expect(SSHTerminalWorkingDirectory.report(from: "file://Mac-Studio./tmp")?.host == "mac-studio")
    }

    @Test func onlyFileURLsAreAFolder() {
        #expect(SSHTerminalWorkingDirectory.path(from: "") == nil)
        #expect(SSHTerminalWorkingDirectory.path(from: "/Users/duh") == nil, "a bare path is not OSC 7")
        #expect(SSHTerminalWorkingDirectory.path(from: "file:/tmp/x") == "/tmp/x", "a local file URL either way")
        #expect(SSHTerminalWorkingDirectory.path(from: "https://example.com/a") == nil)
        #expect(SSHTerminalWorkingDirectory.path(from: "file://host/tmp?x=1") == nil)
        #expect(SSHTerminalWorkingDirectory.path(from: "file://host/tmp#y") == nil)
        #expect(SSHTerminalWorkingDirectory.path(from: "file://host/a\u{0}b") == nil)
        #expect(SSHTerminalWorkingDirectory.path(from: "file://host/" + String(repeating: "a", count: 5000)) == nil)
    }

    @Test func normalizeCollapsesDotSegmentsAndTrailingSlashes() {
        #expect(SSHTerminalWorkingDirectory.normalize("/a/b/../c") == "/a/c")
        #expect(SSHTerminalWorkingDirectory.normalize("/a/./b") == "/a/b")
        #expect(SSHTerminalWorkingDirectory.normalize("/a//b//") == "/a/b")
        #expect(SSHTerminalWorkingDirectory.normalize("/..") == "/", "never above the root")
        #expect(SSHTerminalWorkingDirectory.normalize("relative/x") == nil)
    }

    @Test @MainActor func enginePublishesTheShellFolderAndClearsItOnReset() throws {
        let engine = try SSHTerminalEngine(geometry: .init(columns: 40, rows: 6)) { _ in }
        #expect(engine.workingDirectory.isEmpty)
        engine.receive(Data("\u{1b}]7;file://mac-studio/Users/duh/workspace/oppi\u{1b}\\".utf8))
        #expect(engine.workingDirectory == "/Users/duh/workspace/oppi")
        engine.receive(Data("\u{1b}]7;file://mac-studio/tmp/a%20b\u{7}".utf8))
        #expect(engine.workingDirectory == "/tmp/a b", "BEL-terminated OSC 7 reads the same")
        // A nested shell on another machine must not resolve this server's paths.
        engine.receive(Data("\u{1b}]7;file://other-box/srv/x\u{1b}\\".utf8))
        #expect(engine.workingDirectory.isEmpty)
        engine.receive(Data("\u{1b}]7;file://mac-studio/tmp/c\u{1b}\\".utf8))
        #expect(engine.workingDirectory == "/tmp/c", "the first host still counts")
        // RIS clears the folder with the title and the program records.
        engine.receive(Data("\u{1b}c".utf8))
        #expect(engine.workingDirectory.isEmpty)
    }
}

@Suite("SSH terminal open targets")
struct SSHTerminalOpenResolutionTests {
    private let folder = "/Users/duh/workspace/oppi"

    @Test func trailingLineAndColumnAreDroppedOnlyForPaths() {
        #expect(SSHTerminalOpenResolution.strippingLineColumn("/a/b.swift:42") == "/a/b.swift")
        #expect(SSHTerminalOpenResolution.strippingLineColumn("/a/b.swift:12:3") == "/a/b.swift")
        #expect(SSHTerminalOpenResolution.strippingLineColumn("src/x.swift:1") == "src/x.swift")
        #expect(SSHTerminalOpenResolution.strippingLineColumn("error:") == "error:")
        #expect(SSHTerminalOpenResolution.strippingLineColumn("a:b") == "a:b")
        // A URL is resolved whole, so its port is not read as a line number.
        #expect(
            SSHTerminalOpenResolution.target(text: "http://localhost:5173", hyperlink: nil, folder: nil)
                == .web(url: URL(string: "http://localhost:5173")!, hostLabel: "localhost")
        )
        #expect(
            SSHTerminalOpenResolution.target(text: "https://ex.com:8443/x", hyperlink: nil, folder: nil)
                == .web(url: URL(string: "https://ex.com:8443/x")!, hostLabel: "ex.com")
        )
        #expect(
            SSHTerminalOpenResolution.target(text: "/a/b.swift:12:3", hyperlink: nil, folder: nil)
                == .path("/a/b.swift")
        )
    }

    @Test func webLinksOpenOnlyForHTTPAndHTTPS() {
        #expect(
            SSHTerminalOpenResolution.target(text: "https://example.com/a/b?x=1", hyperlink: nil, folder: nil)
                == .web(url: URL(string: "https://example.com/a/b?x=1")!, hostLabel: "example.com")
        )
        #expect(
            SSHTerminalOpenResolution.target(text: "http://user@host.test:8080/x", hyperlink: nil, folder: nil)
                == .web(url: URL(string: "http://user@host.test:8080/x")!, hostLabel: "host.test")
        )
        #expect(SSHTerminalOpenResolution.target(text: "mailto:a@b.test", hyperlink: nil, folder: nil) == nil)
        #expect(SSHTerminalOpenResolution.target(text: "ftp://example.com/a", hyperlink: nil, folder: nil) == nil)
    }

    @Test func anOSC8LinkWinsOverItsWordAndOtherSchemesAreNotOpened() {
        #expect(
            SSHTerminalOpenResolution.target(
                text: "the docs", hyperlink: "https://example.com/docs", folder: nil
            ) == .web(url: URL(string: "https://example.com/docs")!, hostLabel: "example.com")
        )
        #expect(
            SSHTerminalOpenResolution.target(
                text: "open", hyperlink: "vscode://file/tmp/x", folder: folder
            ) == nil,
            "a link with another scheme is a Copy, not a fallback to the word"
        )
    }

    @Test func pathsResolveAgainstTheShellFolder() {
        #expect(
            SSHTerminalOpenResolution.target(text: "/usr/local/bin/thing", hyperlink: nil, folder: nil)
                == .path("/usr/local/bin/thing")
        )
        #expect(
            SSHTerminalOpenResolution.target(text: "Sources/App.swift", hyperlink: nil, folder: folder)
                == .path("/Users/duh/workspace/oppi/Sources/App.swift")
        )
        #expect(
            SSHTerminalOpenResolution.target(text: "../other/x.md", hyperlink: nil, folder: folder)
                == .path("/Users/duh/workspace/other/x.md")
        )
        #expect(
            SSHTerminalOpenResolution.target(text: "README.md", hyperlink: nil, folder: folder)
                == .path("/Users/duh/workspace/oppi/README.md")
        )
        #expect(
            SSHTerminalOpenResolution.target(text: "src/x.swift:42", hyperlink: nil, folder: folder)
                == .path("/Users/duh/workspace/oppi/src/x.swift")
        )
        #expect(
            SSHTerminalOpenResolution.target(text: "~/notes.md", hyperlink: nil, folder: nil)
                == .path("~/notes.md"),
            "a home-relative path resolves on the server, which knows its home"
        )
    }

    @Test func aRelativePathWithNoFolderIsNotOpened() {
        #expect(SSHTerminalOpenResolution.target(text: "Sources/App.swift", hyperlink: nil, folder: nil) == nil)
        #expect(SSHTerminalOpenResolution.target(text: "README.md", hyperlink: nil, folder: nil) == nil)
        #expect(SSHTerminalOpenResolution.target(text: "..", hyperlink: nil, folder: folder) == nil)
        #expect(SSHTerminalOpenResolution.target(text: "", hyperlink: nil, folder: folder) == nil)
        #expect(SSHTerminalOpenResolution.target(text: nil, hyperlink: nil, folder: folder) == nil)
        #expect(
            SSHTerminalOpenResolution.target(text: "two words/x", hyperlink: nil, folder: folder) == nil,
            "a word split by a space is not one path"
        )
    }

    @Test func aHomePathCannotClimbAboveHome() {
        #expect(SSHTerminalOpenResolution.target(text: "~/../x", hyperlink: nil, folder: nil) == nil)
        #expect(SSHTerminalOpenResolution.target(text: "~/a/../b", hyperlink: nil, folder: nil) == .path("~/b"))
        #expect(SSHTerminalPathResolution.normalizingRelative("../x") == nil)
        #expect(SSHTerminalPathResolution.normalizingRelative("a/../../x") == nil)
        #expect(SSHTerminalPathResolution.normalizingRelative("") == nil)
    }

    @Test func aFolderThatIsRelativeIsNotUsableAsABase() {
        #expect(
            SSHTerminalOpenResolution.target(text: "a/b", hyperlink: nil, folder: "relative/folder") == nil
        )
    }
}

@Suite("SSH terminal paired server match")
struct SSHTerminalServerMatchTests {
    private let paired: [(id: String, host: String)] = [
        (id: "studio", host: "mac-studio.tail1234.ts.net"),
        (id: "mini", host: "mac-mini"),
        (id: "box", host: "192.0.2.10"),
    ]

    @Test func hostAndTailnetNameAreTheSameMachine() {
        #expect(SSHTerminalServerMatch.serverId(forHost: "mac-studio", paired: paired) == "studio")
        #expect(SSHTerminalServerMatch.serverId(forHost: "Mac-Studio", paired: paired) == "studio")
        #expect(SSHTerminalServerMatch.serverId(forHost: "mac-studio.tail1234.ts.net", paired: paired) == "studio")
        #expect(SSHTerminalServerMatch.serverId(forHost: "mac-studio.tail1234.ts.net.", paired: paired) == "studio")
        #expect(SSHTerminalServerMatch.serverId(forHost: "mac-mini.", paired: paired) == "mini")
        #expect(SSHTerminalServerMatch.serverId(forHost: "192.0.2.10", paired: paired) == "box")
    }

    @Test func twoServersWithTheSameShortNameMatchNothing() {
        let ambiguous: [(id: String, host: String)] = [
            (id: "a", host: "mac-studio.a1.ts.net"),
            (id: "b", host: "mac-studio.b2.ts.net"),
        ]
        #expect(SSHTerminalServerMatch.serverId(forHost: "mac-studio", paired: ambiguous) == nil)
        #expect(SSHTerminalServerMatch.serverId(forHost: "mac-studio.a1.ts.net", paired: ambiguous) == "a")
    }

    @Test func anotherMachineOrAShorterNameDoesNotMatch() {
        #expect(SSHTerminalServerMatch.serverId(forHost: "mac-mini", paired: [(id: "x", host: "mac-mini-2")]) == nil)
        #expect(SSHTerminalServerMatch.serverId(forHost: "mac", paired: paired) == nil)
        #expect(SSHTerminalServerMatch.serverId(forHost: "192.0.2.11", paired: paired) == nil)
        #expect(SSHTerminalServerMatch.serverId(forHost: "", paired: paired) == nil)
        #expect(SSHTerminalServerMatch.serverId(forHost: "box.local", paired: paired) == nil)
        #expect(
            SSHTerminalServerMatch.serverId(
                forHost: "pc", paired: [(id: "y", host: "pc.example.com")]
            ) == nil,
            "only a tailnet FQDN is the same machine as its short name"
        )
    }
}

@Suite("SSH terminal host path plan")
struct SSHTerminalHostPathPolicyTests {
    private let home = "/Users/duh"

    private func status(
        _ path: String, exists: Bool = true, directory: Bool = false, file: Bool = true
    ) -> HostPathStatus {
        HostPathStatus(
            path: path, resolvedPath: path, exists: exists,
            isDirectory: directory, isFile: file, issue: nil, message: nil
        )
    }

    @Test func insideHomeMeansTheHomeFolderOrBelowIt() {
        #expect(SSHTerminalHostPathPolicy.isInside(home: home, path: "/Users/duh"))
        #expect(SSHTerminalHostPathPolicy.isInside(home: home, path: "/Users/duh/"))
        #expect(SSHTerminalHostPathPolicy.isInside(home: home, path: "/Users/duh/workspace/x"))
        #expect(!SSHTerminalHostPathPolicy.isInside(home: home, path: "/Users/duh2/x"))
        #expect(!SSHTerminalHostPathPolicy.isInside(home: home, path: "/opt/homebrew/bin/brew"))
        #expect(!SSHTerminalHostPathPolicy.isInside(home: home, path: "/Users"))
        #expect(!SSHTerminalHostPathPolicy.isInside(home: "/", path: "/Users/duh/x"), "never every path")
        #expect(!SSHTerminalHostPathPolicy.isInside(home: "relative", path: "relative/x"))
    }

    @Test func aFileOpensInTheViewerAndAFolderInTheBrowser() {
        #expect(
            SSHTerminalHostPathPolicy.plan(status: status("/Users/duh/notes.md"), home: home)
                == .file("/Users/duh/notes.md")
        )
        #expect(
            SSHTerminalHostPathPolicy.plan(status: status("/Users/duh/workspace", directory: true), home: home)
                == .folder("/Users/duh/workspace")
        )
    }

    @Test func pathsOutsideHomeMissingOnesAndOddOnesAreRefused() {
        #expect(
            SSHTerminalHostPathPolicy.plan(status: status("/opt/homebrew/bin/brew"), home: home)
                == .refused("Files open inside the server's home folder.")
        )
        #expect(
            SSHTerminalHostPathPolicy.plan(status: status("/Users/duh/x", exists: false, file: false), home: home)
                == .refused("That path is not on the host.")
        )
        #expect(
            SSHTerminalHostPathPolicy.plan(status: status("/Users/duh/x", file: false), home: home)
                == .refused("That path is not a file or a folder.")
        )
    }
}

@Suite("SSH terminal menu header")
struct SSHTerminalMenuHeaderTests {
    @Test func theHeaderNamesTheScreenAndTheFolder() {
        #expect(SSHTerminalMenuHeader.text(title: "pi", folder: "") == "pi")
        #expect(SSHTerminalMenuHeader.text(title: "", folder: "") == "SSH Terminal")
        #expect(SSHTerminalMenuHeader.text(title: "pi", folder: "/Users/duh/workspace") == "pi — /Users/duh/workspace")
        #expect(SSHTerminalMenuHeader.text(title: "  pi  ", folder: "  /tmp  ") == "pi — /tmp")
    }

    @Test func aLongFolderKeepsItsTail() {
        let long = "/Users/duh/" + Array(repeating: "a-very-long-folder", count: 8).joined(separator: "/")
        let header = SSHTerminalMenuHeader.text(title: "pi", folder: long)
        #expect(header.count <= SSHTerminalMenuHeader.maximumLength)
        #expect(header.hasPrefix("pi — "))
        #expect(header.hasSuffix("a-very-long-folder"))
        #expect(header.contains("…"))
    }
}

@Suite("SSH terminal hold menu title")
@MainActor
struct SSHTerminalHoldMenuTitleTests {
    @Test func openNamesWhereItGoes() {
        #expect(
            SSHTerminalGridView.openTitle(for: .web(url: URL(string: "https://example.com/a")!, hostLabel: "example.com"))
                == "Open example.com"
        )
        #expect(SSHTerminalGridView.openTitle(for: .path("/Users/duh/notes.md")) == "Open notes.md")
        #expect(SSHTerminalGridView.openTitle(for: .path("/")) == "Open")
    }

    @Test func aLinkPathOrURLHoldsOpenCopyAndPaste() throws {
        let held = SSHTerminalHeldCell(text: "src/x.swift:42", spans: [], hyperlink: nil)
        let menu = try #require(SSHTerminalGridView.holdMenu(
            held: held,
            target: .path("/Users/duh/src/x.swift"),
            canPaste: true,
            open: { _ in },
            copy: {},
            paste: {}
        ))
        #expect(menu.children.map(\.title) == ["Open x.swift", "Copy", "Paste"])
        #expect(menu.children.allSatisfy { $0 is UIAction })
    }

    @Test func aWordWithNothingToOpenStillGetsCopyAndPaste() throws {
        // An unpaired host, or a path outside its home: the owner has no
        // target, and Copy must still be there.
        let word = SSHTerminalHeldCell(text: "/opt/homebrew/bin/brew", spans: [], hyperlink: nil)
        let menu = try #require(SSHTerminalGridView.holdMenu(
            held: word,
            target: nil,
            canPaste: true,
            open: { _ in }, copy: {}, paste: {}
        ))
        #expect(menu.children.map(\.title) == ["Copy", "Paste"])
        let noClipboard = try #require(SSHTerminalGridView.holdMenu(
            held: word, target: nil, canPaste: false, open: { _ in }, copy: {}, paste: {}
        ))
        #expect(noClipboard.children.map(\.title) == ["Copy"])
    }

    @Test func aLinkOnABlankCellCopiesTheLink() throws {
        let held = SSHTerminalHeldCell(text: "", spans: [], hyperlink: "https://example.com/a")
        #expect(SSHTerminalGridView.copyText(for: held) == "https://example.com/a")
        let menu = try #require(SSHTerminalGridView.holdMenu(
            held: held,
            target: .web(url: URL(string: "https://example.com/a")!, hostLabel: "example.com"),
            canPaste: false,
            open: { _ in }, copy: {}, paste: {}
        ))
        #expect(menu.children.map(\.title) == ["Open example.com", "Copy"])
        #expect(SSHTerminalGridView.copyText(for: SSHTerminalHeldCell(text: "notes.md", spans: [], hyperlink: nil)) == "notes.md")
        #expect(SSHTerminalGridView.copyText(for: SSHTerminalHeldCell(text: "", spans: [], hyperlink: nil)) == nil)
    }

    @Test func aPlainCellKeepsTheSystemMenu() {
        #expect(
            SSHTerminalGridView.holdMenu(
                held: SSHTerminalHeldCell(text: "", spans: [], hyperlink: nil),
                target: nil,
                canPaste: true,
                open: { _ in }, copy: {}, paste: {}
            ) == nil,
            "nothing to open and nothing to copy keeps the system's Paste menu"
        )
    }
}
