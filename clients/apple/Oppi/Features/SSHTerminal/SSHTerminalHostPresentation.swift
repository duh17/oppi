import Foundation

/// Rising-edge gate for `SSHTerminalConnectSession.devicePasscodeChanged`.
/// The flag stays true after the first tick; re-applying it would clear a
/// newly created replacement key.
struct SSHTerminalDevicePasscodeGate: Equatable {
    private var applied = false

    mutating func shouldClearIdentity(devicePasscodeChanged: Bool) -> Bool {
        if !devicePasscodeChanged {
            applied = false
            return false
        }
        if applied { return false }
        applied = true
        return true
    }
}

/// Device-key identity shown on Add/Edit Host. Observation of the passcode
/// flag only clears on the rising edge, so a successful replacement stays.
struct SSHTerminalDeviceKeyState {
    var identity: SSHIdentity?
    var identityNeedsReplacement = false
    var identityFailure: String?
    private var passcodeGate = SSHTerminalDevicePasscodeGate()

    mutating func observePasscodeChanged(_ changed: Bool, failure: String?) {
        guard passcodeGate.shouldClearIdentity(devicePasscodeChanged: changed) else { return }
        identity = nil
        identityNeedsReplacement = true
        identityFailure = failure
    }

    mutating func applyLoadResult(identity: SSHIdentity?, needsReplacement: Bool, failure: String?) {
        self.identity = identity
        identityNeedsReplacement = needsReplacement
        identityFailure = failure
    }
}

/// Detects Back / Edit Host while a reconnect is in flight: cancel only on
/// `showsTerminal` true→false, never while it is merely false.
struct SSHTerminalShowsTerminalEdge: Equatable {
    private var last = false

    mutating func shouldCancelAttempt(showsTerminal: Bool) -> Bool {
        let falling = last && !showsTerminal
        last = showsTerminal
        return falling
    }
}
