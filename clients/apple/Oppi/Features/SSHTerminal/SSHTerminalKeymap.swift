import Foundation
import GhosttyVt
import Observation

/// One key press, ready for the terminal encoder.
struct SSHTerminalKeyStroke: Equatable, Sendable {
    let key: GhosttyKey
    /// The character the key types without modifiers ("" for named keys).
    let text: String
    let modifiers: GhosttyMods
    let label: String
}

/// A named action of the program in front, sent as that program binds it now.
struct SSHTerminalKeyAction: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// More than one stroke is a chord (Claude Code's `ctrl+x ctrl+e`).
    let strokes: [SSHTerminalKeyStroke]
    var keyLabel: String { strokes.map(\.label).joined(separator: " ") }
}

/// Per-program key strip actions: each program's documented defaults, then
/// the user's own keybinding file from the host. The chat bar uses
/// `composerPages`; the raw keyboard still shows `fixed`. A program without
/// a profile still gets the default agent keys, arrows, and exit chords.
/// To support another program, add a profile; to read its overrides, add a
/// `Config` case.
///
/// Defaults come from each program's own reference: pi `docs/keybindings.md`,
/// Claude Code https://code.claude.com/docs/en/keybindings, and Codex
/// `codex-rs/tui/src/keymap.rs` (`built_in_defaults`).
enum SSHTerminalKeymap {
    enum Syntax: Sendable {
        /// pi and Claude Code: `ctrl+shift+p`; Claude chords split on spaces.
        case plus
        /// Codex: `ctrl-t`, `page-down`, `alt-.`.
        case dash
    }

    enum Config: Sendable {
        /// `{ "app.model.select": "ctrl+k" | [...] | [] }` replaces defaults.
        case piJSON
        /// `{ "bindings": [{ "context", "bindings": { key: action | null } }] }`
        /// adds keys; a key bound elsewhere or to null leaves its default action.
        case claudeJSON(contexts: Set<String>)
        /// `[tui.keymap.<context>] <action> = "key" | [...] | []` replaces defaults.
        case codexTOML
    }

    struct ActionSpec: Sendable {
        /// The program's own action id, as its keybinding file names it.
        let id: String
        let title: String
        let defaults: [String]
    }

    struct Profile: Sendable {
        let syntax: Syntax
        let config: Config?
        /// Sent on stdin to `sh -s`; prints the user's keybinding file, or fails.
        let readScript: String?
        let actions: [ActionSpec]
    }

    /// Program name as the foreground probe or Herdr reports it.
    static func profile(for program: String) -> Profile? {
        switch program {
        case "shell":
            Profile(syntax: .plus, config: nil, readScript: nil, actions: [
                .init(id: "history", title: "History", defaults: ["ctrl+r"]),
                .init(id: "clear", title: "Clear", defaults: ["ctrl+l"]),
            ])
        case "pi":
            Profile(syntax: .plus, config: .piJSON,
                    readScript: #"cat "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/keybindings.json""#,
                    actions: [
                        .init(id: "app.interrupt", title: "Stop", defaults: ["escape"]),
                        .init(id: "app.thinking.cycle", title: "Thinking", defaults: ["shift+tab"]),
                        .init(id: "app.model.select", title: "Model", defaults: ["ctrl+l"]),
                        .init(id: "app.tools.expand", title: "Tools", defaults: ["ctrl+o"]),
                    ])
        case "claude":
            Profile(syntax: .plus, config: .claudeJSON(contexts: ["Global", "Chat", "Task"]),
                    readScript: #"cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/keybindings.json""#,
                    actions: [
                        .init(id: "chat:cancel", title: "Cancel", defaults: ["escape"]),
                        .init(id: "chat:cycleMode", title: "Mode", defaults: ["shift+tab"]),
                        .init(id: "chat:modelPicker", title: "Model", defaults: ["meta+p"]),
                        .init(id: "app:toggleTranscript", title: "Transcript", defaults: ["ctrl+o"]),
                        .init(id: "app:toggleTodos", title: "Todos", defaults: ["ctrl+t"]),
                        .init(id: "task:background", title: "Background", defaults: ["ctrl+b", "ctrl+x ctrl+b"]),
                    ])
        case "codex":
            // Only the `tui` tables leave the host; the rest of config.toml can hold secrets.
            Profile(syntax: .dash, config: .codexTOML,
                    readScript: #"awk '/^[ \t]*\[/ { keep = ($0 ~ /^[ \t]*\[[ \t]*tui[ \t]*(\]|\.)/) } keep || /^[ \t]*tui\./' "${CODEX_HOME:-$HOME/.codex}/config.toml""#,
                    actions: [
                        .init(id: "chat.interrupt_turn", title: "Stop", defaults: ["esc"]),
                        .init(id: "global.open_transcript", title: "Transcript", defaults: ["ctrl-t"]),
                        .init(id: "chat.decrease_reasoning_effort", title: "Effort \u{2212}", defaults: ["alt-,", "shift-down"]),
                        .init(id: "chat.increase_reasoning_effort", title: "Effort +", defaults: ["alt-.", "shift-up"]),
                    ])
        default: nil
        }
    }

