import SwiftUI
import TipKit
import UIKit

/// Header-only element. Body controls stay siblings so expansion does not hide them.
final class ToolTimelineHeaderElement: UIAccessibilityElement {
    var onActivate: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        onActivate?() ?? false
    }

    func apply(
        configuration: ToolTimelineRowConfiguration,
        onActivate: (() -> Bool)?,
        customActions: [UIAccessibilityCustomAction]?
    ) {
        accessibilityIdentifier = "chat.timeline.row.\(configuration.itemID).header"
        accessibilityLabel = Self.spokenLabel(configuration)
        let execution = Self.executionState(configuration)
        if onActivate != nil {
            let expansion = configuration.isExpanded
                ? String(localized: "Expanded")
                : String(localized: "Collapsed")
            accessibilityValue = "\(execution), \(expansion)"
            accessibilityTraits = .button
        } else {
            accessibilityValue = execution
            accessibilityTraits = []
        }
        self.onActivate = onActivate
        accessibilityCustomActions = customActions
        // Frame is measured from the title band. Do not advertise the body here.
    }

    func reset() {
        onActivate = nil
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityTraits = []
        accessibilityCustomActions = nil
        accessibilityFrameInContainerSpace = .zero
    }

    func updateMeasuredFrame(
        borderWidth: CGFloat,
        titleMaxY: CGFloat,
        statusMaxY: CGFloat,
        excludedFrames: [CGRect]
    ) {
        // Title band only. Do not clip to the body stack origin: that frame
        // can start at the border top and erase the header.
        let bandBottom = max(titleMaxY, statusMaxY)
        var frame = CGRect(x: 0, y: 0, width: max(0, borderWidth), height: max(0, bandBottom))
        for excluded in excludedFrames where excluded.width > 1 && excluded.height > 1 && frame.intersects(excluded) {
            let overlap = frame.intersection(excluded)
            if overlap.minY > frame.minY + 1 {
                frame.size.height = max(0, overlap.minY - frame.minY)
            } else if overlap.minX > frame.minX + 1 {
                frame.size.width = max(0, overlap.minX - frame.minX)
            } else if excluded.minX > 1 {
                frame.size.width = max(0, min(frame.width, excluded.minX - frame.minX))
            }
        }
        accessibilityFrameInContainerSpace = frame
    }

    private static func spokenLabel(_ configuration: ToolTimelineRowConfiguration) -> String {
        let summary = configuration.headerAccessibilitySummary
            ?? configuration.segmentAttributedTitle?.string
            ?? configuration.title
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Tool") : trimmed
    }

    private static func executionState(_ configuration: ToolTimelineRowConfiguration) -> String {
        if configuration.isInterrupted { return String(localized: "Interrupted") }
        if configuration.isError { return String(localized: "Failed") }
        if configuration.isDone { return String(localized: "Completed") }
        return String(localized: "Running")
    }
}

/// Lightweight collapsed tool chrome. Expanded rows and voice-while-collapsed
/// keep `ToolTimelineRowConfiguration` so they can still render content.
struct CollapsedToolTimelineRowConfiguration: UIContentConfiguration {
    let chrome: ToolTimelineRowConfiguration

