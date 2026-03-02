import Testing
import UIKit

@testable import Oppi

@Suite("UserTimelineRowContent")
struct UserTimelineRowContentTests {
    @MainActor
    @Test("fullscreen image viewer pins image to content-layout edges")
    func fullscreenViewerPinsImageToContentEdges() throws {
        let viewController = FullScreenImageViewController(image: makeTestImage())
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
        let viewController = FullScreenImageViewController(image: makeTestImage())
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
    @Test("tool timeline image presentation uses page-sheet swipe dismiss")
    func toolTimelineImagePresentationUsesPageSheet() throws {
        let window = UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()

        let source = UIView(frame: .zero)
        host.view.addSubview(source)

        ToolTimelineRowPresentationHelpers.presentFullScreenImage(makeTestImage(), from: source)

        let presented = try #require(host.presentedViewController as? FullScreenImageViewController)
        #expect(presented.modalPresentationStyle == .pageSheet)

        let sheet = try #require(presented.sheetPresentationController)
        #expect(sheet.prefersGrabberVisible)
        #expect(sheet.detents.count == 1)

        host.dismiss(animated: false)
        window.isHidden = true
    }

    @MainActor
    @Test("user row truncates oversized text for display")
    func userRowTruncatesOversizedTextForDisplay() throws {
        let longText = String(repeating: "0123456789abcdef", count: 1_000)
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: longText,
                images: [],
                canFork: false,
                onFork: nil,
                themeID: .dark
            )
        )

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let labels = allSubviews(ofType: UILabel.self, in: view)
        let renderedLabel = try #require(
            labels.first(where: { $0.text?.contains("message truncated for display") == true })
        )
        let renderedText = try #require(renderedLabel.text)

        #expect(renderedText.contains("message truncated for display"))
        #expect(renderedText.count < longText.count)

        let menu = try #require(view.contextMenu())
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @MainActor
    @Test("user row reconfigure keeps thumbnail view identity for same images")
    func userRowReconfigureKeepsThumbnailViewIdentityForSameImages() throws {
        let image = ImageAttachment(data: "aGVsbG8=", mimeType: "image/png")
        let configuration = UserTimelineRowConfiguration(
            text: "",
            images: [image],
            canFork: false,
            onFork: nil,
            themeID: .dark
        )

        let view = UserTimelineRowContentView(configuration: configuration)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let firstThumbnail = try #require(
            firstSubview(withAccessibilityIdentifier: "chat.user.thumbnail.0", in: view)
        )

        view.configuration = configuration
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let secondThumbnail = try #require(
            firstSubview(withAccessibilityIdentifier: "chat.user.thumbnail.0", in: view)
        )

        #expect(firstThumbnail === secondThumbnail)
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

@MainActor
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

@MainActor
private func allSubviews<T: UIView>(ofType type: T.Type, in root: UIView) -> [T] {
    var matches: [T] = []
    if let typed = root as? T {
        matches.append(typed)
    }

    for child in root.subviews {
        matches.append(contentsOf: allSubviews(ofType: type, in: child))
    }

    return matches
}

@MainActor
private func firstSubview(withAccessibilityIdentifier identifier: String, in root: UIView) -> UIView? {
    if root.accessibilityIdentifier == identifier {
        return root
    }

    for child in root.subviews {
        if let match = firstSubview(withAccessibilityIdentifier: identifier, in: child) {
            return match
        }
    }

    return nil
}

@MainActor
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
