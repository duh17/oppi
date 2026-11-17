import UIKit

/// Horizontal strip of pending image tiles and file pills.
final class ComposerAttachmentStripView: UIView {
    var onAnnotate: ((PendingAttachment) -> Void)?
    var onRemove: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var colors = ComposerThemeColors.placeholder
    private var allowsMutation = true
    private var uploads: ComposerAttachmentUploads?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentTileSize),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentTileSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        attachments: [PendingAttachment],
        colors: ComposerThemeColors,
        allowsMutation: Bool,
        uploads: ComposerAttachmentUploads? = nil
    ) {
        self.colors = colors
        self.allowsMutation = allowsMutation
        self.uploads = uploads
        // Upload progress redraws the strip every percent. Rebuilding the tiles each
        // time would swap a Cancel button out from under a finger mid-tap, so a
        // change that keeps every tile's controls updates the tiles in place. A file
        // pill takes every upload state in place, so its ring can finish its arc.
        let structure = attachments.map(tileStructure) + ["mutable:\(allowsMutation)", "fg:\(colors.fg)"]
        if structure == builtStructure {
            for attachment in attachments {
                if let pill = pillViews[attachment.id] {
                    configure(pill, name: attachment.displayName, id: attachment.id)
                } else if let overlay = overlayViews[attachment.id], let display = uploadDisplay(for: attachment.id) {
                    overlay.apply(display, colors: colors)
                }
            }
        } else {
            builtStructure = structure
            pillViews = [:]
            overlayViews = [:]
            tileViews = [:]
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for attachment in attachments {
                let tile = makeTile(for: attachment)
                tileViews[attachment.id] = tile
                stack.addArrangedSubview(tile)
            }
            isHidden = attachments.isEmpty
        }
        revealUploadingTile()
    }

    private var tileViews: [String: UIView] = [:]
    private var revealedUploadID: String?

    /// A narrow strip scrolls; when the next file starts uploading, bring it into view.
    private func revealUploadingTile() {
        let current = uploads?.batch.current?.id
        guard current != revealedUploadID else { return }
        revealedUploadID = current
        guard let current, let tile = tileViews[current] else { return }
        layoutIfNeeded()
        scrollView.scrollRectToVisible(tile.frame.insetBy(dx: -8, dy: 0), animated: true)
    }

    private var builtStructure: [String] = []
    private var pillViews: [String: ComposerAttachmentFilePillView] = [:]
    private var overlayViews: [String: ComposerAttachmentUploadOverlay] = [:]

    /// Which controls a photo tile has; progress alone does not change it. A file
    /// pill updates its controls in place, so only its identity counts.
    private func tileStructure(_ attachment: PendingAttachment) -> String {
        guard attachment.source == .image, let thumbnail = attachment.thumbnail else {
            return "\(attachment.id)|file"
        }
        let corner: String = switch cornerAction(for: attachment.id) {
        case .cancel: "cancel"
        case .remove: "remove"
        case nil: "none"
        }
        return "\(attachment.id)|image:\(ObjectIdentifier(thumbnail).hashValue)|\(corner)"
            + "|retry:\(retryAction(for: attachment.id) != nil)|upload:\(uploadDisplay(for: attachment.id) != nil)"
    }

    private func configure(_ pill: ComposerAttachmentFilePillView, name: String, id: String) {
        pill.apply(
            name: name,
            id: id,
            colors: colors,
            corner: cornerAction(for: id),
            upload: uploadDisplay(for: id),
            onRetry: retryAction(for: id)
        )
    }

    private func makeTile(for attachment: PendingAttachment) -> UIView {
        if attachment.source == .image, let thumbnail = attachment.thumbnail {
            return makeImageTile(attachment: attachment, thumbnail: thumbnail)
        }
        return makeFilePill(name: attachment.displayName, id: attachment.id)
    }

    /// What an attachment's corner button does: Cancel while its upload runs (even
    /// mid-send), Remove otherwise when the draft can change.
    private func cornerAction(for id: String) -> ComposerAttachmentFilePillView.CornerAction? {
        if let uploads, let item = uploads.batch.item(id), item.isActive {
            let onCancel = uploads.onCancel
            return .cancel(onCancel)
        }
        guard allowsMutation else { return nil }
        return .remove { [weak self] in self?.onRemove?(id) }
    }

    /// Retry on a file whose upload failed or was cancelled, once the send has stopped.
    private func retryAction(for id: String) -> (() -> Void)? {
        guard allowsMutation, let uploads, let item = uploads.batch.item(id) else { return nil }
        switch item.state {
        case .failed, .cancelled: return uploads.onRetry
        default: return nil
        }
    }

    private func uploadDisplay(for id: String) -> ComposerAttachmentFilePillView.UploadDisplay? {
        guard let batch = uploads?.batch, let item = batch.item(id), let badge = batch.badge(for: id) else { return nil }
        return .init(state: item.state, fraction: item.fraction, isPaused: batch.isPaused, badge: badge)
    }

    private func makeImageTile(attachment: PendingAttachment, thumbnail: UIImage) -> UIView {
        let tile = UIView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: ComposerShared.attachmentTileSize),
            tile.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentTileSize),
        ])
        tile.accessibilityIdentifier = "chat.attachment.image.\(attachment.id)"

        let imageButton = UIButton(type: .custom)
        imageButton.setImage(thumbnail, for: .normal)
        imageButton.imageView?.contentMode = .scaleAspectFill
        imageButton.clipsToBounds = true
        imageButton.layer.cornerRadius = 8
        imageButton.layer.cornerCurve = .continuous
        imageButton.layer.borderWidth = 1
        imageButton.layer.borderColor = colors.comment.withAlphaComponent(0.3).cgColor
        imageButton.isEnabled = allowsMutation
        imageButton.accessibilityLabel = "Annotate photo"
        imageButton.accessibilityIdentifier = "chat.attachment.image.annotate.\(attachment.id)"
        imageButton.addAction(UIAction { [weak self] _ in
            self?.onAnnotate?(attachment)
        }, for: .touchUpInside)
        imageButton.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(imageButton)
        NSLayoutConstraint.activate([
            imageButton.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            imageButton.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            imageButton.widthAnchor.constraint(equalToConstant: ComposerShared.attachmentThumbnailSize),
            imageButton.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentThumbnailSize),
        ])

        if let display = uploadDisplay(for: attachment.id) {
            let overlay = ComposerAttachmentUploadOverlay()
            overlay.apply(display, colors: colors)
            overlayViews[attachment.id] = overlay
            overlay.accessibilityIdentifier = "chat.attachment.upload.\(attachment.id)"
            overlay.translatesAutoresizingMaskIntoConstraints = false
            imageButton.addSubview(overlay)
            NSLayoutConstraint.activate([
                overlay.leadingAnchor.constraint(equalTo: imageButton.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: imageButton.trailingAnchor),
                overlay.bottomAnchor.constraint(equalTo: imageButton.bottomAnchor),
            ])
        }
        if let onRetry = retryAction(for: attachment.id) {
            let retry = UIButton(type: .system)
            let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
                .applying(UIImage.SymbolConfiguration(paletteColors: [colors.fg, colors.scrim]))
            retry.setImage(UIImage(systemName: "arrow.clockwise.circle.fill", withConfiguration: config), for: .normal)
            retry.accessibilityLabel = "Retry upload"
            retry.accessibilityIdentifier = "chat.attachment.retry.\(attachment.id)"
            retry.addAction(UIAction { _ in onRetry() }, for: .touchUpInside)
            retry.translatesAutoresizingMaskIntoConstraints = false
            imageButton.addSubview(retry)
            NSLayoutConstraint.activate([
                retry.centerXAnchor.constraint(equalTo: imageButton.centerXAnchor),
                retry.centerYAnchor.constraint(equalTo: imageButton.centerYAnchor, constant: -6),
            ])
        }

        if let action = cornerAction(for: attachment.id) {
            let remove = UIButton(type: .system)
            // Palette rendering: glyph on scrim, matching SwiftUI `.palette`.
            remove.setImage(Self.removeImage(fg: colors.fg, scrim: colors.scrim), for: .normal)
            remove.accessibilityLabel = action.accessibilityLabel(for: "photo")
            remove.accessibilityIdentifier = action.identifier(for: attachment.id)
            remove.addAction(UIAction { _ in action.perform() }, for: .touchUpInside)
            remove.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(remove)
            NSLayoutConstraint.activate([
                remove.widthAnchor.constraint(equalToConstant: ComposerShared.attachmentRemoveHitSize),
                remove.heightAnchor.constraint(equalToConstant: ComposerShared.attachmentRemoveHitSize),
                remove.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8),
                remove.topAnchor.constraint(equalTo: tile.topAnchor, constant: -8),
            ])
        }
        return tile
    }

    private func makeFilePill(name: String, id: String) -> UIView {
        let pill = ComposerAttachmentFilePillView()
        configure(pill, name: name, id: id)
        pillViews[id] = pill
        pill.accessibilityIdentifier = "chat.attachment.file.\(id)"
        return pill
    }

    private static func removeImage(fg: UIColor, scrim: UIColor) -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            .applying(UIImage.SymbolConfiguration(paletteColors: [fg, scrim]))
        return UIImage(systemName: "xmark.circle.fill", withConfiguration: config) ?? UIImage()
    }
}

