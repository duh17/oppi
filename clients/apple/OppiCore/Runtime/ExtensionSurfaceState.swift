import Foundation

/// Focused-session extension UI snapshot. Identity is protocol metadata
/// (`widgetKey`, `nativeSurface.id`, placement), never a tool or extension name.
struct ExtensionStatusState: Equatable, Sendable {
    let key: String
    var text: String
    var extensionScopeId: String? = nil
    var extensionDisplayName: String? = nil
}

struct ExtensionWidgetState: Equatable, Sendable {
    let key: String
    var lines: [String]
    var placement: String?
    var extensionScopeId: String? = nil
    var extensionDisplayName: String? = nil
    var order: Int = 0
}

struct ExtensionNativeSurfaceState: Equatable, Sendable, Identifiable {
    let key: String
    let surface: ExtensionUINativeSurface
    var placement: String?
    var extensionScopeId: String? = nil
    var extensionDisplayName: String? = nil
    var order: Int = 0

    var id: String { surface.id }

    var hasVisibleContent: Bool {
        surface.hasVisibleContent
    }
}

struct ExtensionWorkingState: Equatable, Sendable {
    var message: String?
    var visible: Bool = true
    var indicator: ExtensionUIWorkingIndicator?

    var isDefault: Bool {
        (message?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && visible
            && indicator == nil
    }
}

/// One dismissed composable surface's revision floor: the id, the revision the dismissal carried,
/// and its place in the order the floors were recorded. A late frame at or below the floor stays
/// out, so a surface the person dismissed cannot come back under the same id.
struct ExtensionSurfaceDismissal: Equatable, Sendable {
    let surfaceId: String
    let revision: Int
}

/// One composable (v2) surface a session holds, in the order it first arrived.
struct ExtensionComposableSurfaceState: Equatable, Sendable, Identifiable {
    var surface: ExtensionUISurface
    var order: Int

    var id: String { surface.id }
}

/// One action on a composable surface, waiting for the server. The pressed action shows its
/// declared `pending` words and disables the ids it names until `extension_ui_settled` names this
/// request, or a frame newer than the revision it was sent at answers it.
struct ExtensionSurfacePendingAction: Equatable, Sendable {
    let requestId: String
    let surfaceId: String
    let compositeId: String
    let actionId: String
    let rowId: String?
    /// The blocks node that offered the action, when a tree's node did.
    let nodeId: String?
    /// The revision the action was sent at.
    let revision: Int
    let title: String?
    let disabledActionIds: Set<String>
}

/// What a tap on a card's action asks the host to send: the card, the action, and the row when the
/// action belongs to one. The host mints the request id and reads the revision to send at.
struct ExtensionSurfaceActionIntent: Equatable, Sendable {
    let surfaceId: String
    let compositeId: String
    let actionId: String
    let rowId: String?
    /// The blocks node that offered the action, when a tree's node did.
    let nodeId: String?
    let revision: Int
    /// Values the tap carries: a toggle's new value, or the ones a node action declares.
    let values: [String: JSONValue]?
    /// A node action's declared optimistic state; a closed composite's comes from the table.
    let pending: ExtensionUISurfacePendingState?

    init(
        surfaceId: String,
        compositeId: String,
        actionId: String,
        rowId: String? = nil,
        nodeId: String? = nil,
        revision: Int,
        values: [String: JSONValue]? = nil,
        pending: ExtensionUISurfacePendingState? = nil
    ) {
        self.surfaceId = surfaceId
        self.compositeId = compositeId
        self.actionId = actionId
        self.rowId = rowId
        self.nodeId = nodeId
        self.revision = revision
        self.values = values
        self.pending = pending
    }
}

struct ExtensionSurfaceState: Equatable, Sendable {
    var title: String?
    var statuses: [String: ExtensionStatusState]
    var widgets: [String: ExtensionWidgetState]
    var nativeSurfaces: [String: ExtensionNativeSurfaceState]
    /// Composable (v2) surfaces by protocol id. A surface replaces by id and outlives the turn
    /// that published it; `dismissedComposableSurfaces` keeps a late frame from bringing a
    /// dismissed one back.
    var composableSurfaces: [String: ExtensionComposableSurfaceState]
    /// Dismissals, oldest first, bounded by `rememberedDismissalLimit` the way the server bounds
    /// its revision floors: a session publishing thousands of short-lived surfaces must not
    /// carry them all for its whole life.
    var dismissedComposableSurfaces: [ExtensionSurfaceDismissal]
    var widgetOrderCursor: Int
    var working: ExtensionWorkingState?
    var hiddenThinkingLabel: String?
    var toolsExpanded: Bool?

