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

struct ExtensionSurfaceState: Equatable, Sendable {
    var title: String?
    var statuses: [String: ExtensionStatusState]
    var widgets: [String: ExtensionWidgetState]
    var nativeSurfaces: [String: ExtensionNativeSurfaceState]
    var widgetOrderCursor: Int
    var working: ExtensionWorkingState?
    var hiddenThinkingLabel: String?
    var toolsExpanded: Bool?

    init(
        title: String? = nil,
        statuses: [String: ExtensionStatusState] = [:],
        widgets: [String: ExtensionWidgetState] = [:],
        nativeSurfaces: [String: ExtensionNativeSurfaceState] = [:],
        widgetOrderCursor: Int = 0,
        working: ExtensionWorkingState? = nil,
        hiddenThinkingLabel: String? = nil,
        toolsExpanded: Bool? = nil
    ) {
        self.title = title
        self.statuses = statuses
        self.widgets = widgets
        self.nativeSurfaces = nativeSurfaces
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
        return hasTitle || hasStatuses || hasWidgets || hasNativeSurfaces
    }

    var hasRetainedContent: Bool {
        hasVisibleContent
            || working?.isDefault == false
            || !(hiddenThinkingLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || toolsExpanded != nil
    }

    mutating func nextWidgetOrder() -> Int {
        widgetOrderCursor += 1
        return widgetOrderCursor
    }
}

enum ExtensionSurfacePlacementGroup: Equatable, Sendable {
    case aboveEditor
    case belowEditor

    var showsChrome: Bool {
        self == .aboveEditor
    }

    func includes(widgetPlacement: String?) -> Bool {
        switch self {
        case .aboveEditor:
            return widgetPlacement != "belowEditor"
        case .belowEditor:
            return widgetPlacement == "belowEditor"
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
        hasVisibleMetadata(in: placement) || !widgetEntries(in: placement).isEmpty
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
