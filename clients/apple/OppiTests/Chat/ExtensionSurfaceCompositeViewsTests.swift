import Foundation
import Testing
import UIKit
@testable import Oppi

/// One hosted test per composite, in a real window at the drawer's inner width: identifiers,
/// native semantics, states, and nothing clipped at 320 pt or at an accessibility size.
@Suite("Composable extension surface views (UIKit)")
@MainActor
struct ExtensionSurfaceCompositeViewsTests {
    private let themeID = ThemeID.dark
    /// Windows stay alive for the length of a test: a released window drops its hierarchy.
    private static var windows: [UIWindow] = []

    // MARK: - Fixtures

    private func surface(_ name: String) throws -> ExtensionUISurface {
        try JSONDecoder().decode(ExtensionUISurface.self, from: ProtocolFixtures.data("surfaces/\(name)"))
    }

    /// A fixture in another strip group.
    private func surface(_ name: String, composablePlacement: String) throws -> ExtensionUISurface {
        let object = try JSONSerialization.jsonObject(with: try ProtocolFixtures.data("surfaces/\(name)"))
        var json = try testUnwrap(object as? [String: Any])
        json["placement"] = ["kind": "strip", "preferred": composablePlacement]
        return try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    /// A table fixture with only its first row.
    private func surface(_ name: String, keepingFirstRowOnly: Bool) throws -> ExtensionUISurface {
        let object = try JSONSerialization.jsonObject(with: try ProtocolFixtures.data("surfaces/\(name)"))
        var json = try testUnwrap(object as? [String: Any])
        var sections = try testUnwrap(json["sections"] as? [[String: Any]])
        var rows = try testUnwrap(sections[0]["rows"] as? [[String: Any]])
        rows = Array(rows.prefix(1))
        sections[0]["rows"] = rows
        json["sections"] = sections
        return try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    /// A fixture whose first card is in `kind` with the extension's own words.
    private func surface(
        _ name: String,
        revision: Int,
        state kind: String,
        title: String?,
        message: String?
    ) throws -> ExtensionUISurface {
        let data = try ProtocolFixtures.data("surfaces/\(name)")
        let object = try JSONSerialization.jsonObject(with: data)
        var json = try testUnwrap(object as? [String: Any])
        json["revision"] = revision
        var sections = try testUnwrap(json["sections"] as? [[String: Any]])
        var state: [String: Any] = ["kind": kind]
        if let title { state["title"] = title }
        if let message { state["message"] = message }
        sections[0]["state"] = state
        json["sections"] = sections
        return try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func pending(
        surfaceId: String = "deploy",
        compositeId: String = "status",
        actionId: String = "retry",
        revision: Int = 7,
        title: String? = "Retrying…",
        disabled: [String] = ["retry"]
    ) -> ExtensionSurfacePendingAction {
        ExtensionSurfacePendingAction(
            requestId: "action-1",
            surfaceId: surfaceId,
            compositeId: compositeId,
            actionId: actionId,
            rowId: nil,
            revision: revision,
            title: title,
            disabledActionIds: Set(disabled)
        )
    }

    // MARK: - statusCard

    @Test func statusCardDrawsItsPhaseStepsAndStepAtoms() throws {
        let surface = try surface("status-card.json")
        let view = composites(surface)

        let header = try testUnwrap(control("extension.surface.deploy.status", in: view))
        #expect(header.accessibilityValue == "running")
        #expect(header.accessibilityLabel?.contains("Deploying 4f2c1ab") == true)
        #expect(allLabelTexts(in: view).contains("Running"))

        // Steps are the activity rows, named under the card they belong to.
        let build = try testUnwrap(control("extension.surface.deploy.status.build", in: view))
        #expect(build.accessibilityValue?.contains("Done") == true)
        let test = try testUnwrap(control("extension.surface.deploy.status.test", in: view) as? UIControl)
        #expect(test.accessibilityValue?.contains("Working") == true)
        #expect(allLabelTexts(in: view).contains("Ship"))

        // A step with `extra` is a disclosure row: its atoms are built only while shown.
        #expect(test.accessibilityTraits.contains(.button))
        #expect(!allTexts(in: view).contains { $0.contains("214 passed") })
        test.sendActions(for: .touchUpInside)
        view.layoutIfNeeded()
        #expect(allTexts(in: view).contains { $0.contains("214 passed") })
    }

    // MARK: - checklist

    @Test func checklistDrawsItemsAndTheirDisclosure() throws {
        let surface = try surface("checklist.json")
        let view = composites(surface)

        let header = try testUnwrap(control("extension.surface.release.gates", in: view))
        #expect(header.accessibilityLabel?.contains("2 of 4 done") == true)

        let tests = try testUnwrap(control("extension.surface.release.gates.tests", in: view))
        #expect(tests.accessibilityValue?.contains("Done") == true)

        // An item with a detail discloses it; an item without one has nothing to disclose.
        let notes = try testUnwrap(control("extension.surface.release.gates.notes", in: view) as? UIControl)
        #expect(notes.accessibilityTraits.contains(.button))
        #expect(!allTexts(in: view).contains { $0.contains("Drafting") })
        notes.sendActions(for: .touchUpInside)
        view.layoutIfNeeded()
        #expect(allTexts(in: view).contains { $0.contains("Drafting") })

        let signoff = try testUnwrap(control("extension.surface.release.gates.signoff", in: view))
        #expect(!signoff.accessibilityTraits.contains(.button))
    }

    // MARK: - Identity

    @Test func identityKeysEscapeSoDistinctIdsNeverCollide() {
        // Deleting punctuation folded `table:sessions` and `table.sessions` together.
        #expect(ExtensionSurfaceIdentity.key("table:sessions") == "table_3asessions")
        #expect(ExtensionSurfaceIdentity.key("table.sessions") == "table_2esessions")
        // Case is identity, and an escaped underscore cannot be confused with an escaped byte.
        let raw = ["aB", "ab", "Ab", "a_b", "a b", "a.b", "a:b", "", "_"]
        let keys = raw.map(ExtensionSurfaceIdentity.key)
        #expect(Set(keys).count == raw.count, "two ids shared a key: \(keys)")
        #expect(keys.allSatisfy { !$0.contains(".") }, "a key must never split an identifier: \(keys)")
        // A dotted action id stays one segment of the identifier.
        #expect(
            ExtensionSurfaceIdentity.element(root: "extension.surface.query.rows", key: "a.b")
                == "extension.surface.query.rows.a_2eb"
        )
    }

    // MARK: - dataTable

    @Test func dataTableDrawsColumnsRowsSortAndRowActions() throws {
        let surface = try surface("data-table.json")
        var intents: [ExtensionSurfaceActionIntent] = []
        let view = composites(surface, onAction: { intents.append($0) })

        let header = try testUnwrap(control("extension.surface.query.rows", in: view))
        #expect(header.accessibilityValue == "2 rows")
        // The sorted column is marked in the grid.
        #expect(allLabelTexts(in: view).contains { $0.hasPrefix("Name ▴") })

        let sessions = try testUnwrap(control("extension.surface.query.rows.table_3asessions", in: view))
        #expect(sessions.accessibilityLabel?.contains("Name, sessions") == true)
        #expect(sessions.accessibilityLabel?.contains("Rows, 12") == true)
        #expect(sessions.accessibilityValue == "Selected")
        #expect(sessions.accessibilityTraits.contains(.button))

        // Row actions are on the row's menu, and activation runs the row's first action.
        let menu = try testUnwrap(control("extension.surface.query.rows.table_3asessions.menu", in: view) as? UIButton)
        #expect((menu.menu?.children ?? []).compactMap { ($0 as? UIAction)?.title } == ["Copy"])
        #expect(sessions.accessibilityActivate())
        #expect(intents.count == 1)
        #expect(intents.first?.compositeId == "rows")
        #expect(intents.first?.actionId == "copy")
        #expect(intents.first?.rowId == "table:sessions")
        #expect(intents.first?.revision == 2)
    }

    @Test(arguments: [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func tableHeaderAndRowShareOneColumnPlan(sizeCategory: UIContentSizeCategory) throws {
        let view = composites(try surface("data-table.json"), sizeCategory: sizeCategory)
        // The sorted column's title, and the same column's cell in the first row.
        let headerCell = try testUnwrap(allLabels(in: view).first { $0.text?.hasPrefix("Name") == true })
        let rowCell = try testUnwrap(allLabels(in: view).first { $0.text == "sessions" })
        let headerFrame = headerCell.convert(headerCell.bounds, to: view)
        let rowFrame = rowCell.convert(rowCell.bounds, to: view)
        #expect(
            abs(headerFrame.minX - rowFrame.minX) <= 0.5,
            "the header starts at \(headerFrame.minX) and the row cell at \(rowFrame.minX)"
        )
        #expect(
            abs(headerFrame.width - rowFrame.width) <= 0.5,
            "the header cell is \(headerFrame.width) wide and the row cell \(rowFrame.width)"
        )
    }

    @Test func aOneRowTableSaysOneRow() throws {
        let oneRow = try surface("data-table.json", keepingFirstRowOnly: true)
        let view = composites(oneRow)
        let header = try testUnwrap(control("extension.surface.query.rows", in: view))
        #expect(header.accessibilityValue == "1 row")

        let twoRows = try testUnwrap(control("extension.surface.query.rows", in: composites(try surface("data-table.json"))))
        #expect(twoRows.accessibilityValue == "2 rows")
    }

    @Test func aPendingActionOnlySpeaksForTheCardThatSentIt() throws {
        let surface = try surface("data-table.json")
        let waiting = composites(
            surface,
            pending: pending(
                surfaceId: "query",
                compositeId: "rows",
                actionId: "copy",
                title: "Copying…",
                disabled: ["copy"]
            )
        )
        let menu = try testUnwrap(control("extension.surface.query.rows.table_3asessions.menu", in: waiting) as? UIButton)
        #expect(menu.isEnabled, "one waiting action does not take the row's menu away")
        let copy = try testUnwrap(menu.menu?.children.compactMap { $0 as? UIAction }.first)
        #expect(copy.attributes.contains(.disabled), "the waiting action's own item is disabled")
        let row = try testUnwrap(control("extension.surface.query.rows.table_3asessions", in: waiting))
        #expect(!row.accessibilityActivate(), "a row whose first action is waiting does not run it again")

        // The same wait, from another card, leaves this table interactive.
        let elsewhere = composites(
            surface,
            pending: pending(
                surfaceId: "query",
                compositeId: "status",
                actionId: "copy",
                title: "Copying…",
                disabled: ["copy"]
            )
        )
        let idleMenu = try testUnwrap(control("extension.surface.query.rows.table_3asessions.menu", in: elsewhere) as? UIButton)
        let idleCopy = try testUnwrap(idleMenu.menu?.children.compactMap { $0 as? UIAction }.first)
        #expect(!idleCopy.attributes.contains(.disabled))
        #expect(idleMenu.isEnabled)
    }

    // MARK: - actionBar

    @Test func actionBarDrawsAPrimaryActionAndItsOtherActions() throws {
        let surface = try surface("action-bar.json")
        var intents: [ExtensionSurfaceActionIntent] = []
        let view = composites(surface, onAction: { intents.append($0) })

        let header = try testUnwrap(control("extension.surface.approval.decide", in: view))
        #expect(header.accessibilityLabel?.contains("Approve shipping 4f2c1ab?") == true)

        let approve = try testUnwrap(control("extension.surface.approval.decide.approve", in: view) as? UIButton)
        #expect(approve.configuration?.title == "Approve")
        #expect(approve.isEnabled)
        approve.sendActions(for: .touchUpInside)
        #expect(intents.map(\.actionId) == ["approve"])
        #expect(intents.first?.compositeId == "decide")
        #expect(intents.first?.revision == 1)

        let reject = try testUnwrap(control("extension.surface.approval.decide.reject", in: view) as? UIButton)
        #expect(reject.configuration?.title == "Reject")
    }

    // MARK: - Unknown composite

    @Test func unknownCompositeBecomesALabeledPlaceholderWithItsFallback() throws {
        let surface = try surface("unknown-composite.json")
        let view = composites(surface)

        // The card this build knows is drawn; the one it does not keeps its words.
        #expect(control("extension.surface.mixed.status", in: view) != nil)
        let placeholder = try testUnwrap(control("extension.surface.mixed.log", in: view))
        #expect(placeholder.accessibilityLabel?.contains("logStream") == true)
        #expect(placeholder.accessibilityValue == "Build log: 42 lines")
    }

    // MARK: - States

    @Test(arguments: zip(
        ["status-card.json", "checklist.json", "data-table.json", "action-bar.json"],
        ["status", "gates", "rows", "decide"]
    ))
    func everyCompositeDrawsItsStateWithTheExtensionsWords(file: String, composite: String) throws {
        // A loading state is the platform's one-line spinner caption; empty and failure carry the
        // extension's reason under its title.
        struct ExpectedState {
            let kind: String
            let word: String
            let title: String
            let message: String
            let secondary: String?
        }
        let cases = [
            ExpectedState(
                kind: "loading", word: "Loading",
                title: "Fetching rows", message: "This takes a moment.", secondary: nil
            ),
            ExpectedState(
                kind: "empty", word: "Empty",
                title: "No results", message: "Try another query.", secondary: "Try another query."
            ),
            ExpectedState(
                kind: "failure", word: "Failed",
                title: "Query failed", message: "The database is locked.", secondary: "The database is locked."
            ),
        ]
        for expected in cases {
            let surface = try surface(
                file,
                revision: 2,
                state: expected.kind,
                title: expected.title,
                message: expected.message
            )
            let view = composites(surface)
            let header = try testUnwrap(control("extension.surface.\(surface.id).\(composite)", in: view))
            #expect(header.accessibilityValue == expected.word)
            // The state is drawn by the platform's own unavailable view, in the extension's words.
            #expect(allLabelTexts(in: view).contains { $0.contains(expected.title) })
            let state = try testUnwrap(showingState(in: view))
            #expect(state.text == expected.title)
            #expect(state.secondaryText == expected.secondary)
            // Content is not drawn under a state.
            #expect(control("extension.surface.\(surface.id).\(composite).build", in: view) == nil)
        }
    }

    // MARK: - Pending

    @Test func pendingShowsItsDeclaredWordsAndDisablesTheIdsItNames() throws {
        let surface = try surface("status-card.json")
        let waiting = composites(surface, pending: pending())

        let retry = try testUnwrap(control("extension.surface.deploy.status.retry", in: waiting) as? UIButton)
        #expect(retry.configuration?.title == "Retrying…")
        #expect(!retry.isEnabled)

        // The same card with no pending action is back to the extension's words.
        let settled = composites(surface)
        let idle = try testUnwrap(control("extension.surface.deploy.status.retry", in: settled) as? UIButton)
        #expect(idle.configuration?.title == "Retry")
        #expect(idle.isEnabled)
    }

    // MARK: - Layout

    @Test(arguments: [
        "status-card.json",
        "checklist.json",
        "data-table.json",
        "action-bar.json",
        "unknown-composite.json",
    ])
    func nothingClipsAtThreeTwentyPointsOrAtAnAccessibilitySize(name: String) throws {
        let surface = try surface(name)
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let view = composites(surface, sizeCategory: category)
            let clipped = clippedText(in: view)
            #expect(clipped.isEmpty, "\(name) at \(category.rawValue) clips: \(clipped)")
            for button in subviews(of: UIButton.self, in: view) where !button.isHidden {
                #expect(
                    button.bounds.width + 1 >= button.intrinsicContentSize.width,
                    "\(name) at \(category.rawValue) squeezes a button: \(button.bounds.width) < \(button.intrinsicContentSize.width)"
                )
            }
        }
    }