    init(
        title: String? = nil,
        statuses: [String: ExtensionStatusState] = [:],
        widgets: [String: ExtensionWidgetState] = [:],
        nativeSurfaces: [String: ExtensionNativeSurfaceState] = [:],
        composableSurfaces: [String: ExtensionComposableSurfaceState] = [:],
        dismissedComposableSurfaces: [ExtensionSurfaceDismissal] = [],
        widgetOrderCursor: Int = 0,
        working: ExtensionWorkingState? = nil,
        hiddenThinkingLabel: String? = nil,
        toolsExpanded: Bool? = nil
    ) {
        self.title = title
        self.statuses = statuses
        self.widgets = widgets
        self.nativeSurfaces = nativeSurfaces
        self.composableSurfaces = composableSurfaces
        self.dismissedComposableSurfaces = dismissedComposableSurfaces
        self.widgetOrderCursor = widgetOrderCursor
        self.working = working
        self.hiddenThinkingLabel = hiddenThinkingLabel
        self.toolsExpanded = toolsExpanded
    }

    var hasVisibleContent: Bool {
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasStatuses = !statuses.isEmpty
        let hasWidgets = widgets.values.contains { !$0.lines.isEmpty }
        let hasNativeSurfaces = nativeSurfaces.values.contains { $0.hasVisibleContent }
        // Only the placement this build draws (the strip) makes the panel visible; a surface for a
        // presentation that arrives in a later slice stays in state without drawing anything.
        let hasComposableSurfaces = composableSurfaces.values.contains { $0.surface.placement.kind == "strip" }
        return hasTitle || hasStatuses || hasWidgets || hasNativeSurfaces || hasComposableSurfaces
    }

    var hasRetainedContent: Bool {
        hasVisibleContent
            || working?.isDefault == false
            || !(hiddenThinkingLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || toolsExpanded != nil
    }

    /// Dismissals remembered per session, the same bound the server keeps for its revision floors
    /// (`MAX_REMEMBERED_REVISIONS`).
    static let rememberedDismissalLimit = 64

    /// Record a dismissal, moving a reused id to the newest place and evicting the oldest floor
    /// past the bound.
    mutating func rememberDismissal(surfaceId: String, revision: Int) {
        forgetDismissal(for: surfaceId)
        dismissedComposableSurfaces.append(
            ExtensionSurfaceDismissal(surfaceId: surfaceId, revision: revision)
        )
        if dismissedComposableSurfaces.count > Self.rememberedDismissalLimit {
            dismissedComposableSurfaces.removeFirst()
        }
    }

    func dismissalRevision(for surfaceId: String) -> Int? {
        dismissedComposableSurfaces.first { $0.surfaceId == surfaceId }?.revision
    }

    mutating func forgetDismissal(for surfaceId: String) {
        dismissedComposableSurfaces.removeAll { $0.surfaceId == surfaceId }
    }

    mutating func nextWidgetOrder() -> Int {
        widgetOrderCursor += 1
        return widgetOrderCursor
    }

    /// The composable surfaces the strip draws in `placement`, oldest first.
    func composableSurfaceEntries(in placement: ExtensionSurfacePlacementGroup) -> [ExtensionComposableSurfaceState] {
        composableSurfaces.values
            .filter { entry in
                entry.surface.placement.kind == "strip"
                    && placement.includes(composablePlacement: entry.surface.placement.preferred)
            }
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }
}

enum ExtensionSurfacePlacementGroup: Equatable, Sendable {
    case aboveEditor
    case belowEditor

