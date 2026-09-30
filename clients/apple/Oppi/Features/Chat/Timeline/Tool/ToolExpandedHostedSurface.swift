import UIKit

/// Owns the hosted media and document viewport of a tool timeline row.
///
/// A tool row hosts one embedded view inside `container` for read-media
/// (image, SVG, audio, video, PDF), voice messages, CSV/TSV tables and
/// GeoJSON/TopoJSON maps. The surface keeps that lifecycle in one place: the
/// container and its width and height constraints, the currently mounted
/// content view and whether the container is the row's active expanded
/// layout, the install methods that create or reuse the content view, and
/// teardown. Each content view owns its own async loading; dropping it from
/// the container cancels that work.
///
/// `ToolTimelineRowContentView` keeps header and collapsed presentation
/// (including the collapsed image preview and audio button, which have their
/// own decode/playback lifecycle), gestures, and the choice of which expanded
/// surface is active. It mounts `container` through a
/// `ToolExpandedSurfaceHostView` and forwards layout events to the methods
/// below. Install methods return whether the row must schedule a layout pass
/// and invalidate its enclosing collection layout; the surface does not know
/// about the row or the timeline. The timeline stays the outer
/// vertical-scroll authority.
@MainActor
final class ToolExpandedHostedSurface {
    /// Resources the media views read. Values, not the row configuration.
    struct MediaResources {
        let audioPlayer: AudioPlayerService?
        let sessionId: String?
        let attachmentFetcher: ((String) async throws -> Data)?
        let attachmentMediaSourceProvider: ((String, String?, String?) async throws -> AuthenticatedMediaSource)?
        let sessionFileDataFetcher: ((String) async throws -> Data)?
        let sessionFileMediaSourceProvider: ((String) async throws -> AuthenticatedMediaSource)?
    }

    /// Host for the mounted content view. The row activates it in a
    /// `ToolExpandedSurfaceHostView`.
    let container = UIView()
    /// The mounted embedded view, nil until an install runs and after retirement.
    private(set) var contentView: UIView?
    /// The container is the row's active expanded layout.
    private(set) var isActive = false

    private let viewport: UIScrollView
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    init(viewport: UIScrollView) {
        self.viewport = viewport
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .clear
        container.isHidden = true
    }

    /// Adds the container to `host` and pins its width to the viewport frame.
    /// Call once the host is inside the viewport's hierarchy.
    func mount(in host: ToolExpandedSurfaceHostView) {
        host.prepareSurfaceView(container)
        let width = container.widthAnchor.constraint(
            equalTo: viewport.frameLayoutGuide.widthAnchor,
            constant: 0
        )
        // During the first self-sizing pass the frame layout guide can report
        // width 0. Staying below required lets fitting supply a temporary
        // width instead of measuring at 0px.
        width.priority = .defaultHigh
        width.isActive = true
        widthConstraint = width
    }

    // MARK: - Activation

    /// Call after a host activated `container`.
    func didActivate() {
        container.isHidden = false
        isActive = true
    }

    /// Leaves the expanded layout and drops the content view, which releases
    /// its tasks.
    func retire() {
        container.isHidden = true
        isActive = false
        clearContent()
    }

    // MARK: - Install

    /// Read-media (image, SVG, audio, video, PDF). Returns true when a new
    /// content view was mounted.
    @discardableResult
    func installReadMedia(
        output: String,
        isError: Bool,
        filePath: String?,
        startLine: Int,
        attachments: [ToolPresentationBuilder.ToolMediaAttachment],
        resources: MediaResources
    ) -> Bool {
        let native: NativeExpandedReadMediaView
        let mounted: Bool
        if let existing = contentView as? NativeExpandedReadMediaView {
            native = existing
            mounted = false
        } else {
            clearContent()
            native = NativeExpandedReadMediaView()
            mountContentView(native)
            mounted = true
        }

        native.apply(
            output: output,
            isError: isError,
            filePath: filePath,
            startLine: startLine,
            attachments: attachments,
            themeID: ThemeRuntimeState.currentThemeID(),
            audioPlayer: resources.audioPlayer,
            sessionId: resources.sessionId,
            attachmentFetcher: resources.attachmentFetcher,
            attachmentMediaSourceProvider: resources.attachmentMediaSourceProvider,
            sessionFileDataFetcher: resources.sessionFileDataFetcher,
            sessionFileMediaSourceProvider: resources.sessionFileMediaSourceProvider
        )
        return mounted
    }

