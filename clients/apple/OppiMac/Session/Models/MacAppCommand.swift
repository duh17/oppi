import AppKit
import Foundation
import Observation
import os
import SwiftUI

/// Every keyboard-reachable Mac app action. Menus, the command palette, the
/// shortcut cheat sheet, and Settings all read this one list, so a rebinding
/// shows up everywhere at once.
///
/// Timeline row navigation (arrows, vim, emacs) is not here: it is a
/// focus-scoped preset from the shared `KeybindingCatalog`.
enum MacAppCommand: String, CaseIterable, Codable, Identifiable, Sendable {
    case newSession
    case commandPalette
    case goToSession
    case nextSession
    case previousSession
    case send
    case stopTurn
    case resume
    case toggleDictation
    case toggleFiles
    case toggleOutline
    case toggleContext
    case focusComposer
    case focusTimeline
    case showHome
    case showWorkspaces
    case showAgents
    case showSchedules
    case showSkills
    case showExtensions
    case zoomIn
    case zoomOut
    case actualSize
    case splitRight
    case splitDown
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case closePane
    case keyboardShortcuts

    enum Category: String, CaseIterable, Sendable {
        case sessions = "Sessions"
        case conversation = "Conversation"
        case navigation = "Navigation"
        case panes = "Panes"
        case view = "View"
        case help = "Help"
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newSession: "New Session"
        case .commandPalette: "Command Palette…"
        case .goToSession: "Go to Session…"
        case .nextSession: "Next Session"
        case .previousSession: "Previous Session"
        case .send: "Send"
        case .stopTurn: "Stop Turn"
        case .resume: "Resume"
        case .toggleDictation: "Start or Stop Dictation"
        case .toggleFiles: "Files"
        case .toggleOutline: "Session Outline"
        case .toggleContext: "Context"
        case .focusComposer: "Focus Composer"
        case .focusTimeline: "Focus Timeline"
        case .showHome: "Home"
        case .showWorkspaces: "Workspaces"
        case .showAgents: "Agents"
        case .showSchedules: "Schedules"
        case .showSkills: "Skills"
        case .showExtensions: "Extensions"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .focusPaneLeft: "Focus Pane Left"
        case .focusPaneRight: "Focus Pane Right"
        case .focusPaneUp: "Focus Pane Up"
        case .focusPaneDown: "Focus Pane Down"
        case .closePane: "Close Pane"
        case .keyboardShortcuts: "Keyboard Shortcuts"
        }
    }

    var category: Category {
        switch self {
        case .newSession, .goToSession, .nextSession, .previousSession:
            .sessions
        case .send, .stopTurn, .resume, .toggleDictation, .toggleFiles, .toggleOutline, .toggleContext,
             .focusComposer, .focusTimeline:
            .conversation
        case .showHome, .showWorkspaces, .showAgents, .showSchedules, .showSkills, .showExtensions:
            .navigation
        case .splitRight, .splitDown, .focusPaneLeft, .focusPaneRight, .focusPaneUp,
             .focusPaneDown, .closePane:
            .panes
        case .commandPalette, .zoomIn, .zoomOut, .actualSize:
            .view
        case .keyboardShortcuts:
            .help
        }
    }

    /// Words the palette also matches ("font" finds Zoom In).
    var searchKeywords: String {
        switch self {
        case .newSession: "create start launch quick"
        case .goToSession: "open switch find search"
        case .nextSession, .previousSession: "switch cycle"
        case .stopTurn: "abort cancel interrupt"
        case .toggleDictation: "voice mic microphone speak record transcribe"
        case .toggleFiles: "browser inspector git"
        case .toggleOutline: "outline navigator"
        case .zoomIn, .zoomOut, .actualSize: "text size font scale bigger smaller reset"
        case .splitRight, .splitDown: "pane split tile"
        case .keyboardShortcuts: "keys bindings help cheat sheet"
        default: ""
        }
    }

    var systemImage: String {
        switch self {
        case .newSession: "square.and.pencil"
        case .commandPalette: "command"
        case .goToSession: "arrow.right.circle"
        case .nextSession: "chevron.down"
        case .previousSession: "chevron.up"
        case .send: "arrow.up.circle"
        case .stopTurn: "stop.circle"
        case .resume: "play.circle"
        case .toggleDictation: "mic"
        case .toggleFiles: "folder"
        case .toggleOutline: "list.bullet.indent"
        case .toggleContext: "gauge.with.dots.needle.33percent"
        case .focusComposer: "text.cursor"
        case .focusTimeline: "text.alignleft"
        case .showHome: "house"
        case .showWorkspaces: "folder.badge.gearshape"
        case .showAgents: "person.2"
        case .showSchedules: "calendar"
        case .showSkills: "book"
        case .showExtensions: "puzzlepiece.extension"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .actualSize: "1.magnifyingglass"
        case .splitRight: "rectangle.split.2x1"
        case .splitDown: "rectangle.split.1x2"
        case .focusPaneLeft: "arrow.left.square"
        case .focusPaneRight: "arrow.right.square"
        case .focusPaneUp: "arrow.up.square"
        case .focusPaneDown: "arrow.down.square"
        case .closePane: "xmark.square"
        case .keyboardShortcuts: "keyboard"
        }
    }

    /// Mac-standard defaults. Every preset shares these; presets only change
    /// timeline row navigation.
    var defaultShortcut: MacKeyShortcut? {
        switch self {
        case .newSession: MacKeyShortcut("n", .command)
        case .commandPalette: MacKeyShortcut("k", .command)
        case .goToSession: MacKeyShortcut("p", .command)
        case .nextSession: MacKeyShortcut("}", .command)
        case .previousSession: MacKeyShortcut("{", .command)
        case .send: MacKeyShortcut(.return, .command)
        case .stopTurn: MacKeyShortcut(".", .command)
        case .resume: nil
        case .toggleDictation: MacKeyShortcut("m", [.command, .shift])
        case .toggleFiles: MacKeyShortcut("1", [.command, .option])
        case .toggleOutline: MacKeyShortcut("2", [.command, .option])
        case .toggleContext: MacKeyShortcut("3", [.command, .option])
        case .focusComposer: MacKeyShortcut("l", .command)
        case .focusTimeline: MacKeyShortcut("j", .command)
        case .showHome: MacKeyShortcut("1", .command)
        case .showWorkspaces: MacKeyShortcut("2", .command)
        case .showAgents: MacKeyShortcut("3", .command)
        case .showSchedules: MacKeyShortcut("4", .command)
        case .showSkills: MacKeyShortcut("5", .command)
        case .showExtensions: MacKeyShortcut("6", .command)
        case .zoomIn: MacKeyShortcut("+", .command)
        case .zoomOut: MacKeyShortcut("-", .command)
        case .actualSize: MacKeyShortcut("0", .command)
        case .splitRight: MacKeyShortcut("d", .command)
        case .splitDown: MacKeyShortcut("d", [.command, .shift])
        case .focusPaneLeft: MacKeyShortcut(.leftArrow, [.command, .option])
        case .focusPaneRight: MacKeyShortcut(.rightArrow, [.command, .option])
        case .focusPaneUp: MacKeyShortcut(.upArrow, [.command, .option])
        case .focusPaneDown: MacKeyShortcut(.downArrow, [.command, .option])
        case .closePane: MacKeyShortcut("w", [.command, .shift])
        case .keyboardShortcuts: MacKeyShortcut("/", .command)
        }
    }

    var sidebarSection: MacSidebarSection? {
        switch self {
        case .showHome: .sessionHome
        case .showWorkspaces: .workspaces
        case .showAgents: .agents
        case .showSchedules: .schedules
        case .showSkills: .skills
        case .showExtensions: .extensions
        default: nil
        }
    }

    var paneCommand: MacSessionPaneCommand? {
        switch self {
        case .splitRight: .splitRight
        case .splitDown: .splitDown
        case .focusPaneLeft: .focusLeft
        case .focusPaneRight: .focusRight
        case .focusPaneUp: .focusUp
        case .focusPaneDown: .focusDown
        case .closePane: .closePane
        default: nil
        }
    }

    var sessionCommandKind: MacSessionCommandKind? {
        switch self {
        case .send: .send
        case .stopTurn: .stopTurn
        case .resume: .resume
        case .toggleDictation: .dictation
        case .toggleFiles: .files
        case .toggleOutline: .outline
        case .toggleContext: .context
        default: nil
        }
    }

    static func commands(in category: Category) -> [MacAppCommand] {
        allCases.filter { $0.category == category }
    }
}

