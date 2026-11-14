import UIKit

// The window's pane tree beyond the routed leaf and its companion: the split
// leaves, each a stack of its own, laid out with the routed leaf's cell by
// the fit rule (`PanePresentation.resolve`, with overflow), the dividers
// between cells, each cell's grip and pane menu, and the pane commands the
// keyboard and accessibility run. The tree lives in `ScenePanes`; the host
// draws it and runs the operations the controls ask for.

/// A split leaf's stack and the entry its root shows.
struct PaneSplitLeaf {
    let controller: RouterNavigationController
    var entry: PaneStackEntry
    /// The width class the leaf was last given; nil before its first layout.
    var isRegular: Bool?
}

/// A divider drag in flight: the split, the two neighbours' lengths and
/// weights when it began, and the neighbour a release would collapse.
struct PaneSplitDrag {
    var place: PaneSplitDividerView.Place
    var before: CGFloat
    var after: CGFloat
    var minimumBefore: CGFloat
    var minimumAfter: CGFloat
    var weights: [Double]
    /// The leaves on either side, nil for a nested split (which does not
    /// collapse as a whole).
    var beforeLeaf: PaneID?
    var afterLeaf: PaneID?
    var collapsing: PaneID?
}

/// A direction a pane moves or a split opens toward.
enum PaneDirection: CaseIterable, Hashable, Sendable {
    case left, right, up, down

    var edge: PaneEdge {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .top
        case .down: .bottom
        }
    }

    var title: String {
        switch self {
        case .left: String(localized: "Left")
        case .right: String(localized: "Right")
        case .up: String(localized: "Up")
        case .down: String(localized: "Down")
        }
    }

    /// The arrow key toward this direction, as `UIKeyCommand` takes it.
    var arrowInput: String {
        switch self {
        case .left: UIKeyCommand.inputLeftArrow
        case .right: UIKeyCommand.inputRightArrow
        case .up: UIKeyCommand.inputUpArrow
        case .down: UIKeyCommand.inputDownArrow
        }
    }
}

extension PaneHostController {
    /// Split, Move and Move Divider need a wide window (build plan §1.5); a
    /// compact one keeps one pane. The host is the window's pane area and
    /// takes the window's traits, never a leaf's forced ones. The Split Panes
    /// experiment off takes splits away too: then no Split, web page beside
    /// the chat, or terminal or drop in a new pane is offered.
    var canSplit: Bool {
        panes.splitsEnabled && AdaptiveWidth.isWide(traitCollection)
            && panes.tree.leaves.count < PaneLayout.maximumLeaves
    }

    /// Whether `id` can collapse to a strip: another cell stays open beside it.
    func canCollapse(_ id: PaneID) -> Bool {
        (try? panes.cellLayout.collapse(id)) != nil
    }

    /// The cell `id` sits in now; nil when it is behind a zoom or in overflow.
    func cellFrame(_ id: PaneID) -> CGRect? { cellPresentation?.frames[id] }

    // MARK: Layout

    /// Lays the cells out by the fit rule: the routed leaf's cell (which the
    /// host fills with the primary and its companion) and each split leaf.
    func resolveCells() {
        var cells = panes.cellLayout
        // A compact window shows one pane at a time, the focused one, and the
        // chip lists the rest (build plan §1.5). The tree is unchanged.
        if showsChip(cells) { cells.zoomed = cells.focus }
        let resolved = presentation(of: cells, keyboardHeight: keyboardHeight, firstResponderCell: keyboardHeight > 0 ? firstResponderCell() : nil)
        cellPresentation = resolved
        // A collapsed routed leaf is its strip: the primary and its companion park.
        let routedCollapsed = cells.collapsed[panes.routedLeafID] != nil
        routedCell = routedCollapsed ? .zero : resolved.frames[panes.routedLeafID] ?? .zero
    }

    /// Where `cells` would sit in the host now, by the fit rule. With the
    /// keyboard up, the cell holding the first responder is drawn over its
    /// column when the keyboard would leave it under its minimum height
    /// (build plan §1.3), so a field in a short lower pane stays in sight.
    func presentation(of cells: PaneLayout, keyboardHeight: CGFloat = 0, firstResponderCell: PaneID? = nil) -> PanePresentation {
        // The split view's sidebar floats over the host's leading edge and
        // reaches it as the leading safe area: several panes fit and sit
        // beside it, never under it. One pane fills the host, as before, and
        // keeps its content clear of the sidebar through its own safe area.
        let sideInsets = cells.leaves.count > 1 && cells.zoomed == nil
            ? (leading: view.safeAreaInsets.left, trailing: view.safeAreaInsets.right)
            : (leading: 0, trailing: 0)
        var presentation = PanePresentation.resolve(
            cells,
            size: view.bounds.size,
            sidebarWidth: sideInsets.leading + sideInsets.trailing,
            bottomInset: view.safeAreaInsets.bottom,
            keyboardHeight: keyboardHeight,
            firstResponderLeaf: firstResponderCell,
            minimumSize: { [weak self] leaf in self?.minimumSize(of: leaf) ?? PaneMinimumSize.list },
            liveCap: PlatformCapabilities.livePaneLimit
        )
        presentation.frames = presentation.frames.mapValues { $0.offsetBy(dx: sideInsets.leading, dy: 0) }
        return presentation
    }

