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
                leaving: false,
                keyboardUp: row.keyboardUp,
                rememberedHide: row.rememberedHide,
                temporaryReveal: row.temporaryReveal
            )
            #expect(
                hidden == row.hidden,
                "connected=\(row.connected) keyboard=\(row.keyboardUp) hide=\(row.rememberedHide) peek=\(row.temporaryReveal)"
            )
            #expect(
                !SSHTerminalTopBarVisibility.hidden(
                    connected: row.connected,
                    leaving: true,
                    keyboardUp: row.keyboardUp,
                    rememberedHide: row.rememberedHide,
                    temporaryReveal: row.temporaryReveal
                ),
                "a leaving terminal hands the screen below a visible bar"
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

    @Test @MainActor func keyboardFrameIsReadInItsOwnScreenSpaceAndOtherDisplaysAreIgnored() {
        // A Duo display (892 pt tall) with the terminal 100 pt below its top.
        let screenSpace = UIView(frame: CGRect(x: 0, y: 0, width: 1376, height: 892))
        let terminal = UIView(frame: CGRect(x: 0, y: 100, width: 1376, height: 792))
        screenSpace.addSubview(terminal)
        let docked = CGRect(x: 0, y: 556, width: 1376, height: 336)
        let thisDisplay = NSObject()
        let otherDisplay = NSObject()

        let end = SSHTerminalTopBarKeyboard.endFrame(
            docked, keyboardScreen: thisDisplay, viewScreen: thisDisplay,
            screenSpace: screenSpace, in: terminal
        )
        #expect(end == CGRect(x: 0, y: 456, width: 1376, height: 336))
        #expect(end.map { SSHTerminalTopBarKeyboard.isUp(endFrameInView: $0, viewBounds: terminal.bounds) } == true)

        #expect(
            SSHTerminalTopBarKeyboard.endFrame(
                docked, keyboardScreen: otherDisplay, viewScreen: thisDisplay,
                screenSpace: screenSpace, in: terminal
            ) == nil,
            "a keyboard on the other Duo display must not reach this terminal"
        )
        #expect(
            SSHTerminalTopBarKeyboard.endFrame(
                docked, keyboardScreen: nil, viewScreen: thisDisplay,
                screenSpace: screenSpace, in: terminal
            ) == nil
        )
    }

    @Test func settledGridFollowsTheKeyboardGuideNotTheFloatingKeyboard() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let safeBottom: CGFloat = 34
        let docked = CGRect(x: 0, y: 508, width: 390, height: 336)
        let gone = CGRect(x: 0, y: 844, width: 390, height: 336)
        let floating = CGRect(x: 40, y: 200, width: 310, height: 280)
        #expect(SSHTerminalTopBarKeyboard.settledGuideTop(endFrameInView: docked, viewBounds: bounds, bottomSafeArea: safeBottom) == 508)
        #expect(SSHTerminalTopBarKeyboard.settledGuideTop(endFrameInView: gone, viewBounds: bounds, bottomSafeArea: safeBottom) == 810)
        #expect(SSHTerminalTopBarKeyboard.settledGuideTop(endFrameInView: floating, viewBounds: bounds, bottomSafeArea: safeBottom) == 810)

        // Keyboard up: the bar already hid in this pass, the guide has not
        // moved yet. Keyboard down: the guide already moved. Either way the
        // settled grid is the final one.
        let up = SSHTerminalTopBarKeyboard.settledGridSize(
            current: CGSize(width: 390, height: 751), guideTop: 810, settledGuideTop: 508
        )
        #expect(up == CGSize(width: 390, height: 449))
        let downGuideAlreadyMoved = SSHTerminalTopBarKeyboard.settledGridSize(
            current: CGSize(width: 390, height: 692), guideTop: 810, settledGuideTop: 810
        )
        #expect(downGuideAlreadyMoved == CGSize(width: 390, height: 692))
        #expect(
            SSHTerminalTopBarKeyboard.settledGridSize(
                current: CGSize(width: 390, height: 100), guideTop: 810, settledGuideTop: 508
            ).height == 0
        )
    }

    @Test func dockedKeyboardOnADuoInnerDisplayIsUp() {
        let inner = CGRect(x: 0, y: 0, width: 1376, height: 892)
        #expect(
            SSHTerminalTopBarKeyboard.isUp(
                endFrameInView: CGRect(x: 0, y: 556, width: 1376, height: 336),
                viewBounds: inner
            )
        )
        #expect(
            SSHTerminalTopBarKeyboard.isUp(
                endFrameInView: CGRect(x: 200, y: 556, width: 976, height: 336),
                viewBounds: inner
            ),
            "a docked keyboard need not span the whole Duo panel"
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