    /// Raw-keyboard keys. Actions bound to exactly one of these are left out
    /// of the program list rather than shown twice. The chat bar does not
    /// show the Control and Alt latches; see `composerPages`.
    struct FixedKey: Identifiable {
        let id: String
        let label: String
        var stroke: SSHTerminalKeyStroke? = nil
        var modifier: GhosttyMods? = nil
    }

    static let fixed: [FixedKey] = [
        .init(id: "escape", label: "Esc", stroke: stroke(GHOSTTY_KEY_ESCAPE, label: "Esc")),
        .init(id: "control", label: "Ctrl", modifier: GhosttyMods(GHOSTTY_MODS_CTRL)),
        .init(id: "alt", label: "Alt", modifier: GhosttyMods(GHOSTTY_MODS_ALT)),
        .init(id: "tab", label: "Tab", stroke: stroke(GHOSTTY_KEY_TAB, label: "Tab")),
        .init(id: "left", label: "←", stroke: stroke(GHOSTTY_KEY_ARROW_LEFT, label: "←")),
        .init(id: "down", label: "↓", stroke: stroke(GHOSTTY_KEY_ARROW_DOWN, label: "↓")),
        .init(id: "up", label: "↑", stroke: stroke(GHOSTTY_KEY_ARROW_UP, label: "↑")),
        .init(id: "right", label: "→", stroke: stroke(GHOSTTY_KEY_ARROW_RIGHT, label: "→")),
    ]

    /// One chat-bar page. Exit is last so a miss on the open page cannot
    /// interrupt or close the program.
    struct ComposerPage: Equatable, Identifiable, Sendable {
        enum ID: String, Equatable, Sendable {
            case agent, move, exit
        }

        let id: ID
        var title: String {
            switch id {
            case .agent: "Agent"
            case .move: "Move"
            case .exit: "Exit"
            }
        }
        let items: [ComposerKey]
    }

    /// A key on a chat-bar page. `send` writes its strokes immediately.
    /// Arrows keep the hold-and-drag control. Neither kind arms a latch.
    struct ComposerKey: Equatable, Identifiable, Sendable {
        enum Kind: Equatable, Sendable {
            case send, arrow
        }

        let id: String
        let label: String
        let strokes: [SSHTerminalKeyStroke]
        let kind: Kind
        let accessibilityLabel: String
        var hint: String { strokes.map(\.label).joined(separator: " ") }
    }

