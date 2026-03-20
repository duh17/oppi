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
private final class SafeSizingCell: UICollectionViewCell {
    private static let maxValidHeight: CGFloat = 10_000
    private static let fallbackHeight: CGFloat = 44

    /// UIKit resets contentView.clipsToBounds when applying content
    /// configurations. Override layoutSubviews — which fires after every
    /// configuration change — to enforce clipping. Without this, cell
    /// content overflows into adjacent cells when the compositional
    /// layout hasn't resolved estimated heights to actual heights yet
    /// (e.g., during streaming when layoutIfNeeded is skipped).
    override func layoutSubviews() {
        super.layoutSubviews()
        if !contentView.clipsToBounds {
            contentView.clipsToBounds = true
        }
    }

    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard let attributes = layoutAttributes.copy() as? UICollectionViewLayoutAttributes else {
            return layoutAttributes
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

        attributes.size = CGSize(width: width, height: height)
        return attributes
    }
}

// MARK: - Data Source Configuration

extension ChatTimelineCollectionHost.Controller {
    func configureDataSource(collectionView: UICollectionView) {
        self.collectionView = collectionView
        collectionView.delegate = self

        let assistantRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
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

        let permissionRegistration = UICollectionView.CellRegistration<SafeSizingCell, String> { [weak self] cell, _, itemID in
            self?.configureNativeCell(
                cell,
                itemID: itemID,
                rowLabel: "permission"
            ) { item in
                self?.permissionRowConfiguration(item: item)
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
                renderWindowStep: self.renderWindowStep,
                onTap: { [weak self] in self?.onShowEarlier?() },
                themeID: self.currentThemeID
            )
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            ChatTimelinePerf.recordCellConfigure(
                rowType: "load_more",
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

            cell.contentConfiguration = WorkingIndicatorTimelineRowConfiguration(themeID: self.currentThemeID)
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
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
            permission: { collectionView, indexPath, itemID in
                collectionView.dequeueConfiguredReusableCell(
                    using: permissionRegistration,
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
        if let toolConfig = nativeConfig as? ToolTimelineRowConfiguration,
           case .toolCall(_, let tool, _, _, let outputByteCount, _, _) = item {
            toolContext = ChatTimelinePerf.ToolCellContext(
                tool: tool,
                isExpanded: toolConfig.isExpanded,
                contentType: toolConfig.expandedContent.map(Self.contentTypeName) ?? "collapsed",
                outputBytes: outputByteCount
            )
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
        case .plot: return "plot"
        case .readMedia: return "readMedia"
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
        fallback.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        fallback.textProperties.color = UIColor(Color.themeOrange)
        fallback.secondaryTextProperties.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fallback.secondaryTextProperties.color = UIColor(Color.themeComment)
        cell.contentConfiguration = fallback
        cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
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
