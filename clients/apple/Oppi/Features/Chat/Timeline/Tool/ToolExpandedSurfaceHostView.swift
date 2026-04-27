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

    override var intrinsicContentSize: CGSize {
        guard let activeView else {
            return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
        }
        let width = max(1, bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 48)
        let activeWidth = max(1, width - contentInsets.leading - contentInsets.trailing)
        let activeSize = activeView.systemLayoutSizeFitting(
            CGSize(width: activeWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: activeSize.height + contentInsets.top + contentInsets.bottom
        )
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        guard let activeView else {
            return super.systemLayoutSizeFitting(
                targetSize,
                withHorizontalFittingPriority: horizontalFittingPriority,
                verticalFittingPriority: verticalFittingPriority
            )
        }
        let width = max(1, targetSize.width > 0 ? targetSize.width : bounds.width)
        let activeWidth = max(1, width - contentInsets.leading - contentInsets.trailing)
        let activeSize = activeView.systemLayoutSizeFitting(
            CGSize(width: activeWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(
            width: width,
            height: activeSize.height + contentInsets.top + contentInsets.bottom
        )
    }

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
            invalidateIntrinsicContentSize()
            setNeedsLayout()
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
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func clearActiveSurface() {
        activateSurfaceView(nil)
    }
}
