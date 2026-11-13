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
/// weights when it began.
struct PaneSplitDrag {
    var place: PaneSplitDividerView.Place
    var before: CGFloat
    var after: CGFloat
    var minimumBefore: CGFloat
    var minimumAfter: CGFloat
    var weights: [Double]
}

/// A direction a pane moves or a split opens toward.
enum PaneDirection: CaseIterable {
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
}

extension PaneHostController {
    /// Split, Move and Move Divider need a wide window (build plan §1.5); a
    /// compact one keeps one pane. The host is the window's pane area and
    /// takes the window's traits, never a leaf's forced ones.
    var canSplit: Bool {
        AdaptiveWidth.isWide(traitCollection) && panes.tree.leaves.count < PaneLayout.maximumLeaves
    }

    /// The cell `id` sits in now; nil when it is behind a zoom or in overflow.
    func cellFrame(_ id: PaneID) -> CGRect? { cellPresentation?.frames[id] }

    // MARK: Layout

    /// Lays the cells out by the fit rule: the routed leaf's cell (which the
    /// host fills with the primary and its companion) and each split leaf.
    func resolveCells() {
        let cells = panes.cellLayout
        let presentation = PanePresentation.resolve(
            cells,
            size: view.bounds.size,
            sidebarWidth: 0,
            keyboardHeight: 0,
            firstResponderLeaf: nil,
            minimumSize: { [panes] leaf in
                leaf.id == panes.routedLeafID
                    ? PaneMinimumSize.chat
                    : PaneMinimumSize.standard(for: leaf.stack.last?.route ?? .sessions(workspace: nil)) ?? PaneMinimumSize.list
            },
            liveCap: PlatformCapabilities.livePaneLimit
        )
        cellPresentation = presentation
        routedCell = presentation.frames[panes.routedLeafID] ?? .zero
    }