    /// Page 1 is Thinking, Cycle, and Model, then any other program actions
    /// that are not themselves exit chords. Page 2 is the arrows. Page 3 is
    /// Esc, Tab, Ctrl+C, and Ctrl+D, sent as those keys rather than latches.
    /// A slot whose own binding is an exit chord is omitted. It is not given
    /// a different key under the same label. Shift+Tab is not an exit chord.
    static func composerPages(for profile: Profile?, userFile: String?) -> [ComposerPage] {
        let overrides = userFile.flatMap { file in profile?.config.flatMap { overrides(config: $0, file: file) } } ?? .none
        var specs = profile?.actions ?? []
        func contains(_ spec: ActionSpec, _ needle: String) -> Bool {
            spec.id.range(of: needle, options: .caseInsensitive) != nil
        }
        func take(_ matches: (ActionSpec) -> Bool) -> ActionSpec? {
            guard let index = specs.firstIndex(where: matches) else { return nil }
            return specs.remove(at: index)
        }
        func slot(_ spec: ActionSpec?, id: String, title: String, fallbackSpec: String) -> ComposerKey? {
            guard let profile, let spec else {
                return pageOneSlot(fallback(id, title, fallbackSpec), id: id, title: title)
            }
            // Present in the profile, including a binding actions() drops because
            // it matches Esc or Tab. An exit chord omits the slot. No substitute.
            let strokes = resolvedStrokes(spec, profile: profile, overrides: overrides) ?? []
            guard !strokes.isEmpty, !isExitChord(strokes) else { return nil }
            return slotted(SSHTerminalKeyAction(id: id, title: title, strokes: strokes), id: id, title: title)
        }
        let thinking = take { contains($0, "thinking") }
        // Claim Model before Cycle. "mode" is a prefix of "model".
        let model = take { contains($0, "model") }
        let cycle = take { contains($0, "cycle") || contains($0, "mode") }
        let claimed = Set([thinking?.id, cycle?.id, model?.id].compactMap { $0 })
        let extras = (profile.map { actions(for: $0, userFile: userFile) } ?? [])
            .filter { !isExitChord($0.strokes) && !claimed.contains($0.id) }
        let agent = [
            slot(thinking, id: "thinking", title: "Thinking", fallbackSpec: "shift+tab"),
            slot(cycle, id: "cycle", title: "Cycle", fallbackSpec: "shift+tab"),
            slot(model, id: "model", title: "Model", fallbackSpec: "ctrl+l"),
        ].compactMap { $0 } + extras.map { slotted($0, id: $0.id, title: $0.title) }
        let arrows = fixed.compactMap { key -> ComposerKey? in
            guard let stroke = key.stroke, SSHTerminalArrowRepeat.isArrow(stroke.key) else { return nil }
            return ComposerKey(id: key.id, label: key.label, strokes: [stroke], kind: .arrow,
                               accessibilityLabel: key.label)
        }
        let exit = [
            immediate("escape", "Esc", "escape", "Escape"),
            immediate("tab", "Tab", "tab", "Tab"),
            immediate("ctrl-c", "^C", "ctrl+c", "Control C"),
            immediate("ctrl-d", "^D", "ctrl+d", "Control D"),
        ]
        return [
            ComposerPage(id: .agent, items: agent),
            ComposerPage(id: .move, items: arrows),
            ComposerPage(id: .exit, items: exit),
        ]
    }

    private static func pageOneSlot(_ action: SSHTerminalKeyAction, id: String, title: String) -> ComposerKey? {
        guard !action.strokes.isEmpty, !isExitChord(action.strokes) else { return nil }
        return slotted(action, id: id, title: title)
    }

    private static func slotted(_ action: SSHTerminalKeyAction, id: String, title: String) -> ComposerKey {
        ComposerKey(id: id, label: title, strokes: action.strokes, kind: .send, accessibilityLabel: title)
    }

    private static func fallback(_ id: String, _ title: String, _ spec: String) -> SSHTerminalKeyAction {
        SSHTerminalKeyAction(id: id, title: title, strokes: parse(spec, syntax: .plus) ?? [])
    }

    private static func immediate(_ id: String, _ label: String, _ spec: String, _ accessibilityLabel: String) -> ComposerKey {
        ComposerKey(id: id, label: label, strokes: parse(spec, syntax: .plus) ?? [], kind: .send,
                    accessibilityLabel: accessibilityLabel)
    }

    /// A single unmodified Esc or Tab, or Ctrl+C / Ctrl+D. Shift+Tab is the
    /// thinking and mode cycle, not an exit chord.
    private static func isExitChord(_ strokes: [SSHTerminalKeyStroke]) -> Bool {
        guard strokes.count == 1, let stroke = strokes.first else { return false }
        if stroke.modifiers == 0, stroke.key == GHOSTTY_KEY_ESCAPE || stroke.key == GHOSTTY_KEY_TAB { return true }
        return matches(stroke, "ctrl+c") || matches(stroke, "ctrl+d")
    }

