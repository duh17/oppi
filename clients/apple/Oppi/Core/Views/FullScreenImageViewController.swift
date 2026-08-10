import UIKit

/// Unified zoomable image viewer with share/save actions.
///
/// Presented as a large detent sheet so it matches the app's slide-down
/// dismissal behavior used by other "full-screen" previews.
final class FullScreenImageViewController: UIViewController {
    private let image: UIImage
    private var palette: ThemePalette
    private let scrollView = UIScrollView()
    private let toolbar = UIToolbar()
    private let imageView: UIImageView
    private var swipeDismissHandler: HorizontalBackSwipeGestureInstaller?
    private var savedFeedbackLabel: UILabel?

    init(image: UIImage) {
        self.image = image
        self.palette = ThemeRuntimeState.currentThemeID().palette
        self.imageView = UIImageView(image: image)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .oppiThemeDidChange, object: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(palette.bgDark)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThemeChangeNotification),
            name: .oppiThemeDidChange,
            object: nil
        )

        setupNavigationChrome()
        setupSwipeDismiss()
        setupScrollView()
        setupImageView()
        setupConstraints()
        setupDoubleTap()
        setupBottomToolbar()
    }

    // MARK: - Setup

    private func setupNavigationChrome() {
        navigationItem.leftBarButtonItem = FullScreenViewerNavigationChrome.makeDismissButton(
            mode: .modal,
            target: self,
            action: #selector(dismissTapped),
            palette: palette,
            accessibilityIdentifier: "fullscreen-image.dismiss"
        )

        // No custom UINavigationBarAppearance — iOS 26 Liquid Glass renders
        // bar items as floating glass pills. See FullScreenViewerChrome.
    }

    private func setupSwipeDismiss() {
        let handler = HorizontalBackSwipeGestureInstaller(
            onBack: { [weak self] in
                self?.dismiss(animated: true)
            },
            direction: FullScreenViewerNavigationChrome.DismissMode.modal.gestureDirection
        )
        handler.install(on: view)
        swipeDismissHandler = handler
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.delegate = self
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = UIColor(palette.bgDark)
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
    }

    private func setupImageView() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // Top pinned to view edge (not safe area) so content extends behind
            // the navigation bar's Liquid Glass pills. See FullScreenViewerChrome.
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

    private func setupBottomToolbar() {
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        applyToolbarTheme()

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

    private func applyToolbarTheme() {
        toolbar.tintColor = UIColor(palette.cyan)
        let appearance = UIToolbarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(palette.bgHighlight)
        appearance.shadowColor = UIColor(palette.comment).withAlphaComponent(0.2)
        toolbar.standardAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
        toolbar.compactAppearance = appearance
    }

    @objc private func handleThemeChangeNotification(_: Notification) {
        let themeID = ThemeRuntimeState.currentThemeID()
        palette = themeID.palette
        let interfaceStyle: UIUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        overrideUserInterfaceStyle = interfaceStyle
        navigationController?.overrideUserInterfaceStyle = interfaceStyle
        navigationController?.view.backgroundColor = UIColor(palette.bgDark)
        view.backgroundColor = UIColor(palette.bgDark)
        scrollView.backgroundColor = UIColor(palette.bgDark)
        applyToolbarTheme()
        setupNavigationChrome()

        if let savedFeedbackLabel {
            savedFeedbackLabel.textColor = UIColor(palette.fg)
            savedFeedbackLabel.backgroundColor = UIColor(
                ThemeSurfaceStyle.resolve(.opaqueCard, palette: palette).fill
            )
            savedFeedbackLabel.layer.borderColor = UIColor(palette.comment)
                .withAlphaComponent(0.25).cgColor
        }
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
        guard let pngData = image.pngData() else { return }
        let content = FileShareService.ShareableContent.imageData(pngData, filename: "image.png")
        Task {
            await FileSharePresenter.shareDefault(content)
        }
    }

    @objc private func saveTapped(_: UIBarButtonItem) {
        PhotoLibrarySaver.save(image)
        showSavedFeedback()
    }

    private func showSavedFeedback() {
        // Remove existing feedback if any.
        savedFeedbackLabel?.removeFromSuperview()

        let label = UILabel()
        label.text = "Saved"
        label.font = AppFont.systemFeedbackMedium
        label.textColor = UIColor(palette.fg)
        label.textAlignment = .center
        label.backgroundColor = UIColor(
            ThemeSurfaceStyle.resolve(.opaqueCard, palette: palette).fill
        )
        label.layer.cornerRadius = 8
        label.layer.borderWidth = 1
        label.layer.borderColor = UIColor(palette.comment).withAlphaComponent(0.25).cgColor
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

@MainActor
final class ImagePreviewNavigationController: UINavigationController, UIAdaptivePresentationControllerDelegate {
    private var viewportRestoration: TimelineScrollCoordinator.ImagePreviewViewportRestoration?
    private var restorationScheduled = false
    private var presentationSucceeded = false

    func preserveTimelineViewport(from presenter: UIViewController) {
        viewportRestoration = TimelineScrollCoordinator.captureImagePreviewViewport(from: presenter)
        presentationController?.delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        scheduleViewportRestoration()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        scheduleViewportRestoration()
    }

    func presentationDidSucceed() {
        guard !presentationSucceeded, viewportRestoration != nil else { return }
        presentationSucceeded = true
        presentationController?.delegate = self
        viewportRestoration?.restore()
    }

    func presentationDidAbort() {
        guard !presentationSucceeded, let viewportRestoration else { return }
        self.viewportRestoration = nil
        viewportRestoration.cancel()
    }

    private func scheduleViewportRestoration() {
        guard !restorationScheduled, let viewportRestoration else { return }
        restorationScheduled = true
        self.viewportRestoration = nil

        if let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: nil) { _ in
                Task { @MainActor in viewportRestoration.finish() }
            }
        } else {
            DispatchQueue.main.async {
                viewportRestoration.finish()
            }
        }
    }
}

