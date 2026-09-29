import SwiftUI

/// Window-level command owner. Menu items and the command palette route
/// window commands here; the main window installs `handler` for the ones
/// that need its navigation state.
@MainActor
@Observable
final class MacWindowCommandCenter {
    /// Nil means the command palette is closed.
    private(set) var palette: MacCommandPaletteMode?
    /// Menu-bar snapshot captured when the palette opened. Window views cannot
    /// read the scene's session focused values, so the palette runs commands
    /// through the same dispatch the menu bar resolved.
    private(set) var paletteDispatch: MacAppCommandDispatch?
    var isCheatSheetPresented = false
    var isClientScriptPresented = false
    @ObservationIgnored var handler: @MainActor (MacAppCommand) -> Void = { _ in }

    func closePalette() {
        palette = nil
        paletteDispatch = nil
    }

    func perform(_ command: MacAppCommand, dispatch: MacAppCommandDispatch) {
        switch command {
        case .commandPalette:
            togglePalette(.all, dispatch: dispatch)
        case .goToSession:
            togglePalette(.sessions, dispatch: dispatch)
        case .keyboardShortcuts:
            closePalette()
            isCheatSheetPresented = true
        default:
            handler(command)
        }
    }

    private func togglePalette(_ mode: MacCommandPaletteMode, dispatch: MacAppCommandDispatch) {
        if palette == mode {
            closePalette()
        } else {
            paletteDispatch = dispatch
            palette = mode
        }
    }
}

private struct MacWindowCommandCenterKey: FocusedValueKey {
    typealias Value = MacWindowCommandCenter
}

extension FocusedValues {
    var macWindowCommands: MacWindowCommandCenter? {
        get { self[MacWindowCommandCenterKey.self] }
        set { self[MacWindowCommandCenterKey.self] = newValue }
    }
}

/// Focused-value snapshot shared by the menu bar and the command palette, so
/// both agree on what is enabled and what a command does.
@MainActor
struct MacAppCommandDispatch {
    var window: MacWindowCommandCenter?
    var panes: MacSessionPaneCommandCenter?
    var sessionItems: [MacSessionCommandKind: MacSessionCommandItem]

    func isEnabled(_ command: MacAppCommand) -> Bool {
        if let kind = command.sessionCommandKind {
            return sessionItems[kind]?.enabled == true
        }
        if command.paneCommand != nil {
            return panes?.canClosePane == true
        }
        switch command {
        case .zoomIn, .zoomOut, .actualSize:
            return true
        default:
            return window != nil
        }
    }

    func perform(_ command: MacAppCommand) {
        guard isEnabled(command) else { return }
        if let kind = command.sessionCommandKind {
            sessionItems[kind]?.perform()
            return
        }
        if let paneCommand = command.paneCommand {
            panes?.perform(paneCommand)
            return
        }
        switch command {
        case .zoomIn:
            MacTextZoom.apply(MacTextZoom.stepped(MacTextZoom.current, .larger))
        case .zoomOut:
            MacTextZoom.apply(MacTextZoom.stepped(MacTextZoom.current, .smaller))
        case .actualSize:
            MacTextZoom.apply(MacTextZoom.actualSize)
        default:
            window?.perform(command, dispatch: self)
        }
    }
}

/// The focused values every command surface reads.
struct MacAppCommandFocus: DynamicProperty {
    @FocusedValue(\.macWindowCommands) private var window
    @FocusedValue(\.macSessionPaneCommands) private var panes
    @FocusedValue(\.macSessionSendCommand) private var send
    @FocusedValue(\.macSessionStopTurnCommand) private var stopTurn
    @FocusedValue(\.macSessionResumeCommand) private var resume
    @FocusedValue(\.macSessionDictationCommand) private var dictation
    @FocusedValue(\.macSessionFilesCommand) private var files
    @FocusedValue(\.macSessionOutlineCommand) private var outline
    @FocusedValue(\.macSessionContextCommand) private var context

