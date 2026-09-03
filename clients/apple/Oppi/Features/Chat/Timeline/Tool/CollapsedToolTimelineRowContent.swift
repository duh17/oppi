import SwiftUI
import TipKit
import UIKit

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
    private let featureTipPresentationOwnerID = UUID()

    private var currentConfiguration: CollapsedToolTimelineRowConfiguration
    private var bodyStackCollapsedHeightConstraint: NSLayoutConstraint?
    private var toolLeadingConstraint: NSLayoutConstraint?
    private var toolWidthConstraint: NSLayoutConstraint?
    private var titleLeadingToStatusConstraint: NSLayoutConstraint?
    private var titleLeadingToToolConstraint: NSLayoutConstraint?
    private var elapsedTimer: Timer?
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
            toolNamePrefix: chrome.toolNamePrefix,
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
    }

    private func applyToolIcon(toolNamePrefix: String?, toolNameColor: UIColor) {
        guard let symbolName = ToolTimelineRowUIHelpers.toolSymbolName(for: toolNamePrefix),
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
              configuration.toolNamePrefix?.localizedCaseInsensitiveCompare("ask") != .orderedSame else {
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
