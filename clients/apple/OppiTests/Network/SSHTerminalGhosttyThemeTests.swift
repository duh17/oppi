import Foundation
import Testing
@testable import Oppi

/// Reading a host's Ghostty colors: the parser, the commands that fetch the
/// files, and how a theme file and the config's own values combine.
@Suite("SSH terminal Ghostty theme")
struct SSHTerminalGhosttyThemeTests {
    private func rgb(_ hex: String) -> SSHTerminalRGB { SSHTerminalRGB(hex: hex)! }

    // MARK: - Parser

    @Test func readsTheColorKeysAndNothingElse() {
        let parsed = SSHTerminalGhosttyConfig.parse("""
        # a comment
        font-family = "Fira Code"
        font-size = 17
        background-opacity = 0.80
        keybind = shift+enter=text:\\x1b\\r
        background = #1a1b26
        foreground = c0caf5
        cursor-color = #fff
        cursor-text = #15161e
        selection-background = #33467c
        selection-foreground = #c0caf5
        palette = 1=#f7768e
        palette = 15 = #c0caf5
        """)
        #expect(parsed.colors.background == rgb("#1a1b26"))
        #expect(parsed.colors.foreground == rgb("#c0caf5"))
        #expect(parsed.colors.cursor == SSHTerminalRGB(r: 255, g: 255, b: 255))
        #expect(parsed.colors.cursorText == rgb("#15161e"))
        #expect(parsed.colors.selectionBackground == rgb("#33467c"))
        #expect(parsed.colors.selectionForeground == rgb("#c0caf5"))
        #expect(parsed.colors.palette == [1: rgb("#f7768e"), 15: rgb("#c0caf5")])
        #expect(parsed.theme == nil)
    }

    @Test func laterLinesWinAndACommentDoesNotCount() {
        let parsed = SSHTerminalGhosttyConfig.parse("""
        background = #111111
        #background = #222222
        background = #333333
        palette = 4=#444444
        palette = 4=#555555
        """)
        #expect(parsed.colors.background == rgb("#333333"))
        #expect(parsed.colors.palette == [4: rgb("#555555")])
    }

    @Test func aQuotedValueLosesItsQuotes() {
        let parsed = SSHTerminalGhosttyConfig.parse("""
        theme = "Catppuccin Mocha"
        background = "#101010"
        palette = "2=#00ff00"
        """)
        #expect(parsed.theme == SSHTerminalThemeSelection(light: "Catppuccin Mocha", dark: "Catppuccin Mocha"))
        #expect(parsed.colors.background == rgb("#101010"))
        #expect(parsed.colors.palette == [2: rgb("#00ff00")])
    }

    @Test func aThemeNamesOneThemeOrOnePerAppearance() {
        func selection(_ value: String) -> SSHTerminalThemeSelection? {
            SSHTerminalGhosttyConfig.parse("theme = \(value)").theme
        }
        #expect(selection("tokyonight") == .init(light: "tokyonight", dark: "tokyonight"))
        #expect(selection("/Users/me/themes/mine") == .init(light: "/Users/me/themes/mine", dark: "/Users/me/themes/mine"))
        #expect(selection("light:Rose Pine Dawn,dark:Rose Pine") == .init(light: "Rose Pine Dawn", dark: "Rose Pine"))
        #expect(selection("dark:Rose Pine, light:Rose Pine Dawn") == .init(light: "Rose Pine Dawn", dark: "Rose Pine"))
        #expect(selection("light:Foo, Bar,dark:Baz") == .init(light: "Foo, Bar", dark: "Baz"))
        #expect(selection("dark:Only Dark") == .init(light: nil, dark: "Only Dark"))
        #expect(selection("") == nil)
        let pair = SSHTerminalThemeSelection(light: "Day", dark: "Night")
        #expect(pair.name(dark: true) == "Night")
        #expect(pair.name(dark: false) == "Day")
        #expect(SSHTerminalThemeSelection(light: nil, dark: "Night").name(dark: false) == "Night")
    }

