import SwiftUI
import TipKit
import UIKit

/// Shared chrome convention for all fullscreen viewer controllers.
///
/// Fullscreen viewers use immersive presentation: content extends
/// behind the navigation bar, and bar items render as floating
/// Liquid Glass pills (the iOS 26 default when no custom
/// `UINavigationBarAppearance` is set).
///
/// The convention:
/// 1. Do NOT set a custom `UINavigationBarAppearance` on the content VC.
/// 2. Pin the body view's top to `view.topAnchor` (not `safeAreaLayoutGuide`).
/// 3. Do NOT set a `titleView` — only left/right bar button items.
///
/// Scroll views inside body views use `contentInsetAdjustmentBehavior = .automatic`
/// (the default) so content starts below the bar but scrolls behind it.
///
/// To revert to an opaque header:
/// 1. Set a `UINavigationBarAppearance` with `configureWithOpaqueBackground()`
/// 2. Pin content to `safeAreaLayoutGuide.topAnchor`
/// 3. Optionally restore `titleView`
///
/// Both ``FullScreenCodeViewController`` and ``FullScreenImageViewController``
/// follow this pattern.
enum FullScreenViewerChrome {
    // Marker enum — the convention is documented above.
    // Grep for `FullScreenViewerChrome` to find all adopters.
}

enum FullScreenFloatingControlChrome {
    static let bottomPadding: CGFloat = 22
    static let trailingPadding: CGFloat = 16
    static let controlSize: CGFloat = 56
    static let groupedButtonSize: CGFloat = 36
    static let groupHorizontalPadding: CGFloat = 14
    static let groupVerticalPadding: CGFloat = (controlSize - groupedButtonSize) / 2
    static let symbolPointSize: CGFloat = 20
    static let standaloneContentPadding: CGFloat = (controlSize - symbolPointSize) / 2

    static func applyGlassBackground(
        to config: inout UIButton.Configuration,
        palette: ThemePalette
    ) {
        config.cornerStyle = .capsule
        // Fill comes from the shared surface resolver so the floating-control
        // opacity is chosen in exactly one place (ThemeSurfaceStyle.resolve).
        config.background.backgroundColor = UIColor(
            ThemeSurfaceStyle.resolve(.floatingControl, palette: palette).fill
        )
        config.baseForegroundColor = UIColor(palette.fg)
    }
}

extension View {
    func fullScreenFloatingControlGlass<S: Shape>(in shape: S) -> some View {
        themedSurface(.floatingControl, in: shape)
    }
}

/// Direction for navigation-style swipe gestures.
///
/// Keep the gesture direction aligned with the visible navigation glyph:
/// `chevron.backward` uses a rightward back swipe, and `chevron.down` uses a
/// downward dismissal swipe.
enum NavigationSwipeGestureDirection: Equatable {
    case right
    case down
}

/// Shared policy for navigation and dismissal swipes.
///
/// We keep this policy pure and tiny so SwiftUI and UIKit hosts use the same
/// thresholds. This avoids the earlier split where file preview swipes,
/// full-screen viewers, and chat timeline each guessed independently and fought
/// document scrolling.
///
/// Modal down-dismiss follows the same edge rule as system sheets: only claim
/// the gesture when there is no more content to reveal by scrolling in that
/// direction (at top / content does not overflow). Mid-document pans must stay
/// with the scroll view.
enum NavigationSwipeGesturePolicy {
    static let minimumDistance: CGFloat = 72
    static let dominanceRatio: CGFloat = 1.35
    /// Allow sub-point layout noise and rubber-band settle before treating an
    /// edge as left.
    static let scrollEdgeTolerance: CGFloat = 1.0

    static func isSwipe(translation: CGSize, direction: NavigationSwipeGestureDirection) -> Bool {
        switch direction {
        case .right:
            let primary = translation.width
            let secondary = abs(translation.height)
            guard primary >= minimumDistance else { return false }
            return primary > secondary * dominanceRatio
        case .down:
            let primary = translation.height
            let secondary = abs(translation.width)
            guard primary >= minimumDistance else { return false }
            return primary > secondary * dominanceRatio
        }
    }

    static func shouldBegin(velocity: CGPoint, direction: NavigationSwipeGestureDirection) -> Bool {
        switch direction {
        case .right:
            guard velocity.x > 0 else { return false }
            return velocity.x > abs(velocity.y) * dominanceRatio
        case .down:
            guard velocity.y > 0 else { return false }
            return velocity.y > abs(velocity.x) * dominanceRatio
        }
    }

    /// Whether a navigation/dismiss swipe may claim the pan given current scroll
    /// state. Disabled, hidden, and non-overflowing scroll views do not block.
    ///
    /// When `touchLocationInHost` is provided, only scroll views on the UIKit
    /// hit-test ancestry under the finger participate. Touches that miss every
    /// scroll view (chrome / empty chrome area) may claim immediately so an
    /// unrelated off-screen scrolled cell cannot veto navigation for the whole
    /// host.
    static func canClaimSwipe(
        direction: NavigationSwipeGestureDirection,
        scrollViews: [UIScrollView],
        touchLocationInHost: CGPoint? = nil,
        hostView: UIView? = nil
    ) -> Bool {
        let scoped = scopedScrollViews(
            scrollViews,
            touchLocationInHost: touchLocationInHost,
            hostView: hostView
        )
        // Touch missed every known scroll view (nav chrome, margins, empty areas).
        if touchLocationInHost != nil, hostView != nil, scoped.isEmpty {
            return true
        }

        let candidates = scoped.filter(isEligibleScrollView(_:))
        guard !candidates.isEmpty else { return true }

        switch direction {
        case .down:
            let vertical = candidates.filter(canScrollVertically(_:))
            guard !vertical.isEmpty else { return true }
            return vertical.allSatisfy(isAtTopScrollEdge(_:))
        case .right:
            let horizontal = candidates.filter(canScrollHorizontally(_:))
            guard !horizontal.isEmpty else { return true }
            return horizontal.allSatisfy(isAtLeadingScrollEdge(_:))
        }
    }

