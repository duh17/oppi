import AVFoundation
import SwiftUI
import UIKit

/// Aspect-fit H.264 picture with pinch-zoom, pan, and double-tap fit ↔ 2×.
/// Zoom lives on `UIScrollView` so it does not fight the navigation pop gesture.
final class DesktopLiveSampleBufferView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onDecodeFailed: (() -> Void)?

    private let scrollView = UIScrollView()
    private let videoView = SampleLayerView()
    private let doubleTap = UITapGestureRecognizer()
    private var lastBounds: CGSize = .zero
    private var videoSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityIdentifier = "desktop.live.picture"
        scrollView.isAccessibilityElement = true
        scrollView.accessibilityLabel = "Remote Screen"
        scrollView.accessibilityTraits = .image
        addSubview(scrollView)
        scrollView.addSubview(videoView)
        if let sampleLayer = videoView.sampleLayer {
            sampleLayer.videoGravity = .resizeAspect
            sampleLayer.backgroundColor = UIColor.black.cgColor
        }
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(handleDoubleTap))
        doubleTap.delegate = self
        scrollView.addGestureRecognizer(doubleTap)
        updateZoomAccessibilityActions()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDecodeFailed),
            name: .AVSampleBufferDisplayLayerFailedToDecode,
            object: videoView.sampleLayer
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleDecodeFailed() {
        Task { @MainActor in
            self.onDecodeFailed?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let size = scrollView.bounds.size
        if size != lastBounds {
            lastBounds = size
            layoutPicture(resetZoom: true)
        }
    }

    @discardableResult
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if let format = CMSampleBufferGetFormatDescription(sample) {
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            let next = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
            if next != videoSize {
                let sameAspect = videoSize.width > 0
                    && abs(next.width / next.height - videoSize.width / videoSize.height) < 0.001
                videoSize = next
                videoView.sampleLayer?.videoGravity = .resize
                if !sameAspect {
                    layoutPicture(resetZoom: false)
                }
            }
        }
        guard let layer = videoView.sampleLayer else { return false }
        layer.enqueue(sample)
        if layer.status == .failed {
            return false
        }
        return true
    }

    func clearPicture() {
        videoView.sampleLayer?.flushAndRemoveImage()
    }

    func setAccessibilityChrome(label: String, value: String) {
        scrollView.accessibilityLabel = label
        scrollView.accessibilityValue = value
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { videoView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPicture()
    }

    func scrollViewDidEndZooming(
        _ scrollView: UIScrollView,
        with view: UIView?,
        atScale scale: CGFloat
    ) {
        centerPicture()
        updateZoomAccessibilityActions()
    }

    private func layoutPicture(resetZoom: Bool) {
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }
        let fit: CGSize
        if videoSize.width > 0, videoSize.height > 0 {
            let scale = min(boundsSize.width / videoSize.width, boundsSize.height / videoSize.height)
            fit = CGSize(
                width: floor(videoSize.width * scale),
                height: floor(videoSize.height * scale)
            )
        } else {
            fit = boundsSize
        }
        if resetZoom, scrollView.zoomScale != 1 {
            scrollView.setZoomScale(1, animated: false)
        }
        videoView.frame = CGRect(origin: .zero, size: fit)
        scrollView.contentSize = fit
        centerPicture()
    }

    private func centerPicture() {
        let boundsSize = scrollView.bounds.size
        var frame = videoView.frame
        frame.origin.x = frame.size.width < boundsSize.width ? (boundsSize.width - frame.size.width) / 2 : 0
        frame.origin.y = frame.size.height < boundsSize.height ? (boundsSize.height - frame.size.height) / 2 : 0
        videoView.frame = frame
    }

    @objc private func handleDoubleTap() {
        toggleFitOrTwoX()
    }

    /// Same owner as the double-tap and the VoiceOver custom action.
    @discardableResult
    func toggleFitOrTwoX() -> Bool {
        let target: CGFloat = scrollView.zoomScale > 1.05 ? 1 : 2
        scrollView.setZoomScale(target, animated: !UIAccessibility.isReduceMotionEnabled)
        updateZoomAccessibilityActions()
        return true
    }

    private func updateZoomAccessibilityActions() {
        let zoomed = scrollView.zoomScale > 1.05
        let name = zoomed ? "Fit" : "Zoom to 2×"
        scrollView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.toggleFitOrTwoX() ?? false
            },
        ]
        scrollView.accessibilityHint = zoomed
            ? "Zooms the picture. Activate Fit to show the whole window."
            : "Pinch to zoom. Double-tap or activate Zoom to 2× to read text."
    }

    private final class SampleLayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var sampleLayer: AVSampleBufferDisplayLayer? {
            layer as? AVSampleBufferDisplayLayer
        }
    }
}

struct DesktopLiveSampleBufferRepresentable: UIViewRepresentable {
    var accessibilityLabel: String
    var accessibilityValue: String
    var onView: (DesktopLiveSampleBufferView) -> Void

    func makeUIView(context: Context) -> DesktopLiveSampleBufferView {
        let view = DesktopLiveSampleBufferView()
        onView(view)
        return view
    }

    func updateUIView(_ uiView: DesktopLiveSampleBufferView, context: Context) {
        uiView.setAccessibilityChrome(label: accessibilityLabel, value: accessibilityValue)
        onView(uiView)
    }
}