    // MARK: - Strip

    @Test func theStripPillIsTheSurfaceHeaderAndOpensItsCards() throws {
        let surface = try surface("status-card.json")
        let panel = makePanel(surface)

        let pill = try testUnwrap(control("extension-strip-aboveEditor-pill-surface-deploy", in: panel) as? UIControl)
        #expect(pill.accessibilityLabel?.contains("web → prod") == true)
        #expect(pill.accessibilityValue?.contains("Deploying 4f2c1ab") == true)
        // Collapsed: the drawer's cards are not built yet.
        #expect(control("extension.surface.deploy.status", in: panel) == nil)

        pill.sendActions(for: .touchUpInside)
        panel.layoutIfNeeded()

        let header = try testUnwrap(control("extension.surface.deploy.status", in: panel))
        #expect(header.accessibilityValue == "running")
        #expect(control("extension.surface.deploy.status.build", in: panel) != nil)
        #expect(control("extension.surface.deploy.status.retry", in: panel) != nil)
    }

    @Test func aFailedSurfaceTakesTheDangerToneAndTheFailureWordsInThePill() throws {
        let surface = try surface(
            "status-card.json",
            revision: 8,
            state: "failure",
            title: "Deploy failed",
            message: "The gates did not pass."
        )
        let panel = makePanel(surface)

        // The pill carries the reason in the danger tone, whatever tone the cards declared; the
        // drawer is where the card's own state is drawn.
        let pill = try testUnwrap(control("extension-strip-aboveEditor-pill-surface-deploy", in: panel) as? UIControl)
        #expect(pill.accessibilityValue?.contains("The gates did not pass.") == true)
        let dot = try testUnwrap(toneDot(in: pill))
        #expect(dot.backgroundColor == themeID.palette.ui.red, "a failed surface wears the danger tone")

        pill.sendActions(for: .touchUpInside)
        panel.layoutIfNeeded()
        let header = try testUnwrap(control("extension.surface.deploy.status", in: panel))
        #expect(header.accessibilityValue == "Failed")
    }

