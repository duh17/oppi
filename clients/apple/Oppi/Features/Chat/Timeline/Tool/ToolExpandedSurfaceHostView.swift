import UIKit

@MainActor
final class ToolExpandedSurfaceHostView: UIView {
    private let defaultContentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
    private var activeContentInsets = NSDirectionalEdgeInsets(top: 5, leading: 6, bottom: 5, trailing: 6)
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
        let activeWidth = max(1, width - activeContentInsets.leading - activeContentInsets.trailing)
        let activeSize = activeView.systemLayoutSizeFitting(
            CGSize(width: activeWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: activeSize.height + activeContentInsets.top + activeContentInsets.bottom
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
        let activeWidth = max(1, width - activeContentInsets.leading - activeContentInsets.trailing)
        let activeSize = activeView.systemLayoutSizeFitting(
            CGSize(width: activeWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(
            width: width,
            height: activeSize.height + activeContentInsets.top + activeContentInsets.bottom
        )
    }

    func prepareSurfaceView(_ view: UIView) {
        guard view.superview !== self else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        addSubview(view)
    }

    func activateSurfaceView(
        _ view: UIView?,
        contentInsets: NSDirectionalEdgeInsets? = nil
    ) {
        NSLayoutConstraint.deactivate(activeConstraints)
        activeConstraints.removeAll()
        activeContentInsets = contentInsets ?? defaultContentInsets

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
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: activeContentInsets.leading),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -activeContentInsets.trailing),
            view.topAnchor.constraint(equalTo: topAnchor, constant: activeContentInsets.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -activeContentInsets.bottom),
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
