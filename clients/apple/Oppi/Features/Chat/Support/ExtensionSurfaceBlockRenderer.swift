import UIKit

// MARK: - Environment

/// What one `blocks` tree is drawn with: the card context it belongs to, the section its nodes name
/// in a tap, and the root every node id extends.
///
/// A tree carries no colour, font, padding, or size of its own — only a tone, a text style, a
/// spacing step, and a role — so this environment is the whole of how it is painted.
struct ExtensionSurfaceBlocksEnvironment {
    let context: ExtensionSurfaceCompositeContext
    let compositeId: String
    /// `extension.surface.<surfaceId>.<compositeId>` (or `.pill`): every node id extends this.
    let identifierRoot: String
    /// A strip pill's one line: nothing wraps, and text truncates instead of taking two lines.
    var inline = false
    /// Whether the node is a direct child of a row that holds more than controls: a control there is
    /// an accessory of that line, so it draws compact instead of as a block of its own.
    var isRowAccessory = false
    /// The card's own gap between the body's top-level children. A tree's spacing step is the
    /// protocol's; the card's rhythm is the host's, so only the body root carries it.
    var topLevelSpacing: CGFloat?

    var palette: ThemePalette { context.palette }
    /// The action waiting on the server for this section, when one is.
    var pending: ExtensionSurfacePendingAction? { context.pending(for: compositeId) }
    /// The v1 blocks a tree reuses paint with this.
    var nativeContext: ExtensionNativeBlockContext {
        ExtensionNativeBlockContext(themeID: context.themeID)
    }

    /// The identifier a node's id earns, or nil when the node has none.
    func identifier(for node: ExtensionUISurfaceNode) -> String? {
        node.id.map { ExtensionSurfaceIdentity.element(root: identifierRoot, key: $0) }
    }

    /// The tap a node's own action asks the host to send.
    func tap(for node: ExtensionUISurfaceNode, action: ExtensionUISurfaceNodeAction) -> (() -> Void)? {
        guard let nodeId = node.id else { return nil }
        return tap(nodeId: nodeId, action: action)
    }

    /// The tap a table row's action asks the host to send: the node and the row it names.
    func rowTap(
        for node: ExtensionUISurfaceNode,
        rowId: String,
        action: ExtensionUISurfaceNodeAction
    ) -> (() -> Void)? {
        guard let nodeId = node.id else { return nil }
        return tap(nodeId: nodeId, action: action, rowId: rowId)
    }

    /// The intent a toggle sends when the person moves it: the value the switch now shows.
    func toggle(
        for node: ExtensionUISurfaceNode,
        action: ExtensionUISurfaceNodeAction
    ) -> ((Bool) -> Void)? {
        guard let nodeId = node.id, let onAction = context.onAction else { return nil }
        let compositeId = compositeId
        let context = context
        return { isOn in
            onAction(context.intent(
                compositeId: compositeId,
                nodeId: nodeId,
                action: action,
                values: ["value": .bool(isOn)]
            ))
        }
    }

    /// The wait this node answers for. A wait names the node that sent it, so two nodes offering
    /// one action do not both show its declared words: only the sender is waiting.
    func wait(
        for action: ExtensionUISurfaceNodeAction,
        nodeId: String?
    ) -> ExtensionSurfacePendingAction? {
        guard let pending, pending.actionId == action.id else { return nil }
        guard let sender = pending.nodeId, sender != nodeId else { return pending }
        return nil
    }

    /// The wait as this node's row controls see it: a table row disables and marks its items by
    /// action id, so a wait from a sibling node leaves them alone.
    func wait(nodeId: String?) -> ExtensionSurfacePendingAction? {
        guard let pending else { return nil }
        guard let sender = pending.nodeId, sender != nodeId else { return pending }
        return pending.seenFromAnotherNode
    }

    func isDisabled(_ action: ExtensionUISurfaceNodeAction, nodeId: String?) -> Bool {
        wait(nodeId: nodeId)?.disabledActionIds.contains(action.id) == true
    }

    /// The words a control shows while its action waits on the server.
    func pendingTitle(
        for action: ExtensionUISurfaceNodeAction,
        nodeId: String?,
        fallback: String
    ) -> String {
        guard let wait = wait(for: action, nodeId: nodeId) else { return fallback }
        return wait.title ?? fallback
    }