    // MARK: - Footer gates

    @Test func aComposableSurfaceAloneShowsTheStripPillAndItsDrawer() async throws {
        let sessionId = "composable-strip"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: AppNavigation())
        chat.loadViewIfNeeded()
        defer {
            chat.sessionManager.cleanup()
            connection.disconnectStream()
        }
        connection.extensionSurfaces.apply(try surface("status-card.json"), sessionId: sessionId)

        // The real footer gate: the session holds no title, status, or v1 widget.
        let footer = ChatFooterAboveView(chat: chat)
        footer.updateProperties()
        show(footer, inset: 0)
        footer.updateProperties()

        let pill = try testUnwrap(
            control("extension-strip-aboveEditor-pill-surface-deploy", in: footer) as? UIControl
        )
        #expect(isShown(pill, in: footer), "a composable surface alone must show the strip")

        pill.sendActions(for: .touchUpInside)
        footer.layoutIfNeeded()
        let card = try testUnwrap(control("extension.surface.deploy.status", in: footer))
        #expect(isShown(card, in: footer), "the pill opens the surface's cards")
    }

    @Test func aBelowComposerSurfaceShowsUnderTheComposer() async throws {
        let sessionId = "composable-below"
        let (connection, _) = await makeTestConnection(sessionId: sessionId)
        connection.sessionStore.upsert(makeTestSession(id: sessionId, status: .ready))
        let chat = ChatViewController(sessionId: sessionId, connection: connection, navigation: AppNavigation())
        chat.loadViewIfNeeded()
        defer {
            chat.sessionManager.cleanup()
            connection.disconnectStream()
        }
        connection.extensionSurfaces.apply(
            try surface("status-card.json", composablePlacement: "belowComposer"),
            sessionId: sessionId
        )

        let footer = ChatFooterBelowView(chat: chat)
        footer.updateProperties()
        show(footer, inset: 0)
        footer.updateProperties()

        let pill = try testUnwrap(
            control("extension-strip-belowEditor-pill-surface-deploy", in: footer) as? UIControl
        )
        #expect(isShown(pill, in: footer), "belowComposer draws under the composer, not above it")
    }

    // MARK: - Helpers

    private func composites(
        _ surface: ExtensionUISurface,
        pending: ExtensionSurfacePendingAction? = nil,
        sizeCategory: UIContentSizeCategory = .large,
        onAction: ((ExtensionSurfaceActionIntent) -> Void)? = nil
    ) -> ExtensionSurfaceCompositesView {
        let view = ExtensionSurfaceCompositesView()
        view.traitOverrides.preferredContentSizeCategory = sizeCategory
        show(view)
        // Fonts are built while the views are created, so the category is current for `apply`.
        UITraitCollection(preferredContentSizeCategory: sizeCategory).performAsCurrent {
            view.apply(surface: surface, pending: pending, themeID: themeID, onAction: onAction)
            view.layoutIfNeeded()
        }
        return view
    }

    private func makePanel(_ surface: ExtensionUISurface) -> ExtensionSurfacePanelView {
        let state = ExtensionSurfaceState(composableSurfaces: [
            surface.id: ExtensionComposableSurfaceState(surface: surface, order: 1),
        ])
        let panel = ExtensionSurfacePanelView(
            placement: .aboveEditor,
            actions: ExtensionSurfaceDrawerActions(openReader: { _ in })
        )
        panel.apply(ExtensionSurfacePanelView.Content(
            surface: state,
            messageQueue: nil,
            themeID: themeID,
            collapseRequestID: 0
        ))
        show(panel, inset: 0)
        panel.layoutIfNeeded()
        return panel
    }

    /// Puts `view` in a real window at 320 pt, inset to the drawer's inner width. Each call closes
    /// the previous window so one test cannot read another's layout.
    private func show(_ view: UIView, inset: CGFloat = 28) {
        for window in Self.windows { window.isHidden = true }
        Self.windows.removeAll()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 1400))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.view.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor, constant: -inset),
        ])
        host.view.layoutIfNeeded()
        Self.windows.append(window)
    }

    private func control(_ identifier: String, in root: UIView) -> UIView? {
        ([root] + subviews(of: UIView.self, in: root)).first { $0.accessibilityIdentifier == identifier }
    }

    private func subviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        root.subviews.flatMap { child -> [T] in
            ((child as? T).map { [$0] } ?? []) + subviews(of: type, in: child)
        }
    }

    private func allLabels(in root: UIView) -> [UILabel] {
        subviews(of: UILabel.self, in: root)
    }

    /// The pill's tone dot: the leading swatch, the only 8 pt rounded view it carries.
    private func toneDot(in pill: UIView) -> UIView? {
        subviews(of: UIView.self, in: pill).first {
            $0.layer.cornerRadius == 4 && $0.bounds.width == 8 && $0.bounds.height == 8
        }
    }

    /// Whether every view between `view` and `root` is shown.
    private func isShown(_ view: UIView, in root: UIView) -> Bool {
        var current: UIView? = view
        while let node = current, node !== root {
            if node.isHidden { return false }
            current = node.superview
        }
        return current === root
    }

    private func allLabelTexts(in root: UIView) -> [String] {
        subviews(of: UILabel.self, in: root).compactMap(\.text)
    }

    /// Every string a card paints: labels, and the text views the block renderer uses for text
    /// atoms and checklist details.
    private func allTexts(in root: UIView) -> [String] {
        allLabelTexts(in: root) + subviews(of: UITextView.self, in: root).compactMap(\.text)
    }

    /// The state the visible unavailable view is showing, which is what the card handed it.
    private func showingState(in root: UIView) -> UIContentUnavailableConfiguration? {
        subviews(of: UIContentUnavailableView.self, in: root)
            .first { !$0.isHidden }?
            .configuration as? UIContentUnavailableConfiguration
    }

    /// Labels whose text does not fit the width they were given: the one clipping signal a hosted
    /// test can read without a capture.
    private func clippedText(in root: UIView) -> [String] {
        subviews(of: UILabel.self, in: root).compactMap { label in
            guard !label.isHidden, label.bounds.width > 0, let text = label.text, !text.isEmpty else {
                return nil
            }
            let needed = label.sizeThatFits(
                CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)
            )
            return needed.height > label.bounds.height + 1 ? text : nil
        }
    }
}
