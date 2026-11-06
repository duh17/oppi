import Foundation
import Testing
import UIKit
@testable import Oppi

/// A `blocks` section's tree of primitives, drawn in a real window at the drawer's inner width:
/// every node kind, the identifiers protocol ids name, native semantics for each control, and
/// nothing clipped at 320 pt or at an accessibility size.
@Suite("Composable extension surface blocks (UIKit)")
@MainActor
struct ExtensionSurfaceBlocksViewsTests {
    private let themeID = ThemeID.dark
    /// Windows stay alive for the length of a test: a released window drops its hierarchy.
    private static var windows: [UIWindow] = []

    // MARK: - Fixtures

    private func surface(_ name: String) throws -> ExtensionUISurface {
        try JSONDecoder().decode(ExtensionUISurface.self, from: ProtocolFixtures.data("surfaces/\(name)"))
    }

    /// The named fixture with one JSON edit, for the trees the wire allows and no shipped surface
    /// carries: a second node offering one action, a badge nobody would want in a screenshot.
    private func surface(
        _ name: String,
        mutating edit: (inout [String: Any]) throws -> Void
    ) throws -> ExtensionUISurface {
        var object = testUnwrap(
            try JSONSerialization.jsonObject(with: try ProtocolFixtures.data("surfaces/\(name)"))
                as? [String: Any]
        )
        try edit(&object)
        return try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    /// The panel's controls with a second button offering the same action as `retry`: two nodes of
    /// one section may name one action, and only the one that sent it is waiting.
    private func panelWithTwinRetry() throws -> ExtensionUISurface {
        try surface("blocks-panel.json") { object in
            var sections = testUnwrap(object["sections"] as? [[String: Any]])
            var body = testUnwrap(sections[0]["body"] as? [String: Any])
            var children = testUnwrap(body["children"] as? [[String: Any]])
            let actionsIndex = try #require(children.firstIndex { $0["id"] as? String == "actions" })
            var actionsRow = try #require(children[actionsIndex] as? [String: Any])
            var rowChildren = try #require(actionsRow["children"] as? [[String: Any]])
            let controlsIndex = try #require(rowChildren.firstIndex { $0["id"] as? String == "controls" })
            var controls = try #require(rowChildren[controlsIndex]["children"] as? [[String: Any]])
            controls.append([
                "type": "button",
                "id": "retry-again",
                "title": "Retry again",
                "action": ["id": "retry"],
            ])
            rowChildren[controlsIndex]["children"] = controls
            actionsRow["children"] = rowChildren
            children[actionsIndex] = actionsRow
            body["children"] = children
            sections[0]["body"] = body
            object["sections"] = sections
        }
    }

    /// The panel with its filters group published folded, which is what a reader first gets.
    private func panelWithFoldedGroup() throws -> ExtensionUISurface {
        try surface("blocks-panel.json") { object in
            var sections = testUnwrap(object["sections"] as? [[String: Any]])
            var body = testUnwrap(sections[0]["body"] as? [String: Any])
            var children = testUnwrap(body["children"] as? [[String: Any]])
            let index = try #require(children.firstIndex { $0["id"] as? String == "filters" })
            var group = try #require(children[index] as? [String: Any])
            group["collapsed"] = true
            children[index] = group
            body["children"] = children
            sections[0]["body"] = body
            object["sections"] = sections
        }
    }

    /// The identifier a node's own id earns under its section.
    private func node(_ surfaceId: String, _ sectionId: String, _ id: String) -> String {
        ExtensionSurfaceIdentity.element(
            root: ExtensionSurfaceIdentity.composite(surfaceId: surfaceId, compositeId: sectionId),
            key: id
        )
    }

    private func pending(
        compositeId: String = "panel",
        actionId: String,
        nodeId: String?,
        title: String?,
        disabled: [String]
    ) -> ExtensionSurfacePendingAction {
        ExtensionSurfacePendingAction(
            requestId: "action-1",
            surfaceId: "blocks-panel",
            compositeId: compositeId,
            actionId: actionId,
            rowId: nil,
            nodeId: nodeId,
            revision: 7,
            title: title,
            disabledActionIds: Set(disabled)
        )
    }

    // MARK: - Nodes

    @Test func everyNodeKindDrawsWithItsIdentifiersAndWords() throws {
        let surface = try surface("blocks-panel.json")
        let view = composites(surface)

        // The card's own header, then each kind in draw order.
        let header = try testUnwrap(control(node("blocks-panel", "panel", "body"), in: view))
        #expect(header.accessibilityIdentifier == "extension.surface.blocks_2dpanel.panel.body")
        #expect(control("extension.surface.blocks_2dpanel.panel.phase", in: view) != nil)

        let texts = allLabelTexts(in: view) + allTexts(in: view)
        for word in ["Deploying 4f2c1ab", "2 of 4", "Tests", "Env", "prod", "4f2c1ab", "make test"] {
            #expect(texts.contains { $0.contains(word) }, "the tree did not draw \(word): \(texts)")
        }
        // A markdown node reuses the chat's renderer, so its words arrive as rendered text.
        #expect(allTexts(in: view).contains { $0.contains("Two gates remain") })

        // Every primitive with an id is named from the protocol id, under its section.
        for id in [
            "phase", "state", "progress", "waiting", "facts", "notes", "gates",
            "durations", "tail", "rule", "gap", "hammer", "controls", "retry", "notify", "overflow",
            "logs-link",
        ] {
            #expect(control(node("blocks-panel", "panel", id), in: view) != nil, "no node \(id)")
        }

        // The table keeps the dataTable's row element and row menu, under the node that draws it.
        let gates = node("blocks-panel", "panel", "gates")
        let build = try testUnwrap(control("\(gates).build", in: view))
        #expect(build.accessibilityLabel?.contains("Build") == true)
        #expect(build.accessibilityLabel?.contains("passed") == true)
        #expect(build.accessibilityTraits.contains(.button))
        let menu = try testUnwrap(control("\(gates).build.menu", in: view) as? UIButton)
        #expect(menu.menu?.children.compactMap { ($0 as? UIAction)?.title } == ["Copy", "Open"])
    }

    @Test func anUnknownNodeKeepsItsLabelAndItsSiblingsStillDraw() throws {
        let surface = try surface("blocks-unknown-node.json")
        let view = composites(surface)

        #expect(allLabelTexts(in: view).contains { $0.contains("This part is known") })
        let placeholder = try testUnwrap(control(node("blocks-future", "future", "canvas"), in: view))
        #expect(placeholder.accessibilityLabel?.contains("webview") == true)
    }

    // MARK: - Geometry

    @Test func aDividerDrawsAHairlineAcrossTheBody() throws {
        let view = composites(try surface("blocks-panel.json"))
        let rule = try testUnwrap(control(node("blocks-panel", "panel", "rule"), in: view))
        // A column lays its children out leading-aligned: a divider that does not fill the column
        // keeps its own width of zero and draws nothing at all.
        #expect(rule.bounds.width > 0.5, "the divider draws no width: \(rule.bounds)")
        #expect(rule.bounds.width >= cardInnerWidth(in: view) - 0.5, "the rule stops short of the card: \(rule.bounds)")
        let hairline = 1 / max(1, rule.traitCollection.displayScale)
        #expect(abs(rule.bounds.height - hairline) <= 0.5, "the rule is \(rule.bounds.height) tall")
        // And it paints: a line of the card's own ink, which a person can see. The host's separator
        // follows the device's appearance instead, so over a dark theme it drew within a couple of
        // levels of the card beneath it — a rule nobody could find.
        let card = try testUnwrap(subviews(of: ExtensionSurfaceCompositeCardView.self, in: view).first)
        let ink = try testUnwrap(rule.backgroundColor)
        let fill = (card.backgroundColor ?? .clear).over(themeID.palette.ui.bg)
        let drawn = ink.over(fill)
        let contrast = (max(drawn.relativeLuminance, fill.relativeLuminance) + 0.05)
            / (min(drawn.relativeLuminance, fill.relativeLuminance) + 0.05)
        #expect(contrast > 1.2, "the rule sits within \(contrast) of the card it is drawn on")
    }

    @Test func aRingPaintsItsLabelBesideIt() throws {
        let view = composites(try surface("blocks-panel.json"))
        let ring = try testUnwrap(control(node("blocks-panel", "panel", "waiting"), in: view))
        let words = try #require(allLabels(in: ring).first { $0.text == "Retrying" }, "the ring painted no label")
        let glyph = try #require(
            subviews(of: UIView.self, in: ring).first { abs($0.bounds.width - 16) < 1 && !$0.isHidden },
            "the ring drew no glyph"
        )
        // Beside, not under: the words start after the ring and share its centre line.
        #expect(words.convert(words.bounds, to: ring).minX >= 16, "the label starts on top of the ring")
        let wordsCentre = words.convert(words.bounds, to: ring).midY
        let glyphCentre = glyph.convert(glyph.bounds, to: ring).midY
        #expect(abs(wordsCentre - glyphCentre) < 4, "the label sits on another line: \(wordsCentre) vs \(glyphCentre)")
    }

