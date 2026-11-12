import UIKit

/// What an extension strip pill does about its chat's panel pane
/// (`PaneRoute.panel`): whether the pane shows the pill's surface, what a tap
/// does, and the Open in Pane action. It reads only the surface id and the
/// protocol's panel placement, so every extension takes the same path.
@MainActor
struct ExtensionPanelPillRole {
    /// The pane beside the chat shows this pill's surface: the pill draws
    /// selected, and a tap focuses the pane, since the drawer would show it
    /// twice.
    let inPane: Bool
    /// Open in Pane, for the pill's menu and its accessibility action: beside
    /// the chat only (a narrow window has no pane to open), for a surface the
    /// pane does not show yet.
    let openInPane: (() -> Void)?
    private let tap: (() -> Void)?

    /// - Parameters:
    ///   - surfaceId: the pill's surface, nil for an entry that is not one.
    ///   - opensPanel: the surface's pill opens its pane, with no drawer
    ///     (`placement.kind: "panel"`).
    ///   - shownSurfaceId: the surface the chat's pane shows now.
    init(
        surfaceId: String?,
        opensPanel: Bool,
        shownSurfaceId: String?,
        actions: ExtensionSurfaceDrawerActions
    ) {
        let inPane = surfaceId != nil && surfaceId == shownSurfaceId
        self.inPane = inPane
        let open = surfaceId.flatMap { surfaceId in actions.openPanel.map { open in { open(surfaceId) } } }
        if inPane {
            tap = { actions.focusPanel?() }
        } else if opensPanel, let open {
            tap = open
        } else {
            tap = nil
        }
        openInPane = actions.readerOpensBeside && !inPane ? open : nil
    }

    /// The pill's tap: the pane's, or else the drawer's `toggle`.
    func tapAction(toggle: @escaping () -> Void) -> () -> Void {
        tap ?? toggle
    }

    /// The pill's long-press menu while it offers Open in Pane.
    static func menu(_ openInPane: @escaping () -> Void) -> UIContextMenuConfiguration {
        let image = UIImage(systemName: "rectangle.righthalf.inset.filled")
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: String(localized: "Open in Pane"), image: image) { _ in openInPane() }])
        }
    }

    /// The same action for VoiceOver and Full Keyboard Access.
    static func accessibilityActions(_ openInPane: (() -> Void)?) -> [UIAccessibilityCustomAction]? {
        openInPane.map { open in
            [UIAccessibilityCustomAction(name: String(localized: "Open in Pane")) { _ in open(); return true }]
        }
    }
}
