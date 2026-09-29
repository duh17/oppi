import AppKit
import SwiftUI

/// Settings → Keyboard. Timeline preset (Mac Standard / Vim / Emacs) plus a
/// rebindable shortcut for every `MacAppCommand`.
struct MacKeyboardSettingsView: View {
    @Bindable private var store = MacKeybindingStore.shared
    @State private var recordingCommand: MacAppCommand?
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                Picker(
                    MacAppSettingsPreferenceControl.keybindings.title,
                    selection: Binding(
                        get: { store.timelinePreset },
                        set: { store.setTimelinePreset($0) }
                    )
                ) {
                    ForEach(KeybindingMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(MacAppSettingsPreferenceControl.keybindings.accessibilityIdentifier)

                ForEach(MacAppKeybindingHelp.timelineSection(mode: store.timelinePreset).entries) { entry in
                    LabeledContent(entry.action) {
                        Text(entry.shortcut)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Timeline Keys")
            } footer: {
                Text(presetFooter)
            }

            ForEach(MacAppCommand.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(MacAppCommand.commands(in: category)) { command in
                        commandRow(command)
                    }
                }
            }

            Section {
                if let notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("mac.settings.keyboard.notice")
                }
                Button("Restore All Defaults") {
                    recordingCommand = nil
                    store.resetAll()
                    notice = nil
                }
                .disabled(store.overrides.isEmpty)
            } footer: {
                Text("Click a shortcut, then press the new keys. Delete clears it; Esc cancels. Shortcuts need ⌘, ⌃, or ⌥.")
            }
        }
        .formStyle(.grouped)
    }

    private var presetFooter: String {
        switch store.timelinePreset {
        case .macDefault:
            "Arrow keys move between tool rows while the timeline has focus. Letters always type into the composer."
        case .vim:
            "Adds j/k, h/l, g/G, e, and i/Tab while the timeline has focus; Esc in the composer returns to the timeline. The composer still types every letter."
        case .emacs:
            "Adds ⌃N/⌃P, ⌃F/⌃B, ⌥</⌥>, ⌃G, and Tab folding while the timeline has focus. The composer keeps macOS Emacs text keys."
        }
    }

    private func commandRow(_ command: MacAppCommand) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                MacShortcutRecorder(
                    shortcut: store.shortcut(for: command),
                    isRecording: Binding(
                        get: { recordingCommand == command },
                        set: { recording in
                            recordingCommand = recording ? command : nil
                            if recording { notice = nil }
                        }
                    ),
                    onRecord: { record($0, for: command) },
                    onClear: {
                        store.unbind(command)
                        notice = nil
                    }
                )
                .accessibilityIdentifier("mac.settings.keyboard.\(command.rawValue)")

                Button {
                    store.reset(command)
                    notice = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Restore default")
                .opacity(store.isCustomized(command) ? 1 : 0)
                .disabled(!store.isCustomized(command))
                .accessibilityLabel("Restore default for \(command.title)")
            }
        } label: {
            Label(command.title, systemImage: command.systemImage)
        }
    }

    private func record(_ shortcut: MacKeyShortcut, for command: MacAppCommand) {
        do {
            if let displaced = try store.assign(shortcut, to: command) {
                notice = "\(shortcut.displayString) moved from \(displaced.title) to \(command.title)."
            } else {
                notice = nil
            }
        } catch {
            switch error {
            case .needsModifier:
                notice = "\(shortcut.displayString) would type into the composer. Add ⌘, ⌃, or ⌥."
            case .reservedBySystem:
                notice = "\(shortcut.displayString) belongs to macOS."
            }
        }
    }
}

/// Click to record the next key-down. A local monitor swallows the event
/// before menu key equivalents, so recording ⌘N does not open a session.
struct MacShortcutRecorder: View {
    let shortcut: MacKeyShortcut?
    @Binding var isRecording: Bool
    let onRecord: (MacKeyShortcut) -> Void
    let onClear: () -> Void

    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(label)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(shortcut == nil ? .secondary : .primary))
                .frame(minWidth: 96)
        }
        .buttonStyle(.bordered)
        .onChange(of: isRecording, initial: true) { _, recording in
            recording ? startMonitoring() : stopMonitoring()
        }
        .onDisappear {
            isRecording = false
            stopMonitoring()
        }
    }

    private var label: String {
        if isRecording { return "Type Shortcut" }
        return shortcut?.displayString ?? "None"
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            if event.keyCode == 53, flags.isEmpty {
                isRecording = false
            } else if event.keyCode == 51 || event.keyCode == 117, flags.isEmpty {
                onClear()
                isRecording = false
            } else if let recorded = MacKeyShortcut(event: event) {
                onRecord(recorded)
                isRecording = false
            }
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
