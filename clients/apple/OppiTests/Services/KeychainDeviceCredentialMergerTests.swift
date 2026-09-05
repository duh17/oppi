import Foundation
import Testing
@testable import Oppi

@Suite("Keychain device credential merge")
struct KeychainDeviceCredentialMergerTests {
    @Test func refusesOlderRefresh() {
        let stored = DeviceCredential(
            deviceId: "dev_current",
            accessToken: "at_new",
            expiresAt: 2_000,
            refreshChallenge: nil
        )

        #expect(throws: KeychainCredentialMergeError.staleRefresh) {
            try KeychainDeviceCredentialMerger.acceptedRefresh(
                stored: stored,
                expectedDeviceId: "dev_current",
                accessToken: "at_old",
                expiresAt: 1_000,
                refreshChallenge: nil
            )
        }
    }

    @Test func refusesWrongEnrollmentId() {
        let stored = DeviceCredential(
            deviceId: "dev_new",
            accessToken: "at_new",
            expiresAt: 2_000,
            refreshChallenge: nil
        )

        #expect(throws: KeychainCredentialMergeError.enrollmentMismatch) {
            try KeychainDeviceCredentialMerger.acceptedRefresh(
                stored: stored,
                expectedDeviceId: "dev_old",
                accessToken: "at_old",
                expiresAt: 3_000,
                refreshChallenge: nil
            )
        }
    }

    @Test func acceptsFresherSameEnrollment() throws {
        let stored = DeviceCredential(
            deviceId: "dev_current",
            accessToken: "at_old",
            expiresAt: 1_000,
            refreshChallenge: nil
        )
        let updated = try KeychainDeviceCredentialMerger.acceptedRefresh(
            stored: stored,
            expectedDeviceId: "dev_current",
            accessToken: "at_new",
            expiresAt: 2_000,
            refreshChallenge: nil
        )
        #expect(updated.accessToken == "at_new")
        #expect(updated.expiresAt == 2_000)
        #expect(updated.deviceId == "dev_current")
    }
}