/// One key plus modifiers for a menu command. Letters are stored lowercase
/// with an explicit Shift flag. Other characters are stored as typed
/// (`}` rather than Shift-`]`), which is how AppKit matches key equivalents.
struct MacKeyShortcut: Codable, Hashable, Sendable {
    enum Key: Codable, Hashable, Sendable {
        case character(String)
        case `return`
        case tab
        case space
        case delete
        case escape
        case upArrow
        case downArrow
        case leftArrow
        case rightArrow
    }

    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    var key: Key
    var modifiers: Modifiers

    init(_ key: Key, _ modifiers: Modifiers) {
        if case .character(let raw) = key {
            let lowered = raw.lowercased()
            let isLetter = raw.count == 1 && raw.first?.isLetter == true
            var adjusted = modifiers
            if isLetter, raw != lowered {
                adjusted.insert(.shift)
            }
            if !isLetter {
                adjusted.remove(.shift)
            }
            self.key = .character(isLetter ? lowered : raw)
            self.modifiers = adjusted
        } else {
            self.key = key
            self.modifiers = modifiers
        }
    }

    init(_ character: Character, _ modifiers: Modifiers) {
        self.init(.character(String(character)), modifiers)
    }

    /// Records a key-down. Returns nil for bare modifier presses and for
    /// keys without a stable base character.
    init?(event: NSEvent) {
        var modifiers: Modifiers = []
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        let key: Key
        switch event.keyCode {
        case 36, 76: key = .return
        case 48: key = .tab
        case 49: key = .space
        case 51, 117: key = .delete
        case 53: key = .escape
        case 126: key = .upArrow
        case 125: key = .downArrow
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        default:
            // Shift-= types "+" while charactersIgnoringModifiers stays "=".
            // Keep the typed symbol so Zoom In records as ⌘+, matching the menu.
            let typed = event.characters
            let ignoring = event.charactersIgnoringModifiers
            let base = (flags.contains(.shift)
                && typed?.count == 1
                && typed?.first?.isLetter != true
                && typed != ignoring) ? typed : ignoring
            guard let base,
                  base.count == 1,
                  let scalar = base.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar),
                  // Function keys arrive as private-use scalars.
                  !(0xF700...0xF8FF).contains(scalar.value) else {
                return nil
            }
            key = .character(base)
        }
        self.init(key, modifiers)
    }

    /// A menu shortcut needs Command, Control, or Option; anything else would
    /// steal composer typing.
    var hasCommandLikeModifier: Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// App-menu shortcuts owned by macOS or the text system. Rebinding one of
    /// these would break Quit, Hide, Copy, Settings, and friends.
    var isReservedBySystem: Bool {
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        guard case .character(let character) = key else { return false }
        if modifiers == [.command, .shift] {
            return character == "z"
        }
        return ["q", "w", "h", "m", ",", "c", "v", "x", "a", "z"].contains(character)
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let raw): KeyEquivalent(raw.first ?? " ")
        case .return: .return
        case .tab: .tab
        case .space: .space
        case .delete: .delete
        case .escape: .escape
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// Apple glyph order: Control, Option, Shift, Command, then the key.
    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyDisplay
    }

    private var keyDisplay: String {
        switch key {
        case .character(let raw): raw.uppercased()
        case .return: "↩"
        case .tab: "⇥"
        case .space: "Space"
        case .delete: "⌫"
        case .escape: "⎋"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        }
    }
}

