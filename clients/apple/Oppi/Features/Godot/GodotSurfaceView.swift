import UIKit

/// The one view the engine draws into, app-wide (design §5): the engine adds
/// its Metal layer (OpenGL in the simulator) under this view's layer, and
/// `GodotEngineHost` moves this view between Godot panes rather than making a
/// new one, because the engine cannot start a second time.
///
/// - The engine resizes once a size settles, and again when the view enters
///   a window or its display scale changes, so touches (points times that
///   scale) always land where they are drawn. While a divider drag holds the
///   size (`holdSize`), the engine's layer is stretched to the view instead,
///   and touches map back through the stretch (`enginePoint`).
/// - No gesture recognizer of any view around it may begin on a touch that
///   lands here, so a pane's pans and swipes never take the game's touches
///   (`gestureRecognizerShouldBegin`). A touch makes the view first
///   responder, so hardware keys reach the game.
final class GodotSurfaceView: UIView {
    /// The settled size and scale, for the engine.
    var onSettledSize: ((CGSize, CGFloat) -> Void)?
    /// Moved to another window, or out of one.
    var onWindowChange: (() -> Void)?
    let input = GodotInputForwarder()
    /// The game's pane has focus: the view holds the keyboard whenever it is
    /// in a window, also after it moves between panes (a move resigns it).
    var wantsKeyboard = false {
        didSet { claimKeyboardIfWanted() }
    }

    /// The size the engine last took, while a divider drag holds it.
    private var heldSize: CGSize?
    /// The size and scale the engine last took.
    private var engineSize: CGSize = .zero
    private var engineScale: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
        accessibilityIdentifier = "godot.surface"
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Game")
        accessibilityTraits = .allowsDirectInteraction
        layer.masksToBounds = true
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: Self, _: UITraitCollection) in
            view.settleIfChanged()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // A hold belongs to a resize in the window the view was in; its
        // settle skips a pane out of the window, so it ends here.
        releaseHold()
        settleIfChanged()
        claimKeyboardIfWanted()
        onWindowChange?()
    }

    private func claimKeyboardIfWanted() {
        if wantsKeyboard, window != nil, !isFirstResponder {
            becomeFirstResponder()
        } else if !wantsKeyboard, isFirstResponder {
            resignFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard heldSize == nil else { return stretchHeldLayer() }
        layer.sublayerTransform = CATransform3DIdentity
        settleIfChanged()
    }

    /// Tells the engine the view's size and scale when either changed. Only
    /// in a window: outside one the scale is not the screen's.
    private func settleIfChanged() {
        let scale = traitCollection.displayScale
        guard heldSize == nil, window != nil, bounds.width > 0, bounds.height > 0, scale > 0,
              bounds.size != engineSize || scale != engineScale else { return }
        engineSize = bounds.size
        engineScale = scale
        onSettledSize?(bounds.size, scale)
    }

    // MARK: Live resize

    /// A divider beside the pane started to move: the engine keeps its size
    /// and its layer stretches to the view until `settleSize`.
    func holdSize() {
        guard heldSize == nil, engineSize != .zero else { return }
        heldSize = engineSize
    }

    func settleSize() {
        guard releaseHold() else { return }
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Drops a hold and its stretch; false when nothing was held.
    @discardableResult
    private func releaseHold() -> Bool {
        guard heldSize != nil else { return false }
        heldSize = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()
        return true
    }

    /// The engine's layer sits at the top left at the held size; this maps
    /// it onto the view's bounds, about the layer's centre (its anchor).
    private func stretchHeldLayer() {
        guard let held = heldSize, held.width > 0, held.height > 0 else { return }
        let scaleX = bounds.width / held.width
        let scaleY = bounds.height / held.height
        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = CATransform3DScale(
            CATransform3DMakeTranslation(centre.x * scaleX - centre.x, centre.y * scaleY - centre.y, 0),
            scaleX, scaleY, 1
        )
        CATransaction.commit()
    }

    /// A point in this view as the engine places it: the same point, unless
    /// a held size stretches the engine's layer.
    func enginePoint(_ point: CGPoint) -> CGPoint {
        guard let held = heldSize, bounds.width > 0, bounds.height > 0 else { return point }
        return CGPoint(x: point.x * held.width / bounds.width, y: point.y * held.height / bounds.height)
    }

    // MARK: Input

    /// Recognizers on views around this one (a pane's pans, an edge swipe)
    /// never begin on the game's touches.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === self && super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        wantsKeyboard = true
        input.touchesBegan(touches, in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        input.touchesMoved(touches, with: event, in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        input.touchesEnded(touches, cancelled: false, in: self)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        input.touchesEnded(touches, cancelled: true, in: self)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !input.presses(presses, pressed: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !input.presses(presses, pressed: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !input.presses(presses, pressed: false) { super.pressesCancelled(presses, with: event) }
    }
}