    private func tap(
        nodeId: String,
        action: ExtensionUISurfaceNodeAction,
        rowId: String? = nil
    ) -> (() -> Void)? {
        guard let onAction = context.onAction else { return nil }
        let compositeId = compositeId
        let context = context
        return {
            onAction(context.intent(
                compositeId: compositeId,
                nodeId: nodeId,
                action: action,
                rowId: rowId
            ))
        }
    }
}

extension ExtensionSurfacePendingAction {
    /// The same wait seen from a node that did not send it: nothing is waiting for its actions,
    /// while the ids the wait disabled stay disabled.
    var seenFromAnotherNode: ExtensionSurfacePendingAction {
        ExtensionSurfacePendingAction(
            requestId: requestId,
            surfaceId: surfaceId,
            compositeId: compositeId,
            actionId: "",
            rowId: nil,
            nodeId: nodeId,
            revision: revision,
            title: nil,
            disabledActionIds: disabledActionIds
        )
    }
}

// MARK: - Metrics

/// The whole styling vocabulary a tree has, mapped onto the host's palette, type ramp, and spacing
/// steps. Nothing here reads a tool, extension, status, widget, or display name.
@MainActor
enum ExtensionSurfaceBlockMetrics {
    /// A tree's spacing step, pulled to the host's inline step inside a pill: 6 pt tight, 8 pt
    /// normal, so a pill's icon, words, and badge read as one line rather than two groups.
    static func spacing(_ raw: String?, inline: Bool = false) -> CGFloat {
        let step: CGFloat = raw == "tight" ? 4 : 8
        return inline ? max(6, step) : step
    }

    /// A text style's face. The ramp is the system list's: `headline` is the row title (body,
    /// semibold) and `caption` its secondary line (footnote). Inside a strip pill the same three
    /// steps drop to the strip's own labels, so a composed pill reads like the ones the host
    /// derives from a header.
    static func font(_ raw: String?, inline: Bool = false, monospacedDigits: Bool = false) -> UIFont {
        switch (raw ?? "").lowercased() {
        case "headline":
            return inline
                ? ExtensionNativeBlockStyle.font(.caption1, weight: .semibold, monospacedDigits: monospacedDigits)
                : ExtensionNativeBlockStyle.font(.headline, weight: .semibold, monospacedDigits: monospacedDigits)
        case "caption":
            return inline
                ? ExtensionNativeBlockStyle.font(.caption2, weight: .semibold, monospacedDigits: monospacedDigits)
                : ExtensionNativeBlockStyle.font(.footnote, monospacedDigits: monospacedDigits)
        case "mono": return ExtensionNativeBlockStyle.font(inline ? .caption2 : .footnote, monospaced: true)
        default:
            return ExtensionNativeBlockStyle.font(inline ? .caption1 : .body, monospacedDigits: monospacedDigits)
        }
    }

    /// A text node's ink: its tone, and for an unstyled tone the host's foreground — except
    /// `caption`, which is secondary text and takes the host's secondary ink.
    static func textColor(_ raw: String?, style: String?, _ palette: ThemePalette) -> UIColor {
        if (style ?? "").lowercased() == "caption", ExtensionSurfaceTone(raw: raw) == .neutral {
            return palette.ui.comment
        }
        return textColor(raw, palette)
    }

    static func color(_ raw: String?, _ palette: ThemePalette) -> UIColor {
        ExtensionSurfaceTone(raw: raw).color(palette)
    }

    /// A tone as text: neutral stays the host's foreground, so an unstyled node is not greyed out.
    static func textColor(_ raw: String?, _ palette: ThemePalette) -> UIColor {
        let tone = ExtensionSurfaceTone(raw: raw)
        return tone == .neutral ? palette.ui.fg : tone.color(palette)
    }

    /// A text node's own width cap inside a pill, which has one line to give.
    static let inlineTextMaxWidth: CGFloat = 180

    /// The host's selected item: a tinted capsule with a hairline, the way a list marks the item a
    /// person picked. One look for every kind that can carry a selection, so a selected row, chip,
    /// button, and badge read as the same state.
    static func selectionFill(_ palette: ThemePalette) -> UIColor {
        palette.ui.cyan.withAlphaComponent(0.16)
    }

