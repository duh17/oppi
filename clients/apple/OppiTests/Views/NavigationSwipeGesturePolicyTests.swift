import CoreGraphics
import Testing
import UIKit
@testable import Oppi

@MainActor
@Suite("Navigation swipe gesture policy")
struct NavigationSwipeGesturePolicyTests {

    @Test func downDismissMayClaimWhenContentCannotScroll() {
        let scrollView = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentSize: CGSize(width: 320, height: 200),
            contentOffset: .zero
        )

        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [scrollView]
        ))
    }

    @Test func downDismissMayClaimWhenScrollableContentIsAtTop() {
        let scrollView = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentSize: CGSize(width: 320, height: 2_000),
            contentOffset: CGPoint(x: 0, y: -96),
            adjustedTopInset: 96
        )

        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [scrollView]
        ))
    }

    @Test func downDismissMayClaimDuringTopRubberBandOverpull() {
        let scrollView = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentSize: CGSize(width: 320, height: 2_000),
            contentOffset: CGPoint(x: 0, y: -140),
            adjustedTopInset: 96
        )

        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [scrollView]
        ))
    }

    @Test func downDismissMustNotClaimWhenScrollableContentHasRoomAbove() {
        let scrollView = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentSize: CGSize(width: 320, height: 2_000),
            contentOffset: CGPoint(x: 0, y: 420),
            adjustedTopInset: 96
        )

        #expect(!NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [scrollView]
        ))
    }

    @Test func downDismissIgnoresDisabledScrollViewsWhenDecidingClaim() {
        let disabled = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentSize: CGSize(width: 320, height: 2_000),
            contentOffset: CGPoint(x: 0, y: 420),
            adjustedTopInset: 96
        )
        disabled.isScrollEnabled = false

        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [disabled]
        ))
    }

    @Test func downDismissMayClaimWhenNoScrollViewsArePresent() {
        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: []
        ))
    }

    @Test func downDismissScopesToScrollViewUnderTouchNotUnrelatedSibling() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let touched = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 390, height: 400),
            contentSize: CGSize(width: 390, height: 200),
            contentOffset: .zero
        )
        let unrelatedScrolled = makeScrollView(
            bounds: CGRect(x: 0, y: 420, width: 390, height: 400),
            contentSize: CGSize(width: 390, height: 2_000),
            contentOffset: CGPoint(x: 0, y: 500)
        )
        host.addSubview(touched)
        host.addSubview(unrelatedScrolled)

        // Without location, any scrolled descendant blocks (conservative fallback).
        #expect(!NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [touched, unrelatedScrolled],
            hostView: host
        ))

        // Touch on the short/top content must not be vetoed by a sibling list.
        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [touched, unrelatedScrolled],
            touchLocationInHost: CGPoint(x: 40, y: 40),
            hostView: host
        ))

        // Touch on the scrolled sibling still refuses dismiss.
        #expect(!NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [touched, unrelatedScrolled],
            touchLocationInHost: CGPoint(x: 40, y: 500),
            hostView: host
        ))

        // Touch in chrome outside every scroll view may claim.
        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [touched, unrelatedScrolled],
            touchLocationInHost: CGPoint(x: 20, y: 830),
            hostView: host
        ))
    }

    @Test func rightBackMayClaimWhenContentCannotScrollHorizontally() {
        let scrollView = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentSize: CGSize(width: 300, height: 500),
            contentOffset: .zero
        )

        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .right,
            scrollViews: [scrollView]
        ))
    }

    @Test func rightBackMustNotClaimWhenHorizontallyScrollableContentHasRoomLeading() {
        let scrollView = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentSize: CGSize(width: 1_200, height: 500),
            contentOffset: CGPoint(x: 180, y: 0)
        )

        #expect(!NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .right,
            scrollViews: [scrollView]
        ))
    }

    @Test func rightBackMayClaimWhenHorizontallyScrollableContentIsAtLeadingEdge() {
        let scrollView = makeScrollView(
            bounds: CGRect(x: 0, y: 0, width: 320, height: 500),
            contentSize: CGSize(width: 1_200, height: 500),
            contentOffset: .zero
        )

        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .right,
            scrollViews: [scrollView]
        ))
    }

    @Test func rightBackIgnoresUnrelatedHorizontallyScrolledSiblingUnderTouchScope() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let timeline = makeScrollView(
            bounds: host.bounds,
            contentSize: CGSize(width: 390, height: 3_000),
            contentOffset: .zero
        )
        let codeBlock = makeScrollView(
            bounds: CGRect(x: 12, y: 200, width: 366, height: 120),
            contentSize: CGSize(width: 1_200, height: 120),
            contentOffset: CGPoint(x: 240, y: 0)
        )
        host.addSubview(timeline)
        timeline.addSubview(codeBlock)

        // Finger on empty timeline chrome/rows — not the code block — may back.
        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .right,
            scrollViews: [timeline, codeBlock],
            touchLocationInHost: CGPoint(x: 20, y: 40),
            hostView: host
        ))

        // Finger on the sideways-scrolled code block must not back-navigate.
        #expect(!NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .right,
            scrollViews: [timeline, codeBlock],
            touchLocationInHost: CGPoint(x: 40, y: 240),
            hostView: host
        ))
    }

    @Test func modalFullScreenCodeReaderExposesScrollEdgeStateForDismissGate() throws {
        let longLog = Array(repeating: "build step output line", count: 200).joined(separator: "\n")
        let controller = FullScreenCodeViewController(
            content: .plainText(content: longLog, filePath: "log.txt"),
            presentationMode: .sheet
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let scrollViews = NavigationSwipeGesturePolicy.descendantScrollViews(in: controller.view)
        let scrollView = try #require(scrollViews.first(where: isVerticallyScrollable))

        let topY = -scrollView.adjustedContentInset.top
        scrollView.setContentOffset(CGPoint(x: 0, y: topY + 360), animated: false)
        #expect(!NavigationSwipeGesturePolicy.canClaimSwipe(direction: .down, scrollViews: scrollViews))

        scrollView.setContentOffset(CGPoint(x: 0, y: topY), animated: false)
        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(direction: .down, scrollViews: scrollViews))
    }

    @Test func installerRejectsDownDismissWhileHostContentHasRoomAbove() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scrollView = makeScrollView(
            bounds: host.bounds,
            contentSize: CGSize(width: 390, height: 2_400),
            contentOffset: CGPoint(x: 0, y: 500),
            adjustedTopInset: 0
        )
        host.addSubview(scrollView)

        var dismissed = false
        let installer = HorizontalBackSwipeGestureInstaller(
            onBack: { dismissed = true },
            direction: .down
        )
        installer.install(on: host)

        let touch = CGPoint(x: 40, y: 200)
        #expect(!installer.shouldBeginNavigationSwipe(
            velocity: CGPoint(x: 0, y: 900),
            in: host,
            touchLocationInHost: touch
        ))
        #expect(!dismissed)

        installer.handleNavigationSwipeEnded(
            translation: CGSize(width: 0, height: 120),
            in: host,
            touchLocationInHost: touch
        )
        #expect(!dismissed)

        scrollView.contentOffset = .zero
        #expect(installer.shouldBeginNavigationSwipe(
            velocity: CGPoint(x: 0, y: 900),
            in: host,
            touchLocationInHost: touch
        ))
        installer.handleNavigationSwipeEnded(
            translation: CGSize(width: 0, height: 120),
            in: host,
            touchLocationInHost: touch
        )
        #expect(dismissed)
    }

    @Test func installerClearsTouchScopeWhenShouldBeginRejects() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let scrollView = makeScrollView(
            bounds: host.bounds,
            contentSize: CGSize(width: 390, height: 2_400),
            contentOffset: CGPoint(x: 0, y: 500)
        )
        host.addSubview(scrollView)

        let installer = HorizontalBackSwipeGestureInstaller(onBack: {}, direction: .down)
        installer.install(on: host)
        let pan = try #require(
            host.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first
        )

        // Seed the location a real shouldReceive would capture. Rejecting begin must
        // clear it because UIKit does not call the action selector on .failed.
        installer.setActiveTouchLocationForTesting(CGPoint(x: 40, y: 200))
        #expect(installer.activeTouchLocationForTesting() != nil)
        #expect(!installer.gestureRecognizerShouldBegin(pan))
        #expect(installer.activeTouchLocationForTesting() == nil)
    }

    @Test func installerUsesSingleTouchPanRecognizer() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let installer = HorizontalBackSwipeGestureInstaller(onBack: {}, direction: .down)
        installer.install(on: host)

        let pan = host.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first
        #expect(pan?.maximumNumberOfTouches == 1)
    }

    @Test func installerAllowsSimultaneousRecognitionOnlyWithScrollViewOwnPan() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        let scrollView = UIScrollView(frame: host.bounds)
        host.addSubview(scrollView)
        let installer = HorizontalBackSwipeGestureInstaller(onBack: {}, direction: .down)
        installer.install(on: host)

        let dismissPan = try #require(
            host.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first
        )
        let foreignPanOnScrollView = UIPanGestureRecognizer()
        scrollView.addGestureRecognizer(foreignPanOnScrollView)
        let pinch = UIPinchGestureRecognizer()
        host.addGestureRecognizer(pinch)

        #expect(installer.gestureRecognizer(
            dismissPan,
            shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer
        ))
        #expect(!installer.gestureRecognizer(
            dismissPan,
            shouldRecognizeSimultaneouslyWith: foreignPanOnScrollView
        ))
        #expect(!installer.gestureRecognizer(dismissPan, shouldRecognizeSimultaneouslyWith: pinch))
    }

    @Test func downDismissIgnoresCoveredScrolledSiblingUnderHitTestScope() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let covered = makeScrollView(
            bounds: host.bounds,
            contentSize: CGSize(width: 390, height: 2_400),
            contentOffset: CGPoint(x: 0, y: 600)
        )
        let overlay = UIView(frame: host.bounds)
        overlay.backgroundColor = .black
        overlay.isUserInteractionEnabled = true
        host.addSubview(covered)
        host.addSubview(overlay)

        // Geometric fallback without a live hit would see the covered scroller;
        // hit-testing the overlay must allow dismiss because the finger never
        // reaches the scrolled content underneath.
        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [covered],
            touchLocationInHost: CGPoint(x: 40, y: 200),
            hostView: host
        ))
    }

    @Test func backSwipeSuppressesPopWhenSeekClaimReleasedBeforeParentEnds() {
        let swipe = CGSize(width: 90, height: 12)

        // Begin: the child seek drag acquires an exclusive claim.
        let claim = HorizontalBackSwipeGesturePolicy.acquireExclusiveClaim()
        #expect(HorizontalBackSwipeGesturePolicy.hasActiveExclusiveClaim)

        // Parent onChanged latches while the claim is active.
        let latched = HorizontalBackSwipeGesturePolicy.hasActiveExclusiveClaim
        #expect(latched)

        // Child end: the claim is released before the parent ends.
        HorizontalBackSwipeGesturePolicy.releaseExclusiveClaim(claim)
        #expect(!HorizontalBackSwipeGesturePolicy.hasActiveExclusiveClaim)

        // Parent end: the latched suppression still prevents the pop.
        var backCount = 0
        HorizontalBackSwipeGesturePolicy.handleSwiftUIBackSwipeEnded(
            translation: swipe,
            didLatchSuppression: latched,
            onBack: { backCount += 1 }
        )
        #expect(backCount == 0)
    }

    @Test func offBarSwipeWithoutClaimStillPops() {
        let swipe = CGSize(width: 90, height: 12)
        #expect(!HorizontalBackSwipeGesturePolicy.hasActiveExclusiveClaim)

        var backCount = 0
        HorizontalBackSwipeGesturePolicy.handleSwiftUIBackSwipeEnded(
            translation: swipe,
            didLatchSuppression: false,
            onBack: { backCount += 1 }
        )
        #expect(backCount == 1)
    }

    @Test func releasedClaimDoesNotPoisonSubsequentBackSwipes() {
        let claim = HorizontalBackSwipeGesturePolicy.acquireExclusiveClaim()
        #expect(HorizontalBackSwipeGesturePolicy.hasActiveExclusiveClaim)

        // Idempotent release on cancel/teardown must never underflow or leak.
        HorizontalBackSwipeGesturePolicy.releaseExclusiveClaim(claim)
        HorizontalBackSwipeGesturePolicy.releaseExclusiveClaim(claim)

        #expect(!HorizontalBackSwipeGesturePolicy.hasActiveExclusiveClaim)

        // A fresh off-bar swipe must still pop.
        let swipe = CGSize(width: 90, height: 12)
        var backCount = 0
        HorizontalBackSwipeGesturePolicy.handleSwiftUIBackSwipeEnded(
            translation: swipe,
            didLatchSuppression: false,
            onBack: { backCount += 1 }
        )
        #expect(backCount == 1)
    }

    @Test func downDismissIgnoresScrollViewInsideNonInteractiveAncestor() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        container.isUserInteractionEnabled = false
        let scrollView = makeScrollView(
            bounds: container.bounds,
            contentSize: CGSize(width: 320, height: 2_000),
            contentOffset: CGPoint(x: 0, y: 400)
        )
        container.addSubview(scrollView)

        #expect(NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: .down,
            scrollViews: [scrollView]
        ))
    }

    // MARK: - Helpers

    private func makeScrollView(
        bounds: CGRect,
        contentSize: CGSize,
        contentOffset: CGPoint,
        adjustedTopInset: CGFloat = 0,
        adjustedLeftInset: CGFloat = 0
    ) -> UIScrollView {
        let scrollView = InsetAwareScrollView()
        scrollView.frame = bounds
        scrollView.bounds = CGRect(origin: .zero, size: bounds.size)
        scrollView.contentSize = contentSize
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.stubbedAdjustedContentInset = UIEdgeInsets(
            top: adjustedTopInset,
            left: adjustedLeftInset,
            bottom: 0,
            right: 0
        )
        scrollView.contentInset = scrollView.stubbedAdjustedContentInset
        scrollView.contentOffset = contentOffset
        return scrollView
    }

    private func isVerticallyScrollable(_ scrollView: UIScrollView) -> Bool {
        let viewport = scrollView.bounds.height
            - scrollView.adjustedContentInset.top
            - scrollView.adjustedContentInset.bottom
        return scrollView.contentSize.height > viewport + 0.5
    }
}

/// `adjustedContentInset` is read-only on `UIScrollView`; tests stub it so edge
/// math can be exercised without a full window safe-area pass.
private final class InsetAwareScrollView: UIScrollView {
    var stubbedAdjustedContentInset: UIEdgeInsets = .zero

    override var adjustedContentInset: UIEdgeInsets {
        stubbedAdjustedContentInset
    }
}
