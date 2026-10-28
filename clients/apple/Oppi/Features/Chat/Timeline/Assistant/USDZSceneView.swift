import UIKit

/// How far the inspect gestures have turned, zoomed, and moved a USDZ model.
/// Apple's `CameraControls` is one mode at a time (orbit *or* pan *or*
/// dolly); inspect uses 1-finger orbit, pinch zoom, and 2-finger pan together,
/// so `USDZSceneView` owns the gestures and hands the canvas this value.
struct USDZInspectPose: Equatable {
    static let maximumPitch: Float = 1.2
    static let zoomRange: ClosedRange<Float> = 0.35...3
    static let maximumPan: Float = 1.6

    var yaw: Float = 0
    var pitch: Float = 0
    var zoom: Float = 1
    var pan: SIMD2<Float> = .zero

    mutating func orbit(by translation: CGPoint) {
        yaw += Float(translation.x) * 0.01
        pitch -= Float(translation.y) * 0.01
        clamp()
    }

    mutating func pan(by translation: CGPoint) {
        pan += SIMD2(Float(translation.x) * 0.004, Float(-translation.y) * 0.004)
        clamp()
    }

    /// `startZoom` is the zoom when the pinch began; `scale` is its cumulative scale.
    mutating func zoom(from startZoom: Float, scale: CGFloat) {
        zoom = startZoom * Float(scale)
        clamp()
    }

    private mutating func clamp() {
        pitch = min(Self.maximumPitch, max(-Self.maximumPitch, pitch))
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom))
        pan = SIMD2(
            min(Self.maximumPan, max(-Self.maximumPan, pan.x)),
            min(Self.maximumPan, max(-Self.maximumPan, pan.y))
        )
    }
}

/// A USDZ model on screen: the SwiftUI `USDZRealityCanvas` (the one island
/// RealityKit needs) with the UIKit inspect gestures and accessibility around
/// it. The inline card, the full-screen controller, and the file viewer all
/// mount this.
///
/// The canvas is hosted through `HostFactory.content`, which needs the app
/// root, so it is installed once the view is in a window.
@MainActor
final class USDZSceneView: UIView, UIGestureRecognizerDelegate {
    /// Called on the main actor when RealityKit cannot load the file.
    var onLoadFailed: (() -> Void)?

    /// Whether the gestures act. Off, touches fall through to whatever scrolls
    /// beneath (the chat).
    var isInteractive = false {
        didSet {
            for recognizer in gestureRecognizers ?? [] { recognizer.isEnabled = isInteractive }
        }
    }

    private(set) var pose = USDZInspectPose() {
        didSet {
            guard pose != oldValue, let fileURL else { return }
            host?.setContent(canvas(for: fileURL))
        }
    }

    private var fileURL: URL?
    private var host: HostedContentController?
    private var pinchStartZoom: Float = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityHint = String(localized: "Drag to orbit, pinch to zoom, two fingers to pan")

        let orbit = UIPanGestureRecognizer(target: self, action: #selector(handleOrbit(_:)))
        orbit.minimumNumberOfTouches = 1
        orbit.maximumNumberOfTouches = 1
        orbit.name = "usdz-orbit"
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.name = "usdz-pan"
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.name = "usdz-zoom"
        pan.delegate = self
        pinch.delegate = self
        for recognizer in [orbit, pan, pinch] {
            recognizer.isEnabled = false
            addGestureRecognizer(recognizer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Loads `fileURL` in a fresh canvas with the pose reset.
    func show(fileURL: URL) {
        removeCanvas()
        self.fileURL = fileURL
        pose = USDZInspectPose()
        installCanvasIfPossible()
    }

    /// Removes the canvas; the file is no longer shown.
    func clear() {
        removeCanvas()
        fileURL = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        installCanvasIfPossible()
    }

    private func canvas(for fileURL: URL) -> USDZRealityCanvas {
        USDZRealityCanvas(
            fileURL: fileURL,
            pose: pose,
            onLoadFailed: { [weak self] in self?.onLoadFailed?() }
        )
    }

    private func installCanvasIfPossible() {
        guard host == nil, let fileURL, window != nil,
              let root = HostFactory.root(near: self) else { return }
        let host = HostFactory.content(canvas(for: fileURL), root: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        // The gestures live on this view, so the canvas takes no touches.
        host.view.isUserInteractionEnabled = false
        let parent = nearestViewController()
        parent?.addChild(host)
        addSubview(host.view)
        sendSubviewToBack(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let parent { host.didMove(toParent: parent) }
        self.host = host
    }

    private func removeCanvas() {
        guard let host else { return }
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        self.host = nil
    }

    private func nearestViewController() -> UIViewController? {
        sequence(first: self as UIResponder, next: \.next).first { $0 is UIViewController } as? UIViewController
    }

    @objc private func handleOrbit(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        pose.orbit(by: translation)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        pose.pan(by: translation)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinchStartZoom = pose.zoom }
        pose.zoom(from: pinchStartZoom, scale: gesture.scale)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer.name == "usdz-zoom" && other.name == "usdz-pan"
            || gestureRecognizer.name == "usdz-pan" && other.name == "usdz-zoom"
    }
}
