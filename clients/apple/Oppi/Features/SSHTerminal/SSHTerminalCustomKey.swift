import Foundation
import GhosttyVt

/// A button the person made for the SSH terminal's bottom bar: one key
/// combination, shown only for the program in front that it names. It lives
/// beside the built-in buttons in the Bottom Bar list (`SSHTerminalBarItem.customKey`)
/// and sends through the same `SSHTerminalKeyStroke` path as every other key,
/// so Kitty keyboard protocol and modifiers encode as they do for the
/// keyboard bars.
struct SSHTerminalCustomKey: Codable, Hashable, Identifiable, Sendable {
    /// The program in front that shows the button, in the terms the key
    /// strips use (`SSHTerminalAgentDetection.keymapProgram`): the OSC 7501
    /// root agent, else the shell. Herdr is the shell.
    enum ShowFor: Hashable, Sendable, Codable {
        case all
        case shell
        case agent(String)

        init(storage: String) {
            switch storage {
            case "all": self = .all
            case "shell": self = .shell
            default:
                let prefix = "agent:"
                self = storage.hasPrefix(prefix) ? .agent(String(storage.dropFirst(prefix.count))) : .all
            }
        }

        var storage: String {
            switch self {
            case .all: "all"
            case .shell: "shell"
            case .agent(let id): "agent:\(id)"
            }
        }

        init(from decoder: any Decoder) throws {
            self.init(storage: try decoder.singleValueContainer().decode(String.self))
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(storage)
        }

        /// `program` is `SSHTerminalAgentDetection.keymapProgram`'s answer.
        func matches(program: String) -> Bool {
            switch self {
            case .all: true
            case .shell: program == "shell"
            case .agent(let id): program == id
            }
        }

        var title: String {
            switch self {
            case .all: String(localized: "All programs")
            case .shell: String(localized: "Shell")
            case .agent(let id):
                SSHTerminalAgentDetection.agents.first { $0.id == id }?.title ?? id
            }
        }

        /// The Show for picker's choices, in order.
        static var choices: [ShowFor] {
            [.all, .shell] + SSHTerminalAgentDetection.agents.map { .agent($0.id) }
        }
    }

    /// A key the add screen's picker names, because a text field cannot type
    /// it: `key` is the name `SSHTerminalKeymap.parse` reads.
    struct NamedKey: Hashable, Sendable {
        let key: String
        let title: String

        static let all: [NamedKey] = [
            .init(key: "escape", title: String(localized: "Esc")),
            .init(key: "tab", title: String(localized: "Tab")),
            .init(key: "enter", title: String(localized: "Return")),
            .init(key: "space", title: String(localized: "Space")),
            .init(key: "backspace", title: String(localized: "Backspace")),
            .init(key: "up", title: String(localized: "Up Arrow")),
            .init(key: "down", title: String(localized: "Down Arrow")),
            .init(key: "left", title: String(localized: "Left Arrow")),
            .init(key: "right", title: String(localized: "Right Arrow")),
            .init(key: "home", title: String(localized: "Home")),
            .init(key: "end", title: String(localized: "End")),
            .init(key: "pageup", title: String(localized: "Page Up")),
            .init(key: "pagedown", title: String(localized: "Page Down")),
        ] + (1...12).map { NamedKey(key: "f\($0)", title: "F\($0)") }

        static func named(_ key: String) -> NamedKey? { all.first { $0.key == key } }
    }

    var id: UUID
    var name: String
    var control: Bool
    var option: Bool
    var shift: Bool
    /// What the key field holds: one typed character (a letter, a digit, or
    /// `- = [ ] \ ; ' , . / `` ` ``), or a `NamedKey`'s name.
    var key: String
    var showFor: ShowFor

    init(
        id: UUID = UUID(),
        name: String = "",
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false,
        key: String = "",
        showFor: ShowFor = .all
    ) {
        self.id = id
        self.name = name
        self.control = control
        self.option = option
        self.shift = shift
        self.key = key
        self.showFor = showFor
    }