extension KeybindingChord {
    /// Cheat-sheet text for a timeline catalog chord. Vim letters stay
    /// case-sensitive (`g` vs `G`); a typed character already implies Shift.
    var displayString: String {
        var result = ""
        if control { result += "⌃" }
        if option { result += "⌥" }
        let keyText: String
        var shiftIsImplied = false
        switch key {
        case .character(let character):
            shiftIsImplied = true
            keyText = shift || control ? String(character).uppercased() : String(character)
        case .upArrow: keyText = "↑"
        case .downArrow: keyText = "↓"
        case .leftArrow: keyText = "←"
        case .rightArrow: keyText = "→"
        case .return: keyText = "↩"
        case .escape: keyText = "Esc"
        case .tab: keyText = "Tab"
        }
        if shift, !shiftIsImplied { result += "⇧" }
        if command { result += "⌘" }
        return result + keyText
    }
}

extension KeybindingAction {
    var displayTitle: String {
        switch self {
        case .nextToolRow: "Next Tool Row"
        case .previousToolRow: "Previous Tool Row"
        case .collapse: "Collapse Tool Row"
        case .expand: "Expand Tool Row"
        case .toggleExpanded: "Toggle Tool Row"
        case .openViewer: "Open Document"
        case .moveToTop: "First Tool Row"
        case .moveToBottom: "Last Tool Row"
        case .focusComposer: "Focus Composer"
        case .closeViewer: "Close Document"
        case .send: "Send"
        }
    }
}

