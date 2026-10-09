import Foundation
import SwiftUI

/// Summary returned by `GET /themes`.
struct RemoteThemeSummary: Codable, Sendable, Identifiable {
    let name: String
    let filename: String
    let colorScheme: String

    var id: String { filename }
}

/// Full theme returned by `GET /themes/:name`.
/// 42 color tokens, resolved to `#RRGGBB` hex.
struct RemoteTheme: Codable, Sendable {
    let name: String
    let colorScheme: String?
    let colors: RemoteThemeColors
}

/// Theme color tokens — 49 required, matching ThemePalette, plus 2 optional
/// speaker-chrome tokens (`assistantMessageBg`, `userMessageAccent`).
/// Base colors use their palette names directly (bg, fg, blue, etc.)
/// rather than semantic aliases, so imported themes map without derivation.
struct RemoteThemeColors: Codable, Sendable {
    // ── Base palette (13) ──
    let bg: String
    let bgDark: String
    let bgHighlight: String
    let fg: String
    let fgDim: String
    let comment: String
    let blue: String
    let cyan: String
    let green: String
    let orange: String
    let purple: String
    let red: String
    let yellow: String
    let thinkingText: String

    // ── User / assistant message (2 required, 2 optional) ──
    let userMessageBg: String
    let userMessageText: String
    let assistantMessageBg: String?
    let userMessageAccent: String?

    // ── Tool state (5) ──
    let toolPendingBg: String
    let toolSuccessBg: String
    let toolErrorBg: String
    let toolTitle: String
    let toolOutput: String

    // ── Markdown (10) ──
    let mdHeading: String
    let mdLink: String
    let mdLinkUrl: String
    let mdCode: String
    let mdCodeBlock: String
    let mdCodeBlockBorder: String
    let mdQuote: String
    let mdQuoteBorder: String
    let mdHr: String
    let mdListBullet: String

    // ── Diffs (3) ──
    let toolDiffAdded: String
    let toolDiffRemoved: String
    let toolDiffContext: String

    // ── Syntax (9) ──
    let syntaxComment: String
    let syntaxKeyword: String
    let syntaxFunction: String
    let syntaxVariable: String
    let syntaxString: String
    let syntaxNumber: String
    let syntaxType: String
    let syntaxOperator: String
    let syntaxPunctuation: String

    // ── Thinking levels (6) ──
    let thinkingOff: String
    let thinkingMinimal: String
    let thinkingLow: String
    let thinkingMedium: String
    let thinkingHigh: String
    let thinkingXhigh: String

    init(
        bg: String, bgDark: String, bgHighlight: String,
        fg: String, fgDim: String, comment: String,
        blue: String, cyan: String, green: String,
        orange: String, purple: String, red: String, yellow: String,
        thinkingText: String,
        userMessageBg: String, userMessageText: String,
        assistantMessageBg: String? = nil, userMessageAccent: String? = nil,
        toolPendingBg: String, toolSuccessBg: String, toolErrorBg: String,
        toolTitle: String, toolOutput: String,
        mdHeading: String, mdLink: String, mdLinkUrl: String,
        mdCode: String, mdCodeBlock: String, mdCodeBlockBorder: String,
        mdQuote: String, mdQuoteBorder: String, mdHr: String, mdListBullet: String,
        toolDiffAdded: String, toolDiffRemoved: String, toolDiffContext: String,
        syntaxComment: String, syntaxKeyword: String, syntaxFunction: String,
        syntaxVariable: String, syntaxString: String, syntaxNumber: String,
        syntaxType: String, syntaxOperator: String, syntaxPunctuation: String,
        thinkingOff: String, thinkingMinimal: String, thinkingLow: String,
        thinkingMedium: String, thinkingHigh: String, thinkingXhigh: String
    ) {
        self.bg = bg; self.bgDark = bgDark; self.bgHighlight = bgHighlight
        self.fg = fg; self.fgDim = fgDim; self.comment = comment
        self.blue = blue; self.cyan = cyan; self.green = green
        self.orange = orange; self.purple = purple; self.red = red; self.yellow = yellow
        self.thinkingText = thinkingText
        self.userMessageBg = userMessageBg; self.userMessageText = userMessageText
        self.assistantMessageBg = assistantMessageBg; self.userMessageAccent = userMessageAccent
        self.toolPendingBg = toolPendingBg; self.toolSuccessBg = toolSuccessBg; self.toolErrorBg = toolErrorBg
        self.toolTitle = toolTitle; self.toolOutput = toolOutput
        self.mdHeading = mdHeading; self.mdLink = mdLink; self.mdLinkUrl = mdLinkUrl
        self.mdCode = mdCode; self.mdCodeBlock = mdCodeBlock; self.mdCodeBlockBorder = mdCodeBlockBorder
        self.mdQuote = mdQuote; self.mdQuoteBorder = mdQuoteBorder; self.mdHr = mdHr; self.mdListBullet = mdListBullet
        self.toolDiffAdded = toolDiffAdded; self.toolDiffRemoved = toolDiffRemoved; self.toolDiffContext = toolDiffContext
        self.syntaxComment = syntaxComment; self.syntaxKeyword = syntaxKeyword; self.syntaxFunction = syntaxFunction
        self.syntaxVariable = syntaxVariable; self.syntaxString = syntaxString; self.syntaxNumber = syntaxNumber
        self.syntaxType = syntaxType; self.syntaxOperator = syntaxOperator; self.syntaxPunctuation = syntaxPunctuation
        self.thinkingOff = thinkingOff; self.thinkingMinimal = thinkingMinimal; self.thinkingLow = thinkingLow
        self.thinkingMedium = thinkingMedium; self.thinkingHigh = thinkingHigh; self.thinkingXhigh = thinkingXhigh
    }
}

