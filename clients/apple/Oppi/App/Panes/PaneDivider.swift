import UIKit

// The divider between a pane host's leaf and its companion: the width range
// the companion may take, how the divider follows the finger, where a drag
// settles, and the one view that carries the gesture, the pointer and
// VoiceOver. `PaneHostController` owns the state these act on.

// MARK: - Width policy, rubber banding, and snapping

/// A companion's width range at the host's current bounds: the ordinary
/// side-by-side range (`minimum`...`maximum`), and `full`, the width the
/// companion can be dragged or flung all the way open to.
struct PaneWidthPolicy: Equatable {
    /// The leaf beside the companion keeps at least the chat's tested width
    /// (`PaneMinimumSize.chat`) while the two share the host, so its bar and
    /// composer never wrap. Past that the companion covers the leaf (`full`)
    /// rather than squeezing it.
    static let screenMinimumWidth: CGFloat = PaneMinimumSize.chat.width
    /// What stays of the leaf beside a full-window companion: a slim strip
    /// that carries the divider's grabber, the way back to side by side.
    static let fullWindowGrabEdge: CGFloat = 20

    let minimum: CGFloat
    /// The width a companion opens at when nothing is remembered yet.
    let ideal: CGFloat
    /// The widest side-by-side width: the companion's own ceiling, or the
    /// room left beside the leaf's minimum. Past it the companion slides over
    /// the leaf, which stops reflowing, instead of squeezing it further.
    let maximum: CGFloat
    /// The full-window width: the whole host but its grab edge, the leaf
    /// beside covered.
    let full: CGFloat
    /// The host's own width, which a remembered width is a fraction of.
    var window: CGFloat = 0
    /// Whether the companion's own minimum fits beside the leaf's minimum.
    /// When it does not, the companion shows full, over the leaf, with only
    /// Close, until the host widens: the fit rule (build plan §1.3), which
    /// Stage 3's tree draws as a zoom of the attached leaf.
    var fitsBeside = true

    /// The live policy for a companion's own range in a host `window` wide:
    /// zero before the host's first layout leaves the companion's own range.
    static func resolved(
        minWidth: CGFloat,
        idealWidth: CGFloat,
        maxWidth: CGFloat?,
        window: CGFloat
    ) -> Self {
        let softMaximum = maxWidth ?? min(idealWidth * 1.75, 640)
        guard window > 0 else {
            return Self(
                minimum: min(minWidth, softMaximum), ideal: min(idealWidth, softMaximum),
                maximum: softMaximum, full: softMaximum, window: 0
            )
        }
        let full = max(0, window - fullWindowGrabEdge)
        let room = window - screenMinimumWidth - PanePresentation.dividerThickness
        let maximum = max(0, min(softMaximum, room, full))
        return Self(
            minimum: min(minWidth, maximum),
            ideal: min(idealWidth, maximum),
            maximum: maximum,
            full: max(full, maximum),
            window: window,
            fitsBeside: room >= minWidth
        )
    }

    /// Halfway between `maximum` and `full`: cross it, by position or a fast
    /// fling, and the divider commits to full instead of springing back.
    var expandThreshold: CGFloat { maximum + (full - maximum) / 2 }
    /// Halfway between `minimum` and closed: cross it and the companion
    /// closes instead of springing back to `minimum`.
    var closeThreshold: CGFloat { minimum / 2 }

    func clampedToOrdinaryRange(_ width: CGFloat) -> CGFloat {
        min(maximum, max(minimum, width))
    }
}

/// How the divider follows the finger. Inside the side-by-side range and on
/// past it toward full it tracks 1:1: past `maximum` the leaf beside has
/// stopped reflowing and the companion simply slides over it, so there is
/// nothing to resist. Below `minimum` the companion's content would squeeze,
/// so the divider resists the way `UIScrollView` bounces, saying "this
/// closes".
enum PaneRubberBand {
    /// `coefficient: 2` puts the resisted width at the close threshold
    /// (`minimum / 2`) exactly when the finger is there too.
    static let closingCoefficient: CGFloat = 2

    static func resisted(_ distance: CGFloat, dimension: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0, distance > 0 else { return 0 }
        return (1 - (1 / ((distance * coefficient / dimension) + 1))) * dimension
    }

    /// The width drawn for a raw (1:1 with the finger) target.
    static func liveWidth(forRawTarget raw: CGFloat, policy: PaneWidthPolicy) -> CGFloat {
        guard raw < policy.minimum else { return min(raw, policy.full) }
        let dimension = max(policy.minimum, 1)
        return policy.minimum - resisted(policy.minimum - raw, dimension: dimension, coefficient: closingCoefficient)
    }