    /// A cell's minimum by what it shows: the routed leaf is a chat; a
    /// screen with no link is a list, but for a page waiting for its address.
    private func minimumSize(of leaf: PaneLeaf) -> CGSize {
        if leaf.id == panes.routedLeafID { return PaneMinimumSize.chat }
        let route = leaf.stack.last?.route ?? .sessions(workspace: nil)
        if case .local(let token) = route, case .browser? = PaneLocalScreen(token) { return PaneMinimumSize.browser }
        return PaneMinimumSize.standard(for: route) ?? PaneMinimumSize.list
    }

    /// The cell whose leaf holds the first responder (a field in its bar or
    /// content); nil when it is outside the panes (a sheet).
    private func firstResponderCell() -> PaneID? {
        guard let responder = Self.firstResponder(in: view) else { return nil }
        if let (id, _) = splitLeaves.first(where: { responder.isDescendant(of: $0.value.controller.view) }) { return id }
        return responder.isDescendant(of: view) ? panes.routedLeafID : nil
    }

    func layoutSplitLeaves() {
        guard let presentation = cellPresentation else { return }
        let collapsed = panes.collapsedCells
        for (id, leaf) in splitLeaves {
            let leafView: UIView = leaf.controller.view
            guard let frame = presentation.frames[id], !collapsed.contains(id) else {
                leafView.isHidden = true
                continue
            }
            leafView.isHidden = false
            if leafView.frame != frame { leafView.frame = frame }
            // A leaf lays out compact below 640 pt, as a window does.
            let isRegular = frame.width >= 640
            if leaf.isRegular != isRegular {
                splitLeaves[id]?.isRegular = isRegular
                leaf.controller.traitOverrides.horizontalSizeClass = isRegular ? .regular : .compact
            }
        }
        layoutDividers(presentation)
        layoutGrips(presentation)
        layoutStrips(presentation)
        layoutUndoToast()
    }

    /// The leaves a cell holds that have a frame, unioned.
    private func union(_ node: PaneNode, _ frames: [PaneID: CGRect]) -> CGRect? {
        let shown = node.leaves.compactMap { frames[$0.id] }
        return shown.isEmpty ? nil : shown.dropFirst().reduce(shown[0]) { $0.union($1) }
    }

    private func layoutDividers(_ presentation: PanePresentation) {
        var places: [(PaneSplitDividerView.Place, CGRect, Double)] = []
        let collapsed = panes.collapsedCells
        func isStrip(_ node: PaneNode) -> Bool {
            if case .leaf(let leaf) = node { return collapsed.contains(leaf.id) }
            return false
        }
        func walk(_ node: PaneNode, _ path: [Int]) {
            guard case .split(let axis, let children, let weights) = node else { return }
            let frames = children.map { union($0, presentation.frames) }
            for index in 0..<(children.count - 1) {
                // A strip beside it expands by its own tap, not a drag.
                guard let before = frames[index], let after = frames[index + 1],
                      !isStrip(children[index]), !isStrip(children[index + 1]) else { continue }
                let band = PaneDividerView.hitWidth
                let rect = axis == .row
                    ? CGRect(x: before.maxX + PanePresentation.dividerThickness / 2 - band / 2, y: min(before.minY, after.minY),
                             width: band, height: max(before.maxY, after.maxY) - min(before.minY, after.minY))
                    : CGRect(x: min(before.minX, after.minX), y: before.maxY + PanePresentation.dividerThickness / 2 - band / 2,
                             width: max(before.maxX, after.maxX) - min(before.minX, after.minX), height: band)
                let share = weights[index] / (weights[index] + weights[index + 1])
                places.append((PaneSplitDividerView.Place(path: path, index: index, axis: axis), rect, share))
            }
            for (index, child) in children.enumerated() { walk(child, path + [index]) }
        }
        if panes.cellLayout.zoomed == nil { walk(panes.cellLayout.root, []) }
        while splitDividers.count > places.count { splitDividers.removeLast().removeFromSuperview() }
        for (number, (place, rect, share)) in places.enumerated() {
            let divider: PaneSplitDividerView
            if number < splitDividers.count {
                divider = splitDividers[number]
                if divider.place != place { divider.place = place }
            } else {
                // Number 0 is the companion's divider.
                divider = PaneSplitDividerView(place: place, number: number + 1)
                wire(divider)
                splitDividers.append(divider)
                view.addSubview(divider)
            }
            divider.frame = rect
            divider.share = share
            view.bringSubviewToFront(divider)
        }
    }

    private func wire(_ divider: PaneSplitDividerView) {
        divider.onBegan = { [weak self, weak divider] in
            guard let self, let divider else { return }
            self.splitDragBegan(divider.place)
        }
        divider.onChanged = { [weak self] distance in self?.splitDragChanged(distance) }
        divider.onEnded = { [weak self] in self?.splitDragEnded() }
        divider.onStep = { [weak self, weak divider] delta in
            guard let self, let divider else { return }
            self.splitDragBegan(divider.place)
            self.splitDragChanged(delta)
            self.splitDragEnded()
        }
        divider.onEqualise = { [weak self, weak divider] in
            guard let self, let divider else { return }
            self.panes.equaliseCells(at: divider.place.path)
            self.relayoutCells()
        }
    }