    /// The combination in the keymap's own syntax (`ctrl+alt+d`).
    var spec: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("alt") }
        if shift { parts.append("shift") }
        return (parts + [key]).joined(separator: "+")
    }

    /// What the button sends, nothing for a key the terminal cannot encode.
    var strokes: [SSHTerminalKeyStroke] {
        // Shift changes what a typed character types (`!` for `1`), which the
        // keymap cannot say: only a letter or a named key takes it.
        if shift, key.count == 1, key.first?.isLetter != true { return [] }
        guard !key.isEmpty, !key.contains(" "), var stroke = SSHTerminalKeymap.parse(spec, syntax: .plus)?.first else { return [] }
        // The keymap's text is the key without modifiers; a shifted letter
        // types its capital.
        if shift, stroke.text.count == 1, stroke.text.first?.isLetter == true {
            stroke = SSHTerminalKeyStroke(
                key: stroke.key, text: stroke.text.uppercased(), modifiers: stroke.modifiers, label: stroke.label
            )
        }
        return [stroke]
    }

    var isValid: Bool { !strokes.isEmpty }

    /// The combination as a person reads it: ⌃D, ⌥Enter, ⌃⇧F5.
    var chord: String {
        let keyLabel = SSHTerminalKeymap.parse(key, syntax: .plus)?.first?.label ?? key.uppercased()
        return (control ? "\u{2303}" : "") + (option ? "\u{2325}" : "") + (shift ? "\u{21E7}" : "") + keyLabel
    }

    /// The name, or the combination for a button left unnamed.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? chord : trimmed
    }

    /// What the bar draws on the key cap: the name when it is short enough
    /// for a 44 pt button, else the combination.
    var cap: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...4).contains(trimmed.count) ? trimmed : chord
    }
}

/// What a Rex pane's one Rex control (the pane switcher's pill) shows: the
/// panel it opens has up to three sections, and the pill's icon can carry the
/// program's status. Every part is on until it is turned off.
struct SSHTerminalRexPanelSettings: Equatable, Codable, Sendable {
    /// This pane: the program status records of the pane on screen.
    var showsThisPane = true
    /// Panes in this session: switch, and open a new one.
    var showsPanes = true
    /// Other sessions on the host: open one.
    var showsOtherSessions = true
    /// The pane icon carries the program's status (a dot, the OSC 9;4 ring) and
    /// the number of other panes that need you.
    var showsStatusOnIcon = true
}

/// Where the Bottom Bar's choices are kept: its layout and the custom keys,
/// in one `UserDefaults`, device-local and the same for every host. Only a
/// change someone made writes, so a stored layout is always a choice.
struct SSHTerminalBarStore {
    static let preference = BarLayoutPreference<SSHTerminalBarItem>(
        orderKey: "\(AppIdentifiers.subsystem).sshTerminal.barItemsOrder",
        shownKey: "\(AppIdentifiers.subsystem).sshTerminal.barItemsShown",
        didChangeNotification: Notification.Name("oppi.sshTerminalBar.didChange")
    )
    /// Posted when the layout or the custom keys change; the open terminal
    /// redraws its bar from it.
    static var didChange: Notification.Name { preference.didChangeNotification }

    /// The layout this bar had when it was two pills: the middle's buttons
    /// and, beside them, Herdr, Rex, and the switcher, in one stored order.
    private static let legacyOrderKey = "\(AppIdentifiers.subsystem).sshTerminal.barOrder"
    private static let legacyShownKey = "\(AppIdentifiers.subsystem).sshTerminal.barShown"
    private static let keysKey = "\(AppIdentifiers.subsystem).sshTerminal.barKeys"
    private static let rexPanelKey = "\(AppIdentifiers.subsystem).sshTerminal.rexPanel"

    /// One stored key, or nil when it does not decode.
    private struct Lossy: Decodable {
        let key: SSHTerminalCustomKey?