@MainActor
enum ImagePreviewPresentationCoordinator {
    static func present(_ controller: UIViewController, from presenter: UIViewController) {
        let navigation = controller as? ImagePreviewNavigationController
        navigation?.preserveTimelineViewport(from: presenter)
        presenter.present(controller, animated: true) {
            navigation?.presentationDidSucceed()
        }
        navigation?.presentationController?.delegate = navigation

        // UIKit does not guarantee the presentation completion for a rejected
        // or interrupted attempt. Check the actual ownership relationship on
        // the next main turn and observe cancellation on a real transition.
        // Retain the navigation controller through this one-shot decision.
        // A rejected UIKit presentation may not retain it at all, while its
        // viewport-restoration token still owns logical freeze cleanup.
        DispatchQueue.main.async { [navigation] in
            guard let navigation else { return }
            let isPresented = navigation.presentingViewController != nil
                || navigation.viewIfLoaded?.window != nil
            guard isPresented else {
                navigation.presentationDidAbort()
                return
            }

            guard let transitionCoordinator = navigation.transitionCoordinator else {
                navigation.presentationDidSucceed()
                return
            }
            transitionCoordinator.animate(alongsideTransition: nil) { context in
                if context.isCancelled {
                    navigation.presentationDidAbort()
                } else {
                    navigation.presentationDidSucceed()
                }
            }
        }
    }
}

extension FullScreenImageViewController {
    /// Build a large-detent sheet controller with the app's standard
    /// slide-down dismissal affordance.
    static func makeSlideDownController(
        image: UIImage,
        prefersFullScreenOverlay: Bool = false
    ) -> UIViewController {
        let themeID = ThemeRuntimeState.currentThemeID()
        let viewer = FullScreenImageViewController(image: image)
        let navigation = ImagePreviewNavigationController(rootViewController: viewer)
        navigation.view.backgroundColor = UIColor(themeID.palette.bgDark)

        if prefersFullScreenOverlay {
            navigation.modalPresentationStyle = .overFullScreen
            navigation.modalTransitionStyle = .coverVertical
        } else {
            navigation.modalPresentationStyle = .pageSheet
            if let sheet = navigation.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
            }
        }

        navigation.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        return navigation
    }

    /// Present the image viewer from a specific presenter.
    static func present(image: UIImage, from presenter: UIViewController) {
        ImagePreviewPresentationCoordinator.present(
            makeSlideDownController(
                image: image,
                prefersFullScreenOverlay: FullScreenViewerPresentationPolicy.prefersFullScreenOverlay(
                    for: presenter.traitCollection
                )
            ),
            from: presenter
        )
    }

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
        present(image: image, from: presenter)
    }
}
