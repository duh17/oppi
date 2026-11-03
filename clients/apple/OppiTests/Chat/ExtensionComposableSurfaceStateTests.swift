import Foundation
import Testing
@testable import Oppi

/// The client half of the composable surface loop: a surface replaces by id, a patch merges into
/// the surface the session holds, and a revision that is not above the stored one is a late frame.
@Suite("Composable surface state")
@MainActor
struct ExtensionComposableSurfaceStateTests {
    // MARK: - Fixtures

    private func surface(_ name: String) throws -> ExtensionUISurface {
        try JSONDecoder().decode(ExtensionUISurface.self, from: ProtocolFixtures.data("surfaces/\(name)"))
    }

    private func patch(_ name: String) throws -> ExtensionUISurfacePatch {
        try JSONDecoder().decode(
            ExtensionUISurfacePatch.self,
            from: ProtocolFixtures.data("surfaces/\(name)")
        )
    }

    /// A fixture with a new revision (and, when given, a new header title), as the server would
    /// publish it next.
    private func surface(_ name: String, revision: Int, headerTitle: String? = nil) throws -> ExtensionUISurface {
        let data = try ProtocolFixtures.data("surfaces/\(name)")
        let object = try JSONSerialization.jsonObject(with: data)
        var json = try testUnwrap(object as? [String: Any])
        json["revision"] = revision
        if let headerTitle {
            var header = try testUnwrap(json["header"] as? [String: Any])
            header["title"] = headerTitle
            json["header"] = header
        }
        return try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    /// A fixture whose first card is in `kind` with the extension's own words.
    private func surface(_ name: String, revision: Int, state kind: String, title: String?, message: String?) throws -> ExtensionUISurface {
        let data = try ProtocolFixtures.data("surfaces/\(name)")
        let object = try JSONSerialization.jsonObject(with: data)
        var json = try testUnwrap(object as? [String: Any])
        json["revision"] = revision
        var sections = try testUnwrap(json["sections"] as? [[String: Any]])
        sections[0]["state"] = ["kind": kind, "title": title ?? "", "message": message ?? ""]
        json["sections"] = sections
        return try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func patch(
        surfaceId: String,
        revision: Int,
        _ change: [String: JSONValue]? = nil,
        removed: Bool = false
    ) -> ExtensionUISurfacePatch {
        ExtensionUISurfacePatch(
            surfaceId: surfaceId,
            revision: revision,
            patch: change,
            removed: removed,
            sessionId: "s1"
        )
    }

    private func pending(revision: Int, requestId: String = "action-1") -> ExtensionSurfacePendingAction {
        ExtensionSurfacePendingAction(
            requestId: requestId,
            surfaceId: "deploy",
            compositeId: "status",
            actionId: "retry",
            rowId: nil,
            revision: revision,
            title: "Retrying…",
            disabledActionIds: ["retry"]
        )
    }

    // MARK: - Publish

    @Test func publishesASurfaceUnderItsIdForTheStrip() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        #expect(stored.surface.revision == 7)
        #expect(stored.surface.placement.kind == "strip")
        #expect(state.hasVisibleContent)
        #expect(state.composableSurfaceEntries(in: .aboveEditor).map(\.id) == ["deploy"])
        #expect(state.composableSurfaceEntries(in: .belowEditor).isEmpty)
    }

    @Test func replacesTheSameSurfaceInPlace() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        ExtensionSurfaceReducer.apply(try surface("checklist.json"), to: &state)
        ExtensionSurfaceReducer.apply(try surface("status-card.json", revision: 9, headerTitle: "web → staging"), to: &state)

        #expect(state.composableSurfaces.count == 2)
        #expect(state.composableSurfaceEntries(in: .aboveEditor).map(\.id) == ["deploy", "release"])
        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        #expect(stored.surface.revision == 9)
        #expect(stored.surface.header.title == "web → staging")
    }