    static func selectionBorder(_ palette: ThemePalette) -> UIColor {
        palette.ui.cyan.withAlphaComponent(0.45)
    }

    /// Paint, or clear, the selected look on a region. The capsule keeps its own radius: a region
    /// that grows into a column at an accessibility size stays a rounded block, not a lozenge.
    static func paintSelection(_ selected: Bool, on view: UIView, palette: ThemePalette) {
        view.backgroundColor = selected ? selectionFill(palette) : .clear
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = selected ? 1 : 0
        view.layer.borderColor = selectionBorder(palette).cgColor
    }

    /// The radius a selected region's capsule takes at the height it is drawn.
    static func selectionRadius(_ bounds: CGRect) -> CGFloat {
        min(bounds.height / 2, 14)
    }
}

/// A node view that takes a column's whole width when its tree stacks, so text wraps instead of
/// overflowing and a capsule badge keeps its own size instead of stretching across the card.
protocol BlocksColumnFillable: UIView {
    /// Whether this node wants the whole column today. A primary button spans the card; a
    /// secondary button or a menu keeps its intrinsic width beside its siblings.
    var fillsColumn: Bool { get }
}

extension BlocksColumnFillable {
    var fillsColumn: Bool { true }
}

// MARK: - Renderer

/// One `blocks` section's tree, mapped onto UIKit. A node's view is reused across publications by
/// its position and kind, so a patch updates the view a person is looking at instead of replacing
/// the tree under them.
///
/// Layout is the host's: a row is a horizontal stack that becomes a column when its children cannot
/// fit the width it gets or at an accessibility text size; a stack is always a column. Every
/// control answers through `context.intent(compositeId:nodeId:action:rowId:values:)`, so a tap
/// names the node that offered it. A kind this build does not draw keeps the words it arrived with.
@MainActor
final class BlocksRenderer {
    private var views: [String: UIView] = [:]
    private var live: Set<String> = []