    /// Lays everything out again now, after the tree changed.
    func relayoutCells() {
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    // MARK: Divider drags

    /// The least `node`, drawn at `frame`, may take along `axis`: at the
    /// window's bottom that is above the home indicator, as the fit rule has it.
    private func minimumLength(_ node: PaneNode, axis: PaneAxis, frame: CGRect) -> CGFloat {
        PanePresentation.minimumLength(
            of: node, along: axis, in: panes.cellLayout,
            bottomInset: view.safeAreaInsets.bottom,
            reachesBottom: frame.maxY >= view.bounds.maxY - 0.5,
            minimumSize: { [weak self] leaf in self?.minimumSize(of: leaf) ?? PaneMinimumSize.list }
        )
    }

    private func splitDragBegan(_ place: PaneSplitDividerView.Place) {
        guard let presentation = cellPresentation,
              case .split(_, let children, let weights)? = panes.cellLayout.root.node(at: place.path),
              let before = union(children[place.index], presentation.frames),
              let after = union(children[place.index + 1], presentation.frames) else { return }
        let length: (CGRect) -> CGFloat = { place.axis == .row ? $0.width : $0.height }
        let leafID: (PaneNode) -> PaneID? = { if case .leaf(let leaf) = $0 { leaf.id } else { nil } }
        splitDrag = PaneSplitDrag(
            place: place,
            before: length(before),
            after: length(after),
            minimumBefore: minimumLength(children[place.index], axis: place.axis, frame: before),
            minimumAfter: minimumLength(children[place.index + 1], axis: place.axis, frame: after),
            weights: weights,
            beforeLeaf: leafID(children[place.index]),
            afterLeaf: leafID(children[place.index + 1])
        )
        holdForResize(beginningAt: length(before))
    }

    /// Follows the finger, held at each neighbour's minimum. Past half of a
    /// leaf's minimum the release collapses that leaf to its strip (build
    /// plan R2), with a tick as the drag crosses in and out.
    private func splitDragChanged(_ distance: CGFloat) {
        guard var drag = splitDrag else { return }
        let total = drag.before + drag.after
        let raw = drag.before + distance
        let collapsing: PaneID? = if raw < drag.minimumBefore / 2 {
            drag.beforeLeaf
        } else if total - raw < drag.minimumAfter / 2 {
            drag.afterLeaf
        } else {
            nil
        }
        if collapsing != drag.collapsing {
            drag.collapsing = collapsing
            splitDrag = drag
            AppHaptics.selectionChanged()
        }
        let before = min(max(raw, min(drag.minimumBefore, total / 2)), max(total - drag.minimumAfter, total / 2))
        let pair = drag.weights[drag.place.index] + drag.weights[drag.place.index + 1]
        var weights = drag.weights
        weights[drag.place.index] = pair * Double(before / total)
        weights[drag.place.index + 1] = pair - weights[drag.place.index]
        panes.setCellWeights(at: drag.place.path, weights)
        resizeMoved(to: before)
    }

    private func splitDragEnded() {
        guard let drag = splitDrag else { return }
        splitDrag = nil
        resizeEnded()
        if let collapsing = drag.collapsing { collapse(collapsing) }
    }

    // MARK: Leaves

    /// Mounts a stack for each split leaf the tree has, rebuilds one whose
    /// entry changed, and removes the leaves the tree no longer has.
    func syncSplitLeaves() {
        let leaves = panes.splitLeaves
        let ids = Set(leaves.map(\.id))
        for id in splitLeaves.keys where !ids.contains(id) {
            guard let leaf = splitLeaves.removeValue(forKey: id) else { continue }
            Router.endSearch(in: leaf.controller) {}
            leaf.controller.willMove(toParent: nil)
            leaf.controller.view.removeFromSuperview()
            leaf.controller.removeFromParent()
            grips.removeValue(forKey: id)?.removeFromSuperview()
        }
        for leaf in leaves {
            guard let entry = leaf.stack.last else { continue }
            if let shown = splitLeaves[leaf.id] {
                guard shown.entry != entry else { continue }
                splitLeaves[leaf.id]?.entry = entry
                shown.controller.setViewControllers([makeScreen(entry, leaf: leaf.id)], animated: false)
                // The new screen's bar parts (a search field) arrive a turn later.
                DispatchQueue.main.async { [weak self] in self?.view.setNeedsLayout() }
                continue
            }
            let controller = RouterNavigationController(rootViewController: makeScreen(entry, leaf: leaf.id))
            let root = AppRootEnvironment.near(self)
            controller.interfaceStyle = { root?.themeStore.userInterfaceStyle ?? .unspecified }
            controller.view.backgroundColor = root?.themeStore.backgroundColor ?? .systemBackground
            controller.view.accessibilityIdentifier = "pane.leaf.\(leaf.id.raw)"
            controller.view.focusGroupIdentifier = "pane.\(leaf.id.raw)"
            addChild(controller)
            view.insertSubview(controller.view, belowSubview: cover)
            controller.didMove(toParent: self)
            splitLeaves[leaf.id] = PaneSplitLeaf(controller: controller, entry: entry)
        }
    }

    private func makeScreen(_ entry: PaneStackEntry, leaf id: PaneID) -> UIViewController {
        if let screen = openingScreens.removeValue(forKey: id) { return screen }
        if case .local(let token) = entry.route, let element = panes.standIns[token], let root = AppRootEnvironment.near(self) {
            return PaneSplitScreens.screen(for: element, root: root)
        }
        let restored = panes.takeRestored(id)
        return PaneSplitScreens.make(entry, root: AppRootEnvironment.near(self), restored: restored, actions: PaneSplitScreens.Actions(
            show: { [weak self] entry in
                self?.panes.show(entry, in: id)
                self?.focus(cell: id)
            },
            replaceRoot: { [weak self] screen in
                self?.splitLeaves[id]?.controller.setViewControllers([screen], animated: false)
            },
            close: { [weak self] in self?.closePane(id) },
            follow: { [weak self] entry in self?.leaf(id, follows: entry) }
        ))
    }

    /// The front screen of a cell, for its title and the grip's place.
    func frontScreen(ofCell id: PaneID) -> UIViewController? {
        let leaf: UIViewController? = id == panes.routedLeafID ? primary : splitLeaves[id]?.controller
        return (leaf as? UINavigationController)?.topViewController ?? leaf
    }

    // MARK: Grips

    /// Whether the window is compact and has more than one pane: the chip
    /// then stands in for the grips.
    func showsChip(_ cells: PaneLayout) -> Bool {
        !AdaptiveWidth.isWide(traitCollection) && cells.leaves.count > 1
    }

    private func layoutGrips(_ presentation: PanePresentation) {
        let cells = panes.cellLayout
        let order = cells.leaves.map(\.id)
        let zoomed = cells.zoomed
        let hasPanes = order.count > 1
        var shown: Set<PaneID> = []
        for id in order {
            reserveGripStrip(inCell: id, height: hasPanes ? PaneStripSlot.height : 0)
        }
        layoutChip(cells, presentation)
        let showsGrips = hasPanes && !showsChip(cells)
        let collapsed = panes.collapsedCells
        for id in order where showsGrips && !collapsed.contains(id) {
            guard var frame = presentation.frames[id] else { continue }
            if id == panes.routedLeafID, !primary.view.isHidden { frame = primary.view.frame }
            shown.insert(id)
            let grip = grips[id] ?? makeGrip(id)
            grip.show(PaneGripView.Shown(
                title: cellTitle(id),
                position: (order.firstIndex(of: id) ?? 0) + 1,
                count: order.count,
                isFocused: cells.focus == id && order.count > 1,
                isZoomed: zoomed == id,
                hasWaitingSheet: panes.sheets.waitingOwners.contains(id)
            ))
            let size = zoomed == id ? PaneGripView.capsuleSize : PaneGripView.size
            let top = gripTop(ofCell: id, in: frame) + (PaneStripSlot.height - size.height) / 2
            // A grip being dragged follows the finger by its transform.
            guard grip.transform.isIdentity else { continue }
            // Under a divider the divider's band takes the touches above the grip.
            grip.reachesUp = frame.minY <= view.bounds.minY
            grip.frame = CGRect(x: frame.midX - size.width / 2, y: top, width: size.width, height: size.height)
            grip.isHidden = false
            view.bringSubviewToFront(grip)
        }
        for (id, grip) in grips where !shown.contains(id) { grip.isHidden = true }
    }

    private func leafController(ofCell id: PaneID) -> UIViewController? {
        id == panes.routedLeafID ? primary : splitLeaves[id]?.controller
    }

    /// The strip under each pane's bar that its grip or chip sits in: the
    /// screens of the cell's stack start that much lower, so the grip covers
    /// nothing (a search field, a first row). Zero with one pane, as before.
    /// Each screen carries the strip's slot (`PaneStripSlot`), which Auto
    /// Layout keeps at the top of the strip as the bar changes height (a
    /// search that hides as the list scrolls); a slot that moves lays the
    /// panes out again.
    private func reserveGripStrip(inCell id: PaneID, height: CGFloat) {
        guard let navigation = leafController(ofCell: id) as? UINavigationController else { return }
        for screen in navigation.viewControllers {
            if screen.additionalSafeAreaInsets.top != height { screen.additionalSafeAreaInsets.top = height }
            guard height > 0, screen.isViewLoaded, PaneStripSlot.slot(in: screen) == nil else { continue }
            PaneStripSlot.install(in: screen) { [weak self] in self?.view.setNeedsLayout() }
        }
    }

    /// Where a cell's grip or chip goes: its front screen's strip slot, under
    /// the bar and anything the bar carries, never in the bar (a drag there
    /// moves a floating window), and never above the window's own top inset
    /// (status bar, window controls), which only a pane at the window's top
    /// meets. The leaf lays out first, so a root it just took has its bar.
    private func gripTop(ofCell id: PaneID, in frame: CGRect) -> CGFloat {
        var floor = max(frame.minY, view.safeAreaInsets.top)
        // Under a divider, clear the half of its grabber that reaches in, with a gap.
        if frame.minY > view.bounds.minY { floor += PaneSplitDividerView.grabberThickness }
        guard let leaf = leafController(ofCell: id), leaf.view.window != nil else { return floor }
        leaf.view.layoutIfNeeded()
        guard let screen = frontScreen(ofCell: id), let slot = PaneStripSlot.slot(in: screen) else { return floor }
        return max(floor, slot.convert(slot.bounds, to: view).minY)
    }

    // MARK: VoiceOver

    /// The "Panes" rotor: each shown pane's grip in tree order (its strip
    /// when collapsed, the chip on a compact window), so VoiceOver moves
    /// pane to pane and lands on the control that names the pane. Empty
    /// with one pane.
    func makePanesRotor() -> UIAccessibilityCustomRotor {
        UIAccessibilityCustomRotor(name: String(localized: "Panes")) { [weak self] predicate in
            guard let self else { return nil }
            let targets = self.panesRotorTargets()
            let current = predicate.currentItem.targetElement as? UIView
            let index = current.flatMap { current in targets.firstIndex { $0 === current } }
            let next = switch predicate.searchDirection {
            case .next: index.map { $0 + 1 } ?? 0
            case .previous: index.map { $0 - 1 } ?? targets.count - 1
            @unknown default: -1
            }
            guard targets.indices.contains(next) else { return nil }
            return UIAccessibilityCustomRotorItemResult(targetElement: targets[next], targetRange: nil)
        }
    }

    func panesRotorTargets() -> [UIView] {
        let cells = panes.cellLayout
        guard cells.leaves.count > 1 else { return [] }
        if showsChip(cells) { return chip.isHidden ? [] : [chip] }
        return cells.leaves.map(\.id).compactMap { id in
            if let strip = strips[id] { return strip }
            guard let grip = grips[id], !grip.isHidden else { return nil }
            return grip
        }
    }

    // MARK: Undo

    func makeUndoToast() -> PaneUndoToast {
        let toast = PaneUndoToast()
        toast.addAction(UIAction { [weak self] _ in self?.undoPanes() }, for: .primaryActionTriggered)
        view.addSubview(toast)
        return toast
    }

    /// Centred at the foot of the window, clear of a chat's composer.
    private func layoutUndoToast() {
        guard !undoToast.isHidden else { return }
        let size = undoToast.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let bottom = view.bounds.maxY - view.safeAreaInsets.bottom - 76
        undoToast.frame = CGRect(x: view.bounds.midX - size.width / 2, y: bottom - size.height, width: size.width, height: size.height)
        view.bringSubviewToFront(undoToast)
    }

    /// Offers Undo for the change just made.
    func offerUndo() {
        guard let action = panes.undoAction else { return }
        undoToast.show(action: action)
        view.setNeedsLayout()
    }

    /// Takes back the newest Close Pane, Move Pane or Reset Panes.
    func undoPanes() {
        undoToast.hide()
        guard panes.undo() else { return }
        syncSplitLeaves()
        relayoutCells()
        updateVisibility()
        announceLayoutChange()
    }

    // MARK: Chip

    /// The chip sits in the shown pane's strip under its bar, as a grip does.
    private func layoutChip(_ cells: PaneLayout, _ presentation: PanePresentation) {
        let order = cells.leaves.map(\.id)
        guard showsChip(cells), let index = order.firstIndex(of: cells.focus),
              var frame = presentation.frames[cells.focus] else {
            chip.isHidden = true
            return
        }
        let id = cells.focus
        if id == panes.routedLeafID, !primary.view.isHidden { frame = primary.view.frame }
        chip.show(PaneChipView.Shown(title: cellTitle(id), position: index + 1, count: order.count))
        let width = chip.fittingWidth(maximum: frame.width - 32)
        let top = gripTop(ofCell: id, in: frame) + (PaneStripSlot.height - PaneChipView.height) / 2
        chip.frame = CGRect(x: frame.midX - width / 2, y: top, width: width, height: PaneChipView.height)
        chip.isHidden = false
        view.bringSubviewToFront(chip)
    }

    func makeChip() -> PaneChipView {
        let chip = PaneChipView()
        chip.isHidden = true
        chip.items = { [weak self] in self?.paneListItems() ?? [] }
        chip.onStep = { [weak self] step in self?.showAdjacentPane(step) }
        view.addSubview(chip)
        return chip
    }

    /// Every pane by its title, in tree order; the chosen one shows.
    func paneListItems() -> [PaneMenuItem] {
        let cells = panes.cellLayout
        return cells.leaves.map(\.id).map { id in
            let title = cellTitle(id)
            return PaneMenuItem(
                title: title, symbol: "rectangle", actionName: String(localized: "Show \(title)"),
                identifier: "pane.list.\(id.raw)", isChecked: id == cells.focus,
                run: { [weak self] in self?.focus(cell: id) }
            )
        }
    }

    /// Shows the pane `step` places from the shown one in tree order, wrapping.
    func showAdjacentPane(_ step: Int) {
        let cells = panes.cellLayout
        let order = cells.leaves.map(\.id)
        guard order.count > 1, let index = order.firstIndex(of: cells.focus) else { return }
        focus(cell: order[(index + step + order.count) % order.count])
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    // MARK: Strips

    /// A collapsed cell is a 20 pt strip in its place; a tap expands it. A
    /// strip at the window's bottom sits above the home indicator: its cell
    /// reaches under it (the fit rule adds the inset), and the strip's part
    /// there only paints.
    private func layoutStrips(_ presentation: PanePresentation) {
        let collapsed = panes.collapsedCells
        for (id, strip) in strips where !collapsed.contains(id) || presentation.frames[id] == nil {
            strip.removeFromSuperview()
            strips[id] = nil
        }
        guard panes.cellLayout.zoomed == nil else { return }
        for id in collapsed {
            guard let frame = presentation.frames[id], let axis = stripAxis(id) else { continue }
            let strip = strips[id] ?? {
                let strip = PaneStripView(leafID: id)
                strip.onExpand = { [weak self] in self?.expand(id) }
                strips[id] = strip
                view.addSubview(strip)
                return strip
            }()
            strip.show(title: cellTitle(id), axis: axis)
            strip.frame = frame
            let reachesBottom = axis == .column && frame.maxY >= view.bounds.maxY - 0.5
            strip.bottomInset = reachesBottom ? max(0, frame.height - PanePresentation.collapsedThickness) : 0
            view.bringSubviewToFront(strip)
        }
    }

    /// The axis of the split a collapsed cell sits in.
    private func stripAxis(_ id: PaneID) -> PaneAxis? {
        let root = panes.cellLayout.root
        guard let path = root.path(of: id), !path.isEmpty,
              case .split(let axis, _, _)? = root.node(at: Array(path.dropLast())) else { return nil }
        return axis
    }

    /// A cell's title: its front screen's, else what its entry names.
    func cellTitle(_ id: PaneID) -> String {
        let screen = frontScreen(ofCell: id)
        return screen?.navigationItem.title ?? screen?.title ?? Self.title(of: panes.topEntry(of: id))
    }

    /// A pane's name for its grip when its screen has no title of its own.
    static func title(of entry: PaneStackEntry) -> String {
        switch entry.route {
        case .sessions: String(localized: "Sessions")
        case .files: String(localized: "Files")
        case .git, .commit: String(localized: "Git")
        case .file(_, let path, _): (path as NSString).lastPathComponent
        case .local(let token):
            switch PaneLocalScreen(token) {
            case .terminal?: String(localized: "Terminal")
            case .browser?: String(localized: "Web Page")
            case .launcher?, nil: String(localized: "New Pane")
            }
        default: String(localized: "Pane")
        }
    }

    private func makeGrip(_ id: PaneID) -> PaneGripView {
        let grip = PaneGripView(leafID: id)
        // Drag: the pane moves to another pane's edge, or swaps with it in
        // the middle (`gripPanned`).
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(gripPanned(_:))))
        grip.items = { [weak self] in self?.menuItems(for: id) ?? [] }
        grip.onRestore = { [weak self] in self?.zoom(nil) }
        grips[id] = grip
        view.addSubview(grip)
        return grip
    }

