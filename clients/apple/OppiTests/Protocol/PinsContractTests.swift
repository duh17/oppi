import Foundation
import Testing
@testable import Oppi

/// `protocol/pins-http.json`: the bodies of `GET`, `POST` and `PUT /pins`.
/// Server `pins-routes.test.ts` holds the committed bytes to the protocol
/// types; this side decodes every body and writes the requests the same way.
@Suite("Pins contract")
struct PinsContractTests {
    struct Fixture: Decodable {
        struct Conflict: Decodable {
            let code: String
            let current: PinsList
        }

        let list: PinsList
        let add: PinAddResult
        let conflict: Conflict
    }

    static func raw() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: ProtocolFixtures.data("pins-http.json")) as? [String: Any])
    }

    @Test func decodesEveryStatusAndTarget() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("pins-http.json"))
        #expect(fixture.list.pins.map(\.status) == [.ok, .ok, .missing, .unreadable, .workspaceMissing, .unknown, .ok, .missing])
        #expect(fixture.list.pins[0].target == .host(path: "~/notebook"))
        #expect(fixture.list.pins[1].target == .workspace(id: "ws-1", path: "reports"))
        #expect(fixture.list.pins[1].label == "Reports")
        #expect(fixture.list.pins[2].kind == .file)
        #expect(fixture.list.pins[6].target == .session(id: "2f6c1a9e-session"))
        #expect(fixture.list.pins[6].kind == .session)
        #expect(fixture.add.pinId == "pin_Reports00002")
        #expect(fixture.conflict.code == "revision_conflict")
        #expect(fixture.conflict.current == fixture.list)
    }

    /// The requests the app sends encode to the fixture's request bodies.
    @Test func encodesTheRequestBodiesTheServerReads() throws {
        let raw = try Self.raw()
        let addRequests = try #require(raw["addRequests"] as? [[String: Any]])
        for request in addRequests {
            let target = try #require(request["target"] as? [String: Any])
            let decoded = try JSONDecoder().decode(PinTarget.self, from: JSONSerialization.data(withJSONObject: target))
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary
            #expect(encoded == target as NSDictionary)
        }
        let reorder = try #require(raw["reorderRequest"] as? [String: Any])
        let entries = [PinOrderEntry(id: "pin_Reports00002", label: "Reports"), PinOrderEntry(id: "pin_Notebook0001", label: nil)]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)) as? NSArray
        #expect(encoded == reorder["pins"] as? NSArray, "an absent label is left out, not sent as null")
    }

    @Test func aStatusFromANewerServerReadsAsUnknown() throws {
        let json = #"{"revision":1,"pins":[{"id":"pin_Notebook0001","target":{"origin":"host","path":"~/n"},"kind":"directory","createdAt":1,"status":"asleep"}]}"#
        let list = try JSONDecoder().decode(PinsList.self, from: Data(json.utf8))
        #expect(list.pins.first?.status == .unknown)
    }
}