    /// The raw target that draws `width`, so a drag that starts mid-motion
    /// (an open still settling) picks the divider up where it is drawn
    /// instead of jumping to where the finger math would put it.
    static func rawTarget(forLiveWidth width: CGFloat, policy: PaneWidthPolicy) -> CGFloat {
        guard width < policy.minimum else { return width }
        let dimension = max(policy.minimum, 1)
        // Inverse of `resisted`: y = (1 - 1 / (c·d/D + 1))·D  ⇒  d = y / (c·(1 - y/D)).
        let resistedAmount = min(policy.minimum - width, dimension * 0.999)
        let distance = resistedAmount / (closingCoefficient * (1 - resistedAmount / dimension))
        return policy.minimum - distance
    }
}

/// Where a drag settles once it ends.
enum PaneSnapOutcome: Equatable {
    case closed
    case width(CGFloat)
    case full
}

/// The zone a live width sits in, for a haptic tick each time a drag crosses
/// into or out of a commit zone.
enum PaneSnapZone: Equatable {
    case closing, ordinary, expanding
}

enum PaneSnapResolver {
    /// A companion with no room beside its leaf (the iPad mini in portrait)
    /// covers it with nothing between full and closed, so its divider drag is
    /// a dismiss swipe and reads like a back swipe: a third of the way across
    /// closes it. The resize rule (`closeThreshold`, half the minimum) would
    /// ask for about three quarters of the mini's width.
    static let noRoomDismissFraction: CGFloat = 1.0 / 3.0
    /// A light flick toward closing closes it from anywhere past
    /// `noRoomFlickMinimumTravel`; a flick back toward full keeps it.
    static let noRoomFlickVelocity: CGFloat = 500
    /// A touch that barely moved before its release is not a flick.
    static let noRoomFlickMinimumTravel: CGFloat = 40

    static func zone(for width: CGFloat, policy: PaneWidthPolicy) -> PaneSnapZone {
        if !policy.fitsBeside {
            return policy.full - width >= policy.full * noRoomDismissFraction ? .closing : .expanding
        }
        if width <= policy.closeThreshold { return .closing }
        if width >= policy.expandThreshold { return .expanding }
        return .ordinary
    }

    /// The divider's resting place once a drag ends: closed, full, or an
    /// ordinary width, carrying the gesture's velocity into the projection so
    /// a fast flick settles like a slower drag further in the same direction
    /// would have. Leaving full always returns to the remembered width
    /// rather than wherever the pull-back happened to stop, so full reads as
    /// a clean toggle and not a second free-resize range. `rawWidth` is the
    /// finger's own target, the same one `zone` ticks the haptic for, so a
    /// release decides exactly what the last tick announced. A companion that
    /// does not fit beside its leaf has no ordinary range: it closes or stays
    /// full (`resolveNoRoom`). `verticalTravel` and `verticalVelocity` let a
    /// mostly vertical drag on the divider count as no swipe there.
    static func resolve(
        rawWidth: CGFloat,
        widthVelocity: CGFloat,
        policy: PaneWidthPolicy,
        rememberedWidth: CGFloat,
        wasFull: Bool,
        verticalTravel: CGFloat = 0,
        verticalVelocity: CGFloat = 0,
        projectionSeconds: CGFloat = 0.12
    ) -> PaneSnapOutcome {
        guard policy.fitsBeside else {
            return resolveNoRoom(
                travel: policy.full - rawWidth,
                closingVelocity: -widthVelocity,
                verticalTravel: verticalTravel,
                verticalVelocity: verticalVelocity,
                policy: policy
            )
        }
        let projected = rawWidth + widthVelocity * projectionSeconds
        if projected <= policy.closeThreshold { return .closed }
        if projected >= policy.expandThreshold { return .full }
        if wasFull { return .width(policy.clampedToOrdinaryRange(rememberedWidth)) }
        return .width(policy.clampedToOrdinaryRange(projected))
    }

    /// The dismiss swipe of a companion with no room beside its leaf.
    /// `travel` is how far the divider moved toward closing from full;
    /// `closingVelocity` is positive toward closing. Horizontal must dominate
    /// by the ratio every back swipe uses (`NavigationSwipeGesturePolicy`).
    private static func resolveNoRoom(
        travel: CGFloat,
        closingVelocity: CGFloat,
        verticalTravel: CGFloat,
        verticalVelocity: CGFloat,
        policy: PaneWidthPolicy
    ) -> PaneSnapOutcome {
        let dominance = NavigationSwipeGesturePolicy.dominanceRatio
        guard travel > abs(verticalTravel) * dominance else { return .full }
        let horizontalFlick = abs(closingVelocity) >= noRoomFlickVelocity
            && abs(closingVelocity) > abs(verticalVelocity) * dominance
        if horizontalFlick {
            // The flick's direction decides, as a back swipe's does.
            return closingVelocity > 0 && travel >= noRoomFlickMinimumTravel ? .closed : .full
        }
        return travel >= policy.full * noRoomDismissFraction ? .closed : .full
    }
}

