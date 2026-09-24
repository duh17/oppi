import CoreGraphics
import SwiftUI
import UIKit

/// UIView that draws a `GraphicalDocumentRenderer` output via Core Graphics.
///
/// Computes layout once from the parser output, sizes itself to the bounding box,
/// and draws into its `CGContext` on `draw(_:)`.
final class GraphicalRendererUIView: UIView {
    private var drawBlock: ((CGContext, CGPoint) -> Void)?
    private var contentSize: CGSize = .zero

    func configure(
        size: CGSize,
        draw: @escaping (CGContext, CGPoint) -> Void,
        accessibilityLabel: String? = nil
    ) {
        contentSize = size
        drawBlock = draw
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = accessibilityLabel != nil
        self.accessibilityLabel = accessibilityLabel
        accessibilityTraits = accessibilityLabel == nil ? [] : [.image]
        semanticContentAttribute = accessibilityLabel == nil ? .unspecified : .forceLeftToRight
        // Enable high-quality scaling when zoomed.
        contentMode = .redraw
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize { contentSize }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawBlock?(ctx, .zero)
    }
}

// MARK: - Zoomable Scroll Container

/// UIScrollView wrapper that adds pinch-to-zoom, panning, and Photos-style
/// double-tap zoom to a `GraphicalRendererUIView`. Used for diagrams and LaTeX math.
final class ZoomableGraphicalView: UIView, UIScrollViewDelegate {
    static let minimumPickControlHeight: CGFloat = 44
    private let scrollView = UIScrollView()
    private let contentView = GraphicalRendererUIView()
    private var naturalSize: CGSize = .zero
    private var hasUserAdjustedZoom = false
    private var semanticMap: SemanticAnnotationMap?
    private var semanticCommentHandler: ((SemanticTarget) -> Void)?
    private var pickModeEnabled = false
    var usesExternalPickControls = false {
        didSet {
            pickButton.isHidden = usesExternalPickControls || semanticMap?.targets.isEmpty != false
            commentButton.isHidden = usesExternalPickControls || selectedTargetID == nil
        }
    }
    var onPickStateChange: ((Bool, Bool) -> Void)?
    var onSelectionGeometryChange: (() -> Void)?
    func selectedTargetRect(in view: UIView) -> CGRect? {
        guard let id = selectedTargetID, let semanticMap else { return nil }
        return Self.visibleSelectedTargetRect(
            targetID: id, regions: semanticMap.regions,
            viewport: view.safeAreaLayoutGuide.layoutFrame
        ) { [contentView] rect in contentView.convert(rect, to: view) }
    }

    static func visibleSelectedTargetRect(
        targetID: String, regions: [SemanticRegion], viewport: CGRect,
        convert: (CGRect) -> CGRect
    ) -> CGRect? {
        for region in regions.filter({ $0.targetID == targetID })
            .sorted(by: { $0.precedence > $1.precedence }) {
            guard let point = SemanticHitSampling.point(in: region.geometry) else { continue }
            let bounds: CGRect
            switch region.geometry {
            case .rectangle(let rect), .ellipse(let rect): bounds = rect
            case .path(let path), .strokedPath(let path, _): bounds = path.bounds
            default: bounds = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
            }
            let visibleRect = convert(bounds)
            if visibleRect.intersects(viewport) { return visibleRect }
        }
        return nil
    }
    private var selectedTargetID: String?
    private let pickBanner = UILabel()
    private let pickButton = UIButton(type: .system)
    private let commentButton = UIButton(type: .system)
    private let chooserScrollView = UIScrollView()
    private let chooserStack = UIStackView()
    private var chooserHeightConstraint: NSLayoutConstraint?
    private let highlightView = SemanticPickHighlightView()
    private var pickTap: UITapGestureRecognizer?