    var showsChrome: Bool {
        self == .aboveEditor
    }

    /// A v1 widget names `belowEditor` or nothing.
    func includes(widgetPlacement: String?) -> Bool {
        switch self {
        case .aboveEditor:
            return widgetPlacement != "belowEditor"
        case .belowEditor:
            return widgetPlacement == "belowEditor"
        }
    }

    /// A v2 surface names `aboveComposer` or `belowComposer`; the two vocabularies share these two
    /// groups, never their words.
    func includes(composablePlacement: String?) -> Bool {
        switch self {
        case .aboveEditor:
            return composablePlacement != "belowComposer"
        case .belowEditor:
            return composablePlacement == "belowComposer"
        }
    }
}

enum ExtensionSurfacePanelEntry: Equatable, Sendable, Identifiable {
    case native(ExtensionNativeSurfaceState)
    case widget(ExtensionWidgetState)

    var id: String {
        switch self {
        case .native(let nativeSurface): return "native:\(nativeSurface.key)"
        case .widget(let widget): return "widget:\(widget.key)"
        }
    }

    var order: Int {
        switch self {
        case .native(let nativeSurface): return nativeSurface.order
        case .widget(let widget): return widget.order
        }
    }

    var sortKey: String {
        switch self {
        case .native(let nativeSurface): return nativeSurface.key
        case .widget(let widget): return widget.key
        }
    }
}

extension ExtensionSurfaceState {
    func widgetEntries(in placement: ExtensionSurfacePlacementGroup) -> [ExtensionSurfacePanelEntry] {
        let nativeEntries = nativeSurfaces.values
            .filter { placement.includes(widgetPlacement: $0.placement) && $0.hasVisibleContent }
            .map(ExtensionSurfacePanelEntry.native)
        let textEntries = widgets.values
            .filter { placement.includes(widgetPlacement: $0.placement) && !$0.lines.isEmpty }
            .map(ExtensionSurfacePanelEntry.widget)

        return (nativeEntries + textEntries).sorted { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.sortKey.localizedCaseInsensitiveCompare(rhs.sortKey) == .orderedAscending
        }
    }

    func attachedStatus(for key: String, extensionScopeId: String?) -> ExtensionStatusState? {
        directlyAttachedStatus(key: key, extensionScopeId: extensionScopeId)
            ?? scopedSingletonStatus(extensionScopeId: extensionScopeId)
    }

    func attachedStatusText(for key: String, extensionScopeId: String?) -> String? {
        attachedStatus(for: key, extensionScopeId: extensionScopeId)?.text.extensionSurfaceTrimmedNonEmpty
    }

    func displayTitle(for widget: ExtensionWidgetState) -> String? {
        guard let attachedStatus = attachedStatus(for: widget.key, extensionScopeId: widget.extensionScopeId),
              attachedStatus.key != widget.key else {
            return nil
        }
        return widget.extensionDisplayName?.extensionSurfaceTrimmedNonEmpty
            ?? attachedStatus.extensionDisplayName?.extensionSurfaceTrimmedNonEmpty
    }

