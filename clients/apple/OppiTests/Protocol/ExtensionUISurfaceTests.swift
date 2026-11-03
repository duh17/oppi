import Foundation
import Testing
@testable import Oppi

/// Composable surface contract: the same `protocol/surfaces/` bytes the server's tests hold, so a
/// field the server writes and this build cannot read fails here rather than on a phone.
@Suite("ExtensionUI surfaces")
struct ExtensionUISurfaceTests {

    private func surface(_ name: String) throws -> ExtensionUISurface {
        try JSONDecoder().decode(ExtensionUISurface.self, from: ProtocolFixtures.data("surfaces/\(name)"))
    }

    private func json(_ name: String) throws -> [String: Any] {
        let data = try ProtocolFixtures.data("surfaces/\(name)")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func decodesTheStatusCardSurface() throws {
        let surface = try surface("status-card.json")
        #expect(surface.version == 2)
        #expect(surface.id == "deploy")
        #expect(surface.title == "Deploys")
        #expect(surface.placement.kind == "strip")
        #expect(surface.lifecycle == "persistent")
        #expect(surface.header.title == "web → prod")
        #expect(surface.revision == 7)
        #expect(surface.extensionDisplayName == "Deploy Helper")
        #expect(surface.actions["retry"]?.title == "Retry")
        #expect(surface.actions["retry"]?.isPrimary == true)
        #expect(surface.actions["retry"]?.pending?.title == "Retrying…")
        #expect(surface.actions["retry"]?.pending?.disabled == ["retry"])

        let section = try #require(surface.sections.first)
        guard case .statusCard(let status) = section else {
            Issue.record("Expected a status card")
            return
        }
        #expect(status.base.id == "status")
        #expect(status.phase == "running")
        #expect(status.base.tone == "warning")
        #expect(status.base.actions == ["retry", "openLog"])
        #expect(status.base.state.kind == "content")
        #expect(status.steps?.count == 3)
        #expect(status.steps?.first?.state == "success")
        let extra = try #require(status.steps?[1].extra)
        #expect(extra.count == 3)
        guard case .progress(let label, let value) = extra[0] else {
            Issue.record("Expected progress")
            return
        }
        #expect(label == "Tests")
        #expect(value == 0.4)
        #expect(extra[1] == .divider)
        guard case .text(let spans) = extra[2] else {
            Issue.record("Expected text")
            return
        }
        #expect(spans.first?.text == "214 passed")
        #expect(spans.first?.role == "success")
    }

    @Test func decodesTheChecklistSurface() throws {
        let surface = try surface("checklist.json")
        guard case .checklist(let card) = try #require(surface.sections.first) else {
            Issue.record("Expected a checklist")
            return
        }
        #expect(card.items.map(\.id) == ["tests", "review", "notes", "signoff"])
        #expect(card.items[2].detail == "Drafting")
        #expect(card.base.header.subtitle == "2 of 4 done")
        #expect(card.base.tone == "accent")
    }