    @Test func dropsAFrameAtOrBelowTheStoredRevision() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        ExtensionSurfaceReducer.apply(try surface("status-card.json", revision: 7, headerTitle: "stale"), to: &state)

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        #expect(stored.surface.header.title == "web → prod")
        #expect(stored.surface.revision == 7)
    }

    @Test func keepsASurfaceForAPresentationThisBuildDoesNotDrawOutOfTheStrip() throws {
        let data = try ProtocolFixtures.data("surfaces/status-card.json")
        let object = try JSONSerialization.jsonObject(with: data)
        var json = try testUnwrap(object as? [String: Any])
        json["placement"] = ["kind": "sheet"]
        let sheet = try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: JSONSerialization.data(withJSONObject: json)
        )

        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(sheet, to: &state)
        #expect(state.composableSurfaces["deploy"] != nil)
        #expect(!state.hasVisibleContent)
        #expect(state.composableSurfaceEntries(in: .aboveEditor).isEmpty)
    }

    // MARK: - Patch

    @Test func appliesTheWirePatchAtItsOwnRevision() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        ExtensionSurfaceReducer.apply(try patch("patch.json"), to: &state)

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        #expect(stored.surface.revision == 8)
        guard case .statusCard(let card) = try testUnwrap(stored.surface.sections.first) else {
            Issue.record("Expected the status card to survive the patch")
            return
        }
        // The fixture patches `sections.0.phase` and `sections.0.state` together.
        #expect(card.phase == "queued")
        #expect(card.base.state.kind == "content")
        #expect(card.steps?.count == 3)
    }

    @Test func aNullInAPatchRemovesTheField() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        ExtensionSurfaceReducer.apply(
            patch(surfaceId: "deploy", revision: 8, ["header.subtitle": .null]),
            to: &state
        )

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        #expect(stored.surface.header.subtitle == nil)
        #expect(stored.surface.header.title == "web → prod")
    }

    @Test func dropsAPatchThatDoesNotApplyWhole() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        // Past the end of the list, and a path that rewrites the surface's identity: both are
        // dropped whole, leaving the surface the person is reading untouched.
        ExtensionSurfaceReducer.apply(
            patch(surfaceId: "deploy", revision: 8, ["sections.9.phase": .string("queued")]),
            to: &state
        )
        ExtensionSurfaceReducer.apply(
            patch(surfaceId: "deploy", revision: 8, ["id": .string("other")]),
            to: &state
        )

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        #expect(stored.surface.id == "deploy")
        #expect(stored.surface.revision == 7)
    }

    @Test func dropsAPatchForASurfaceItDoesNotHold() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try patch("patch.json"), to: &state)
        #expect(state.composableSurfaces.isEmpty)
    }

    @Test func dropsAStalePatch() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json", revision: 8), to: &state)
        ExtensionSurfaceReducer.apply(try patch("patch.json"), to: &state)

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        #expect(stored.surface.revision == 8)
        guard case .statusCard(let card) = try testUnwrap(stored.surface.sections.first) else {
            Issue.record("Expected the status card")
            return
        }
        #expect(card.phase == "running")
    }

    @Test func aPatchMayCreateAFieldTheSurfaceDoesNotCarryYet() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        // `state.message` is absent from the fixture: the path names a field that does not exist.
        ExtensionSurfaceReducer.apply(
            patch(surfaceId: "deploy", revision: 8, ["sections.0.state.message": .string("Queued behind the lock")]),
            to: &state
        )

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        guard case .statusCard(let card) = try testUnwrap(stored.surface.sections.first) else {
            Issue.record("Expected the status card to survive the patch")
            return
        }
        #expect(card.base.state.message == "Queued behind the lock")
        #expect(stored.surface.revision == 8)
    }

    @Test func aNullOnAListEntryIsRefusedRatherThanLeavingAHole() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        ExtensionSurfaceReducer.apply(
            patch(surfaceId: "deploy", revision: 8, ["sections.0.steps.0": .null]),
            to: &state
        )

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        guard case .statusCard(let card) = try testUnwrap(stored.surface.sections.first) else {
            Issue.record("Expected the status card")
            return
        }
        #expect(stored.surface.revision == 7)
        #expect(card.steps?.map(\.id) == ["build", "test", "ship"])
    }

    @Test func aPathThatCrossesAValueIsRefused() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        // `header.title` is a string, so nothing can be written inside it.
        ExtensionSurfaceReducer.apply(
            patch(surfaceId: "deploy", revision: 8, ["header.title.extra": .string("x")]),
            to: &state
        )

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        #expect(stored.surface.revision == 7)
        #expect(stored.surface.header.title == "web → prod")
    }

    @Test func overlappingPathsAreRefusedWhole() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        // The server applies the frame's own key order, so one path inside another could land
        // differently on each side; this client drops such a frame instead of guessing.
        ExtensionSurfaceReducer.apply(
            patch(surfaceId: "deploy", revision: 8, [
                "sections.0": .object(["phase": .string("queued")]),
                "sections.0.phase": .string("failed"),
            ]),
            to: &state
        )

        let stored = try testUnwrap(state.composableSurfaces["deploy"])
        guard case .statusCard(let card) = try testUnwrap(stored.surface.sections.first) else {
            Issue.record("Expected the status card")
            return
        }
        #expect(stored.surface.revision == 7)
        #expect(card.phase == "running")
    }

    // MARK: - Removal

    @Test func removalDismissesTheSurfaceAndALateFrameStaysOut() throws {
        var state = ExtensionSurfaceState()
        ExtensionSurfaceReducer.apply(try surface("status-card.json"), to: &state)
        ExtensionSurfaceReducer.apply(patch(surfaceId: "deploy", revision: 8, removed: true), to: &state)
        #expect(state.composableSurfaces.isEmpty)
        #expect(!state.hasVisibleContent)

        ExtensionSurfaceReducer.apply(try surface("status-card.json", revision: 8), to: &state)
        #expect(state.composableSurfaces.isEmpty)

        // The server keeps revisions above the removal's, so the next publish is a new surface.
        ExtensionSurfaceReducer.apply(try surface("status-card.json", revision: 9), to: &state)
        #expect(state.composableSurfaces["deploy"]?.surface.revision == 9)
    }

    @Test func dismissalFloorsAreBoundedAndDropTheOldest() {
        var state = ExtensionSurfaceState()
        let limit = ExtensionSurfaceState.rememberedDismissalLimit
        for index in 0 ... limit {
            state.rememberDismissal(surfaceId: "surface-\(index)", revision: index)
        }

        #expect(state.dismissedComposableSurfaces.count == limit)
        // The oldest floor is gone and the newest still keeps a late frame out.
        #expect(state.dismissalRevision(for: "surface-0") == nil)
        #expect(state.dismissalRevision(for: "surface-\(limit)") == limit)
    }

    // MARK: - Store

    @Test func teardownClearsSurfacesAndPendingActions() throws {
        let store = ExtensionSurfaceStore()
        store.apply(try surface("status-card.json"), sessionId: "s1")
        store.beginAction(pending(revision: 7), sessionId: "s1")
        #expect(store.surface(for: "s1").layout.composableSurfaces["deploy"] != nil)
        #expect(store.surface(for: "s1").pendingAction != nil)

        store.clear(sessionId: "s1")
        #expect(store.surface(for: "s1").state.composableSurfaces.isEmpty)
        #expect(store.surface(for: "s1").pendingAction == nil)
        #expect(!store.surface(for: "s1").layout.hasRetainedContent)
    }

    @Test func aSettledRequestEndsThePendingAction() throws {
        let store = ExtensionSurfaceStore()
        store.apply(try surface("status-card.json"), sessionId: "s1")
        store.beginAction(pending(revision: 7), sessionId: "s1")

        store.settle(requestId: "another-request", sessionId: "s1")
        #expect(store.surface(for: "s1").pendingAction != nil)

        store.settle(requestId: "action-1", sessionId: "s1")
        #expect(store.surface(for: "s1").pendingAction == nil)
    }

    @Test func aNewerFrameForTheSurfaceEndsThePendingAction() throws {
        let store = ExtensionSurfaceStore()
        store.apply(try surface("status-card.json"), sessionId: "s1")
        store.beginAction(pending(revision: 7), sessionId: "s1")

        // The answer to the action: the same revision is not newer, the next one is.
        store.apply(try patch("patch.json"), sessionId: "s1")
        #expect(store.surface(for: "s1").pendingAction == nil)
        #expect(store.surface(for: "s1").layout.composableSurfaces["deploy"]?.surface.revision == 8)
    }

    // MARK: - Encoding

    @Test(arguments: [
        "status-card.json",
        "checklist.json",
        "data-table.json",
        "action-bar.json",
        "unknown-composite.json",
    ])
    func aSurfaceSurvivesTheRoundTripAPatchAppliesTo(name: String) throws {
        let surface = try surface(name)
        let data = try JSONEncoder().encode(surface)
        let decoded = try JSONDecoder().decode(ExtensionUISurface.self, from: data)
        #expect(decoded == surface)
    }
}
