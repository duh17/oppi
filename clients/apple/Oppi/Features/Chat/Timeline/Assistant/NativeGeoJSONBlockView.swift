import UIKit

/// Inline GeoJSON/TopoJSON map for markdown fences.
///
/// Open fences stay a code block. Closed fences show the production MapKit
/// view. Tap opens the document-viewer chrome with Rendered/Source.
@MainActor
final class NativeGeoJSONBlockView: UIView {
    private let codeBlockView = NativeCodeBlockView()
    private var mapView: GeoJSONMapView?
    private var mapHeightConstraint: NSLayoutConstraint?
    private var currentCode: String?
    private var currentKind: GeoJSONViewerPlan.Kind = .geojson
    private var isShowingMap = false
    private var reviewCommentSelectionRouter: ReviewCommentSelectionRouter?
    private var reviewCommentSourceContext: ReviewCommentSourceContext?

    private static let inlineHeight: CGFloat = 220

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configureReviewCommentSelection(
        router: ReviewCommentSelectionRouter?,
        sourceContext: ReviewCommentSourceContext?
    ) {
        reviewCommentSelectionRouter = router
        reviewCommentSourceContext = sourceContext
    }

    func applyAsCode(language: String?, code: String, palette: ThemePalette, isOpen: Bool) {
        currentCode = code
        codeBlockView.isHidden = false
        mapView?.isHidden = true
        mapHeightConstraint?.isActive = false
        isShowingMap = false
        codeBlockView.apply(language: language, code: code, palette: palette, isOpen: isOpen)
        isAccessibilityElement = false
        accessibilityIdentifier = nil
    }

    func applyAsMap(code: String, kind: GeoJSONViewerPlan.Kind, palette: ThemePalette) {
        _ = palette
        currentCode = code
        currentKind = kind
        let plan = GeoJSONViewerPlan.resolved(
            path: kind == .topojson ? "inline.topojson" : "inline.geojson",
            text: code
        )
        if let mapView, mapView.displays(plan) {
            showMap(mapView)
            return
        }
        mapView?.removeFromSuperview()
        let next = GeoJSONMapView(plan: plan, allowsInteraction: false)
        next.translatesAutoresizingMaskIntoConstraints = false
        addSubview(next)
        NSLayoutConstraint.activate([
            next.topAnchor.constraint(equalTo: topAnchor),
            next.leadingAnchor.constraint(equalTo: leadingAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor),
            next.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        mapView = next
        showMap(next)
    }

    override func accessibilityActivate() -> Bool {
        openMapPreview()
    }

    @objc private func handleTap() {
        _ = openMapPreview()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        codeBlockView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(codeBlockView)
        NSLayoutConstraint.activate([
            codeBlockView.topAnchor.constraint(equalTo: topAnchor),
            codeBlockView.leadingAnchor.constraint(equalTo: leadingAnchor),
            codeBlockView.trailingAnchor.constraint(equalTo: trailingAnchor),
            codeBlockView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let height = heightAnchor.constraint(equalToConstant: Self.inlineHeight)
        height.isActive = false
        mapHeightConstraint = height

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    private func showMap(_ view: GeoJSONMapView) {
        codeBlockView.isHidden = true
        view.isHidden = false
        mapHeightConstraint?.isActive = true
        isShowingMap = true
        isAccessibilityElement = true
        accessibilityIdentifier = "geojson.diagram.open"
        accessibilityLabel = currentKind.fileType.displayLabel
        accessibilityHint = String(localized: "Opens map full screen")
        accessibilityTraits = [.button]
        invalidateIntrinsicContentSize()
        ToolTimelineRowPresentationHelpers.forceInvalidateEnclosingCollectionViewLayout(startingAt: self)
    }

    @discardableResult
    private func openMapPreview() -> Bool {
        guard let code = currentCode, isShowingMap else { return false }
        let content = FullScreenCodeContent.geoJSON(content: code, filePath: nil)
        ToolTimelineRowPresentationHelpers.presentFullScreenContent(
            content,
            from: self,
            reviewCommentSelectionRouter: reviewCommentSelectionRouter,
            reviewCommentSessionId: reviewCommentSourceContext?.sessionId,
            reviewCommentSourceLabel: reviewCommentSourceContext?.sourceLabel
        )
        return true
    }
}