    @Test func decodesTheDataTableSurface() throws {
        let surface = try surface("data-table.json")
        guard case .dataTable(let table) = try #require(surface.sections.first) else {
            Issue.record("Expected a data table")
            return
        }
        #expect(table.columns.map(\.id) == ["name", "type", "rows"])
        #expect(table.columns[2].isNumeric)
        #expect(table.rows.count == 2)
        #expect(table.rows[0].cell("name") == .text("sessions"))
        #expect(table.rows[0].cell("rows") == .number(12))
        #expect(table.rows[0].cell("missing") == .empty)
        #expect(table.rows[0].actions == ["copy"])
        #expect(table.sort?.columnId == "name")
        #expect(table.selectedRowId == "table:sessions")
        #expect(surface.offeredActionIds == ["copy"])
    }

    @Test func decodesTheActionBarOneShotSurface() throws {
        let surface = try surface("action-bar.json")
        #expect(surface.isOneShot)
        #expect(surface.timeoutAt == 1_739_750_700_000)
        guard case .actionBar(let bar) = try #require(surface.sections.first) else {
            Issue.record("Expected an action bar")
            return
        }
        #expect(bar.base.actions == ["approve", "reject"])
        #expect(surface.actions["reject"]?.isDestructive == true)
        #expect(surface.actions["approve"]?.pending?.disabled == ["approve", "reject"])
    }

    @Test func keepsAnUnknownCompositeAsAPlaceholderWithItsFallback() throws {
        let surface = try surface("unknown-composite.json")
        #expect(surface.sections.count == 2)
        guard case .statusCard = surface.sections[0] else {
            Issue.record("Expected the known card first")
            return
        }
        guard case .unsupported(let unknown) = surface.sections[1] else {
            Issue.record("Expected an unsupported placeholder")
            return
        }
        #expect(unknown.id == "log")
        #expect(unknown.composite == "logStream")
        #expect(unknown.fallback.text == "Build log: 42 lines")
        // A field this build has never heard of is ignored, never fatal.
        #expect(surface.revision == 4)
    }

    @Test func treatsACardThatFailsDecodingAsAPlaceholderNotAThrow() throws {
        var raw = try json("status-card.json")
        var sections = try #require(raw["sections"] as? [[String: Any]])
        sections[0].removeValue(forKey: "header")
        raw["sections"] = sections
        let data = try JSONSerialization.data(withJSONObject: raw)
        let surface = try JSONDecoder().decode(ExtensionUISurface.self, from: data)
        guard case .unsupported(let unknown) = try #require(surface.sections.first) else {
            Issue.record("Expected an unsupported placeholder")
            return
        }
        #expect(unknown.id == "status")
        #expect(unknown.fallback.text.contains("Deploying"))
    }

    @Test func keepsAKnownCompositeWhoseListsFailToDecodeAsAPlaceholder() throws {
        var table = try json("data-table.json")
        var tableSections = try #require(table["sections"] as? [[String: Any]])
        tableSections[0]["rows"] = "not a list"
        table["sections"] = tableSections
        let tableSurface = try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: try JSONSerialization.data(withJSONObject: table)
        )
        guard case .unsupported(let unknownTable) = try #require(tableSurface.sections.first) else {
            Issue.record("Expected an unsupported placeholder")
            return
        }
        #expect(unknownTable.id == "rows")
        #expect(unknownTable.composite == "dataTable")
        #expect(unknownTable.fallback.text == "Tables: sqlite_schema, sqlite_master")

        // A required list the build cannot read is the same as a composite it cannot draw: the
        // card keeps its words instead of decoding into an empty one.
        var checklist = try json("checklist.json")
        var checklistSections = try #require(checklist["sections"] as? [[String: Any]])
        checklistSections[0]["items"] = [["id": "tests"]]
        checklist["sections"] = checklistSections
        let checklistSurface = try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: try JSONSerialization.data(withJSONObject: checklist)
        )
        guard case .unsupported(let unknownChecklist) = try #require(checklistSurface.sections.first)
        else {
            Issue.record("Expected an unsupported placeholder")
            return
        }
        #expect(unknownChecklist.id == "gates")
        #expect(unknownChecklist.fallback.text == "2 of 4 gates done")
    }

    @Test func encodesTheCapabilitiesAClientDraws() throws {
        let message = ClientMessage.clientCapabilities(
            capabilities: ["extension-native-ui:v2:composites"],
            requestId: "capabilities-1"
        )
        let encoded = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(message)
        )
        let expected = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: ProtocolFixtures.data("surfaces/client-capabilities.json")
        )
        #expect(encoded == expected)
    }

    @Test func encodesASurfaceActionAndDecodesItsPatch() throws {
        let message = ClientMessage.extensionUIAction(
            surfaceId: "deploy",
            compositeId: "status",
            actionId: "retry",
            revision: 7,
            values: ["env": .string("prod")],
            requestId: "action-1"
        )
        let encoded = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(message)
        )
        let expected = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: ProtocolFixtures.data("surfaces/action.json")
        )
        #expect(encoded == expected)

        // A card action sends no row; a row action names the row it belongs to.
        #expect(encoded["rowId"] == nil)
        let rowAction = ClientMessage.extensionUIAction(
            surfaceId: "query",
            compositeId: "rows",
            actionId: "copy",
            rowId: "table:sessions",
            revision: 2
        )
        let rowJSON = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(rowAction)
        )
        #expect(rowJSON["rowId"] == .string("table:sessions"))

        let patch = try JSONDecoder().decode(
            ExtensionUISurfacePatch.self,
            from: ProtocolFixtures.data("surfaces/patch.json")
        )
        #expect(patch.surfaceId == "deploy")
        #expect(patch.revision == 8)
        #expect(patch.removed == false)
        #expect(patch.sessionId == "test-session-1")
        #expect(patch.patch?["sections.0.phase"] == .string("queued"))
    }

    @Test func decodesBothFramesAsServerMessages() throws {
        let messages = try #require(
            try JSONSerialization.jsonObject(with: ProtocolFixtures.data("server-messages.json"))
                as? [String: Any]
        )["messages"] as? [String: Any]
        let surfaceFrame = try #require(messages?["extension_ui_surface"])
        let decodedSurface = try JSONDecoder().decode(
            ServerMessage.self,
            from: try JSONSerialization.data(withJSONObject: surfaceFrame)
        )
        guard case .extensionUISurface(let surface, let sessionId) = decodedSurface else {
            Issue.record("Expected a surface frame")
            return
        }
        #expect(surface.id == "deploy")
        #expect(sessionId == "test-session-1")

        let patchFrame = try #require(messages?["extension_ui_patch"])
        let decodedPatch = try JSONDecoder().decode(
            ServerMessage.self,
            from: try JSONSerialization.data(withJSONObject: patchFrame)
        )
        guard case .extensionUIPatch(let patch) = decodedPatch else {
            Issue.record("Expected a patch frame")
            return
        }
        #expect(patch.surfaceId == "deploy")
        #expect(patch.revision == 8)
    }

    @Test func carriesTheRemovalOfASurface() throws {
        let frame: [String: Any] = [
            "type": "extension_ui_patch",
            "surfaceId": "deploy",
            "revision": 9,
            "removed": true,
            "sessionId": "test-session-1",
        ]
        let decoded = try JSONDecoder().decode(
            ServerMessage.self,
            from: try JSONSerialization.data(withJSONObject: frame)
        )
        guard case .extensionUIPatch(let patch) = decoded else {
            Issue.record("Expected a patch frame")
            return
        }
        #expect(patch.removed)
        #expect(patch.patch == nil)
    }
}
