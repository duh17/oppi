import UIKit

/// A page that shows one media view (a video player) at the largest size with
/// the media's own proportions that fits its safe area, centered. The media
/// view takes its frame from this page, so it needs no size constraints.
/// Until `contentSize` arrives the box has the 16:9 fallback
/// (`ImageViewportSizing.aspectFit`).
@MainActor
final class AspectFitMediaView: UIView {
    /// The media's natural size, once known; a nil, zero, or absurd size keeps the fallback.
    var contentSize: CGSize? {
        didSet {
            if contentSize != oldValue { setNeedsLayout() }
        }
    }

    private let content: UIView
    private let margin: CGFloat
    private let minimumWidth: CGFloat

    /// `minimumWidth` keeps a very tall, thin video wide enough for its player
    /// controls; the player letterboxes the picture inside.
    init(content: UIView, margin: CGFloat = 16, minimumWidth: CGFloat = 240) {
        self.content = content
        self.margin = margin
        self.minimumWidth = minimumWidth
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let area = bounds.inset(by: safeAreaInsets).insetBy(dx: margin, dy: margin)
        let size = ImageViewportSizing.aspectFit(
            contentSize: contentSize,
            in: area.size,
            minimumWidth: minimumWidth
        )
        content.frame = CGRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

extension ImageViewportSizing {
    /// The largest size with the content's proportions inside `box`, for a media
    /// view whose box is not set by the content's intrinsic size (a width-driven
    /// view in a scroll view keeps `fittedHeight`). A missing or invalid
    /// `contentSize` uses `fallbackAspectRatio` (width over height) until the real
    /// one arrives. `minimumWidth` keeps a very tall, thin picture wide enough for
    /// its controls, never past the box; the player letterboxes the picture inside.
    /// A box with no room has no size.
    static func aspectFit(
        contentSize: CGSize?,
        in box: CGSize,
        fallbackAspectRatio: CGFloat = 16.0 / 9.0,
        minimumWidth: CGFloat = 0
    ) -> CGSize {
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { return .zero }
        let fallback = fallbackAspectRatio.isFinite && fallbackAspectRatio > 0 ? fallbackAspectRatio : 16.0 / 9.0
        let widthToHeight = contentSize
            .flatMap { validatedHeightToWidthRatio(width: $0.width, height: $0.height) }
            .map { 1 / $0 } ?? fallback
        let fittedWidth = min(box.width, box.height * widthToHeight)
        return CGSize(
            width: max(fittedWidth, min(minimumWidth, box.width)),
            height: fittedWidth / widthToHeight
        )
    }
}
