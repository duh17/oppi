import CoreGraphics
import Testing
import UIKit
@testable import Oppi

@Suite("SSH terminal floating controls")
struct SSHTerminalFloatingControlsTests {
    @Test func dockedKeyboardIsUpAndFloatingKeyboardIsNot() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        #expect(!SSHTerminalKeyboard.isUp(endFrameInView: .zero, viewBounds: bounds))
        #expect(
            !SSHTerminalKeyboard.isUp(endFrameInView: CGRect(x: 0, y: 844, width: 390, height: 300), viewBounds: bounds)
        )
        #expect(
            SSHTerminalKeyboard.isUp(endFrameInView: CGRect(x: 0, y: 544, width: 390, height: 300), viewBounds: bounds)
        )
        #expect(
            !SSHTerminalKeyboard.isUp(endFrameInView: CGRect(x: 40, y: 200, width: 310, height: 280), viewBounds: bounds),
            "a floating iPad keyboard must not hide the controls"
        )
        #expect(
            !SSHTerminalKeyboard.isUp(endFrameInView: CGRect(x: 0, y: 843.6, width: 390, height: 0.4), viewBounds: bounds)
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

        let end = SSHTerminalKeyboard.endFrame(
            docked, keyboardScreen: thisDisplay, viewScreen: thisDisplay,
            screenSpace: screenSpace, in: terminal
        )
        #expect(end == CGRect(x: 0, y: 456, width: 1376, height: 336))
        #expect(end.map { SSHTerminalKeyboard.isUp(endFrameInView: $0, viewBounds: terminal.bounds) } == true)

        #expect(
            SSHTerminalKeyboard.endFrame(
                docked, keyboardScreen: otherDisplay, viewScreen: thisDisplay,
                screenSpace: screenSpace, in: terminal
            ) == nil,
            "a keyboard on the other Duo display must not reach this terminal"
        )
        #expect(
            SSHTerminalKeyboard.endFrame(
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
        #expect(SSHTerminalKeyboard.settledGuideTop(endFrameInView: docked, viewBounds: bounds, bottomSafeArea: safeBottom) == 508)
        #expect(SSHTerminalKeyboard.settledGuideTop(endFrameInView: gone, viewBounds: bounds, bottomSafeArea: safeBottom) == 810)
        #expect(SSHTerminalKeyboard.settledGuideTop(endFrameInView: floating, viewBounds: bounds, bottomSafeArea: safeBottom) == 810)

        // Keyboard up: the guide has not moved yet. Keyboard down: it
        // already moved. Either way the settled grid is the final one.
        let up = SSHTerminalKeyboard.settledGridSize(
            current: CGSize(width: 390, height: 751), guideTop: 810, settledGuideTop: 508
        )
        #expect(up == CGSize(width: 390, height: 449))
        let downGuideAlreadyMoved = SSHTerminalKeyboard.settledGridSize(
            current: CGSize(width: 390, height: 692), guideTop: 810, settledGuideTop: 810
        )
        #expect(downGuideAlreadyMoved == CGSize(width: 390, height: 692))
        #expect(
            SSHTerminalKeyboard.settledGridSize(
                current: CGSize(width: 390, height: 100), guideTop: 810, settledGuideTop: 508
            ).height == 0
        )
    }

    @Test func dockedKeyboardOnADuoInnerDisplayIsUp() {
        let inner = CGRect(x: 0, y: 0, width: 1376, height: 892)
        #expect(
            SSHTerminalKeyboard.isUp(endFrameInView: CGRect(x: 0, y: 556, width: 1376, height: 336), viewBounds: inner)
        )
        #expect(
            SSHTerminalKeyboard.isUp(endFrameInView: CGRect(x: 200, y: 556, width: 976, height: 336), viewBounds: inner),
            "a docked keyboard need not span the whole Duo panel"
        )
    }
}

@Suite("SSH terminal floating pills")
@MainActor
struct SSHTerminalFloatingPillTests {
    @Test func backPillSpeaksPendingAttention() {
        let back = SSHTerminalBackPill()
        #expect(back.button.accessibilityIdentifier == "sshTerminal.back")
        #expect(back.button.accessibilityLabel == "Back")
        #expect(back.button.accessibilityValue == nil)

        let theme = ThemeRuntimeState.currentThemeID()
        back.apply(themeID: theme, attentionPending: true)
        #expect(back.button.accessibilityValue == "Attention pending")
        back.apply(themeID: theme, attentionPending: false)
        #expect(back.button.accessibilityValue == nil)
    }

    @Test func eachPillButtonAnswersA44By44PointTouch() throws {
        let back = SSHTerminalBackPill()
        let pill = SSHTerminalMorePill(status: SSHTerminalStatusGlyphButton())
        pill.apply(themeID: ThemeRuntimeState.currentThemeID(), herdrAvailable: true, herdrWaiting: 0, showsStatus: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let host = root.view!
        host.addSubview(back)
        host.addSubview(pill)
        NSLayoutConstraint.activate([
            back.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
            back.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            pill.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
            pill.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 120),
        ])
        host.layoutIfNeeded()
        #expect(pill.bounds.height == SSHTerminalGlassPill.height)
        #expect(back.bounds.size == CGSize(width: SSHTerminalGlassPill.height, height: SSHTerminalGlassPill.height))

        /// A finger anywhere in the 44 \u{d7} 44 pt square on the button's
        /// center lands on it; one point past that square reaches the grid.
        func expect44PointTouch(_ button: UIView, _ id: String) {
            let center = host.convert(button.center, from: button.superview)
            let reach: CGFloat = 22 - 0.5
            for dx in [-reach, 0, reach] {
                for dy in [-reach, 0, reach] {
                    let point = CGPoint(x: center.x + dx, y: center.y + dy)
                    #expect(host.hitTest(point, with: nil) === button, "\(id) at \(dx), \(dy)")
                }
            }
            #expect(host.hitTest(CGPoint(x: center.x, y: center.y - 23), with: nil) === host, "\(id): above 44 pt")
            #expect(button.accessibilityIdentifier == id)
        }
        expect44PointTouch(back.button, "sshTerminal.back")
        for (button, id) in [(pill.status as UIView, "sshTerminal.programStatus"), (pill.herdr, "sshTerminal.herdr"), (pill.more, "sshTerminal.more")] {
            expect44PointTouch(button, id)
        }

        pill.apply(themeID: ThemeRuntimeState.currentThemeID(), herdrAvailable: false, herdrWaiting: nil, showsStatus: false)
        host.layoutIfNeeded()
        #expect(
            pill.bounds.width == SSHTerminalGlassPill.itemWidth,
            "only \u{2026} without status or Herdr: status \(pill.status.frame.width), herdr \(pill.herdr.frame.width)"
        )
        expect44PointTouch(pill.more, "sshTerminal.more")
    }
}