    /// Scroll views that should arbitrate a swipe at `touchLocationInHost`.
    ///
    /// Prefer the live hit-test chain so clipped, covered, or non-interactive
    /// descendants cannot veto a gesture the user is not actually touching.
    /// Falls back to geometric containment only when the host cannot hit-test
    /// (detached test hosts without a full responder tree).
    static func scopedScrollViews(
        _ scrollViews: [UIScrollView],
        touchLocationInHost: CGPoint?,
        hostView: UIView?
    ) -> [UIScrollView] {
        guard let touchLocationInHost, let hostView else { return scrollViews }

        if let hitView = hostView.hitTest(touchLocationInHost, with: nil) {
            let ancestry = scrollViewsOnAncestry(of: hitView)
            let known = Set(scrollViews.map { ObjectIdentifier($0) })
            let hitKnown = ancestry.filter { known.contains(ObjectIdentifier($0)) }
            if !hitKnown.isEmpty {
                return hitKnown
            }
            // Hit something outside every candidate scroll view (chrome).
            return []
        }

        // Detached/test hosts: geometric containment is the best available signal.
        return scrollViews.filter { scrollView in
            scrollView.convert(scrollView.bounds, to: hostView).contains(touchLocationInHost)
        }
    }

    static func scrollViewsOnAncestry(of view: UIView) -> [UIScrollView] {
        var matches: [UIScrollView] = []
        var current: UIView? = view
        while let node = current {
            if let scrollView = node as? UIScrollView {
                matches.append(scrollView)
            }
            current = node.superview
        }
        return matches
    }

    static func descendantScrollViews(in root: UIView) -> [UIScrollView] {
        var matches: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scrollView = view as? UIScrollView {
                matches.append(scrollView)
            }
            for child in view.subviews {
                walk(child)
            }
        }
        walk(root)
        return matches
    }

    static func isEligibleScrollView(_ scrollView: UIScrollView) -> Bool {
        guard scrollView.isScrollEnabled
            && scrollView.isUserInteractionEnabled
            && !scrollView.isHidden
            && scrollView.alpha > 0.01
            && scrollView.bounds.width > 0
            && scrollView.bounds.height > 0
        else { return false }

        // Ancestor visibility/interaction: a scrolled cell inside a hidden or
        // non-interactive container must not veto a gesture the user cannot touch.
        var ancestor: UIView? = scrollView.superview
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 || !view.isUserInteractionEnabled {
                return false
            }
            ancestor = view.superview
        }
        return true
    }

    static func canScrollVertically(_ scrollView: UIScrollView) -> Bool {
        let viewport = scrollView.bounds.height
            - scrollView.adjustedContentInset.top
            - scrollView.adjustedContentInset.bottom
        return scrollView.contentSize.height > viewport + scrollEdgeTolerance
    }

    static func canScrollHorizontally(_ scrollView: UIScrollView) -> Bool {
        let viewport = scrollView.bounds.width
            - scrollView.adjustedContentInset.left
            - scrollView.adjustedContentInset.right
        return scrollView.contentSize.width > viewport + scrollEdgeTolerance
    }

    static func isAtTopScrollEdge(_ scrollView: UIScrollView) -> Bool {
        scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + scrollEdgeTolerance
    }

    static func isAtLeadingScrollEdge(_ scrollView: UIScrollView) -> Bool {
        scrollView.contentOffset.x <= -scrollView.adjustedContentInset.left + scrollEdgeTolerance
    }
}

/// Shared policy for the app-wide horizontal back gesture.
///
/// Left-to-right swipes mean leaving the current pushed surface. Modal viewers
/// with down-chevron chrome must not install this horizontal recognizer.
///
/// Distance/velocity thresholds are shared with ``NavigationSwipeGesturePolicy``.
/// Scroll-edge gating lives on the UIKit installer path; pure SwiftUI
/// ``horizontalBackSwipeGesture`` hosts still only apply the translation gate.
enum HorizontalBackSwipeGesturePolicy {
    static let minimumHorizontalDistance = NavigationSwipeGesturePolicy.minimumDistance
    static let horizontalDominanceRatio = NavigationSwipeGesturePolicy.dominanceRatio

    static func isBackSwipe(translation: CGSize) -> Bool {
        NavigationSwipeGesturePolicy.isSwipe(translation: translation, direction: .right)
    }

    static func shouldBegin(velocity: CGPoint) -> Bool {
        NavigationSwipeGesturePolicy.shouldBegin(velocity: velocity, direction: .right)
    }
}

private struct HorizontalBackSwipeGestureModifier: ViewModifier {
    let isEnabled: Bool
    let onBack: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: HorizontalBackSwipeGesturePolicy.minimumHorizontalDistance)
                        .onEnded { value in
                            guard HorizontalBackSwipeGesturePolicy.isBackSwipe(translation: value.translation) else { return }
                            onBack()
                        }
                )
        } else {
            content
        }
    }
}

extension View {
    /// SwiftUI adapter for surfaces built from SwiftUI views.
    /// UIKit scroll views should use ``HorizontalBackSwipeGestureInstaller`` so
    /// the recognizer lives on the view that actually receives pan events.
    func horizontalBackSwipeGesture(
        isEnabled: Bool = true,
        _ onBack: @escaping () -> Void
    ) -> some View {
        modifier(HorizontalBackSwipeGestureModifier(isEnabled: isEnabled, onBack: onBack))
    }
}

private struct HorizontalBackSwipeActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
    /// Back action inherited by UIKit-backed SwiftUI renderers.
    ///
    /// Use this when a SwiftUI surface contains `UIViewRepresentable` scroll
    /// views: the parent keeps SwiftUI fallback handling, while the UIKit child
    /// installs the same recognizer on the actual scroll receiver.
    var horizontalBackSwipeAction: (@MainActor @Sendable () -> Void)? {
        get { self[HorizontalBackSwipeActionKey.self] }
        set { self[HorizontalBackSwipeActionKey.self] = newValue }
    }
}

