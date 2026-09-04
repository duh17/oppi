import SwiftUI
import UIKit

// MARK: - Safe-sizing cell

/// UICollectionViewCell subclass that bypasses UIKit's content-view size
/// assertion entirely.
///
/// **The problem:** `UICollectionViewCell.systemLayoutSizeFitting` internally
/// calls `systemLayoutSizeFitting` on the *UIContentView*, checks the result,
/// and throws `NSInternalInconsistencyException` if it's non-finite (DBL_MAX).
/// This happens when a content view's constraints are momentarily ambiguous
/// (e.g. during initial cell configuration). Overriding `systemLayoutSizeFitting`
/// on the cell doesn't help because the assertion fires inside UIKit's private
/// code path *before* calling the cell's method.
///
/// **The fix:** Override `preferredLayoutAttributesFittingAttributes:` — the
/// method that UIKit calls to get self-sizing dimensions. This is the CALLER
/// of `systemLayoutSizeFitting`. By overriding it, we compute the size
/// ourselves (via `contentView.systemLayoutSizeFitting`) and clamp the result,
/// completely bypassing the assertion path in `UICollectionViewCell`.
final class SafeSizingCell: UICollectionViewCell {
    /// High ceiling that still protects against bogus/non-finite layout output
    /// while allowing legitimately massive timeline rows (for example, a very
    /// long assistant markdown reply) to self-size correctly.
    private static let maxValidHeight: CGFloat = 1_000_000
    private static let fallbackHeight: CGFloat = 44

    /// When true, `preferredLayoutAttributesFitting` uses a cached height on
    /// alternate calls to avoid the O(total) `systemLayoutSizeFitting` text
    /// layout cost on every streaming tick. Between recomputations,
    /// the cached height accommodates the full text layout — UITextView
    /// lays out all characters regardless of visibility.
    var isStreamingAssistant = false
    var cachedStreamingHeight: CGFloat?
    /// Last time preferredLayoutAttributesFitting did a full computation.
    /// Used to throttle self-sizing during streaming — recompute periodically
    /// instead of every streaming tick. Between recomputations, text appends add
    /// only a few lines, and structural markdown changes explicitly invalidate
    /// the cache.
    var lastFullSizeComputeNs: UInt64 = 0
    /// Minimum interval between full self-sizing computations during streaming.
    /// Text-only tail growth can reuse the previous height briefly; structural
    /// changes still call `invalidateStreamingHeightCache()` for immediate sizing.
    private static let streamingSizeThrottleNs: UInt64 = 340_000_000 // 340ms

