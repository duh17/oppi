import UIKit

/// Unified full-screen zoomable image viewer with share/save actions.
///
/// Used everywhere via direct UIKit presentation (``present(image:)``).
/// Pinch-to-zoom via UIScrollView with double-tap toggle. Bottom toolbar has
/// share and save-to-photos actions.
final class FullScreenImageViewController: UIViewController {
    private let image: UIImage
    private var scrollView: UIScrollView!
    private var imageView: UIImageView!
    private var savedFeedbackLabel: UILabel?

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupScrollView()
        setupImageView()
        setupConstraints()
        setupDoubleTap()
        setupDoneButton()
        setupBottomToolbar()
    }

    // MARK: - Setup

    private func setupScrollView() {
        scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        view.addSubview(scrollView)
    }

    private func setupImageView() {
        imageView = UIImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Pin all edges so contentLayoutGuide gets a deterministic content size
            // (equal to the viewport at zoomScale = 1). Center-only constraints can
            // leave content geometry underconstrained, causing the image to render
            // offset (top-left clipped) on first presentation.
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    private func setupDoubleTap() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    private func setupDoneButton() {
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        done.setTitleColor(.white, for: .normal)
        done.translatesAutoresizingMaskIntoConstraints = false
        done.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
        view.addSubview(done)

        NSLayoutConstraint.activate([
            done.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            done.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
        ])
    }

    private func setupBottomToolbar() {
        let toolbar = UIToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.barStyle = .black
        toolbar.isTranslucent = true
        toolbar.tintColor = .white
        view.addSubview(toolbar)

        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        let shareButton = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain,
            target: self,
            action: #selector(shareTapped)
        )
        let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let saveButton = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.down"),
            style: .plain,
            target: self,
            action: #selector(saveTapped(_:))
        )
        toolbar.items = [shareButton, flexSpace, saveButton]
    }

    // MARK: - Actions

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1.0 {
            scrollView.setZoomScale(1.0, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(
                width: scrollView.bounds.width / 2.5,
                height: scrollView.bounds.height / 2.5
            )
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }

    @objc private func dismissTapped() {
        dismiss(animated: true)
    }

    @objc private func shareTapped() {
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 44, width: 0, height: 0)
        present(activity, animated: true)
    }

    @objc private func saveTapped(_ sender: UIBarButtonItem) {
        PhotoLibrarySaver.save(image)
        showSavedFeedback()
    }

    private func showSavedFeedback() {
        // Remove existing feedback if any.
        savedFeedbackLabel?.removeFromSuperview()

        let label = UILabel()
        label.text = "Saved!"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        savedFeedbackLabel = label

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -56),
            label.widthAnchor.constraint(equalToConstant: 80),
            label.heightAnchor.constraint(equalToConstant: 32),
        ])

        UIView.animate(withDuration: 0.3, delay: 1.5, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
            if self.savedFeedbackLabel === label { self.savedFeedbackLabel = nil }
        }
    }
}

// MARK: - UIScrollViewDelegate

extension FullScreenImageViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }
}

// MARK: - Presentation Helper

extension FullScreenImageViewController {
    /// Present the image viewer from the topmost view controller.
    /// Works from both UIKit and SwiftUI contexts.
    static func present(image: UIImage) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let vc = FullScreenImageViewController(image: image)
        // Use .overFullScreen to prevent SwiftUI lifecycle churn (onDisappear/onAppear).
        vc.modalPresentationStyle = .overFullScreen
        presenter.present(vc, animated: true)
    }
}