/// Retains the UIKit recognizer/action bridge for `UIViewRepresentable` coordinators.
@MainActor
final class HorizontalBackSwipeActionCoordinator {
    private var action: (@MainActor @Sendable () -> Void)?
    private var installer: HorizontalBackSwipeGestureInstaller?

    func install(
        action: (@MainActor @Sendable () -> Void)?,
        on view: UIView
    ) {
        self.action = action
        guard action != nil else { return }
        if installer == nil {
            installer = HorizontalBackSwipeGestureInstaller { [weak self] in
                self?.action?()
            }
        }
        installer?.install(on: view)
    }
}

/// Pan recognizer that reports reset so navigation swipe hosts can drop stale
/// touch-scope state even when UIKit fails the gesture without an action callback.
private final class NavigationSwipePanGestureRecognizer: UIPanGestureRecognizer {
    var onReset: (() -> Void)?

    override func reset() {
        super.reset()
        onReset?()
    }
}

@MainActor
final class HorizontalBackSwipeGestureInstaller: NSObject, UIGestureRecognizerDelegate {
    private let onBack: @MainActor () -> Void
    private let direction: NavigationSwipeGestureDirection
    private let shouldReceiveTouch: (@MainActor (UITouch) -> Bool)?
    private weak var recognizer: UIPanGestureRecognizer?
    /// Last accepted touch location in the host, used to scope scroll-edge checks
    /// to the content under the finger rather than every descendant scroll view.
    private var activeTouchLocationInHost: CGPoint?

    init(
        onBack: @escaping @MainActor () -> Void,
        direction: NavigationSwipeGestureDirection = .right,
        shouldReceiveTouch: (@MainActor (UITouch) -> Bool)? = nil
    ) {
        self.onBack = onBack
        self.direction = direction
        self.shouldReceiveTouch = shouldReceiveTouch
        super.init()
    }

    func install(on view: UIView) {
        if recognizer?.view === view { return }
        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }

        let recognizer = NavigationSwipePanGestureRecognizer(
            target: self,
            action: #selector(handlePan(_:))
        )
        // One-finger only so pinch zoom / multi-touch pans cannot also dismiss.
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        // reset() is the reliable cleanup point: UIKit does not invoke the action
        // selector on .failed, and sequences that never leave .possible still reset.
        recognizer.onReset = { [weak self] in
            self?.activeTouchLocationInHost = nil
        }
        view.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .ended:
            let host = recognizer.view
            let translation = recognizer.translation(in: host)
            handleNavigationSwipeEnded(
                translation: CGSize(width: translation.x, height: translation.y),
                in: host,
                touchLocationInHost: activeTouchLocationInHost
            )
            activeTouchLocationInHost = nil
        case .cancelled, .failed:
            activeTouchLocationInHost = nil
        default:
            break
        }
    }

    /// Testable entry point for pan-ended dismiss/back handling.
    func handleNavigationSwipeEnded(
        translation: CGSize,
        in hostView: UIView?,
        touchLocationInHost: CGPoint? = nil
    ) {
        guard NavigationSwipeGesturePolicy.isSwipe(
            translation: translation,
            direction: direction
        ) else { return }
        // Re-check scroll edges on end so a pan that began at the edge but was
        // absorbed as document scrolling cannot dismiss mid-content.
        guard canClaimSwipe(in: hostView, touchLocationInHost: touchLocationInHost) else { return }
        onBack()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let allowed = shouldBeginNavigationSwipe(
            velocity: pan.velocity(in: pan.view),
            in: pan.view,
            touchLocationInHost: activeTouchLocationInHost
        )
        // UIKit does not invoke the action selector on .failed, so clear here when
        // we reject begin; otherwise the next gesture keeps a stale touch point.
        if !allowed {
            activeTouchLocationInHost = nil
        }
        return allowed
    }

    /// Testable entry point for should-begin policy (velocity + scroll edge).
    func shouldBeginNavigationSwipe(
        velocity: CGPoint,
        in hostView: UIView?,
        touchLocationInHost: CGPoint? = nil
    ) -> Bool {
        guard NavigationSwipeGesturePolicy.shouldBegin(
            velocity: velocity,
            direction: direction
        ) else { return false }
        return canClaimSwipe(in: hostView, touchLocationInHost: touchLocationInHost)
    }

    private func canClaimSwipe(
        in hostView: UIView?,
        touchLocationInHost: CGPoint?
    ) -> Bool {
        guard let hostView else { return true }
        return NavigationSwipeGesturePolicy.canClaimSwipe(
            direction: direction,
            scrollViews: NavigationSwipeGesturePolicy.descendantScrollViews(in: hostView),
            touchLocationInHost: touchLocationInHost,
            hostView: hostView
        )
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard shouldReceiveTouch?(touch) ?? true else { return false }
        // While still Possible, redefine scope on touch-down. A prior pan can fail
        // without invoking the action selector, so requiring `== nil` would leave a
        // stale point. After began/changed, keep the original finger location.
        if gestureRecognizer.state == .possible, let host = gestureRecognizer.view {
            activeTouchLocationInHost = touch.location(in: host)
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Coexist only with a scroll view's own pan recognizer. Selection-handle
        // pans, pinches, and other recognizers attached to UITextView/UIScrollView
        // stay exclusive so dismiss cannot fire as a side effect.
        if let scrollView = otherGestureRecognizer.view as? UIScrollView,
           otherGestureRecognizer === scrollView.panGestureRecognizer {
            return true
        }
        return false
    }

    #if DEBUG
    func setActiveTouchLocationForTesting(_ point: CGPoint?) {
        activeTouchLocationInHost = point
    }

    func activeTouchLocationForTesting() -> CGPoint? {
        activeTouchLocationInHost
    }
    #endif
}