    func makeContentView() -> any UIView & UIContentView {
        CollapsedToolTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

/// Chrome-only content view: status, icon, title, badge, trailing/diff,
/// elapsed, and the feature-education tip. No expanded surfaces, fetchers,
/// or output descriptors.
final class CollapsedToolTimelineRowContentView: UIView, UIContentView {
    private let statusImageView = UIImageView()
    private let toolImageView = UIImageView()
    private let titleLabel = UILabel()
    private let trailingStack = UIStackView()
    private let languageBadgeIconView = UIImageView()
    private let addedLabel = UILabel()
    private let removedLabel = UILabel()
    private let trailingLabel = UILabel()
    private let elapsedLabel = UILabel()
    private let bodyStack = UIStackView()
    private let borderView = UIView()
    private lazy var headerElement = ToolTimelineHeaderElement(accessibilityContainer: borderView)
    private let featureTipPresentationOwnerID = UUID()

    private var currentConfiguration: CollapsedToolTimelineRowConfiguration
    private var bodyStackCollapsedHeightConstraint: NSLayoutConstraint?
    private var toolLeadingConstraint: NSLayoutConstraint?
    private var toolWidthConstraint: NSLayoutConstraint?
    private var titleLeadingToStatusConstraint: NSLayoutConstraint?
    private var titleLeadingToToolConstraint: NSLayoutConstraint?
    nonisolated(unsafe) private var elapsedTimer: Timer?
    private var featureTipView: FeatureEducationTipBannerView?
    private var featureTipID: String?

    init(configuration: CollapsedToolTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        elapsedTimer?.invalidate()
        if let featureTipID {
            let ownerID = featureTipPresentationOwnerID
            Task { @MainActor in
                ToolTimelineRowContentView.activeInlineFeatureTipIDs.remove(featureTipID)
                FeatureEducationTipPresentationCoordinator.shared.release(
                    tipID: featureTipID,
                    ownerID: ownerID
                )
            }
        }
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? CollapsedToolTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            clearInlineFeatureEducationTip()
            return
        }
        scheduleFeatureEducationTipIfNeeded(configuration: currentConfiguration.chrome)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if ToolTimelineRowDisplayState.updateCollapsedFileTitleForCurrentWidth(
            configuration: currentConfiguration.chrome,
            titleLabel: titleLabel,
            availableWidth: collapsedTitleAvailableWidth()
        ) {
            super.layoutSubviews()
        }
        updateHeaderAccessibilityFrame()
    }

    func resetHeaderAccessibility() {
        headerElement.reset()
        borderView.accessibilityElements = nil
        borderView.accessibilityElementsHidden = false
        accessibilityElementsHidden = false
        accessibilityCustomActions = nil
    }

    private func updateHeaderAccessibilityFrame() {
        headerElement.updateMeasuredFrame(
            borderWidth: borderView.bounds.width,
            titleMaxY: titleLabel.frame.maxY,
            statusMaxY: statusImageView.frame.maxY,
            excludedFrames: headerExcludedFrames()
        )
    }

    private func headerExcludedFrames() -> [CGRect] {
        guard !bodyStack.isHidden, bodyStack.bounds.height > 1 else { return [] }
        return [bodyStack.convert(bodyStack.bounds, to: borderView).insetBy(dx: 0, dy: -4)]
    }

    private func refreshHeaderAccessibility() {
        let showBody = featureTipView != nil
        if showBody {
            bodyStackCollapsedHeightConstraint?.isActive = false
            bodyStack.isHidden = false
        }
        borderView.isAccessibilityElement = false
        bodyStack.isAccessibilityElement = false
        borderView.accessibilityElements = showBody ? [headerElement, bodyStack] : [headerElement]
        updateHeaderAccessibilityFrame()
    }

    private func setupViews() {
        backgroundColor = .clear
        ToolTimelineRowViewStyler.styleBorderView(borderView)
        addSubview(borderView)

        ToolTimelineRowViewStyler.styleHeader(
            statusImageView: statusImageView,
            toolImageView: toolImageView,
            titleLabel: titleLabel,
            trailingStack: trailingStack,
            languageBadgeIconView: languageBadgeIconView,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel,
            elapsedLabel: elapsedLabel
        )

        trailingStack.addArrangedSubview(elapsedLabel)
        trailingStack.addArrangedSubview(addedLabel)
        trailingStack.addArrangedSubview(removedLabel)
        trailingStack.addArrangedSubview(trailingLabel)
        trailingStack.addArrangedSubview(languageBadgeIconView)

        bodyStackCollapsedHeightConstraint = ToolTimelineRowViewStyler.styleBodyStack(bodyStack)

        borderView.addSubview(statusImageView)
        borderView.addSubview(toolImageView)
        borderView.addSubview(titleLabel)
        borderView.addSubview(trailingStack)
        borderView.addSubview(bodyStack)
        borderView.isAccessibilityElement = false
        bodyStack.isAccessibilityElement = false
        isAccessibilityElement = false

        let layout = ToolTimelineRowLayoutBuilder.makeCollapsedChromeConstraints(
            containerView: self,
            borderView: borderView,
            statusImageView: statusImageView,
            toolImageView: toolImageView,
            titleLabel: titleLabel,
            trailingStack: trailingStack,
            bodyStack: bodyStack
        )
        toolLeadingConstraint = layout.toolLeading
        toolWidthConstraint = layout.toolWidth
        titleLeadingToStatusConstraint = layout.titleLeadingToStatus
        titleLeadingToToolConstraint = layout.titleLeadingToTool
        NSLayoutConstraint.activate(
            ToolTimelineRowLayoutBuilder.makeLanguageBadgeConstraints(
                languageBadgeIconView: languageBadgeIconView
            ) + layout.all
        )
    }

    private func apply(configuration: CollapsedToolTimelineRowConfiguration) {
        currentConfiguration = configuration
        let chrome = configuration.chrome

        ToolTimelineRowViewStyler.applyChromeTheme(
            statusImageView: statusImageView,
            toolImageView: toolImageView,
            titleLabel: titleLabel,
            languageBadgeIconView: languageBadgeIconView,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel,
            elapsedLabel: elapsedLabel
        )

        ToolTimelineRowDisplayState.applyTitle(
            configuration: chrome,
            titleLabel: titleLabel
        )
        applyToolIcon(
            toolNamePrefix: chrome.glyph,
            toolNameColor: chrome.toolNameColor
        )
        ToolTimelineRowDisplayState.applyLanguageBadge(
            badge: chrome.languageBadge,
            languageBadgeIconView: languageBadgeIconView
        )
        ToolTimelineRowDisplayState.applyTrailing(
            configuration: chrome,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel
        )
        ToolTimelineRowDisplayState.applyElapsed(
            startedAt: chrome.startedAt,
            elapsedSeconds: chrome.elapsedSeconds,
            isDone: chrome.isDone,
            elapsedLabel: elapsedLabel
        )
        ToolTimelineRowDisplayState.updateTrailingVisibility(
            trailingStack: trailingStack,
            languageBadgeIconView: languageBadgeIconView,
            addedLabel: addedLabel,
            removedLabel: removedLabel,
            trailingLabel: trailingLabel,
            elapsedLabel: elapsedLabel
        )

        if ToolTimelineRowDisplayState.updateCollapsedFileTitleForCurrentWidth(
            configuration: chrome,
            titleLabel: titleLabel,
            availableWidth: collapsedTitleAvailableWidth()
        ) {
            setNeedsLayout()
        }

        ToolTimelineRowDisplayState.applyStatusAppearance(
            isDone: chrome.isDone,
            isError: chrome.isError,
            isInterrupted: chrome.isInterrupted,
            statusImageView: statusImageView,
            borderView: borderView
        )

        updateElapsedTimer(configuration: chrome)
        scheduleFeatureEducationTipIfNeeded(configuration: chrome)
        let showBody = featureTipView != nil
        bodyStackCollapsedHeightConstraint?.isActive = !showBody
        bodyStack.isHidden = !showBody
        headerElement.apply(configuration: chrome, onActivate: chrome.onHeaderActivate, customActions: nil)
        refreshHeaderAccessibility()
    }

    private func applyToolIcon(toolNamePrefix: String?, toolNameColor: UIColor) {
        guard let symbolName = toolNamePrefix,
              let baseImage = UIImage(systemName: symbolName) else {
            toolImageView.image = nil
            toolImageView.isHidden = true
            toolLeadingConstraint?.constant = 0
            toolWidthConstraint?.constant = 0
            titleLeadingToToolConstraint?.isActive = false
            titleLeadingToStatusConstraint?.isActive = true
            return
        }

        let configuredImage = baseImage.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        toolImageView.image = configuredImage
        toolImageView.tintColor = toolNameColor
        toolImageView.isHidden = false
        toolLeadingConstraint?.constant = 5
        toolWidthConstraint?.constant = 12
        titleLeadingToStatusConstraint?.isActive = false
        titleLeadingToToolConstraint?.isActive = true
    }

    private func collapsedTitleAvailableWidth() -> CGFloat {
        let containerWidth = max(borderView.bounds.width, bounds.width)
        let titleMinX = titleLabel.frame.minX
        let rightLimit: CGFloat
        if trailingStack.isHidden {
            rightLimit = containerWidth - 14
        } else {
            let fittingWidth = trailingStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
            let trailingWidth = max(trailingStack.bounds.width, fittingWidth)
            rightLimit = containerWidth - 8 - trailingWidth - 6
        }
        return max(0, rightLimit - titleMinX)
    }

    private func updateElapsedTimer(configuration: ToolTimelineRowConfiguration) {
        let needsTimer = configuration.startedAt != nil && !configuration.isDone
        if needsTimer, let startedAt = configuration.startedAt {
            if elapsedTimer != nil { return }
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    ToolTimelineRowDisplayState.applyElapsed(
                        startedAt: startedAt,
                        elapsedSeconds: nil,
                        isDone: false,
                        elapsedLabel: self.elapsedLabel
                    )
                }
            }
        } else {
            elapsedTimer?.invalidate()
            elapsedTimer = nil
        }
    }

    private func scheduleFeatureEducationTipIfNeeded(configuration: ToolTimelineRowConfiguration) {
        guard configuration.isDone,
              !configuration.isExpanded,
              !configuration.isInteractive else {
            clearInlineFeatureEducationTip()
            return
        }
        showInlineFeatureEducationTip(
            FeatureEducationTips.OpenToolDetailsTip(),
            descriptor: FeatureEducationTips.openToolDetails
        )
    }

    private func showInlineFeatureEducationTip<TipType: Tip>(
        _ tip: TipType,
        descriptor: FeatureEducationTipDescriptor
    ) {
#if DEBUG
        let force = ToolTimelineRowContentView.forcesInlineFeatureTipsForTesting
            || ProcessInfo.processInfo.arguments.contains("--show-feature-tips-for-testing")
        let shouldDisplay = tip.shouldDisplay || force
#else
        let force = false
        let shouldDisplay = tip.shouldDisplay
#endif
        guard shouldDisplay else {
            if featureTipID == descriptor.id { clearInlineFeatureEducationTip() }
            return
        }
        if featureTipID == descriptor.id, featureTipView?.superview === bodyStack { return }
        guard !ToolTimelineRowContentView.activeInlineFeatureTipIDs.contains(descriptor.id) else { return }
        guard FeatureEducationTipPresentationCoordinator.shared.claim(
            tipID: descriptor.id,
            ownerID: featureTipPresentationOwnerID,
            force: force
        ) else { return }

        clearInlineFeatureEducationTip()

        let tipView = FeatureEducationTipBannerView()
        let tipToClose = tip
        tipView.configure(descriptor: descriptor) { [weak self] in
            tipToClose.invalidate(reason: .tipClosed)
            self?.clearInlineFeatureEducationTip()
        }
        tipView.translatesAutoresizingMaskIntoConstraints = false
        featureTipView = tipView
        featureTipID = descriptor.id
        ToolTimelineRowContentView.activeInlineFeatureTipIDs.insert(descriptor.id)
        bodyStack.insertArrangedSubview(tipView, at: 0)
        bodyStackCollapsedHeightConstraint?.isActive = false
        bodyStack.isHidden = false
        refreshHeaderAccessibility()
        invalidateLayoutForFeatureEducationTipSizeChange()
    }

    private func clearInlineFeatureEducationTip() {
        guard let featureTipView else { return }
        bodyStack.removeArrangedSubview(featureTipView)
        featureTipView.removeFromSuperview()
        if let featureTipID {
            ToolTimelineRowContentView.activeInlineFeatureTipIDs.remove(featureTipID)
            FeatureEducationTipPresentationCoordinator.shared.release(
                tipID: featureTipID,
                ownerID: featureTipPresentationOwnerID
            )
        }
        self.featureTipView = nil
        featureTipID = nil
        bodyStackCollapsedHeightConstraint?.isActive = true
        bodyStack.isHidden = true
        refreshHeaderAccessibility()
        invalidateLayoutForFeatureEducationTipSizeChange()
    }

    private func invalidateLayoutForFeatureEducationTipSizeChange() {
#if DEBUG
        ToolTimelineRowContentView.featureEducationTipLayoutInvalidationHookForTesting?()
#endif
        setNeedsLayout()
        ToolTimelineRowPresentationHelpers.invalidateEnclosingCollectionViewLayout(startingAt: self)
    }
}