    /// The pane menu for `id`, as it is now.
    func menuItems(for id: PaneID) -> [PaneMenuItem] {
        let cells = panes.cellLayout
        let isZoomed = cells.zoomed == id
        let isSplitLeaf = id != panes.routedLeafID
        var items: [PaneMenuItem] = []
        if let action = panes.undoAction {
            items.append(PaneMenuItem(
                title: String(localized: "Undo \(action)"), symbol: "arrow.uturn.backward",
                actionName: String(localized: "Undo \(action)"), identifier: "pane.menu.undo",
                run: { [weak self] in self?.undoPanes() }
            ))
        }
        items += [
            PaneMenuItem(
                title: isZoomed ? String(localized: "Restore") : String(localized: "Zoom"),
                symbol: isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                actionName: isZoomed ? String(localized: "Restore") : String(localized: "Zoom"),
                identifier: "pane.menu.zoom",
                isEnabled: cells.leaves.count > 1,
                run: { [weak self] in self?.zoom(isZoomed ? nil : id) }
            ),
            PaneMenuItem(
                title: String(localized: "Split Right"), symbol: "rectangle.split.2x1",
                actionName: String(localized: "Split Right"), identifier: "pane.menu.splitRight",
                isEnabled: canSplit, run: { [weak self] in self?.split(id, axis: .row) }
            ),
            PaneMenuItem(
                title: String(localized: "Split Down"), symbol: "rectangle.split.1x2",
                actionName: String(localized: "Split Down"), identifier: "pane.menu.splitDown",
                isEnabled: canSplit, run: { [weak self] in self?.split(id, axis: .column) }
            ),
        ]
        items.append(PaneMenuItem(
            title: String(localized: "Collapse"), symbol: "rectangle.compress.vertical",
            actionName: String(localized: "Collapse"), identifier: "pane.menu.collapse",
            isEnabled: !isZoomed && canCollapse(id), run: { [weak self] in self?.collapse(id) }
        ))
        if isSplitLeaf {
            items.append(PaneMenuItem(
                title: String(localized: "Show in Pane"), symbol: "square.grid.2x2",
                actionName: String(localized: "Show in Pane"), identifier: "pane.menu.showInPane",
                run: { [weak self] in
                    guard let self else { return }
                    self.panes.show(self.panes.launcher(for: id), in: id)
                }
            ))
        }
        let moves = PaneDirection.allCases.map { direction in
            PaneMenuItem(
                title: direction.title, symbol: "arrow.\(direction == .up ? "up" : direction == .down ? "down" : direction == .left ? "left" : "right")",
                actionName: String(localized: "Move \(direction.title)"), identifier: "pane.menu.move.\(direction)",
                isEnabled: canMove(id, toward: direction),
                run: { [weak self] in self?.move(id, toward: direction) }
            )
        }
        if moves.contains(where: \.isEnabled) {
            items.append(PaneMenuItem(
                title: String(localized: "Move"), symbol: "arrow.up.and.down.and.arrow.left.and.right",
                actionName: String(localized: "Move"), identifier: "pane.menu.move", children: moves
            ))
        }
        let hidden = cellPresentation?.overflow ?? []
        if !hidden.isEmpty {
            items.append(PaneMenuItem(
                title: String(localized: "Hidden Panes"), symbol: "eye.slash",
                actionName: String(localized: "Hidden Panes"), identifier: "pane.menu.hidden",
                children: hidden.map { hiddenID in
                    let screen = frontScreen(ofCell: hiddenID)
                    let title = screen?.navigationItem.title ?? screen?.title ?? String(localized: "Pane")
                    return PaneMenuItem(
                        title: title, symbol: "rectangle", actionName: String(localized: "Show \(title)"),
                        identifier: "pane.menu.hidden.\(hiddenID.raw)",
                        run: { [weak self] in self?.focus(cell: hiddenID) }
                    )
                }
            ))
        }
        items.append(PaneMenuItem(
            title: String(localized: "Reset Panes"), symbol: "rectangle",
            actionName: String(localized: "Reset Panes"), identifier: "pane.menu.reset",
            isEnabled: cells.leaves.count > 1, run: { [weak self] in self?.resetPanes() }
        ))
        items.append(PaneMenuItem(
            title: String(localized: "Close Pane"), symbol: "xmark",
            actionName: String(localized: "Close Pane"), identifier: "pane.menu.close",
            isEnabled: isSplitLeaf, isDestructive: true,
            run: { [weak self] in self?.closePane(id) }
        ))
        return items
    }

