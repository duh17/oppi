import Foundation
import Observation
import SwiftUI

enum MacSessionPaneCommand: String, CaseIterable, Sendable {
    case splitRight
    case splitDown
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case closePane

    var title: String {
        switch self {
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .focusLeft: "Focus Left"
        case .focusRight: "Focus Right"
        case .focusUp: "Focus Up"
        case .focusDown: "Focus Down"
        case .closePane: "Close Pane"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .splitRight, .splitDown: "d"
        case .focusLeft: .leftArrow
        case .focusRight: .rightArrow
        case .focusUp: .upArrow
        case .focusDown: .downArrow
        case .closePane: "w"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .splitRight: .command
        case .splitDown: [.command, .shift]
        case .focusLeft, .focusRight, .focusUp, .focusDown: [.command, .option]
        case .closePane: [.command, .shift]
        }
    }
}

@MainActor
@Observable
final class MacSessionPaneCommandCenter {
    let deck: MacSessionPaneDeck
    var isCheatSheetPresented = false

    init(deck: MacSessionPaneDeck) {
        self.deck = deck
    }

    var canSplit: Bool { deck.canSplit }
    var canClosePane: Bool { deck.layout != nil }
    var canShowCheatSheet: Bool {
        MacAppKeybindingHelp.allowsCheatSheetShortcut(
            composerIsFirstResponder: deck.hasComposerFirstResponder
        )
    }

    func perform(_ command: MacSessionPaneCommand) {
        let originID = deck.focusedPaneID
        switch command {
        case .splitRight:
            _ = deck.splitFocusedRight()
        case .splitDown:
            _ = deck.splitFocusedBelow()
        case .focusLeft:
            _ = deck.focusAdjacent(.left)
        case .focusRight:
            _ = deck.focusAdjacent(.right)
        case .focusUp:
            _ = deck.focusAdjacent(.up)
        case .focusDown:
            _ = deck.focusAdjacent(.down)
        case .closePane:
            _ = deck.closeFocused()
        }
        if deck.focusedPaneID != originID {
            deck.synchronizeKeyboardOwnership()
        }
    }

    func showCheatSheet() {
        guard canShowCheatSheet else { return }
        isCheatSheetPresented = true
    }
}

private struct MacSessionPaneCommandCenterKey: FocusedValueKey {
    typealias Value = MacSessionPaneCommandCenter
}

extension FocusedValues {
    var macSessionPaneCommands: MacSessionPaneCommandCenter? {
        get { self[MacSessionPaneCommandCenterKey.self] }
        set { self[MacSessionPaneCommandCenterKey.self] = newValue }
    }
}

struct MacSessionPaneCommandMenu: Commands {
    @FocusedValue(\.macSessionPaneCommands) private var commands

    var body: some Commands {
        CommandMenu("View") {
            commandButton(.splitRight)
            commandButton(.splitDown)
            Divider()
            commandButton(.focusLeft)
            commandButton(.focusRight)
            commandButton(.focusUp)
            commandButton(.focusDown)
            Divider()
            commandButton(.closePane)
        }

        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                commands?.showCheatSheet()
            }
            .keyboardShortcut("?", modifiers: .shift)
            .disabled(commands?.canShowCheatSheet != true)
        }
    }

    @ViewBuilder
    private func commandButton(_ command: MacSessionPaneCommand) -> some View {
        Button(command.title) {
            commands?.perform(command)
        }
        .keyboardShortcut(command.key, modifiers: command.modifiers)
        .disabled(!isEnabled(command))
    }

    private func isEnabled(_ command: MacSessionPaneCommand) -> Bool {
        switch command {
        case .splitRight, .splitDown:
            commands?.canSplit == true
        case .focusLeft, .focusRight, .focusUp, .focusDown, .closePane:
            commands?.canClosePane == true
        }
    }
}

struct MacKeyboardCheatSheetView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }

            List(MacAppKeybindingHelp.entries) { entry in
                HStack {
                    Text(entry.action)
                    Spacer()
                    Text(entry.shortcut)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 480)
        .accessibilityIdentifier("mac.keyboardCheatSheet")
    }
}
