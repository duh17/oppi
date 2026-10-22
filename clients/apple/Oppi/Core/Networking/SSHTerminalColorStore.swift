import Foundation

/// One 8-bit sRGB color of a terminal theme.
struct SSHTerminalRGB: Codable, Equatable, Sendable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#rrggbb`, `rrggbb`, `#rgb`, or `rgb`. Anything else (Ghostty's X11
    /// color names, `cell-foreground`) is not a color this device reads.
    init?(hex text: String) {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.utf8.allSatisfy(\.isHexDigit), digits.count == 6 || digits.count == 3,
              let value = UInt32(digits, radix: 16) else { return nil }
        if digits.count == 6 {
            self.init(r: UInt8(value >> 16 & 0xFF), g: UInt8(value >> 8 & 0xFF), b: UInt8(value & 0xFF))
        } else {
            self.init(r: UInt8(value >> 8 & 0xF) * 17, g: UInt8(value >> 4 & 0xF) * 17, b: UInt8(value & 0xF) * 17)
        }
    }

    /// Perceived brightness in 0...1, to tell a light terminal from a dark one.
    var luminance: Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255
    }
}

private extension UInt8 {
    var isHexDigit: Bool {
        (0x30 ... 0x39).contains(self) || (0x41 ... 0x46).contains(self) || (0x61 ... 0x66).contains(self)
    }
}

/// The colors a Ghostty theme or config sets. Fonts, size, opacity, and keybinds
/// are never read.
struct SSHTerminalColorTheme: Codable, Equatable, Sendable {
    /// The theme's name when it came from one; nil for colors set in the config alone.
    var name: String?
    /// Entries by palette index, 0 through 255.
    var palette: [UInt8: SSHTerminalRGB] = [:]
    var background: SSHTerminalRGB?
    var foreground: SSHTerminalRGB?
    var cursor: SSHTerminalRGB?
    var cursorText: SSHTerminalRGB?
    var selectionBackground: SSHTerminalRGB?
    var selectionForeground: SSHTerminalRGB?

    var isEmpty: Bool {
        palette.isEmpty && background == nil && foreground == nil && cursor == nil && cursorText == nil
            && selectionBackground == nil && selectionForeground == nil
    }

    /// Whether the terminal is dark: by its background when the theme sets one,
    /// else by `fallback`, the app theme's appearance.
    static func isDark(background: SSHTerminalRGB?, fallback: Bool) -> Bool {
        background.map { $0.luminance < 0.5 } ?? fallback
    }

    /// `other`'s values win; entries it does not set stay.
    func overlaid(by other: Self) -> Self {
        var result = self
        result.palette.merge(other.palette) { _, new in new }
        result.background = other.background ?? background
        result.foreground = other.foreground ?? foreground
        result.cursor = other.cursor ?? cursor
        result.cursorText = other.cursorText ?? cursorText
        result.selectionBackground = other.selectionBackground ?? selectionBackground
        result.selectionForeground = other.selectionForeground ?? selectionForeground
        return result
    }
}

/// Where a host's terminal takes its colors from.
enum SSHTerminalColorChoice: Codable, Equatable, Hashable, Sendable {
    /// The Ghostty theme the host itself uses (its Ghostty config).
    case host
    /// This app's own theme.
    case oppi
    /// One theme, by name, from the host's theme folders.
    case named(String)

    var title: String {
        switch self {
        case .host: "Host’s Ghostty theme"
        case .oppi: "Oppi theme"
        case let .named(name): name
        }
    }
}

/// What the last read of a host's colors found, kept so the next connect paints
/// right away and the host form can say what the host uses.
struct SSHTerminalColorResolution: Codable, Equatable, Sendable {
    let choice: SSHTerminalColorChoice
    /// Nil when the app's own colors apply: the host has no theme to read, or
    /// a named theme is gone.
    let theme: SSHTerminalColorTheme?
    /// A theme the config or the choice names that the host does not have.
    let missing: String?
    /// The appearance this was read for: a `light:`/`dark:` pair resolves to
    /// one side, so a read for the other side is not this one.
    let dark: Bool

    /// What the host form shows next to the row.
    var summary: String {
        switch choice {
        case .oppi: return "Oppi theme"
        case .named(let name): return missing == nil ? name : "\(name) (not found)"
        case .host:
            if let name = theme?.name { return name }
            if missing != nil { return "not found" }
            return theme == nil ? "not found" : "Custom colors"
        }
    }
}

/// Per-host color settings. Kept apart from the saved host, so changing the
/// colors neither ends an open terminal nor asks for a new sign-in.
struct SSHTerminalColorStore {
    static let prefix = "\(AppIdentifiers.subsystem).ssh.terminal.colors"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func choiceKey(_ id: UUID) -> String { "\(prefix).choice.\(id.uuidString)" }
    static func cacheKey(_ id: UUID) -> String { "\(prefix).cache.\(id.uuidString)" }

    func choice(for id: UUID) -> SSHTerminalColorChoice {
        defaults.data(forKey: Self.choiceKey(id)).flatMap { try? JSONDecoder().decode(SSHTerminalColorChoice.self, from: $0) }
            ?? .host
    }

    func setChoice(_ choice: SSHTerminalColorChoice, for id: UUID) {
        if choice == self.choice(for: id) { return }
        if choice == .host {
            defaults.removeObject(forKey: Self.choiceKey(id))
        } else if let data = try? JSONEncoder().encode(choice) {
            defaults.set(data, forKey: Self.choiceKey(id))
        }
    }

    /// The last read for `choice`; a read made for another choice does not
    /// count. The host's own theme is also per appearance when `dark` is given
    /// (`nil` takes the read whichever side it was for, as the host form does).
    func cached(for id: UUID, choice: SSHTerminalColorChoice, dark: Bool? = nil) -> SSHTerminalColorResolution? {
        guard let data = defaults.data(forKey: Self.cacheKey(id)),
              let value = try? JSONDecoder().decode(SSHTerminalColorResolution.self, from: data),
              value.choice == choice else { return nil }
        if choice == .host, let dark, value.dark != dark { return nil }
        return value
    }

    func cache(_ resolution: SSHTerminalColorResolution, for id: UUID) {
        guard cached(for: id, choice: resolution.choice, dark: resolution.dark) != resolution,
              let data = try? JSONEncoder().encode(resolution) else { return }
        defaults.set(data, forKey: Self.cacheKey(id))
    }

    func forget(_ id: UUID) {
        defaults.removeObject(forKey: Self.choiceKey(id))
        defaults.removeObject(forKey: Self.cacheKey(id))
    }
}