    private let navigationHighlightOverlay = UIView()
    private var navigationHighlightToken: UInt = 0
    private var preparationItemID: String?
    private var cancelPreparationDemand: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Cell-level clipping: UIKit resets contentView.clipsToBounds when
        // applying content configurations, but does NOT reset the cell's own
        // clipsToBounds. Setting it here provides persistent overflow
        // protection even when layoutSubviews hasn't fired yet (e.g. during
        // streaming when layoutIfNeeded is skipped and cells still have
        // estimated heights from the timeline layout).
        clipsToBounds = true
        contentView.clipsToBounds = true
        configureNavigationHighlightOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        // The sizing cache belongs to the current item, not the reusable cell.
        // Without clearing it here, a short streaming row can constrain a tall
        // wrapped-table row after UIKit recycles the cell.
        isStreamingAssistant = false
        invalidateStreamingHeightCache()
        cancelTimelinePreparationDemand()
    }

    func bindTimelinePreparationDemand(
        itemID: String,
        cancel: @escaping () -> Void
    ) {
        guard preparationItemID != itemID else { return }
        cancelTimelinePreparationDemand()
        preparationItemID = itemID
        cancelPreparationDemand = cancel
    }

    func cancelTimelinePreparationDemand() {
        cancelPreparationDemand?()
        cancelPreparationDemand = nil
        preparationItemID = nil
    }

    private func configureNavigationHighlightOverlay() {
        navigationHighlightOverlay.isUserInteractionEnabled = false
        navigationHighlightOverlay.alpha = 0
        navigationHighlightOverlay.backgroundColor = UIColor(Color.themeBlue).withAlphaComponent(0.18)
        navigationHighlightOverlay.layer.borderColor = UIColor(Color.themeBlue).withAlphaComponent(0.9).cgColor
        navigationHighlightOverlay.layer.borderWidth = 2
        navigationHighlightOverlay.layer.cornerRadius = 14
        navigationHighlightOverlay.layer.zPosition = 10_000
        navigationHighlightOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(navigationHighlightOverlay)
        NSLayoutConstraint.activate([
            navigationHighlightOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            navigationHighlightOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            navigationHighlightOverlay.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            navigationHighlightOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
        ])
    }

    func ensureNavigationHighlightOverlayFrontmost() {
        contentView.bringSubviewToFront(navigationHighlightOverlay)
    }

    func performNavigationHighlight(token: UInt) {
        navigationHighlightToken = token
        ensureNavigationHighlightOverlayFrontmost()
        navigationHighlightOverlay.layer.removeAllAnimations()
        navigationHighlightOverlay.alpha = 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.navigationHighlightToken == token else { return }
            UIView.animate(
                withDuration: 1.2,
                delay: 0,
                options: [.allowUserInteraction, .curveEaseOut]
            ) {
                self.navigationHighlightOverlay.alpha = 0
            }
        }
    }

    #if DEBUG
        var isShowingNavigationHighlightForTesting: Bool {
            navigationHighlightOverlay.alpha > 0.01
        }

        var isNavigationHighlightOverlayFrontmostForTesting: Bool {
            let maxOtherZ = contentView.subviews
                .filter { $0 !== navigationHighlightOverlay }
                .map(\.layer.zPosition)
                .max() ?? -.greatestFiniteMagnitude
            return contentView.subviews.last === navigationHighlightOverlay
                || navigationHighlightOverlay.layer.zPosition > maxOtherZ
        }
    #endif

    /// Safety net: re-enforce contentView clipping after UIKit resets it
    /// during content configuration changes.
    override func layoutSubviews() {
        super.layoutSubviews()
        if !contentView.clipsToBounds {
            contentView.clipsToBounds = true
        }
        ensureNavigationHighlightOverlayFrontmost()
    }

    func invalidateStreamingHeightCache() {
        cachedStreamingHeight = nil
        lastFullSizeComputeNs = 0
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard let attributes = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else {
            return layoutAttributes
        }

        // Streaming throttle: avoid full self-sizing on every tick. Text-only
        // tail growth reuses the cached height briefly; structural markdown
        // changes clear the cache before the next sizing pass.
        if isStreamingAssistant, let cached = cachedStreamingHeight {
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastFullSizeComputeNs < Self.streamingSizeThrottleNs {
                attributes.size = CGSize(width: attributes.size.width, height: cached)
                return attributes
            }
        }

        let targetSize = CGSize(
            width: attributes.size.width,
            height: UIView.layoutFittingCompressedSize.height
        )

        // Size the cell's contentView directly. This triggers auto layout on
        // all subviews (including the UIContentView) without going through
        // UICollectionViewCell's assertion-guarded systemLayoutSizeFitting.
        let fitted = contentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .defaultLow
        )

        let width = attributes.size.width
        let height: CGFloat
        if fitted.height.isFinite && fitted.height > 0 {
            height = min(fitted.height, Self.maxValidHeight)
        } else {
            height = Self.fallbackHeight
        }

        let resolvedHeight: CGFloat
        if isStreamingAssistant {
            // While text is streaming, never let self-sizing estimates shrink
            // the cell. Shrink/grow oscillation turns TextKit/layout noise into
            // visible outer-scroll bounce. The final non-streaming configure
            // clears this cache and allows one settled measurement.
            resolvedHeight = max(cachedStreamingHeight ?? 0, height)
            cachedStreamingHeight = resolvedHeight
            lastFullSizeComputeNs = DispatchTime.now().uptimeNanoseconds
        } else {
            resolvedHeight = height
        }

        attributes.size = CGSize(width: width, height: resolvedHeight)
        return attributes
    }
}

// MARK: - Data Source Configuration

