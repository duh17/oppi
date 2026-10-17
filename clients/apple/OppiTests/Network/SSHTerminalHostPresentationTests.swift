import CryptoKit
import Foundation
import NIOSSH
import Testing
import UIKit
@testable import Oppi

@Suite("SSH host list presentation")
@MainActor
struct SSHTerminalHostPresentationTests {
    @Test func passcodeChangeClearsIdentityOnlyOnTheRisingEdgeAndReplacementStays() throws {
        var state = SSHTerminalDeviceKeyState()
        state.observePasscodeChanged(true, failure: SSHIdentityKeyStoreError.devicePasscodeChanged.localizedDescription)
        #expect(state.identity == nil)
        #expect(state.identityNeedsReplacement)
        #expect(state.identityFailure == SSHIdentityKeyStoreError.devicePasscodeChanged.localizedDescription)

        let replacement = SSHIdentity(
            privateKey: NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()),
            isHardwareBacked: false
        )
        state.applyLoadResult(identity: replacement, needsReplacement: false, failure: nil)
        #expect(state.identity?.publicKeyOpenSSH == replacement.publicKeyOpenSSH)
        #expect(!state.identityNeedsReplacement)
        #expect(state.identityFailure == nil)

        state.observePasscodeChanged(true, failure: "New SSH key created. Replace the old entry in ~/.ssh/authorized_keys before connecting.")
        #expect(state.identity?.publicKeyOpenSSH == replacement.publicKeyOpenSSH)
        #expect(!state.identityNeedsReplacement)
        #expect(state.identityFailure == nil)
    }

    @Test func leavingTheTerminalCancelsAReconnectAndDoesNotPushAgain() {
        let host = UIViewController()
        let session = SSHTerminalConnectSession()
        let chrome = SSHTerminalConnectChrome(
            host: host,
            session: session,
            profile: { SSHTerminalProfile(host: "one.ts.net", username: "alice") },
            setProfile: { _ in },
            editHost: {},
            submitPassword: { _ in },
            onSaved: { _ in }
        )
        session.showsTerminal = true
        chrome.sync()
        session.connecting = true
        session.showsTerminal = false
        chrome.sync()
        #expect(!session.connecting)

        session.showsTerminal = true
        chrome.sync()
        #expect(!session.connecting)
        #expect(session.channel == nil)
    }

    @Test func aListConnectIsNotCancelledWhileTheTerminalHasNotBeenShown() {
        let host = UIViewController()
        let session = SSHTerminalConnectSession()
        let chrome = SSHTerminalConnectChrome(
            host: host,
            session: session,
            profile: { SSHTerminalProfile(host: "one.ts.net", username: "alice") },
            setProfile: { _ in },
            editHost: {},
            submitPassword: { _ in },
            onSaved: { _ in }
        )
        session.connecting = true
        chrome.sync()
        #expect(session.connecting)
        chrome.sync()
        #expect(session.connecting)
    }
}