@MainActor
enum FullScreenViewerNavigationChrome {
    enum DismissMode {
        case modal
        case embedded

        var systemImageName: String {
            switch self {
            case .modal:
                return "chevron.down"
            case .embedded:
                return "chevron.backward"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .modal:
                return String(localized: "Done")
            case .embedded:
                return String(localized: "Back")
            }
        }

        var gestureDirection: NavigationSwipeGestureDirection {
            switch self {
            case .modal:
                return .down
            case .embedded:
                return .right
            }
        }
    }

    static func makeDismissButton(
        mode: DismissMode,
        target: AnyObject,
        action: Selector,
        palette: ThemePalette,
        accessibilityIdentifier: String? = nil
    ) -> UIBarButtonItem {
        let button = UIBarButtonItem(
            image: UIImage(systemName: mode.systemImageName),
            style: .plain,
            target: target,
            action: action
        )
        button.tintColor = UIColor(palette.cyan)
        button.accessibilityLabel = mode.accessibilityLabel
        button.accessibilityIdentifier = accessibilityIdentifier
        return button
    }

    static func makeShareButton(
        for content: FileShareService.ShareableContent,
        palette: ThemePalette
    ) -> UIBarButtonItem {
        FileSharePresenter.makeShareBarButtonItem(
            for: content,
            tintColor: UIColor(palette.fgDim)
        )
    }
}

enum CodeWrapControl {
    static let symbolName = "text.alignleft"
}

enum FullScreenCodeTypography {
    static var codeFont: UIFont { AppFont.monoMedium }

    static func codeFont(for preferences: FullScreenReaderPreferences) -> UIFont {
        scaledFont(codeFont, scale: preferences.textScale)
    }

    static func scaledFont(_ font: UIFont, scale: CGFloat) -> UIFont {
        guard scale != 1 else { return font }
        let pointSize = min(40, max(8, font.pointSize * scale))
        return font.withSize(pointSize)
    }
}

@MainActor
protocol FullScreenReaderConfigurable: AnyObject {
    func applyReaderPreferences(_ preferences: FullScreenReaderPreferences)
}

func fullScreenAttributedCodeText(
    from attributed: NSAttributedString,
    font: UIFont = FullScreenCodeTypography.codeFont
) -> NSAttributedString {
    let mutable = NSMutableAttributedString(attributedString: attributed)
    let fullRange = NSRange(location: 0, length: mutable.length)
    mutable.addAttribute(.font, value: font, range: fullRange)
    return mutable
}

private final class FullScreenTextSelectionHighlightOverlayView: UIView {
    var rects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    var fillColor: UIColor = .systemBlue.withAlphaComponent(0.22) {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !rects.isEmpty else { return }
        context.setFillColor(fillColor.cgColor)
        for selectionRect in rects where selectionRect.intersects(rect) {
            let path = UIBezierPath(roundedRect: selectionRect, cornerRadius: 3)
            context.addPath(path.cgPath)
            context.fillPath()
        }
    }
}

final class FullScreenLineAnchorHighlightOverlayView: UIView {
    var rects: [CGRect] = [] {
        didSet { setNeedsDisplay() }
    }

    var fillColor: UIColor = .systemBlue.withAlphaComponent(0.18) {
        didSet { setNeedsDisplay() }
    }

    var strokeColor: UIColor = .systemBlue.withAlphaComponent(0.8) {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let firstRect = rects.first else { return }

        // A wrapped source line may produce several TextKit fragments. They
        // are still one logical anchor, so union every fragment before drawing
        // anything. This also keeps a rendered Markdown range to one enclosure
        // when its highlighted blocks are laid out in separate cells.
        let enclosureRect = rects.dropFirst().reduce(firstRect) { partial, next in
            partial.union(next)
        }
        guard enclosureRect.intersects(rect) else { return }

        let path = UIBezierPath(
            roundedRect: enclosureRect,
            cornerRadius: min(6, max(0, enclosureRect.height / 2))
        )
        context.setFillColor(fillColor.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(2)
        context.setLineJoin(.round)
        context.addPath(path.cgPath)
        context.strokePath()

    }
}

struct FullScreenLineAnchorLayoutResult {
    let visibleRects: [CGRect]
    let contentRects: [CGRect]
    let firstVisibleRect: CGRect?

    var firstContentRect: CGRect? { contentRects.first }
}

enum FullScreenLineAnchorLayout {
    static func layout(
        for textView: UITextView,
        sourceLineRange: ClosedRange<Int>,
        startLine: Int
    ) -> FullScreenLineAnchorLayoutResult {
        let source = textView.textStorage.string as NSString
        let lineRanges = SourceLineMetrics.logicalLineContentRanges(in: source)
        guard !lineRanges.isEmpty else {
            return FullScreenLineAnchorLayoutResult(
                visibleRects: [],
                contentRects: [],
                firstVisibleRect: nil
            )
        }

        let layoutManager = textView.layoutManager
        layoutManager.ensureLayout(for: textView.textContainer)
        let font = textView.font ?? FullScreenCodeTypography.codeFont
        let viewportWidth = max(
            1,
            textView.bounds.width - textView.textContainerInset.left - textView.textContainerInset.right
        )
        var contentRects: [CGRect] = []
        contentRects.reserveCapacity(sourceLineRange.count)
        var fallbackY = textView.textContainerInset.top

        for sourceLine in sourceLineRange {
            let localIndex = sourceLine - startLine
            guard lineRanges.indices.contains(localIndex) else { continue }
            let characterRange = lineRanges[localIndex]
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )

            var fragmentRects: [CGRect] = []
            if glyphRange.length > 0 {
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
                    guard NSIntersectionRange(glyphRange, lineGlyphRange).length > 0 else { return }
                    fragmentRects.append(usedRect)
                }
            } else if textView.textStorage.length > 0 {
                if characterRange.location < textView.textStorage.length {
                    let resolvedGlyphIndex = layoutManager.glyphIndexForCharacter(at: characterRange.location)
                    if resolvedGlyphIndex < layoutManager.numberOfGlyphs {
                        fragmentRects.append(
                            layoutManager.lineFragmentRect(forGlyphAt: resolvedGlyphIndex, effectiveRange: nil)
                        )
                    }
                } else if layoutManager.numberOfGlyphs > 0 {
                    let lastGlyphRect = layoutManager.lineFragmentRect(
                        forGlyphAt: layoutManager.numberOfGlyphs - 1,
                        effectiveRange: nil
                    )
                    fragmentRects.append(CGRect(
                        x: 0,
                        y: lastGlyphRect.maxY,
                        width: viewportWidth,
                        height: font.lineHeight
                    ))
                }
            }

