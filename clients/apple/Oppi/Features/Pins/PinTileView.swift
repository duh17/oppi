import UIKit

/// A place as a tile shows it, from any list that shows places as tiles (a
/// pin on the Pinned screen, an extension surface's `tiles` node): what it
/// opens, the words its owner knows for it, and why it cannot open.
struct PinTilePlace: Equatable {
    var route: PaneRoute
    var title: String
    var detail: String?
    /// A name the owner chose (a pin's label, an extension's title): a web
    /// page's own title does not replace it.
    var keepsTitle = false
    /// A line the owner chose (an extension's subtitle): what the preview
    /// reads does not replace it.
    var keepsDetail = false
    /// Not there any more (`detail` says why): dimmed, its kind's glyph.
    var isGone = false
    /// A game while Godot Pane is off here: dimmed.
    var isOff = false
    var isUnreadable = false
    var isLocked = false

    var isDimmed: Bool { isGone || isOff }

    /// A file's own icon; nil for every other place.
    var fileIcon: FileIcon? {
        guard case .file(_, let path, _) = route else { return nil }
        return FileIcon.forPath(path)
    }
}

/// The picture at the top of a pin's tile: a file's page or picture, a
/// game's last frame, a web page's image or icon, else its kind's glyph.
struct PinArtwork: Equatable {
    enum Fit: Equatable {
        /// A picture filling its frame.
        case fill
        /// A page, whole, on its backdrop with a shadow.
        case page
        /// A symbol or icon in the middle (in the top corner over a folder's items).
        case glyph
    }

    var image: UIImage?
    var fit: Fit
    var tint: UIColor
    var backdrop: UIColor
    /// A mark in the corner: the Godot logo over a game's frame.
    var badge: UIImage?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image === rhs.image && lhs.fit == rhs.fit && lhs.tint == rhs.tint
            && lhs.backdrop == rhs.backdrop && lhs.badge === rhs.badge
    }

    /// Godot's own blue, for its logo.
    static let godotBlue = UIColor(red: 0.278, green: 0.549, blue: 0.749, alpha: 1)

    /// The artwork for a place of `kind` with what its preview has read so
    /// far. A place that is gone or can't open here shows its kind's glyph,
    /// dimmed.
    @MainActor
    static func make(kind: PinKind, place: PinTilePlace, preview: PinPreview?, palette: ThemePalette) -> Self {
        let ui = palette.ui
        let dimmed = place.isDimmed
        let preview = dimmed ? nil : preview
        func glyph(_ image: UIImage?, _ tint: UIColor) -> Self {
            let color = dimmed ? ui.comment : tint
            return Self(image: image, fit: .glyph, tint: color, backdrop: color.withAlphaComponent(0.14))
        }
        let godot = UIImage(named: "lang-godot")?.withRenderingMode(.alwaysTemplate)
        switch kind {
        case .files:
            if let image = preview?.image {
                let isPage = if case .file(_, let path, _) = place.route {
                    (path as NSString).pathExtension.lowercased() == "pdf"
                } else {
                    true
                }
                return Self(image: image, fit: isPage ? .page : .fill, tint: ui.fg, backdrop: ui.bgDark)
            }
            let icon = place.fileIcon ?? FileIcon(symbolName: "doc", tint: .comment)
            return glyph(icon.uiImage(pointSize: 28).withRenderingMode(.alwaysTemplate), icon.color)
        case .folders:
            return glyph(UIImage(systemName: "folder.fill"), ui.blue)
        case .games:
            if let image = preview?.image {
                return Self(image: image, fit: .fill, tint: godotBlue, backdrop: ui.bgDark, badge: godot)
            }
            return glyph(godot ?? UIImage(systemName: kind.symbol), godotBlue)
        case .web:
            if let image = preview?.image {
                return Self(image: image, fit: .fill, tint: ui.fg, backdrop: ui.bgDark)
            }
            if let icon = preview?.icon {
                return Self(image: icon, fit: .glyph, tint: ui.fg, backdrop: ui.bgHighlight)
            }
            return glyph(UIImage(systemName: kind.symbol), ui.cyan)
        case .panels:
            return glyph(UIImage(systemName: kind.symbol), ui.purple)
        case .sessions:
            return glyph(UIImage(systemName: kind.symbol), ui.blue)
        }
    }
}