    func layoutSplitLeaves() {
        guard let presentation = cellPresentation else { return }
        for (id, leaf) in splitLeaves {
            let leafView: UIView = leaf.controller.view
            guard let frame = presentation.frames[id] else {
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
    }

    /// The leaves a cell holds that have a frame, unioned.
    private func union(_ node: PaneNode, _ frames: [PaneID: CGRect]) -> CGRect? {
        let shown = node.leaves.compactMap { frames[$0.id] }
        return shown.isEmpty ? nil : shown.dropFirst().reduce(shown[0]) { $0.union($1) }
    }

    private func layoutDividers(_ presentation: PanePresentation) {
        var places: [(PaneSplitDividerView.Place, CGRect, Double)] = []
        func walk(_ node: PaneNode, _ path: [Int]) {
            guard case .split(let axis, let children, let weights) = node else { return }
            let frames = children.map { union($0, presentation.frames) }
            for index in 0..<(children.count - 1) {
                guard let before = frames[index], let after = frames[index + 1] else { continue }
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

    private func minimumLength(_ node: PaneNode, axis: PaneAxis) -> CGFloat {
        switch node {
        case .leaf(let leaf):
            let size = leaf.id == panes.routedLeafID
                ? PaneMinimumSize.chat
                : PaneMinimumSize.standard(for: leaf.stack.last?.route ?? .sessions(workspace: nil)) ?? PaneMinimumSize.list
            return axis == .row ? size.width : size.height
        case .split(let splitAxis, let children, _):
            let lengths = children.map { minimumLength($0, axis: axis) }
            return splitAxis == axis
                ? lengths.reduce(0, +) + PanePresentation.dividerThickness * CGFloat(children.count - 1)
                : lengths.max() ?? 0
        }
    }

    private func splitDragBegan(_ place: PaneSplitDividerView.Place) {
        guard let presentation = cellPresentation,
              case .split(_, let children, let weights)? = panes.cellLayout.root.node(at: place.path),
              let before = union(children[place.index], presentation.frames),
              let after = union(children[place.index + 1], presentation.frames) else { return }
        let length: (CGRect) -> CGFloat = { place.axis == .row ? $0.width : $0.height }
        splitDrag = PaneSplitDrag(
            place: place,
            before: length(before),
            after: length(after),
            minimumBefore: minimumLength(children[place.index], axis: place.axis),
            minimumAfter: minimumLength(children[place.index + 1], axis: place.axis),
            weights: weights
        )
        holdForResize(beginningAt: length(before))
    }

    private func splitDragChanged(_ distance: CGFloat) {
        guard let drag = splitDrag else { return }
        let total = drag.before + drag.after
        let before = min(max(drag.before + distance, min(drag.minimumBefore, total / 2)), max(total - drag.minimumAfter, total / 2))
        let pair = drag.weights[drag.place.index] + drag.weights[drag.place.index + 1]
        var weights = drag.weights
        weights[drag.place.index] = pair * Double(before / total)
        weights[drag.place.index + 1] = pair - weights[drag.place.index]
        panes.setCellWeights(at: drag.place.path, weights)
        resizeMoved(to: before)
    }

    private func splitDragEnded() {
        guard splitDrag != nil else { return }
        splitDrag = nil
        resizeEnded()
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
            addChild(controller)
            view.insertSubview(controller.view, belowSubview: cover)
            controller.didMove(toParent: self)
            splitLeaves[leaf.id] = PaneSplitLeaf(controller: controller, entry: entry)
        }
    }

    private func makeScreen(_ entry: PaneStackEntry, leaf id: PaneID) -> UIViewController {
        PaneSplitScreens.make(entry, root: AppRootEnvironment.near(self), actions: PaneSplitScreens.Actions(
            show: { [weak self] entry in
                self?.panes.show(entry, in: id)
                self?.focus(cell: id)
            },
            replaceRoot: { [weak self] screen in
                self?.splitLeaves[id]?.controller.setViewControllers([screen], animated: false)
            },
            close: { [weak self] in self?.closePane(id) }
        ))
    }

    /// The front screen of a cell, for its title and the grip's place.
    func frontScreen(ofCell id: PaneID) -> UIViewController? {
        let leaf: UIViewController? = id == panes.routedLeafID ? primary : splitLeaves[id]?.controller
        return (leaf as? UINavigationController)?.topViewController ?? leaf
    }

    // MARK: Grips

    private func layoutGrips(_ presentation: PanePresentation) {
        let cells = panes.cellLayout
        let order = cells.leaves.map(\.id)
        let zoomed = cells.zoomed
        let showsGrips = order.count > 1
        var shown: Set<PaneID> = []
        for id in order {
            reserveGripStrip(inCell: id, height: showsGrips ? PaneGripView.size.height : 0)
        }
        for id in order where showsGrips {
            guard var frame = presentation.frames[id] else { continue }
            if id == panes.routedLeafID, !primary.view.isHidden { frame = primary.view.frame }
            shown.insert(id)
            let grip = grips[id] ?? makeGrip(id)
            let screen = frontScreen(ofCell: id)
            let title = screen?.navigationItem.title ?? screen?.title
                ?? splitLeaves[id].map { Self.title(of: $0.entry) } ?? String(localized: "Pane")
            grip.show(PaneGripView.Shown(
                title: title,
                position: (order.firstIndex(of: id) ?? 0) + 1,
                count: order.count,
                isFocused: cells.focus == id && order.count > 1,
                isZoomed: zoomed == id
            ))
            let top = gripTop(ofCell: id, in: frame)
            let size = zoomed == id ? PaneGripView.capsuleSize : PaneGripView.size
            // A grip being dragged follows the finger by its transform.
            guard grip.transform.isIdentity else { continue }
            grip.frame = CGRect(x: frame.midX - size.width / 2, y: top, width: size.width, height: size.height)
            grip.isHidden = false
            view.bringSubviewToFront(grip)
        }
        for (id, grip) in grips where !shown.contains(id) { grip.isHidden = true }
    }

    private func leafController(ofCell id: PaneID) -> UIViewController? {
        id == panes.routedLeafID ? primary : splitLeaves[id]?.controller
    }

    /// The strip under each pane's bar that its grip sits in: the screens of
    /// the cell's stack start that much lower, so the grip covers nothing (a
    /// search field, a first row). Zero with one pane, as before.
    private func reserveGripStrip(inCell id: PaneID, height: CGFloat) {
        guard let navigation = leafController(ofCell: id) as? UINavigationController else { return }
        for screen in navigation.viewControllers where screen.additionalSafeAreaInsets.top != height {
            screen.additionalSafeAreaInsets.top = height
        }
    }

    /// Where a cell's grip goes: in its strip under the navigation bar, never
    /// in the bar (a drag there moves a floating window), and never above the
    /// window's own top inset (status bar, window controls). The leaf lays
    /// out first, so a root it just took has its bar.
    private func gripTop(ofCell id: PaneID, in frame: CGRect) -> CGFloat {
        let floor = frame.minY + view.safeAreaInsets.top
        guard let leaf = leafController(ofCell: id), leaf.view.window != nil else { return floor }
        leaf.view.layoutIfNeeded()
        var top = floor
        if let navigation = leaf as? UINavigationController, !navigation.isNavigationBarHidden {
            let bar = navigation.navigationBar
            top = max(top, bar.convert(bar.bounds, to: view).maxY)
        }
        // A search field below the bar (Files) is the screen's, not the bar's.
        if let screen = frontScreen(ofCell: id), screen.isViewLoaded {
            let content = screen.view.safeAreaInsets.top - screen.additionalSafeAreaInsets.top
            top = max(top, screen.view.convert(CGPoint(x: 0, y: content), to: view).y)
        }
        return top
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
        var items: [PaneMenuItem] = [
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
                isEnabled: !isZoomed && neighbour(of: id, toward: direction) != nil,
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

    /// Split Right and Split Down for the pane holding `screen`, for that
    /// screen's own … menu: with one pane there is no grip yet, so this is
    /// the first split's touch path.
    func splitItems(for screen: UIViewController) -> [PaneMenuItem] {
        guard canSplit, let cell = cell(holding: screen) else { return [] }
        let splits: Set<String> = ["pane.menu.splitRight", "pane.menu.splitDown"]
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
        announceLayoutChange()
    }

    func resetPanes() {
        panes.resetPanes()
        syncSplitLeaves()
        relayoutCells()
        updateVisibility()
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
        announceLayoutChange()
    }

    /// Trades two panes' places (a grip dropped on a pane's middle).
    func swap(_ id: PaneID, with target: PaneID) {
        panes.swap(id, target)
        relayoutCells()
        announceLayoutChange()
    }

    /// Equal shares for every split (⌃⌘=).
    func equaliseSizes() {
        panes.equaliseCells()
        relayoutCells()
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

    private func announceLayoutChange() {
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }
}
