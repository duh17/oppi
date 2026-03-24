import Foundation
import Network
import Testing
@testable import Oppi

@Suite("LANDiscovery")
struct LANDiscoveryTests {
    @Test func parseTXTRecordDecodesStringAndDataFields() {
        let txtData = NetService.data(fromTXTRecord: [
            "sid": Data("SERVERPREFIX".utf8),
            "ip": Data("192.168.1.42".utf8),
            "binary": Data([0xFF, 0x00]),
        ])

        let map = LANDiscovery.parseTXTRecord(NWTXTRecord(txtData))

        #expect(map["sid"] == "SERVERPREFIX")
        #expect(map["ip"] == "192.168.1.42")
        #expect(map["binary"] == nil)
    }

    @Test func parseTXTRecordHandlesEmptyAndNoneEntries() {
        let raw = Data([
            4, 0x66, 0x6f, 0x6f, 0x3d, // foo=
            3, 0x62, 0x61, 0x72, // bar
        ])

        let map = LANDiscovery.parseTXTRecord(NWTXTRecord(raw))

        #expect(map["foo"]?.isEmpty == true)
        #expect(map["bar"] == nil)
    }

    @Test func parseTXTRecordDataDecodesUTF8Fields() {
        let txtData = NetService.data(fromTXTRecord: [
            "v": Data("1".utf8),
            "sid": Data("SERVERPREFIX".utf8),
            "tfp": Data("TLSPREFIX".utf8),
            "ip": Data("192.168.1.42".utf8),
            "p": Data("7749".utf8),
        ])

        let map = LANDiscovery.parseTXTRecordData(txtData)

        #expect(map["v"] == "1")
        #expect(map["sid"] == "SERVERPREFIX")
        #expect(map["tfp"] == "TLSPREFIX")
        #expect(map["ip"] == "192.168.1.42")
        #expect(map["p"] == "7749")
    }

    @Test func endpointFromTXTRecordBuildsEndpoint() {
        let endpoint = LANDiscovery.endpoint(fromTXTRecord: [
            "sid": "SERVERPREFIX",
            "tfp": "TLSPREFIX",
            "ip": "192.168.1.42",
            "p": "7749",
        ])

        #expect(endpoint == LANDiscoveredEndpoint(
            host: "192.168.1.42",
            port: 7749,
            serverFingerprintPrefix: "SERVERPREFIX",
            tlsCertFingerprintPrefix: "TLSPREFIX"
        ))
    }

    @Test func endpointFromTXTRecordRejectsMissingFields() {
        #expect(LANDiscovery.endpoint(fromTXTRecord: [:]) == nil)
        #expect(LANDiscovery.endpoint(fromTXTRecord: ["sid": "SERVER", "ip": "192.168.1.42"]) == nil)
        #expect(LANDiscovery.endpoint(fromTXTRecord: ["sid": "SERVER", "p": "7749"]) == nil)
    }

    @Test func endpointFromTXTRecordRejectsInvalidPort() {
        #expect(LANDiscovery.endpoint(fromTXTRecord: [
            "sid": "SERVER",
            "ip": "192.168.1.42",
            "p": "0",
        ]) == nil)

        #expect(LANDiscovery.endpoint(fromTXTRecord: [
            "sid": "SERVER",
            "ip": "192.168.1.42",
            "p": "99999",
        ]) == nil)
    }
}