    init(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        super.init(frame: .zero)
        setup(size: size, draw: draw)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setup(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        backgroundColor = .clear

        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.25
        scrollView.maximumZoomScale = 4.0
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        DoubleTapZoom.install(on: scrollView, target: self, action: #selector(handleDoubleTap(_:)))

        contentView.configure(size: size, draw: draw)
        // UIScrollView owns the zoom transform. Pinning this canvas to its
        // contentLayoutGuide lets later sheet layouts move the transformed
        // frame a second time. Keep natural geometry explicit instead.
        naturalSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        contentView.frame = CGRect(origin: .zero, size: naturalSize)
        scrollView.addSubview(contentView)
        highlightView.isUserInteractionEnabled = false
        highlightView.frame = contentView.bounds
        highlightView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(highlightView)
        scrollView.contentSize = naturalSize
        installPickChrome()

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Update content size and draw block after initial creation.
    ///
    /// Called from `UIViewRepresentable.updateUIView` when SwiftUI
    /// detects property changes. A theme-only redraw preserves the user zoom.
    func update(size: CGSize, draw: @escaping (CGContext, CGPoint) -> Void) {
        contentView.configure(size: size, draw: draw)
        let newWidth = max(size.width, 1)
        let newHeight = max(size.height, 1)
        let sizeChanged = abs(naturalSize.width - newWidth) > 0.5
            || abs(naturalSize.height - newHeight) > 0.5
        if sizeChanged {
            scrollView.zoomScale = 1
            naturalSize = CGSize(width: newWidth, height: newHeight)
            contentView.frame = CGRect(origin: .zero, size: naturalSize)
            scrollView.contentSize = naturalSize
            hasUserAdjustedZoom = false
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyFitScaleIfNeeded()
        centerContent()
        refreshPickAccessibility()
        if selectedTargetID != nil { onSelectionGeometryChange?() }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        toggleZoom(at: gesture.location(in: contentView))
    }

    private func toggleZoom(at pointInContent: CGPoint, animated: Bool? = nil) {
        let fitScale = currentFitScale()
        let zoomingIn = !DoubleTapZoom.isZoomedIn(scale: scrollView.zoomScale, fitScale: fitScale)
        if zoomingIn {
            hasUserAdjustedZoom = true
        }
        DoubleTapZoom.toggle(
            in: scrollView,
            tapInContent: pointInContent,
            fitScale: fitScale,
            animated: animated
        )
        if !zoomingIn {
            hasUserAdjustedZoom = false
        }
    }

    /// Fit to width on first layout and after rotation, but keep a user zoom.
    private func applyFitScaleIfNeeded() {
        let fitScale = currentFitScale()
        guard fitScale > 0 else { return }
        scrollView.minimumZoomScale = fitScale
        if hasUserAdjustedZoom {
            if scrollView.zoomScale < fitScale {
                scrollView.zoomScale = fitScale
            }
            return
        }
        if abs(scrollView.zoomScale - fitScale) > DoubleTapZoom.scaleSlop {
            scrollView.zoomScale = fitScale
        }
    }

    private func currentFitScale() -> CGFloat {
        DoubleTapZoom.fitScale(
            boundsWidth: scrollView.bounds.width,
            contentWidth: naturalSize.width
        )
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        hasUserAdjustedZoom = true
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        hasUserAdjustedZoom = DoubleTapZoom.isZoomedIn(scale: scale, fitScale: currentFitScale())
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        refreshPickAccessibility()
        onSelectionGeometryChange?()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refreshPickAccessibility()
        onSelectionGeometryChange?()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentView
    }

    func configureSemanticPick(
        map: SemanticAnnotationMap?,
        onComment: ((SemanticTarget) -> Void)?
    ) {
        semanticMap = map
        semanticCommentHandler = onComment
        let available = map?.targets.isEmpty == false
        pickButton.isHidden = !available || usesExternalPickControls
        if !available {
            setPickMode(false)
        }
    }

    private func installPickChrome() {
        pickBanner.translatesAutoresizingMaskIntoConstraints = false
        pickBanner.numberOfLines = 0
        pickBanner.font = .preferredFont(forTextStyle: .footnote)
        pickBanner.textColor = .label
        pickBanner.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.94)
        pickBanner.layer.cornerRadius = 8
        pickBanner.clipsToBounds = true
        pickBanner.textAlignment = .center
        pickBanner.isHidden = true
        pickBanner.accessibilityIdentifier = "semantic-pick.banner"
        pickBanner.text = "Tap an object to select it. Pinch or drag to explore."
        addSubview(pickBanner)

        configurePickButton(pickButton, title: "Pick object", identifier: "semantic-pick.enter")
        pickButton.addTarget(self, action: #selector(togglePickMode), for: .touchUpInside)
        addSubview(pickButton)

        configurePickButton(commentButton, title: "Comment", identifier: "semantic-pick.comment")
        commentButton.isHidden = true
        commentButton.addTarget(self, action: #selector(commentOnSelection), for: .touchUpInside)
        addSubview(commentButton)

        chooserScrollView.translatesAutoresizingMaskIntoConstraints = false
        chooserScrollView.isHidden = true
        chooserScrollView.showsVerticalScrollIndicator = true
        chooserScrollView.alwaysBounceVertical = false
        chooserScrollView.delaysContentTouches = true
        chooserScrollView.canCancelContentTouches = true
        chooserScrollView.accessibilityIdentifier = "semantic-pick.chooser-scroll"
        addSubview(chooserScrollView)

        chooserStack.axis = .vertical
        chooserStack.spacing = 6
        chooserStack.translatesAutoresizingMaskIntoConstraints = false
        chooserStack.accessibilityIdentifier = "semantic-pick.chooser"
        chooserScrollView.addSubview(chooserStack)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handlePickTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.isEnabled = false
        contentView.addGestureRecognizer(tap)
        pickTap = tap

        NSLayoutConstraint.activate([
            pickBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pickBanner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pickBanner.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            pickButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            pickButton.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -12),
            commentButton.trailingAnchor.constraint(equalTo: pickButton.leadingAnchor, constant: -8),
            commentButton.centerYAnchor.constraint(equalTo: pickButton.centerYAnchor),
            chooserScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            chooserScrollView.bottomAnchor.constraint(equalTo: pickButton.topAnchor, constant: -8),
            chooserScrollView.widthAnchor.constraint(equalToConstant: 220),
            chooserScrollView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            chooserStack.leadingAnchor.constraint(equalTo: chooserScrollView.contentLayoutGuide.leadingAnchor),
            chooserStack.trailingAnchor.constraint(equalTo: chooserScrollView.contentLayoutGuide.trailingAnchor),
            chooserStack.topAnchor.constraint(equalTo: chooserScrollView.contentLayoutGuide.topAnchor),
            chooserStack.bottomAnchor.constraint(equalTo: chooserScrollView.contentLayoutGuide.bottomAnchor),
            chooserStack.widthAnchor.constraint(equalTo: chooserScrollView.frameLayoutGuide.widthAnchor),
        ])
        let chooserHeight = chooserScrollView.heightAnchor.constraint(equalToConstant: 0)
        chooserHeight.isActive = true
        chooserHeightConstraint = chooserHeight
    }

    private func configurePickButton(_ button: UIButton, title: String, identifier: String) {
        button.configuration = pickControlConfiguration(title: title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = identifier
        button.isHidden = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumPickControlHeight).isActive = true
    }

    private func pickControlConfiguration(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        config.background.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.94)
        config.background.cornerRadius = 8
        return config
    }

    @objc private func togglePickMode() {
        setPickMode(!pickModeEnabled)
    }

    private func setPickMode(_ enabled: Bool) {
        guard semanticMap?.targets.isEmpty == false || !enabled else { return }
        pickModeEnabled = enabled
        pickTap?.isEnabled = enabled
        // The canvas tap recognizer handles picks; the scroll view still owns
        // multi-touch zoom and pans, including while choosing an object.
        pickBanner.isHidden = !enabled
        var buttonConfig = pickButton.configuration ?? .plain()
        buttonConfig.title = enabled ? "Browse" : "Pick object"
        pickButton.configuration = buttonConfig
        pickButton.accessibilityIdentifier = enabled ? "semantic-pick.leave" : "semantic-pick.enter"
        pickButton.accessibilityLabel = enabled
            ? "Leave pick and resume pan and zoom"
            : "Pick a diagram object"
        if !enabled {
            clearSelection()
        }
        onPickStateChange?(enabled, selectedTargetID != nil)
        refreshPickAccessibility()
    }

    @objc private func handlePickTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: contentView)
        selectSemanticObject(at: point)
    }

    func setExternalPickMode(_ enabled: Bool) { setPickMode(enabled) }
    var hasSemanticTargets: Bool { semanticMap?.targets.isEmpty == false }
    var isPickingObjects: Bool { pickModeEnabled }
    var hasSelectedTarget: Bool { selectedTargetID != nil }
    func commentOnExternalSelection() { commentOnSelection() }

    private func selectSemanticObject(at layoutPoint: CGPoint) {
        guard let semanticMap, pickModeEnabled else { return }
        let tolerance = SemanticCoordinateTransform.layoutTolerance(
            screenTolerance: 12,
            zoomScale: max(scrollView.zoomScale, 0.01)
        )
        let visible = contentView.convert(scrollView.bounds, from: scrollView)
        let hit = semanticMap.hitTest(point: layoutPoint, tolerance: tolerance, clip: visible)
        showHit(hit)
    }

    private func showHit(_ hit: SemanticHitResult) {
        chooserStack.arrangedSubviews.forEach {
            chooserStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if hit.targets.count > 1 {
            selectedTargetID = nil
            highlightView.regions = []
            commentButton.isHidden = true
            onPickStateChange?(true, false)
            chooserScrollView.isHidden = false
            chooserHeightConstraint?.constant = min(320, CGFloat(hit.targets.count) * 50)
            chooserScrollView.setContentOffset(.zero, animated: false)
            for target in hit.targets {
                let button = UIButton(configuration: pickControlConfiguration(title: SemanticChooserTitle.text(for: target)))
                button.accessibilityIdentifier = "semantic-pick.choice.\(target.id)"
                button.accessibilityLabel = SemanticChooserTitle.text(for: target)
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumPickControlHeight).isActive = true
                button.addAction(UIAction { [weak self] _ in
                    self?.choose(target)
                }, for: .touchUpInside)
                chooserStack.addArrangedSubview(button)
            }
            setNeedsLayout()
            layoutIfNeeded()
            chooserScrollView.layoutIfNeeded()
            return
        }
        chooserScrollView.isHidden = true
        chooserHeightConstraint?.constant = 0
        guard let target = hit.targets.first else {
            clearSelection()
            return
        }
        choose(target)
    }

    private func choose(_ target: SemanticTarget) {
        selectedTargetID = target.id
        highlightView.regions = semanticMap?.regions.filter { $0.targetID == target.id } ?? []
        pickBanner.isHidden = true
        commentButton.isHidden = usesExternalPickControls
        onPickStateChange?(true, true)
        chooserScrollView.isHidden = true
        chooserHeightConstraint?.constant = 0
    }

    private func clearSelection() {
        selectedTargetID = nil
        highlightView.regions = []
        pickBanner.isHidden = !pickModeEnabled
        commentButton.isHidden = true
        onPickStateChange?(pickModeEnabled, false)
        chooserScrollView.isHidden = true
        chooserHeightConstraint?.constant = 0
        chooserStack.arrangedSubviews.forEach {
            chooserStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    @objc private func commentOnSelection() {
        guard let id = selectedTargetID,
              let target = semanticMap?.target(id: id) else { return }
        semanticCommentHandler?(target)
    }

    private func refreshPickAccessibility() {
        guard pickModeEnabled, let semanticMap else {
            contentView.accessibilityElements = nil
            return
        }
        let side = Self.minimumPickControlHeight / max(scrollView.zoomScale, 0.01)
        var visible = contentView.convert(scrollView.bounds, from: scrollView)
        visible.size.height = max(0, visible.height - side)
        var elements: [UIAccessibilityElement] = []
        for target in semanticMap.targets {
            guard let point = Self.accessibilityPoint(for: target.id, in: semanticMap, visible: visible) else { continue }
            let element = UIAccessibilityElement(accessibilityContainer: contentView)
            element.accessibilityIdentifier = "semantic-pick.target.\(Self.accessibilityToken(target.id))"
            element.accessibilityLabel = SemanticChooserTitle.text(for: target)
            element.accessibilityValue = target.id
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = CGRect(
                x: point.x - side / 2,
                y: point.y - side / 2,
                width: side,
                height: side
            )
            elements.append(element)
        }
        contentView.isAccessibilityElement = false
        contentView.accessibilityElements = elements
    }

    private static func accessibilityToken(_ targetID: String) -> String {
        targetID.replacingOccurrences(of: ":", with: ".")
    }

    /// Prefer a point that is on screen and inside the ink. Legend rows can sit
    /// under the pick controls; the sector or node path is the object the user sees.
    private static func accessibilityPoint(
        for targetID: String,
        in map: SemanticAnnotationMap,
        visible: CGRect
    ) -> CGPoint? {
        let regions = map.regions.filter { $0.targetID == targetID }
        let candidates = regions.compactMap { region -> (CGPoint, Int)? in
            guard let point = SemanticHitSampling.point(in: region.geometry),
                  region.geometry.contains(point, tolerance: 0) else { return nil }
            return (point, region.precedence)
        }
        if let visiblePoint = candidates
            .filter({ visible.contains($0.0) })
            .max(by: { $0.1 < $1.1 })?.0 {
            return visiblePoint
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    /// Center content on either axis when it is smaller than the viewport.
    private func centerContent() {
        let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
    }

#if DEBUG
    var debugZoomScaleForTesting: CGFloat { scrollView.zoomScale }
    var debugFitScaleForTesting: CGFloat { currentFitScale() }
    var debugDoubleTapRecognizerCountForTesting: Int {
        (scrollView.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 2 }
            .count
    }
    var debugSingleTapRecognizerCountForTesting: Int {
        (scrollView.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }
            .filter { $0.numberOfTapsRequired == 1 }
            .count
    }

    func debugToggleZoomForTesting(at pointInContent: CGPoint) {
        toggleZoom(at: pointInContent, animated: false)
    }

    var debugPickModeEnabledForTesting: Bool { pickModeEnabled }
    var debugPickScrollEnabledForTesting: Bool { scrollView.isScrollEnabled }
    var debugPickPinchEnabledForTesting: Bool { scrollView.pinchGestureRecognizer?.isEnabled == true }
    var debugSelectedTargetIDForTesting: String? { selectedTargetID }
    var debugChooserCountForTesting: Int { chooserStack.arrangedSubviews.count }
    var debugChooserTitlesForTesting: [String] {
        chooserStack.arrangedSubviews.compactMap { ($0 as? UIButton)?.accessibilityLabel }
    }
    var debugMinimumControlHeightForTesting: CGFloat { Self.minimumPickControlHeight }
    var debugCommentButtonHiddenForTesting: Bool { commentButton.isHidden }

    func debugEnterPickForTesting() {
        setPickMode(true)
    }

    func debugLeavePickForTesting() {
        setPickMode(false)
    }

    func debugSelectForTesting(at layoutPoint: CGPoint) {
        selectSemanticObject(at: layoutPoint)
    }

    func debugSelectTargetForTesting(_ id: String) {
        guard let semanticMap, let point = SemanticHitSampling.point(for: id, in: semanticMap) else { return }
        selectSemanticObject(at: point)
    }

    func debugPanForTesting(to offset: CGPoint) {
        scrollView.setContentOffset(offset, animated: false)
    }

    func debugChooseForTesting(targetID: String) {
        guard let target = semanticMap?.target(id: targetID) else { return }
        choose(target)
    }

    func debugCommentForTesting() {
        commentOnSelection()
    }
#endif
}

private final class SemanticPickHighlightView: UIView {
    var regions: [SemanticRegion] = [] {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        accessibilityIdentifier = "semantic-pick.highlight"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: SemanticPickHighlightView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !regions.isEmpty else { return }
        let stroke = UIColor.systemOrange.cgColor
        let fill = UIColor.systemOrange.withAlphaComponent(0.28).cgColor
        for region in regions {
            ctx.setStrokeColor(stroke)
            ctx.setFillColor(fill)
            ctx.setLineWidth(SemanticHighlightStyle.lineWidth(for: region.geometry))
            switch region.geometry {
            case .rectangle(let rect):
                ctx.fill(rect)
                ctx.stroke(rect)
            case .ellipse(let rect):
                ctx.fillEllipse(in: rect)
                ctx.strokeEllipse(in: rect)
            case .sector(let center, let radius, let startAngle, let endAngle):
                ctx.beginPath()
                ctx.move(to: center)
                ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                ctx.closePath()
                ctx.drawPath(using: .fillStroke)
            case .polyline(let points, _):
                guard let first = points.first else { continue }
                ctx.beginPath()
                ctx.move(to: first)
                for point in points.dropFirst() { ctx.addLine(to: point) }
                ctx.strokePath()
            case .polygon(let points):
                guard let first = points.first else { continue }
                ctx.beginPath()
                ctx.move(to: first)
                for point in points.dropFirst() { ctx.addLine(to: point) }
                ctx.closePath()
                ctx.drawPath(using: .fillStroke)
            case .path(let path):
                ctx.addPath(path.cgPath())
                ctx.drawPath(using: .fillStroke)
            case .strokedPath(let path, _):
                ctx.addPath(path.cgPath())
                ctx.strokePath()
            }
        }
    }
}
