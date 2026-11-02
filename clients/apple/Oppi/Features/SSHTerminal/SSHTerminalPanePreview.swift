import QuartzCore
import UIKit

/// The incoming side of a pane swipe: the neighbour pane's terminal, drawn from
/// its own engine while the screen slides to it.
///
/// A Rex session keeps its neighbours' panes streaming, each into its own
/// engine (`SSHTerminalChannel`), so the pane a swipe reveals has its screen
/// already; a pane whose stream closed still has the last screen it streamed.
/// This view draws that screen on the grid's display-link tick — the screen
/// keeps one display link — and takes no input: the grid under it owns
/// touches, first responder, scroll, and selection. It never draws for a pane
/// that has no screen; the incoming page shows the pane's card instead.
///
/// It has no background of its own: it sits on the incoming page
/// (`SSHTerminalIncomingPage`), whose card shows through until the first
/// frame of the pane lands. Every pane it is given gets a fresh surface, so
/// the picture another pane left on it can never slide in under this one's name.
final class SSHTerminalPanePreview: UIView {
    /// The pane this draws, nil when there is no incoming side.
    private(set) var block: String?
    private weak var channel: SSHTerminalChannel?
    private var metalHost = SSHTerminalMetalHostView()
    private var renderer: SSHTerminalMetalRenderer?
    /// Rebuilt when `AppFont` rebuilds, as the grid's is.
    private var metrics = SSHTerminalCellMetrics.codeFont()
    private var foreground: UIColor = .label
    private var cursorColor: UIColor?
    private var needsFullPaint = true
    private var paintedKittyGeneration: UInt64 = 0

    private var metalLayer: CAMetalLayer? { metalHost.metalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        clipsToBounds = true
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        metalHost.isUserInteractionEnabled = false
        addSubview(metalHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Draws `block`'s terminal from now on, with `adopt(_:)`'s colors. A pane
    /// it was not drawing starts on a blank surface: transparent until its
    /// first frame is presented, never the last pane's picture.
    func show(block: String, channel: SSHTerminalChannel) {
        guard self.block != block || self.channel !== channel else { return }
        if self.block != block { replaceSurface() }
        self.block = block
        self.channel = channel
        paintedKittyGeneration = 0
        // The grid's next tick draws it, once it is in the hierarchy.
        needsFullPaint = true
    }

    /// No incoming side any more: the next swipe starts from nothing, and the
    /// renderer it built goes (4 MiB of atlas, 20 MiB once a pane drew an
    /// emoji) rather than waiting for the next drag.
    func detach() {
        block = nil
        channel = nil
        renderer = nil
        needsFullPaint = true
    }

    /// A Metal layer keeps showing the last drawable presented to it. A new
    /// layer shows nothing until this pane's first frame is presented, so the
    /// page's card stays visible underneath until then.
    private func replaceSurface() {
        metalHost.removeFromSuperview()
        metalHost = SSHTerminalMetalHostView()
        metalHost.isUserInteractionEnabled = false
        metalHost.frame = bounds
        addSubview(metalHost)
    }

    /// What draws with this view's colors: the grid's theme and font.
    func adopt(_ grid: SSHTerminalGridView) {
        foreground = grid.foreground
        cursorColor = grid.cursorColorForPreview
        needsFullPaint = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalHost.frame = bounds
        needsFullPaint = true
    }

    /// What one paint of the pane's screen did: it drew (or had nothing new to
    /// draw), it is worth retrying in a moment, or there is nothing to draw here.
    enum Paint: Equatable {
        case drawn
        /// A transient miss (no drawable yet, the ring full): retry.
        case waiting
        /// No pane, no screen, or no renderer: retrying would spin.
        case nothing
    }

    /// One paint of the pane's screen when it changed. Same gate as the grid's: a
    /// pane whose picture did not move costs one `changeCount` read.
    @discardableResult
    func presentIfNeeded(scale: CGFloat) -> Paint {
        guard let block, let channel, window != nil, bounds.width > 0, bounds.height > 0 else { return .nothing }
        guard let engine = channel.screenEngine(for: block) else { return .nothing }
        guard let renderer = rendererIfReady(scale: scale) else { return .nothing }
        if renderer.inFlightCount >= SSHTerminalMetalRenderer.ringSize { return .waiting }
        guard let metalLayer else { return .nothing }
        let frame = engine.frame()
        let shouldDraw = needsFullPaint || !frame.rebuiltRows.isEmpty
            || (frame.kittyGeneration != paintedKittyGeneration && frame.kittyGeneration != 0)
        if !shouldDraw { return .drawn }
        metalLayer.device = renderer.device
        metalLayer.contentsScale = scale
        let drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if metalLayer.drawableSize != drawableSize { metalLayer.drawableSize = drawableSize }
        guard let drawable = metalLayer.nextDrawable() else {
            needsFullPaint = true
            return .waiting
        }
        let cursor = (cursorColor ?? foreground).withAlphaComponent(0.65)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        cursor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let cost = renderer.encode(
            frame: frame,
            cursorColor: SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha)),
            drawable: drawable,
            // The incoming pane is on screen for one slide: a full rebuild every
            // paint is what its screen needs, and it costs no cache of its own.
            fullRebuild: true,
            shiftPixels: 0
        )
        if cost.submitted {
            needsFullPaint = false
            paintedKittyGeneration = frame.kittyGeneration
            return .drawn
        }
        needsFullPaint = true
        return cost.miss == .deterministic ? .nothing : .waiting
    }

    private func rendererIfReady(scale: CGFloat) -> SSHTerminalMetalRenderer? {
        if let renderer { return renderer }
        guard let pipeline = SSHTerminalMetalPipeline.peek() else {
            SSHTerminalMetalPipeline.prewarm()
            return nil
        }
        guard let built = try? SSHTerminalMetalRenderer(pipeline: pipeline, metrics: metrics, scale: scale) else {
            return nil
        }
        metalLayer?.device = built.device
        renderer = built
        return built
    }

    /// Posted on the main thread after `AppFont` rebuilds.
    func fontPreferencesChanged() {
        metrics = SSHTerminalCellMetrics.codeFont()
        renderer?.setMetrics(metrics, scale: max(traitCollection.displayScale, 1))
        needsFullPaint = true
    }
}
