import UIKit

// MARK: - Identity

/// Host-owned identifiers for composable surfaces (`dev/testing/ios-accessibility-testability.md`).
///
/// A surface, a card, and a row inside it are named from protocol ids —
/// `extension.surface.<surfaceId>.<compositeId>[.<key>]` — never a tool, extension, status, or
/// display name. Each segment is one escaped key (see `key(_:)`), so a protocol id can never add
/// a segment or merge with another id.
enum ExtensionSurfaceIdentity {
    /// One model key as a single identifier segment: ASCII letters and digits stay exactly as they
    /// are, and every other UTF-8 byte becomes `_` and two lowercase hex digits (`table:sessions`
    /// is `table_3asessions`). Escaping keeps distinct protocol ids distinct — deleting punctuation
    /// would fold `table:sessions` and `table.sessions` together, and `aB` and `ab` already differ
    /// in case — and the result holds no dot, so a key never splits into two segments.
    static func key(_ raw: String) -> String {
        var segment = ""
        for byte in raw.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"):
                segment.append(Character(UnicodeScalar(byte)))
            default:
                let hex = String(byte, radix: 16)
                segment += "_" + String(repeating: "0", count: 2 - hex.count) + hex
            }
        }
        // A key with nothing to name still needs a segment; no escape produces a bare `_`.
        return segment.isEmpty ? "_" : segment
    }

    /// A composite's card, and the element its header is identified by.
    static func composite(surfaceId: String, compositeId: String) -> String {
        "extension.surface.\(key(surfaceId)).\(key(compositeId))"
    }

    /// One element inside a card: a step, a checklist item, a table row, or an action button.
    static func element(root: String, key raw: String) -> String {
        "\(root).\(key(raw))"
    }
}

// MARK: - Tone

/// The whole styling vocabulary a composite has: a tone, painted with the host's palette.
enum ExtensionSurfaceTone: Equatable, Sendable {
    case neutral, accent, success, warning, danger

    init(raw: String?) {
        switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "accent": self = .accent
        case "success": self = .success
        case "warning": self = .warning
        case "danger": self = .danger
        default: self = .neutral
        }
    }

    func color(_ palette: ThemePalette) -> UIColor {
        switch self {
        case .neutral: palette.ui.comment
        case .accent: palette.ui.cyan
        case .success: palette.ui.green
        case .warning: palette.ui.orange
        case .danger: palette.ui.red
        }
    }
}

// MARK: - Context

/// What every card of one surface is drawn with.
struct ExtensionSurfaceCompositeContext {
    let themeID: ThemeID
    let surface: ExtensionUISurface
    /// The action waiting on the server, when one is: its declared words and disabled ids.
    let pending: ExtensionSurfacePendingAction?
    let onAction: ((ExtensionSurfaceActionIntent) -> Void)?

    var palette: ThemePalette { themeID.palette }

    /// The pending action a card owns, if any: a surface-level wait belongs to the one card that
    /// sent it, so two cards offering the same action id do not both show its words.
    func pending(for compositeId: String) -> ExtensionSurfacePendingAction? {
        pending?.compositeId == compositeId ? pending : nil
    }

    /// The intent a card builds when someone presses one of its actions.
    func intent(compositeId: String, actionId: String, rowId: String? = nil) -> ExtensionSurfaceActionIntent {
        ExtensionSurfaceActionIntent(
            surfaceId: surface.id,
            compositeId: compositeId,
            actionId: actionId,
            rowId: rowId,
            revision: surface.revision
        )
    }

    /// The intent a strip pill's own tap builds. A pill is its own composite id (`pill`) and has
    /// no node: the surface declared that tapping the pill sends this action.
    func pillIntent(_ action: ExtensionUISurfaceNodeAction) -> ExtensionSurfaceActionIntent {
        ExtensionSurfaceActionIntent(
            surfaceId: surface.id,
            compositeId: ExtensionSurfacePillContent.compositeId,
            actionId: action.id,
            revision: surface.revision,
            values: action.values,
            pending: action.pending
        )
    }

    /// The intent a blocks node builds: the node it came from, and whatever the tap carries.
    func intent(
        compositeId: String,
        nodeId: String,
        action: ExtensionUISurfaceNodeAction,
        rowId: String? = nil,
        values: [String: JSONValue]? = nil
    ) -> ExtensionSurfaceActionIntent {
        let declared = action.values ?? [:]
        let collected = values ?? [:]
        let merged = declared.merging(collected) { _, collected in collected }
        return ExtensionSurfaceActionIntent(
            surfaceId: surface.id,
            compositeId: compositeId,
            actionId: action.id,
            rowId: rowId,
            nodeId: nodeId,
            revision: surface.revision,
            values: merged.isEmpty ? nil : merged,
            pending: action.pending
        )
    }
}

/// A composite's `state` as the card reads it: a kind this build does not know is content, never a
/// card that hides everything it was given.
private enum ExtensionSurfaceCompositeState {
    case loading, empty, failure, content

    init(_ state: ExtensionUISurfaceState) {
        switch state.kind {
        case "loading": self = .loading
        case "empty": self = .empty
        case "failure": self = .failure
        default: self = .content
        }
    }

    var isContent: Bool { self == .content }
}

// MARK: - Surface body

