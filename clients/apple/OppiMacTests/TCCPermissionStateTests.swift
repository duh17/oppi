import Testing
import Foundation
@testable import Oppi

@Suite("TCCPermissionState")
@MainActor
struct TCCPermissionStateTests {

    // MARK: - requiredGranted

    @Test func requiredGrantedWhenFDAGranted() {
        let state = TCCPermissionState()
        state._setPermissionStatusForTesting(kind: .fullDiskAccess, status: .granted)

        #expect(state.requiredGranted)
    }

    @Test("requiredGranted is false when FDA is not granted",
          arguments: [
            TCCPermissionState.PermissionStatus.denied,
            .unknown,
          ])
    func requiredNotGranted(fdaStatus: TCCPermissionState.PermissionStatus) {
        let state = TCCPermissionState()
        state._setPermissionStatusForTesting(kind: .fullDiskAccess, status: fdaStatus)

        #expect(!state.requiredGranted)
    }

    @Test func optionalPermissionsDontAffectRequiredGranted() {
        let state = TCCPermissionState()
        state._setPermissionStatusForTesting(kind: .fullDiskAccess, status: .granted)
        // Set all optional to denied — should not affect requiredGranted.
        state._setPermissionStatusForTesting(kind: .accessibility, status: .denied)
        state._setPermissionStatusForTesting(kind: .screenRecording, status: .denied)
        state._setPermissionStatusForTesting(kind: .notifications, status: .denied)

        #expect(state.requiredGranted)
    }

    // MARK: - summary

    @Test func summaryAllRequiredGranted() {
        let state = TCCPermissionState()
        state._setPermissionStatusForTesting(kind: .fullDiskAccess, status: .granted)

        #expect(state.summary == "1/1 required")
    }

    @Test func summaryRequiredNotGranted() {
        let state = TCCPermissionState()
        state._setPermissionStatusForTesting(kind: .fullDiskAccess, status: .denied)

        #expect(state.summary == "0/1 required — action needed")
    }

    // MARK: - status(for:)

    @Test("status(for:) returns correct status after set",
          arguments: TCCPermissionState.PermissionKind.allCases)
    func statusLookup(kind: TCCPermissionState.PermissionKind) {
        let state = TCCPermissionState()
        state._setPermissionStatusForTesting(kind: kind, status: .granted)

        #expect(state.status(for: kind) == .granted)
    }

    @Test func statusDefaultsToUnknown() {
        let state = TCCPermissionState()
        for kind in TCCPermissionState.PermissionKind.allCases {
            #expect(state.status(for: kind) == .unknown)
        }
    }

    // MARK: - PermissionKind metadata

    @Test("every kind has non-empty display name",
          arguments: TCCPermissionState.PermissionKind.allCases)
    func displayNameNotEmpty(kind: TCCPermissionState.PermissionKind) {
        #expect(!kind.displayName.isEmpty)
    }

    @Test("every kind has non-empty description",
          arguments: TCCPermissionState.PermissionKind.allCases)
    func descriptionNotEmpty(kind: TCCPermissionState.PermissionKind) {
        #expect(!kind.displayDescription.isEmpty)
    }

    @Test("every kind has a system settings URL",
          arguments: TCCPermissionState.PermissionKind.allCases)
    func systemSettingsURLNotNil(kind: TCCPermissionState.PermissionKind) {
        #expect(kind.systemSettingsURL != nil)
    }

    @Test func onlyFDAIsRequired() {
        let required = TCCPermissionState.PermissionKind.allCases.filter(\.isRequired)
        #expect(required == [.fullDiskAccess])
    }

    @Test func initialPermissionCountMatchesAllCases() {
        let state = TCCPermissionState()
        #expect(state.permissions.count == TCCPermissionState.PermissionKind.allCases.count)
    }
}