    @Test func aThemeFileYieldsToTheConfigsExplicitValues() {
        let config = SSHTerminalGhosttyConfig.parse("""
        theme = tokyonight
        background = #000000
        palette = 1=#ff0000
        """)
        let file = SSHTerminalGhosttyConfig.parse("""
        palette = 0=#15161e
        palette = 1=#f7768e
        background = #1a1b26
        foreground = #c0caf5
        selection-background = #33467c
        """)
        let theme = SSHTerminalGhosttyConfig.resolve(config: config, themeFile: file, themeName: "tokyonight")
        #expect(theme.name == "tokyonight")
        #expect(theme.background == rgb("#000000"), "the config's own value beats the theme's")
        #expect(theme.foreground == rgb("#c0caf5"), "what the config leaves unset comes from the theme")
        #expect(theme.selectionBackground == rgb("#33467c"))
        #expect(theme.palette == [0: rgb("#15161e"), 1: rgb("#ff0000")], "per index: the config wins entry by entry")
    }

    @Test func colorsThatDoNotReadSetNothing() {
        let parsed = SSHTerminalGhosttyConfig.parse("""
        background = red
        foreground = #12345
        cursor-color = cell-foreground
        selection-background = #gggggg
        palette = 256=#ffffff
        palette = -1=#ffffff
        palette = x=#ffffff
        palette = 3
        palette = 3=
        no equals sign here
        = no key
        """)
        #expect(parsed.colors.isEmpty)
    }

    @Test func garbageInputStaysBounded() {
        // Far past the byte cap: only the first part is read.
        let early = "background = #010203\n"
        let late = "foreground = #040506\n"
        let filler = String(repeating: "# padding line that goes on and on\n", count: 20_000)
        let big = SSHTerminalGhosttyConfig.parse(Data((early + filler + late).utf8))
        #expect(big.colors.background == rgb("#010203"))
        #expect(big.colors.foreground == nil, "bytes past the cap are never read")

        // More lines than the line cap.
        let many = SSHTerminalGhosttyConfig.parse(String(repeating: "x\n", count: 20_000) + "background = #070809\n")
        #expect(many.colors.background == nil)

        // One enormous line is skipped without taking the rest down with it.
        let huge = "background = #" + String(repeating: "a", count: 100_000) + "\nforeground = #0a0b0c\n"
        #expect(SSHTerminalGhosttyConfig.parse(huge).colors.foreground == rgb("#0a0b0c"))
        #expect(SSHTerminalGhosttyConfig.parse(huge).colors.background == nil)

        // Bytes that are not UTF-8, NULs, and a lone surrogate-looking mess.
        let junk = Data([0xFF, 0xFE, 0x00, 0x00, 0xC3, 0x28, 0x0A]) + Data("palette = 9=#090909\n".utf8)
        #expect(SSHTerminalGhosttyConfig.parse(junk).colors.palette == [9: rgb("#090909")])
        #expect(SSHTerminalGhosttyConfig.parse(Data()).colors.isEmpty)
    }

    @Test func aThemeNameIsAskedOfTheHostOnlyWhenItIsReadable() {
        #expect(SSHTerminalGhosttyConfig.isReadableThemeName("Catppuccin Mocha"))
        #expect(!SSHTerminalGhosttyConfig.isReadableThemeName(""))
        #expect(!SSHTerminalGhosttyConfig.isReadableThemeName("a\u{0}b"))
        #expect(!SSHTerminalGhosttyConfig.isReadableThemeName("line\nbreak"))
        #expect(!SSHTerminalGhosttyConfig.isReadableThemeName(String(repeating: "x", count: 256)))
    }

    @Test func aLightBackgroundIsNotDark() {
        #expect(SSHTerminalColorTheme.isDark(background: rgb("#1a1b26"), fallback: false))
        #expect(!SSHTerminalColorTheme.isDark(background: rgb("#fdf6e3"), fallback: true))
        #expect(SSHTerminalColorTheme.isDark(background: nil, fallback: true))
    }

    // MARK: - Commands