    /// The cell whose leaf holds `screen`: the routed leaf's for the primary
    /// and its companion.
    func cell(holding screen: UIViewController) -> PaneID? {
        var child = screen
        while let parent = child.parent {
            if parent === self {
                return splitLeaves.first { $0.value.controller === child }?.key ?? panes.routedLeafID
            }
            child = parent
        }
        return nil
    }

    /// Split Right, Split Down and Undo for the pane holding `screen`, for
    /// that screen's own … menu: with one pane there is no grip, so this is
    /// the first split's touch path, and Undo's after the last pane closed.
    func splitItems(for screen: UIViewController) -> [PaneMenuItem] {
        guard canSplit, let cell = cell(holding: screen) else { return [] }
        let splits: Set<String> = ["pane.menu.undo", "pane.menu.splitRight", "pane.menu.splitDown"]
        return menuItems(for: cell).filter { splits.contains($0.identifier) }
    }

    // MARK: Operations

    /// The focused cell: the routed leaf's when its companion has focus.
    var focusedCell: PaneID { panes.cellLayout.focus }

    /// Splits `id` (the focused cell when nil). A new leaf that would go
    /// straight to overflow takes focus, so the person sees what they made.
    func split(_ id: PaneID? = nil, axis: PaneAxis) {
        guard canSplit, let made = panes.split(id ?? focusedCell, axis: axis) else { return }
        syncSplitLeaves()
        relayoutCells()
        if cellFrame(made) == nil { focus(cell: made) }
        announceLayoutChange()
    }