// MARK: - Conversion

extension RemoteTheme {
    /// Convert to a live `ThemePalette`.
    ///
    /// Direct 1:1 mapping — JSON fields match palette fields exactly.
    func toPalette() -> ThemePalette? {
        let c = colors

        // Base 13 must all parse
        guard
            let bg = Color(hex: c.bg),
            let bgDark = Color(hex: c.bgDark),
            let bgHighlight = Color(hex: c.bgHighlight),
            let fg = Color(hex: c.fg),
            let fgDim = Color(hex: c.fgDim),
            let comment = Color(hex: c.comment),
            let blue = Color(hex: c.blue),
            let cyan = Color(hex: c.cyan),
            let green = Color(hex: c.green),
            let orange = Color(hex: c.orange),
            let purple = Color(hex: c.purple),
            let red = Color(hex: c.red),
            let yellow = Color(hex: c.yellow)
        else { return nil }

        return ThemePalette(
            bg: bg, bgDark: bgDark, bgHighlight: bgHighlight,
            fg: fg, fgDim: fgDim, comment: comment,
            blue: blue, cyan: cyan, green: green,
            orange: orange, purple: purple, red: red, yellow: yellow,
            thinkingText: Color(hex: c.thinkingText) ?? fgDim,

            userMessageBg: Color(hex: c.userMessageBg) ?? bgHighlight,
            userMessageText: Color(hex: c.userMessageText) ?? fg,
            assistantMessageBg: c.assistantMessageBg.flatMap { Color(hex: $0) } ?? .clear,
            // Opt-in: omitted or "" means no strip on the user card.
            userMessageAccent: c.userMessageAccent.flatMap { Color(hex: $0) },

            toolPendingBg: Color(hex: c.toolPendingBg) ?? blue.opacity(0.12),
            toolSuccessBg: Color(hex: c.toolSuccessBg) ?? green.opacity(0.08),
            toolErrorBg: Color(hex: c.toolErrorBg) ?? red.opacity(0.10),
            toolTitle: Color(hex: c.toolTitle) ?? fg,
            toolOutput: Color(hex: c.toolOutput) ?? fgDim,

            mdHeading: Color(hex: c.mdHeading) ?? blue,
            mdLink: Color(hex: c.mdLink) ?? cyan,
            mdLinkUrl: Color(hex: c.mdLinkUrl) ?? comment,
            mdCode: Color(hex: c.mdCode) ?? cyan,
            mdCodeBlock: Color(hex: c.mdCodeBlock) ?? green,
            mdCodeBlockBorder: Color(hex: c.mdCodeBlockBorder) ?? comment,
            mdQuote: Color(hex: c.mdQuote) ?? fgDim,
            mdQuoteBorder: Color(hex: c.mdQuoteBorder) ?? comment,
            mdHr: Color(hex: c.mdHr) ?? comment,
            mdListBullet: Color(hex: c.mdListBullet) ?? orange,

            toolDiffAdded: Color(hex: c.toolDiffAdded) ?? green,
            toolDiffRemoved: Color(hex: c.toolDiffRemoved) ?? red,
            toolDiffContext: Color(hex: c.toolDiffContext) ?? comment,

            syntaxComment: Color(hex: c.syntaxComment) ?? comment,
            syntaxKeyword: Color(hex: c.syntaxKeyword) ?? purple,
            syntaxFunction: Color(hex: c.syntaxFunction) ?? blue,
            syntaxVariable: Color(hex: c.syntaxVariable) ?? fg,
            syntaxString: Color(hex: c.syntaxString) ?? green,
            syntaxNumber: Color(hex: c.syntaxNumber) ?? orange,
            syntaxType: Color(hex: c.syntaxType) ?? cyan,
            syntaxOperator: Color(hex: c.syntaxOperator) ?? fg,
            syntaxPunctuation: Color(hex: c.syntaxPunctuation) ?? fgDim,

            thinkingOff: Color(hex: c.thinkingOff) ?? comment,
            thinkingMinimal: Color(hex: c.thinkingMinimal) ?? fgDim,
            thinkingLow: Color(hex: c.thinkingLow) ?? blue,
            thinkingMedium: Color(hex: c.thinkingMedium) ?? cyan,
            thinkingHigh: Color(hex: c.thinkingHigh) ?? purple,
            thinkingXhigh: Color(hex: c.thinkingXhigh) ?? red
        )
    }
}

