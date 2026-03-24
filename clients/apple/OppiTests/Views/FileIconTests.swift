import Testing
import SwiftUI
@testable import Oppi

@Suite("FileIcon")
struct FileIconTests {

    // MARK: - Programming Languages

    @Test func swiftUsesSwiftSymbol() {
        let icon = FileIcon.forPath("Sources/main.swift")
        #expect(icon.symbolName == "swift")
        #expect(icon.color == .themeOrange)
    }

    @Test func typescriptUsesTSquare() {
        let icon = FileIcon.forPath("src/index.ts")
        #expect(icon.symbolName == "t.square.fill")
        #expect(icon.color == .themeBlue)

        let tsx = FileIcon.forPath("App.tsx")
        #expect(tsx.symbolName == "t.square.fill")
    }

    @Test func javascriptUsesJSquare() {
        let icon = FileIcon.forPath("index.js")
        #expect(icon.symbolName == "j.square.fill")
        #expect(icon.color == .themeYellow)

        let jsx = FileIcon.forPath("App.jsx")
        #expect(jsx.symbolName == "j.square.fill")
    }

    @Test func pythonUsesPSquare() {
        let icon = FileIcon.forPath("main.py")
        #expect(icon.symbolName == "p.square.fill")
        #expect(icon.color == .themeCyan)
    }

    @Test func goUsesGSquare() {
        let icon = FileIcon.forPath("main.go")
        #expect(icon.symbolName == "g.square.fill")
    }

    @Test func rustUsesRSquare() {
        let icon = FileIcon.forPath("lib.rs")
        #expect(icon.symbolName == "r.square.fill")
        #expect(icon.color == .themeOrange)
    }

    @Test func rubyUsesRSquareRed() {
        let icon = FileIcon.forPath("app.rb")
        #expect(icon.symbolName == "r.square.fill")
        #expect(icon.color == .themeRed)
    }

    @Test func shellUsesTerminal() {
        for ext in ["sh", "bash", "zsh", "fish"] {
            let icon = FileIcon.forPath("script.\(ext)")
            #expect(icon.symbolName == "terminal.fill")
            #expect(icon.color == .themeGreen)
        }
    }

    @Test func cUsesCSquare() {
        let c = FileIcon.forPath("main.c")
        #expect(c.symbolName == "c.square.fill")
        #expect(c.color == .themeCyan)

        let h = FileIcon.forPath("header.h")
        #expect(h.symbolName == "c.square.fill")
    }

    @Test func cppUsesCSquarePurple() {
        let icon = FileIcon.forPath("main.cpp")
        #expect(icon.symbolName == "c.square.fill")
        #expect(icon.color == .themePurple)
    }

    @Test func javaUsesCup() {
        let icon = FileIcon.forPath("Main.java")
        #expect(icon.symbolName == "cup.and.saucer.fill")
    }

    @Test func kotlinUsesKSquare() {
        let icon = FileIcon.forPath("App.kt")
        #expect(icon.symbolName == "k.square.fill")
    }

    @Test func zigUsesZSquare() {
        let icon = FileIcon.forPath("main.zig")
        #expect(icon.symbolName == "z.square.fill")
    }

    // MARK: - Markup / Data

    @Test func htmlUsesChevron() {
        let icon = FileIcon.forPath("index.html")
        #expect(icon.symbolName == "chevron.left.forwardslash.chevron.right")
    }

    @Test func cssUsesPaintbrush() {
        let icon = FileIcon.forPath("style.css")
        #expect(icon.symbolName == "paintbrush.fill")

        let scss = FileIcon.forPath("main.scss")
        #expect(scss.symbolName == "paintbrush.fill")
    }

    @Test func jsonUsesCurlybraces() {
        let icon = FileIcon.forPath("config.json")
        #expect(icon.symbolName == "curlybraces")
        #expect(icon.color == .themeYellow)
    }

    @Test func yamlUsesListBullet() {
        let icon = FileIcon.forPath("config.yaml")
        #expect(icon.symbolName == "list.bullet.rectangle")

        let yml = FileIcon.forPath("ci.yml")
        #expect(yml.symbolName == "list.bullet.rectangle")
    }

    @Test func sqlUsesCylinder() {
        let icon = FileIcon.forPath("schema.sql")
        #expect(icon.symbolName == "cylinder.fill")
    }

    @Test func markdownUsesDocRichtext() {
        let icon = FileIcon.forPath("README.md")
        #expect(icon.symbolName == "doc.richtext")
        #expect(icon.color == .themeBlue)
    }

