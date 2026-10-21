import Foundation

/// A Ghostty config's `theme` value: one name, or one per appearance.
struct SSHTerminalThemeSelection: Equatable, Sendable {
    let light: String?
    let dark: String?

    /// The name for the appearance. A pair that names one side only serves both.
    func name(dark wantsDark: Bool) -> String? {
        wantsDark ? (dark ?? light) : (light ?? dark)
    }
}

/// Reads the few Ghostty settings that set color, from text a host sent.
/// Everything else in a config is skipped. The input is untrusted and bounded.
enum SSHTerminalGhosttyConfig {
    /// More than a real config or theme holds; the remote command caps its
    /// output below this.
    static let maximumBytes = 256 * 1024
    static let maximumLines = 8192
    static let maximumLineBytes = 2048
    static let maximumNameBytes = 255

    struct Parsed: Equatable, Sendable {
        var theme: SSHTerminalThemeSelection?
        var colors = SSHTerminalColorTheme()
    }

    /// Later lines win, as in Ghostty, so concatenated files parse in order.
    static func parse(_ data: Data) -> Parsed {
        parse(String(decoding: data.prefix(maximumBytes), as: UTF8.self))
    }

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed()
        var lines = 0
        for substring in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            lines += 1
            if lines > maximumLines { break }
            guard substring.utf8.count <= maximumLineBytes else { continue }
            apply(line: substring.trimmingCharacters(in: .whitespaces), to: &parsed)
        }
        return parsed
    }

    /// The name a theme is searched under, or a path. Nil for a name no host
    /// should be asked to open.
    static func isReadableThemeName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maximumNameBytes
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// `theme` first, then explicit config values on top of it.
    static func resolve(config: Parsed, themeFile: Parsed?, themeName: String?) -> SSHTerminalColorTheme {
        var base = themeFile?.colors ?? SSHTerminalColorTheme()
        base.name = themeName
        var merged = base.overlaid(by: config.colors)
        merged.name = themeName
        return merged
    }

    private static func apply(line: String, to parsed: inout Parsed) {
        guard !line.isEmpty, !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = unquoted(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        switch key {
        case "theme": parsed.theme = selection(value)
        case "palette": applyPalette(value, to: &parsed.colors)
        case "background": parsed.colors.background = SSHTerminalRGB(hex: value)
        case "foreground": parsed.colors.foreground = SSHTerminalRGB(hex: value)
        case "cursor-color": parsed.colors.cursor = SSHTerminalRGB(hex: value)
        case "cursor-text": parsed.colors.cursorText = SSHTerminalRGB(hex: value)
        case "selection-background": parsed.colors.selectionBackground = SSHTerminalRGB(hex: value)
        case "selection-foreground": parsed.colors.selectionForeground = SSHTerminalRGB(hex: value)
        default: break
        }
    }

    /// `N=#rrggbb`. An index outside 0...255 or a color that does not read sets nothing.
    private static func applyPalette(_ value: String, to colors: inout SSHTerminalColorTheme) {
        guard let equals = value.firstIndex(of: "="),
              let index = UInt8(value[..<equals].trimmingCharacters(in: .whitespaces)),
              let color = SSHTerminalRGB(hex: unquoted(String(value[value.index(after: equals)...]))) else { return }
        colors.palette[index] = color
    }

    /// `name`, `light:name`, `dark:name`, or `light:a,dark:b`, in either order.
    /// A name that itself holds a comma is read as one name.
    private static func selection(_ value: String) -> SSHTerminalThemeSelection? {
        guard !value.isEmpty else { return nil }
        var light: String?
        var dark: String?
        var rest = Substring(value)
        while let side = pairSide(rest) {
            var name = rest.dropFirst(side.prefix.count)
            rest = ""
            var from = name.startIndex
            while let comma = name[from...].firstIndex(of: ",") {
                let after = name[name.index(after: comma)...]
                if pairSide(after) != nil {
                    rest = after
                    name = name[..<comma]
                    break
                }
                from = name.index(after: comma)
            }
            let text = unquoted(name.trimmingCharacters(in: .whitespaces))
            if side.isDark { dark = text } else { light = text }
        }
        if light != nil || dark != nil {
            return SSHTerminalThemeSelection(light: light.flatMap { $0.isEmpty ? nil : $0 },
                                             dark: dark.flatMap { $0.isEmpty ? nil : $0 })
        }
        return SSHTerminalThemeSelection(light: value, dark: value)
    }

    private static func pairSide(_ text: Substring) -> (prefix: String, isDark: Bool)? {
        let trimmed = text.drop { $0 == " " }
        let skipped = text.count - trimmed.count
        for (prefix, isDark) in [("light:", false), ("dark:", true)] where trimmed.hasPrefix(prefix) {
            return (String(repeating: " ", count: skipped) + prefix, isDark)
        }
        return nil
    }

    /// `"a b"` is `a b`, with `\"` and `\\` inside. Anything else is the text.
    private static func unquoted(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\"") else { return text }
        var result = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        return text
    }
}

