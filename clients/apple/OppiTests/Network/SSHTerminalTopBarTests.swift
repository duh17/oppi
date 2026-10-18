import CoreGraphics
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal top bar")
struct SSHTerminalTopBarTests {
    @Test func visibilityIsKeyboardTimesRememberedHideTimesTemporaryReveal() {
        let rows: [(
            connected: Bool,
            keyboardUp: Bool,
            rememberedHide: Bool,
            temporaryReveal: Bool,
            hidden: Bool
        )] = [
            (true, false, false, false, false),
            (true, true, false, false, true),
            (true, true, false, true, false),
            (true, false, true, false, true),
            (true, false, true, true, true),
            (true, true, true, false, true),
            (true, true, true, true, false),
            (false, true, true, false, false),
            (false, false, true, false, false),
            (false, true, false, true, false),
        ]
        for row in rows {
            let hidden = SSHTerminalTopBarVisibility.hidden(
                connected: row.connected,
                keyboardUp: row.keyboardUp,
                rememberedHide: row.rememberedHide,
                temporaryReveal: row.temporaryReveal
            )
            #expect(
                hidden == row.hidden,
                "connected=\(row.connected) keyboard=\(row.keyboardUp) hide=\(row.rememberedHide) peek=\(row.temporaryReveal)"
            )
            #expect(
                SSHTerminalTopBarVisibility.handleVisible(barHidden: hidden, connected: row.connected)
                    == (hidden && row.connected)
            )
        }
    }

    @Test func attentionDotFollowsHerdrAndBlockedProgramNotNotifications() {
        #expect(!SSHTerminalTopBarAttention.pending(herdrWaiting: 0, blockedProgram: false))
        #expect(SSHTerminalTopBarAttention.pending(herdrWaiting: 1, blockedProgram: false))
        #expect(SSHTerminalTopBarAttention.pending(herdrWaiting: 0, blockedProgram: true))
        #expect(SSHTerminalTopBarAttention.pending(herdrWaiting: 2, blockedProgram: true))
    }

    @Test func dockedKeyboardIsUpAndFloatingKeyboardIsNot() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        #expect(
            !SSHTerminalTopBarKeyboard.isUp(
                endFrameInView: .zero,
                viewBounds: bounds
            )
        )
        #expect(
            !SSHTerminalTopBarKeyboard.isUp(
                endFrameInView: CGRect(x: 0, y: 844, width: 390, height: 300),
                viewBounds: bounds
            )
        )
        #expect(
            SSHTerminalTopBarKeyboard.isUp(
                endFrameInView: CGRect(x: 0, y: 544, width: 390, height: 300),
                viewBounds: bounds
            )
        )
        #expect(
            !SSHTerminalTopBarKeyboard.isUp(
                endFrameInView: CGRect(x: 40, y: 200, width: 310, height: 280),
                viewBounds: bounds
            ),
            "a floating iPad keyboard must not auto-hide the bar"
        )
        #expect(
            !SSHTerminalTopBarKeyboard.isUp(
                endFrameInView: CGRect(x: 0, y: 843.6, width: 390, height: 0.4),
                viewBounds: bounds
            )
        )
    }
}

@Suite("AppPreferences.SSHTerminal", .serialized)
struct SSHTerminalHideBarPreferenceTests {
    private let key = AppPreferences.SSHTerminal.hideBarKey

    @Test func hideBarDefaultsToShownAndPersists() {
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(!AppPreferences.SSHTerminal.hideBar)

        AppPreferences.SSHTerminal.setHideBar(true)
        #expect(AppPreferences.SSHTerminal.hideBar)
        #expect(UserDefaults.standard.bool(forKey: key))

        AppPreferences.SSHTerminal.setHideBar(true)
        #expect(AppPreferences.SSHTerminal.hideBar)

        AppPreferences.SSHTerminal.setHideBar(false)
        #expect(!AppPreferences.SSHTerminal.hideBar)
    }

    @Test func keyboardAutoHideDoesNotWriteTheRememberedChoice() {
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        _ = SSHTerminalTopBarVisibility.hidden(
            connected: true,
            keyboardUp: true,
            rememberedHide: AppPreferences.SSHTerminal.hideBar,
            temporaryReveal: false
        )
        #expect(!AppPreferences.SSHTerminal.hideBar)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}

@Suite("SSH terminal top bar handle")
@MainActor
struct SSHTerminalTopBarHandleTests {
    @Test func handleKeepsItsIdentifierAndSpeaksPendingAttention() {
        let handle = SSHTerminalTopBarHandleView()
        let button = handle.subviews.compactMap { $0 as? UIButton }.first
        #expect(button?.accessibilityIdentifier == "sshTerminal.showBar")
        #expect(button?.accessibilityLabel == "Show terminal bar")
        #expect(button?.accessibilityValue == nil)

        let theme = ThemeRuntimeState.currentThemeID()
        handle.apply(themeID: theme, attentionPending: true)
        #expect(button?.accessibilityValue == "Attention pending")
        handle.apply(themeID: theme, attentionPending: false)
        #expect(button?.accessibilityValue == nil)
    }
}