    /// Draw `node` as the view its cached position and kind already owns, or a new one.
    func render(
        _ node: ExtensionUISurfaceNode,
        path: String,
        environment: ExtensionSurfaceBlocksEnvironment
    ) -> UIView {
        let key = "\(path)#\(node.kind)"
        live.insert(key)
        switch node {
        case .row(let layout):
            let view: BlocksLayoutView = cached(key, BlocksLayoutView())
            view.apply(
                children: children(
                    layout.children,
                    path: path,
                    environment: environment,
                    rowAccessories: layout.children.contains { !Self.isControl($0) }
                ),
                node: node,
                action: layout.action,
                spacing: environment.topLevelSpacing
                    ?? ExtensionSurfaceBlockMetrics.spacing(layout.spacing, inline: environment.inline),
                align: layout.align,
                isRow: true,
                inline: environment.inline,
                selected: layout.selected == true,
                disabled: layout.disabled == true,
                environment: environment
            )
            return view
        case .stack(let layout):
            let view: BlocksLayoutView = cached(key, BlocksLayoutView())
            view.apply(
                children: children(layout.children, path: path, environment: environment),
                node: node,
                action: layout.action,
                spacing: environment.topLevelSpacing
                    ?? ExtensionSurfaceBlockMetrics.spacing(layout.spacing, inline: environment.inline),
                align: nil,
                isRow: false,
                inline: environment.inline,
                selected: false,
                disabled: layout.disabled == true,
                environment: environment
            )
            return view
        case .group(let group):
            let view: BlocksGroupView = cached(key, BlocksGroupView())
            view.apply(
                title: group.title,
                collapsed: group.collapsed,
                children: children(group.children, path: path, environment: environment),
                node: node,
                environment: environment
            )
            return view
        case .text(let text):
            let view: BlocksTextView = cached(key, BlocksTextView())
            view.apply(text: text, node: node, action: text.action, environment: environment)
            return view
        case .badge(let badge):
            let view: BlocksBadgeView = cached(key, BlocksBadgeView())
            view.apply(badge: badge, node: node, action: badge.action, environment: environment)
            return view
        case .icon(let icon):
            let view: BlocksIconView = cached(key, BlocksIconView())
            view.apply(icon: icon, node: node, environment: environment)
            return view
        case .elapsed(let elapsed):
            let view: BlocksElapsedView = cached(key, BlocksElapsedView())
            view.apply(elapsed: elapsed, node: node, environment: environment)
            return view
        case .progress(let progress):
            if progress.isRing {
                let view: BlocksProgressRingView = cached(key, BlocksProgressRingView())
                view.apply(progress: progress, node: node, environment: environment)
                return view
            }
            let view: ExtensionNativeProgressBlockView = cached(key, ExtensionNativeProgressBlockView())
            view.apply(
                .progress(
                    base: Self.base(progress.base),
                    label: progress.label,
                    value: progress.value,
                    indeterminate: progress.value == nil
                ),
                context: environment.nativeContext,
                tint: ExtensionSurfaceTone(raw: progress.tone) == .neutral
                    ? nil
                    : ExtensionSurfaceBlockMetrics.color(progress.tone, environment.palette)
            )
            view.accessibilityIdentifier = environment.identifier(for: node)
            return view
        case .markdown(let markdown):
            let view: ExtensionNativeMarkdownBlockView = cached(key, ExtensionNativeMarkdownBlockView())
            view.apply(
                .markdown(base: Self.base(markdown.base), markdown: markdown.markdown),
                context: environment.nativeContext
            )
            view.accessibilityIdentifier = environment.identifier(for: node)
            return view
        case .code(let code):
            let view: NativeCodeBlockView = cached(key, NativeCodeBlockView())
            view.apply(
                .code(base: Self.base(code.base), language: code.language, text: code.text),
                context: environment.nativeContext
            )
            view.accessibilityIdentifier = environment.identifier(for: node)
            return view
        case .chart(let chart):
            let view: ExtensionNativeChartBlockView = cached(key, ExtensionNativeChartBlockView())
            view.apply(
                .chart(
                    base: Self.base(chart.base),
                    kind: chart.kind,
                    title: chart.title,
                    labels: chart.labels,
                    series: chart.series.map {
                        ExtensionUIChartSeries(name: $0.name, values: $0.values)
                    },
                    truncated: chart.truncated
                ),
                context: environment.nativeContext
            )
            view.accessibilityIdentifier = environment.identifier(for: node)
            return view
        case .table(let table):
            let view: BlocksTableView = cached(key, BlocksTableView())
            view.apply(table: table, node: node, environment: environment)
            return view
        case .keyValue(let keyValue):
            let view: BlocksKeyValueView = cached(key, BlocksKeyValueView())
            view.apply(pairs: keyValue.pairs, node: node, environment: environment)
            return view
        case .divider(let divider):
            let view: ExtensionNativeDividerView = cached(key, ExtensionNativeDividerView())
            view.apply(
                .divider(base: Self.base(divider)),
                context: environment.nativeContext,
                // A rule is a line of the card's own ink. The host's separator follows the device's
                // appearance, which over a themed card can land where nothing shows.
                tint: environment.palette.ui.fg.withAlphaComponent(0.12)
            )
            view.accessibilityIdentifier = environment.identifier(for: node)
            return view
        case .spacer(let spacer):
            let view: ExtensionNativeSpacerView = cached(key, ExtensionNativeSpacerView())
            view.apply(
                .spacer(base: Self.base(spacer.base), size: spacer.size),
                context: environment.nativeContext
            )
            view.accessibilityIdentifier = environment.identifier(for: node)
            return view
        case .button(let button):
            let view: BlocksButtonView = cached(key, BlocksButtonView())
            view.apply(button: button, node: node, environment: environment)
            return view
        case .toggle(let toggle):
            let view: BlocksToggleView = cached(key, BlocksToggleView())
            view.apply(toggle: toggle, node: node, environment: environment)
            return view
        case .menu(let menu):
            let view: BlocksButtonView = cached(key, BlocksButtonView())
            view.apply(menu: menu, node: node, environment: environment)
            return view
        case .unsupported(let unsupported):
            let view: BlocksUnsupportedView = cached(key, BlocksUnsupportedView())
            view.apply(unsupported: unsupported, node: node, environment: environment)
            return view
        }
    }

    /// Forget the views this pass did not draw. Their parents already dropped them.
    func endPass() {
        views = views.filter { live.contains($0.key) }
        live.removeAll()
    }

