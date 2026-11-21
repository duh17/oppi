import UIKit

// The side arm of `SceneNavigation.open`: side content (a file, a folder, a
// web page, a session list, Git, a terminal, a game) lands in the pane the
// table names beside the one it came from, and the layout follows. A pane
// already showing the same kind takes it in place of what it showed; else a
// new pane splits beside the opener.

extension PaneHostController {
    /// Where side content of `kind` showing `route` lands in a pane beside, if
    /// one takes it: `PanePlacement.sideContent`, read from this window.
    func sidePlacement(
        of kind: PaneContentKind,
        showing route: WorkspaceStackRouteElement,
        from origin: OpenOrigin
    ) -> PanePlacement? {
        // A chat shows in one pane: a row or a link for it lands in the main
        // pane however the caller names it.
        guard !route.isChat else { return nil }
        // A game already on screen shows there rather than opening twice.
        if kind == .game, let shown = panes.cellLayout.leaves.first(where: { panes.stack(of: $0.id)?.top == route }) {
            return .reuse(shown.id)
        }
        return PanePlacement.sideContent(
            kind,
            from: origin,
            side: AppPreferenceStore.NewPanes.side(for: kind.setting, in: panes.preferences),
            isWide: AdaptiveWidth.isWide(traitCollection),
            canAddPane: panes.tree.leaves.count < PaneLayout.maximumLeaves,
            cells: panes.cellLayout,
            focused: focusedCell,
            mainLeaf: panes.mainLeafID,
            isPortrait: view.bounds.height > view.bounds.width,
            shown: { [weak self] in self?.shown($0) ?? .other },
            fits: { [weak self] target, edge in
                guard let self else { return false }
                // The probe stands for the pane the content would get, so its
                // minimum is the content's own.
                let probe = PaneEntries.entry(for: route)?.route ?? .file(.host, path: "", line: nil)
                return PaneOpenChoices.fits(edge, of: target, in: panes.cellLayout, showing: probe) {
                    self.presentation(of: $0)
                }
            }
        )
    }

    /// What `leaf` shows, as the table weighs it.
    func shown(_ leaf: PaneLeaf) -> PanePlacement.Shown {
        guard let top = panes.stack(of: leaf.id)?.top else { return .other }
        if top.isLauncher { return .launcher }
        return top.contentKind.map(PanePlacement.Shown.kind) ?? .other
    }

    /// Shows `route` in a pane beside: in place of what `pane` showed, or in a
    /// new pane at `edge` of it, focused. False when `placement` names no pane
    /// beside.
    @discardableResult
    func showBeside(_ route: WorkspaceStackRouteElement, kind: PaneContentKind?, _ placement: PanePlacement) -> Bool {
        switch placement {
        case .reuse(let pane):
            if case .entry(let entry) = route, case .browser(let url) = entry.route,
               let browser = frontScreen(ofCell: pane) as? BrowserPaneViewController {
                // A live page loads the link in place, keeping its history.
                browser.open(url)
            } else {
                panes.show(route, in: pane)
                syncSplitLeaves()
            }
            focus(cell: pane)
        case .split(let target, let edge):
            // A file beside a pane reads at its reading width; anything else,
            // or a pane below, halves the cell.
            let share = kind == .file && edge == .right ? readerShare(beside: target) : nil
            guard let made = panes.split(target, edge: edge, showing: route, share: share) else { return false }
            syncSplitLeaves()
            focus(cell: made)
        default:
            return false
        }
        announceLayoutChange()
        return true
    }

    /// The share of `target`'s cell a reader split off its trailing edge takes
    /// (`PaneReadingWidth.splitShare`).
    private func readerShare(beside target: PaneID) -> Double? {
        guard let width = cellFrame(target)?.width, let leaf = panes.cellLayout.leaf(target) else { return nil }
        return PaneReadingWidth.splitShare(of: width, neighbourMinimum: minimumSize(of: leaf).width)
    }

    /// Side content `opener` opens itself (a path in a terminal, the File
    /// Browser's row, the chat bar's Terminal, a Rex link): beside the opener's
    /// pane where the table puts it, else over the opener in its own pane.
    static func openBeside(_ content: PaneOpenContent, kind: PaneContentKind, from opener: UIViewController) {
        guard let host = containing(opener), let cell = host.cell(holding: opener),
              let root = AppRootEnvironment.near(opener) else { return }
        root.navigation.open(content.mainPaneDestination(coordinator: root.coordinator), from: .row(cell), beside: kind)
    }
}
