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
    @Test("fullscreen image viewer uses theme navigation chrome")
    func fullscreenViewerUsesThemeNavigationChrome() throws {
        let palette = ThemeRuntimeState.currentThemeID().palette
        let viewController = FullScreenImageViewController(image: makeTestImage())
        let navigation = UINavigationController(rootViewController: viewController)

        navigation.loadViewIfNeeded()
        viewController.loadViewIfNeeded()

        let doneButton = try #require(viewController.navigationItem.leftBarButtonItem)
        #expect(doneButton.accessibilityLabel == "Done")
        #expect(doneButton.accessibilityIdentifier == "fullscreen-image.dismiss")
        #expect(color(doneButton.tintColor, approximatelyEquals: UIColor(palette.cyan)))

        let navAppearance = navigation.navigationBar.standardAppearance
        #expect(color(navAppearance.backgroundColor, approximatelyEquals: UIColor(palette.bgHighlight)))

        let toolbar = try #require(firstSubview(ofType: UIToolbar.self, in: viewController.view))
        #expect(color(toolbar.tintColor, approximatelyEquals: UIColor(palette.cyan)))
        #expect(color(toolbar.standardAppearance.backgroundColor, approximatelyEquals: UIColor(palette.bgHighlight)))
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

        let navigation = try #require(host.presentedViewController as? UINavigationController)
        #expect(navigation.modalPresentationStyle == .pageSheet)
        #expect(navigation.viewControllers.first is FullScreenImageViewController)

        let sheet = try #require(navigation.sheetPresentationController)
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

        let renderedTextView = try #require(userMessageTextView(in: view))
        let renderedText = try #require(renderedTextView.text)

        #expect(renderedText.contains("message truncated for display"))
        #expect(renderedText.count < longText.count)

        let menu = try #require(view.contextMenu())
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @MainActor
    @Test("user row selected text edit menu prepends π submenu")
    func userRowSelectedTextEditMenuPrependsPiSubmenu() throws {
        let router = SelectedTextPiActionRouter { _ in }
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: "Need help with this prompt",
                images: [],
                canFork: false,
                onFork: nil,
                themeID: .dark,
                selectedTextPiRouter: router,
                selectedTextSourceContext: .init(sessionId: "session-1", surface: .userMessage)
            )
        )

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let textView = try #require(userMessageTextView(in: view))
        #expect(textView.isSelectable)

        let menu = try #require(view.textView(
            textView,
            editMenuForTextIn: NSRange(location: 0, length: 4),
            suggestedActions: [UIAction(title: "Copy") { _ in }]
        ))

        let piMenu = try #require(menu.children.first as? UIMenu)
        #expect(piMenu.title == "π")
        #expect(timelineActionTitles(in: piMenu) == ["Explain", "Do it", "Fix", "Refactor", "Add to Prompt", "New Session"])
    }

    @MainActor
    @Test("user row uses semantic user bubble colors from the theme")
    func userRowUsesSemanticUserBubbleColors() throws {
        let themeID: ThemeID = .light
        let palette = themeID.palette
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: "Hello from the dog-color bubble",
                images: [],
                canFork: false,
                onFork: nil,
                themeID: themeID
            )
        )

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 160)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let bubble = try #require(userMessageBubbleContainer(in: view))
        let textView = try #require(userMessageTextView(in: view))

        #expect(color(bubble.backgroundColor, approximatelyEquals: UIColor(palette.userMessageBg)))
        #expect(color(textView.textColor, approximatelyEquals: UIColor(palette.userMessageText)))
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
private func userMessageTextView(in view: UserTimelineRowContentView) -> UITextView? {
    Mirror(reflecting: view).children.first { $0.label == "messageTextView" }?.value as? UITextView
}

@MainActor
private func userMessageBubbleContainer(in view: UserTimelineRowContentView) -> UIView? {
    Mirror(reflecting: view).children.first { $0.label == "bubbleContainer" }?.value as? UIView
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

@MainActor
private func color(_ lhs: UIColor?, approximatelyEquals rhs: UIColor, tolerance: CGFloat = 0.01) -> Bool {
    guard let lhs else { return false }

    var lr: CGFloat = 0
    var lg: CGFloat = 0
    var lb: CGFloat = 0
    var la: CGFloat = 0
    var rr: CGFloat = 0
    var rg: CGFloat = 0
    var rb: CGFloat = 0
    var ra: CGFloat = 0

    guard lhs.getRed(&lr, green: &lg, blue: &lb, alpha: &la),
          rhs.getRed(&rr, green: &rg, blue: &rb, alpha: &ra) else {
        return lhs.cgColor == rhs.cgColor
    }

    return abs(lr - rr) <= tolerance &&
        abs(lg - rg) <= tolerance &&
        abs(lb - rb) <= tolerance &&
        abs(la - ra) <= tolerance
}
