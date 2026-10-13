import Foundation
import Testing
@testable import Oppi

@Suite("Paired device roster")
struct PairedDeviceRosterTests {
    @Test func hidesRevokedDevicesAndMarksThisIPhone() {
        let devices = [
            AuthDevice(
                id: "dev_other",
                name: "iPad",
                scope: "device",
                createdAt: 10,
                lastUsedAt: 40,
                revokedAt: nil,
                keyEnrolled: true
            ),
            AuthDevice(
                id: "dev_me",
                name: "Chen iPhone",
                scope: "device",
                createdAt: 20,
                lastUsedAt: 30,
                revokedAt: nil,
                keyEnrolled: true
            ),
            AuthDevice(
                id: "dev_old",
                name: "Stolen",
                scope: "device",
                createdAt: 1,
                lastUsedAt: 2,
                revokedAt: 3,
                keyEnrolled: true
            ),
        ]

        let rows = PairedDeviceRoster.rows(from: devices, currentDeviceId: "dev_me")

        #expect(rows.map(\.id) == ["dev_me", "dev_other"])
        #expect(rows[0].isThisDevice)
        #expect(!rows[0].canRevoke)
        #expect(rows[0].title == "Chen iPhone")
        #expect(!rows[1].isThisDevice)
        #expect(rows[1].canRevoke)
    }

    @Test func blankNameFallsBackToDeviceAndThisDeviceCannotRevokeItself() {
        let rows = PairedDeviceRoster.rows(
            from: [
                AuthDevice(
                    id: "dev_me",
                    name: "  ",
                    scope: "device",
                    createdAt: 1,
                    lastUsedAt: nil,
                    revokedAt: nil,
                    keyEnrolled: true
                ),
            ],
            currentDeviceId: "dev_me"
        )

        #expect(rows.count == 1)
        #expect(rows[0].id == "dev_me")
        #expect(rows[0].title == "Device")
        #expect(rows[0].isThisDevice)
        #expect(!rows[0].canRevoke)
        #expect(rows[0].lastUsedAt == nil)
        #expect(rows[0].createdAt == 1)
        #expect(rows[0].pairingMethod == nil)
        #expect(rows[0].pairingSource == nil)
        #expect(rows[0].caption.hasPrefix("This device · Enrolled"))
    }

    @Test func sortsThisDeviceFirstThenMostRecentlyUsed() {
        let rows = PairedDeviceRoster.rows(
            from: [
                AuthDevice(id: "dev_a", name: "A", scope: "device", createdAt: 1, lastUsedAt: 10, revokedAt: nil, keyEnrolled: true),
                AuthDevice(id: "dev_b", name: "B", scope: "device", createdAt: 2, lastUsedAt: 50, revokedAt: nil, keyEnrolled: true),
                AuthDevice(id: "dev_me", name: "Me", scope: "device", createdAt: 3, lastUsedAt: 1, revokedAt: nil, keyEnrolled: true),
            ],
            currentDeviceId: "dev_me"
        )

        #expect(rows.map(\.id) == ["dev_me", "dev_b", "dev_a"])
    }

    @Test func metadataRowShowsMethodSourceAndEnrolledTime() {
        let createdAt: Int64 = 1_760_000_000_000
        let rows = PairedDeviceRoster.rows(
            from: [
                AuthDevice(
                    id: "dev_ipad",
                    name: "iPad",
                    scope: "device",
                    createdAt: createdAt,
                    lastUsedAt: 2,
                    revokedAt: nil,
                    keyEnrolled: true,
                    pairingMethod: "invite",
                    pairingSource: "100.64.0.7",
                    approvedByDeviceId: "dev_me"
                ),
            ],
            currentDeviceId: "dev_me"
        )

        #expect(rows[0].pairingMethod == "invite")
        #expect(rows[0].pairingSource == "100.64.0.7")
        #expect(rows[0].caption.contains("Invite"))
        #expect(rows[0].caption.contains("100.64.0.7"))
        #expect(rows[0].caption.contains("Enrolled"))
        #expect(!rows[0].caption.hasPrefix("This device"))
    }

    @Test func legacyRowShowsOnlyEnrolledDate() {
        let rows = PairedDeviceRoster.rows(
            from: [
                AuthDevice(
                    id: "dev_cli",
                    name: "oppi CLI",
                    scope: "device",
                    createdAt: 1_760_000_000_000,
                    lastUsedAt: nil,
                    revokedAt: nil,
                    keyEnrolled: false
                ),
            ],
            currentDeviceId: "dev_me"
        )

        #expect(rows[0].pairingMethod == nil)
        #expect(rows[0].pairingSource == nil)
        #expect(rows[0].caption.hasPrefix("Enrolled"))
        #expect(!rows[0].caption.contains("Invite"))
        #expect(!rows[0].caption.contains("This device"))
    }

    @Test func loadedStateKeepsLastRowsWhenRefreshFails() {
        let devices = [
            AuthDevice(id: "dev_me", name: "Phone", scope: "device", createdAt: 1, lastUsedAt: 2, revokedAt: nil, keyEnrolled: true),
        ]

        #expect(
            ServerDetailPairedDevicesState.resolve(
                devices: nil,
                currentDeviceId: "dev_me",
                isLoading: true,
                error: nil
            ) == .loading
        )
        #expect(
            ServerDetailPairedDevicesState.resolve(
                devices: devices,
                currentDeviceId: "dev_me",
                isLoading: false,
                error: "Offline"
            ) == .loaded(
                rows: PairedDeviceRoster.rows(from: devices, currentDeviceId: "dev_me"),
                error: "Offline"
            )
        )
        #expect(
            ServerDetailPairedDevicesState.resolve(
                devices: nil,
                currentDeviceId: "dev_me",
                isLoading: false,
                error: "Offline"
            ) == .failed("Offline")
        )
    }
}

@Suite("Pairing device name")
struct PairingDeviceNameTests {
    @Test func trimsAndDropsBlankNames() {
        #expect(PairingDeviceName.resolved("  Chen iPhone  ") == "Chen iPhone")
        #expect(PairingDeviceName.resolved("   ") == nil)
        #expect(PairingDeviceName.resolved(nil) == nil)
    }

    @Test func capsLongNames() {
        let long = String(repeating: "a", count: PairingDeviceName.maxLength + 20)
        #expect(PairingDeviceName.resolved(long)?.count == PairingDeviceName.maxLength)
    }

    @Test func genericModelNameGetsStableVendorSuffix() throws {
        let id = (try #require(UUID(uuidString: "A3F91234-0000-0000-0000-000000000000")))
        #expect(PairingDeviceName.resolved("iPhone", model: "iPhone", vendorId: id) == "iPhone (A3F9)")
        #expect(PairingDeviceName.resolved(" iphone ", model: "iPhone", vendorId: id) == "iphone (A3F9)")
        let other = (try #require(UUID(uuidString: "B7710000-0000-0000-0000-000000000000")))
        #expect(PairingDeviceName.resolved("iPhone", model: "iPhone", vendorId: other) == "iPhone (B771)")
    }

    @Test func userAssignedNameIsKeptVerbatim() {
        let id = UUID()
        #expect(PairingDeviceName.resolved("Chen's iPhone", model: "iPhone", vendorId: id) == "Chen's iPhone")
    }

    @Test func genericNameWithoutVendorIdIsKept() {
        #expect(PairingDeviceName.resolved("iPad", model: "iPad", vendorId: nil) == "iPad")
    }
}