/// Persisted keyboard configuration: the timeline preset plus per-command
/// overrides of the Mac-standard defaults.
@MainActor
@Observable
final class MacKeybindingStore {
    enum Binding: Codable, Equatable, Sendable {
        case shortcut(MacKeyShortcut)
        case unbound
    }

    enum AssignmentError: Error, Equatable {
        case needsModifier
        case reservedBySystem
    }

    static let shared = MacKeybindingStore()
    static let overridesKey = "oppi.mac.keybinding.overrides"

    @ObservationIgnored private let defaults: UserDefaults
    private(set) var overrides: [MacAppCommand: Binding]
    private(set) var timelinePreset: KeybindingMode

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        timelinePreset = KeybindingPreferenceStore(defaults: defaults).mode
        overrides = Self.loadOverrides(from: defaults)
    }

    func setTimelinePreset(_ mode: KeybindingMode) {
        timelinePreset = mode
        KeybindingPreferenceStore(defaults: defaults).mode = mode
    }

    func shortcut(for command: MacAppCommand) -> MacKeyShortcut? {
        switch overrides[command] {
        case .shortcut(let shortcut): shortcut
        case .unbound: nil
        case nil: command.defaultShortcut
        }
    }

    func isCustomized(_ command: MacAppCommand) -> Bool {
        overrides[command] != nil
    }

    func command(boundTo shortcut: MacKeyShortcut) -> MacAppCommand? {
        MacAppCommand.allCases.first { self.shortcut(for: $0) == shortcut }
    }

    /// Binds `shortcut` to `command`. Another command holding the same chord
    /// loses it (becomes unbound) and is returned so Settings can say so.
    @discardableResult
    func assign(
        _ shortcut: MacKeyShortcut,
        to command: MacAppCommand
    ) throws(AssignmentError) -> MacAppCommand? {
        guard shortcut.hasCommandLikeModifier else { throw .needsModifier }
        guard !shortcut.isReservedBySystem else { throw .reservedBySystem }
        let displaced = self.command(boundTo: shortcut).flatMap { $0 == command ? nil : $0 }
        if let displaced {
            setBinding(.unbound, for: displaced)
        }
        setBinding(.shortcut(shortcut), for: command)
        return displaced
    }

    func unbind(_ command: MacAppCommand) {
        setBinding(.unbound, for: command)
    }

    func reset(_ command: MacAppCommand) {
        overrides[command] = nil
        // A restored default can collide with a chord another command took.
        if let shortcut = command.defaultShortcut {
            for other in MacAppCommand.allCases where other != command
                && self.shortcut(for: other) == shortcut {
                overrides[other] = .unbound
            }
        }
        persist()
    }

    func resetAll() {
        overrides = [:]
        persist()
    }

    private func setBinding(_ binding: Binding, for command: MacAppCommand) {
        let normalized: Binding? = switch binding {
        case .shortcut(let shortcut) where shortcut == command.defaultShortcut: nil
        case .unbound where command.defaultShortcut == nil: nil
        default: binding
        }
        overrides[command] = normalized
        persist()
    }

    private func persist() {
        let encodable = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key.rawValue, $0.value) })
        if encodable.isEmpty {
            defaults.removeObject(forKey: Self.overridesKey)
        } else if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: Self.overridesKey)
        }
    }

    /// Unknown command ids (from a newer or older build) are dropped.
    private static func loadOverrides(from defaults: UserDefaults) -> [MacAppCommand: Binding] {
        guard let data = defaults.data(forKey: overridesKey),
              let decoded = try? JSONDecoder().decode([String: Binding].self, from: data) else {
            return [:]
        }
        var result: [MacAppCommand: Binding] = [:]
        for (rawValue, binding) in decoded {
            if let command = MacAppCommand(rawValue: rawValue) {
                result[command] = binding
            }
        }
        return result
    }
}

/// ⌘+ / ⌘- / ⌘0 step the code and message text scales together. Each scale
/// keeps its own clamp, so one can stop at its limit while the other moves.
enum MacTextZoom {
    static let step = 0.1

    struct Scales: Equatable {
        var code: Double
        var message: Double
    }

    enum Direction {
        case larger
        case smaller
    }

    static var current: Scales {
        Scales(code: FontPreferenceStore.codeTextScale, message: FontPreferenceStore.messageTextScale)
    }

    static let actualSize = Scales(
        code: FontPreferenceStore.standardCodeTextScale,
        message: FontPreferenceStore.standardMessageTextScale
    )