            if fragmentRects.isEmpty {
                fragmentRects = [CGRect(
                    x: 0,
                    y: max(0, fallbackY - textView.textContainerInset.top),
                    width: viewportWidth,
                    height: font.lineHeight
                )]
            }

            for fragmentRect in fragmentRects {
                var contentRect = fragmentRect
                contentRect.origin.x += textView.textContainerInset.left
                contentRect.origin.y += textView.textContainerInset.top
                contentRect.size.width = max(contentRect.width, viewportWidth)
                contentRect.size.height = max(contentRect.height, font.lineHeight)
                contentRects.append(contentRect.integral)
                fallbackY = max(fallbackY, contentRect.maxY)
            }
        }

        let firstVisibleRect = contentRects.first?.offsetBy(
            dx: -textView.contentOffset.x,
            dy: -textView.contentOffset.y
        ).integral
        let visibleRects: [CGRect]
        if var enclosureRect = contentRects.first {
            for contentRect in contentRects.dropFirst() {
                enclosureRect = enclosureRect.union(contentRect)
            }
            visibleRects = [enclosureRect.offsetBy(
                dx: -textView.contentOffset.x,
                dy: -textView.contentOffset.y
            ).integral]
        } else {
            visibleRects = []
        }
        return FullScreenLineAnchorLayoutResult(
            visibleRects: visibleRects,
            contentRects: contentRects,
            firstVisibleRect: firstVisibleRect
        )
    }

}

/// Clipboard writes for full-screen copy actions.
///
/// Unit tests replace ``testWriteOverride`` so they never touch
/// `UIPasteboard.general`. Reading or writing the system pasteboard can hang
/// the simulator pasteboardd / paste-permission prompt on the test main thread.
@MainActor
enum FullScreenCopyDestination {
    #if DEBUG
    static var testWriteOverride: ((String) -> Void)?
    #endif

    static func write(_ text: String) {
        #if DEBUG
        if let testWriteOverride {
            testWriteOverride(text)
            return
        }
        #endif
        UIPasteboard.general.string = text
    }
}

/// UITextView variant that carries review-comment routing context.
///
/// The owning `UITextViewDelegate` builds the menu when UIKit asks for it.
/// Some read-only full-screen selections never get that callback, so this view
/// also owns a fallback `UIEditMenuInteraction`; the fallback stands down when
/// the native delegate has already built the menu for the current selection.
final class FullScreenReviewCommentTextView: UITextView {
#if DEBUG
    static var forcesReviewSelectionTipForTesting = false
#endif

    var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    var reviewCommentSourceContext: ReviewCommentSourceContext?

    private static let reviewSelectionTipTopPadding: CGFloat = 10
    private static let reviewSelectionTipHorizontalPadding: CGFloat = 12
    private static let reviewSelectionTipReservedHeight = FeatureEducationTipBannerView.preferredHeight + 18

    private let selectionHighlightOverlay = FullScreenTextSelectionHighlightOverlayView()
    private let lineAnchorHighlightOverlay = FullScreenLineAnchorHighlightOverlayView()
    private var lineAnchorFocusRect: CGRect?
    private let reviewSelectionTipPresentationOwnerID = UUID()
    private var reviewSelectionTipView: FeatureEducationTipBannerView?
    private var reviewSelectionTipBaseTextContainerInset: UIEdgeInsets?
    private lazy var reviewCommentEditMenuInteraction = UIEditMenuInteraction(delegate: self)
    private var pendingEditMenuPresentation = false
    private var currentEditMenuTargetRect: CGRect?
    private var observedSelectedRange = NSRange(location: NSNotFound, length: 0)
    private var selectionGeneration = 0
    private var nativeTextViewEditMenuGeneration: Int?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addInteraction(reviewCommentEditMenuInteraction)
        installLineAnchorHighlightOverlay()
        installSelectionHighlightOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var selectedRange: NSRange {
        get { super.selectedRange }
        set {
            super.selectedRange = newValue
            noteSelectionRangeDidMaybeChange()
            updateSelectionHighlightOverlay()
            scheduleReviewCommentEditMenuPresentation()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        lineAnchorHighlightOverlay.frame = bounds
        updateSelectionHighlightOverlay()
    }

#if DEBUG
    var debugLineAnchorHighlightRectCountForTesting: Int {
        lineAnchorHighlightOverlay.rects.isEmpty ? 0 : 1
    }

    var debugLineAnchorFirstHighlightRectForTesting: CGRect? {
        lineAnchorFocusRect ?? lineAnchorHighlightOverlay.rects.first
    }

    var debugLineAnchorHighlightEnclosureRectForTesting: CGRect? {
        lineAnchorHighlightOverlay.rects.first
    }

    var debugLineAnchorHighlightContainsFirstTargetForTesting: Bool {
        guard let enclosure = lineAnchorHighlightOverlay.rects.first,
              let firstTarget = lineAnchorFocusRect,
              enclosure.width > 0,
              enclosure.height > 0 else {
            return false
        }
        return enclosure.insetBy(dx: -1, dy: -1).contains(firstTarget)
    }

    var debugLineAnchorHighlightHasVisibleGeometryForTesting: Bool {
        guard debugLineAnchorHighlightContainsFirstTargetForTesting,
              let rect = lineAnchorHighlightOverlay.rects.first,
              !rect.intersection(bounds).isEmpty else {
            return false
        }
        return true
    }
#endif

    func setLineAnchorHighlight(
        rects: [CGRect],
        firstRect: CGRect? = nil,
        fillColor: UIColor,
        strokeColor: UIColor
    ) {
        lineAnchorHighlightOverlay.frame = bounds
        lineAnchorHighlightOverlay.fillColor = fillColor
        lineAnchorHighlightOverlay.strokeColor = strokeColor
        lineAnchorFocusRect = firstRect
        lineAnchorHighlightOverlay.rects = rects
    }

    func reviewCommentSelectionDidChange() {
        noteSelectionRangeDidMaybeChange()
        updateSelectionHighlightOverlay()
        scheduleReviewCommentEditMenuPresentation()
    }

    func noteNativeTextViewEditMenuRequest(for range: NSRange) {
        noteSelectionRangeDidMaybeChange()
        guard NSEqualRanges(range, selectedRange) else { return }
        nativeTextViewEditMenuGeneration = selectionGeneration
    }

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
        presentReviewCommentSelectionTipIfNeeded()
        scheduleReviewCommentEditMenuPresentation()
    }

