import UIKit

/// A file download for Share in progress, over the whole screen: the file's
/// name, how much has arrived, and Cancel, in an elevated panel. The screen
/// behind takes no touches until the download ends or is cancelled, so the
/// row or button the share sheet anchors to stays where it is.
final class FileShareProgressOverlay: UIView {
    private let panel = UIView()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let status = UILabel()
    /// Cancel's action: stops the download, which takes the overlay down.
    var onCancel: (() -> Void)?

    init(fileName: String, progress: FileDownloadProgress, palette: ThemePalette) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.25)
        accessibilityViewIsModal = true
        accessibilityIdentifier = "fileBrowser.share.progress"

        let surface = ThemeSurfaceStyle.resolve(.elevatedPanel, palette: palette)
        // The elevated fill is translucent; the blur keeps the rows behind out of the text.
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.frame = panel.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        panel.addSubview(blur)
        panel.clipsToBounds = true
        blur.contentView.backgroundColor = surface.fill
        panel.layer.cornerRadius = 14
        panel.layer.cornerCurve = .continuous
        panel.layer.borderColor = surface.stroke?.cgColor
        panel.layer.borderWidth = surface.stroke == nil ? 0 : surface.strokeLineWidth

        let title = UILabel()
        title.text = String(localized: "Preparing “\(fileName)”")
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = palette.ui.fg
        title.lineBreakMode = .byTruncatingMiddle

        bar.progressTintColor = palette.ui.cyan

        status.font = UIFont.scaled(.footnote, monospacedDigits: true)
        status.textColor = palette.ui.comment
        status.accessibilityIdentifier = "fileBrowser.share.status"
        status.accessibilityTraits = .updatesFrequently

        var cancelConfiguration = UIButton.Configuration.gray()
        cancelConfiguration.title = String(localized: "Cancel")
        let cancel = UIButton(configuration: cancelConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.onCancel?()
        })
        cancel.accessibilityIdentifier = "fileBrowser.share.cancel"

        let stack = UIStackView(arrangedSubviews: [title, bar, status, cancel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(6, after: bar)
        for view in [title, status] {
            view.adjustsFontForContentSizeCategory = true
            view.textAlignment = .center
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        addSubview(panel)
        let width = panel.widthAnchor.constraint(equalToConstant: 300)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
            panel.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor, constant: -32),
            width,
        ])
        update(progress)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// "3.1 MB of 48 MB" under a bar at that fraction, or the bytes so far
    /// when the size is not known.
    func update(_ progress: FileDownloadProgress) {
        let received = ByteCountFormatter.string(fromByteCount: progress.received, countStyle: .file)
        guard let expected = progress.expected, expected > 0 else {
            bar.isHidden = true
            status.text = received
            return
        }
        bar.isHidden = false
        bar.setProgress(Float(min(1, Double(progress.received) / Double(expected))), animated: true)
        let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
        status.text = String(localized: "\(received) of \(total)")
    }

    /// Covers `host`, fading in.
    func show(over host: UIView) {
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        alpha = 0
        host.addSubview(self)
        UIView.animate(withDuration: 0.15) { self.alpha = 1 }
        UIAccessibility.post(notification: .screenChanged, argument: panel)
    }
}
