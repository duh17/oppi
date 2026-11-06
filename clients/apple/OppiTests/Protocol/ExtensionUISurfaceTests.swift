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

    // MARK: - Blocks

    private func blocksSection(_ name: String) throws -> ExtensionUISurfaceBlocks {
        let surface = try surface(name)
        guard case .blocks(let blocks) = try #require(surface.sections.first) else {
            throw SurfaceFixtureError.notBlocks
        }
        return blocks
    }

    private enum SurfaceFixtureError: Error {
        case notBlocks
    }

    /// Every node the panel's tree draws, flattened so each kind is asserted where it belongs.
    private func nodes(in node: ExtensionUISurfaceNode) -> [ExtensionUISurfaceNode] {
        [node] + node.children.flatMap { nodes(in: $0) }
    }

    @Test func decodesAComposedPillAndEveryNodeKind() throws {
        let surface = try surface("blocks-panel.json")
        let pill = try #require(surface.pill)
        #expect(pill.tap == .drawer)
        #expect(pill.content.kind == "row")
        #expect(pill.children.map(\.kind) == ["icon", "text", "badge", "progress"])

        let blocks = try blocksSection("blocks-panel.json")
        #expect(blocks.id == "panel")
        #expect(blocks.header?.title == "Gates")
        #expect(blocks.tone == "accent")
        #expect(blocks.actions == ["refresh"])
        #expect(blocks.state.isContent)
        #expect(blocks.body.kind == "stack")

        let all = nodes(in: blocks.body)
        let kinds = Set(all.flatMap { [$0.kind] + ($0.actionIds.isEmpty ? [] : ["action"]) })
        for kind in [
            "row", "stack", "text", "markdown", "badge", "icon", "progress", "keyValue",
            "table", "chart", "code", "divider", "spacer", "button", "toggle", "menu",
        ] {
            #expect(kinds.contains(kind), "missing node kind \(kind)")
        }

        // A control keeps its own id, role, icon, and declared pending words.
        let retry = try #require(all.first { $0.id == "retry" })
        guard case .button(let button) = retry else {
            Issue.record("Expected the retry button")
            return
        }
        #expect(button.title == "Retry")
        #expect(button.isPrimary)
        #expect(button.icon == "arrow.clockwise")
        #expect(button.action?.id == "retry")
        #expect(button.action?.pending?.title == "Retrying…")

        // A toggle carries its own value; its tap sends the new one.
        let notify = try #require(all.first { $0.id == "notify" })
        guard case .toggle(let toggle) = notify else {
            Issue.record("Expected the notify toggle")
            return
        }
        #expect(toggle.value == false)
        #expect(toggle.action?.id == "notify")

        // A table row names the actions it offers, and the surface offers them all.
        let table = try #require(all.first { $0.id == "gates" })
        guard case .table(let grid) = table else {
            Issue.record("Expected the gates table")
            return
        }
        #expect(grid.columns == ["Gate", "State"])
        #expect(grid.rows.first?.id == "build")
        #expect(grid.rows.first?.cells == [.text("Build"), .text("passed")])
        #expect(grid.rows.first?.actions?.map(\.id) == ["copyRow", "openRow"])
        #expect(surface.offeredActionIds.isSuperset(of: ["retry", "notify", "copyRow", "openRow"]))

        // A menu offers its items' actions, with the role each item names.
        let overflow = try #require(all.first { $0.id == "overflow" })
        guard case .menu(let menu) = overflow else {
            Issue.record("Expected the overflow menu")
            return
        }
        #expect(menu.title == "More")
        #expect(menu.items.map(\.title) == ["Logs", "Cancel", "Filters"])
        #expect(menu.items[1].role == "destructive")
        #expect(menu.items.map(\.action.id) == ["openLog", "cancel", "filters"])

        // A progress node without a value is indeterminate, and a ring says so.
        let waiting = try #require(all.first { $0.id == "waiting" })
        guard case .progress(let progress) = waiting else {
            Issue.record("Expected the waiting progress")
            return
        }
        #expect(progress.value == nil)
        #expect(progress.isRing)
    }

    @Test func decodesAPillWhoseTapIsAnAction() throws {
        let surface = try surface("blocks-status.json")
        let pill = try #require(surface.pill)
        guard case .action(let action) = pill.tap else {
            Issue.record("Expected a pill action")
            return
        }
        #expect(action.id == "refresh")
        // The pill's own tap is one of the action ids the surface offers.
        #expect(surface.offeredActionIds.contains("refresh"))
        let blocks = try blocksSection("blocks-status.json")
        #expect(blocks.header == nil)
        #expect(blocks.body.kind == "stack")
        #expect(blocks.body.children.map(\.kind) == ["text", "text", "button"])
    }

    @Test func readsAPillWhoseTapKindIsNewerThanThisBuild() throws {
        var raw = try json("blocks-panel.json")
        var pill = try #require(raw["pill"] as? [String: Any])
        pill["tap"] = ["sheet": ["id": "openSheet"]]
        raw["pill"] = pill
        let surface = try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: try JSONSerialization.data(withJSONObject: raw)
        )
        // A tap kind this build has never heard of opens the drawer, and the frame stands.
        #expect(surface.pill?.tap == .drawer)
        #expect(surface.sections.count == 1)

        // Content the build cannot read costs the pill, never the surface.
        var broken = try json("blocks-panel.json")
        var brokenPill = try #require(broken["pill"] as? [String: Any])
        brokenPill["content"] = "not a row"
        broken["pill"] = brokenPill
        let withoutPill = try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: try JSONSerialization.data(withJSONObject: broken)
        )
        #expect(withoutPill.pill == nil)
        #expect(withoutPill.sections.count == 1)
    }

    @Test func decodesSelectionDisabledAndAGroup() throws {
        let surface = try surface("blocks-filters.json")
        let blocks = try blocksSection("blocks-filters.json")
        let all = nodes(in: blocks.body)
        let node = { (id: String) throws -> ExtensionUISurfaceNode in
            try #require(all.first { $0.id == id })
        }

        guard case .row(let active) = try node("active-row") else {
            Issue.record("Expected the active row")
            return
        }
        #expect(active.selected == true)
        #expect(active.action?.id == "clear")
        guard case .row(let archived) = try node("archived-row") else {
            Issue.record("Expected the archived row")
            return
        }
        #expect(archived.disabled == true)
        guard case .button(let allSegment) = try node("seg-all") else {
            Issue.record("Expected the All segment")
            return
        }
        #expect(allSegment.selected == true)
        guard case .button(let failedSegment) = try node("seg-failed") else {
            Issue.record("Expected the Failed segment")
            return
        }
        #expect(failedSegment.disabled == true)
        guard case .badge(let selectedBadge) = try node("badge-selected") else {
            Issue.record("Expected the selected badge")
            return
        }
        #expect(selectedBadge.selected == true)
        #expect(selectedBadge.icon == "cloud")
        guard case .badge(let disabledBadge) = try node("badge-disabled") else {
            Issue.record("Expected the disabled badge")
            return
        }
        #expect(disabledBadge.disabled == true)
        guard case .stack(let locked) = try node("locked") else {
            Issue.record("Expected the locked stack")
            return
        }
        #expect(locked.disabled == true)
        guard case .toggle(let toggle) = try node("notify-toggle") else {
            Issue.record("Expected the disabled toggle")
            return
        }
        #expect(toggle.disabled == true)
        guard case .menu(let menu) = try node("groupby") else {
            Issue.record("Expected the disabled menu")
            return
        }
        #expect(menu.disabled == true)
        // A disabled node still names the verbs it would offer.
        #expect(surface.offeredActionIds.isSuperset(of: ["apply", "clear", "group"]))

        // A group is a titled region with its own children, folded or not.
        let panel = try blocksSection("blocks-panel.json")
        guard case .group(let group) = try #require(
            nodes(in: panel.body).first(where: { $0.kind == "group" })
        ) else {
            Issue.record("Expected the filters group")
            return
        }
        #expect(group.title == "Filters")
        #expect(group.collapsed == false)
        #expect(group.children.count == 1)
        #expect(nodes(in: group.children[0]).map(\.id) == [
            "filter-set", "filter-all", "filter-running", "filter-archived",
        ])
        guard case .text(let selectedFilter) = try #require(
            nodes(in: group.children[0]).first(where: { $0.id == "filter-all" })
        ) else {
            Issue.record("Expected the selected filter")
            return
        }
        // `false` and `true` are both states: neither may be lost on the way in.
        #expect(selectedFilter.selected == true)
        #expect(selectedFilter.disabled == nil)
    }

    @Test func keepsANodeKindThisBuildCannotDrawWithItsWords() throws {
        let surface = try surface("blocks-unknown-node.json")
        guard case .blocks(let blocks) = try #require(surface.sections.first) else {
            Issue.record("Expected a blocks section")
            return
        }
        let all = nodes(in: blocks.body)
        #expect(all.map(\.kind).contains("webview"))
        guard case .unsupported(let unknown) = try #require(all.first(where: { $0.id == "canvas" }))
        else {
            Issue.record("Expected an unsupported node")
            return
        }
        #expect(unknown.type == "webview")
        // The frame still decodes whole: a newer server never costs this build the section.
        #expect(blocks.fallback.text == "A panel this build cannot draw")
    }

    @Test func decodesAnElapsedNodeInThePillAndTheBodyAndCountsFromItsStart() throws {
        let surface = try surface("blocks-elapsed.json")
        let pill = try #require(surface.pill)
        guard case .elapsed(let ticking) = try #require(pill.children.last) else {
            Issue.record("Expected an elapsed node in the pill")
            return
        }
        #expect(ticking.since == 1_790_000_000_000)
        #expect(ticking.style == "mono")
        #expect(ticking.tone == "warning")
        guard case .blocks(let blocks) = try #require(surface.sections.first),
              case .elapsed(let short) = try #require(blocks.body.children.last)
        else {
            Issue.record("Expected an elapsed node in the body")
            return
        }
        #expect(short.base.id == "job-elapsed")
        #expect(short.isShort)

        let start = ticking.date
        #expect(ticking.text(at: start.addingTimeInterval(42)) == "0:42")
        #expect(ticking.text(at: start.addingTimeInterval(65)) == "1:05")
        #expect(ticking.text(at: start.addingTimeInterval(3600 + 5 * 60 + 10)) == "1:05:10")
        #expect(ticking.text(at: start.addingTimeInterval(-30)) == "0:00", "a start in the future reads zero")
        #expect(short.text(at: start.addingTimeInterval(42)) == "42s")
        #expect(short.text(at: start.addingTimeInterval(5 * 60 + 59)) == "5m")
        #expect(short.text(at: start.addingTimeInterval(3600 + 5 * 60)) == "1h 5m")
        #expect(short.text(at: start.addingTimeInterval(7200)) == "2h")

        let again = try JSONDecoder().decode(ExtensionUISurface.self, from: JSONEncoder().encode(surface))
        #expect(again == surface)
    }

    @Test func roundTripsATreeThroughEncoding() throws {
        // The patch applier re-encodes a surface and decodes it again, so encoding has to be
        // as complete as decoding: a field the wire carries must survive the round trip.
        for name in ["blocks-panel.json", "blocks-filters.json"] {
            let surface = try surface(name)
            let encoded = try JSONEncoder().encode(surface)
            let decoded = try JSONDecoder().decode(ExtensionUISurface.self, from: encoded)
            #expect(decoded == surface, "\(name)")
        }
    }

    @Test func encodesANodeActionAndAppliesAPatchIntoABody() throws {
        let action = ClientMessage.extensionUIAction(
            surfaceId: "blocks-panel",
            compositeId: "panel",
            actionId: "notify",
            nodeId: "notify",
            revision: 7,
            values: ["value": .bool(true)],
            requestId: "blocks-action-1"
        )
        let encodedAction = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: JSONEncoder().encode(action)
        )
        let expectedAction = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: ProtocolFixtures.data("surfaces/blocks-action.json")
        )
        #expect(encodedAction == expectedAction)

        // A patch into a body lands by child index and by node id, the way the server merged it.
        let patch = try JSONDecoder().decode(
            ExtensionUISurfacePatch.self,
            from: ProtocolFixtures.data("surfaces/blocks-patch.json")
        )
        let surface = try surface("blocks-panel.json")
        let patchBody = try #require(patch.patch)
        let merged = try #require(
            ExtensionSurfacePatchApplier.apply(patchBody, to: surface, revision: patch.revision)
        )
        guard case .blocks(let blocks) = try #require(merged.sections.first) else {
            Issue.record("Expected a blocks section")
            return
        }
        let all = nodes(in: blocks.body)
        guard case .progress(let progress) = try #require(all.first { $0.id == "progress" }) else {
            Issue.record("Expected the progress node")
            return
        }
        #expect(progress.value == 0.7)
        guard case .badge(let state) = try #require(all.first { $0.id == "state" }) else {
            Issue.record("Expected the state badge")
            return
        }
        #expect(state.text == "3 of 4")
        guard case .table(let grid) = try #require(all.first { $0.id == "gates" }) else {
            Issue.record("Expected the gates table")
            return
        }
        #expect(grid.rows.first?.cells == [.text("Build"), .text("running")])
        #expect(merged.revision == patch.revision)
    }

    @Test func refusesABodyPatchThatNamesNoNode() throws {
        let surface = try surface("blocks-panel.json")
        let merged = ExtensionSurfacePatchApplier.apply(
            ["sections.0.body.children.#ghost.text": .string("x")],
            to: surface,
            revision: 8
        )
        #expect(merged == nil)
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
