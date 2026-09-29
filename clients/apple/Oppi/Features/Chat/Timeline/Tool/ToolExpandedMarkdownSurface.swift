import UIKit

/// Owns the expanded Markdown viewport of a tool timeline row.
///
/// A tool row shows Markdown in one of two forms. While the tool streams, the
/// incremental `AssistantMarkdownContentView` is the host's active view and the
/// row's expanded scroll view scrolls it inside a fixed-height viewport. When
/// the tool completes, an immutable `NativeFullScreenMarkdownBody` replaces it
/// inside a container the surface also owns, and the reader position carries
/// across the swap.
///
/// The surface keeps that lifecycle in one place: both views and their width
/// and height constraints, the theme and geometry signatures that mark a
/// mounted viewport stale, the live tail-follow policy, and teardown.
/// `ToolTimelineRowContentView` keeps header and collapsed presentation,
/// gestures, and the choice of which expanded surface is active. It mounts
/// `mountedView` through `ToolExpandedSurfaceHostView` and forwards layout and
/// scroll events to the methods below. The timeline stays the outer
/// vertical-scroll authority; the surface only reads and positions the row's
/// expanded scroll view for its own follow-tail and completion hand-off.
@MainActor
final class ToolExpandedMarkdownSurface {
    /// What one row apply cycle asks the surface to show.
    struct Input {
        let itemID: String
        let text: String
        let isStreaming: Bool
        let textSelectionEnabled: Bool
        let reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
        let reviewCommentSourceContext: ReviewCommentSourceContext?
        let resourceAccess: MarkdownResourceAccess
        let sourceFilePath: String?
        let resourcePressure: StreamingRenderPolicy.ResourcePressure
        /// Row-level tail-follow flag before this apply. Seeds the reader
        /// position handed across when a live viewport completes.
        let viewportFollowsTail: Bool
        /// Live-follow bookkeeping for this tick: whether a Markdown viewport
        /// was already showing, the text it rendered, and whether the strategy
        /// re-rendered.
        let wasVisible: Bool
        let previousText: String?
        let shouldRerender: Bool
    }

    enum Outcome {
        /// The incremental viewport took the new text.
        case liveUpdated
        /// A new immutable reader was built and mounted.
        case completedInstalled
        /// The mounted reader already shows this text in this theme.
        case completedUnchanged
    }

    enum Retirement {
        /// The row collapsed. The same document can come back, so the live
        /// viewport keeps its parsed content.
        case collapsed
        /// Another surface took over the expanded viewport; parsed content goes.
        case replaced
    }

    /// Incremental viewport, the host's active view while the tool streams.
    let liveView = AssistantMarkdownContentView()
    /// Holds the immutable reader once the tool is done.
    let completedContainer = UIView()
    private(set) var completedBody: NativeFullScreenMarkdownBody?
    /// Text `completedBody` was built from.
    private var completedText: String?

    /// Theme captured by the mounted viewport; nil while none is installed.
    private(set) var themeID: ThemeID?
    /// Whether the most recent install was the live, incremental viewport.
    /// Retirement does not clear it, so a completed install after any
    /// retirement still asks the outer viewport for a hand-off position, as the
    /// row did before this state moved here.
    private(set) var usesIncrementalViewport = false
    private var isMounted = false
    private var lastContainerWidth: CGFloat?
    private var lastViewportHeight: CGFloat?
    private var liveFollow = LiveStreamingPresentation.ViewportPolicy(followsTail: true)

    private let viewport: UIScrollView
    private var completedWidthConstraint: NSLayoutConstraint?
    private var completedHeightConstraint: NSLayoutConstraint?

    init(viewport: UIScrollView) {
        self.viewport = viewport
        liveView.translatesAutoresizingMaskIntoConstraints = false
        liveView.backgroundColor = .clear
        liveView.isHidden = true
        completedContainer.translatesAutoresizingMaskIntoConstraints = false
        completedContainer.backgroundColor = .clear
        completedContainer.isHidden = true
    }