    private static func matches(_ stroke: SSHTerminalKeyStroke, _ spec: String) -> Bool {
        guard let expected = parse(spec, syntax: .plus)?.first else { return false }
        return stroke.key == expected.key && stroke.modifiers == expected.modifiers
    }

    /// Resolves a profile against the user's file. Unreadable or invalid
    /// files mean defaults, as the programs themselves fall back.
    static func actions(for profile: Profile, userFile: String?) -> [SSHTerminalKeyAction] {
        let overrides = userFile.flatMap { file in profile.config.flatMap { overrides(config: $0, file: file) } } ?? .none
        return profile.actions.compactMap { spec in
            guard let strokes = resolvedStrokes(spec, profile: profile, overrides: overrides) else { return nil }
            if strokes.count == 1, fixed.contains(where: { $0.stroke?.key == strokes[0].key && $0.stroke?.modifiers == strokes[0].modifiers }) { return nil }
            return SSHTerminalKeyAction(id: spec.id, title: spec.title, strokes: strokes)
        }
    }

    /// The binding the program would send, including one that matches a fixed
    /// key. `actions(for:)` drops those so the raw strip does not show them twice.
    private static func resolvedStrokes(_ spec: ActionSpec, profile: Profile, overrides: Overrides) -> [SSHTerminalKeyStroke]? {
        let keys: [String] = switch overrides {
        case .none: spec.defaults
        case .replace(let map): map[spec.id] ?? spec.defaults
        case .claude(let byKey):
            spec.defaults.filter { byKey[normalized($0)] == nil }
                + byKey.filter { $0.value == spec.id }.keys.sorted()
        }
        return keys.lazy.compactMap({ parse($0, syntax: profile.syntax) }).first
    }

    enum Overrides: Equatable {
        case none
        /// Action id → keys; an empty list unbinds.
        case replace([String: [String]])
        /// Normalized key → action id, or "" when the key was unbound.
        case claude([String: String])
    }