    private func presentReviewCommentSelectionTipIfNeeded() {
        guard reviewCommentSelectionRouter != nil, reviewCommentSourceContext != nil else {
            clearReviewCommentSelectionTip()
            return
        }
        let tip = FeatureEducationTips.ReviewCommentSelectionTip()
#if DEBUG
        let forceTip = ProcessInfo.processInfo.arguments.contains("--show-feature-tips-for-testing")
            || Self.forcesReviewSelectionTipForTesting
#else
        let forceTip = false
#endif
        guard tip.shouldDisplay || forceTip else {
            clearReviewCommentSelectionTip()
            return
        }
        guard reviewSelectionTipView == nil else { return }
        guard FeatureEducationTipPresentationCoordinator.shared.claim(
            tipID: FeatureEducationTips.reviewCommentSelection.id,
            ownerID: reviewSelectionTipPresentationOwnerID,
            force: forceTip
        ) else { return }

        reserveSpaceForReviewCommentSelectionTip()

        let tipView = FeatureEducationTipBannerView()
        tipView.configure(descriptor: FeatureEducationTips.reviewCommentSelection) { [weak self] in
            tip.invalidate(reason: .tipClosed)
            self?.clearReviewCommentSelectionTip()
        }
        tipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tipView)
        reviewSelectionTipView = tipView
        NSLayoutConstraint.activate([
            tipView.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor, constant: Self.reviewSelectionTipHorizontalPadding),
            tipView.trailingAnchor.constraint(equalTo: frameLayoutGuide.trailingAnchor, constant: -Self.reviewSelectionTipHorizontalPadding),
            tipView.topAnchor.constraint(equalTo: frameLayoutGuide.topAnchor, constant: Self.reviewSelectionTipTopPadding),
            tipView.heightAnchor.constraint(equalToConstant: FeatureEducationTipBannerView.preferredHeight),
        ])
        bringSubviewToFront(tipView)
    }

    func dismissReviewCommentSelectionTip() {
        clearReviewCommentSelectionTip()
    }

    private func clearReviewCommentSelectionTip() {
        guard reviewSelectionTipView != nil else { return }
        reviewSelectionTipView?.removeFromSuperview()
        reviewSelectionTipView = nil
        restoreSpaceReservedForReviewCommentSelectionTip()
        FeatureEducationTipPresentationCoordinator.shared.release(
            tipID: FeatureEducationTips.reviewCommentSelection.id,
            ownerID: reviewSelectionTipPresentationOwnerID
        )
    }

    private func reserveSpaceForReviewCommentSelectionTip() {
        guard reviewSelectionTipBaseTextContainerInset == nil else { return }
        let baseInset = textContainerInset
        reviewSelectionTipBaseTextContainerInset = baseInset
        textContainerInset = UIEdgeInsets(
            top: baseInset.top + Self.reviewSelectionTipReservedHeight,
            left: baseInset.left,
            bottom: baseInset.bottom,
            right: baseInset.right
        )
    }

    private func restoreSpaceReservedForReviewCommentSelectionTip() {
        guard let baseInset = reviewSelectionTipBaseTextContainerInset else { return }
        reviewSelectionTipBaseTextContainerInset = nil
        textContainerInset = baseInset
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            reviewCommentEditMenuInteraction.dismissMenu()
            clearReviewCommentSelectionTip()
        } else {
            presentReviewCommentSelectionTipIfNeeded()
            scheduleReviewCommentEditMenuPresentation()
        }
    }

    func setAttributedTextPreservingSelection(_ attributedText: NSAttributedString) {
        let selection = selectedRange
        let shouldRestoreSelection = selection.location != NSNotFound
            && selection.length > 0
            && NSMaxRange(selection) <= attributedText.length
        let wasFirstResponder = isFirstResponder

        self.attributedText = attributedText

        if shouldRestoreSelection {
            selectedRange = selection
            if wasFirstResponder {
                becomeFirstResponder()
            }
        }
        updateSelectionHighlightOverlay()
    }

    private func installLineAnchorHighlightOverlay() {
        lineAnchorHighlightOverlay.isUserInteractionEnabled = false
        lineAnchorHighlightOverlay.backgroundColor = .clear
        lineAnchorHighlightOverlay.isOpaque = false
        insertSubview(lineAnchorHighlightOverlay, at: 0)
    }

    private func installSelectionHighlightOverlay() {
        selectionHighlightOverlay.isUserInteractionEnabled = false
        selectionHighlightOverlay.backgroundColor = .clear
        selectionHighlightOverlay.isOpaque = false
        addSubview(selectionHighlightOverlay)
    }

    private func updateSelectionHighlightOverlay() {
        bringSubviewToFront(lineAnchorHighlightOverlay)
        bringSubviewToFront(selectionHighlightOverlay)
        if let reviewSelectionTipView {
            bringSubviewToFront(reviewSelectionTipView)
        }
        selectionHighlightOverlay.frame = bounds
        selectionHighlightOverlay.fillColor = tintColor.withAlphaComponent(0.30)
        selectionHighlightOverlay.rects = selectionHighlightRects(for: selectedRange)
    }

    private func selectionHighlightRects(for range: NSRange) -> [CGRect] {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        let selectedGlyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard selectedGlyphRange.location != NSNotFound, selectedGlyphRange.length > 0 else { return [] }

        var rects: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: selectedGlyphRange) { _, _, _, lineGlyphRange, _ in
            let glyphRange = NSIntersectionRange(selectedGlyphRange, lineGlyphRange)
            guard glyphRange.length > 0 else { return }
            var rect = self.layoutManager.boundingRect(forGlyphRange: glyphRange, in: self.textContainer)
            rect.origin.x += self.textContainerInset.left - self.contentOffset.x - 2
            rect.origin.y += self.textContainerInset.top - self.contentOffset.y
            rect.size.width += 4
            rect.size.height = max(rect.height, self.font?.lineHeight ?? rect.height)
            rects.append(rect.integral)
        }
        return rects
    }

    private func noteSelectionRangeDidMaybeChange() {
        let range = selectedRange
        guard !NSEqualRanges(range, observedSelectedRange) else { return }
        observedSelectedRange = range
        selectionGeneration &+= 1
        nativeTextViewEditMenuGeneration = nil
    }

    private func scheduleReviewCommentEditMenuPresentation() {
        guard !pendingEditMenuPresentation else { return }
        pendingEditMenuPresentation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            pendingEditMenuPresentation = false
            presentReviewCommentEditMenuIfNeeded()
        }
    }

    private func presentReviewCommentEditMenuIfNeeded() {
        noteSelectionRangeDidMaybeChange()
        guard nativeTextViewEditMenuGeneration != selectionGeneration else { return }
        // Present for any non-empty selection. Requiring a review-comment router hid the
        // system Copy menu on File-tab / non-chat code surfaces (UITextView nil = no menu).
        // Use raw range length so whitespace-only selections still get Copy.
        let hasRawSelection = selectedRange.location != NSNotFound
            && selectedRange.length > 0
            && NSMaxRange(selectedRange) <= (attributedText?.string ?? text ?? "" as String).utf16.count
        guard window != nil, hasRawSelection else {
            currentEditMenuTargetRect = nil
            reviewCommentEditMenuInteraction.dismissMenu()
            return
        }

        if !isFirstResponder {
            becomeFirstResponder()
        }

        let targetRect = selectionAnchorRect(for: selectedRange)
            ?? CGRect(x: bounds.midX, y: min(bounds.midY, bounds.minY + 180), width: 1, height: 1)
        currentEditMenuTargetRect = targetRect.integral
        reviewCommentEditMenuInteraction.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: "review-comment-selection" as NSString,
            sourcePoint: CGPoint(x: targetRect.midX, y: targetRect.minY)
        ))
    }