    /// Adds both views to `host` and pins their widths to the viewport frame.
    /// Call once the host is inside the viewport's hierarchy.
    func mount(in host: ToolExpandedSurfaceHostView) {
        host.prepareSurfaceView(liveView)
        host.prepareSurfaceView(completedContainer)

        let liveWidth = liveView.widthAnchor.constraint(
            equalTo: viewport.frameLayoutGuide.widthAnchor,
            constant: -12
        )
        let completedWidth = completedContainer.widthAnchor.constraint(
            equalTo: viewport.frameLayoutGuide.widthAnchor,
            constant: 0
        )
        // During the first self-sizing pass the frame layout guide can report
        // width 0. Staying below required lets fitting supply a temporary
        // width instead of measuring at 0px.
        liveWidth.priority = .defaultHigh
        completedWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([liveWidth, completedWidth])
        completedWidthConstraint = completedWidth
    }

    // MARK: - Mounting

    /// The view the host should activate for the current install.
    var mountedView: UIView {
        usesIncrementalViewport ? liveView : completedContainer
    }

    /// Host insets for `mountedView`; nil selects the host default.
    var mountInsets: NSDirectionalEdgeInsets? {
        usesIncrementalViewport ? nil : .zero
    }

    /// Call after the host activated `mountedView`.
    func didActivate() {
        isMounted = true
        liveView.isHidden = !usesIncrementalViewport
        completedContainer.isHidden = usesIncrementalViewport
        updateCompletedWidthPriority()
    }

    /// The live incremental viewport is the active surface.
    var isLiveLayoutActive: Bool {
        isMounted && usesIncrementalViewport
    }

    /// Either Markdown viewport is installed.
    var isViewportActive: Bool {
        isLiveLayoutActive || completedBody != nil
    }

    /// Mounted view the row scrolls to the tail while following; nil when the
    /// surface is not active.
    var followTailTarget: UIView? {
        guard isMounted else { return nil }
        return usesIncrementalViewport ? liveView : completedContainer
    }

    /// The captured theme no longer matches the runtime theme.
    var isThemeStale: Bool {
        themeID != ThemeRuntimeState.currentThemeID()
    }

    var followsTail: Bool {
        liveFollow.followsTail
    }

    // MARK: - Install / update