    // MARK: - Media

    @Test func imageUsesPhoto() {
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "heic"] {
            let icon = FileIcon.forPath("image.\(ext)")
            #expect(icon.symbolName == "photo.fill")
            #expect(icon.color == .themePurple)
        }
    }

    @Test func audioUsesWaveform() {
        for ext in ["mp3", "wav", "m4a", "flac"] {
            let icon = FileIcon.forPath("sound.\(ext)")
            #expect(icon.symbolName == "waveform")
        }
    }

    @Test func videoUsesFilm() {
        let icon = FileIcon.forPath("clip.mp4")
        #expect(icon.symbolName == "film")
    }

    // MARK: - Well-Known Filenames

    @Test func dockerfileUsesShippingbox() {
        let icon = FileIcon.forPath("Dockerfile")
        #expect(icon.symbolName == "shippingbox.fill")
    }

    @Test func makefileUsesHammer() {
        let icon = FileIcon.forPath("Makefile")
        #expect(icon.symbolName == "hammer.fill")
    }

    @Test func packageManifestsUseShippingbox() {
        let paths = [
            "Package.swift", "package.json", "Cargo.toml",
            "go.mod", "Gemfile", "Podfile",
        ]
        for path in paths {
            let icon = FileIcon.forPath(path)
            #expect(icon.symbolName == "shippingbox.fill", "Expected shippingbox for \(path)")
        }
    }

    @Test func lockFilesUseLock() {
        let paths = [
            "package-lock.json", "yarn.lock", "Cargo.lock",
            "go.sum", "Gemfile.lock", "Podfile.lock",
        ]
        for path in paths {
            let icon = FileIcon.forPath(path)
            #expect(icon.symbolName == "lock.fill", "Expected lock for \(path)")
        }
    }

    // MARK: - Dotfiles

    @Test func gitignoreUsesEyeSlash() {
        let icon = FileIcon.forPath(".gitignore")
        #expect(icon.symbolName == "eye.slash")
    }

    @Test func envUsesKey() {
        let icon = FileIcon.forPath(".env")
        #expect(icon.symbolName == "key.fill")
    }

    @Test func editorConfigUsesGear() {
        let icon = FileIcon.forPath(".editorconfig")
        #expect(icon.symbolName == "gearshape.fill")
    }

    // MARK: - Archives / Special

    @Test func archiveUsesZipper() {
        for ext in ["zip", "tar", "gz", "7z"] {
            let icon = FileIcon.forPath("file.\(ext)")
            #expect(icon.symbolName == "doc.zipper", "Expected zipper for .\(ext)")
        }
    }

    @Test func pdfUsesDocRichtext() {
        let icon = FileIcon.forPath("report.pdf")
        #expect(icon.symbolName == "doc.richtext")
        #expect(icon.color == .themeRed)
    }

    @Test func diffUsesPlusSlashMinus() {
        let icon = FileIcon.forPath("changes.diff")
        #expect(icon.symbolName == "plus.forwardslash.minus")
    }

    // MARK: - Fallback

    @Test func unknownExtensionFallsBackToDocText() {
        let icon = FileIcon.forPath("file.xyz")
        #expect(icon.symbolName == "doc.text")
        #expect(icon.color == .themeComment)
    }

    @Test func noExtensionFallsBackToDocText() {
        let icon = FileIcon.forPath("LICENSE")
        #expect(icon.symbolName == "doc.text")
        #expect(icon.color == .themeComment)
    }

    @Test func pathsWorkWithDirectories() {
        let icon = FileIcon.forPath("ios/Oppi/Core/Views/FileIcon.swift")
        #expect(icon.symbolName == "swift")
        #expect(icon.color == .themeOrange)
    }

    // MARK: - Additional Languages

    @Test func luaUsesLSquare() {
        let icon = FileIcon.forPath("init.lua")
        #expect(icon.symbolName == "l.square.fill")
    }

    @Test func dartUsesDSquare() {
        let icon = FileIcon.forPath("main.dart")
        #expect(icon.symbolName == "d.square.fill")
    }

    @Test func configFilesUseGear() {
        let paths = ["tsconfig.json", ".eslintrc.json", ".prettierrc"]
        for path in paths {
            let icon = FileIcon.forPath(path)
            #expect(icon.symbolName == "gearshape.fill", "Expected gear for \(path)")
        }
    }
}