/// A composable surface's drawer body: its cards in publication order, host spacing, no author
/// layout. Cards are kept per section id, so a patch updates a card instead of replacing the
/// drawer the person is reading.
final class ExtensionSurfaceCompositesView: UIView {
    private let stack = UIStackView()
    private var cards: [String: UIView] = [:]
    private var kinds: [String: String] = [:]
    /// What the cards were last drawn from. The drawer is applied again for anything its footer
    /// repaints for (a followed child's tail streams ten times a second), and a card redraws by
    /// replacing its controls: a touch already down on one would never end.
    private var drawn: (
        surface: ExtensionUISurface,
        pending: ExtensionSurfacePendingAction?,
        themeID: ThemeID,
        sendsActions: Bool,
        sizeCategory: UIContentSizeCategory
    )?
    /// The last inputs, to draw again when the text size changes: some blocks measure their
    /// layout when drawn.
    private var latest: (surface: ExtensionUISurface, pending: ExtensionSurfacePendingAction?, themeID: ThemeID)?
    private var onAction: ((ExtensionSurfaceActionIntent) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            guard let latest = self.latest else { return }
            self.apply(
                surface: latest.surface,
                pending: latest.pending,
                themeID: latest.themeID,
                onAction: self.onAction
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        surface: ExtensionUISurface,
        pending: ExtensionSurfacePendingAction?,
        themeID: ThemeID,
        onAction: ((ExtensionSurfaceActionIntent) -> Void)?
    ) {
        self.onAction = onAction
        latest = (surface, pending, themeID)
        let sendsActions = onAction != nil
        let sizeCategory = traitCollection.preferredContentSizeCategory
        if let drawn, drawn.surface == surface, drawn.pending == pending, drawn.themeID == themeID,
           drawn.sendsActions == sendsActions, drawn.sizeCategory == sizeCategory { return }
        drawn = (surface, pending, themeID, sendsActions, sizeCategory)
        // The cards send through this view, so an unchanged card still reaches the latest host.
        let context = ExtensionSurfaceCompositeContext(
            themeID: themeID,
            surface: surface,
            pending: pending,
            onAction: sendsActions ? { [weak self] in self?.onAction?($0) } : nil
        )
        var kept: [String: UIView] = [:]
        var nextKinds: [String: String] = [:]
        var ordered: [UIView] = []
        for section in surface.sections {
            let id = section.id
            let kind = Self.kind(of: section)
            let card: UIView
            if kinds[id] == kind, let existing = cards[id] {
                card = existing
            } else {
                card = Self.makeCard(section: section, surfaceId: surface.id)
            }
            switch card {
            case let card as ExtensionSurfaceCompositeCardView:
                card.apply(section, context: context)
            case let placeholder as ExtensionSurfaceUnsupportedCardView:
                placeholder.apply(section, context: context)
            default:
                break
            }
            kept[id] = card
            nextKinds[id] = kind
            ordered.append(card)
        }
        cards = kept
        kinds = nextKinds
        guard !stack.arrangedSubviews.elementsEqual(ordered, by: ===) else { return }
        for view in stack.arrangedSubviews where !ordered.contains(where: { $0 === view }) {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in ordered.enumerated() {
            stack.insertArrangedSubview(view, at: index)
        }
    }

    private static func kind(of section: ExtensionUISurfaceSection) -> String {
        switch section {
        case .statusCard: "statusCard"
        case .checklist: "checklist"
        case .dataTable: "dataTable"
        case .actionBar: "actionBar"
        case .blocks: "blocks"
        case .unsupported(let value): "unsupported:\(value.composite)"
        }
    }

    private static func makeCard(section: ExtensionUISurfaceSection, surfaceId: String) -> UIView {
        switch section {
        case .statusCard(let value):
            ExtensionSurfaceStatusCardView(surfaceId: surfaceId, compositeId: value.base.id)
        case .checklist(let value):
            ExtensionSurfaceChecklistView(surfaceId: surfaceId, compositeId: value.base.id)
        case .dataTable(let value):
            ExtensionSurfaceDataTableView(surfaceId: surfaceId, compositeId: value.base.id)
        case .actionBar(let value):
            ExtensionSurfaceActionBarView(surfaceId: surfaceId, compositeId: value.base.id)
        case .blocks(let value):
            ExtensionSurfaceBlocksView(surfaceId: surfaceId, compositeId: value.id)
        case .unsupported(let value):
            ExtensionSurfaceUnsupportedCardView(surfaceId: surfaceId, compositeId: value.id)
        }
    }
}

// MARK: - Card frame

/// One composite's card: the host's header, then either its `state` (loading, empty, failure) or
/// its content, then its actions. A composite never styles itself; its `tone` is the whole
/// palette, and a failure state is always the danger tone.
class ExtensionSurfaceCompositeCardView: UIView {
    let surfaceId: String
    let compositeId: String
    let body = UIStackView()
    let actions = ExtensionSurfaceActionRow()
    /// The section last applied, so a subclass reads its own card without keeping a second copy.
    private(set) var appliedSection: ExtensionUISurfaceSection?

    private let titleLabel = ExtensionNativeBlockStyle.label(.subheadline, weight: .semibold)
    private let subtitleLabel = ExtensionNativeBlockStyle.label(.caption1)
    private let header = UIView()
    private let stateView = UIContentUnavailableView(loadState: .loading(nil))
    private let column = UIStackView()
    private var stateHeight: NSLayoutConstraint?
    private var measuredStateHeight: CGFloat = 0
    private var columnInsets: [NSLayoutConstraint] = []
    private static let cardPadding: CGFloat = 10
    private(set) var context: ExtensionSurfaceCompositeContext?

    var identifier: String {
        ExtensionSurfaceIdentity.composite(surfaceId: surfaceId, compositeId: compositeId)
    }

    init(surfaceId: String, compositeId: String) {
        self.surfaceId = surfaceId
        self.compositeId = compositeId
        super.init(frame: .zero)
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical
        titles.alignment = .fill
        titles.spacing = 2
        titles.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titles)
        header.isAccessibilityElement = true
        header.accessibilityTraits = .staticText
        header.accessibilityIdentifier = identifier

        body.axis = .vertical
        body.alignment = .fill
        body.spacing = 8

        stateView.translatesAutoresizingMaskIntoConstraints = false
        let stateHeight = stateView.heightAnchor.constraint(equalToConstant: 96)
        self.stateHeight = stateHeight

        for view in [header, stateView, body, actions] as [UIView] {
            column.addArrangedSubview(view)
        }
        columnInsets = [
            column.topAnchor.constraint(equalTo: topAnchor, constant: Self.cardPadding),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.cardPadding),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.cardPadding),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.cardPadding),
        ]
        NSLayoutConstraint.activate(columnInsets + [
            titles.topAnchor.constraint(equalTo: header.topAnchor),
            titles.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            titles.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titles.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            stateHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// What the card's header element says about the card's own state, when it has words for it.
    func accessibilityValue(for base: ExtensionUISurfaceCompositeBase) -> String? { nil }

    /// The gap between the body's own children, and between the body and the card's action row. A
    /// tree's levels read as groups, so it gives its top level more room than a nested stack does.
    var bodySpacing: CGFloat { 8 }
    var actionSpacing: CGFloat { 8 }

    /// Whether the card draws its own frame: the faint fill, hairline, and padding that set one
    /// card off from the next. A card that is its whole surface's only content, with nothing of its
    /// own to say in a header or an action row, is drawn straight onto the drawer, which is already
    /// the surface's card; framing it again puts a card inside a card.
    func drawsFrame(
        header: ExtensionUISurfaceHeader?,
        actionIds: [String],
        tone: ExtensionSurfaceTone,
        context: ExtensionSurfaceCompositeContext
    ) -> Bool { true }

    /// Whether the body already offers a primary action of its own: the card's action row is then
    /// secondary, so one card never shows two primary buttons.
    var bodyOffersPrimaryAction: Bool { false }

    /// Draw this card's content. Called only while the card's state is content.
    func applyBody(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {}

    /// The card's own actions; an action bar's body is those actions.
    func actionIds(for base: ExtensionUISurfaceCompositeBase) -> [String] { base.actions ?? [] }

    func apply(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {
        guard let base = section.base else { return }
        // A card's own header value is read from the section it was last given, so the section is
        // recorded before the subclass answers for it.
        appliedSection = section
        apply(
            section,
            header: base.header,
            state: base.state,
            actionIds: actionIds(for: base),
            tone: base.tone,
            value: accessibilityValue(for: base),
            context: context
        )
    }

    /// Draw one card from the parts every composite shares. A tree supplies its own optional header
    /// and its own action list, so it enters here rather than through a closed composite's base.
    func apply(
        _ section: ExtensionUISurfaceSection,
        header cardHeader: ExtensionUISurfaceHeader?,
        state rawState: ExtensionUISurfaceState,
        actionIds: [String],
        tone rawTone: String?,
        value: String?,
        context: ExtensionSurfaceCompositeContext
    ) {
        self.context = context
        appliedSection = section
        let palette = context.palette
        let state = ExtensionSurfaceCompositeState(rawState)
        let tone = state == .failure ? ExtensionSurfaceTone.danger : ExtensionSurfaceTone(raw: rawTone)

        let title = Self.nonEmpty(cardHeader?.title)
        let subtitle = Self.nonEmpty(cardHeader?.subtitle)
        titleLabel.text = title
        titleLabel.textColor = palette.ui.fg
        subtitleLabel.text = subtitle
        subtitleLabel.textColor = palette.ui.comment
        subtitleLabel.isHidden = subtitle == nil
        // A tree's region may carry no header at all: the card then starts at its body.
        header.isHidden = title == nil && subtitle == nil

        let framed = drawsFrame(header: cardHeader, actionIds: actionIds, tone: tone, context: context)
        if framed {
            ExtensionNativeBlockStyle.applyInset(to: self, palette: palette)
            layer.borderWidth = tone == .neutral ? 0.5 : 1
            layer.borderColor = tone.color(palette).withAlphaComponent(tone == .neutral ? 0.08 : 0.4).cgColor
        } else {
            backgroundColor = .clear
            layer.borderWidth = 0
        }
        for constraint in columnInsets {
            constraint.constant = (constraint.firstAttribute == .top || constraint.firstAttribute == .leading ? 1 : -1)
                * (framed ? Self.cardPadding : 0)
        }

        header.accessibilityLabel = [title, subtitle].compactMap(\.self).joined(separator: ", ")
        header.accessibilityValue = state.isContent ? value : Self.stateWords(state)

        body.isHidden = !state.isContent
        stateView.isHidden = state.isContent
        body.spacing = bodySpacing
        column.setCustomSpacing(actionSpacing, after: body)
        if state.isContent {
            applyBody(section, context: context)
        } else {
            applyState(rawState, state: state, palette: palette)
        }

        let pending = context.pending(for: compositeId)
        actions.isHidden = actionIds.isEmpty
        if !actionIds.isEmpty {
            actions.apply(
                actionIds: actionIds,
                definitions: context.surface.actions,
                pending: pending,
                palette: palette,
                identifierRoot: identifier,
                primaryInBody: bodyOffersPrimaryAction,
                onAction: { [weak self] actionId in
                    guard let self, let context = self.context else { return }
                    context.onAction?(context.intent(compositeId: self.compositeId, actionId: actionId))
                }
            )
        }
    }

    private func applyState(
        _ state: ExtensionUISurfaceState,
        state kind: ExtensionSurfaceCompositeState,
        palette: ThemePalette
    ) {
        let words = Self.nonEmpty(state.title)
        let message = Self.nonEmpty(state.message)
        let loadState: LoadState = switch kind {
        case .loading:
            .loading(words ?? message)
        case .empty:
            .empty(title: words ?? String(localized: "Nothing Here"), systemImage: "tray", message: message)
        case .failure:
            .failed(title: words ?? String(localized: "Something Went Wrong"), message: message, retry: nil)
        case .content:
            .loading(nil)
        }
        stateView.configuration = UIContentUnavailableConfiguration.loadState(loadState, palette: palette)
        measureState()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private static func stateWords(_ state: ExtensionSurfaceCompositeState) -> String {
        switch state {
        case .loading: String(localized: "Loading")
        case .empty: String(localized: "Empty")
        case .failure: String(localized: "Failed")
        case .content: ""
        }
    }

    /// The unavailable view has no intrinsic height of its own inside a card, so the card measures
    /// it at the width it is shown at: the extension's words decide the height, never a clip.
    private func measureState() {
        let width = bounds.width > 0 ? bounds.width : (superview?.bounds.width ?? 280)
        let height = stateView.systemLayoutSizeFitting(
            CGSize(width: max(1, width - 20), height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let resolved = max(height, 96)
        guard abs(resolved - measuredStateHeight) > 0.5 else { return }
        measuredStateHeight = resolved
        stateHeight?.constant = resolved
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !stateView.isHidden { measureState() }
    }
}

// MARK: - statusCard

/// A job's steps, its phase, and the actions it offers. Steps reuse the activity rows and their
/// disclosure, so `extra` atoms paint through the block views that already draw them.
final class ExtensionSurfaceStatusCardView: ExtensionSurfaceCompositeCardView {
    private let phaseLabel = ExtensionNativeBlockStyle.label(.caption2, weight: .semibold)
    private let steps = ExtensionNativeActivityListView()

    override init(surfaceId: String, compositeId: String) {
        super.init(surfaceId: surfaceId, compositeId: compositeId)
        body.addArrangedSubview(phaseLabel)
        body.addArrangedSubview(steps)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func accessibilityValue(for base: ExtensionUISurfaceCompositeBase) -> String? {
        guard case .statusCard(let card)? = appliedSection else { return nil }
        return card.phase
    }

    override func applyBody(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {
        guard case .statusCard(let card) = section else { return }
        let palette = context.palette
        let phase = card.phase.trimmingCharacters(in: .whitespacesAndNewlines)
        phaseLabel.text = phase.isEmpty ? nil : phase.replacingOccurrences(of: "_", with: " ").capitalized
        phaseLabel.textColor = ExtensionSurfaceTone(raw: card.base.tone).color(palette)
        phaseLabel.isHidden = phaseLabel.text == nil

        let rows = (card.steps ?? []).map(Self.activityRow(for:))
        let root = identifier
        steps.apply(
            rows: rows,
            context: ExtensionNativeBlockContext(themeID: context.themeID),
            accessibilityIdentifier: { row in
                ExtensionSurfaceIdentity.element(root: root, key: row.id)
            }
        )
        steps.isHidden = rows.isEmpty
    }

    /// A step is an activity row: its state and detail, with `extra` atoms as the row's disclosure
    /// content, so one set of views draws both a v1 activity list and a status card.
    private static func activityRow(for step: ExtensionUISurfaceStep) -> ExtensionUIActivityRow {
        let blocks = (step.extra ?? []).compactMap { $0.nativeBlock(id: step.id) }
        return ExtensionUIActivityRow(
            id: step.id,
            title: step.title,
            subtitle: nil,
            detail: step.detail,
            state: step.state,
            progress: nil,
            link: nil,
            children: nil,
            blocks: blocks.isEmpty ? nil : blocks
        )
    }
}

// MARK: - checklist

/// A plan's items, each with its state and, when it has one, its detail behind a disclosure row.
final class ExtensionSurfaceChecklistView: ExtensionSurfaceCompositeCardView {
    private let items = ExtensionNativeActivityListView()

    override init(surfaceId: String, compositeId: String) {
        super.init(surfaceId: surfaceId, compositeId: compositeId)
        body.addArrangedSubview(items)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func applyBody(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {
        guard case .checklist(let card) = section else { return }
        let rows = card.items.map { item -> ExtensionUIActivityRow in
            let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            let blocks: [ExtensionUINativeBlock] = (detail?.isEmpty == false)
                ? [.text(
                    base: ExtensionUIBlockBase(id: item.id, accessibility: nil),
                    spans: [ExtensionUITextSpan(text: detail ?? "", role: nil, traits: nil, link: nil)]
                )]
                : []
            return ExtensionUIActivityRow(
                id: item.id,
                title: item.title,
                subtitle: nil,
                detail: nil,
                state: item.state,
                progress: nil,
                link: nil,
                children: nil,
                blocks: blocks.isEmpty ? nil : blocks
            )
        }
        let root = identifier
        items.apply(
            rows: rows,
            context: ExtensionNativeBlockContext(themeID: context.themeID),
            accessibilityIdentifier: { row in
                ExtensionSurfaceIdentity.element(root: root, key: row.id)
            }
        )
    }
}

// MARK: - dataTable

/// The table's one column plan. The header and every row lay their cells out between the same
/// leading inset and the same trailing gutter, so a column's title sits exactly over its cells;
/// the gutter is the row menu button and its margins, reserved whether or not a row has actions.
private enum ExtensionSurfaceTableMetrics {
    static let leadingInset: CGFloat = 6
    static let columnSpacing: CGFloat = 8
    static let menuButtonSize: CGFloat = 32
    static let menuButtonTrailing: CGFloat = 2
    static let menuButtonGap: CGFloat = 4

    /// Where the cells stop, on the header and on a row alike.
    static var rowMenuGutter: CGFloat { menuButtonTrailing + menuButtonSize + menuButtonGap }
}

/// A result table: the host's grid, the sorted column marked, and each row's actions on a context
/// menu and on its own menu button, with the row's first action on activation.
///
/// This is not `DelimitedTableRenderView`: that grid is a read-only reader body in a collection
/// view with fixed-height clipped cells and no row controls, while a surface table must host a
/// menu button and a touch target on every row and size itself inside a card. Only the column
/// plan is shared in spirit — equal columns between one leading inset and one trailing gutter.
final class ExtensionSurfaceDataTableView: ExtensionSurfaceCompositeCardView {
    private let headerRow = ExtensionSurfaceTableHeaderRow()
    private let rows = UIStackView()

    override init(surfaceId: String, compositeId: String) {
        super.init(surfaceId: surfaceId, compositeId: compositeId)
        rows.axis = .vertical
        rows.alignment = .fill
        rows.spacing = 2
        body.addArrangedSubview(headerRow)
        body.addArrangedSubview(rows)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func accessibilityValue(for base: ExtensionUISurfaceCompositeBase) -> String? {
        guard case .dataTable(let table)? = appliedSection else { return nil }
        // The catalog carries this format's plural forms, so one row reads "1 row".
        return String(localized: "\(table.rows.count) rows")
    }

    override func applyBody(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {
        guard case .dataTable(let table) = section else { return }
        headerRow.apply(columns: table.columns, sort: table.sort, palette: context.palette)
        var kept: [String: ExtensionSurfaceTableRowView] = [:]
        var ordered: [UIView] = []
        for row in table.rows where kept[row.id] == nil {
            let view = rows.arrangedSubviews
                .compactMap { $0 as? ExtensionSurfaceTableRowView }
                .first { $0.rowId == row.id } ?? ExtensionSurfaceTableRowView()
            view.apply(
                row: row,
                columns: table.columns,
                selected: row.id == table.selectedRowId,
                definitions: context.surface.actions,
                pending: context.pending(for: compositeId),
                palette: context.palette,
                identifier: ExtensionSurfaceIdentity.element(root: identifier, key: row.id),
                onAction: { [weak self] actionId in
                    guard let self, let context = self.context else { return }
                    context.onAction?(context.intent(
                        compositeId: self.compositeId,
                        actionId: actionId,
                        rowId: row.id
                    ))
                }
            )
            kept[row.id] = view
            ordered.append(view)
        }
        for view in rows.arrangedSubviews where !ordered.contains(where: { $0 === view }) {
            rows.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, view) in ordered.enumerated() {
            rows.insertArrangedSubview(view, at: index)
        }
    }
}

/// The table's column titles, with the sorted column marked. A `blocks` table draws the same grid
/// a `dataTable` does, so its column plan is shared rather than copied.
final class ExtensionSurfaceTableHeaderRow: UIView {
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = ExtensionSurfaceTableMetrics.columnSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: ExtensionSurfaceTableMetrics.leadingInset
            ),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -ExtensionSurfaceTableMetrics.rowMenuGutter
            ),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(columns: [ExtensionUISurfaceColumn], sort: ExtensionUISurfaceSort?, palette: ThemePalette) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for column in columns {
            let label = ExtensionNativeBlockStyle.label(.caption2, weight: .semibold)
            let isSorted = sort?.columnId == column.id
            label.text = column.title + (isSorted ? (sort?.descending == true ? " ▾" : " ▴") : "")
            label.textColor = isSorted ? palette.ui.fg : palette.ui.comment
            label.textAlignment = column.isNumeric ? .right : .natural
            stack.addArrangedSubview(label)
        }
        isHidden = columns.isEmpty
    }
}

/// One table row: its cells, the fill of a selected row, its actions on a context menu and a menu
/// button, and its first action on touch and on assistive activation alike.
final class ExtensionSurfaceTableRowView: UIControl {
    private let stack = UIStackView()
    private let menuButton = UIButton(type: .system)
    private var onAction: ((String) -> Void)?
    private var actionIds: [String] = []
    private var disabledActionIds: Set<String> = []
    private(set) var rowId: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .top
        stack.spacing = ExtensionSurfaceTableMetrics.columnSpacing
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.setContentHuggingPriority(.required, for: .horizontal)
        menuButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: ExtensionSurfaceTableMetrics.leadingInset
            ),
            // The cells stop at the gutter even when the row has no actions: hiding the button
            // does not release its constraints, so the header and every row share one grid.
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -ExtensionSurfaceTableMetrics.rowMenuGutter
            ),
            menuButton.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -ExtensionSurfaceTableMetrics.menuButtonTrailing
            ),
            menuButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: ExtensionSurfaceTableMetrics.menuButtonSize),
            menuButton.heightAnchor.constraint(equalToConstant: ExtensionSurfaceTableMetrics.menuButtonSize),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        row: ExtensionUISurfaceRow,
        columns: [ExtensionUISurfaceColumn],
        selected: Bool,
        definitions: [String: ExtensionUISurfaceActionDefinition],
        pending: ExtensionSurfacePendingAction?,
        palette: ThemePalette,
        identifier: String,
        onAction: ((String) -> Void)?
    ) {
        rowId = row.id
        self.onAction = onAction
        let actions = (row.actions ?? []).filter { definitions[$0] != nil }
        actionIds = actions
        disabledActionIds = pending?.disabledActionIds ?? []

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for column in columns {
            let label = ExtensionNativeBlockStyle.label(.caption1)
            label.text = row.cell(column.id).displayText
            label.textColor = palette.ui.fg
            label.textAlignment = column.isNumeric ? .right : .natural
            stack.addArrangedSubview(label)
        }
        backgroundColor = selected ? palette.ui.cyan.withAlphaComponent(0.10) : .clear
        layer.borderWidth = selected ? 1 : 0
        layer.borderColor = palette.ui.cyan.withAlphaComponent(0.35).cgColor

        menuButton.isHidden = actions.isEmpty
        menuButton.setImage(
            UIImage(
                systemName: "ellipsis.circle",
                // A fixed glyph keeps the button inside the row gutter the header also stops at;
                // a text-style symbol grows past it at accessibility sizes and squeezes the row.
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            ),
            for: .normal
        )
        menuButton.tintColor = palette.ui.comment
        menuButton.accessibilityIdentifier = "\(identifier).menu"
        menuButton.accessibilityLabel = String(localized: "Row Actions")
        menuButton.menu = actions.isEmpty ? nil : UIMenu(children: actions.compactMap { actionId -> UIMenuElement? in
            guard let definition = definitions[actionId] else { return nil }
            // One action waiting does not take the row's other actions away: only that item is
            // disabled, and the menu still opens.
            var attributes: UIMenuElement.Attributes = definition.isDestructive ? .destructive : []
            if disabledActionIds.contains(actionId) { attributes.insert(.disabled) }
            return UIAction(title: definition.title, attributes: attributes) { [weak self] _ in
                self?.onAction?(actionId)
            }
        })

        isAccessibilityElement = true
        accessibilityIdentifier = identifier
        accessibilityLabel = columns
            .map { "\($0.title), \(row.cell($0.id).displayText)" }
            .joined(separator: ". ")
        accessibilityValue = selected ? String(localized: "Selected") : nil
        accessibilityTraits = actions.isEmpty ? .staticText : .button
        accessibilityCustomActions = actions.compactMap { actionId in
            definitions[actionId].map { definition in
                UIAccessibilityCustomAction(name: definition.title) { [weak self] _ in
                    self?.onAction?(actionId)
                    return true
                }
            }
        }
        accessibilityHint = actions.first.flatMap { first in
            definitions[first].map { String(format: String(localized: "Double tap to %@"), $0.title) }
        }
    }

    /// The row's first action, run by touch and by assistive activation alike. A first action that
    /// is waiting on the server stays inert rather than running a different one.
    @objc private func handleTap() {
        guard let first = actionIds.first, !disabledActionIds.contains(first) else { return }
        onAction?(first)
    }

    override func accessibilityActivate() -> Bool {
        guard let first = actionIds.first, !disabledActionIds.contains(first) else { return false }
        onAction?(first)
        return true
    }
}

// MARK: - actionBar

/// The surface's actions as the card's whole content: the primary action, and the rest in an
/// overflow menu.
final class ExtensionSurfaceActionBarView: ExtensionSurfaceCompositeCardView {
    override func applyBody(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {
        // The card's action row is this composite's body; it has nothing else to draw.
    }
}

// MARK: - Unsupported

/// A section this build cannot draw: a labeled placeholder with the extension's own fallback
/// text, never a crash and never an empty card.
final class ExtensionSurfaceUnsupportedCardView: UIView {
    private let titleLabel = ExtensionNativeBlockStyle.label(.caption2, weight: .semibold)
    private let textLabel = ExtensionNativeBlockStyle.label(.caption1)

    init(surfaceId: String, compositeId: String) {
        super.init(frame: .zero)
        let column = UIStackView(arrangedSubviews: [titleLabel, textLabel])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = ExtensionSurfaceIdentity.composite(
            surfaceId: surfaceId,
            compositeId: compositeId
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {
        let palette = context.palette
        ExtensionNativeBlockStyle.applyInset(to: self, palette: palette)
        let fallback: String
        switch section {
        case .unsupported(let value):
            titleLabel.text = String(format: String(localized: "Unsupported card: %@"), value.composite)
            fallback = value.fallback.text
        case .blocks(let value):
            // A tree this build cannot draw keeps the words the server shipped with it.
            titleLabel.text = value.header?.title
            fallback = value.fallback.text
        default:
            return
        }
        titleLabel.textColor = palette.ui.comment
        let text = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        textLabel.text = text
        textLabel.textColor = palette.ui.fg
        textLabel.isHidden = text.isEmpty
        accessibilityLabel = titleLabel.text
        accessibilityValue = text.isEmpty ? nil : text
    }
}

// MARK: - Actions

/// The host's one native button for one action. A surface's action row and a `blocks` tree's own
/// button read their role, their destructive tint, their icon, and their waiting words from here,
/// so the two renderings cannot drift apart.
@MainActor
enum ExtensionSurfaceButtonFactory {
    /// The words a button shows while its action waits on the server.
    static func title(
        _ fallback: String,
        pending: ExtensionSurfacePendingAction?,
        actionId: String
    ) -> String {
        guard let pending, pending.actionId == actionId, let waiting = pending.title else {
            return fallback
        }
        return waiting
    }

    /// `role: primary` is the one emphasis in the vocabulary: only it fills with the accent. A
    /// primary fills the column and may wrap; a secondary keeps its own width, so its title stays on
    /// one line at an accessibility size instead of breaking inside a fixed capsule.
    static func configuration(
        title: String,
        isPrimary: Bool,
        isDestructive: Bool,
        icon: String?,
        palette: ThemePalette,
        compact: Bool = false
    ) -> UIButton.Configuration {
        if compact {
            return compactConfiguration(
                title: title,
                isDestructive: isDestructive,
                icon: icon,
                palette: palette
            )
        }
        var configuration = isPrimary ? UIButton.Configuration.borderedProminent() : .bordered()
        configuration.title = title
        configuration.titleLineBreakMode = isPrimary ? .byWordWrapping : .byTruncatingTail
        if let icon {
            configuration.image = UIImage.scaledSymbol(icon, style: .body, weight: .semibold)
            // The button resolves the glyph at the text style it is drawn at, so the symbol grows
            // with the title beside it instead of staying at whatever size this pass baked.
            configuration.preferredSymbolConfigurationForImage =
                UIImage.SymbolConfiguration(textStyle: .body)
                    .applying(UIImage.SymbolConfiguration(weight: .semibold))
        }
        if isPrimary {
            configuration.baseForegroundColor = palette.ui.bg
            configuration.baseBackgroundColor = isDestructive ? palette.ui.red : palette.ui.cyan
        } else {
            configuration.baseForegroundColor = isDestructive ? palette.ui.red : palette.ui.fg
        }
        return configuration
    }

    /// A row's trailing accessory: a tinted capsule one line of subheadline tall, drawn inside a
    /// frame of 44 pt so the target is the system's without the capsule being. The tint is the
    /// control's one colour, so destructive is red text on a quiet red fill rather than a button
    /// the size of its row.
    private static func compactConfiguration(
        title: String,
        isDestructive: Bool,
        icon: String?,
        palette: ThemePalette
    ) -> UIButton.Configuration {
        // A destructive accessory is red words on the quiet grey fill, not red on red.
        var configuration = isDestructive ? UIButton.Configuration.gray() : .tinted()
        configuration.title = title
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = ExtensionNativeBlockStyle.font(.subheadline, weight: .semibold)
            return attributes
        }
        if let icon {
            configuration.image = UIImage.scaledSymbol(icon, style: .subheadline, weight: .semibold)
            configuration.imagePadding = 4
        }
        configuration.baseForegroundColor = isDestructive ? palette.ui.red : palette.ui.cyan
        configuration.baseBackgroundColor = isDestructive ? palette.ui.fg.withAlphaComponent(0.12) : palette.ui.cyan
        // 12 pt above and below the words makes the frame 44 pt at the default size; the capsule
        // is painted 7 pt in from each, so it is the words plus 5 pt.
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 0)
        return configuration
    }
}

/// One card's actions: its primary action as a prominent button, and everything else in an
/// overflow menu. While an action waits on the server, its declared pending title stands in and
/// the ids it disables are disabled. A card whose body already offers a primary action keeps its
/// own row secondary, so one card never shows two primary buttons.
final class ExtensionSurfaceActionRow: UIView {
    private let stack = UIStackView()
    private var onAction: ((String) -> Void)?
    /// Whether this row shows no primary, so its buttons keep their own size side by side.
    private var demoted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        actionIds: [String],
        definitions: [String: ExtensionUISurfaceActionDefinition],
        pending: ExtensionSurfacePendingAction?,
        palette: ThemePalette,
        identifierRoot: String,
        primaryInBody: Bool = false,
        onAction: ((String) -> Void)?
    ) {
        self.onAction = onAction
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let known = actionIds.filter { definitions[$0] != nil }
        // The body's own primary owns the card's one emphasis; otherwise the declared primary — or
        // the first action — carries it.
        let primary = primaryInBody
            ? nil
            : known.first { definitions[$0]?.isPrimary == true } ?? known.first
        demoted = primary == nil
        // A long title at an accessibility size takes the full width instead of being clipped.
        applyAxis()
        let rest = known.filter { $0 != primary }
        if let primary, let definition = definitions[primary] {
            stack.addArrangedSubview(
                button(
                    actionId: primary,
                    definition: definition,
                    isPrimary: true,
                    pending: pending,
                    palette: palette,
                    identifierRoot: identifierRoot
                )
            )
        }
        if rest.count == 1, let only = rest.first, let definition = definitions[only] {
            stack.addArrangedSubview(
                button(
                    actionId: only,
                    definition: definition,
                    isPrimary: false,
                    pending: pending,
                    palette: palette,
                    identifierRoot: identifierRoot
                )
            )
        } else if !rest.isEmpty {
            stack.addArrangedSubview(
                overflowButton(
                    actionIds: rest,
                    definitions: definitions,
                    pending: pending,
                    palette: palette,
                    identifierRoot: identifierRoot
                )
            )
        }
        if demoted {
            // The leftover width goes to a spacer, so a secondary action keeps its own size beside
            // its siblings instead of stretching across the card.
            let spacer = UIView()
            spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
            stack.addArrangedSubview(spacer)
        }
    }

    private func applyAxis() {
        let isAccessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        stack.axis = isAccessibility ? .vertical : .horizontal
        stack.distribution = isAccessibility || demoted ? .fill : .fillProportionally
    }

    private func button(
        actionId: String,
        definition: ExtensionUISurfaceActionDefinition,
        isPrimary: Bool,
        pending: ExtensionSurfacePendingAction?,
        palette: ThemePalette,
        identifierRoot: String
    ) -> UIButton {
        let configuration = ExtensionSurfaceButtonFactory.configuration(
            title: ExtensionSurfaceButtonFactory.title(
                definition.title,
                pending: pending,
                actionId: actionId
            ),
            isPrimary: isPrimary,
            isDestructive: definition.isDestructive,
            icon: nil,
            palette: palette
        )
        let button = UIButton(configuration: configuration)
        button.isEnabled = pending?.disabledActionIds.contains(actionId) != true
        button.accessibilityIdentifier = ExtensionSurfaceIdentity.element(root: identifierRoot, key: actionId)
        button.accessibilityLabel = configuration.title
        button.addAction(UIAction { [weak self] _ in self?.onAction?(actionId) }, for: .touchUpInside)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    private func overflowButton(
        actionIds: [String],
        definitions: [String: ExtensionUISurfaceActionDefinition],
        pending: ExtensionSurfacePendingAction?,
        palette: ThemePalette,
        identifierRoot: String
    ) -> UIButton {
        var configuration = UIButton.Configuration.bordered()
        configuration.image = UIImage(
            systemName: "ellipsis",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .body)
        )
        configuration.baseForegroundColor = palette.ui.fg
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = ExtensionSurfaceIdentity.element(root: identifierRoot, key: "more")
        button.accessibilityLabel = String(localized: "More Actions")
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: actionIds.compactMap { actionId -> UIMenuElement? in
            guard let definition = definitions[actionId] else { return nil }
            // The ids the pressed action disabled are disabled one item at a time, so the menu
            // still opens with the rest.
            var attributes: UIMenuElement.Attributes = definition.isDestructive ? .destructive : []
            if pending?.disabledActionIds.contains(actionId) == true { attributes.insert(.disabled) }
            return UIAction(
                title: ExtensionSurfaceButtonFactory.title(
                    definition.title,
                    pending: pending,
                    actionId: actionId
                ),
                attributes: attributes
            ) { [weak self] _ in self?.onAction?(actionId) }
        })
        button.isEnabled = pending.map { pending in actionIds.contains { !pending.disabledActionIds.contains($0) } } ?? true
        return button
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            applyAxis()
        }
    }
}

// MARK: - Atoms

extension ExtensionUISurfaceAtom {
    /// The atom as the v1 block that already draws it, so a step's `extra` needs no second
    /// renderer. An atom this build cannot draw contributes nothing.
    func nativeBlock(id: String) -> ExtensionUINativeBlock? {
        let base = ExtensionUIBlockBase(id: id, accessibility: nil)
        switch self {
        case .text(let spans):
            return .text(base: base, spans: spans)
        case .markdown(let markdown):
            return .markdown(base: base, markdown: markdown)
        case .progress(let label, let value):
            return .progress(base: base, label: label, value: value, indeterminate: value == nil)
        case .divider:
            return .divider(base: base)
        case .spacer(let size):
            return .spacer(base: base, size: size)
        }
    }
}