    @discardableResult
    func apply(_ input: Input) -> Outcome {
        let themeID = ThemeRuntimeState.currentThemeID()
        // Capture before the mode flag flips: a completed install that replaces
        // a live viewport carries the reader position across.
        let handoffIntent = (!input.isStreaming && usesIncrementalViewport)
            ? FullScreenMarkdownViewportIntent.capturing(
                scrollView: viewport,
                followsTail: input.viewportFollowsTail
            )
            : nil
        usesIncrementalViewport = input.isStreaming

        _ = liveFollow.applyStreamTick(
            isStreaming: input.isStreaming,
            shouldRerender: input.shouldRerender,
            wasVisible: input.wasVisible,
            previousText: input.previousText,
            currentText: input.text
        )

        if input.isStreaming {
            removeCompletedViewport()
            self.themeID = themeID
            liveView.accessibilityIdentifier = Self.accessibilityIdentifier(itemID: input.itemID)
            liveView.apply(configuration: .make(
                content: input.text,
                isStreaming: true,
                themeID: themeID,
                textSelectionEnabled: input.textSelectionEnabled,
                reviewCommentSelectionRouter: input.reviewCommentSelectionRouter,
                reviewCommentSourceContext: input.reviewCommentSourceContext,
                resourceAccess: input.resourceAccess,
                sourceFilePath: input.sourceFilePath,
                perfSurface: .toolExpanded,
                renderingMode: .live,
                resourcePressure: input.resourcePressure
            ))
            liveView.setNeedsLayout()
            return .liveUpdated
        }

        liveView.clearContent()
        if self.themeID == themeID, completedText == input.text, completedBody != nil {
            return .completedUnchanged
        }
        removeCompletedViewport()
        let body = NativeFullScreenMarkdownBody(
            content: input.text,
            themeID: themeID,
            palette: themeID.palette,
            reviewCommentSelectionRouter: input.reviewCommentSelectionRouter,
            reviewCommentSourceContext: input.reviewCommentSourceContext,
            textSelectionEnabled: input.textSelectionEnabled,
            resourceAccess: input.resourceAccess,
            sourceFilePath: input.sourceFilePath,
            readerPreferences: FullScreenReaderContentFamily.markdown.defaultPreferences,
            perfSurface: .toolExpanded,
            allowsVerticalBounce: false,
            allowsVerticalScrolling: false
        )
        self.themeID = themeID
        body.accessibilityIdentifier = Self.accessibilityIdentifier(itemID: input.itemID)
        body.translatesAutoresizingMaskIntoConstraints = false
        completedContainer.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: completedContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: completedContainer.trailingAnchor),
            body.topAnchor.constraint(equalTo: completedContainer.topAnchor),
            body.bottomAnchor.constraint(equalTo: completedContainer.bottomAnchor),
        ])
        completedBody = body
        completedText = input.text

        // Pin the reader frame to the capped viewport; systemLayoutSizeFitting
        // would otherwise report the full document height.
        let heightConstraint = completedContainer.heightAnchor.constraint(
            equalTo: viewport.frameLayoutGuide.heightAnchor
        )
        heightConstraint.priority = .required
        heightConstraint.isActive = true
        completedHeightConstraint = heightConstraint

        if let handoffIntent {
            body.restoreViewportAfterMutableTransition(handoffIntent)
        }
        body.setNeedsLayout()
        return .completedInstalled
    }

    // MARK: - Teardown

    /// Leaves the expanded viewport. Dropping the completed reader releases it
    /// and its render tasks.
    func retire(_ retirement: Retirement) {
        liveView.isHidden = true
        completedContainer.isHidden = true
        isMounted = false
        removeCompletedViewport()
        switch retirement {
        case .collapsed:
            liveFollow = LiveStreamingPresentation.ViewportPolicy(followsTail: true)
        case .replaced:
            // Stale content would keep contributing intrinsic size.
            liveView.clearContent()
        }
    }

    private func removeCompletedViewport() {
        completedHeightConstraint?.isActive = false
        completedHeightConstraint = nil
        themeID = nil
        completedText = nil
        lastContainerWidth = nil
        lastViewportHeight = nil
        completedBody?.removeFromSuperview()
        completedBody = nil
    }

    // MARK: - Layout

    /// Completed readers pin their container to the viewport frame width once
    /// it is known; before that the pin stays soft.
    func updateCompletedWidthPriority() {
        if isMounted, !usesIncrementalViewport, viewport.bounds.width > 1 {
            completedWidthConstraint?.priority = .required
        } else {
            completedWidthConstraint?.priority = .defaultHigh
        }
    }

    /// Tracks the mounted viewport's width. Returns true when it changed
    /// enough that the timeline must measure the row once more.
    func refreshWidthSignature(policyOwnsViewport: Bool) -> Bool {
        guard policyOwnsViewport, isViewportActive else {
            lastContainerWidth = nil
            return false
        }
        let width = isLiveLayoutActive ? liveView.bounds.width : completedContainer.bounds.width
        guard width > 0 else { return false }
        defer { lastContainerWidth = width }
        // Content stays inside a fixed-height viewport, but a width change can
        // alter wrapping and the outer cell's geometry.
        return lastContainerWidth.map { abs($0 - width) > 0.5 } ?? false
    }

    /// Tracks the viewport height the row published. Returns true when it
    /// changed enough that the timeline must measure the row once more.
    func recordViewportHeight(_ height: CGFloat, policyOwnsViewport: Bool) -> Bool {
        guard policyOwnsViewport, isViewportActive else {
            lastViewportHeight = nil
            return false
        }
        defer { lastViewportHeight = height }
        // The fixed streaming height can still change when the available
        // geometry changes. That is an outer geometry transition, not content churn.
        return lastViewportHeight.map { abs($0 - height) > 0.5 } ?? false
    }

    // MARK: - Live follow

    func viewportInteractionBegan() {
        _ = liveFollow.handle(.interactionBegan)
    }

    /// Returns true when the live viewport should resume following the tail.
    func viewportInteractionEnded(isStreaming: Bool) -> Bool {
        let intent = liveFollow.handle(.interactionEnded(
            isNearBottom: ToolTimelineRowUIHelpers.isNearBottom(viewport),
            isStreaming: isStreaming
        ))
        return intent == .followTail
    }

    private static func accessibilityIdentifier(itemID: String) -> String {
        "chat.timeline.row.\(itemID).markdownViewport"
    }
}
