import UIKit

/// The reader holds its body at its width while a divider beside it moves: a
/// width change re-wraps every visible chunk of a Markdown, Org or code body.
/// The bar and the floating controls follow every frame. Where the divider
/// pauses or rests, the body lays out once and keeps the reading position.
extension FullScreenCodeViewController: PaneLiveResizing {
    func paneWillBeginLiveResize() {
        guard let body = installedBodyView, let edges = bodyWidthEdges, edges.held == nil,
              body.bounds.width > 1 else { return }
        let held = body.widthAnchor.constraint(equalToConstant: body.bounds.width)
        edges.trailing.isActive = false
        held.isActive = true
        bodyWidthEdges = (edges.trailing, held)
    }

    func paneSettleLiveResize(to size: CGSize, final: Bool) {
        guard let body = installedBodyView, let edges = bodyWidthEdges, let held = edges.held else { return }
        // A body that keeps a reading position says where it is; any other
        // keeps the same share of its scroll height.
        let intent = body.viewportIntent
        let scrollView = Self.mainScrollView(in: body)
        let fraction = scrollView.map { scroll in
            (scroll.contentOffset.y + scroll.adjustedContentInset.top) / max(scroll.contentSize.height, 1)
        }
        held.isActive = false
        edges.trailing.isActive = true
        bodyWidthEdges = (edges.trailing, nil)
        view.layoutIfNeeded()
        if let intent, body.restoreViewport(intent) { return }
        if let scrollView, let fraction {
            scrollView.layoutIfNeeded()
            let maxY = max(-scrollView.adjustedContentInset.top,
                           scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let y = fraction * scrollView.contentSize.height - scrollView.adjustedContentInset.top
            scrollView.contentOffset.y = min(max(y, -scrollView.adjustedContentInset.top), maxY)
        }
    }

    /// The body itself when it scrolls, else its largest scrolling descendant.
    private static func mainScrollView(in body: UIView) -> UIScrollView? {
        if let scroll = body as? UIScrollView { return scroll }
        var best: UIScrollView?
        var queue = body.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? UIScrollView {
                if scroll.bounds.height * scroll.bounds.width > (best.map { $0.bounds.height * $0.bounds.width } ?? 0) {
                    best = scroll
                }
                continue
            }
            queue.append(contentsOf: view.subviews)
        }
        return best
    }
}
