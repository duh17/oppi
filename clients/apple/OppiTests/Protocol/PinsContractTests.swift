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

    @Test func decodesEveryStatusAndRoute() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("pins-http.json"))
        let pins = fixture.list.pins
        #expect(pins.map(\.status) == [
            .ok, .ok, .missing, .unreadable, .workspaceMissing, .unknown, .ok, .missing, .ok, .missing,
            .ok, .ok, .ok, .ok, .ok,
        ])
        #expect(pins.map(\.target) == [
            .hostFiles(path: "~/notebook"),
            .files(workspace: "ws-1", path: "reports"),
            .file(.host, path: "~/Books/The Left Hand of Darkness.epub", line: nil),
            .hostFiles(path: "~/Documents"),
            .files(workspace: "ws-gone", path: nil),
            .hostFiles(path: "~/Volumes/Archive"),
            .session("2f6c1a9e-session"),
            .session("deleted-session"),
            .godot(project: "sword-lab-3fa9c2b1"),
            .godot(project: "tide-7c01d2e4"),
            .browser(try #require(URL(string: "https://docs.godotengine.org/en/stable/"))),
            .panel(session: "2f6c1a9e-session", id: "subagents"),
            .thread("7d1e-root"),
            .sessions(workspace: "ws-1"),
            .file(.workspace(id: "ws-1", worktree: "wt-feature"), path: "src/app.ts", line: 12),
        ])
        #expect(pins[1].label == "Reports")
        #expect(pins[8].name == "Sword Lab")
        #expect(pins[9].name == nil, "a gone game has no name")
        #expect(fixture.add.pinId == "pin_Reports00002")
        #expect(fixture.conflict.code == "revision_conflict")
        #expect(fixture.conflict.current == fixture.list)
    }

    /// The routes the app pins encode to the fixture's request bodies: every
    /// field of the kind, `null` where the link leaves it out.
    @Test func encodesTheRequestBodiesTheServerReads() throws {
        let raw = try Self.raw()
        let addRequests = try #require(raw["addRequests"] as? [[String: Any]])
        for request in addRequests {
            let target = try #require(request["target"] as? [String: Any])
            let decoded = try JSONDecoder().decode(PaneRoute.self, from: JSONSerialization.data(withJSONObject: target))
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? NSDictionary
            #expect(encoded == target as NSDictionary)
        }
        let reorder = try #require(raw["reorderRequest"] as? [String: Any])
        let entries = [PinOrderEntry(id: "pin_Reports00002", label: "Reports"), PinOrderEntry(id: "pin_Notebook0001", label: nil)]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entries)) as? NSArray
        #expect(encoded == reorder["pins"] as? NSArray, "an absent label is left out, not sent as null")
    }

    @Test func aStatusFromANewerServerReadsAsUnknown() throws {
        let json = #"{"revision":1,"pins":[{"id":"pin_Notebook0001","target":{"kind":"files","origin":"host","path":"~/n"},"createdAt":1,"status":"asleep"}]}"#
        let list = try JSONDecoder().decode(PinsList.self, from: Data(json.utf8))
        #expect(list.pins.first?.status == .unknown)
    }
}