    /// Collapses `id` to its strip (a divider dragged past its minimum, or
    /// the pane menu).
    func collapse(_ id: PaneID) {
        guard panes.collapse(id) else { return }
        relayoutCells()
        updateVisibility()
        announceLayoutChange()
    }

    /// A strip's tap: its pane comes back at the share it had, focused.
    func expand(_ id: PaneID) {
        panes.expand(id)
        focus(cell: id)
        announceLayoutChange()
    }

    /// Opens `screen` in a new pane to the right of `id`, focused, with
    /// `entry` as what the pane shows. False when the window cannot split.
    @discardableResult
    func split(_ id: PaneID, showing entry: PaneStackEntry, screen: UIViewController) -> Bool {
        guard canSplit, let made = panes.split(id, edge: .right, showing: entry) else { return false }
        openingScreens[made] = screen
        syncSplitLeaves()
        openingScreens[made] = nil
        focus(cell: made)
        announceLayoutChange()
        return true
    }

    /// Zooms `id` to the whole window; nil restores every pane.
    func zoom(_ id: PaneID?) {
        panes.zoom(id)
        relayoutCells()
        updateVisibility()
        announceLayoutChange()
    }

    func closePane(_ id: PaneID) {
        panes.close(id)
        syncSplitLeaves()
        relayoutCells()
        updateVisibility()
        offerUndo()
        announceLayoutChange()
    }

