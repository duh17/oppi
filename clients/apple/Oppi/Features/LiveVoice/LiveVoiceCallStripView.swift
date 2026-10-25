import AVKit
import UIKit

/// The call strip's drawing: a glass capsule under the status bar holding the call's
/// session and status (a button back to the call), the audio route, Mute, and End.
///
/// The view's top edge is the window's: its backdrop runs behind the status bar, and the
/// capsule sits in the band below it (`contentHeight`). At accessibility text sizes the
/// controls move to a row of their own under the text.
@MainActor
final class LiveVoiceCallStripView: UIView {
    static let identifier = "liveVoice.callStrip"
    /// System call green, as the status bar's call indicator.
    private static let callGreen = UIColor.systemGreen
    private static let bandInsets = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 6, trailing: 12)
    private static let maxCapsuleWidth: CGFloat = 720
    private static let controlSide: CGFloat = 44

    var onOpen: (() -> Void)?
    var onToggleMute: (() -> Void)?
    var onEnd: (() -> Void)?

    /// Painted behind the status bar and around the capsule: the content's own background.
    var backdropColor: UIColor? {
        didSet { backgroundColor = backdropColor }
    }

    private let band = UIView()
    private let capsule = UIVisualEffectView(effect: LiveVoiceCallStripView.glass())
    private let row = UIStackView()
    private let controls = UIStackView()
    private let openControl = LiveVoiceCallStripOpenControl()
    private let glyph = UIImageView()
    private let glyphDisc = UIView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let routePicker = AVRoutePickerView()
    private let muteButton = UIButton(type: .system)
    private let endButton = UIButton(type: .system)

    private var content: LiveVoiceCallStripContent?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Apply

    func apply(_ content: LiveVoiceCallStripContent, now: Date) {
        self.content = content
        let failed = content.phase == .failed

        glyphDisc.backgroundColor = failed ? .systemRed : (content.isMuted ? .systemOrange : Self.callGreen)
        glyph.image = UIImage(systemName: failed
            ? "exclamationmark.triangle.fill"
            : (content.isMuted ? "mic.slash.fill" : "phone.fill"))
        titleLabel.text = content.title
        updateDuration(now: now)

        routePicker.setHiddenIfChanged(failed)
        muteButton.setHiddenIfChanged(failed)
        applyMute(isMuted: content.isMuted)
        applyEnd(failed: failed)
        // A hidden title is already "Live Voice"; it is not said twice.
        let named = content.title == LiveVoiceCallStripContent.lockedTitle ? "" : ", \(content.title)"
        openControl.accessibilityLabel = (failed ? "Live Voice call failed" : "Live Voice call") + named
    }

    /// The status line with the call's duration; the clock calls this once a second.
    func updateDuration(now: Date) {
        guard let content else { return }
        statusLabel.attributedText = Self.statusLine(content, now: now)
        // A failure's reason is the one thing to read: whole at accessibility sizes.
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        statusLabel.numberOfLines = content.phase == .failed ? (large ? 0 : 2) : 1
        openControl.spokenStatus = { [content] in Self.spokenStatus(content, now: Date()) }
    }

    /// The band under the status bar: the capsule and its padding.
    func contentHeight(fitting width: CGFloat) -> CGFloat {
        let bandWidth = max(0, width - safeAreaInsets.left - safeAreaInsets.right)
        return band.systemLayoutSizeFitting(
            CGSize(width: bandWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    private static func statusLine(_ content: LiveVoiceCallStripContent, now: Date) -> NSAttributedString {
        let font = UIFont.scaled(.footnote)
        let line = NSMutableAttributedString()
        if let start = content.connectedAt {
            let digits = UIFont.scaled(.footnote, .semibold, monospacedDigits: true)
            line.append(NSAttributedString(
                string: LiveVoiceCallStripContent.durationText(since: start, now: now),
                attributes: [.font: digits, .foregroundColor: callGreen]
            ))
            line.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        }
        var status = content.status
        // Muted is said in words too, also while the agent's progress holds the status.
        if content.isMuted, status != "Muted" {
            status = "Muted · \(status)"
        }
        line.append(NSAttributedString(string: status, attributes: [
            .font: font,
            .foregroundColor: content.phase == .failed ? UIColor.systemRed : UIColor.secondaryLabel,
        ]))
        return line
    }

    private static func spokenStatus(_ content: LiveVoiceCallStripContent, now: Date) -> String {
        var parts: [String] = []
        if content.isMuted, content.status != "Muted" { parts.append("Muted") }
        parts.append(content.status)
        if let start = content.connectedAt {
            parts.append(LiveVoiceCallStripContent.spokenDuration(since: start, now: now))
        }
        return parts.joined(separator: ", ")
    }

    /// The theme's light or dark for the strip; a change redraws the muted platter.
    func setAppearance(_ style: UIUserInterfaceStyle) {
        guard overrideUserInterfaceStyle != style else { return }
        overrideUserInterfaceStyle = style
        if let content { applyMute(isMuted: content.isMuted) }
    }

    private func applyMute(isMuted: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        var background = UIBackgroundConfiguration.clear()
        if isMuted {
            // Muted is a filled platter in the text color with the glyph cut out of it, as the
            // system call screen draws it. Fixed colors: inside the glass a dynamic glyph color
            // resolved to the platter's own in dark mode, and the glyph vanished.
            let dark = overrideUserInterfaceStyle == .dark
                || (overrideUserInterfaceStyle == .unspecified && traitCollection.userInterfaceStyle == .dark)
            configuration.image = UIImage(systemName: "mic.slash.fill")?
                .withTintColor(dark ? .black : .white, renderingMode: .alwaysOriginal)
            background.backgroundColor = dark ? .white : .black
        } else {
            configuration.image = UIImage(systemName: "mic.fill")
            configuration.baseForegroundColor = .label
            background.backgroundColor = .tertiarySystemFill
        }
        background.cornerRadius = 18
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        configuration.background = background
        muteButton.configuration = configuration
        muteButton.accessibilityLabel = "Mute"
        muteButton.accessibilityValue = isMuted ? "Muted" : "Not muted"
    }

    private func applyEnd(failed: Bool) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: failed ? "xmark" : "phone.down.fill")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
        configuration.baseForegroundColor = failed ? .label : .white
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = failed ? .tertiarySystemFill : .systemRed
        background.cornerRadius = 18
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        configuration.background = background
        endButton.configuration = configuration
        endButton.accessibilityLabel = failed ? "Dismiss" : "End call"
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // The picker's own button is the element VoiceOver and UI tests reach: it takes the
        // strip's identifier and says what it picks.
        if let button = routePicker.subviews.lazy.compactMap({ $0 as? UIButton }).first,
           button.accessibilityIdentifier != routePicker.accessibilityIdentifier {
            button.accessibilityIdentifier = routePicker.accessibilityIdentifier
            button.accessibilityLabel = "Audio output"
        }
    }

    private func build() {
        accessibilityIdentifier = Self.identifier
        shouldGroupAccessibilityChildren = true

        band.translatesAutoresizingMaskIntoConstraints = false
        addSubview(band)

        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.cornerConfiguration = .capsule()
        band.addSubview(capsule)

        glyphDisc.translatesAutoresizingMaskIntoConstraints = false
        glyphDisc.layer.cornerRadius = 15
        glyphDisc.isUserInteractionEnabled = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.tintColor = .white
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        glyphDisc.addSubview(glyph)

        titleLabel.font = UIFont.scaled(.subheadline, .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        statusLabel.adjustsFontForContentSizeCategory = true
        let text = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        text.axis = .vertical
        text.spacing = 0
        text.isUserInteractionEnabled = false
        text.translatesAutoresizingMaskIntoConstraints = false

        openControl.translatesAutoresizingMaskIntoConstraints = false
        openControl.accessibilityIdentifier = "\(Self.identifier).open"
        openControl.accessibilityHint = "Opens the call's session."
        openControl.addSubview(glyphDisc)
        openControl.addSubview(text)
        openControl.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        openControl.onActivate = { [weak self] in self?.onOpen?() }

        routePicker.accessibilityIdentifier = "\(Self.identifier).route"
        routePicker.tintColor = .label
        routePicker.activeTintColor = Self.callGreen
        routePicker.prioritizesVideoDevices = false

        muteButton.accessibilityIdentifier = "\(Self.identifier).mute"
        muteButton.addAction(UIAction { [weak self] _ in self?.onToggleMute?() }, for: .touchUpInside)
        endButton.accessibilityIdentifier = "\(Self.identifier).end"
        endButton.addAction(UIAction { [weak self] _ in self?.onEnd?() }, for: .touchUpInside)

        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = 0
        for control in [routePicker, muteButton, endButton] as [UIView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            controls.addArrangedSubview(control)
            NSLayoutConstraint.activate([
                control.widthAnchor.constraint(equalToConstant: Self.controlSide),
                control.heightAnchor.constraint(equalToConstant: Self.controlSide),
            ])
        }
        controls.setContentHuggingPriority(.required, for: .horizontal)
        controls.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(openControl)
        row.addArrangedSubview(controls)
        capsule.contentView.addSubview(row)

        let insets = Self.bandInsets
        let fullWidth = capsule.widthAnchor.constraint(equalTo: band.widthAnchor, constant: -(insets.leading + insets.trailing))
        fullWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            band.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: bottomAnchor),

            capsule.topAnchor.constraint(equalTo: band.topAnchor, constant: insets.top),
            band.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: insets.bottom),
            capsule.centerXAnchor.constraint(equalTo: band.centerXAnchor),
            capsule.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxCapsuleWidth),
            capsule.leadingAnchor.constraint(greaterThanOrEqualTo: band.leadingAnchor, constant: insets.leading),
            fullWidth,

            row.topAnchor.constraint(equalTo: capsule.contentView.topAnchor, constant: 2),
            capsule.contentView.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: 2),
            row.leadingAnchor.constraint(equalTo: capsule.contentView.leadingAnchor, constant: 8),
            capsule.contentView.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: 4),

            glyphDisc.widthAnchor.constraint(equalToConstant: 30),
            glyphDisc.heightAnchor.constraint(equalToConstant: 30),
            glyphDisc.leadingAnchor.constraint(equalTo: openControl.leadingAnchor),
            glyphDisc.centerYAnchor.constraint(equalTo: openControl.centerYAnchor),
            glyph.centerXAnchor.constraint(equalTo: glyphDisc.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: glyphDisc.centerYAnchor),

            text.leadingAnchor.constraint(equalTo: glyphDisc.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: openControl.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: openControl.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: openControl.topAnchor, constant: 4),
            openControl.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.controlSide),
        ])
        openControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        applyTextSize()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (strip: Self, _) in
            strip.applyTextSize()
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (strip: Self, _) in
            if let content = strip.content { strip.applyMute(isMuted: content.isMuted) }
        }
    }

    /// Accessibility sizes stack the controls under the text, so the title and status keep
    /// the capsule's width instead of truncating to a word.
    private func applyTextSize() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        row.axis = large ? .vertical : .horizontal
        row.alignment = large ? .trailing : .center
        row.spacing = large ? 0 : 4
        titleLabel.numberOfLines = large ? 2 : 1
        openControl.fillsRow = large
        capsule.cornerConfiguration = large ? .uniformCorners(radius: 26) : .capsule()
        updateDuration(now: Date())
    }

    /// Plain regular glass: the call green lives in the leading disc and the clock, which a
    /// green-tinted capsule washed out.
    private static func glass() -> UIVisualEffect {
        UIGlassEffect(style: .regular)
    }
}

/// The strip's leading part: the call's session and status, a button back to the call.
/// VoiceOver reads the duration only when it lands here, never as it ticks.
@MainActor
private final class LiveVoiceCallStripOpenControl: UIControl {
    var onActivate: (() -> Void)?
    var spokenStatus: (() -> String)?
    private var fillWidth: NSLayoutConstraint?

    /// At accessibility sizes the text takes the whole first row.
    var fillsRow = false {
        didSet {
            guard fillsRow != oldValue, let superview else { return }
            fillWidth?.isActive = false
            fillWidth = fillsRow ? widthAnchor.constraint(equalTo: superview.widthAnchor) : nil
            fillWidth?.isActive = true
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        let fills = fillsRow
        fillsRow = false
        fillsRow = fills
    }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override var accessibilityValue: String? {
        get { spokenStatus?() }
        set {}
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}