    /// What fish reads specially inside single quotes. A word without any of
    /// these cannot be closed early, so a value in it is never shell code.
    private func assertSafeWord(_ command: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(command.hasPrefix("sh -c '"), sourceLocation: sourceLocation)
        #expect(command.hasSuffix("'"), sourceLocation: sourceLocation)
        let word = String(command.dropFirst("sh -c '".count).dropLast())
        #expect(!word.contains("'"), sourceLocation: sourceLocation)
        #expect(!word.contains("\\'"), sourceLocation: sourceLocation)
        #expect(!word.contains("\\\\"), sourceLocation: sourceLocation)
    }

    @Test func everyCommandIsOneQuoteFreeWord() {
        assertSafeWord(SSHTerminalGhosttyRemote.configCommand())
        assertSafeWord(SSHTerminalGhosttyRemote.listCommand())
        let hostile = [
            "tokyonight", "Catppuccin Mocha", "/Users/me/themes/mine",
            "x';touch /tmp/PWN;#", "quote'inside", "back\\slash", "double\\\\backslash",
            "dollar$(touch /tmp/PWN)", "backtick`touch /tmp/PWN`", "semi;touch /tmp/PWN;#",
            "and&&touch /tmp/PWN", "line\nbreak", "dquote\"inside", "日本語テーマ", "trailing ",
        ]
        for name in hostile {
            let command = SSHTerminalGhosttyRemote.themeCommand(name)
            assertSafeWord(command)
            // The name travels only as octal escapes: no byte of it appears raw.
            #expect(command.contains(SSHTerminalRemoteShell.octalEncoded(name)))
            if name.contains(where: { !$0.isLetter && !$0.isNumber }) {
                #expect(!command.contains(name), "\(name) must not appear in the command as written")
            }
        }
    }

    @Test func aThemeListHasNamesOnly() {
        let list = Data("""
        tokyonight
        Catppuccin Mocha
        0x96f
        tokyonight
        .hidden
        has/slash

        \u{1b}[31mescape
        zeta
        Alpha
        """.utf8)
        #expect(SSHTerminalGhosttyRemote.parseThemeList(list) == ["0x96f", "Alpha", "Catppuccin Mocha", "tokyonight", "zeta"])
        let flood = Data((0 ..< 10_000).map { "theme-\($0)\n" }.joined().utf8)
        #expect(SSHTerminalGhosttyRemote.parseThemeList(flood).count <= SSHTerminalGhosttyRemote.listLimit)
    }

    // MARK: - Loader

    private struct Host {
        var config: String?
        var themes: [String: String] = [:]
        var failing = false
        private(set) var commands = [String]()

        mutating func answer(_ command: String) throws -> SSHExecResult {
            commands.append(command)
            if failing { throw SSHConnectionError.notConnected }
            if command == SSHTerminalGhosttyRemote.configCommand() {
                return SSHExecResult(output: Data((config ?? "").utf8), errorOutput: Data(), exitStatus: 0)
            }
            for (name, body) in themes where command == SSHTerminalGhosttyRemote.themeCommand(name) {
                return SSHExecResult(output: Data(body.utf8), errorOutput: Data(), exitStatus: 0)
            }
            return SSHExecResult(output: Data(), errorOutput: Data(), exitStatus: 3)
        }
    }

    private final class Box: @unchecked Sendable {
        var host: Host
        init(_ host: Host) { self.host = host }
    }

    @MainActor private func read(_ choice: SSHTerminalColorChoice, dark: Bool = true, host: Host) async -> (SSHTerminalColorResolution?, [String]) {
        let box = Box(host)
        let result = await SSHTerminalColorLoader.read(choice: choice, dark: dark) { try box.host.answer($0) }
        return (result, box.host.commands)
    }

    @Test @MainActor func theHostsThemeAndConfigOverridesCombine() async {
        let host = Host(
            config: "theme = tokyonight\nbackground = #000000\nfont-size = 14\n",
            themes: ["tokyonight": "background = #1a1b26\nforeground = #c0caf5\npalette = 4=#7aa2f7\n"]
        )
        let (result, commands) = await read(.host, host: host)
        #expect(result?.summary == "tokyonight")
        #expect(result?.theme?.background == rgb("#000000"))
        #expect(result?.theme?.foreground == rgb("#c0caf5"))
        #expect(result?.theme?.palette == [4: rgb("#7aa2f7")])
        #expect(commands.count == 2)
    }