    /// Voice message. Always returns true: the row re-measures after every apply.
    @discardableResult
    func installAudioMessage(
        itemID: String,
        text: String,
        attachmentId: String,
        mimeType: String,
        playbackBehavior: AudioPlaybackBehavior?,
        suppressAutoplay: Bool,
        durationSeconds: TimeInterval?,
        resources: MediaResources
    ) -> Bool {
        let native: NativeAudioMessageView
        if let existing = contentView as? NativeAudioMessageView {
            native = existing
        } else {
            clearContent()
            native = NativeAudioMessageView()
            mountContentView(native)
        }

        let hasAttachment = !attachmentId.isEmpty
        native.apply(
            id: itemID,
            message: text,
            attachmentId: attachmentId,
            mimeType: mimeType,
            playbackBehavior: playbackBehavior,
            sessionId: resources.sessionId,
            audioPlayer: resources.audioPlayer,
            attachmentFetcher: hasAttachment ? resources.attachmentFetcher : nil,
            attachmentMediaSourceProvider: hasAttachment ? resources.attachmentMediaSourceProvider : nil,
            palette: ThemeRuntimeState.currentPalette(),
            suppressAutoplay: suppressAutoplay,
            durationSeconds: durationSeconds
        )
        native.setNeedsLayout()
        return true
    }

    /// CSV/TSV table. Returns true when a new content view was mounted.
    @discardableResult
    func installDelimitedTable(itemID: String, text: String, filePath: String?) -> Bool {
        let plan = DelimitedTableViewerPlan.resolved(path: filePath, text: text)
        if let existing = contentView as? DelimitedTableRenderView,
           existing.displays(plan) {
            return false
        }

        clearContent()
        let view = DelimitedTableRenderView(plan: plan)
        view.accessibilityIdentifier = "chat.timeline.row.\(itemID).delimitedTable"
        mountContentView(view)
        pinHeightToViewport()
        return true
    }

    /// GeoJSON/TopoJSON map. Returns true when a new content view was mounted.
    @discardableResult
    func installGeoJSON(itemID: String, text: String, filePath: String?) -> Bool {
        let plan = GeoJSONViewerPlan.resolved(path: filePath, text: text)
        if let existing = contentView as? GeoJSONMapView,
           existing.displays(plan) {
            return false
        }

        clearContent()
        let view = GeoJSONMapView(plan: plan)
        view.accessibilityIdentifier = "chat.timeline.row.\(itemID).geojson"
        mountContentView(view)
        pinHeightToViewport()
        return true
    }

    private func mountContentView(_ view: UIView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = view
    }

    /// Tables and maps follow the capped viewport, not
    /// systemLayoutSizeFitting's full content height (same frame pin as
    /// completed Markdown).
    private func pinHeightToViewport() {
        heightConstraint?.isActive = false
        let constraint = container.heightAnchor.constraint(
            equalTo: viewport.frameLayoutGuide.heightAnchor
        )
        constraint.priority = .required
        constraint.isActive = true
        heightConstraint = constraint
    }

    private func clearContent() {
        heightConstraint?.isActive = false
        heightConstraint = nil
        contentView?.removeFromSuperview()
        contentView = nil
    }

    // MARK: - Layout

    /// Before the viewport width is known the pin stays soft (`.defaultHigh`):
    /// frame layout guides can report 0 during the first fitting pass, and a
    /// soft pin lets fitting supply a temporary width. Once the width is known
    /// the pin must be `.required` to beat a descendant's compression
    /// resistance (also 750 by default); otherwise the hosted view stays too
    /// wide and clips.
    func updateWidthPriority() {
        guard let widthConstraint else { return }
        widthConstraint.priority = isActive && viewport.bounds.width > 1
            ? .required
            : .defaultHigh
    }

    /// Hosted content never scrolls horizontally inside the row's viewport.
    func pinViewportHorizontalOffset() {
        guard isActive else { return }
        let pinnedX = -viewport.adjustedContentInset.left
        if abs(viewport.contentOffset.x - pinnedX) > 0.5 {
            viewport.contentOffset.x = pinnedX
        }
    }

    /// Natural height of the hosted content at `width`, before the row applies
    /// its policy bounds.
    func measuredHeight(width: CGFloat) -> CGFloat {
        ToolRowViewportCalculator.measuredExpandedContentHeight(
            for: contentView ?? container,
            width: width
        )
    }
}