#if DEBUG
    func shouldPresentFallbackEditMenuForTesting() -> Bool {
        noteSelectionRangeDidMaybeChange()
        return nativeTextViewEditMenuGeneration != selectionGeneration
    }

    func fallbackEditMenuForTesting(suggestedActions: [UIMenuElement]) -> UIMenu? {
        makeFallbackEditMenu(suggestedActions: suggestedActions)
    }
#endif

    fileprivate func makeFallbackEditMenu(
        suggestedActions: [UIMenuElement],
        range: NSRange? = nil
    ) -> UIMenu? {
        // Prefer the explicit edit-menu range from UITextViewDelegate; selectedRange may
        // still be empty when tests or UIKit query the menu before committing selection.
        let effectiveRange = range ?? selectedRange
        guard effectiveRange.location != NSNotFound,
              effectiveRange.length > 0 else {
            return nil
        }

        let fullText = attributedText?.string ?? text ?? ""
        let nsText = fullText as NSString
        guard NSMaxRange(effectiveRange) <= nsText.length else { return nil }
        // Copy must use the raw substring so indentation/trailing whitespace survive.
        // Comment payloads still go through the normalized selected-text helper below.
        let rawSelectedText = nsText.substring(with: effectiveRange)
        let actions = Self.suggestedActionsEnsuringCopy(
            suggestedActions,
            rawSelectedText: rawSelectedText
        )

        if let router = reviewCommentSelectionRouter,
           let sourceContext = reviewCommentSourceContext,
           let commentText = ReviewCommentSelectionTextViewSupport.selectedText(
            in: self,
            range: effectiveRange
           ) {
            return ReviewCommentSelectionMenuBuilder.editMenu(
                suggestedActions: actions,
                selectedText: commentText,
                sourceContext: ReviewCommentSelectionEditMenuSupport.enrichedSourceContext(
                    sourceContext,
                    textView: self,
                    range: effectiveRange
                ),
                router: router,
                presentingViewController: nearestViewController(from: self),
                textView: self,
                selectedRange: effectiveRange
            )
        }

        // UITextView treats a nil return as no menu — always keep at least Copy.
        return UIMenu(children: actions)
    }

    private static let synthesizedCopyActionIdentifier = UIAction.Identifier("oppi.fullscreen-code.copy")

    private static func suggestedActionsEnsuringCopy(
        _ suggestedActions: [UIMenuElement],
        rawSelectedText: String
    ) -> [UIMenuElement] {
        let localizedCopyTitle = String(localized: "Copy")
        let alreadyHasCopy = suggestedActions.contains { element in
            guard let action = element as? UIAction else { return false }
            if action.identifier == synthesizedCopyActionIdentifier { return true }
            // UIKit/system and Oppi menus both surface Copy via localized title.
            return action.title == localizedCopyTitle || action.title == "Copy"
        }
        guard !alreadyHasCopy else { return suggestedActions }

        let copyAction = UIAction(
            title: localizedCopyTitle,
            image: UIImage(systemName: "doc.on.doc"),
            identifier: synthesizedCopyActionIdentifier
        ) { _ in
            FullScreenCopyDestination.write(rawSelectedText)
        }
        return [copyAction] + suggestedActions
    }

    private func selectionAnchorRect(for range: NSRange) -> CGRect? {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= textStorage.length else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }

        var rect: CGRect?
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, _, stop in
            rect = usedRect
            stop.pointee = true
        }

        guard var anchor = rect else { return nil }
        anchor.origin.x += textContainerInset.left
        anchor.origin.y += textContainerInset.top
        anchor = anchor.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
        return anchor.integral
    }
}