    private func children(
        _ nodes: [ExtensionUISurfaceNode],
        path: String,
        environment: ExtensionSurfaceBlocksEnvironment,
        rowAccessories: Bool = false
    ) -> [UIView] {
        // The card's own rhythm is the body root's; a nested level keeps its tree spacing.
        var nested = withoutTopLevelSpacing(environment)
        nested.isRowAccessory = rowAccessories
        return nodes.enumerated().map { index, child in
            render(child, path: "\(path).\(index)", environment: nested)
        }
    }

    /// A control, or the space between controls. A row of nothing else is a set of controls
    /// (segments, a toolbar) rather than a line of content with accessories, and keeps the card's
    /// own buttons, so its selected item still stands out from the rest.
    private static func isControl(_ node: ExtensionUISurfaceNode) -> Bool {
        switch node {
        case .button, .toggle, .menu, .spacer, .divider: true
        default: false
        }
    }

    private func withoutTopLevelSpacing(
        _ environment: ExtensionSurfaceBlocksEnvironment
    ) -> ExtensionSurfaceBlocksEnvironment {
        var nested = environment
        nested.topLevelSpacing = nil
        return nested
    }

    private static func base(_ base: ExtensionUISurfaceNodeBase) -> ExtensionUIBlockBase {
        ExtensionUIBlockBase(id: base.id, accessibility: base.accessibility)
    }

    /// The cached view for `key` when it is the class `make` builds. A different kind at the same
    /// position is a different class, so it gets a new view.
    private func cached<T: UIView>(_ key: String, _ make: @autoclosure () -> T) -> T {
        if let existing = views[key] as? T { return existing }
        let view = make()
        views[key] = view
        return view
    }
}

// MARK: - Words