    @MainActor
    var dispatch: MacAppCommandDispatch {
        var items: [MacSessionCommandKind: MacSessionCommandItem] = [:]
        items[.send] = send
        items[.stopTurn] = stopTurn
        items[.resume] = resume
        items[.dictation] = dictation
        items[.files] = files
        items[.outline] = outline
        items[.context] = context
        return MacAppCommandDispatch(window: window, panes: panes, sessionItems: items)
    }
}

/// Menu bar layout. Every item's shortcut is read from `MacKeybindingStore`,
/// so a rebinding in Settings updates the menus immediately.
struct MacAppCommandMenus: Commands {
    private var focus = MacAppCommandFocus()
    private var keybindings: MacKeybindingStore { .shared }

    var body: some Commands {
        let dispatch = focus.dispatch

        CommandGroup(replacing: .newItem) {
            item(.newSession, dispatch)
        }

        CommandMenu("Session") {
            item(.send, dispatch)
            item(.stopTurn, dispatch)
            item(.resume, dispatch)
            item(.toggleDictation, dispatch)
            Divider()
            item(.toggleFiles, dispatch)
            item(.toggleOutline, dispatch)
            item(.toggleContext, dispatch)
            Divider()
            item(.focusComposer, dispatch)
            item(.focusTimeline, dispatch)
        }

        CommandMenu("Go") {
            item(.goToSession, dispatch)
            item(.nextSession, dispatch)
            item(.previousSession, dispatch)
            Divider()
            ForEach(MacAppCommand.commands(in: .navigation)) { command in
                item(command, dispatch)
            }
        }

        CommandGroup(before: .sidebar) {
            item(.commandPalette, dispatch)
            Divider()
            item(.zoomIn, dispatch)
            item(.zoomOut, dispatch)
            item(.actualSize, dispatch)
            Divider()
            item(.splitRight, dispatch)
            item(.splitDown, dispatch)
            item(.focusPaneLeft, dispatch)
            item(.focusPaneRight, dispatch)
            item(.focusPaneUp, dispatch)
            item(.focusPaneDown, dispatch)
            item(.closePane, dispatch)
            Divider()
        }

        CommandGroup(after: .help) {
            item(.keyboardShortcuts, dispatch)
            Button("Client Script…") {
                dispatch.window?.isClientScriptPresented = true
            }
            .disabled(dispatch.window == nil)
        }
    }

    private func item(_ command: MacAppCommand, _ dispatch: MacAppCommandDispatch) -> some View {
        Button(command.title) {
            dispatch.perform(command)
        }
        .keyboardShortcut(keybindings.shortcut(for: command)?.keyboardShortcut)
        .disabled(!dispatch.isEnabled(command))
    }
}

struct MacClientScriptSheet: View {
    @Binding var line: String
    let snapshot: String
    let run: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Client Script")
                .font(.title2.weight(.semibold))
            Text("focus timeline · command focusComposer · catalog nextToolRow")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("focus timeline", text: $line)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mac.clientScript.input")
                .onSubmit(run)
            HStack {
                Button("Run", action: run)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("mac.clientScript.run")
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            Text(snapshot)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("mac.clientScript.snapshot")
                .accessibilityLabel("Client script snapshot")
        }
        .padding(20)
        .frame(minWidth: 640)
        .accessibilityIdentifier("mac.clientScript")
    }
}

struct MacKeyboardCheatSheetView: View {
    let dismiss: () -> Void
    private var keybindings: MacKeybindingStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))
                Spacer()
                SettingsLink {
                    Text("Customize…")
                }
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                // Adaptive columns propose an unbounded width, so a row's
                // Spacer spills its shortcut into the next column. Two
                // flexible columns keep each shortcut beside its action.
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 240), spacing: 28, alignment: .top),
                        GridItem(.flexible(minimum: 240), spacing: 28, alignment: .top),
                    ],
                    alignment: .leading,
                    spacing: 18
                ) {
                    ForEach(MacAppKeybindingHelp.sections(store: keybindings)) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            ForEach(section.entries) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(entry.action)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(entry.shortcut)
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 520)
        .accessibilityIdentifier("mac.keyboardCheatSheet")
    }
}