/// Draws a `PinArtwork`: rounded, its picture filled, or a page or glyph on
/// its backdrop.
final class PinArtworkView: UIView {
    private let imageView = UIImageView()
    private let badgeBackground = UIView()
    private let badgeView = UIImageView()
    /// Puts the glyph in the top corner instead of the middle (a folder's tile).
    var glyphAtCorner = false {
        didSet { setNeedsLayout() }
    }
    private var artwork: PinArtwork?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        imageView.layer.shadowRadius = 4
        imageView.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(imageView)
        badgeBackground.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        badgeBackground.layer.cornerRadius = 7
        badgeBackground.layer.cornerCurve = .continuous
        badgeView.contentMode = .scaleAspectFit
        badgeBackground.addSubview(badgeView)
        addSubview(badgeBackground)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ artwork: PinArtwork) {
        guard artwork != self.artwork else { return }
        self.artwork = artwork
        backgroundColor = artwork.backdrop
        imageView.image = artwork.image
        imageView.tintColor = artwork.tint
        imageView.contentMode = artwork.fit == .fill ? .scaleAspectFill : .scaleAspectFit
        imageView.clipsToBounds = artwork.fit == .fill
        imageView.layer.shadowOpacity = artwork.fit == .page ? 0.35 : 0
        badgeView.image = artwork.badge
        badgeView.tintColor = PinArtwork.godotBlue
        badgeBackground.isHidden = artwork.badge == nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = bounds
        switch artwork?.fit {
        case .fill:
            imageView.frame = bounds
        case .page:
            let box = bounds.insetBy(dx: 12, dy: 10)
            let size = artwork?.image?.size ?? box.size
            let scale = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            imageView.frame = CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        case _ where glyphAtCorner:
            let side = min(bounds.width * 0.16, 28)
            imageView.frame = CGRect(x: 12, y: 12, width: side, height: side)
        default:
            let side = min(bounds.width, bounds.height) * 0.36
            imageView.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        }
        let badge = min(26, bounds.height * 0.22)
        badgeBackground.frame = CGRect(x: 8, y: bounds.maxY - badge - 8, width: badge, height: badge)
        badgeView.frame = badgeBackground.bounds.insetBy(dx: 4, dy: 4)
    }
}

/// One place as a tile: its artwork over its name and a line of detail. A
/// folder's tile lists its first items under the folder glyph. The Pinned
/// screen's cells (`PinTileCell`) and an extension surface's `tiles` node
/// (`BlocksTilesView`) draw it, so a place reads the same in both.
///
/// The view draws only: its host owns the tap, the accessibility element,
/// and the frame (the artwork's height is `artworkAspect` of the width, and
/// the words under it fit in `captionHeight`).
final class PinTileView: UIView {
    struct Content: Equatable {
        var artwork: PinArtwork
        var title: String
        var detail: String?
        var children: [FileEntry]
        var isDimmed: Bool
        var isLocked: Bool

        /// A tile's name and line of detail: why it can't open, else what
        /// its preview read (a PDF's pages and size, a folder's items, a
        /// game's build), else where it lives. A web page shows its title
        /// over its host unless the place has a name of its own.
        @MainActor
        static func make(place: PinTilePlace, kind: PinKind, preview: PinPreview?, palette: ThemePalette) -> Self {
            var title = place.title
            var detail = place.detail
            if !(place.isDimmed || place.isUnreadable) {
                switch (kind, place.route) {
                case (.web, .browser(let url)):
                    if !place.keepsTitle, let pageTitle = preview?.title, !pageTitle.isEmpty {
                        title = pageTitle
                        if !place.keepsDetail { detail = url.host() ?? place.detail }
                    }
                case (.folders, _) where !place.keepsDetail:
                    let parts = [preview?.detail, place.detail].compactMap { $0 }
                    detail = parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
                case (.files, _) where !place.keepsDetail, (.games, _) where !place.keepsDetail:
                    detail = preview?.detail ?? place.detail
                default:
                    break
                }
            }
            return Self(
                artwork: PinArtwork.make(kind: kind, place: place, preview: preview, palette: palette),
                title: title,
                detail: detail,
                children: kind == .folders ? preview?.children ?? [] : [],
                isDimmed: place.isDimmed,
                isLocked: place.isLocked
            )
        }

        /// What VoiceOver reads: the name, the line under it, and the lock.
        var accessibilityLabel: String {
            [title, detail, isLocked ? String(localized: "Locked") : nil].compactMap { $0 }.joined(separator: ", ")
        }
    }

    let artworkView = PinArtworkView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let lockView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let childrenStack = UIStackView()
    private var isDimmed = false