extension FullScreenReviewCommentTextView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        makeFallbackEditMenu(suggestedActions: suggestedActions)
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
        currentEditMenuTargetRect ?? .null
    }
}

@MainActor
func buildFullScreenReviewCommentMenu(
    textView: UITextView,
    range: NSRange,
    suggestedActions: [UIMenuElement],
    router: ReviewCommentSelectionRouter?,
    sourceContext: ReviewCommentSourceContext?
) -> UIMenu? {
    // Always mark the native request so the fallback interaction stands down for this
    // selection generation, whether we return Comment+actions or system actions only.
    (textView as? FullScreenReviewCommentTextView)?.noteNativeTextViewEditMenuRequest(for: range)

    // One construction path for full-screen code text views so native delegate and
    // UIEditMenuInteraction fallback cannot diverge on Copy synthesis.
    // Router/sourceContext come from configureReviewCommentSelection on the text view
    // (set by NativeFullScreenCodeBody / full-screen controllers). Explicit params remain
    // for non-full-screen UITextView call sites below.
    if let fullScreenTextView = textView as? FullScreenReviewCommentTextView {
        return fullScreenTextView.makeFallbackEditMenu(
            suggestedActions: suggestedActions,
            range: range
        )
    }

    if let menu = ReviewCommentSelectionEditMenuSupport.buildMenu(
        textView: textView,
        range: range,
        suggestedActions: suggestedActions,
        router: router,
        sourceContext: sourceContext,
        presentingViewController: nearestViewController(from: textView)
    ) {
        return menu
    }

    // UITextView: nil means "no menu", not "use defaults". Preserve system actions.
    guard !suggestedActions.isEmpty else { return nil }
    return UIMenu(children: suggestedActions)
}

@MainActor
private func nearestViewController(from responder: UIResponder) -> UIViewController? {
    var current: UIResponder? = responder
    while let node = current {
        if let controller = node as? UIViewController {
            return controller
        }
        current = node.next
    }
    return nil
}

@MainActor
final class TailFollowScrollCoordinator {
    private let scrollView: UIScrollView
    private let nearBottomThreshold: CGFloat
    private let performLayout: () -> Void

    private(set) var isApplyingProgrammaticScroll = false
    var shouldAutoFollowTail: Bool
    private var pendingAutoFollowScroll = false

    init(
        scrollView: UIScrollView,
        shouldAutoFollowTail: Bool,
        nearBottomThreshold: CGFloat = 28,
        performLayout: @escaping () -> Void
    ) {
        self.scrollView = scrollView
        self.shouldAutoFollowTail = shouldAutoFollowTail
        self.nearBottomThreshold = nearBottomThreshold
        self.performLayout = performLayout
    }

    func onLayoutPass() {
        scheduleAutoFollowToBottomIfNeeded()
    }

    func scheduleAutoFollowToBottomIfNeeded() {
        guard shouldAutoFollowTail else { return }
        guard !pendingAutoFollowScroll else { return }
        pendingAutoFollowScroll = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingAutoFollowScroll = false
            guard self.shouldAutoFollowTail else { return }
            self.scrollToBottomIfNeeded()
        }
    }

    func handleWillBeginDragging() {
        // The user's gesture owns the viewport immediately, even when it starts
        // at the bottom. A Mermaid/LaTeX height reconciliation may already have
        // queued a tail-follow block before UIKit delivers the first didScroll.
        // Drag-end handling re-enables following when the user stays at bottom.
        shouldAutoFollowTail = false
    }

    func handleDidScroll(isUserDriven: Bool, isStreaming: Bool) {
        guard !isApplyingProgrammaticScroll else { return }
        guard isUserDriven else { return }

        // Never re-arm while a finger or deceleration still owns the viewport.
        // Drag/deceleration end callbacks re-enable following if the user chose
        // to settle at the bottom of a live stream.
        if !isStreaming || !isNearBottom() {
            shouldAutoFollowTail = false
        }
    }

    func handleDidEndDragging(willDecelerate: Bool, isStreaming: Bool) {
        guard !willDecelerate else { return }
        if isNearBottom() {
            shouldAutoFollowTail = isStreaming
        }
    }

    func handleDidEndDecelerating(isStreaming: Bool) {
        if isNearBottom() {
            shouldAutoFollowTail = isStreaming
        }
    }

    private func scrollToBottomIfNeeded() {
        guard scrollView.bounds.height > 0 else { return }

        performLayout()

        let targetY = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        guard targetY.isFinite else { return }
        guard abs(scrollView.contentOffset.y - targetY) > 0.5 else { return }

        isApplyingProgrammaticScroll = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        CATransaction.commit()
        isApplyingProgrammaticScroll = false
    }

    private func isNearBottom() -> Bool {
        distanceFromBottom() <= nearBottomThreshold
    }

    private func distanceFromBottom() -> CGFloat {
        let viewportHeight = scrollView.bounds.height
            - scrollView.adjustedContentInset.top
            - scrollView.adjustedContentInset.bottom
        guard viewportHeight > 0 else { return .greatestFiniteMagnitude }

        let visibleBottom = scrollView.contentOffset.y
            + scrollView.adjustedContentInset.top
            + viewportHeight

        return scrollView.contentSize.height - visibleBottom
    }
}