    // MARK: - Key/value

    @Test func keyValueRowsAreReusedAndValuesShareOneColumn() throws {
        let surface = try surface("blocks-panel.json")
        let view = composites(surface)
        let facts = try testUnwrap(control(node("blocks-panel", "panel", "facts"), in: view))
        let before = allLabels(in: facts)
        #expect(before.count == 4, "two pairs, two labels each: \(before.count)")

        // A republish rewrites the rows it already has instead of building new ones.
        view.apply(surface: surface, pending: nil, themeID: themeID, onAction: nil)
        view.layoutIfNeeded()
        let after = allLabels(in: facts)
        #expect(after.count == before.count)
        #expect(zip(before, after).allSatisfy { $0.0 === $0.1 }, "the key/value rows were rebuilt")

        let frames = after.map { $0.convert($0.bounds, to: facts) }
        let keys = stride(from: 0, to: frames.count, by: 2).map { frames[$0] }
        let values = stride(from: 1, to: frames.count, by: 2).map { frames[$0] }
        // One column: every value starts where the widest key ends.
        #expect(abs(values[0].minX - values[1].minX) <= 0.5, "the values do not line up: \(values.map(\.minX))")
        #expect(abs(keys[0].width - keys[1].width) <= 0.5, "the keys are not one column: \(keys.map(\.width))")
        #expect(values[0].minX > keys[0].maxX - 0.5, "the value overlaps its own key")
    }

    // MARK: - Buttons and pending

    @Test func aButtonTapSendsItsNodeAndTheDeclaredPendingShowsThenSettles() throws {
        let surface = try surface("blocks-panel.json")
        var intents: [ExtensionSurfaceActionIntent] = []
        let view = composites(surface, onAction: { intents.append($0) })

        let retry = try testUnwrap(control(node("blocks-panel", "panel", "retry"), in: view) as? UIButton)
        #expect(retry.configuration?.title == "Retry")
        retry.sendActions(for: .touchUpInside)
        #expect(intents.count == 1)
        #expect(intents.first?.compositeId == "panel")
        #expect(intents.first?.nodeId == "retry")
        #expect(intents.first?.actionId == "retry")
        #expect(intents.first?.revision == 7)
        #expect(intents.first?.pending?.title == "Retrying…")

        // The wait shows on the node that offered the action, and disables what it named.
        let waiting = composites(
            surface,
            pending: pending(actionId: "retry", nodeId: "retry", title: "Retrying…", disabled: ["retry"])
        )
        let busy = try testUnwrap(control(node("blocks-panel", "panel", "retry"), in: waiting) as? UIButton)
        #expect(busy.configuration?.title == "Retrying…")
        #expect(!busy.isEnabled)
        #expect(
            (control(node("blocks-panel", "panel", "notify"), in: waiting) as? UISwitch)?.isEnabled == true,
            "one waiting node does not disable a different control"
        )