/// Every string a node and its children paint, so one button element can speak for the words
/// inside it.
enum ExtensionSurfaceBlockWords {
    static func words(of node: ExtensionUISurfaceNode) -> String? {
        var parts: [String] = []
        func walk(_ node: ExtensionUISurfaceNode) {
            switch node {
            case .text(let value): parts.append(value.text)
            case .badge(let value): parts.append(value.text)
            // The count changes every second: the words carry its stable name, never the digits.
            case .elapsed(let value): parts.append(value.base.accessibility?.label ?? BlocksElapsedView.spokenName)
            case .progress(let value): parts.append(value.label ?? "")
            case .button(let value): parts.append(value.title)
            case .toggle(let value): parts.append(value.title)
            case .menu(let value): parts.append(value.title ?? "")
            case .table(let value): parts.append(contentsOf: value.columns)
            case .keyValue(let value): parts.append(contentsOf: value.pairs.flatMap { [$0.key, $0.value] })
            case .markdown(let value): parts.append(value.markdown)
            case .code(let value): parts.append(value.text)
            case .unsupported(let value): parts.append(value.text)
            case .icon, .row, .stack, .group, .chart, .divider, .spacer:
                node.children.forEach(walk)
            }
        }
        walk(node)
        let joined = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - Controls

/// A button or a menu: the host's bordered button, with the node's role, its icon, and the words
/// its action declares while it waits. A primary button takes the column's width; a secondary
/// button or a menu keeps its own size, so only the primary reads as the next step.
final class BlocksButtonView: UIButton, BlocksColumnFillable {
    private var onTap: (() -> Void)?
    private var onSelect: ((String) -> Void)?
    private(set) var isPrimary = false
    /// Set while the button is a row's trailing accessory (see `apply(button:)`).
    private var compact = false

    var fillsColumn: Bool { isPrimary }

    /// The smallest target a touch should have to land on; a compact capsule paints less than this
    /// and keeps its frame at it.
    private static let minimumTarget: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        button node: ExtensionUISurfaceButtonNode,
        node surfaceNode: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        let action = node.action
        isPrimary = node.isPrimary
        // A secondary control in a row of content is that row's accessory: a small tinted capsule
        // in a 44 pt target. Primary stays the card's one prominent block.
        compact = environment.isRowAccessory && !environment.inline && !node.isPrimary
        var configuration = ExtensionSurfaceButtonFactory.configuration(
            title: action.map {
                environment.pendingTitle(for: $0, nodeId: surfaceNode.id, fallback: node.title)
            } ?? node.title,
            isPrimary: node.isPrimary,
            isDestructive: node.isDestructive,
            icon: node.icon,
            palette: environment.palette,
            compact: compact
        )
        // The active item of a set of buttons: the host's selection, under the button's own role.
        let selected = node.selected == true
        if selected {
            let palette = environment.palette
            configuration.background.backgroundColor = ExtensionSurfaceBlockMetrics.selectionFill(palette)
            configuration.background.strokeColor = ExtensionSurfaceBlockMetrics.selectionBorder(palette)
            configuration.background.strokeWidth = 1
        }
        self.configuration = configuration
        isSelected = selected
        showsMenuAsPrimaryAction = false
        menu = nil
        isEnabled = node.disabled != true
            && (action.map { !environment.isDisabled($0, nodeId: surfaceNode.id) } ?? false)
        onSelect = nil
        onTap = action.flatMap { environment.tap(for: surfaceNode, action: $0) }
        removeTarget(self, action: #selector(runTap), for: .touchUpInside)
        addTarget(self, action: #selector(runTap), for: .touchUpInside)
        accessibilityIdentifier = environment.identifier(for: surfaceNode)
        accessibilityLabel = configuration.title
        accessibilityHint = node.base.accessibility?.hint
        accessibilityValue = node.base.accessibility?.value
        accessibilityTraits = Self.traits(enabled: isEnabled, selected: selected)
    }

    func apply(
        menu node: ExtensionUISurfaceMenuNode,
        node surfaceNode: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        isPrimary = false
        compact = false
        isSelected = false
        let configuration = ExtensionSurfaceButtonFactory.configuration(
            title: node.title ?? String(localized: "More Actions"),
            isPrimary: false,
            isDestructive: false,
            icon: node.icon,
            palette: environment.palette
        )
        self.configuration = configuration
        removeTarget(self, action: #selector(runTap), for: .touchUpInside)
        onTap = nil
        showsMenuAsPrimaryAction = true
        // One action waiting disables its own item; the menu still opens for the rest.
        menu = UIMenu(children: node.items.map { item in
            var attributes: UIMenuElement.Attributes = item.role == "destructive" ? .destructive : []
            if environment.isDisabled(item.action, nodeId: surfaceNode.id) {
                attributes.insert(.disabled)
            }
            let title = environment.pendingTitle(
                for: item.action,
                nodeId: surfaceNode.id,
                fallback: item.title
            )
            return UIAction(title: title, attributes: attributes) { [weak self] _ in
                self?.onSelect?(item.action.id)
            }
        })
        onSelect = { actionId in
            guard let item = node.items.first(where: { $0.action.id == actionId }) else { return }
            environment.tap(for: surfaceNode, action: item.action)?()
        }
        isEnabled = node.disabled != true
            && node.items.contains { !environment.isDisabled($0.action, nodeId: surfaceNode.id) }
        accessibilityIdentifier = environment.identifier(for: surfaceNode)
        accessibilityLabel = configuration.title
        accessibilityHint = node.base.accessibility?.hint
        accessibilityValue = node.base.accessibility?.value
        accessibilityTraits = Self.traits(enabled: isEnabled, selected: false)
    }

    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        if compact { size.height = max(size.height, Self.minimumTarget) }
        return size
    }

    /// A control that cannot be used says so, and one that is the active item of a set does too.
    private static func traits(enabled: Bool, selected: Bool) -> UIAccessibilityTraits {
        var traits: UIAccessibilityTraits = .button
        if !enabled { traits.insert(.notEnabled) }
        if selected { traits.insert(.selected) }
        return traits
    }

    @objc private func runTap() {
        guard isEnabled else { return }
        onTap?()
    }
}

/// A toggle: the host's switch, sending the value it now shows. A switch's position belongs to the
/// extension until the person moves it, so an idle apply puts it back at the value the surface
/// published: a round trip that failed leaves nothing on screen to keep. While this node's own
/// action is in flight the switch stays where the person put it, because repainting the still-old
/// published value would snap it back under their finger.
final class BlocksToggleView: UIView, BlocksColumnFillable {
    private let label = ExtensionNativeBlockStyle.label(.body)
    private let toggle = UISwitch()
    /// The host's capsule behind the switch: an off track is nearly the card's own colour, so the
    /// control gets its own surface to sit on.
    private let track = UIView()
    private var onChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let row = UIStackView(arrangedSubviews: [label, toggle])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The switch speaks its own value; the title is painted once, beside it.
        label.isAccessibilityElement = false
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        track.translatesAutoresizingMaskIntoConstraints = false
        track.isUserInteractionEnabled = false
        track.layer.cornerCurve = .continuous
        addSubview(row)
        row.insertSubview(track, at: 0)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.leadingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -3),
            track.trailingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 3),
            track.topAnchor.constraint(equalTo: toggle.topAnchor, constant: -3),
            track.bottomAnchor.constraint(equalTo: toggle.bottomAnchor, constant: 3),
        ])
        toggle.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        toggle node: ExtensionUISurfaceToggleNode,
        node surfaceNode: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        let palette = environment.palette
        let disabled = node.disabled == true
        label.text = node.title
        // A control nobody may use reads as unusable, words and track alike.
        label.textColor = palette.ui.fg.withAlphaComponent(disabled ? 0.55 : 1)
        toggle.onTintColor = palette.ui.cyan
        track.backgroundColor = palette.ui.fg.withAlphaComponent(0.06)
        track.layer.borderWidth = 0.5
        track.layer.borderColor = palette.ui.fg.withAlphaComponent(0.12).cgColor
        let wait = node.action.flatMap { environment.wait(for: $0, nodeId: surfaceNode.id) }
        // In flight: the person's position is the truth until the server answers.
        if wait == nil { toggle.setOn(node.value, animated: false) }
        toggle.isEnabled = !disabled && (node.action.map {
            !environment.isDisabled($0, nodeId: surfaceNode.id) && wait == nil
        } ?? false)
        alpha = disabled ? 0.55 : 1
        toggle.accessibilityIdentifier = environment.identifier(for: surfaceNode)
        toggle.accessibilityLabel = node.base.accessibility?.label ?? node.title
        toggle.accessibilityHint = node.base.accessibility?.hint
        toggle.accessibilityValue = node.base.accessibility?.value
        onChange = node.action.flatMap { environment.toggle(for: surfaceNode, action: $0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        track.layer.cornerRadius = track.bounds.height / 2
    }

    @objc private func valueChanged() {
        onChange?(toggle.isOn)
    }
}