// MARK: - Hex Parsing

private extension Color {
    /// Parse `#RRGGBB` hex string. Returns nil for empty string or invalid format.
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !str.isEmpty else { return nil }
        if str.hasPrefix("#") { str.removeFirst() }
        guard str.count == 6, let rgb = UInt32(str, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

// MARK: - Local Persistence

/// Stores imported custom themes in UserDefaults so they survive app restarts.
enum CustomThemeStore {
    private static let storageKey = "\(AppIdentifiers.subsystem).customThemes"
    static let renamedThemes = ["Paper Official": "Paper"]

    /// Save a remote theme locally.
    static func save(_ theme: RemoteTheme) {
        var themes = loadAllRaw()
        themes[theme.name] = theme
        persist(themes)
    }

    /// Load all saved custom themes.
    static func loadAll() -> [String: RemoteTheme] {
        migrateRenamedThemes()
        return loadAllRaw()
    }

    static func migratedThemeID(_ themeID: ThemeID) -> ThemeID {
        guard case .custom(let name) = themeID, let newName = renamedThemes[name] else {
            return themeID
        }
        return .custom(newName)
    }

    private static func loadAllRaw() -> [String: RemoteTheme] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let themes = try? JSONDecoder().decode([String: RemoteTheme].self, from: data)
        else { return [:] }
        return themes
    }

    private static func persist(_ themes: [String: RemoteTheme]) {
        if let data = try? JSONEncoder().encode(themes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    static func migrateRenamedThemes() {
        var themes = loadAllRaw()
        var changed = false
        for (oldName, newName) in renamedThemes {
            guard let theme = themes.removeValue(forKey: oldName) else { continue }
            themes[newName] = RemoteTheme(
                name: newName,
                colorScheme: theme.colorScheme,
                colors: theme.colors
            )
            changed = true
        }
        if changed {
            persist(themes)
        }
    }

    /// Load a specific theme by name.
    static func load(name: String) -> RemoteTheme? {
        loadAll()[name]
    }

    private static let paletteLock = NSLock()
    nonisolated(unsafe) private static var paletteCacheData: Data?
    nonisolated(unsafe) private static var paletteCache: [String: ThemePalette?] = [:]

    /// Resolved palette for a custom theme. Theme-aware paint resolves this on
    /// every render, so it must not decode the stored JSON each time; the memo
    /// is keyed by the stored bytes and drops itself when a theme is saved.
    static func palette(name: String) -> ThemePalette? {
        let stored = UserDefaults.standard.data(forKey: storageKey)
        paletteLock.lock()
        if paletteCacheData == stored, let hit = paletteCache[name] {
            paletteLock.unlock()
            return hit
        }
        paletteLock.unlock()

        // May migrate renamed themes, which rewrites the stored bytes.
        let palette = load(name: name)?.toPalette()
        let current = UserDefaults.standard.data(forKey: storageKey)
        paletteLock.lock()
        if paletteCacheData != current {
            paletteCacheData = current
            paletteCache = [:]
        }
        paletteCache[name] = .some(palette)
        paletteLock.unlock()
        return palette
    }

    /// Delete a custom theme.
    static func delete(name: String) {
        var themes = loadAll()
        themes.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(themes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Get all custom theme names.
    static func names() -> [String] {
        Array(loadAll().keys).sorted()
    }
}