    static func stepped(_ scales: Scales, _ direction: Direction) -> Scales {
        let delta = direction == .larger ? step : -step
        return Scales(
            code: rounded(FontPreferenceStore.clampedCodeTextScale(scales.code + delta)),
            message: rounded(FontPreferenceStore.clampedMessageTextScale(scales.message + delta))
        )
    }

    static func canStep(_ scales: Scales, _ direction: Direction) -> Bool {
        stepped(scales, direction) != scales
    }

    static func apply(_ scales: Scales) {
        FontPreferenceStore.setCodeTextScale(scales.code)
        FontPreferenceStore.setMessageTextScale(scales.message)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

/// One QA step. Scripts name a focus or an action; they do not send chords.
/// Computer Use reads the snapshot, then either runs a step or presses the
/// menu shortcut and checks that the snapshot moved the same way.
enum MacClientScriptStep: Equatable, Sendable {
    case focus(KeybindingFocus)
    case command(MacAppCommand)
    case catalog(KeybindingAction)
}

enum MacClientScript {
    static func parse(_ line: String) -> MacClientScriptStep? {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = parts.first?.lowercased(), parts.count >= 2 else { return nil }
        let name = parts.dropFirst().joined(separator: " ")
        switch verb {
        case "focus":
            guard let focus = KeybindingFocus(rawValue: name.lowercased()) else { return nil }
            return .focus(focus)
        case "command":
            guard let command = MacAppCommand(rawValue: name) else { return nil }
            return .command(command)
        case "catalog":
            guard let action = KeybindingAction.clientScript(named: name) else { return nil }
            return .catalog(action)
        default:
            return nil
        }
    }

    /// Composer controls already have accessibility identifiers. A script
    /// names the control instead of growing a second send path.
    static func controlIdentifier(for command: MacAppCommand) -> String? {
        switch command {
        case .send: "mac.composer.send"
        case .stopTurn: "mac.composer.stop"
        case .resume: "mac.composer.resume"
        case .toggleDictation: "mac.composer.dictation"
        default: nil
        }
    }
}

extension KeybindingAction {
    var clientScriptName: String {
        switch self {
        case .nextToolRow: "nextToolRow"
        case .previousToolRow: "previousToolRow"
        case .collapse: "collapse"
        case .expand: "expand"
        case .toggleExpanded: "toggleExpanded"
        case .openViewer: "openViewer"
        case .closeViewer: "closeViewer"
        case .moveToTop: "moveToTop"
        case .moveToBottom: "moveToBottom"
        case .focusComposer: "focusComposer"
        case .send: "send"
        }
    }

    static func clientScript(named name: String) -> Self? {
        switch name {
        case "nextToolRow": .nextToolRow
        case "previousToolRow": .previousToolRow
        case "collapse": .collapse
        case "expand": .expand
        case "toggleExpanded": .toggleExpanded
        case "openViewer": .openViewer
        case "closeViewer": .closeViewer
        case "moveToTop": .moveToTop
        case "moveToBottom": .moveToBottom
        case "focusComposer": .focusComposer
        case "send": .send
        default: nil
        }
    }
}

/// Readback Computer Use checks after a click, a shortcut, or a script step.
struct MacClientScriptSnapshot: Equatable, Sendable {
    var focus = "-"
    var section = "-"
    var sessionID = "-"
    var selectedToolRowID = "-"
    var openDocumentID = "-"
    var palette = "closed"
    var lastStep = "-"
    var lastResult = "-"

    var accessibilityValue: String {
        [
            "focus=\(focus)",
            "section=\(section)",
            "session=\(sessionID)",
            "row=\(selectedToolRowID)",
            "document=\(openDocumentID)",
            "palette=\(palette)",
            "last=\(lastStep)",
            "result=\(lastResult)",
        ].joined(separator: " ")
    }
}

enum MacClientScriptLog {
    private static let logger = Logger(subsystem: "dev.chenda.OppiMac", category: "ClientScript")
    private static let signposter = OSSignposter(subsystem: "dev.chenda.OppiMac", category: "ClientScript")

    static func measure<T>(_ step: String, _ body: () -> T) -> T {
        let state = signposter.beginInterval("ClientScript", id: signposter.makeSignpostID())
        let started = Date()
        let value = body()
        let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
        signposter.endInterval("ClientScript", state)
        logger.info("step=\(step, privacy: .public) ms=\(milliseconds, privacy: .public)")
        return value
    }
}