// MARK: - Unsupported

/// A node kind this build does not draw: the kind it arrived as, and the words it shipped with.
final class BlocksUnsupportedView: UIView, BlocksColumnFillable {
    private let title = ExtensionNativeBlockStyle.label(.caption2, weight: .semibold)
    private let text = ExtensionNativeBlockStyle.label(.caption1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let column = UIStackView(arrangedSubviews: [title, text])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        unsupported node: ExtensionUISurfaceNodeUnsupported,
        node surfaceNode: ExtensionUISurfaceNode,
        environment: ExtensionSurfaceBlocksEnvironment
    ) {
        title.text = String(format: String(localized: "Unsupported block: %@"), node.type)
        title.textColor = environment.palette.ui.comment
        let words = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        text.text = words
        text.textColor = environment.palette.ui.fg
        text.isHidden = words.isEmpty
        accessibilityIdentifier = environment.identifier(for: surfaceNode)
        accessibilityLabel = title.text
        accessibilityValue = words.isEmpty ? nil : words
    }
}

/// The v1 blocks a tree reuses take a column's width, so their own measurement sees the width
/// they are drawn at.
extension ExtensionNativeMarkdownBlockView: BlocksColumnFillable {}
extension ExtensionNativeProgressBlockView: BlocksColumnFillable {}
extension ExtensionNativeChartBlockView: BlocksColumnFillable {}
extension NativeCodeBlockView: BlocksColumnFillable {}
extension ExtensionNativeDividerView: BlocksColumnFillable {}

// MARK: - Card

/// A `blocks` section: an optional header — a region may be nothing but its body — the tree the
/// server composed, and the region's own actions.
final class ExtensionSurfaceBlocksView: ExtensionSurfaceCompositeCardView {
    private let renderer = BlocksRenderer()