final class ComposerAttachmentFilePillView: UIView {
    /// The pill's trailing X: Cancel while the file uploads, Remove otherwise.
    enum CornerAction {
        case cancel(() -> Void)
        case remove(() -> Void)

        func perform() {
            switch self {
            case .cancel(let action), .remove(let action): action()
            }
        }

        func accessibilityLabel(for noun: String) -> String {
            switch self {
            case .cancel: return "Cancel upload"
            case .remove: return "Remove \(noun)"
            }
        }

        func identifier(for id: String) -> String {
            switch self {
            case .cancel: return "chat.attachment.cancel.\(id)"
            case .remove: return "chat.attachment.remove.\(id)"
            }
        }
    }

    /// One attachment's upload, as its tile shows it.
    struct UploadDisplay: Equatable {
        let state: AttachmentUploadBatch.State
        /// Bytes sent over the file's size; 1 once it arrived.
        let fraction: Double
        /// The app is in the background on a route that cannot upload there.
        let isPaused: Bool
        /// Short words: "48%", "Waiting", "Paused", "Failed".
        let badge: String

        var isInFlight: Bool {
            switch state {
            case .waiting, .uploading, .retrying: true
            case .uploaded, .failed, .cancelled: false
            }
        }

        var isProblem: Bool {
            switch state {
            case .failed, .cancelled: true
            case .waiting, .uploading, .retrying, .uploaded: false
            }
        }