extension ChatTimelineCollectionHost.Controller {
    func configureDataSource(collectionView: UICollectionView) {
        self.collectionView = collectionView
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        // Constraint changes (tool expand, mermaid settle) must republish
        // height through the cached-height layout without a full estimated
        // cascade. Tests that skip makeUIView still go through this path.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints

        let assistantRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            cell.bindTimelinePreparationDemand(itemID: itemID) { [weak self] in
                self?.preparationRunway.cancel(itemID: itemID, demand: .visible)
            }
            // Set streaming flag for self-sizing throttle. When streaming,
            // the cell skips expensive auto layout on alternate ticks.
            let isStreaming = self?.isAssistantStreamingPresentationActive == true
                && self?.streamingAssistantID == itemID
            cell.isStreamingAssistant = isStreaming
            if !isStreaming {
                cell.invalidateStreamingHeightCache()
            }
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "assistant"
            ) { item in
                self?.assistantRowConfiguration(itemID: itemID, item: item)
            }
        }

        let userRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "user"
            ) { item in
                self?.userRowConfiguration(itemID: itemID, item: item)
            }
        }

        let thinkingRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "thinking"
            ) { item in
                self?.thinkingRowConfiguration(itemID: itemID, item: item)
            }
        }

        let toolRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "tool"
            ) { item in
                self?.toolRowConfiguration(itemID: itemID, item: item)
            }
        }

        let audioRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "audio"
            ) { item in
                self?.audioRowConfiguration(item: item)
            }
        }

        let systemRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "system"
            ) { item in
                self?.systemEventRowConfiguration(itemID: itemID, item: item)
            }
        }

        let compactionRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "compaction"
            ) { item in
                self?.systemEventRowConfiguration(itemID: itemID, item: item)
            }
        }

        let errorRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "error"
            ) { item in
                self?.errorRowConfiguration(item: item)
            }
        }

        let missingItemRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, _ in
            self?.applyNativeFrictionRow(
                to: cell,
                title: "\u{26a0}\u{fe0f} Timeline row unavailable",
                detail: "Timeline item missing from snapshot.",
                rowType: "placeholder"
            )
        }

        let loadMoreRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, _ in
            let configureStartNs = ChatTimelinePerf.timestampNs()
            guard let self else {
                ChatTimelinePerf.recordCellConfigure(
                    rowType: "load_more",
                    durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                )
                return
            }

            cell.contentConfiguration = LoadMoreTimelineRowConfiguration(
                hiddenCount: self.hiddenCount,
                hasOlderServerPage: self.hasOlderServerPage,
                renderWindowStep: self.renderWindowStep,
                onTap: { [weak self] in self?.onShowEarlier?() }
            )
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.contentView.clipsToBounds = true
            ChatTimelinePerf.recordCellConfigure(
                rowType: "load_more",
                durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
            )
        }

        let quietWorkRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            let configureStartNs = ChatTimelinePerf.timestampNs()
            guard let self,
                  let workLine = self.currentWorkLineByID[itemID] else {
                self?.applyNativeFrictionRow(
                    to: cell,
                    title: "Work row unavailable",
                    detail: "Synthetic quiet-mode row missing from snapshot.",
                    rowType: "quiet_work_placeholder",
                    startNs: configureStartNs
                )
                return
            }

            cell.contentConfiguration = QuietWorkLineTimelineRowConfiguration(
                workLine: workLine,
                onTap: { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    self.toggleQuietWorkLine(workLine, in: collectionView)
                }
            )
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.contentView.clipsToBounds = true
            ChatTimelinePerf.recordCellConfigure(
                rowType: "quiet_work",
                durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
            )
        }

        let workingRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, _ in
            let configureStartNs = ChatTimelinePerf.timestampNs()
            guard let self else {
                ChatTimelinePerf.recordCellConfigure(
                    rowType: "working_indicator",
                    durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
                )
                return
            }

            let modelId = self.currentModel
            cell.contentConfiguration = WorkingIndicatorTimelineRowConfiguration(
                modelId: modelId,
                workingState: self.currentExtensionWorkingState
            )
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.contentView.clipsToBounds = true
            ChatTimelinePerf.recordCellConfigure(
                rowType: "working_indicator",
                durationMs: ChatTimelinePerf.elapsedMs(since: configureStartNs)
            )
        }

        let registrations = TimelineCellFactory.Registrations(
            assistant: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: assistantRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            user: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: userRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            thinking: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: thinkingRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            tool: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: toolRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            audio: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: audioRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            system: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: systemRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            compaction: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: compactionRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            error: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: errorRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            missingItem: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: missingItemRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            loadMore: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: loadMoreRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            working: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: workingRegistration,
                    for: indexPath,
                    item: itemID
                )
            },
            quietWork: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: quietWorkRegistration,
                    for: indexPath,
                    item: itemID
                )
            }
        )

        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, itemID in
            TimelineCellFactory.dequeueCell(
                collectionView: collectionView,
                indexPath: indexPath,
                itemID: itemID,
                itemByID: self?.currentItemByID ?? [:],
                registrations: registrations,
                isCompactionMessage: { message in
                    Self.compactionPresentation(from: message) != nil
                }
            )
        }
    }

    // MARK: - Cell Configuration Helpers

    private func configureNativeCell(
        _ cell: SafeSizingCell,
        itemID: String,
        rowLabel: String,
        builder: (ChatItem) -> (any UIContentConfiguration)?
    ) {
        let configureStartNs = ChatTimelinePerf.timestampNs()
        cell.accessibilityIdentifier = "chat.timeline.row.\(itemID)"

        guard let item = currentItemByID[itemID],
              toolOutputStore != nil,
              reducer != nil,
              toolArgsStore != nil,
              toolDetailsStore != nil,
              connection != nil,
              audioPlayer != nil
        else {
            applyNativeFrictionRow(
                to: cell,
                title: "\u{26a0}\u{fe0f} Timeline row unavailable",
                detail: "Native timeline dependencies missing.",
                rowType: "placeholder",
                startNs: configureStartNs
            )
            return
        }

        guard let nativeConfig = builder(item) else {
            Self.reportNativeRendererGap("Native \(rowLabel) configuration missing.")
            applyNativeFrictionRow(
                to: cell,
                title: "\u{26a0}\u{fe0f} Native \(rowLabel) row unavailable",
                detail: "Native \(rowLabel) renderer gap.",
                rowType: "\(rowLabel)_native_failsafe",
                startNs: configureStartNs
            )
            return
        }

        let toolContext: ChatTimelinePerf.ToolCellContext?
        if case .toolCall(_, let tool, _, _, let outputByteCount, _, _) = item {
            if let toolConfig = nativeConfig as? ToolTimelineRowConfiguration {
                toolContext = ChatTimelinePerf.ToolCellContext(
                    tool: tool,
                    isExpanded: toolConfig.isExpanded,
                    contentType: toolConfig.expandedContent.map(Self.contentTypeName) ?? "collapsed",
                    outputBytes: outputByteCount
                )
            } else if nativeConfig is CollapsedToolTimelineRowConfiguration {
                toolContext = ChatTimelinePerf.ToolCellContext(
                    tool: tool,
                    isExpanded: false,
                    contentType: "collapsed",
                    outputBytes: outputByteCount
                )
            } else {
                toolContext = nil
            }
        } else {
            toolContext = nil
        }

        applyNativeRow(
            to: cell,
            configuration: nativeConfig,
            rowType: "\(rowLabel)_native",
            startNs: configureStartNs,
            toolContext: toolContext
        )
    }

    private static func contentTypeName(
        _ content: ToolPresentationBuilder.ToolExpandedContent
    ) -> String {
        switch content {
        case .bash: return "bash"
        case .diff: return "diff"
        case .code: return "code"
        case .markdown: return "markdown"
        case .readMedia: return "readMedia"
        case .audioMessage: return "audioMessage"
        case .status: return "status"
        case .text: return "text"
        }
    }

    private func applyNativeRow(
        to cell: SafeSizingCell,
        configuration: any UIContentConfiguration,
        rowType: String,
        startNs: UInt64,
        toolContext: ChatTimelinePerf.ToolCellContext? = nil
    ) {
        cell.contentConfiguration = configuration
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        // Re-enforce clipping immediately — UIKit resets contentView.clipsToBounds
        // when applying content configurations, and layoutSubviews won't fire until
        // the next display link tick. Without this, cells overflow during streaming
        // when layoutIfNeeded is skipped.
        cell.contentView.clipsToBounds = true
        ChatTimelinePerf.recordCellConfigure(
            rowType: rowType,
            durationMs: ChatTimelinePerf.elapsedMs(since: startNs),
            toolContext: toolContext
        )
    }

    private func applyNativeFrictionRow(
        to cell: SafeSizingCell,
        title: String,
        detail: String,
        rowType: String,
        startNs: UInt64 = ChatTimelinePerf.timestampNs()
    ) {
        var fallback = UIListContentConfiguration.subtitleCell()
        fallback.text = title
        fallback.secondaryText = detail
        fallback.textProperties.font = AppFont.monoMediumSemibold
        fallback.textProperties.color = UIColor(Color.themeOrange)
        fallback.secondaryTextProperties.font = AppFont.mono
        fallback.secondaryTextProperties.color = UIColor(Color.themeComment)
        cell.contentConfiguration = fallback
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
        cell.contentView.clipsToBounds = true
        ChatTimelinePerf.recordCellConfigure(
            rowType: rowType,
            durationMs: ChatTimelinePerf.elapsedMs(since: startNs)
        )
    }

    private static func reportNativeRendererGap(_ message: String) {
        #if DEBUG
            NSLog("\u{26a0}\u{fe0f} [TimelineNativeGap] %@", message)
        #endif
    }
}
