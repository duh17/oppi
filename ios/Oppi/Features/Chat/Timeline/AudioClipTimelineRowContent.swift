import UIKit

struct AudioClipTimelineRowConfiguration: UIContentConfiguration {
    let id: String
    let title: String
    let fileURL: URL
    let audioPlayer: AudioPlayerService
    let themeID: ThemeID

    func makeContentView() -> any UIView & UIContentView {
        AudioClipTimelineRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> Self {
        self
    }
}

private enum AudioClipButtonState {
    case idle
    case loading
    case playing
}

final class AudioClipTimelineRowContentView: UIView, UIContentView {
    private let containerView = UIView()
    private let rootStack = UIStackView()
    private let iconImageView = UIImageView()
    private let labelsStack = UIStackView()
    private let titleLabel = UILabel()
    private let fileNameLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    private var currentConfiguration: AudioClipTimelineRowConfiguration

    init(configuration: AudioClipTimelineRowConfiguration) {
        self.currentConfiguration = configuration
        super.init(frame: .zero)
        setupViews()
        apply(configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var configuration: UIContentConfiguration {
        get { currentConfiguration }
        set {
            guard let config = newValue as? AudioClipTimelineRowConfiguration else { return }
            apply(configuration: config)
        }
    }

    private func setupViews() {
        backgroundColor = .clear

        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.layer.cornerRadius = 8

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        rootStack.spacing = 10

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.image = UIImage(systemName: "waveform")

        labelsStack.translatesAutoresizingMaskIntoConstraints = false
        labelsStack.axis = .vertical
        labelsStack.alignment = .leading
        labelsStack.spacing = 2

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.numberOfLines = 1

        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = .preferredFont(forTextStyle: .caption2)
        fileNameLabel.lineBreakMode = .byTruncatingTail
        fileNameLabel.numberOfLines = 1

        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.contentHorizontalAlignment = .center
        playButton.contentVerticalAlignment = .center
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true

        addSubview(containerView)
        containerView.addSubview(rootStack)

        labelsStack.addArrangedSubview(titleLabel)
        labelsStack.addArrangedSubview(fileNameLabel)

        rootStack.addArrangedSubview(iconImageView)
        rootStack.addArrangedSubview(labelsStack)
        rootStack.addArrangedSubview(UIView())
        rootStack.addArrangedSubview(playButton)

        playButton.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),

            rootStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            rootStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            rootStack.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            rootStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -8),

            iconImageView.widthAnchor.constraint(equalToConstant: 14),
            iconImageView.heightAnchor.constraint(equalToConstant: 14),

            playButton.widthAnchor.constraint(equalToConstant: 44),
            playButton.heightAnchor.constraint(equalToConstant: 44),

            loadingIndicator.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
        ])
    }

    private func apply(configuration: AudioClipTimelineRowConfiguration) {
        currentConfiguration = configuration

        let palette = configuration.themeID.palette
        containerView.backgroundColor = UIColor(palette.bgDark)

        iconImageView.tintColor = UIColor(palette.purple)
        titleLabel.textColor = UIColor(palette.fg)
        fileNameLabel.textColor = UIColor(palette.comment)

        titleLabel.text = configuration.title
        fileNameLabel.text = configuration.fileURL.lastPathComponent

        loadingIndicator.color = UIColor(palette.purple)
        updatePlayButton(state: buttonState(for: configuration), palette: palette)
    }

    private func buttonState(for configuration: AudioClipTimelineRowConfiguration) -> AudioClipButtonState {
        if configuration.audioPlayer.loadingItemID == configuration.id {
            return .loading
        }

        if configuration.audioPlayer.playingItemID == configuration.id {
            return .playing
        }

        return .idle
    }

    private func updatePlayButton(state: AudioClipButtonState, palette: ThemePalette) {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        playButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)

        switch state {
        case .idle:
            loadingIndicator.stopAnimating()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
            playButton.tintColor = UIColor(palette.comment)

        case .loading:
            playButton.setImage(nil, for: .normal)
            playButton.tintColor = UIColor(palette.purple)
            loadingIndicator.startAnimating()

        case .playing:
            loadingIndicator.stopAnimating()
            playButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
            playButton.tintColor = UIColor(palette.purple)
        }
    }

    @objc
    private func togglePlayback() {
        currentConfiguration.audioPlayer.toggleFilePlayback(
            fileURL: currentConfiguration.fileURL,
            itemID: currentConfiguration.id
        )
        apply(configuration: currentConfiguration)
    }
}