        init(from decoder: any Decoder) throws {
            key = try? SSHTerminalCustomKey(from: decoder)
        }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var customKeys: [SSHTerminalCustomKey] {
        guard let data = defaults.data(forKey: Self.keysKey),
              let entries = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        // Entry by entry: one this build cannot read (written by another
        // version, or damaged) must not take the others with it.
        return entries.compactMap(\.key).filter(\.isValid)
    }

    /// The saved layout, or the one this bar had before it was one list
    /// (`migrating`), else the default, always covering the custom keys: one
    /// a deleted key left behind is dropped, and one the order has not met
    /// yet goes last, shown.
    var layout: SSHTerminalBarLayout {
        var layout: SSHTerminalBarLayout
        if defaults.stringArray(forKey: Self.preference.orderKey) != nil {
            layout = Self.preference.layout(in: defaults)
        } else if let order = defaults.stringArray(forKey: Self.legacyOrderKey),
                  let shown = defaults.stringArray(forKey: Self.legacyShownKey) {
            layout = .migrating(legacyOrder: order, legacyShown: shown)
        } else {
            layout = .defaultValue
        }
        return covering(layout)
    }

    /// What Reset to Default restores: the built-in buttons as they start,
    /// and the custom keys, which are the person's own, after them.
    var defaultLayout: SSHTerminalBarLayout { covering(.defaultValue) }

    private func covering(_ layout: SSHTerminalBarLayout) -> SSHTerminalBarLayout {
        let keys = customKeys
        let known = Set(keys.map { SSHTerminalBarItem.customKey($0.id) })
        var covered = layout
        for item in layout.order {
            if case .customKey = item, !known.contains(item) { covered = covered.removing(item) }
        }
        for key in keys { covered = covered.adding(.customKey(key.id), shown: true) }
        return covered
    }

    func setLayout(_ layout: SSHTerminalBarLayout) {
        let hadLegacy = defaults.object(forKey: Self.legacyOrderKey) != nil || defaults.object(forKey: Self.legacyShownKey) != nil
        Self.preference.save(layout, in: defaults)
        defaults.removeObject(forKey: Self.legacyOrderKey)
        defaults.removeObject(forKey: Self.legacyShownKey)
        // Retiring the old keys changes what `layout` reads even when the new
        // layout equals the default and `save` skipped the write.
        if hadLegacy { NotificationCenter.default.post(name: Self.preference.didChangeNotification, object: nil) }
    }

    /// Adds a key, or replaces the one with its id.
    func save(_ key: SSHTerminalCustomKey) {
        var keys = customKeys
        if let index = keys.firstIndex(where: { $0.id == key.id }) {
            keys[index] = key
        } else {
            keys.append(key)
        }
        write(keys)
    }

    func delete(_ id: UUID) {
        write(customKeys.filter { $0.id != id })
        // The layout keeps no place for it; the next write of the layout
        // drops it, and `layout` never shows it.
    }

    var rexPanel: SSHTerminalRexPanelSettings {
        defaults.data(forKey: Self.rexPanelKey)
            .flatMap { try? JSONDecoder().decode(SSHTerminalRexPanelSettings.self, from: $0) } ?? SSHTerminalRexPanelSettings()
    }

    func setRexPanel(_ settings: SSHTerminalRexPanelSettings) {
        guard settings != rexPanel else { return }
        defaults.set(try? JSONEncoder().encode(settings), forKey: Self.rexPanelKey)
        NotificationCenter.default.post(name: Self.preference.didChangeNotification, object: nil)
    }

    /// Forgets the saved layout; the custom keys and the Rex panel's choices stay.
    func reset() {
        defaults.removeObject(forKey: Self.preference.orderKey)
        defaults.removeObject(forKey: Self.preference.shownKey)
        defaults.removeObject(forKey: Self.legacyOrderKey)
        defaults.removeObject(forKey: Self.legacyShownKey)
        NotificationCenter.default.post(name: Self.preference.didChangeNotification, object: nil)
    }

    private func write(_ keys: [SSHTerminalCustomKey]) {
        defaults.set(try? JSONEncoder().encode(keys), forKey: Self.keysKey)
        NotificationCenter.default.post(name: Self.preference.didChangeNotification, object: nil)
    }
}