        /// The words a pill speaks for its state: the percentage while the file
        /// moves or is paused part way, otherwise the badge.
        var spokenValue: String {
            switch state {
            case .uploading where isPaused: "Paused at \(Int(fraction * 100))%"
            case .retrying: "Retrying at \(Int(fraction * 100))%"
            default: badge
            }
        }
    }

    /// The pill's leading slot: the file's icon, or its upload state in its place.
    private let iconView = UIImageView()
    private let ring = ProgressRingGlyph(lineWidth: 2)
    /// A failed or cancelled file's error badge; tapping it retries the send.
    private let retryButton = UIButton(type: .system)
    private let nameLabel = UILabel()
    private let removeButton = UIButton(type: .system)
    /// The display last applied, so a file that just arrived can finish its ring.
    private var shownUpload: UploadDisplay?
    /// Bumped by every apply; a pending finish runs only if nothing came after it
    /// but more "uploaded" refreshes.
    private var finishGeneration = 0
    private var isFinishing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        nameLabel.font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            weight: .regular
        )
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iconView.contentMode = .scaleAspectFit
        ring.isHidden = true
        let xConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        removeButton.setImage(UIImage(systemName: "xmark", withConfiguration: xConfig), for: .normal)
        let errorConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        retryButton.setImage(
            UIImage(systemName: "exclamationmark.arrow.circlepath", withConfiguration: errorConfig),
            for: .normal
        )
        retryButton.accessibilityLabel = "Retry upload"
        retryButton.isHidden = true
        let stack = UIStackView(arrangedSubviews: [iconView, ring, retryButton, nameLabel, removeButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            ring.widthAnchor.constraint(equalToConstant: 13),
            ring.heightAnchor.constraint(equalToConstant: 13),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            removeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            removeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(
        name: String,
        id: String,
        colors: ComposerThemeColors,
        corner: CornerAction?,
        upload: UploadDisplay?,
        onRetry: (() -> Void)?
    ) {
        nameLabel.text = name
        nameLabel.textColor = colors.fg
        // The name carries the pill's upload state for assistive tech and UI tests.
        nameLabel.accessibilityIdentifier = "chat.attachment.upload.\(id)"
        nameLabel.accessibilityValue = upload?.spokenValue
        nameLabel.accessibilityTraits = upload?.isInFlight == true ? .updatesFrequently : .staticText
        let wasInFlight = shownUpload?.isInFlight == true
        shownUpload = upload
        applyLeadingSlot(name: name, upload: upload, canRetry: onRetry != nil, wasInFlight: wasInFlight, colors: colors)

        retryButton.tintColor = colors.red
        retryButton.accessibilityIdentifier = "chat.attachment.retry.\(id)"
        // A fixed action identifier: a refresh replaces the action on the same
        // button instead of stacking a second one.
        let retryID = UIAction.Identifier("chat.attachment.retry")
        retryButton.removeAction(identifiedBy: retryID, for: .touchUpInside)
        if let onRetry {
            retryButton.addAction(UIAction(identifier: retryID) { _ in onRetry() }, for: .touchUpInside)
        }

        removeButton.tintColor = colors.comment
        let cornerID = UIAction.Identifier("chat.attachment.corner")
        removeButton.isHidden = corner == nil
        removeButton.accessibilityLabel = corner?.accessibilityLabel(for: "file")
        removeButton.accessibilityIdentifier = corner?.identifier(for: id)
        removeButton.removeAction(identifiedBy: cornerID, for: .touchUpInside)
        if let corner {
            removeButton.addAction(UIAction(identifier: cornerID) { _ in corner.perform() }, for: .touchUpInside)
        }
        backgroundColor = upload?.isProblem == true
            ? colors.red.withAlphaComponent(0.12)
            : colors.comment.withAlphaComponent(0.1)
    }

    private enum Leading { case icon(UIImage?), ring, retry }

    /// A file in flight shows a ring where its icon was: dashed while it waits its
    /// turn (orange while it starts over), its share sent while it moves (grey
    /// while paused). A file that just arrived fills the ring, then its icon comes
    /// back. A failed or cancelled one shows the error badge, which retries.
    private func applyLeadingSlot(
        name: String,
        upload: UploadDisplay?,
        canRetry: Bool,
        wasInFlight: Bool,
        colors: ComposerThemeColors
    ) {
        let fileIcon = FileIcon.forPath(name).uiImage(pointSize: 9, weight: .medium)
        let track = colors.comment.withAlphaComponent(0.3)
        if upload?.state != .uploaded {
            finishGeneration += 1
            isFinishing = false
        }
        guard let upload else {
            show(.icon(fileIcon))
            return
        }
        switch upload.state {
        case .waiting:
            ring.apply(track: track, arc: colors.comment, fraction: nil)
            show(.ring)
        case .uploading:
            ring.apply(track: track, arc: upload.isPaused ? colors.comment : colors.blue, fraction: upload.fraction)
            show(.ring)
        case .retrying:
            ring.apply(track: track, arc: colors.orange, fraction: nil)
            show(.ring)
        case .uploaded:
            // Progress for the next file refreshes this pill too; a finish under
            // way keeps going.
            guard !isFinishing else { return }
            guard wasInFlight, window != nil, !UIAccessibility.isReduceMotionEnabled else {
                show(.icon(fileIcon))
                return
            }
            isFinishing = true
            let generation = finishGeneration
            ring.apply(track: track, arc: colors.blue, fraction: 1)
            show(.ring)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.finishGeneration == generation else { return }
                self.isFinishing = false
                UIView.transition(with: self, duration: 0.2, options: .transitionCrossDissolve) {
                    self.show(.icon(fileIcon))
                }
            }
        case .failed, .cancelled:
            if canRetry {
                show(.retry)
            } else {
                show(.icon(UIImage(
                    systemName: "exclamationmark.circle.fill",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
                )?.withTintColor(colors.red, renderingMode: .alwaysOriginal)))
            }
        }
    }

    private func show(_ leading: Leading) {
        if case .icon(let image) = leading { iconView.image = image }
        iconView.setHiddenIfChanged({ if case .icon = leading { false } else { true } }())
        ring.setHiddenIfChanged({ if case .ring = leading { false } else { true } }())
        retryButton.setHiddenIfChanged({ if case .retry = leading { false } else { true } }())
    }
}

/// The upload state along the bottom of a photo tile: badge and progress.
final class ComposerAttachmentUploadOverlay: UIView {
    private let badgeLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .bar)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        badgeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [badgeLabel, bar])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            bar.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func apply(_ display: ComposerAttachmentFilePillView.UploadDisplay, colors: ComposerThemeColors) {
        backgroundColor = colors.scrim.withAlphaComponent(0.7)
        badgeLabel.text = display.badge
        badgeLabel.textColor = display.isProblem ? colors.red : colors.fg
        bar.isHidden = !display.isInFlight
        bar.progress = Float(display.fraction)
        bar.progressTintColor = colors.blue
        bar.trackTintColor = colors.comment.withAlphaComponent(0.3)
    }
}