/// The side commands that read a host's Ghostty config and themes. Each is one
/// `sh -c` word from `SSHTerminalRemoteShell`: a theme name or path reaches the
/// host only as octal-escaped bytes that the inner `sh` rebuilds, never as shell
/// code. Output is cut on the host as well as bounded when parsed.
enum SSHTerminalGhosttyRemote {
    /// Per file and per command, so a huge or hostile file cannot flood the link.
    static let fileLimit = 65536
    static let outputLimit = 262_144
    static let listLimit = 4096

    /// Where Ghostty looks for a theme by name, in order: the user's folder, the
    /// resources folder Ghostty was started with, then the bundled themes of a
    /// macOS app and of a Linux package.
    private static let themeFolders = [
        #""${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/themes""#,
        #""${GHOSTTY_RESOURCES_DIR:-/nonexistent}/themes""#,
        "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
        #""$HOME/Applications/Ghostty.app/Contents/Resources/ghostty/themes""#,
        "/usr/share/ghostty/themes",
        "/usr/local/share/ghostty/themes",
    ].joined(separator: " ")

    /// Prints the config files Ghostty reads, later ones last, each followed by
    /// the files its `config-file` lines name (one level, `?` optional marker,
    /// relative to the including file). A missing file prints nothing.
    static func configCommand() -> String {
        SSHTerminalRemoteShell.word(#"""
        x="${XDG_CONFIG_HOME:-$HOME/.config}"; m="$HOME/Library/Application Support/com.mitchellh.ghostty"; \#
        { for f in "$x/ghostty/config" "$x/ghostty/config.ghostty" "$m/config" "$m/config.ghostty"; do \#
        [ -f "$f" ] || continue; head -c \#(fileLimit) "$f"; echo; d="${f%/*}"; \#
        sed -n "s/^[[:space:]]*config-file[[:space:]]*=[[:space:]]*//p" "$f" | head -n 8 | while IFS= read -r i; do \#
        i="${i#\?}"; i="${i#\"}"; i="${i%\"}"; \#
        case "$i" in "~/"*) i="$HOME/${i#\~/}";; /*) ;; *) i="$d/$i";; esac; \#
        [ -f "$i" ] && { head -c \#(fileLimit) "$i"; echo; }; done; done; } | head -c \#(outputLimit); exit 0
        """#)
    }

    /// Prints one theme file: a path as given, a name from the first folder that has it.
    /// Exit 3 when there is none.
    static func themeCommand(_ name: String) -> String {
        SSHTerminalRemoteShell.word(
            SSHTerminalRemoteShell.assign("t", name) + #"""
             f=""; case "$t" in /*) f="$t";; ""|.|..|*/*) exit 3;; *) \#
            for d in \#(themeFolders); do [ -f "$d/$t" ] && { f="$d/$t"; break; }; done;; esac; \#
            [ -n "$f" ] && [ -f "$f" ] || exit 3; head -c \#(fileLimit) "$f"
            """#
        )
    }

    /// Prints the names of every theme the user's folder and the bundled folders hold.
    static func listCommand() -> String {
        SSHTerminalRemoteShell.word(#"""
        for d in \#(themeFolders); do [ -d "$d" ] && ls -1 "$d" 2>/dev/null; done \#
        | LC_ALL=C sort -u | head -n \#(listLimit) | head -c \#(outputLimit); exit 0
        """#)
    }

    /// One theme per line; names a host should not be asked to open, and
    /// duplicates, are dropped. Sorted without regard to case.
    static func parseThemeList(_ data: Data) -> [String] {
        var seen = Set<String>()
        var names = [String]()
        let text = String(decoding: data.prefix(SSHTerminalGhosttyConfig.maximumBytes), as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline).prefix(listLimit) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard SSHTerminalGhosttyConfig.isReadableThemeName(name), !name.contains("/"),
                  !name.hasPrefix("."), seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
