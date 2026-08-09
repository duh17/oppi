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

        // Nav bar has no custom appearance — iOS 26 Liquid Glass handles chrome
        let navAppearance = navigation.navigationBar.standardAppearance
        #expect(navAppearance.backgroundColor == nil, "Liquid Glass nav bar should not set explicit backgroundColor")

        let toolbar = try #require(firstSubview(ofType: UIToolbar.self, in: viewController.view))
        #expect(color(toolbar.tintColor, approximatelyEquals: UIColor(palette.cyan)))
        #expect(color(toolbar.standardAppearance.backgroundColor, approximatelyEquals: UIColor(palette.bgHighlight)))
    }

    @MainActor
    @Test("fullscreen image theme notification updates navigation controller chrome")
    func fullscreenImageThemeNotificationUpdatesNavigationController() throws {
        let originalThemeID = ThemeRuntimeState.currentThemeID()
        defer { ThemeRuntimeState.setThemeID(originalThemeID) }

        ThemeRuntimeState.setThemeID(.dark)
        let navigation = try #require(
            FullScreenImageViewController.makeSlideDownController(image: makeTestImage())
                as? UINavigationController
        )
        navigation.loadViewIfNeeded()
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageViewController)
        viewer.loadViewIfNeeded()
        #expect(navigation.overrideUserInterfaceStyle == .dark)

        ThemeRuntimeState.setThemeID(.light)
        NotificationCenter.default.post(name: .oppiThemeDidChange, object: nil)

        #expect(navigation.overrideUserInterfaceStyle == .light)
        #expect(color(navigation.view.backgroundColor, approximatelyEquals: UIColor(ThemePalettes.light.bgDark)))
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
            )
        )

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let renderedTextView = try #require(userMessageTextView(in: view))
        let renderedText = try #require(renderedTextView.text)

        #expect(renderedText.contains("message truncated for display"))
        #expect(renderedText.count < longText.count)

        let menu = try #require(view.buildContextMenu())
        #expect(timelineActionTitles(in: menu) == ["Copy"])
    }

    @MainActor
    @Test("timeline user row builder keeps fork disabled in row menus")
    func timelineUserRowBuilderKeepsForkDisabledInRowMenus() {
        let controller = ChatTimelineCollectionHost.Controller()
        controller.onFork = { _ in
            Issue.record("Row-level fork callback should not be wired")
        }

        let item = ChatItem.userMessage(
            id: "entry-1",
            text: "Investigate timeline branch behavior",
            images: [],
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let configuration = controller.userRowConfiguration(itemID: "entry-1", item: item)
        #expect(configuration != nil)
        #expect(configuration?.canFork == false)
        #expect(configuration?.onFork == nil)
    }

    @MainActor
    @Test("selection-enabled user row passes vertical pans to outer timeline")
    func selectionEnabledUserRowPassesVerticalPansToOuterTimeline() throws {
        let interactionCtx = TimelineInteractionContext()
        interactionCtx.reviewCommentSelectionRouter = ReviewCommentSelectionRouter { _ in }
        interactionCtx.sessionId = "session-1"
        var config = UserTimelineRowConfiguration(
            text: String(repeating: "Review clients/apple/Oppi/Features/Chat/ChatView.swift\n", count: 40),
            images: [],
            canFork: false,
            onFork: nil
        )
        config.interactionContext = interactionCtx
        let view = UserTimelineRowContentView(configuration: config)

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let textView = try #require(userMessageTextView(in: view))
        #expect(textView.isSelectable)
        #expect(!textView.isScrollEnabled)
        #expect(
            textView.gestureRecognizerShouldBegin(textView.panGestureRecognizer) == false,
            "Selectable non-scrollable user text should pass vertical drags to the outer timeline"
        )
    }

    @MainActor
    @Test("user row selected text edit menu prepends Comment")
    func userRowSelectedTextEditMenuPrependsComment() throws {
        let interactionCtx = TimelineInteractionContext()
        interactionCtx.reviewCommentSelectionRouter = ReviewCommentSelectionRouter { _ in }
        interactionCtx.sessionId = "session-1"
        var config = UserTimelineRowConfiguration(
            text: "Need help with this prompt",
            images: [],
            canFork: false,
            onFork: nil
        )
        config.interactionContext = interactionCtx
        let view = UserTimelineRowContentView(configuration: config)

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

        #expect(timelineActionTitles(in: menu) == ["Comment", "Copy"])
    }

    @MainActor
    @Test("user row uses semantic user bubble colors from the theme")
    func userRowUsesSemanticUserBubbleColors() throws {
        let palette = ThemeRuntimeState.currentPalette()
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: "Hello from the dog-color bubble",
                images: [],
                canFork: false,
                onFork: nil
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
    @Test("user row hides generic photo badge when inline uploaded image preview is available")
    func userRowHidesGenericPhotoBadgeWhenInlineUploadedImagePreviewIsAvailable() async throws {
        let pngData = try #require(makeTestImage().pngData())
        let text = "[[oppi-attachments:b:photos=1]]\nAttached files:\n- image-1.png: .pi/attachments/demo/image-1.png"
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: text,
                images: [],
                fetchWorkspaceFileData: { _ in pngData },
                canFork: false,
                onFork: nil
            )
        )

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let inlineThumbnail = try #require(
            firstSubview(withAccessibilityIdentifier: "chat.user.inline-path-thumbnail.0", in: view)
        )
        #expect(!inlineThumbnail.isHidden)
        #expect(!allLabelTexts(in: view).contains("1 photo"))
    }

    @MainActor
    @Test("user row renders uploaded SVG thumbnail through shared web preview")
    func userRowRendersUploadedSVGThumbnailThroughSharedWebPreview() async throws {
        let svg = """
        <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"80\">
          <rect width=\"120\" height=\"80\" fill=\"#7c3aed\"/>
        </svg>
        """
        let attachment = ImageAttachment(data: Data(svg.utf8).base64EncodedString(), mimeType: "image/svg+xml")
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: "",
                images: [attachment],
                canFork: false,
                onFork: nil
            )
        )

        let host = UIViewController()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        let window = UIWindow(frame: host.view.frame)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        view.frame = host.view.bounds
        host.view.addSubview(view)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let rendered = await waitForTimelineCondition(timeoutMs: 1_400) { @MainActor in
            view.setNeedsLayout()
            view.layoutIfNeeded()
            guard let thumbnail = firstSubview(withAccessibilityIdentifier: "chat.user.thumbnail.0", in: view) else {
                return false
            }
            let hasHostedPreview = thumbnail.subviews.contains { String(describing: type(of: $0)).contains("Hosting") }
            return hasHostedPreview && abs(thumbnail.bounds.width - 80) < 0.5 && abs(thumbnail.bounds.height - 80) < 0.5
        }

        #expect(rendered, "Uploaded SVG thumbnail should stay square and use the shared preview path")
    }

    @MainActor
    @Test("user row suppresses duplicate uploaded image inline preview when local image is present")
    func userRowSuppressesDuplicateUploadedImageInlinePreviewWhenLocalImageIsPresent() throws {
        let imageData = try #require(makeTestImage().pngData())
        let attachment = ImageAttachment(data: imageData.base64EncodedString(), mimeType: "image/png")
        let text = "Attached files:\n- image-1.png: .pi/attachments/demo/image-1.png"
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: text,
                images: [attachment],
                fetchWorkspaceFileData: { _ in imageData },
                canFork: false,
                onFork: nil
            )
        )

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 220)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(firstSubview(withAccessibilityIdentifier: "chat.user.thumbnail.0", in: view) != nil)
        #expect(firstSubview(withAccessibilityIdentifier: "chat.user.inline-path-thumbnail.0", in: view) == nil)
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
    @Test("detached mid-history anchor survives raster image Done dismissal")
    func detachedMidHistoryAnchorSurvivesRasterImageDoneDismissal() async throws {
        let fixture = ImagePreviewTimelineFixture()
        defer { fixture.teardown() }

        let anchor = try fixture.exerciseUpThenDownAndCaptureMidHistoryAnchor()
        ToolTimelineRowPresentationHelpers.presentFullScreenImage(makeTestImage(), from: fixture.sourceView)
        let navigation = try #require(fixture.host.presentedViewController as? UINavigationController)
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageViewController)
        viewer.loadViewIfNeeded()

        let imageScrollView = try #require(firstSubview(ofType: UIScrollView.self, in: viewer.view))
        imageScrollView.setZoomScale(2, animated: false)
        imageScrollView.contentOffset = CGPoint(x: 18, y: 24)
        fixture.assertReadingAnchor(anchor)

        fixture.simulatePreviewReturnLosingDetachedPosition()
        let done = try #require(viewer.navigationItem.leftBarButtonItem)
        _ = UIApplication.shared.sendAction(
            try #require(done.action),
            to: done.target,
            from: done,
            for: nil
        )

        #expect(await fixture.waitForPreviewDismissal())
        fixture.assertReadingAnchor(anchor)
    }

    @MainActor
    @Test("detached mid-history anchor survives data-image custom swipe dismissal")
    func detachedMidHistoryAnchorSurvivesDataImageCustomSwipeDismissal() async throws {
        let fixture = ImagePreviewTimelineFixture()
        defer { fixture.teardown() }

        let anchor = try fixture.exerciseUpThenDownAndCaptureMidHistoryAnchor()
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='120' height='80'></svg>".utf8)
        FullScreenImageDataPreviewPresenter.present(
            data: svg,
            mimeType: "image/svg+xml",
            from: fixture.host
        )
        let navigation = try #require(fixture.host.presentedViewController as? UINavigationController)
        let viewer = try #require(navigation.viewControllers.first as? FullScreenImageDataPreviewViewController)
        viewer.loadViewIfNeeded()

        fixture.simulatePreviewReturnLosingDetachedPosition()
        let swipeInstaller = try #require(
            viewer.view.gestureRecognizers?.compactMap { $0.delegate as? HorizontalBackSwipeGestureInstaller }.first
        )
        swipeInstaller.handleNavigationSwipeEnded(
            translation: CGSize(width: 0, height: 180),
            in: viewer.view
        )

        #expect(await fixture.waitForPreviewDismissal())
        fixture.assertReadingAnchor(anchor)
    }

    @MainActor
    @Test("detached mid-history anchor survives native sheet dismissal lifecycle")
    func detachedMidHistoryAnchorSurvivesNativeSheetDismissalLifecycle() async throws {
        let fixture = ImagePreviewTimelineFixture()
        defer { fixture.teardown() }

        let anchor = try fixture.exerciseUpThenDownAndCaptureMidHistoryAnchor()
        FullScreenImageViewController.present(image: makeTestImage(), from: fixture.host)
        _ = try #require(fixture.host.presentedViewController)

        fixture.simulatePreviewReturnLosingDetachedPosition()
        fixture.host.dismiss(animated: false)

        #expect(await fixture.waitForPreviewDismissal())
        fixture.assertReadingAnchor(anchor)
    }

    @MainActor
    @Test("attached image return stays on the live tail")
    func attachedImageReturnStaysOnLiveTail() async throws {
        let fixture = ImagePreviewTimelineFixture()
        defer { fixture.teardown() }

        fixture.prepareAttachedTail()
        FullScreenImageViewController.present(image: makeTestImage(), from: fixture.host)
        _ = try #require(fixture.host.presentedViewController)

        fixture.simulatePreviewReturnLosingAttachedTail()
        fixture.host.dismiss(animated: false)

        #expect(await fixture.waitForPreviewDismissal())
        fixture.assertAttachedToTail()
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
private final class ImagePreviewTimelineFixture {
    struct ReadingAnchor {
        let itemID: String
        let viewportRelativeY: CGFloat
    }

    let windowed: WindowedTimelineHarness
    let host: UIViewController
    let sourceView = UIView()

    var collectionView: UICollectionView { windowed.collectionView }
    var coordinator: ChatTimelineCollectionHost.Controller { windowed.coordinator }
    var scrollController: ChatScrollController { windowed.scrollController }

    init() {
        windowed = makeWindowedTimelineHarness(
            sessionId: "image-preview-return-position-\(UUID().uuidString)",
            useAnchoredCollectionView: true
        )
        host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = windowed.window.bounds

        collectionView.removeFromSuperview()
        collectionView.frame = host.view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.accessibilityIdentifier = "chat.timeline"
        collectionView.delegate = coordinator
        host.view.addSubview(collectionView)

        sourceView.frame = CGRect(x: 8, y: 8, width: 44, height: 44)
        host.view.addSubview(sourceView)
        windowed.window.rootViewController = host
        windowed.window.makeKeyAndVisible()

        let items = (0 ..< 90).map { index in
            ChatItem.assistantMessage(
                id: "assistant-history-\(index)",
                text: Array(
                    repeating: "Stable assistant history row \(index) with deterministic wrapped text.",
                    count: 4
                ).joined(separator: "\n"),
                timestamp: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        windowed.applyItems(items, isBusy: false)
        settleTimelineLayout(collectionView, passes: 4)
    }

    func exerciseUpThenDownAndCaptureMidHistoryAnchor() throws -> ReadingAnchor {
        let lastIndex = coordinator.currentIDs.count - 1
        collectionView.scrollToItem(
            at: IndexPath(item: lastIndex, section: 0),
            at: .bottom,
            animated: false
        )
        settleTimelineLayout(collectionView, passes: 2)

        // Match the reported interaction sequence: scroll away from the tail,
        // reverse direction, then stop at a deliberate detached reading point.
        collectionView.scrollToItem(
            at: IndexPath(item: 16, section: 0),
            at: .top,
            animated: false
        )
        settleTimelineLayout(collectionView, passes: 2)
        scrollController.detachFromBottomForUserScroll()
        collectionView.scrollToItem(
            at: IndexPath(item: 27, section: 0),
            at: .top,
            animated: false
        )
        settleTimelineLayout(collectionView, passes: 3)
        coordinator.updateScrollState(collectionView)
        scrollController.detachFromBottomForUserScroll()

        let visible = collectionView.indexPathsForVisibleItems.sorted { lhs, rhs in
            let lhsY = collectionView.layoutAttributesForItem(at: lhs)?.frame.minY ?? .greatestFiniteMagnitude
            let rhsY = collectionView.layoutAttributesForItem(at: rhs)?.frame.minY ?? .greatestFiniteMagnitude
            return lhsY < rhsY
        }
        let indexPath = try #require(visible.first)
        let attributes = try #require(collectionView.layoutAttributesForItem(at: indexPath))
        let itemID = coordinator.currentIDs[indexPath.item]
        let viewportRelativeY = attributes.frame.minY - collectionView.contentOffset.y

        #expect(!scrollController.isCurrentlyNearBottom)
        #expect(indexPath.item > 0 && indexPath.item < lastIndex)
        return ReadingAnchor(itemID: itemID, viewportRelativeY: viewportRelativeY)
    }

    func prepareAttachedTail() {
        let lastIndex = coordinator.currentIDs.count - 1
        collectionView.scrollToItem(
            at: IndexPath(item: lastIndex, section: 0),
            at: .bottom,
            animated: false
        )
        settleTimelineLayout(collectionView, passes: 3)
        scrollController.updateNearBottom(true)
    }

    func simulatePreviewReturnLosingDetachedPosition() {
        prepareAttachedTail()
    }

    func simulatePreviewReturnLosingAttachedTail() {
        collectionView.scrollToItem(
            at: IndexPath(item: 22, section: 0),
            at: .top,
            animated: false
        )
        settleTimelineLayout(collectionView, passes: 2)
        scrollController.detachFromBottomForUserScroll()
    }

    func waitForPreviewDismissal() async -> Bool {
        let dismissed = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
            self.host.presentedViewController == nil
        }
        await Task.yield()
        await Task.yield()
        return dismissed
    }

    func assertReadingAnchor(_ anchor: ReadingAnchor) {
        settleTimelineLayout(collectionView, passes: 4)
        guard let index = coordinator.currentIDs.firstIndex(of: anchor.itemID),
              let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
              ) else {
            Issue.record("Stable timeline item \(anchor.itemID) disappeared after image preview dismissal")
            return
        }

        let actualY = attributes.frame.minY - collectionView.contentOffset.y
        #expect(
            abs(actualY - anchor.viewportRelativeY) <= 1,
            "Image return moved \(anchor.itemID) from viewport y=\(anchor.viewportRelativeY) to y=\(actualY)"
        )
        #expect(!scrollController.isCurrentlyNearBottom, "Detached image return must not attach to the live tail")
    }

    func assertAttachedToTail() {
        settleTimelineLayout(collectionView, passes: 4)
        let insets = collectionView.adjustedContentInset
        let maxOffsetY = max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
        #expect(scrollController.isCurrentlyNearBottom)
        #expect(abs(collectionView.contentOffset.y - maxOffsetY) <= 1)
    }

    func teardown() {
        host.dismiss(animated: false)
        windowed.window.isHidden = true
        windowed.window.rootViewController = nil
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
private func allLabelTexts(in root: UIView) -> [String] {
    var texts: [String] = []
    if let label = root as? UILabel, let text = label.text {
        texts.append(text)
    }

    for child in root.subviews {
        texts.append(contentsOf: allLabelTexts(in: child))
    }

    return texts
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