    func resetPanes() {
        panes.resetPanes()
        syncSplitLeaves()
        relayoutCells()
        updateVisibility()
        offerUndo()
        announceLayoutChange()
    }

    func move(_ id: PaneID, toward direction: PaneDirection) {
        guard let target = neighbour(of: id, toward: direction) else { return }
        move(id, to: target, edge: direction.edge)
    }

    /// Moves `id` to `edge` of `target` (a grip dropped on a pane's edge).
    func move(_ id: PaneID, to target: PaneID, edge: PaneEdge) {
        panes.move(id, to: target, edge: edge)
        relayoutCells()
        offerUndo()
        announceLayoutChange()
    }

    /// Trades two panes' places (a grip dropped on a pane's middle).
    func swap(_ id: PaneID, with target: PaneID) {
        panes.swap(id, target)
        relayoutCells()
        offerUndo()
        announceLayoutChange()
    }

    /// Equal shares for every split (⌃⌘=).
    func equaliseSizes() {
        panes.equaliseCells()
        relayoutCells()
    }

    /// Focuses the pane beside the focused one (⌥⌘ arrows).
    func focusPane(toward direction: PaneDirection) {
        guard let target = neighbour(of: focusedCell, toward: direction) else { return }
        focus(cell: target)
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// Focuses the pane at `number` in tree order (⌃⌘1–8).
    func focusPane(number: Int) {
        let order = panes.cellLayout.leaves.map(\.id)
        guard order.indices.contains(number - 1) else { return }
        focus(cell: order[number - 1])
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    /// Whether `id` can move toward `direction`: a wide window, no zoom, and
    /// a pane there to move beside.
    func canMove(_ id: PaneID, toward direction: PaneDirection) -> Bool {
        AdaptiveWidth.isWide(traitCollection) && panes.cellLayout.zoomed == nil
            && neighbour(of: id, toward: direction) != nil
    }

    /// The divider ⌃⌘ arrows move: on the focused pane's trailing edge along
    /// the arrow's axis, else its leading edge, in the nearest split of that
    /// axis. Nil on a compact window, behind a zoom, or with no split there.
    private func dividerToMove(toward direction: PaneDirection) -> PaneSplitDividerView.Place? {
        let cells = panes.cellLayout
        guard AdaptiveWidth.isWide(traitCollection), cells.zoomed == nil,
              let path = cells.root.path(of: cells.focus) else { return nil }
        let axis = direction.edge.axis
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let splitPath = Array(path.prefix(depth))
            guard case .split(let splitAxis, let children, _)? = cells.root.node(at: splitPath), splitAxis == axis else { continue }
            let index = path[depth]
            return PaneSplitDividerView.Place(path: splitPath, index: index < children.count - 1 ? index : index - 1, axis: axis)
        }
        return nil
    }

    /// Whether ⌃⌘ arrows move a divider now: a split's, or the companion's
    /// beside the chat (left and right).
    func canMoveDivider(toward direction: PaneDirection) -> Bool {
        if dividerToMove(toward: direction) != nil { return true }
        return direction.edge.axis == .row && canStepCompanion
    }

    /// Moves that divider 32 pt toward the arrow, as VoiceOver's step does.
    func moveDivider(toward direction: PaneDirection) {
        let step = PaneDividerView.accessibilityStep
        let delta = direction == .left || direction == .up ? -step : step
        guard let place = dividerToMove(toward: direction) else {
            // The companion's width grows as its divider moves toward the chat.
            if direction.edge.axis == .row { stepCompanion(by: -delta) }
            return
        }
        splitDragBegan(place)
        splitDragChanged(delta)
        splitDragEnded()
    }

    /// Focuses a cell, bringing it out of overflow or behind a zoom.
    func focus(cell id: PaneID) {
        panes.focus(id)
        relayoutCells()
        updateVisibility()
    }

    /// The nearest shown cell beside `id` toward `direction`, overlapping it
    /// across that direction.
    func neighbour(of id: PaneID, toward direction: PaneDirection) -> PaneID? {
        guard let frames = cellPresentation?.frames, let from = frames[id] else { return nil }
        let candidates = frames.filter { other, frame in
            guard other != id else { return false }
            switch direction {
            case .left: return frame.maxX <= from.minX + 1 && frame.minY < from.maxY && frame.maxY > from.minY
            case .right: return frame.minX >= from.maxX - 1 && frame.minY < from.maxY && frame.maxY > from.minY
            case .up: return frame.maxY <= from.minY + 1 && frame.minX < from.maxX && frame.maxX > from.minX
            case .down: return frame.minY >= from.maxY - 1 && frame.minX < from.maxX && frame.maxX > from.minX
            }
        }
        return candidates.min { lhs, rhs in
            distance(from, lhs.value, direction) < distance(from, rhs.value, direction)
        }?.key
    }

    private func distance(_ from: CGRect, _ to: CGRect, _ direction: PaneDirection) -> CGFloat {
        switch direction {
        case .left: from.minX - to.maxX
        case .right: to.minX - from.maxX
        case .up: from.minY - to.maxY
        case .down: to.minY - from.maxY
        }
    }

    func announceLayoutChange() {
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}