// MARK: - Divider

/// A host's one draggable divider: a visible grabber mark and the
/// resize/expand/close gesture's single owner, so a touch drag, a trackpad
/// hover, and VoiceOver's adjustable actions all drive the same width. One
/// accessibility element, not three competing views.
final class PaneDividerView: UIView {
    /// VoiceOver's increment/decrement step, in points.
    static let accessibilityStep: CGFloat = 32
    /// The touch and pointer band around the hairline; narrower than this and
    /// a resize target is too easy to miss (`ExtensionStripPillHitBand` uses
    /// the same overhang idea for pill rows).
    static let hitWidth: CGFloat = 28

    var onBegan: (() -> Void)?
    var onChanged: ((_ translationX: CGFloat) -> Void)?
    var onEnded: ((_ translation: CGPoint, _ velocity: CGPoint) -> Void)?
    var onStep: ((_ delta: CGFloat) -> Void)?
    var onExpandRequested: (() -> Void)?
    var onRestoreRequested: (() -> Void)?
    var onCloseRequested: (() -> Void)?

    /// What the companion's width can do from here, for the accessibility
    /// action offered, the hint and the spoken value.
    enum Mode: Equatable {
        /// Side by side: it can expand to the full window.
        case beside
        /// Full by choice: it can give the chat its room back.
        case full
        /// Full because it does not fit beside the chat: it can only close.
        case noRoomBeside
    }

    /// The host sets this from its state.
    var mode = Mode.beside {
        didSet {
            guard mode != oldValue else { return }
            applyMode()
        }
    }

    private func applyMode() {
        let (hint, action): (String, String) = switch mode {
        case .beside:
            (String(localized: "Drag, or use the rotor, to resize. Double-tap and drag to expand."),
             String(localized: "Expand Pane"))
        case .full:
            (String(localized: "Drag, or use the rotor, to resize. Double-tap to show the pane beside it again."),
             String(localized: "Show Both Panes"))
        case .noRoomBeside:
            (String(localized: "There is no room beside this panel. Double-tap and drag to close it."),
             String(localized: "Close Panel"))
        }
        accessibilityHint = hint
        let mode = mode
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: action) { [weak self] _ in
            guard let self else { return false }
            switch mode {
            case .beside: self.onExpandRequested?()
            case .full: self.onRestoreRequested?()
            case .noRoomBeside: self.onCloseRequested?()
            }
            return true
        }]
    }

    /// The companion's drawn width, set on every layout; spoken only when
    /// VoiceOver asks, so a drag formats no string per frame.
    var companionWidth: CGFloat = 0

    override var accessibilityValue: String? {
        get {
            mode != .beside
                ? String(localized: "Full window")
                : String(localized: "\(Int(companionWidth.rounded())) points")
        }
        set {}
    }

    private let grabber = UIView()
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    /// `index` names the divider in tree order (`pane.divider.<n>`).
    init(index: Int) {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityIdentifier = "pane.divider.\(index)"
        accessibilityLabel = String(localized: "Resize panel")
        accessibilityTraits = .adjustable
        // Readable on a dark theme: `.separator` all but vanishes, and in
        // portrait on the iPad mini this mark is the only cue that the
        // companion can be dragged.
        grabber.backgroundColor = .tertiaryLabel
        grabber.layer.cornerRadius = 2.5
        grabber.isUserInteractionEnabled = false
        addSubview(grabber)
        addGestureRecognizer(pan)
        // Full by choice, the divider is the strip at the leading edge that
        // is left of the leaf beside: a tap gives that leaf its room back.
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        addInteraction(UIPointerInteraction(delegate: self))
        applyMode()
    }

    @objc private func handleTap() {
        if mode == .full { onRestoreRequested?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let grabberSize = CGSize(width: 5, height: 48)
        grabber.frame = CGRect(
            x: (bounds.width - grabberSize.width) / 2,
            y: (bounds.height - grabberSize.height) / 2,
            width: grabberSize.width,
            height: grabberSize.height
        )
    }

    override func accessibilityIncrement() { onStep?(Self.accessibilityStep) }
    override func accessibilityDecrement() { onStep?(-Self.accessibilityStep) }

    /// Cancels a drag in flight; the recognizer reports `.cancelled`, which
    /// ends the drag where it was last drawn.
    func cancelDrag() {
        guard pan.state == .began || pan.state == .changed else { return }
        pan.isEnabled = false
        pan.isEnabled = true
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            onBegan?()
        case .changed:
            onChanged?(recognizer.translation(in: self).x)
        case .ended, .cancelled:
            onEnded?(recognizer.translation(in: self), recognizer.velocity(in: self))
        default:
            break
        }
    }
}

extension PaneDividerView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        UIPointerStyle(effect: .highlight(UITargetedPreview(view: grabber)))
    }
}