    /// A tree's levels are its groups: the card gives the body's top level 12 pt and the action row
    /// 14 pt, while a nested stack keeps the spacing step the tree asked for.
    override var bodySpacing: CGFloat { 12 }
    override var actionSpacing: CGFloat { 14 }

    override func drawsFrame(
        header: ExtensionUISurfaceHeader?,
        actionIds: [String],
        tone: ExtensionSurfaceTone,
        context: ExtensionSurfaceCompositeContext
    ) -> Bool {
        let hasHeader = (header?.title.isEmpty == false) || (header?.subtitle?.isEmpty == false)
        let alone = context.surface.sections.count == 1
        return !(alone && !hasHeader && actionIds.isEmpty && tone == .neutral)
    }

    override var bodyOffersPrimaryAction: Bool {
        guard case .blocks(let blocks)? = appliedSection else { return false }
        return Self.offersPrimary(blocks.body)
    }

    /// Whether any node the body draws asks for `role: primary`.
    private static func offersPrimary(_ node: ExtensionUISurfaceNode) -> Bool {
        switch node {
        case .button(let button):
            return button.isPrimary
        case .row, .stack, .group:
            return node.children.contains(where: offersPrimary)
        default:
            return false
        }
    }

    override func apply(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {
        guard case .blocks(let blocks) = section else { return }
        apply(
            section,
            header: blocks.header,
            state: blocks.state,
            actionIds: blocks.actions ?? [],
            tone: blocks.tone,
            value: nil,
            context: context
        )
    }

    override func applyBody(_ section: ExtensionUISurfaceSection, context: ExtensionSurfaceCompositeContext) {
        guard case .blocks(let blocks) = section else { return }
        let root = renderer.render(
            blocks.body,
            path: "0",
            environment: ExtensionSurfaceBlocksEnvironment(
                context: context,
                compositeId: compositeId,
                identifierRoot: identifier,
                topLevelSpacing: bodySpacing
            )
        )
        renderer.endPass()
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        body.addArrangedSubview(root)
    }
}

// MARK: - Pill

/// A surface's declared pill, ready to draw: the content row it composes and the context its tap
/// answers with.
struct ExtensionSurfacePillContent {
    /// A pill's own composite id: a pill tap names `pill`, never a section or a node.
    static let compositeId = "pill"

    let pill: ExtensionUISurfacePill
    let context: ExtensionSurfaceCompositeContext
}

/// The strip pill's own one-line summary: the facts the server composed for it, drawn instead of
/// the header-derived title. A pill holds inline facts only — never a control — so nothing inside
/// it is a tap target of its own; while the pill's tap is an action, its content is the button
/// that sends it.
final class ExtensionSurfacePillContentView: UIView, BlocksColumnFillable {
    private let renderer = BlocksRenderer()
    private var root: UIView?
    private(set) var words: String?
    /// Whether the row starts with an icon, which already says what the strip's tone dot would.
    private(set) var startsWithIcon = false
    /// VoiceOver's activation while the pill's tap is an action, where the content row is the body.
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The strip has one line to give: past this the content row's text truncates instead of
        // the pill growing wider than the strip that holds it.
        widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ content: ExtensionSurfacePillContent, identifierRoot: String) {
        let node = content.pill.content
        let view = renderer.render(
            node,
            path: "0",
            environment: ExtensionSurfaceBlocksEnvironment(
                context: content.context,
                compositeId: ExtensionSurfacePillContent.compositeId,
                identifierRoot: identifierRoot,
                inline: true
            )
        )
        renderer.endPass()
        if root !== view {
            root?.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            root = view
        }
        words = ExtensionSurfaceBlockWords.words(of: node)
        startsWithIcon = Self.leadsWithIcon(node)
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    /// Whether the first thing a row draws is a glyph of its own: an icon, a badge's symbol, or a
    /// progress ring. Each already says what the strip's tone dot would repeat.
    private static func leadsWithIcon(_ node: ExtensionUISurfaceNode) -> Bool {
        switch node {
        case .icon:
            return true
        case .badge(let badge):
            return badge.icon != nil
        case .progress(let progress):
            return progress.isRing
        case .row, .stack:
            return node.children.first.map(leadsWithIcon) ?? false
        default:
            return false
        }
    }
}
