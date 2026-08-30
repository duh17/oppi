import UIKit

extension ChatTimelineCollectionHost.Controller {
    func attachHardwareKeybindingResponder(to collectionView: UICollectionView) {
        let responder = HardwareKeybindingResponder(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        responder.mode = KeybindingPreferenceStore().mode
        responder.onAction = { [weak self] action in
            self?.applyHardwareKeybinding(action)
        }
        collectionView.addSubview(responder)
        hardwareKeybindingResponder = responder
    }

    func refreshHardwareKeybindingResponder() {
        guard let responder = hardwareKeybindingResponder else { return }
        responder.mode = KeybindingPreferenceStore().mode
        if responder.isFirstResponder, !responder.canBecomeFirstResponder {
            responder.resignFirstResponder()
        }
    }

    func claimHardwareKeybindingFocusIfNeeded() {
        hardwareKeybindingResponder?.claimFocusIfPossible()
    }

    func applyHardwareKeybinding(_ action: KeybindingAction) {
        guard let collectionView else { return }
        let toolRowIDs = hardwareKeybindingToolRowIDs()
        switch action {
        case .nextToolRow:
            selectHardwareKeybindingToolRow(
                nextID(after: hardwareKeybindingResponder?.selectedToolRowID, in: toolRowIDs),
                in: collectionView
            )
        case .previousToolRow:
            selectHardwareKeybindingToolRow(
                previousID(before: hardwareKeybindingResponder?.selectedToolRowID, in: toolRowIDs),
                in: collectionView
            )
        case .expand:
            setHardwareKeybindingExpanded(true, in: collectionView)
        case .collapse:
            setHardwareKeybindingExpanded(false, in: collectionView)
        case .toggleExpanded:
            guard let id = hardwareKeybindingResponder?.selectedToolRowID else { return }
            let expanded = reducer?.expandedItemIDs.contains(id) == true
            setHardwareKeybindingExpanded(!expanded, in: collectionView)
        case .openViewer:
            presentHardwareKeybindingViewer(in: collectionView)
        case .closeViewer:
            dismissHardwareKeybindingViewer(from: collectionView)
        case .moveToTop:
            selectHardwareKeybindingToolRow(toolRowIDs.first, in: collectionView)
        case .moveToBottom:
            selectHardwareKeybindingToolRow(toolRowIDs.last, in: collectionView)
        case .focusComposer, .send:
            break
        }
    }

    private func hardwareKeybindingToolRowIDs() -> [String] {
        currentIDs.compactMap { id in
            guard let item = currentItemByID[id], case .toolCall(_, let tool, _, _, _, _, _) = item else {
                return nil
            }
            if ToolCallFormatting.normalized(tool) == "ask" {
                return nil
            }
            return id
        }
    }

    private func selectHardwareKeybindingToolRow(_ id: String?, in collectionView: UICollectionView) {
        hardwareKeybindingResponder?.selectedToolRowID = id
        hardwareKeybindingResponder?.focus = .timeline
        guard let id, let index = currentIDs.firstIndex(of: id) else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: .centeredVertically,
            animated: false
        )
    }

    private func setHardwareKeybindingExpanded(_ expanded: Bool, in collectionView: UICollectionView) {
        guard let id = hardwareKeybindingResponder?.selectedToolRowID,
              let reducer,
              let item = currentItemByID[id],
              case .toolCall(_, let tool, _, _, let outputByteCount, _, _) = item,
              let index = currentIDs.firstIndex(of: id) else {
            return
        }
        let wasExpanded = reducer.expandedItemIDs.contains(id)
        if expanded == wasExpanded {
            return
        }
        if expanded {
            reducer.expandedItemIDs.insert(id)
            FeatureEducationTips.markToolDetailsOpened()
            ensureExpandedToolOutputLoaded(
                itemID: id,
                tool: tool,
                outputByteCount: outputByteCount,
                in: collectionView
            )
        } else {
            reducer.expandedItemIDs.remove(id)
            cancelToolOutputRetryWork(for: id)
            cancelToolOutputLoadTasks(for: [id])
        }
        anchoredReconfigureToolRow(
            itemID: id,
            anchorIndexPath: IndexPath(item: index, section: 0),
            in: collectionView,
            preserveTopEdge: true
        )
    }

    private func presentHardwareKeybindingViewer(in collectionView: UICollectionView) {
        guard let id = hardwareKeybindingResponder?.selectedToolRowID,
              let index = currentIDs.firstIndex(of: id) else {
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        if reducer?.expandedItemIDs.contains(id) != true {
            setHardwareKeybindingExpanded(true, in: collectionView)
        }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: indexPath),
              let row = Self.firstSubview(
                ofType: ToolTimelineRowContentView.self,
                in: cell.contentView
              ) else {
            return
        }
        row.showFullScreenContent()
        hardwareKeybindingResponder?.focus = .viewer
    }

    private func dismissHardwareKeybindingViewer(from collectionView: UICollectionView) {
        guard let presenter = ToolTimelineRowPresentationHelpers.nearestViewController(from: collectionView) else {
            return
        }
        var current: UIViewController? = presenter
        while let node = current {
            if node.presentedViewController is FullScreenCodeViewController
                || node.presentedViewController is FullScreenImageViewController {
                node.dismiss(animated: true)
                hardwareKeybindingResponder?.focus = .timeline
                return
            }
            current = node.presentedViewController ?? node.parent
        }
        hardwareKeybindingResponder?.focus = .timeline
    }

    private func nextID(after selected: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return selected }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return ids.first
        }
        let next = index + 1
        return next < ids.count ? ids[next] : selected
    }

    private func previousID(before selected: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return selected }
        guard let selected, let index = ids.firstIndex(of: selected) else {
            return ids.last
        }
        let previous = index - 1
        return previous >= 0 ? ids[previous] : selected
    }
}
