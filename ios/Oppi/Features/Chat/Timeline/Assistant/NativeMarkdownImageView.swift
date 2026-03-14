import UIKit

/// UIKit view that loads and displays a workspace image referenced in markdown.
///
/// Lifecycle: apply(url:alt:apiClient:) triggers an async load. States:
/// - loading: spinner + alt text label
/// - loaded: image view (tap to fullscreen)
/// - failed: bracketed alt text in comment color
@MainActor
final class NativeMarkdownImageView: UIView {
    private static let imageCache = NSCache<NSURL, UIImage>()
    private static let maxRenderHeight: CGFloat = 400

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let altLabel = UILabel()
    private let imageView = UIImageView()
    private let errorLabel = UILabel()

    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?

    typealias FetchWorkspaceFile = (_ workspaceID: String, _ path: String) async throws -> Data

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 8
        clipsToBounds = true
        backgroundColor = UIColor(ThemeRuntimeState.currentPalette().bgHighlight)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true

        altLabel.translatesAutoresizingMaskIntoConstraints = false
        altLabel.font = .preferredFont(forTextStyle: .caption1)
        altLabel.textAlignment = .center
        altLabel.numberOfLines = 2

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.isHidden = true
        imageView.isUserInteractionEnabled = true

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.font = .preferredFont(forTextStyle: .body)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 2
        errorLabel.isHidden = true

        addSubview(imageView)
        addSubview(spinner)
        addSubview(altLabel)
        addSubview(errorLabel)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        imageView.addGestureRecognizer(tapGesture)

        NSLayoutConstraint.activate([
            // Loading state: spinner + alt
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -14),

            altLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 6),
            altLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            altLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            // Image view fills available width
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Error label centered
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    func apply(url: URL, alt: String, fetchWorkspaceFile: FetchWorkspaceFile?) {
        guard url != currentURL else { return }
        currentURL = url

        loadTask?.cancel()
        showLoadingState(alt: alt)

        // Check synchronous cache first.
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            showLoadedState(image: cached)
            return
        }

        loadTask = Task { [weak self] in
            await self?.loadImage(url: url, alt: alt, fetch: fetchWorkspaceFile)
        }
    }

    private func loadImage(url: URL, alt: String, fetch: FetchWorkspaceFile?) async {
        guard let fetch else {
            showErrorState(alt: alt)
            return
        }

        guard let components = WorkspaceFileURL.parse(url) else {
            showErrorState(alt: alt)
            return
        }

        do {
            let data = try await fetch(components.workspaceID, components.filePath)
            guard !Task.isCancelled else { return }

            guard let image = UIImage(data: data) else {
                showErrorState(alt: alt)
                return
            }

            Self.imageCache.setObject(image, forKey: url as NSURL)
            showLoadedState(image: image)
        } catch {
            guard !Task.isCancelled else { return }
            showErrorState(alt: alt)
        }
    }

    private func showLoadingState(alt: String) {
        let palette = ThemeRuntimeState.currentPalette()
        backgroundColor = UIColor(palette.bgHighlight)
        spinner.color = UIColor(palette.comment)
        altLabel.textColor = UIColor(palette.comment)
        altLabel.text = alt.isEmpty ? nil : alt

        spinner.startAnimating()
        altLabel.isHidden = alt.isEmpty
        imageView.isHidden = true
        errorLabel.isHidden = true
    }

    private func showLoadedState(image: UIImage) {
        spinner.stopAnimating()
        altLabel.isHidden = true
        errorLabel.isHidden = true

        // Compute display height from aspect ratio, capped at max.
        let aspectRatio = image.size.height / max(image.size.width, 1)
        let displayWidth = bounds.width > 0
            ? bounds.width
            : (window?.windowScene?.screen.bounds.width ?? bounds.width)
        let naturalHeight = displayWidth * aspectRatio
        let displayHeight = min(naturalHeight, Self.maxRenderHeight)

        // Reset height constraint.
        for constraint in constraints where constraint.firstAttribute == .height {
            constraint.isActive = false
        }
        heightAnchor.constraint(equalToConstant: max(displayHeight, 80)).isActive = true

        imageView.image = image
        imageView.isHidden = false
        backgroundColor = .clear
    }

    private func showErrorState(alt: String) {
        spinner.stopAnimating()
        imageView.isHidden = true

        if alt.isEmpty {
            isHidden = true
            return
        }

        let palette = ThemeRuntimeState.currentPalette()
        errorLabel.textColor = UIColor(palette.comment)
        errorLabel.text = "[\(alt)]"
        errorLabel.isHidden = false
        backgroundColor = .clear
    }

    @objc private func handleTap() {
        guard let image = imageView.image else { return }
        FullScreenImageViewController.present(image: image)
    }
}