    func standaloneStatusEntries() -> [(id: String, key: String, text: String)] {
        let candidates = statuses
            .filter { _, status in
                !isAttachedStatus(status)
                    && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map { storageKey, status in
                (
                    id: storageKey,
                    key: status.key.trimmingCharacters(in: .whitespacesAndNewlines),
                    text: status.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            .filter { !$0.key.isEmpty && !$0.text.isEmpty }
            .sorted { lhs, rhs in
                let keyOrder = lhs.key.localizedCaseInsensitiveCompare(rhs.key)
                if keyOrder != .orderedSame { return keyOrder == .orderedAscending }
                return lhs.id < rhs.id
            }

        var seen = Set<String>()
        return candidates.filter { status in
            let identity = "\(status.key.lowercased())\u{1f}\(status.text)"
            return seen.insert(identity).inserted
        }
    }

    func hasVisibleMetadata(in placement: ExtensionSurfacePlacementGroup) -> Bool {
        guard placement.showsChrome else { return false }
        let hasTitle = !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasTitle || !standaloneStatusEntries().isEmpty
    }

    func hasVisibleContent(in placement: ExtensionSurfacePlacementGroup) -> Bool {
        hasVisibleMetadata(in: placement)
            || !widgetEntries(in: placement).isEmpty
            || !composableSurfaceEntries(in: placement).isEmpty
    }

    private func visibleSurfaceCount(in extensionScopeId: String?) -> Int {
        let widgetCount = widgets.values.filter { widget in
            widget.extensionScopeId == extensionScopeId && !widget.lines.isEmpty
        }.count
        let nativeCount = nativeSurfaces.values.filter { nativeSurface in
            nativeSurface.extensionScopeId == extensionScopeId && nativeSurface.hasVisibleContent
        }.count
        return widgetCount + nativeCount
    }

    private func statusCount(in extensionScopeId: String?) -> Int {
        statuses.values.filter { status in
            status.extensionScopeId == extensionScopeId
                && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private func hasVisibleSurface(key: String) -> Bool {
        // Pi/TUI widget and status keys are global identity. Scope metadata is
        // only a fallback for grouping related surfaces that use different keys.
        widgets.values.contains { widget in
            widget.key == key && !widget.lines.isEmpty
        } || nativeSurfaces.values.contains { nativeSurface in
            nativeSurface.key == key && nativeSurface.hasVisibleContent
        }
    }

    private func directlyAttachedStatus(key: String, extensionScopeId: String?) -> ExtensionStatusState? {
        guard hasVisibleSurface(key: key) else { return nil }
        return statuses.values.first { status in
            status.key == key
                && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func scopedSingletonStatus(extensionScopeId: String?) -> ExtensionStatusState? {
        guard extensionScopeId != nil,
              visibleSurfaceCount(in: extensionScopeId) == 1,
              statusCount(in: extensionScopeId) == 1 else {
            return nil
        }
        return statuses.values.first { status in
            status.extensionScopeId == extensionScopeId
                && !status.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func isAttachedStatus(_ status: ExtensionStatusState) -> Bool {
        if directlyAttachedStatus(key: status.key, extensionScopeId: status.extensionScopeId) != nil {
            return true
        }
        guard status.extensionScopeId != nil else { return false }
        return visibleSurfaceCount(in: status.extensionScopeId) == 1
            && statusCount(in: status.extensionScopeId) == 1
    }
}

enum ExtensionSurfaceReducer {
    static func apply(_ notification: ExtensionUINotification, to surface: inout ExtensionSurfaceState) {
        switch notification.method {
        case "setStatus":
            guard let statusKey = notification.statusKey else { return }
            let normalized = notification.statusText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalized, !normalized.isEmpty {
                surface.statuses[statusKey] = ExtensionStatusState(
                    key: statusKey,
                    text: normalized,
                    extensionScopeId: notification.extensionScopeId,
                    extensionDisplayName: notification.extensionDisplayName
                )
            } else {
                surface.statuses.removeValue(forKey: statusKey)
            }

        case "setWidget":
            guard let widgetKey = notification.widgetKey else { return }
            if let nativeSurface = notification.nativeSurface, nativeSurface.hasVisibleContent {
                surface.widgets.removeValue(forKey: widgetKey)
                removeNativeWidgetSurfaces(widgetKey: widgetKey, from: &surface)
                let order = surface.nextWidgetOrder()
                surface.nativeSurfaces[nativeSurface.id] = ExtensionNativeSurfaceState(
                    key: widgetKey,
                    surface: nativeSurface,
                    placement: notification.widgetPlacement,
                    extensionScopeId: notification.extensionScopeId,
                    extensionDisplayName: notification.extensionDisplayName,
                    order: order
                )
            } else if let widgetLines = notification.widgetLines {
                removeNativeWidgetSurfaces(widgetKey: widgetKey, from: &surface)
                let normalizedLines = widgetLines
                    .map { $0.trimmingCharacters(in: .newlines) }
                    .filter { !$0.isEmpty }
                if normalizedLines.isEmpty {
                    surface.widgets.removeValue(forKey: widgetKey)
                } else {
                    let order = surface.nextWidgetOrder()
                    surface.widgets[widgetKey] = ExtensionWidgetState(
                        key: widgetKey,
                        lines: normalizedLines,
                        placement: notification.widgetPlacement,
                        extensionScopeId: notification.extensionScopeId,
                        extensionDisplayName: notification.extensionDisplayName,
                        order: order
                    )
                }
            } else {
                surface.widgets.removeValue(forKey: widgetKey)
                removeNativeWidgetSurfaces(widgetKey: widgetKey, from: &surface)
            }

        case "setTitle":
            let normalized = notification.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            surface.title = (normalized?.isEmpty == false) ? normalized : nil

        case "setWorkingMessage":
            var working = surface.working ?? ExtensionWorkingState()
            let normalized = notification.message?.trimmingCharacters(in: .whitespacesAndNewlines)
            working.message = (normalized?.isEmpty == false) ? normalized : nil
            surface.working = working.isDefault ? nil : working

        case "setWorkingVisible":
            var working = surface.working ?? ExtensionWorkingState()
            working.visible = notification.workingVisible ?? true
            surface.working = working.isDefault ? nil : working

        case "setWorkingIndicator":
            var working = surface.working ?? ExtensionWorkingState()
            working.indicator = notification.workingIndicator
            surface.working = working.isDefault ? nil : working

        case "setHiddenThinkingLabel":
            let normalized = notification.hiddenThinkingLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            surface.hiddenThinkingLabel = (normalized?.isEmpty == false) ? normalized : nil

        case "setToolsExpanded":
            surface.toolsExpanded = notification.toolsExpanded ?? false

        default:
            break
        }
    }

    private static func removeNativeWidgetSurfaces(
        widgetKey: String,
        from surface: inout ExtensionSurfaceState
    ) {
        let canonicalSurfaceId = "widget:\(widgetKey)"
        surface.nativeSurfaces = surface.nativeSurfaces.filter { entry in
            entry.value.surface.id != canonicalSurfaceId && entry.value.key != widgetKey
        }
    }

    // MARK: - Composable (v2) surfaces

    /// A published surface replaces the one the session holds under the same id. Revisions are
    /// monotonic per id, so a frame at or below the stored revision is a late duplicate and is
    /// dropped, and a frame at or below a dismissal's revision cannot bring a surface back.
    static func apply(_ surface: ExtensionUISurface, to state: inout ExtensionSurfaceState) {
        if let stored = state.composableSurfaces[surface.id], stored.surface.revision >= surface.revision {
            return
        }
        if state.composableSurfaces[surface.id] == nil,
           let dismissed = state.dismissalRevision(for: surface.id),
           surface.revision <= dismissed {
            return
        }
        let order = state.composableSurfaces[surface.id]?.order ?? state.nextWidgetOrder()
        state.composableSurfaces[surface.id] = ExtensionComposableSurfaceState(surface: surface, order: order)
        state.forgetDismissal(for: surface.id)
    }

    /// A patch merges into the surface the session holds. A patch for a surface this client does
    /// not hold, one at or below the stored revision, or one that does not apply whole is dropped
    /// without touching the surface.
    static func apply(_ patch: ExtensionUISurfacePatch, to state: inout ExtensionSurfaceState) {
        guard let stored = state.composableSurfaces[patch.surfaceId] else { return }
        guard patch.revision > stored.surface.revision else { return }
        if patch.removed {
            state.composableSurfaces.removeValue(forKey: patch.surfaceId)
            state.rememberDismissal(surfaceId: patch.surfaceId, revision: patch.revision)
            return
        }
        guard let change = patch.patch,
              let merged = ExtensionSurfacePatchApplier.apply(
                  change,
                  to: stored.surface,
                  revision: patch.revision
              ) else {
            return
        }
        state.composableSurfaces[patch.surfaceId] = ExtensionComposableSurfaceState(
            surface: merged,
            order: stored.order
        )
    }
}

extension String {
    var extensionSurfaceTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    var extensionSurfaceTrimmedNonEmpty: String? {
        self?.extensionSurfaceTrimmedNonEmpty
    }
}
