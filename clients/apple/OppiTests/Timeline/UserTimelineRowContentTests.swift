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
    @Test("user row keeps reloaded skill-only turns visible as /skill:name")
    func userRowKeepsReloadedSkillOnlyTurnsVisibleAsSlashCommand() throws {
        let raw = """
        <skill name="zwift-coros-sync" location="/Users/chenda/.pi/agent/skills/zwift-coros-sync/SKILL.md">
        References are relative to /Users/chenda/.pi/agent/skills/zwift-coros-sync.

        # Zwift–COROS Sync

        Use the standalone CLI.
        </skill>
        """
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: raw,
                images: [],
                canFork: false,
                onFork: nil
            )
        )

        view.frame = CGRect(x: 0, y: 0, width: 390, height: 200)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let renderedTextView = try #require(userMessageTextView(in: view))
        let bubble = try #require(userMessageBubbleContainer(in: view))
        #expect(renderedTextView.text == "/skill:zwift-coros-sync")
        #expect(!renderedTextView.isHidden)
        #expect(!bubble.isHidden)
        #expect(view.copyableText == "/skill:zwift-coros-sync")
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
    @Test("user row renders GFM tables with NativeTableBlockView instead of ASCII pipes")
    func userRowRendersGFMTablesWithNativeTableView() throws {
        let markdown = """
        Complexity is concentrated.

        | Tree | Files | Lines |
        |------|------:|------:|
        | `server/src/**/*.ts` | 245 | 84,865 |
        | `clients/apple/**/*.swift` (tests, E2E, perf, Mac included) | 1,002 | 353,511 |
        """
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: markdown,
                images: [],
                canFork: false,
                onFork: nil
            )
        )
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 640)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let table = try #require(firstSubview(ofType: NativeTableBlockView.self, in: view))
        #expect(table.accessibilityIdentifier == "markdown.table")
        #expect(table.bounds.height > 1)

        let textView = try #require(userMessageTextView(in: view))
        let rendered = textView.text ?? ""
        #expect(rendered.contains("Complexity is concentrated."))
        #expect(!rendered.contains("Tree | Files | Lines"))
        #expect(!rendered.contains("────"))
    }

    @MainActor
    @Test("user row renders a simple HTML table as NativeTableBlockView")
    func userRowRendersSimpleHTMLTable() throws {
        let markdown = """
        Summary

        <table>
        <tr><th>Path</th><th>Lines</th></tr>
        <tr><td>a.ts</td><td>12</td></tr>
        </table>
        """
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: markdown,
                images: [],
                canFork: false,
                onFork: nil
            )
        )
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        #expect(firstSubview(ofType: NativeTableBlockView.self, in: view) != nil)
        let textView = try #require(userMessageTextView(in: view))
        #expect(!(textView.text ?? "").contains("<table>"))
    }

    @MainActor
    @Test("user row renders a table-only prompt without ASCII fallback")
    func userRowRendersTableOnlyPrompt() throws {
        let markdown = """
        | Path | Lines |
        | --- | ---: |
        | a.ts | 12 |
        """
        let view = UserTimelineRowContentView(
            configuration: UserTimelineRowConfiguration(
                text: markdown,
                images: [],
                canFork: false,
                onFork: nil
            )
        )
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 320)
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let table = try #require(firstSubview(ofType: NativeTableBlockView.self, in: view))
        #expect(table.bounds.height > 1)
        let textView = try #require(userMessageTextView(in: view))
        #expect(textView.isHidden)
        #expect(!(textView.text ?? "").contains("Path | Lines"))
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
        #expect(await fixture.waitForPreviewPresentation())
        fixture.assertReadingAnchorWithoutDrivingLayout(anchor, phase: "presentation")

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

        #expect(await fixture.waitForPreviewPresentation())
        fixture.assertReadingAnchorWithoutDrivingLayout(anchor, phase: "data-image presentation")
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

        #expect(await fixture.waitForPreviewPresentation())
        fixture.assertReadingAnchorWithoutDrivingLayout(anchor, phase: "native-sheet presentation")
        let remounted = fixture.remountTimelineWhilePreviewIsOpen()
        fixture.host.dismiss(animated: false)

        #expect(await fixture.waitForPreviewDismissal())
        fixture.assertReadingAnchor(
            anchor,
            collectionView: remounted.collectionView,
            coordinator: remounted.coordinator
        )
    }

    @MainActor
    @Test("attached image return stays on the live tail")
    func attachedImageReturnStaysOnLiveTail() async throws {
        let fixture = ImagePreviewTimelineFixture()
        defer { fixture.teardown() }

        fixture.prepareAttachedTail()
        FullScreenImageViewController.present(image: makeTestImage(), from: fixture.host)
        _ = try #require(fixture.host.presentedViewController)

        #expect(await fixture.waitForPreviewPresentation())
        fixture.assertAttachedToTailWithoutDrivingLayout(phase: "presentation")
        fixture.host.dismiss(animated: false)

        #expect(await fixture.waitForPreviewDismissal())
        fixture.assertAttachedToTail()
    }

    @MainActor
    @Test("queued attached-tail restoration cancels when touch starts after image dismissal")
    func queuedAttachedTailRestorationCancelsWhenTouchStarts() async throws {
        let fixture = ImagePreviewTimelineFixture()
        defer { fixture.teardown() }

        fixture.prepareAttachedTail()
        await Task.yield()
        await Task.yield()
        let restoration = try #require(
            TimelineScrollCoordinator.captureImagePreviewViewport(from: fixture.host)
        )
        restoration.restore()

        fixture.coordinator.scrollViewWillBeginDragging(fixture.collectionView)
        fixture.scrollController.detachFromBottomForUserScroll()
        if let anchoredCollectionView = fixture.collectionView as? AnchoredCollectionView {
            // Real tracking bypasses detached-anchor correction. Unit tests
            // cannot set UIKit's read-only gesture flags, so mirror that state.
            anchoredCollectionView.isDetachedFromBottom = false
            anchoredCollectionView.clearDetachedAnchor()
            anchoredCollectionView.layoutIfNeeded()
        }
        let touchedOffsetY = TimelineOffsetController.clampedOffsetY(
            fixture.collectionView.contentOffset.y - 180,
            in: fixture.collectionView
        )
        fixture.collectionView.contentOffset.y = touchedOffsetY
        fixture.coordinator.scrollViewDidEndDragging(
            fixture.collectionView,
            willDecelerate: false
        )

        try? await Task.sleep(for: .milliseconds(80))

        #expect(!fixture.scrollController.isUserInteracting)
        #expect(!fixture.scrollController.isCurrentlyNearBottom)
        #expect(
            abs(fixture.collectionView.contentOffset.y - touchedOffsetY) <= 1,
            "Every deferred pass from the canceled preview must stay invalid after a completed drag"
        )
    }

    @MainActor
    @Test("failed image presentation releases viewport freeze ownership")
    func failedImagePresentationReleasesViewportFreezeOwnership() async throws {
        let rejectingHost = RejectingImagePreviewHostController()
        let fixture = ImagePreviewTimelineFixture(host: rejectingHost)
        defer { fixture.teardown() }

        _ = try fixture.exerciseUpThenDownAndCaptureMidHistoryAnchor()
        let navigation = FullScreenImageViewController.makeSlideDownController(image: makeTestImage())
        ImagePreviewPresentationCoordinator.present(navigation, from: rejectingHost)
        await Task.yield()
        await Task.yield()

        #expect(rejectingHost.rejectedController === navigation)
        fixture.scrollController.updateNearBottom(true)
        #expect(
            fixture.scrollController.isCurrentlyNearBottom,
            "An aborted presentation must release the detached-intent freeze"
        )
    }

    @MainActor
    @Test("window growth remount maps a full-order image target into the rendered suffix")
    func windowGrowthRemountMapsFullOrderImageTargetIntoRenderedSuffix() async throws {
        let originalAllItems = makeImagePreviewTimelineItems(prefix: "original", count: 240)
        let fixture = ImagePreviewTimelineFixture(
            items: Array(originalAllItems.suffix(80)),
            fullTimelineItemIDs: originalAllItems.map(\.id)
        )
        defer { fixture.teardown() }

        let originalAnchor = try fixture.exerciseUpThenDownAndCaptureMidHistoryAnchor()
        FullScreenImageViewController.present(image: makeTestImage(), from: fixture.host)
        #expect(await fixture.waitForPreviewPresentation())

        let ordinalText = try #require(originalAnchor.itemID.split(separator: "-").last)
        let ordinal = try #require(Int(ordinalText))
        let replacementAllItems = makeImagePreviewTimelineItems(prefix: "replacement", count: 300)
        let remounted = fixture.remountTimelineWhilePreviewIsOpen(
            items: Array(replacementAllItems.suffix(80)),
            fullTimelineItemIDs: replacementAllItems.map(\.id)
        )
        let fullOrderTargetID = "replacement-\(ordinal)"
        #expect(!remounted.coordinator.currentIDs.contains(fullOrderTargetID))
        let renderedFallbackID = try #require(remounted.coordinator.currentIDs.first)
        #expect(renderedFallbackID == "replacement-220")

        // A remounted suffix can initially settle on its own nearby context.
        // Restoration must correct from there without jumping to the live tail.
        remounted.collectionView.scrollToItem(
            at: IndexPath(item: 12, section: 0),
            at: .top,
            animated: false
        )
        remounted.collectionView.layoutIfNeeded()
        fixture.host.dismiss(animated: false)

        #expect(await fixture.waitForPreviewDismissal())
        fixture.assertReadingAnchor(
            ImagePreviewTimelineFixture.ReadingAnchor(
                itemID: renderedFallbackID,
                viewportRelativeY: originalAnchor.viewportRelativeY
            ),
            collectionView: remounted.collectionView,
            coordinator: remounted.coordinator
        )
    }

    @MainActor
    @Test("interrupted image presentation cleanup releases viewport ownership")
    func interruptedImagePresentationCleanupReleasesViewportOwnership() throws {
        let fixture = ImagePreviewTimelineFixture()
        defer { fixture.teardown() }

        _ = try fixture.exerciseUpThenDownAndCaptureMidHistoryAnchor()
        let navigation = try #require(
            FullScreenImageViewController.makeSlideDownController(image: makeTestImage())
                as? ImagePreviewNavigationController
        )
        navigation.preserveTimelineViewport(from: fixture.host)

        // UIKit transition cancellation is routed through this lifecycle seam.
        navigation.presentationDidAbort()

        fixture.scrollController.updateNearBottom(true)
        #expect(fixture.scrollController.isCurrentlyNearBottom)
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
    let items: [ChatItem]
    let fullTimelineItemIDs: [String]

    var collectionView: UICollectionView { windowed.collectionView }
    var coordinator: ChatTimelineCollectionHost.Controller { windowed.coordinator }
    var scrollController: ChatScrollController { windowed.scrollController }

    init(
        host: UIViewController = UIViewController(),
        items: [ChatItem]? = nil,
        fullTimelineItemIDs: [String]? = nil
    ) {
        let resolvedItems = items ?? makeImagePreviewTimelineItems(
            prefix: "assistant-history",
            count: 90
        )
        self.items = resolvedItems
        self.fullTimelineItemIDs = fullTimelineItemIDs ?? resolvedItems.map(\.id)
        windowed = makeWindowedTimelineHarness(
            sessionId: "image-preview-return-position-\(UUID().uuidString)",
            useAnchoredCollectionView: true
        )
        self.host = host
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

        let configuration = makeTimelineConfiguration(
            items: resolvedItems,
            fullTimelineItemIDs: self.fullTimelineItemIDs,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        coordinator.apply(configuration: configuration, to: collectionView)
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

    func remountTimelineWhilePreviewIsOpen(
        items replacementItems: [ChatItem]? = nil,
        fullTimelineItemIDs replacementFullTimelineItemIDs: [String]? = nil
    ) -> (
        collectionView: UICollectionView,
        coordinator: ChatTimelineCollectionHost.Controller
    ) {
        let replacement = AnchoredCollectionView(
            frame: host.view.bounds,
            collectionViewLayout: ChatTimelineCollectionHost.makeTestLayout()
        )
        replacement.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        replacement.accessibilityIdentifier = "chat.timeline"

        let replacementCoordinator = ChatTimelineCollectionHost.Controller()
        replacementCoordinator.configureDataSource(collectionView: replacement)
        replacement.delegate = replacementCoordinator
        host.view.insertSubview(replacement, belowSubview: sourceView)
        collectionView.removeFromSuperview()

        let configuration = makeTimelineConfiguration(
            items: replacementItems ?? items,
            fullTimelineItemIDs: replacementFullTimelineItemIDs ?? fullTimelineItemIDs,
            isBusy: false,
            sessionId: windowed.sessionId,
            reducer: windowed.reducer,
            toolOutputStore: windowed.toolOutputStore,
            toolArgsStore: windowed.toolArgsStore,
            toolSegmentStore: windowed.toolSegmentStore,
            connection: windowed.connection,
            scrollController: windowed.scrollController,
            audioPlayer: windowed.audioPlayer
        )
        replacementCoordinator.apply(configuration: configuration, to: replacement)
        replacement.layoutIfNeeded()
        return (replacement, replacementCoordinator)
    }

    func waitForPreviewPresentation() async -> Bool {
        let presented = await waitForTimelineCondition(timeoutMs: 1_000) { @MainActor in
            guard let presented = self.host.presentedViewController else { return false }
            return presented.viewIfLoaded?.window != nil
                && presented.transitionCoordinator == nil
        }
        await Task.yield()
        return presented
    }

    func assertReadingAnchorWithoutDrivingLayout(_ anchor: ReadingAnchor, phase: String) {
        guard let index = coordinator.currentIDs.firstIndex(of: anchor.itemID),
              let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
              ) else {
            Issue.record("Stable timeline item \(anchor.itemID) disappeared during image preview \(phase)")
            return
        }

        let actualY = attributes.frame.minY - collectionView.contentOffset.y
        #expect(
            abs(actualY - anchor.viewportRelativeY) <= 1,
            "Image preview \(phase) moved \(anchor.itemID) from viewport y=\(anchor.viewportRelativeY) to y=\(actualY)"
        )
        #expect(!scrollController.isCurrentlyNearBottom)
    }

    func assertAttachedToTailWithoutDrivingLayout(phase: String) {
        let insets = collectionView.adjustedContentInset
        let maxOffsetY = max(
            -insets.top,
            collectionView.contentSize.height - collectionView.bounds.height + insets.bottom
        )
        #expect(scrollController.isCurrentlyNearBottom)
        #expect(
            abs(collectionView.contentOffset.y - maxOffsetY) <= 1,
            "Image preview \(phase) moved the live tail from y=\(maxOffsetY) to y=\(collectionView.contentOffset.y)"
        )
    }

    func waitForPreviewDismissal() async -> Bool {
        let dismissed = await waitForTimelineCondition(timeoutMs: 500) { @MainActor in
            self.host.presentedViewController == nil
        }
        await Task.yield()
        await Task.yield()
        return dismissed
    }

    func assertReadingAnchor(
        _ anchor: ReadingAnchor,
        collectionView: UICollectionView? = nil,
        coordinator: ChatTimelineCollectionHost.Controller? = nil
    ) {
        let targetCollectionView = collectionView ?? self.collectionView
        let targetCoordinator = coordinator ?? self.coordinator
        settleTimelineLayout(targetCollectionView, passes: 4)
        guard let index = targetCoordinator.currentIDs.firstIndex(of: anchor.itemID),
              let attributes = targetCollectionView.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
              ) else {
            Issue.record("Stable timeline item \(anchor.itemID) disappeared after image preview dismissal")
            return
        }

        let actualY = attributes.frame.minY - targetCollectionView.contentOffset.y
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
private final class RejectingImagePreviewHostController: UIViewController {
    private(set) var rejectedController: UIViewController?

    override func present(
        _ viewControllerToPresent: UIViewController,
        animated flag: Bool,
        completion: (() -> Void)? = nil
    ) {
        rejectedController = viewControllerToPresent
    }
}

private func makeImagePreviewTimelineItems(prefix: String, count: Int) -> [ChatItem] {
    (0..<count).map { index in
        ChatItem.assistantMessage(
            id: "\(prefix)-\(index)",
            text: Array(
                repeating: "Stable assistant history row \(index) with deterministic wrapped text.",
                count: 4
            ).joined(separator: "\n"),
            timestamp: Date(timeIntervalSince1970: TimeInterval(index))
        )
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