        // Settled: the extension's own words are back and the control works again.
        let settled = composites(surface)
        let idle = try testUnwrap(control(node("blocks-panel", "panel", "retry"), in: settled) as? UIButton)
        #expect(idle.configuration?.title == "Retry")
        #expect(idle.isEnabled)
    }

    @Test func aWaitBelongsToTheNodeThatSentIt() throws {
        let waiting = composites(
            try panelWithTwinRetry(),
            pending: pending(actionId: "retry", nodeId: "retry", title: "Retrying…", disabled: ["retry"])
        )
        let sender = try testUnwrap(control(node("blocks-panel", "panel", "retry"), in: waiting) as? UIButton)
        let twin = try testUnwrap(control(node("blocks-panel", "panel", "retry-again"), in: waiting) as? UIButton)
        #expect(sender.configuration?.title == "Retrying…")
        #expect(!sender.isEnabled)
        #expect(twin.configuration?.title == "Retry again", "a node that did not send the action keeps its words")
        // One action is in flight: the twin does not offer it a second time either.
        #expect(!twin.isEnabled, "the twin offered an action that is already waiting")
        #expect(twin.accessibilityLabel == "Retry again")
    }

    // MARK: - Toggle

    @Test func aToggleSendsItsNewValueAndRevertsToTheServersValueWhenNothingSettlesIt() throws {
        let surface = try surface("blocks-panel.json")
        var intents: [ExtensionSurfaceActionIntent] = []
        let view = composites(surface, onAction: { intents.append($0) })

        let toggle = try testUnwrap(control(node("blocks-panel", "panel", "notify"), in: view) as? UISwitch)
        #expect(!toggle.isOn, "the switch starts at the value the server published")
        #expect(toggle.accessibilityLabel == "Notify on failure")
        toggle.setOn(true, animated: false)
        toggle.sendActions(for: .valueChanged)
        #expect(intents.count == 1)
        #expect(intents.first?.nodeId == "notify")
        #expect(intents.first?.actionId == "notify")
        #expect(intents.first?.values == ["value": .bool(true)])

        // The round trip failed: no frame arrived, so the surface still says false and the switch
        // goes back to it rather than keeping a value the server never accepted.
        let reverted = composites(surface)
        let afterFailure = try testUnwrap(control(node("blocks-panel", "panel", "notify"), in: reverted) as? UISwitch)
        #expect(!afterFailure.isOn)
    }

    @Test func aToggleKeepsThePositionItWasGivenWhileItsActionIsInFlight() throws {
        let surface = try surface("blocks-panel.json")
        let inFlight = pending(actionId: "notify", nodeId: "notify", title: nil, disabled: [])
        let view = composites(surface, pending: inFlight)
        let toggle = try testUnwrap(control(node("blocks-panel", "panel", "notify"), in: view) as? UISwitch)

        // The person moved it. The repaint that the sent action causes still reads the published
        // value, so this frame must leave the switch where the person put it.
        toggle.setOn(true, animated: false)
        view.apply(surface: surface, pending: inFlight, themeID: themeID, onAction: nil)
        view.layoutIfNeeded()
        let waiting = try testUnwrap(control(node("blocks-panel", "panel", "notify"), in: view) as? UISwitch)
        #expect(waiting === toggle, "the switch was rebuilt instead of repainted")
        #expect(toggle.isOn, "the switch snapped back to the published value while its action waited")
        #expect(!toggle.isEnabled, "a waiting switch does not offer the same action twice")

        // Settled: the published value is the truth again, and the control answers.
        view.apply(surface: surface, pending: nil, themeID: themeID, onAction: nil)
        view.layoutIfNeeded()
        #expect(!toggle.isOn)
        #expect(toggle.isEnabled)
    }

    @Test func aToggleSpeaksItsTitleOnce() throws {
        let view = composites(try surface("blocks-panel.json"))
        let toggle = try testUnwrap(control(node("blocks-panel", "panel", "notify"), in: view) as? UISwitch)
        #expect(toggle.accessibilityLabel == "Notify on failure")
        let holder = try testUnwrap(toggle.superview?.superview)
        let painted = try testUnwrap(allLabels(in: holder).first { $0.text == "Notify on failure" })
        #expect(!painted.isAccessibilityElement, "the title is a second VoiceOver stop beside the switch")
    }

    // MARK: - Menu

    @Test func aMenuItemSendsTheActionItNames() throws {
        let surface = try surface("blocks-panel.json")
        var intents: [ExtensionSurfaceActionIntent] = []
        let view = composites(surface, onAction: { intents.append($0) })

        let overflow = try testUnwrap(control(node("blocks-panel", "panel", "overflow"), in: view) as? UIButton)
        let items = try testUnwrap(overflow.menu?.children.compactMap { $0 as? UIAction })
        #expect(items.map(\.title) == ["Logs", "Cancel", "Filters"])
        #expect(items[1].attributes.contains(.destructive), "a destructive item wears the role")
        items[0].performWithSender(nil, target: nil)
        #expect(intents.map(\.actionId) == ["openLog"])
        #expect(intents.first?.nodeId == "overflow")
    }

    // MARK: - Tappable region

    @Test func aTappableTextIsAButtonForTouchAndForAssistiveActivation() throws {
        let surface = try surface("blocks-panel.json")
        var intents: [ExtensionSurfaceActionIntent] = []
        let view = composites(surface, onAction: { intents.append($0) })

        let link = try testUnwrap(control(node("blocks-panel", "panel", "logs-link"), in: view) as? UIControl)
        #expect(link.accessibilityTraits.contains(.button))
        #expect(link.accessibilityLabel == "Open logs")
        #expect(link.accessibilityActivate())
        link.sendActions(for: .touchUpInside)
        #expect(intents.map(\.nodeId) == ["logs-link", "logs-link"])
        #expect(intents.map(\.actionId) == ["openLog", "openLog"])
    }

    @Test func aTappableRowIsOneButtonElementCarryingItsChildrensWords() throws {
        var intents: [ExtensionSurfaceActionIntent] = []
        let json = try JSONSerialization.jsonObject(with: try ProtocolFixtures.data("surfaces/blocks-panel.json"))
        var object = testUnwrap(json as? [String: Any])
        var sections = testUnwrap(object["sections"] as? [[String: Any]])
        var body = testUnwrap(sections[0]["body"] as? [String: Any])
        var children = testUnwrap(body["children"] as? [[String: Any]])
        // The headline row becomes a tappable region.
        children[0]["action"] = ["id": "openLog"]
        body["children"] = children
        sections[0]["body"] = body
        object["sections"] = sections
        let tappable = try JSONDecoder().decode(
            ExtensionUISurface.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let view = composites(tappable, onAction: { intents.append($0) })

        let row = try testUnwrap(control(node("blocks-panel", "panel", "headline"), in: view) as? UIControl)
        #expect(row.accessibilityTraits.contains(.button))
        #expect(row.accessibilityLabel?.contains("Deploying 4f2c1ab") == true)
        #expect(row.accessibilityActivate())
        #expect(intents.map(\.nodeId) == ["headline"])
        #expect(intents.map(\.actionId) == ["openLog"])
    }

    @Test func aTappableRegionHonoursTheWaitingActionsDisableList() throws {
        var intents: [ExtensionSurfaceActionIntent] = []
        let waiting = composites(
            try surface("blocks-panel.json"),
            pending: pending(actionId: "retry", nodeId: "retry", title: "Retrying…", disabled: ["openLog"]),
            onAction: { intents.append($0) }
        )
        let link = try testUnwrap(control(node("blocks-panel", "panel", "logs-link"), in: waiting) as? UIControl)
        #expect(!link.isEnabled, "the region does not say it is disabled")
        #expect(link.accessibilityTraits.contains(.notEnabled))
        #expect(!link.accessibilityActivate(), "an assistive activation sent a disabled action")
        link.sendActions(for: .touchUpInside)
        #expect(intents.isEmpty, "a disabled region sent the action anyway")
    }

    // MARK: - Layout

    @Test(arguments: [
        ("blocks-panel.json", UIContentSizeCategory.large),
        ("blocks-panel.json", UIContentSizeCategory.accessibilityExtraExtraExtraLarge),
        ("blocks-status.json", UIContentSizeCategory.large),
        ("blocks-status.json", UIContentSizeCategory.accessibilityExtraExtraExtraLarge),
    ])
    func nothingClipsAtThreeTwentyPointsOrAtAnAccessibilitySize(
        name: String,
        category: UIContentSizeCategory
    ) throws {
        let view = composites(try surface(name), sizeCategory: category)
        let clipped = clippedText(in: view)
        #expect(clipped.isEmpty, "\(name) at \(category.rawValue) clips: \(clipped)")
        for button in subviews(of: UIButton.self, in: view) where !button.isHidden && !hasFixedWidth(button) {
            #expect(
                button.bounds.width + 1 >= button.intrinsicContentSize.width,
                "\(name) at \(category.rawValue) squeezes \(button.accessibilityIdentifier ?? "a button"): \(button.bounds.width) < \(button.intrinsicContentSize.width)"
            )
        }
        // Nothing is clipped at the card's edge, because nothing draws outside it: a hosted test
        // can measure the whole subtree instead of hoping a clip reveals the overflow.
        for card in subviews(of: ExtensionSurfaceCompositeCardView.self, in: view) {
            let furthest = subtreeMaxX(in: card)
            #expect(
                furthest <= card.bounds.width + 0.5,
                "\(name) at \(category.rawValue) draws \(furthest) pt into a \(card.bounds.width) pt card"
            )
        }
    }

    @Test func aLongBadgeAtAnAccessibilitySizeStaysInsideTheCard() throws {
        // Forty characters in a capsule that hugs its content: at AX-XXXL this used to be drawn
        // outside the card, where nothing clipped it.
        let surface = try surface("blocks-panel.json", mutating: { object in
            var sections = testUnwrap(object["sections"] as? [[String: Any]])
            var body = testUnwrap(sections[0]["body"] as? [String: Any])
            var children = testUnwrap(body["children"] as? [[String: Any]])
            var headline = testUnwrap(children[0]["children"] as? [[String: Any]])
            headline[1]["text"] = "Deployment window closes at noon"
            children[0]["children"] = headline
            body["children"] = children
            sections[0]["body"] = body
            object["sections"] = sections
        })
        let view = composites(surface, sizeCategory: .accessibilityExtraExtraExtraLarge)
        let card = try testUnwrap(subviews(of: ExtensionSurfaceCompositeCardView.self, in: view).first)
        let badge = try testUnwrap(control(node("blocks-panel", "panel", "state"), in: view))
        let badgeFrame = badge.convert(badge.bounds, to: card)
        #expect(badgeFrame.maxX <= card.bounds.width + 0.5, "the badge ends \(badgeFrame.maxX) pt into a \(card.bounds.width) pt card")
        #expect(clippedText(in: card).isEmpty, "the long badge clips: \(clippedText(in: card))")
    }

    @Test func aLongKeyKeepsItsColumnInsideTheCard() throws {
        // A key names a fact and may be any length the wire allows; the widest one sets the column
        // every pair shares. Unbounded, a long key drew its value out past the card's edge, where
        // nothing clips it.
        let surface = try surface("blocks-panel.json", mutating: { object in
            var sections = testUnwrap(object["sections"] as? [[String: Any]])
            var body = testUnwrap(sections[0]["body"] as? [String: Any])
            var children = testUnwrap(body["children"] as? [[String: Any]])
            let index = try #require(children.firstIndex { $0["id"] as? String == "facts" })
            var facts = try #require(children[index] as? [String: Any])
            var pairs = try #require(facts["pairs"] as? [[String: Any]])
            pairs[0]["key"] = "Deployment window closes at noon"
            facts["pairs"] = pairs
            children[index] = facts
            body["children"] = children
            sections[0]["body"] = body
            object["sections"] = sections
        })
        let view = composites(surface)
        let card = try testUnwrap(subviews(of: ExtensionSurfaceCompositeCardView.self, in: view).first)
        let facts = try testUnwrap(control(node("blocks-panel", "panel", "facts"), in: view))
        let furthest = subtreeMaxX(in: card)
        #expect(furthest <= card.bounds.width + 0.5, "the long key draws \(furthest) pt into a \(card.bounds.width) pt card")

        // The key column keeps its share and no more, and the key gives way inside it.
        let key = try #require(allLabels(in: facts).first { $0.text?.hasPrefix("Deployment") == true })
        #expect(
            key.bounds.width <= facts.bounds.width * 0.45 + 1,
            "the key column is \(key.bounds.width) of a \(facts.bounds.width) pt row"
        )
        #expect(key.bounds.width < key.intrinsicContentSize.width, "the long key never had to give way")
        let value = try #require(allLabels(in: facts).first { $0.text == "prod" })
        #expect(value.bounds.width > 40, "the value has no room left: \(value.bounds.width)")
    }

    @Test func theClippingDetectorSeesAOneLineLabelThatCannotFit() throws {
        // The detector the layout tests rely on: a one-line label wider than its frame is a clip
        // the height-based check alone can never see.
        let host = UIView()
        let label = UILabel()
        label.numberOfLines = 1
        label.text = String(repeating: "a wide word ", count: 6)
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: host.topAnchor),
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: 80),
        ])
        show(host)
        host.layoutIfNeeded()
        #expect(
            clippedText(in: host).count == 1,
            "a one-line label \(label.bounds.width) wide in \(label.intrinsicContentSize.width) pt of text was not reported"
        )
    }

    @Test func onlyAPrimaryButtonTakesTheColumnWidth() throws {
        let view = composites(try surface("blocks-panel.json"))
        let controls = try testUnwrap(control(node("blocks-panel", "panel", "controls"), in: view))
        let retry = try testUnwrap(control(node("blocks-panel", "panel", "retry"), in: view) as? UIButton)
        let more = try testUnwrap(control(node("blocks-panel", "panel", "overflow"), in: view) as? UIButton)
        #expect(abs(retry.bounds.width - controls.bounds.width) <= 0.5, "the primary does not span its column")
        #expect(more.bounds.width < controls.bounds.width - 20, "a menu stretches across the column: \(more.bounds.width)")

        // The body already offers a primary, so the card's own action row is secondary: not filled
        // with the accent, and no wider than its own words.
        let card = try testUnwrap(subviews(of: ExtensionSurfaceCompositeCardView.self, in: view).first)
        let refresh = try testUnwrap(cardAction("refresh", in: view) as? UIButton)
        #expect(refresh.configuration?.baseBackgroundColor == nil, "the demoted action still fills with the accent")
        #expect(refresh.bounds.width < card.bounds.width - 20, "the demoted action still spans the card")
        #expect(retry.configuration?.baseBackgroundColor != nil, "the body's primary lost its emphasis")
    }

    @Test func theCardBodyGivesItsTopLevelChildrenTwelvePoints() throws {
        let view = composites(try surface("blocks-panel.json"))
        let headline = try testUnwrap(control(node("blocks-panel", "panel", "headline"), in: view))
        let progress = try testUnwrap(control(node("blocks-panel", "panel", "progress"), in: view))
        let gap = progress.convert(progress.bounds, to: view).minY - headline.convert(headline.bounds, to: view).maxY
        #expect(abs(gap - 12) <= 0.5, "the body's top level is \(gap) pt apart")

        // The action row stands off the body a little further than the body's own children. The
        // group is the body's last child, so the card's own row follows it.
        let last = try testUnwrap(control(node("blocks-panel", "panel", "filters"), in: view))
        let refresh = try testUnwrap(cardAction("refresh", in: view))
        let actionGap = refresh.convert(refresh.bounds, to: view).minY - last.convert(last.bounds, to: view).maxY
        #expect(actionGap >= 12 && actionGap <= 16, "the action row is \(actionGap) pt under the body")
    }

    @Test func anIconAndTheControlsShareOneLine() throws {
        let view = composites(try surface("blocks-panel.json"))
        let icon = try testUnwrap(control(node("blocks-panel", "panel", "hammer"), in: view))
        let retry = try testUnwrap(control(node("blocks-panel", "panel", "retry"), in: view))
        let iconFrame = icon.convert(icon.bounds, to: view)
        let retryFrame = retry.convert(retry.bounds, to: view)
        #expect(abs(iconFrame.midY - retryFrame.midY) < iconFrame.height, "the icon sits on a line of its own")
        #expect(iconFrame.maxX <= retryFrame.minX + 0.5, "the icon is drawn over the controls")
    }

    @Test func aRowWrapsToAColumnWhenItsChildrenCannotFit() throws {
        let surface = try surface("blocks-panel.json")
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let view = composites(surface, sizeCategory: category)
            let headline = try testUnwrap(control(node("blocks-panel", "panel", "headline"), in: view))
            let phase = try testUnwrap(control(node("blocks-panel", "panel", "phase"), in: view))
            let badge = try testUnwrap(control(node("blocks-panel", "panel", "state"), in: view))
            let phaseFrame = phase.convert(phase.bounds, to: view)
            let badgeFrame = badge.convert(badge.bounds, to: view)
            if category.isAccessibilityCategory {
                // At an accessibility size the row stacks: the badge sits under the text and
                // never squeezes it off the edge.
                #expect(badgeFrame.minY >= phaseFrame.maxY - 0.5, "the badge did not stack under the text")
                #expect(badgeFrame.maxX <= view.bounds.width + 0.5)
            } else {
                #expect(abs(phaseFrame.minY - badgeFrame.minY) < 12, "the row should stay one line at 320 pt")
            }
            _ = headline
        }
    }

    // MARK: - Selected and disabled

    @Test func aSelectedNodePaintsTheHostsSelectionAndSaysSo() throws {
        let view = composites(try surface("blocks-filters.json"))
        let palette = themeID.palette

        // A selected row: the fill and hairline the host gives the item a person picked, and the
        // trait VoiceOver reads instead of "button".
        let row = try testUnwrap(control(node("blocks-filters", "filters", "active-row"), in: view))
        #expect(row.accessibilityTraits.contains(.selected), "the row is not marked selected")
        #expect(row.backgroundColor == palette.ui.cyan.withAlphaComponent(0.16), "the row is not filled")
        #expect(row.layer.borderWidth == 1, "the row has no hairline")

        // A button keeps its own role and takes the same mark.
        let button = try testUnwrap(
            control(node("blocks-filters", "filters", "seg-all"), in: view) as? UIButton
        )
        #expect(button.accessibilityTraits.contains(.selected))
        #expect(button.configuration?.background.backgroundColor == palette.ui.cyan.withAlphaComponent(0.16))

        // A badge is already a capsule; a selection paints over the tone it arrived with.
        let badge = try testUnwrap(control(node("blocks-filters", "filters", "badge-selected"), in: view))
        #expect(badge.accessibilityTraits.contains(.selected), "the badge is not marked selected")
        #expect(badge.backgroundColor == palette.ui.cyan.withAlphaComponent(0.16))
        #expect(badge.layer.borderWidth == 1)

        // The item that is not the one picked says nothing of the sort.
        let other = try testUnwrap(control(node("blocks-filters", "filters", "seg-running"), in: view))
        #expect(!other.accessibilityTraits.contains(.selected))
        #expect(other.backgroundColor == nil || other.backgroundColor == .clear)
    }

    @Test func aSelectedTextPaintsACapsuleAroundItsWords() throws {
        // The panel's filters group: a chip row of one selected and one plain item.
        let view = composites(try surface("blocks-panel.json"))
        let palette = themeID.palette
        let chip = try testUnwrap(control(node("blocks-panel", "panel", "filter-all"), in: view))
        let plain = try testUnwrap(control(node("blocks-panel", "panel", "filter-running"), in: view))

        #expect(chip.accessibilityTraits.contains(.selected), "the chip is not marked selected")
        #expect(chip.backgroundColor == palette.ui.cyan.withAlphaComponent(0.16))
        #expect(chip.layer.borderWidth == 1)
        #expect(chip.layer.cornerRadius > 0, "the selected words are not a capsule")
        // The words keep their own air inside the capsule, so the fill reads as one chip.
        let chipLabel = try testUnwrap(allLabels(in: chip).first)
        #expect(chipLabel.frame.minX >= 4, "the words sit on the capsule's edge")
        // The capsule is the words plus their air each side, not a width the words overflow.
        #expect(abs(chip.bounds.width - (chipLabel.intrinsicContentSize.width + 24)) <= 1,
                "the capsule is \(chip.bounds.width) for \(chipLabel.intrinsicContentSize.width) of words")
        // And the next chip starts after this one, so no two chips draw over each other.
        #expect(chip.convert(chip.bounds, to: view).maxX <= plain.convert(plain.bounds, to: view).minX + 0.5,
                "the selected chip is drawn over its sibling")

        // A chip hugs its words: it sits beside its siblings rather than stretching over them.
        let row = try testUnwrap(control(node("blocks-panel", "panel", "filter-set"), in: view))
        #expect(chip.bounds.width < row.bounds.width - 40,
                "the chip stretched across the row: \(chip.bounds.width) of \(row.bounds.width)")

        #expect(!plain.accessibilityTraits.contains(.selected))
        #expect(plain.backgroundColor == .clear)
    }

    @Test func aDisabledNodeSendsNothingAndSaysItIsUnusable() throws {
        var intents: [ExtensionSurfaceActionIntent] = []
        let view = composites(try surface("blocks-filters.json"), onAction: { intents.append($0) })

        // Every kind that can be published disabled: a control, and a region a tap would reach.
        let row = try testUnwrap(control(node("blocks-filters", "filters", "archived-row"), in: view) as? UIControl)
        #expect(!row.isEnabled)
        #expect(row.accessibilityTraits.contains(.notEnabled))
        #expect(!row.accessibilityActivate(), "assistive activation sent the action")
        row.sendActions(for: .touchUpInside)

        let stack = try testUnwrap(control(node("blocks-filters", "filters", "locked"), in: view) as? UIControl)
        #expect(!stack.isEnabled)
        stack.sendActions(for: .touchUpInside)

        let text = try testUnwrap(control(node("blocks-filters", "filters", "locked-text"), in: view))
        #expect(text.accessibilityTraits.contains(.notEnabled))
        #expect(!text.accessibilityActivate())

        let badge = try testUnwrap(control(node("blocks-filters", "filters", "badge-disabled"), in: view))
        #expect(badge.accessibilityTraits.contains(.notEnabled))
        #expect(badge.alpha < 1, "a disabled region does not look like a usable one")

        let button = try testUnwrap(control(node("blocks-filters", "filters", "seg-failed"), in: view) as? UIButton)
        #expect(!button.isEnabled)
        #expect(button.accessibilityTraits.contains(.notEnabled))
        button.sendActions(for: .touchUpInside)

        let toggle = try testUnwrap(control(node("blocks-filters", "filters", "notify-toggle"), in: view) as? UISwitch)
        #expect(!toggle.isEnabled)

        let menu = try testUnwrap(control(node("blocks-filters", "filters", "groupby"), in: view) as? UIButton)
        #expect(!menu.isEnabled)

        #expect(intents.isEmpty, "a disabled node sent \(intents.map(\.actionId))")

        // The sibling nobody disabled still answers: one node's state is not the whole tree's.
        let running = try testUnwrap(control(node("blocks-filters", "filters", "seg-running"), in: view) as? UIButton)
        #expect(running.isEnabled)
        running.sendActions(for: .touchUpInside)
        #expect(intents.map(\.actionId) == ["apply"])
    }

    // MARK: - Tone, icon, and group

    @Test func aProgressBarAndRingPaintTheToneTheyDeclare() throws {
        let view = composites(try surface("blocks-panel.json"))
        let palette = themeID.palette

        // A ring's arc carries the node's tone; its track is the same colour, paler.
        let ring = try testUnwrap(control(node("blocks-panel", "panel", "waiting"), in: view))
        let strokes = ringStrokes(in: ring)
        #expect(strokes.contains(palette.ui.orange), "the ring's arc is not its warning tone: \(strokes)")

        // The bar's fill carries its own tone instead of the host's default foreground.
        let bar = try testUnwrap(control(node("blocks-panel", "panel", "progress"), in: view))
        let fills = subviews(of: UIView.self, in: bar).compactMap(\.backgroundColor)
        #expect(fills.contains(palette.ui.green.withAlphaComponent(0.82)),
                "the bar's fill is not its success tone: \(fills)")
    }

    @Test func aBadgeDrawsItsIconBeforeItsWords() throws {
        let view = composites(try surface("blocks-panel.json"))
        let badge = try testUnwrap(control(node("blocks-panel", "panel", "state"), in: view))
        let icon = try #require(
            subviews(of: UIImageView.self, in: badge).first { !$0.isHidden && $0.image != nil },
            "the badge drew no icon"
        )
        let words = try #require(allLabels(in: badge).first { $0.text == "2 of 4" })
        let iconFrame = icon.convert(icon.bounds, to: badge)
        let wordsFrame = words.convert(words.bounds, to: badge)
        #expect(iconFrame.width > 0, "the icon has no width")
        #expect(iconFrame.maxX <= wordsFrame.minX + 0.5,
                "the icon sits after the words: \(iconFrame) vs \(wordsFrame)")
        // And the glyph is inside the capsule, not outside it.
        #expect(iconFrame.minX >= 0 && iconFrame.maxX <= badge.bounds.width,
                "the icon escaped the capsule: \(iconFrame) of \(badge.bounds)")
    }

    @Test func aGroupStartsWithItsPublishedStateAndTogglesLocally() throws {
        var intents: [ExtensionSurfaceActionIntent] = []
        let surface = try surface("blocks-panel.json")
        let view = composites(surface, onAction: { intents.append($0) })

        let group = try testUnwrap(control(node("blocks-panel", "panel", "filters"), in: view))
        #expect(!group.isAccessibilityElement, "the region is a container, not a control")
        let disclosure = try testUnwrap(
            control(node("blocks-panel", "panel", "filters") + ".disclosure", in: view) as? UIControl
        )
        #expect(disclosure.accessibilityTraits.contains(.button))
        #expect(disclosure.accessibilityLabel == "Filters")

        // Published open: the children are on screen and the control says so.
        #expect(disclosure.accessibilityValue == "Expanded")
        let chip = try testUnwrap(control(node("blocks-panel", "panel", "filter-all"), in: view))
        #expect(!isHiddenFromReader(chip, in: view), "the open group hid its children")

        // Folding is the reader's own business: it changes what is on screen and sends nothing.
        disclosure.sendActions(for: .touchUpInside)
        #expect(disclosure.accessibilityValue == "Collapsed")
        #expect(isHiddenFromReader(chip, in: view), "the collapsed group still shows its children")
        #expect(intents.isEmpty, "folding sent \(intents.map(\.actionId))")

        // A repaint that publishes the same state leaves the reader where they left themselves.
        view.apply(surface: surface, pending: nil, themeID: themeID, onAction: nil)
        view.layoutIfNeeded()
        let repainted = try testUnwrap(
            control(node("blocks-panel", "panel", "filters") + ".disclosure", in: view) as? UIControl
        )
        #expect(repainted.accessibilityValue == "Collapsed", "a repaint opened the region again")
        // The children are the same renderer's: they keep their own identifiers and state.
        let repaintedChip = try testUnwrap(control(node("blocks-panel", "panel", "filter-all"), in: view))
        #expect(repaintedChip.accessibilityTraits.contains(.selected))
        #expect(isHiddenFromReader(repaintedChip, in: view))
    }

    // MARK: - A row's glyph, accessory, and the card that holds it

    /// A surface whose sections are headerless blocks trees with the given bodies, in order.
    private func headerlessBlocks(_ bodies: [[String: Any]]) throws -> ExtensionUISurface {
        try surface("blocks-panel.json") { object in
            object["sections"] = bodies.enumerated().map { index, body -> [String: Any] in
                [
                    "composite": "blocks",
                    "id": "section-\(index)",
                    "state": ["kind": "content"],
                    "fallback": ["text": "fallback"],
                    "body": body,
                ]
            }
        }
    }

    private func jobRow(title: String = "A running job") -> [String: Any] {
        [
            "type": "row",
            "id": "head",
            "children": [
                ["type": "icon", "id": "glyph", "name": "checkmark.circle.fill", "tone": "success"],
                ["type": "text", "id": "title", "text": title, "style": "headline"],
                [
                    "type": "button", "id": "stop", "title": "Stop", "role": "destructive",
                    "action": ["id": "retry"],
                ],
            ],
        ]
    }

    @Test func aCardThatIsItsSurfacesOnlyContentSitsOnTheDrawerWithoutAFrame() throws {
        func cards(_ bodies: [[String: Any]]) throws -> [ExtensionSurfaceBlocksView] {
            subviews(of: ExtensionSurfaceBlocksView.self, in: composites(try headerlessBlocks(bodies)))
        }
        let alone = try #require(cards([jobRow()]).first)
        #expect(alone.layer.borderWidth == 0, "the only card framed itself inside the drawer")
        #expect(alone.backgroundColor == .clear)

        // With a neighbour, each card is a card: the frame is what tells them apart.
        let neighbours = try cards([jobRow(), jobRow()])
        #expect(neighbours.count == 2)
        #expect(neighbours.allSatisfy { $0.layer.borderWidth > 0 })
    }

    @Test func aSecondaryButtonEndingARowIsACompactCapsuleInA44PointTarget() throws {
        let view = composites(try headerlessBlocks([jobRow()]))
        let stop = try #require(
            control(node("blocks-panel", "section-0", "stop"), in: view) as? UIButton
        )
        #expect(stop.frame.height >= 44, "Stop is \(stop.frame.height) pt tall")
        // The capsule is painted inside that frame, not across it.
        let inset = try #require(stop.configuration?.background.backgroundInsets)
        #expect(inset.top > 0 && inset.bottom > 0)

        // The same button on a line of its own is the card's ordinary bordered button.
        let alone = composites(try headerlessBlocks([[
            "type": "stack", "children": [[
                "type": "button", "id": "stop", "title": "Stop", "role": "destructive",
                "action": ["id": "retry"],
            ]],
        ]]))
        let block = try #require(
            control(node("blocks-panel", "section-0", "stop"), in: alone) as? UIButton
        )
        #expect(block.configuration?.background.backgroundInsets == NSDirectionalEdgeInsets.zero)

        // A row of nothing but buttons is a set, not a line with an accessory: its unselected items
        // keep the ordinary look, so the selected one is the one that stands out.
        let set = composites(try surface("blocks-filters.json"))
        let unselected = try #require(
            control(node("blocks-filters", "filters", "seg-running"), in: set) as? UIButton
        )
        #expect(unselected.configuration?.background.backgroundInsets == NSDirectionalEdgeInsets.zero)
    }

    @Test func aRowThatStacksAtAnAccessibilitySizeKeepsItsGlyphBesideItsWords() throws {
        let view = composites(
            try headerlessBlocks([jobRow(title: "bun run release")]),
            sizeCategory: .accessibilityExtraExtraExtraLarge
        )
        let glyph = try #require(subviews(of: BlocksIconView.self, in: view).first)
        let title = try #require(control(node("blocks-panel", "section-0", "title"), in: view))
        let stop = try #require(control(node("blocks-panel", "section-0", "stop"), in: view))
        let glyphFrame = glyph.convert(glyph.bounds, to: view)
        let titleFrame = title.convert(title.bounds, to: view)
        let stopFrame = stop.convert(stop.bounds, to: view)
        #expect(glyphFrame.maxX <= titleFrame.minX + 0.5, "the glyph is not beside its title")
        #expect(abs(glyphFrame.minY - titleFrame.minY) < 12, "the glyph left its title's first line")
        #expect(stopFrame.minY >= titleFrame.maxY - 0.5, "Stop did not wrap below the title")
    }

    @Test func aGroupPublishedFoldedStartsFoldedAndOpensOnTap() throws {
        let view = composites(try panelWithFoldedGroup())
        let disclosure = try testUnwrap(
            control(node("blocks-panel", "panel", "filters") + ".disclosure", in: view) as? UIControl
        )
        let chip = try testUnwrap(control(node("blocks-panel", "panel", "filter-all"), in: view))
        #expect(disclosure.accessibilityValue == "Collapsed")
        #expect(isHiddenFromReader(chip, in: view))

        disclosure.sendActions(for: .touchUpInside)
        #expect(disclosure.accessibilityValue == "Expanded")
        #expect(!isHiddenFromReader(chip, in: view), "the opened group kept its children off screen")
    }

    @Test func aFoldsRowTakesTouchesAcrossA44PointTargetThoughItIsDrawnShorter() throws {
        let view = composites(try panelWithFoldedGroup())
        let disclosure = try testUnwrap(
            control(node("blocks-panel", "panel", "filters") + ".disclosure", in: view) as? UIControl
        )
        let frame = disclosure.convert(disclosure.bounds, to: view)
        #expect(frame.height < 44, "the fold's row is drawn compact")
        // Just above the drawn row, inside the 44 pt target: the fold answers, not the card.
        let reach = (44 - frame.height) / 2
        let above = CGPoint(x: frame.midX, y: frame.minY - reach + 1)
        #expect(view.hitTest(above, with: nil) === disclosure, "a touch just above the fold missed it")
        // Past the target, the touch is not the fold's.
        let outside = CGPoint(x: frame.midX, y: frame.minY - reach - 1)
        #expect(view.hitTest(outside, with: nil) !== disclosure)
    }

    // MARK: - Pill

    @Test func aComposedPillDrawsItsContentRowInsteadOfTheHeaderTitle() throws {
        let surface = try surface("blocks-panel.json")
        let panel = makePanel(surface)

        let pill = try testUnwrap(
            control("extension-strip-aboveEditor-pill-surface-blocks_2dpanel", in: panel) as? UIControl
        )
        let texts = shownLabelTexts(in: pill)
        #expect(texts.contains("web → prod"), "the pill draws the content row's text: \(texts)")
        #expect(texts.contains("running"), "the pill draws the content row's badge: \(texts)")
        #expect(
            !texts.contains(where: { $0.contains("4f2c1ab") }),
            "the header-derived subtitle is replaced by the content row: \(texts)"
        )
        // The content row's icon and its progress ring are drawn.
        #expect(subviews(of: UIImageView.self, in: pill).contains { $0.image != nil })
        #expect(
            subviews(of: UIView.self, in: pill).contains { $0.accessibilityValue?.contains("40") == true },
            "the content row's ring is drawn"
        )
        // A danger dot rule still applies: this surface is not failing and declares no danger.
        #expect(pill.accessibilityValue?.contains("running") == true)

        // The content row starts with an icon, which already says what the strip's tone dot would,
        // so only one leading indicator is drawn.
        let dot = try #require(toneDot(in: pill), "the strip's tone dot is not in the hierarchy")
        #expect(dot.isHidden, "the pill shows a tone dot beside its own icon")

        // One inline step: the content row's own spacing is 6 pt in a pill.
        let icon = try testUnwrap(subviews(of: UIImageView.self, in: pill).first { $0.image != nil })
        let words = try testUnwrap(subviews(of: UILabel.self, in: pill).first { $0.text == "web → prod" && !$0.isHidden })
        let step = words.convert(words.bounds, to: pill).minX - icon.convert(icon.bounds, to: pill).maxX
        #expect(abs(step - 6) <= 0.5, "the pill's inline step is \(step) pt")

        // `tap: "drawer"` still opens the section.
        pill.sendActions(for: .touchUpInside)
        panel.layoutIfNeeded()
        #expect(control("extension.surface.blocks_2dpanel.panel", in: panel) != nil)
    }

    @Test func aPillThatLeadsWithItsOwnIndicatorDropsTheStripDot() throws {
        // A badge's own glyph and a ring say what the strip's tone dot would, exactly as a bare icon
        // does: the dot stays in the hierarchy, hidden, instead of drawing a second indicator.
        let badgePanel = makePanel(try surface("blocks-filters.json"))
        let badgePill = try testUnwrap(
            control("extension-strip-aboveEditor-pill-surface-blocks_2dfilters", in: badgePanel)
        )
        #expect(
            subviews(of: UIImageView.self, in: badgePill).contains { $0.image != nil },
            "the badge lost the glyph it leads with"
        )
        let badgeDot = try #require(toneDot(in: badgePill), "the strip's tone dot is not in the hierarchy")
        #expect(badgeDot.isHidden, "the pill draws a tone dot beside its badge's glyph")

        // The same for a ring, which a surface may also publish first.
        let ringSurface = try surface("blocks-filters.json", mutating: { object in
            var pill = testUnwrap(object["pill"] as? [String: Any])
            var content = testUnwrap(pill["content"] as? [String: Any])
            content["children"] = [
                ["type": "progress", "kind": "ring", "value": 0.4],
                ["type": "text", "text": "Filters"],
            ]
            pill["content"] = content
            object["pill"] = pill
        })
        let ringPanel = makePanel(ringSurface)
        let ringPill = try testUnwrap(
            control("extension-strip-aboveEditor-pill-surface-blocks_2dfilters", in: ringPanel)
        )
        #expect(
            subviews(of: UIView.self, in: ringPill).contains { $0.accessibilityValue?.contains("40") == true },
            "the content row's ring is drawn"
        )
        let ringDot = try #require(toneDot(in: ringPill), "the strip's tone dot is not in the hierarchy")
        #expect(ringDot.isHidden, "the pill draws a tone dot beside its ring")
    }

    @Test func aPillWhoseTapSendsAnActionKeepsItsChevronForTheDrawer() throws {
        let surface = try surface("blocks-status.json")
        var intents: [ExtensionSurfaceActionIntent] = []
        let panel = makePanel(surface, onAction: { intents.append($0) })

        let pillId = "extension-strip-aboveEditor-pill-surface-blocks_2dstatus"
        let pill = try testUnwrap(control(pillId, in: panel) as? UIControl)
        // The body and the drawer are two controls, named by their scoped ids rather than by their
        // words, and only the drawer says "Expand".
        #expect(!pill.isAccessibilityElement, "the pill is still one element doing two things")
        #expect(pill.accessibilityLabel?.contains("Expand") != true, "the pill body claims to expand: \(pill.accessibilityLabel ?? "nil")")
        let body = try #require(control("\(pillId).body", in: pill), "the pill body is not a control of its own")
        let drawer = try #require(control("\(pillId).drawer", in: pill), "the drawer's control has no id")
        #expect(body.isAccessibilityElement)
        #expect(body.accessibilityLabel?.contains("Waiting on you") == true, "the body does not say what it holds")
        #expect(drawer.isAccessibilityElement)
        #expect(drawer.accessibilityLabel?.hasPrefix("Expand") == true, "the drawer's control has no words")
        #expect(body.accessibilityHint?.contains("Refresh") == true, "the body does not say what it sends")

        // The body sends the pill's action and leaves the drawer alone.
        #expect(body.accessibilityActivate())
        #expect(intents.map(\.actionId) == ["refresh"])
        #expect(intents.first?.compositeId == "pill")
        #expect(intents.first?.nodeId == nil)
        #expect(control("extension.surface.blocks_2dstatus.ask", in: panel) == nil, "the drawer stays closed")

        // The pill's own touch target is the body too: the chevron is the only way in.
        pill.sendActions(for: .touchUpInside)
        panel.layoutIfNeeded()
        #expect(intents.count == 2, "a pill body tap should send the action")
        #expect(control("extension.surface.blocks_2dstatus.ask", in: panel) == nil, "the drawer stays closed")
        (drawer as? UIControl)?.sendActions(for: .touchUpInside)
        panel.layoutIfNeeded()
        #expect(control("extension.surface.blocks_2dstatus.ask", in: panel) != nil, "the chevron does not open the drawer")
        #expect(intents.count == 2, "the drawer's control sent the action")
    }

    // MARK: - Captures

    @Test func capturesADrawerAndAComposedPill() throws {
        // The drawer's cards, at the width a drawer gives them: every kind draws its part.
        let drawer = composites(try surface("blocks-panel.json"))
        try write(png: drawer, named: "blocks-drawer.png")

        // The same drawer at an accessibility text size: rows stack and nothing clips.
        let large = composites(
            try surface("blocks-panel.json"),
            sizeCategory: .accessibilityExtraExtraExtraLarge
        )
        try write(png: large, named: "blocks-drawer-ax.png")

        // Each capture covers every card it drew: a view whose bounds stopped short of its last
        // card would drop a whole row from the picture without failing anything else.
        for (name, view) in [("blocks-drawer.png", drawer), ("blocks-drawer-ax.png", large)] {
            let cards = subviews(of: ExtensionSurfaceCompositeCardView.self, in: view)
            let last = try #require(cards.last)
            let bottom = last.convert(last.bounds, to: view).maxY
            #expect(bottom <= view.bounds.height + 0.5, "\(name) cuts its last card at \(bottom) of \(view.bounds.height)")
        }

        // A composed pill, at its own size: the strip draws these facts instead of a title. This
        // one names a badge with its icon and a caption, the two things a pill can hold.
        let panel = makePanel(try surface("blocks-filters.json"))
        let pill = try testUnwrap(
            control("extension-strip-aboveEditor-pill-surface-blocks_2dfilters", in: panel) as? UIControl
        )
        try write(png: pill, named: "blocks-pill.png")
        #expect(pill.bounds.width > 0 && pill.bounds.height > 0)
        // The pill fits the strip it lives in: a 320 pt phone keeps the whole line.
        #expect(pill.bounds.width <= 320, "the pill is \(pill.bounds.width) wide")
    }

    /// A capture of `view`'s layers over the theme's background. `drawHierarchy` renders a glass
    /// surface as blank, and a layered render keeps every view's own drawing.
    private func write(png view: UIView, named name: String) throws {
        let size = CGSize(width: max(1, view.bounds.width), height: max(1, view.bounds.height))
        let image = UIGraphicsImageRenderer(size: size).image { context in
            themeID.palette.ui.bg.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            view.layer.render(in: context.cgContext)
        }
        let data = try #require(image.pngData(), "no PNG for \(name)")
        #expect(data.count > 1_000, "\(name) looks empty")
        try data.write(to: testArtifactURL(name), options: .atomic)
    }

    // MARK: - Elapsed

    /// The elapsed fixture with its pill and body timers started `seconds` ago.
    private func elapsedSurface(startedSecondsAgo seconds: TimeInterval) throws -> ExtensionUISurface {
        let since = (Date().timeIntervalSince1970 - seconds) * 1000
        return try surface("blocks-elapsed.json") { object in
            var pill = testUnwrap(object["pill"] as? [String: Any])
            var content = testUnwrap(pill["content"] as? [String: Any])
            var children = testUnwrap(content["children"] as? [[String: Any]])
            children[2]["since"] = since
            content["children"] = children
            pill["content"] = content
            object["pill"] = pill
        }
    }

    /// Runs the main loop for `seconds`, so the shared clock gets to fire.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @Test func anElapsedLabelAdvancesWhileItIsOnScreenAndSpeaksTheCountAsItStands() throws {
        let panel = makePanel(try elapsedSurface(startedSecondsAgo: 58))
        let pill = try testUnwrap(
            control("extension-strip-aboveEditor-pill-surface-blocks_2delapsed", in: panel) as? UIControl
        )
        let timer = try testUnwrap(subviews(of: BlocksElapsedView.self, in: pill).first)
        let label = try testUnwrap(subviews(of: UILabel.self, in: timer).first)
        let first = try #require(label.text)
        #expect(first == "0:58" || first == "0:59", "the timer starts from its since: \(first)")
        // Digits keep their width: every digit measures the same, so the line does not shift.
        let widths = Set(["0:11", "0:88", "0:00"].map { ($0 as NSString).size(withAttributes: [.font: label.font]).width })
        #expect(widths.count == 1, "the timer's digits differ in width: \(widths)")
        let name = timer.accessibilityLabel
        #expect(name == BlocksElapsedView.spokenName)
        // VoiceOver reads the pill's words when it lands there: the count as it stands, in words.
        let spokenAtFirst = try #require(pill.accessibilityValue)
        #expect(spokenAtFirst.contains("seconds") && !spokenAtFirst.contains("minute"), "\(spokenAtFirst)")

        spin(2.3)
        let later = try #require(label.text)
        #expect(later != first, "the label did not advance: \(first) → \(later)")
        #expect(timer.accessibilityLabel == name, "the name stays put while the count moves")
        #expect(timer.accessibilityValue?.contains("minute") == true)
        // Past a minute now: the pill speaks the count it has reached, not the one it was drawn with.
        let spokenLater = try #require(pill.accessibilityValue)
        #expect(spokenLater.contains("minute"), "\(spokenLater)")
    }

    @Test func aStripPillTakesTouchesAcrossA44ptBandThoughItDrawsShorter() throws {
        let panel = makePanel(try elapsedSurface(startedSecondsAgo: 5))
        let pill = try testUnwrap(
            control("extension-strip-aboveEditor-pill-surface-blocks_2delapsed", in: panel) as? UIControl
        )
        let window = try #require(panel.window)
        let frame = pill.convert(pill.bounds, to: window)
        #expect(frame.height < 44, "the pill draws shorter than its band: \(frame.height)")
        let band = (44 - frame.height) / 2 - 1
        for y in [frame.minY - band, frame.maxY + band] {
            let hit = window.hitTest(CGPoint(x: frame.midX, y: y), with: nil)
            #expect(hit?.isDescendant(of: pill) == true, "a touch at y \(y) missed the pill at \(frame)")
        }
    }

    @Test func theSharedClockRunsOnlyWhileAnElapsedLabelIsInAWindow() throws {
        // An earlier test's window may still hold its timer: take every window down first.
        for window in Self.windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        Self.windows.removeAll()
        #expect(!ElapsedLabelTicker.shared.isRunning)
        let panel = makePanel(try elapsedSurface(startedSecondsAgo: 5))
        #expect(ElapsedLabelTicker.shared.isRunning)
        panel.removeFromSuperview()
        #expect(!ElapsedLabelTicker.shared.isRunning, "no label is on screen, so the clock stops")
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
        // The view's own size is its parent's business: a capture taken before the window lays out
        // again would cut the last card off at an accessibility size.
        view.superview?.layoutIfNeeded()
        view.layoutIfNeeded()
        return view
    }

    private func makePanel(
        _ surface: ExtensionUISurface,
        onAction: ((ExtensionSurfaceActionIntent) -> Void)? = nil
    ) -> ExtensionSurfacePanelView {
        let state = ExtensionSurfaceState(composableSurfaces: [
            surface.id: ExtensionComposableSurfaceState(surface: surface, order: 1),
        ])
        let panel = ExtensionSurfacePanelView(
            placement: .aboveEditor,
            actions: ExtensionSurfaceDrawerActions(openReader: { _ in }, sendAction: onAction)
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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 2400))
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

    /// The card's own action button: the row's ids extend the card's composite identifier.
    private func cardAction(_ actionId: String, in view: UIView) -> UIView? {
        let root = ExtensionSurfaceIdentity.composite(surfaceId: "blocks-panel", compositeId: "panel")
        return control(ExtensionSurfaceIdentity.element(root: root, key: actionId), in: view)
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

    /// The strip's tone dot: the small square a pill draws only when nothing in its content leads
    /// with an indicator of its own.
    private func toneDot(in root: UIView) -> UIView? {
        subviews(of: UIView.self, in: root).first {
            abs($0.bounds.width - 8) < 0.5 && abs($0.bounds.height - 8) < 0.5 && $0.layer.cornerRadius == 4
        }
    }

    private func allLabelTexts(in root: UIView) -> [String] {
        allLabels(in: root).compactMap(\.text)
    }

    /// The labels a person can see: a pill keeps the header-derived words in its hierarchy but
    /// hides them behind the content row.
    private func shownLabelTexts(in root: UIView) -> [String] {
        allLabels(in: root).filter { !$0.isHidden }.compactMap(\.text)
    }

    private func allTexts(in root: UIView) -> [String] {
        allLabelTexts(in: root) + subviews(of: UITextView.self, in: root).compactMap(\.text)
    }

    /// The width a card's body gets: the card less its own inset.
    private func cardInnerWidth(in root: UIView) -> CGFloat {
        guard let card = subviews(of: ExtensionSurfaceCompositeCardView.self, in: root).first else {
            return 0
        }
        return card.bounds.width - 20
    }

    /// The furthest right anything inside `root` is drawn, in `root`'s own coordinates. Nothing
    /// clips a card, so a child that escapes it is only visible by measuring.
    private func subtreeMaxX(in root: UIView) -> CGFloat {
        var furthest: CGFloat = 0
        func walk(_ view: UIView) {
            guard !view.isHidden else { return }
            furthest = max(furthest, view.convert(view.bounds, to: root).maxX)
            view.subviews.forEach(walk)
        }
        root.subviews.forEach(walk)
        return furthest
    }

    /// A control pinned to its own width — an icon button in reused block chrome — cannot be
    /// squeezed by the tree's layout, so its intrinsic size says nothing about a clip.
    private func hasFixedWidth(_ button: UIButton) -> Bool {
        button.constraints.contains { constraint in
            constraint.isActive
                && constraint.firstItem === button
                && constraint.firstAttribute == .width
                && constraint.relation == .equal
                && constraint.constant > 0
        }
    }

    /// Whether VoiceOver would reach `view`: nothing between it and the tree it was drawn in is
    /// hidden. A collapsed region keeps its children built and takes them off screen.
    private func isHiddenFromReader(_ view: UIView, in root: UIView) -> Bool {
        var current: UIView? = view
        while let node = current {
            if node.isHidden { return true }
            if node === root { return false }
            current = node.superview
        }
        return true
    }

    /// Every stroke colour a ring's glyph paints with, in draw order: the track first, the arc last.
    private func ringStrokes(in ring: UIView) -> [UIColor] {
        subviews(of: UIView.self, in: ring).flatMap { view in
            (view.layer.sublayers ?? []).compactMap { layer in
                (layer as? CAShapeLayer)?.strokeColor.flatMap { UIColor(cgColor: $0) }
            }
        }
    }

    /// Labels whose words do not fit the space they were given: one that needed more height, or a
    /// one-line label whose own width is wider than the frame it got. Those are the two ways a
    /// hosted test can see a clip without a capture.
    private func clippedText(in root: UIView) -> [String] {
        allLabels(in: root).compactMap { label in
            guard !label.isHidden, label.bounds.width > 0, let text = label.text, !text.isEmpty else {
                return nil
            }
            let needed = label.sizeThatFits(
                CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)
            )
            if needed.height > label.bounds.height + 1 { return text }
            if label.numberOfLines == 1, label.intrinsicContentSize.width > label.bounds.width + 1 {
                return text
            }
            return nil
        }
    }
}

private extension UIColor {
    /// What a person sees of `self` over an opaque `background`: both the card and the rules drawn
    /// on it are translucent washes, so only the composited colours can be compared.
    func over(_ background: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        var underRed: CGFloat = 0
        var underGreen: CGFloat = 0
        var underBlue: CGFloat = 0
        var underAlpha: CGFloat = 0
        background.getRed(&underRed, green: &underGreen, blue: &underBlue, alpha: &underAlpha)
        return UIColor(
            red: red * alpha + underRed * (1 - alpha),
            green: green * alpha + underGreen * (1 - alpha),
            blue: blue * alpha + underBlue * (1 - alpha),
            alpha: 1
        )
    }

    /// WCAG relative luminance, the scale a contrast ratio is measured on.
    var relativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