    @Test @MainActor func aPairOfThemesFollowsTheAppearance() async {
        let host = Host(
            config: "theme = light:day,dark:night\n",
            themes: ["day": "background = #ffffff\n", "night": "background = #000000\n"]
        )
        #expect(await read(.host, dark: true, host: host).0?.theme?.background == rgb("#000000"))
        #expect(await read(.host, dark: false, host: host).0?.theme?.background == rgb("#ffffff"))
    }

    @Test @MainActor func aThemeTheHostLacksIsNotFound() async {
        let missing = await read(.host, host: Host(config: "theme = nowhere\n")).0
        #expect(missing?.theme == nil)
        #expect(missing?.missing == "nowhere")
        #expect(missing?.summary == "not found")

        let missingWithColors = await read(.host, host: Host(config: "theme = nowhere\nbackground = #123456\n")).0
        #expect(missingWithColors?.theme?.background == rgb("#123456"), "explicit colors still apply")
        #expect(missingWithColors?.summary == "not found")

        let none = await read(.host, host: Host(config: nil)).0
        #expect(none?.theme == nil)
        #expect(none?.summary == "not found")
    }

    @Test @MainActor func aConfigWithColorsAndNoThemeStillPaints() async {
        let result = await read(.host, host: Host(config: "background = #123456\npalette = 1=#ff0000\n")).0
        #expect(result?.theme?.background == rgb("#123456"))
        #expect(result?.theme?.name == nil)
        #expect(result?.summary == "Custom colors")
    }

    @Test @MainActor func aNamedThemeIgnoresTheHostsConfig() async {
        let host = Host(config: "theme = tokyonight\n", themes: ["gruvbox": "background = #282828\n"])
        let (result, commands) = await read(.named("gruvbox"), host: host)
        #expect(result?.theme?.background == rgb("#282828"))
        #expect(result?.summary == "gruvbox")
        #expect(commands == [SSHTerminalGhosttyRemote.themeCommand("gruvbox")])
        #expect(await read(.named("gone"), host: host).0?.summary == "gone (not found)")
        #expect(await read(.oppi, host: host).0?.theme == nil)
    }

    @Test @MainActor func aBrokenConnectionLearnsNothing() async {
        var host = Host(config: "theme = x\n")
        host.failing = true
        #expect(await read(.host, host: host).0 == nil)
        #expect(await read(.named("x"), host: host).0 == nil)
    }

    // MARK: - Store

    @Test @MainActor func aCachedReadPaintsTheNextConnectAndFollowsTheChoice() async {
        let suite = "SSHTerminalGhosttyThemeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SSHTerminalColorStore(defaults: defaults)
        let id = UUID()
        #expect(store.choice(for: id) == .host)

        let loader = SSHTerminalColorLoader(profileID: id, choice: .host, store: store)
        #expect(loader.theme == nil, "nothing is known before the first read")
        let host = Host(config: "theme = tokyonight\n", themes: ["tokyonight": "background = #1a1b26\n"])
        let box = Box(host)
        await loader.load(choice: .host, dark: true) { try box.host.answer($0) }
        #expect(loader.theme?.background == rgb("#1a1b26"))

        // A new terminal of the same host starts from that read, before any command.
        let next = SSHTerminalColorLoader(profileID: id, choice: .host, store: store)
        #expect(next.theme?.background == rgb("#1a1b26"))
        #expect(store.cached(for: id, choice: .host)?.summary == "tokyonight")

        // A different choice never borrows the other choice's read.
        store.setChoice(.named("gruvbox"), for: id)
        #expect(store.choice(for: id) == .named("gruvbox"))
        #expect(store.cached(for: id, choice: .named("gruvbox")) == nil)
        #expect(SSHTerminalColorLoader(profileID: id, choice: .oppi, store: store).theme == nil)

        // A failed read leaves the colors as they were.
        var failing = Host(config: nil)
        failing.failing = true
        let failBox = Box(failing)
        await next.load(choice: .host, dark: true) { try failBox.host.answer($0) }
        #expect(next.theme?.background == rgb("#1a1b26"))

        store.setChoice(.host, for: id)
        store.forget(id)
        #expect(store.cached(for: id, choice: .host) == nil)
    }
}