    /// Drawn pressed: the artwork fades as a touch holds it.
    var isPressed = false {
        didSet { applyAlpha() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        lockView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2)
        lockView.setContentHuggingPriority(.required, for: .horizontal)
        lockView.setContentCompressionResistancePriority(.required, for: .horizontal)
        childrenStack.axis = .vertical
        childrenStack.spacing = 4
        let detailRow = UIStackView(arrangedSubviews: [lockView, detailLabel])
        detailRow.spacing = 4
        detailRow.alignment = .center
        for view in [artworkView, titleLabel, detailRow] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Inside the artwork, which clips the items that don't fit.
        childrenStack.translatesAutoresizingMaskIntoConstraints = false
        artworkView.addSubview(childrenStack)
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: topAnchor),
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor),
            artworkView.trailingAnchor.constraint(equalTo: trailingAnchor),
            artworkView.heightAnchor.constraint(equalTo: artworkView.widthAnchor, multiplier: Self.artworkAspect),
            childrenStack.topAnchor.constraint(equalTo: artworkView.topAnchor, constant: 46),
            childrenStack.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor, constant: 12),
            childrenStack.trailingAnchor.constraint(lessThanOrEqualTo: artworkView.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            detailRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailRow.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The artwork's height for its width.
    static let artworkAspect: CGFloat = 3.0 / 4.0

    /// The height under the artwork: two lines of title and one of detail.
    static func captionHeight(for traits: UITraitCollection) -> CGFloat {
        let title = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight
        let detail = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits).lineHeight
        return (8 + title * 2 + 2 + detail + 6).rounded(.up)
    }

    /// The whole tile's height for its width.
    static func height(forWidth width: CGFloat, traits: UITraitCollection) -> CGFloat {
        (width * artworkAspect).rounded() + captionHeight(for: traits)
    }

    func show(_ content: Content, palette: ThemePalette) {
        let ui = palette.ui
        let isFolder = !content.children.isEmpty && !content.isDimmed
        artworkView.glyphAtCorner = isFolder
        var artwork = content.artwork
        if isFolder { artwork.backdrop = ui.bgHighlight }
        artworkView.show(artwork)
        isDimmed = content.isDimmed
        applyAlpha()
        titleLabel.text = content.title
        titleLabel.textColor = content.isDimmed ? ui.comment : ui.fg
        detailLabel.text = content.detail
        detailLabel.textColor = ui.comment
        detailLabel.isHidden = content.detail == nil
        lockView.isHidden = !content.isLocked
        lockView.tintColor = ui.comment
        childrenStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if isFolder {
            for entry in content.children { childrenStack.addArrangedSubview(Self.childRow(entry, palette: palette)) }
        }
        childrenStack.isHidden = !isFolder
    }

    private func applyAlpha() {
        artworkView.alpha = isPressed ? 0.7 : (isDimmed ? 0.6 : 1)
    }

    private static func childRow(_ entry: FileEntry, palette: ThemePalette) -> UIView {
        let icon = entry.isDirectory ? nil : FileIcon.forPath(entry.name)
        let image = UIImageView(image: icon.map { $0.uiImage(pointSize: 11).withRenderingMode(.alwaysTemplate) } ?? UIImage(systemName: "folder.fill"))
        image.tintColor = icon?.color ?? palette.ui.blue
        image.contentMode = .scaleAspectFit
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2)
        image.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let label = UILabel()
        label.text = entry.name
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = palette.ui.fgDim
        let row = UIStackView(arrangedSubviews: [image, label])
        row.spacing = 6
        row.alignment = .center
        return row
    }
}

/// One pin as a tile on the Pinned screen (`PinTileView`). In Edit, a
/// remove button sits on the artwork's corner.
///
/// The cell is its own accessibility element (`pinned.pin.<key>`); the
/// remove button is the second one while editing (`pinned.pin.remove.<key>`).
final class PinTileCell: UICollectionViewCell {
    /// Edit's remove button; set by the screen.
    var remove: (() -> Void)?

    private let tile = PinTileView()
    private lazy var removeButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "minus.circle.fill")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemRed]))
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.remove?() })
        button.accessibilityLabel = String(localized: "Remove")
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [tile, removeButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: contentView.topAnchor),
            tile.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tile.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            removeButton.centerXAnchor.constraint(equalTo: tile.artworkView.leadingAnchor, constant: 6),
            removeButton.centerYAnchor.constraint(equalTo: tile.artworkView.topAnchor, constant: 6),
            removeButton.widthAnchor.constraint(equalToConstant: 44),
            removeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        contentView.clipsToBounds = false
        clipsToBounds = false
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ content: PinTileView.Content, isEditing: Bool, palette: ThemePalette, identifier: String, removeIdentifier: String) {
        tile.show(content, palette: palette)
        removeButton.isHidden = !isEditing
        removeButton.accessibilityIdentifier = removeIdentifier
        accessibilityIdentifier = identifier
        accessibilityElements = isEditing ? [removeButton] : nil
        isAccessibilityElement = !isEditing
    }

    override var isHighlighted: Bool {
        didSet { tile.isPressed = isHighlighted }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont(descriptor: fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]]), size: 0)
    }
}
