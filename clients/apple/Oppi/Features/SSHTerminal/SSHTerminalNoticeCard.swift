import UIKit

/// Floating notice over the top of the terminal grid: a blocked program or a
/// one-shot notification.
///
/// It is a material card, not a dialog and not a row of the grid: the headline
/// and host are Oppi's, and the program's text is a separate line, so a host
/// cannot dress its message up as Oppi's. Floating keeps the grid's row count
/// stable, so a notice does not resize the remote PTY. A tap or an upward
/// swipe folds it into the toolbar glyph, so the prompt under it can be read.
final class SSHTerminalNoticeCardView: UIView {
    var onDismiss: (SSHTerminalNotice.Key) -> Void = { _ in }
    var onFrameChange: (CGRect) -> Void = { _ in }

    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let fill = UIView()
    private let stroke = UIView()
    private let symbolView = SSHTerminalStatusMarkView(style: .banner)
    private let bellView = UIImageView()
    private let headlineLabel = UILabel()
    private let hostLabel = UILabel()
    private let hostIcon = UIImageView()
    private let remoteLabel = UILabel()
    private var dragOffset: CGFloat = 0
    private var reduceMotion = false
    private var notice: SSHTerminalNotice?
    /// The notice under the finger when the swipe began.
    private var panBeganKey: SSHTerminalNotice.Key?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        material.translatesAutoresizingMaskIntoConstraints = false
        material.layer.cornerRadius = 14
        material.clipsToBounds = true
        addSubview(material)

        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.isUserInteractionEnabled = false
        material.contentView.addSubview(fill)

        stroke.translatesAutoresizingMaskIntoConstraints = false
        stroke.isUserInteractionEnabled = false
        stroke.layer.cornerRadius = 14
        stroke.layer.borderWidth = 0.5
        stroke.backgroundColor = .clear
        addSubview(stroke)

        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        bellView.translatesAutoresizingMaskIntoConstraints = false
        bellView.image = UIImage(systemName: "bell.badge")
        bellView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        bellView.setContentHuggingPriority(.required, for: .horizontal)
        symbolView.setContentHuggingPriority(.required, for: .horizontal)

        headlineLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        headlineLabel.adjustsFontForContentSizeCategory = true
        headlineLabel.lineBreakMode = .byTruncatingTail
        headlineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        hostIcon.image = UIImage(systemName: "network")
        hostIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1)
        hostIcon.setContentHuggingPriority(.required, for: .horizontal)
        hostLabel.font = .preferredFont(forTextStyle: .caption1)
        hostLabel.adjustsFontForContentSizeCategory = true
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let host = UIStackView(arrangedSubviews: [hostIcon, hostLabel])
        host.axis = .horizontal
        host.spacing = 4
        host.alignment = .center
        host.setContentHuggingPriority(.required, for: .horizontal)

        header.addArrangedSubview(symbolView)
        header.addArrangedSubview(bellView)
        header.addArrangedSubview(headlineLabel)
        header.addArrangedSubview(UIView())
        header.addArrangedSubview(host)

        remoteLabel.font = .preferredFont(forTextStyle: .footnote)
        remoteLabel.adjustsFontForContentSizeCategory = true
        remoteLabel.numberOfLines = 2

        let column = UIStackView(arrangedSubviews: [header, remoteLabel])
        column.axis = .vertical
        column.spacing = 4
        column.translatesAutoresizingMaskIntoConstraints = false
        material.contentView.addSubview(column)

        NSLayoutConstraint.activate([
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            material.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            material.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            fill.topAnchor.constraint(equalTo: material.contentView.topAnchor),
            fill.bottomAnchor.constraint(equalTo: material.contentView.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: material.contentView.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: material.contentView.trailingAnchor),
            stroke.topAnchor.constraint(equalTo: material.topAnchor),
            stroke.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            stroke.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            stroke.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            column.topAnchor.constraint(equalTo: material.contentView.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: material.contentView.bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: material.contentView.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: material.contentView.trailingAnchor, constant: -12),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 1
        addGestureRecognizer(pan)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Dismisses the notice"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Dismiss") { [weak self] _ in
                guard let self, let key = self.notice?.key else { return false }
                self.onDismiss(key)
                return true
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Layout frame, not the drag transform, so a swipe never writes cardFrame.
        onFrameChange(convert(bounds, to: nil))
    }

    func apply(notice: SSHTerminalNotice, hostCaption: String, themeID: ThemeID, reduceMotion: Bool) {
        self.notice = notice
        self.reduceMotion = reduceMotion
        let palette = themeID.palette
        let theme = themeID.appTheme
        let tint: UIColor
        let headline: String
        let remote: String
        switch notice {
        case .blocked(let blocked):
            tint = UIColor(blocked.kind.tint(theme))
            headline = blocked.kind.label
            remote = blocked.remoteText
            symbolView.isHidden = false
            bellView.isHidden = true
            symbolView.apply(status: blocked.kind, themeID: themeID, reduceMotion: reduceMotion)
            accessibilityIdentifier = "sshTerminal.programStatusBanner"
        case .alert(let alert):
            tint = UIColor(palette.blue)
            headline = "Notification"
            remote = [alert.title, alert.body].filter { !$0.isEmpty }.joined(separator: ": ")
            symbolView.isHidden = true
            bellView.isHidden = false
            bellView.tintColor = tint
            accessibilityIdentifier = "sshTerminal.notificationBanner"
        }
        let host = SSHTerminalProgramStatusPresentation.hostCaption(hostCaption)
        headlineLabel.text = headline
        headlineLabel.textColor = tint
        hostLabel.text = host
        hostLabel.textColor = UIColor(palette.comment)
        hostIcon.tintColor = UIColor(palette.comment)
        remoteLabel.text = remote
        remoteLabel.isHidden = remote.isEmpty
        remoteLabel.textColor = UIColor(palette.fg)
        fill.backgroundColor = UIColor(palette.bg).withAlphaComponent(0.72)
        stroke.layer.borderColor = tint.cgColor
        accessibilityLabel = "\(headline), \(host)"
        accessibilityValue = remote
    }

    @objc private func tapped() {
        guard let key = notice?.key else { return }
        onDismiss(key)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        handlePan(
            state: gesture.state,
            translationY: gesture.translation(in: self).y,
            velocityY: gesture.velocity(in: self).y
        )
    }

    /// Captures the notice at finger-down. A replacement mid-swipe is a new
    /// card: the gesture cannot dismiss it.
    func handlePan(state: UIGestureRecognizer.State, translationY dy: CGFloat, velocityY: CGFloat) {
        switch state {
        case .began:
            panBeganKey = notice?.key
        case .changed:
            dragOffset = dy < 0 ? dy : dy / 6
            transform = CGAffineTransform(translationX: 0, y: dragOffset)
        case .ended, .cancelled:
            let began = panBeganKey
            panBeganKey = nil
            let sameNotice = began != nil && began == notice?.key
            let flick = dy < -24 || velocityY < -400
            let duration: TimeInterval = reduceMotion ? 0.2 : 0.35
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.transform = .identity
            }
            if state == .ended, sameNotice, flick, let began {
                onDismiss(began)
            } else {
                dragOffset = 0
            }
        default:
            break
        }
    }

    /// In from the top. Out into the toolbar glyph: the card shrinks toward the
    /// glyph's centre. Reduce Motion fades both ways.
    static func collapseTransform(card: CGRect, glyph: CGRect) -> CGAffineTransform {
        let target: CGPoint
        if glyph == .zero || card.width <= 0 || card.height <= 0 {
            target = CGPoint(x: card.midX, y: card.minY)
        } else {
            target = CGPoint(x: glyph.midX, y: glyph.midY)
        }
        return CGAffineTransform(translationX: target.x - card.midX, y: target.y - card.midY)
            .scaledBy(x: 0.08, y: 0.08)
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