    static func overrides(config: Config, file: String) -> Overrides? {
        switch config {
        case .piJSON:
            guard let object = try? JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any] else { return nil }
            return .replace(object.compactMapValues { value in
                if let key = value as? String { return [key] }
                return value as? [String]
            })
        case .claudeJSON(let contexts):
            guard let object = try? JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any],
                  let blocks = object["bindings"] as? [[String: Any]] else { return nil }
            var byKey = [String: String]()
            for block in blocks {
                guard let context = block["context"] as? String, contexts.contains(context),
                      let bindings = block["bindings"] as? [String: Any] else { continue }
                for (key, action) in bindings { byKey[normalized(key)] = action as? String ?? "" }
            }
            return .claude(byKey)
        case .codexTOML:
            return .replace(codexKeymap(fromTOML: file))
        }
    }

    // MARK: - Key specs

    static func parse(_ spec: String, syntax: Syntax) -> [SSHTerminalKeyStroke]? {
        let strokes = syntax == .plus ? spec.split(separator: " ").map(String.init) : [spec]
        let parsed = strokes.compactMap { parseStroke($0.lowercased(), separator: syntax == .plus ? "+" : "-") }
        return parsed.count == strokes.count && !parsed.isEmpty ? parsed : nil
    }

    private static func parseStroke(_ spec: String, separator: Character) -> SSHTerminalKeyStroke? {
        var rest = Substring(spec)
        var mods: GhosttyMods = 0
        var prefix = ""
        // Peel known modifier words; what remains is the key, which may itself
        // be the separator character (`ctrl+-`, `ctrl--`).
        while let dash = rest.dropFirst().firstIndex(of: separator),
              let modifier = modifiers[String(rest[..<dash])] {
            rest = rest[rest.index(after: dash)...]
            mods |= modifier.mods
            prefix += modifier.label
        }
        guard let (key, text, name) = namedKey(String(rest)) else { return nil }
        return stroke(key, text: text, modifiers: mods, label: prefix + name)
    }

    private static let modifiers: [String: (mods: GhosttyMods, label: String)] = [
        "ctrl": (GhosttyMods(GHOSTTY_MODS_CTRL), "^"), "control": (GhosttyMods(GHOSTTY_MODS_CTRL), "^"),
        "alt": (GhosttyMods(GHOSTTY_MODS_ALT), "\u{2325}"), "opt": (GhosttyMods(GHOSTTY_MODS_ALT), "\u{2325}"),
        "option": (GhosttyMods(GHOSTTY_MODS_ALT), "\u{2325}"), "meta": (GhosttyMods(GHOSTTY_MODS_ALT), "\u{2325}"),
        "shift": (GhosttyMods(GHOSTTY_MODS_SHIFT), "\u{21E7}"),
    ]

    /// Key names from the three formats; super/cmd and shifted symbols are
    /// left out because a phone terminal cannot send them reliably.
    private static func namedKey(_ name: String) -> (GhosttyKey, String, String)? {
        if name.count == 1, let scalar = name.unicodeScalars.first {
            if (97...122).contains(scalar.value) {
                return (GhosttyKey(rawValue: GHOSTTY_KEY_A.rawValue + Int32(scalar.value) - 97), name, name.uppercased())
            }
            if (48...57).contains(scalar.value) {
                return (GhosttyKey(rawValue: GHOSTTY_KEY_DIGIT_0.rawValue + Int32(scalar.value) - 48), name, name)
            }
        }
        if name.hasPrefix("f"), let number = Int32(name.dropFirst()), (1...12).contains(number) {
            return (GhosttyKey(rawValue: GHOSTTY_KEY_F1.rawValue + number - 1), "", "F\(number)")
        }
        switch name {
        case "escape", "esc": return (GHOSTTY_KEY_ESCAPE, "", "Esc")
        case "enter", "return": return (GHOSTTY_KEY_ENTER, "", "Enter")
        case "tab": return (GHOSTTY_KEY_TAB, "", "Tab")
        case "space": return (GHOSTTY_KEY_SPACE, " ", "Space")
        case "backspace": return (GHOSTTY_KEY_BACKSPACE, "", "\u{232B}")
        case "delete": return (GHOSTTY_KEY_DELETE, "", "Del")
        case "insert": return (GHOSTTY_KEY_INSERT, "", "Ins")
        case "home": return (GHOSTTY_KEY_HOME, "", "Home")
        case "end": return (GHOSTTY_KEY_END, "", "End")
        case "pageup", "page-up": return (GHOSTTY_KEY_PAGE_UP, "", "PgUp")
        case "pagedown", "page-down": return (GHOSTTY_KEY_PAGE_DOWN, "", "PgDn")
        case "up": return (GHOSTTY_KEY_ARROW_UP, "", "\u{2191}")
        case "down": return (GHOSTTY_KEY_ARROW_DOWN, "", "\u{2193}")
        case "left": return (GHOSTTY_KEY_ARROW_LEFT, "", "\u{2190}")
        case "right": return (GHOSTTY_KEY_ARROW_RIGHT, "", "\u{2192}")
        case "-", "minus": return (GHOSTTY_KEY_MINUS, "-", "-")
        case "=", "equal": return (GHOSTTY_KEY_EQUAL, "=", "=")
        case "[": return (GHOSTTY_KEY_BRACKET_LEFT, "[", "[")
        case "]": return (GHOSTTY_KEY_BRACKET_RIGHT, "]", "]")
        case "\\": return (GHOSTTY_KEY_BACKSLASH, "\\", "\\")
        case ";": return (GHOSTTY_KEY_SEMICOLON, ";", ";")
        case "'": return (GHOSTTY_KEY_QUOTE, "'", "'")
        case ",", "comma": return (GHOSTTY_KEY_COMMA, ",", ",")
        case ".", "period": return (GHOSTTY_KEY_PERIOD, ".", ".")
        case "/", "slash": return (GHOSTTY_KEY_SLASH, "/", "/")
        case "`": return (GHOSTTY_KEY_BACKQUOTE, "`", "`")
        default: return nil
        }
    }

    private static func stroke(_ key: GhosttyKey, text: String = "", modifiers: GhosttyMods = 0, label: String) -> SSHTerminalKeyStroke {
        SSHTerminalKeyStroke(key: key, text: text, modifiers: modifiers, label: label)
    }

    /// Claude Code matches names case-insensitively, accepts aliases, and
    /// ignores modifier order, so `Meta+P` in the file is `alt+p` here.
    static func normalized(_ key: String) -> String {
        let aliases = ["control": "ctrl", "option": "alt", "opt": "alt", "meta": "alt", "esc": "escape", "return": "enter"]
        return key.lowercased().split(separator: " ").map { stroke in
            var parts = stroke.split(separator: "+", omittingEmptySubsequences: false).map { aliases[String($0)] ?? String($0) }
            let key = parts.removeLast()
            return (parts.sorted() + [key]).joined(separator: "+")
        }.joined(separator: " ")
    }

    // MARK: - Codex config.toml subset

    /// Reads `tui.keymap.<context>.<action>` assignments from table headers
    /// (`[tui.keymap.chat]`) and dotted keys (`keymap.chat.x = ...` under
    /// `[tui]`). Values are strings or arrays of strings; inline tables and
    /// other layers (profiles, project `.codex/config.toml`) are not read.
    static func codexKeymap(fromTOML text: String) -> [String: [String]] {
        var table = [String]()
        var result = [String: [String]]()
        var pending: (key: [String], value: String)?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if var open = pending {
                open.value += " " + line
                pending = open
                if line.contains("]") {
                    assign(open.key, open.value)
                    pending = nil
                }
                continue
            }
            if line.hasPrefix("[") {
                table = dottedKey(String(line.dropFirst().prefix { $0 != "]" }))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = table + dottedKey(String(line[..<equals]))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), !value.contains("]") { pending = (key, value); continue }
            assign(key, value)
        }
        return result

        func assign(_ key: [String], _ value: String) {
            guard key.count == 4, key[0] == "tui", key[1] == "keymap", let keys = stringValues(value) else { return }
            result["\(key[2]).\(key[3])"] = keys
        }
    }

    private static func dottedKey(_ text: String) -> [String] {
        text.split(separator: ".").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    }

    private static func stringValues(_ value: String) -> [String]? {
        let strings = quotedStrings(value)
        if value.hasPrefix("[") { return strings }
        return strings.count == 1 ? strings : nil
    }

    private static func quotedStrings(_ value: String) -> [String] {
        var strings = [String]()
        var current: String?
        var quote: Character = "\""
        for character in value {
            if var open = current {
                if character == quote { strings.append(open); current = nil } else { open.append(character); current = open }
            } else if character == "\"" || character == "'" {
                quote = character
                current = ""
            }
        }
        return strings
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for (index, character) in zip(line.indices, line) {
            if let open = quote { if character == open { quote = nil } }
            else if character == "\"" || character == "'" { quote = character }
            else if character == "#" { return String(line[..<index]) }
        }
        return line
    }
}

/// Resolves the key strip for the program in front, reading its keybinding
/// file once each time that program takes the foreground.
@MainActor @Observable
final class SSHTerminalKeymapLoader {
    private(set) var actions: [SSHTerminalKeyAction] = []
    private(set) var profile: SSHTerminalKeymap.Profile?
    private(set) var userFile: String?

    func load(program: String?, on channel: SSHTerminalChannel) async {
        guard let program, let found = SSHTerminalKeymap.profile(for: program) else {
            actions = []
            profile = nil
            userFile = nil
            return
        }
        profile = found
        userFile = nil
        actions = SSHTerminalKeymap.actions(for: found, userFile: nil)
        guard let script = found.readScript,
              let result = try? await channel.run("sh -s", input: Data(script.utf8)),
              !Task.isCancelled, result.exitStatus == 0 else { return }
        userFile = String(decoding: result.output, as: UTF8.self)
        actions = SSHTerminalKeymap.actions(for: found, userFile: userFile)
    }
}
