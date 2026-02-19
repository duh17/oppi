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

/// Theme color tokens — 49 total, matching ThemePalette 1:1.
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

    // ── User message (2) ──
    let userMessageBg: String
    let userMessageText: String

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

    /// Save a remote theme locally.
    static func save(_ theme: RemoteTheme) {
        var themes = loadAll()
        themes[theme.name] = theme
        if let data = try? JSONEncoder().encode(themes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Load all saved custom themes.
    static func loadAll() -> [String: RemoteTheme] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let themes = try? JSONDecoder().decode([String: RemoteTheme].self, from: data)
        else { return [:] }
        return themes
    }

    /// Load a specific theme by name.
    static func load(name: String) -> RemoteTheme? {
        loadAll()[name]
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
