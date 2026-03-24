import UIKit

@MainActor
final class ToolExpandedSurfaceHostView: UIView {
    private let contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
    private var activeConstraints: [NSLayoutConstraint] = []
    private(set) weak var activeView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func prepareSurfaceView(_ view: UIView) {
        guard view.superview !== self else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        addSubview(view)
    }

    func activateSurfaceView(_ view: UIView?) {
        NSLayoutConstraint.deactivate(activeConstraints)
        activeConstraints.removeAll()

        if let activeView, activeView !== view {
            activeView.isHidden = true
        }

        guard let view else {
            activeView = nil
            return
        }

        prepareSurfaceView(view)
        view.isHidden = false

        let constraints = [
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInsets.leading),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInsets.trailing),
            view.topAnchor.constraint(equalTo: topAnchor, constant: contentInsets.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -contentInsets.bottom),
        ]
        NSLayoutConstraint.activate(constraints)
        activeConstraints = constraints
        activeView = view
    }

    func clearActiveSurface() {
        activateSurfaceView(nil)
    }
}
