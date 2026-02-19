import Testing
import UIKit

@testable import Oppi

@Suite("UserTimelineRowContent")
struct UserTimelineRowContentTests {
    @MainActor
    @Test("fullscreen image viewer pins image to content-layout edges")
    func fullscreenViewerPinsImageToContentEdges() throws {
        let viewController = NativeZoomableImageViewController(image: makeTestImage())
        viewController.loadViewIfNeeded()
        viewController.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()

        let scrollView = try #require(firstSubview(ofType: UIScrollView.self, in: viewController.view))
        let imageView = try #require(firstSubview(ofType: UIImageView.self, in: scrollView))

        let allConstraints = scrollView.constraints + viewController.view.constraints

        #expect(
            hasConstraint(
                in: allConstraints,
                between: imageView,
                attribute: .leading,
                and: scrollView.contentLayoutGuide,
                attribute: .leading
            )
        )
        #expect(
            hasConstraint(
                in: allConstraints,
                between: imageView,
                attribute: .trailing,
                and: scrollView.contentLayoutGuide,
                attribute: .trailing
            )
        )
        #expect(
            hasConstraint(
                in: allConstraints,
                between: imageView,
                attribute: .top,
                and: scrollView.contentLayoutGuide,
                attribute: .top
            )
        )
        #expect(
            hasConstraint(
                in: allConstraints,
                between: imageView,
                attribute: .bottom,
                and: scrollView.contentLayoutGuide,
                attribute: .bottom
            )
        )

        // Guard against previous regression pattern.
        #expect(
            !hasConstraint(
                in: allConstraints,
                between: imageView,
                attribute: .centerX,
                and: scrollView.contentLayoutGuide,
                attribute: .centerX
            )
        )
        #expect(
            !hasConstraint(
                in: allConstraints,
                between: imageView,
                attribute: .centerY,
                and: scrollView.contentLayoutGuide,
                attribute: .centerY
            )
        )
    }

    @MainActor
    @Test("fullscreen image viewer starts with viewport-sized content at zoom 1")
    func fullscreenViewerInitialLayoutMatchesViewport() throws {
        let viewController = NativeZoomableImageViewController(image: makeTestImage())
        viewController.loadViewIfNeeded()
        viewController.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        viewController.view.setNeedsLayout()
        viewController.view.layoutIfNeeded()

        let scrollView = try #require(firstSubview(ofType: UIScrollView.self, in: viewController.view))
        let imageView = try #require(firstSubview(ofType: UIImageView.self, in: scrollView))

        let tolerance: CGFloat = 0.5

        #expect(abs(imageView.frame.minX) <= tolerance)
        #expect(abs(imageView.frame.minY) <= tolerance)
        #expect(abs(imageView.frame.width - scrollView.bounds.width) <= tolerance)
        #expect(abs(imageView.frame.height - scrollView.bounds.height) <= tolerance)

        #expect(abs(scrollView.contentSize.width - scrollView.bounds.width) <= tolerance)
        #expect(abs(scrollView.contentSize.height - scrollView.bounds.height) <= tolerance)
    }

    @MainActor
    private func makeTestImage() -> UIImage {
        let size = CGSize(width: 120, height: 80)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

private func firstSubview<T: UIView>(ofType type: T.Type, in root: UIView) -> T? {
    if let typed = root as? T {
        return typed
    }

    for child in root.subviews {
        if let typed = firstSubview(ofType: type, in: child) {
            return typed
        }
    }

    return nil
}

private func hasConstraint(
    in constraints: [NSLayoutConstraint],
    between firstItem: AnyObject,
    attribute firstAttribute: NSLayoutConstraint.Attribute,
    and secondItem: AnyObject,
    attribute secondAttribute: NSLayoutConstraint.Attribute
) -> Bool {
    for constraint in constraints where constraint.isActive && constraint.relation == .equal {
        let directMatch =
            (constraint.firstItem as AnyObject?) === firstItem &&
            constraint.firstAttribute == firstAttribute &&
            (constraint.secondItem as AnyObject?) === secondItem &&
            constraint.secondAttribute == secondAttribute

        let inverseMatch =
            (constraint.firstItem as AnyObject?) === secondItem &&
            constraint.firstAttribute == secondAttribute &&
            (constraint.secondItem as AnyObject?) === firstItem &&
            constraint.secondAttribute == firstAttribute

        if directMatch || inverseMatch {
            return true
        }
    }

    return false
}
