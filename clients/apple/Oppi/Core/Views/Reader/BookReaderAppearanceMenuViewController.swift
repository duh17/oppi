import UIKit

/// The reader's "Aa" sheet: theme, typeface, size, spacing, margins,
/// justification and layout, applied to the page as each control moves.
///
/// Every control writes the whole `BookReaderAppearance` back to the store, so
/// there is one source of truth and the chapter re-renders from a change
/// notification rather than from this sheet.
@MainActor
final class BookReaderAppearanceMenuViewController: UIViewController {
    private let store: BookReaderAppearanceStore
    private var appearance: BookReaderAppearance

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let sizeValueLabel = UILabel()
    private let smallerButton = UIButton(type: .system)
    private let largerButton = UIButton(type: .system)
    private let spacingControl = UISegmentedControl(
        items: BookLineSpacing.allCases.map(\.displayName)
    )
    private let marginControl = UISegmentedControl(
        items: BookMargins.allCases.map(\.displayName)
    )
    private let layoutControl = UISegmentedControl(
        items: BookReadingLayout.allCases.map(\.displayName)
    )
    private let justifySwitch = UISwitch()
    private var themeButtons: [BookReaderTheme: UIButton] = [:]
    private var fontButtons: [BookFontFamily: UIButton] = [:]
    /// The checkmark each typeface row shows when it is the chosen face.
    private var fontChecks: [BookFontFamily: UIImageView] = [:]
    /// Height the sheet asks for once its content is measured.
    private var measuredHeight: CGFloat = 420

    init(store: BookReaderAppearanceStore = .shared) {
        self.store = store
        self.appearance = store.appearance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        setUpContent()
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configurePresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSheetHeightIfNeeded()
    }

    /// A sheet that hugs its content on a phone and a popover at the control
    /// that opened it on a wide screen.
    private func configurePresentation() {
        let width = view.bounds.width
        if width > 0 {
            measureHeight(for: width)
        }
        if traitCollection.horizontalSizeClass == .regular {
            modalPresentationStyle = .popover
            preferredContentSize = CGSize(width: 340, height: measuredHeight)
            if let popover = popoverPresentationController {
                popover.permittedArrowDirections = .any
            }
            return
        }
        guard let sheet = sheetPresentationController else { return }
        sheet.detents = [Self.detent(height: { [weak self] in self?.measuredHeight ?? 420 })]
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 22
    }

    private static func detent(
        height: @escaping () -> CGFloat
    ) -> UISheetPresentationController.Detent {
        .custom(identifier: .init("bookAppearance")) { context in
            min(height(), context.maximumDetentValue)
        }
    }

    private func updateSheetHeightIfNeeded() {
        let width = view.bounds.width
        guard width > 0 else { return }
        let previous = measuredHeight
        measureHeight(for: width)
        guard abs(measuredHeight - previous) > 1, let sheet = sheetPresentationController else { return }
        sheet.animateChanges {
            sheet.detents = [Self.detent(height: { [weak self] in self?.measuredHeight ?? 420 })]
        }
    }

    /// The content's own height, plus the sheet's padding and the home
    /// indicator, capped so a tall Dynamic Type size still leaves the page
    /// visible behind the sheet.
    private func measureHeight(for width: CGFloat) {
        let contentWidth = max(width - 40, 240)
        let content = stack.systemLayoutSizeFitting(
            CGSize(width: contentWidth, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        measuredHeight = min(max(content + view.safeAreaInsets.bottom + 28, 300), 640)
        preferredContentSize = CGSize(width: min(width, 380), height: measuredHeight)
    }

    // MARK: - Content

    private func setUpContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.accessibilityIdentifier = "fullScreen.book.aa.sheet"
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                constant: -40
            ),
        ])

        stack.addArrangedSubview(makeSizeRow())
        stack.addArrangedSubview(makeSection(title: String(localized: "Theme"), content: makeThemeRow()))
        stack.addArrangedSubview(makeSection(title: String(localized: "Typeface"), content: makeFontList()))
        stack.addArrangedSubview(makeSection(title: String(localized: "Line Spacing"), content: spacingControl))
        stack.addArrangedSubview(makeSection(title: String(localized: "Margins"), content: marginControl))
        stack.addArrangedSubview(makeSection(title: String(localized: "Layout"), content: layoutControl))
        stack.addArrangedSubview(makeSection(title: String(localized: "Justification"), content: makeJustifyRow()))

        spacingControl.addTarget(self, action: #selector(spacingChanged), for: .valueChanged)
        marginControl.addTarget(self, action: #selector(marginsChanged), for: .valueChanged)
        layoutControl.addTarget(self, action: #selector(layoutChanged), for: .valueChanged)
    }

    private func makeSizeRow() -> UIView {
        let caption = UILabel()
        caption.text = "Aa"
        caption.font = BookFontFamily.newYork.font(size: 26, weight: .semibold, italic: false)
        caption.textColor = .label
        caption.setContentHuggingPriority(.required, for: .horizontal)

        for (button, symbol) in [(smallerButton, "textformat.size.smaller"), (largerButton, "textformat.size.larger")] {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
            button.configuration = configuration
            button.tintColor = .label
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        smallerButton.accessibilityIdentifier = "fullScreen.book.appearance.sizeDecrease"
        largerButton.accessibilityIdentifier = "fullScreen.book.appearance.sizeIncrease"
        smallerButton.accessibilityLabel = String(localized: "Smaller text")
        largerButton.accessibilityLabel = String(localized: "Larger text")
        smallerButton.addTarget(self, action: #selector(makeTextSmaller), for: .touchUpInside)
        largerButton.addTarget(self, action: #selector(makeTextLarger), for: .touchUpInside)

        sizeValueLabel.font = .preferredFont(forTextStyle: .footnote)
        sizeValueLabel.adjustsFontForContentSizeCategory = true
        sizeValueLabel.textColor = .secondaryLabel
        sizeValueLabel.textAlignment = .center
        sizeValueLabel.accessibilityIdentifier = "fullScreen.book.appearance.sizeValue"

        let row = UIStackView(arrangedSubviews: [caption, UIView(), smallerButton, sizeValueLabel, largerButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        sizeValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return row
    }

    private func makeSection(title: String, content: UIView) -> UIView {
        let header = UILabel()
        header.text = title
        header.font = .preferredFont(forTextStyle: .footnote)
        header.adjustsFontForContentSizeCategory = true
        header.textColor = .secondaryLabel

        let section = UIStackView(arrangedSubviews: [header, content])
        section.axis = .vertical
        section.spacing = 8
        return section
    }

    private func makeThemeRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        for theme in BookReaderTheme.allCases {
            let button = UIButton(type: .custom)
            button.setImage(swatchImage(for: theme), for: .normal)
            button.accessibilityIdentifier = "fullScreen.book.appearance.theme.\(theme.rawValue)"
            button.accessibilityLabel = theme.displayName
            button.addAction(
                UIAction { [weak self] _ in self?.select(theme: theme) },
                for: .touchUpInside
            )
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            themeButtons[theme] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    /// A paper circle with the theme's ink "A", and a checkmark badge on the
    /// selected one.
    private func swatchImage(for theme: BookReaderTheme) -> UIImage {
        let size = CGSize(width: 52, height: 52)
        let colors = theme.fixedColors
        let paper = colors?.paper ?? .secondarySystemBackground
        let ink = colors?.ink ?? .label
        let selected = appearance.theme == theme
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let circle = CGRect(x: 3, y: 3, width: 46, height: 46)
            let path = UIBezierPath(ovalIn: circle)
            paper.setFill()
            path.fill()
            UIColor.separator.setStroke()
            path.lineWidth = 1
            path.stroke()
            let letter = "A" as NSString
            let font = BookFontFamily.newYork.font(size: 22, weight: .semibold, italic: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
            let letterSize = letter.size(withAttributes: attributes)
            letter.draw(
                at: CGPoint(
                    x: circle.midX - letterSize.width / 2,
                    y: circle.midY - letterSize.height / 2
                ),
                withAttributes: attributes
            )
            guard selected else { return }
            let badge = CGRect(x: 34, y: 34, width: 20, height: 20)
            let badgePath = UIBezierPath(ovalIn: badge)
            self.view.tintColor.setFill()
            badgePath.fill()
            let check = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            check?.draw(in: CGRect(x: 39, y: 39, width: 10, height: 10))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    private func makeFontList() -> UIView {
        let list = UIStackView()
        list.axis = .vertical
        list.spacing = 2
        for family in BookFontFamily.allCases {
            // Each name is set in its own face, the way Books previews a type
            // list; the button is a transparent target over the row so the name
            // stays flush left and the checkmark flush right.
            let name = UILabel()
            name.text = family.displayName
            name.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: family.font(size: 17, weight: .regular, italic: false)
            )
            name.textColor = .label
            name.numberOfLines = 1

            let check = UIImageView(image: UIImage(systemName: "checkmark"))
            check.tintColor = .label
            check.setContentHuggingPriority(.required, for: .horizontal)
            check.isAccessibilityElement = false

            let row = UIStackView(arrangedSubviews: [name, UIView(), check])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 8
            row.isUserInteractionEnabled = false
            row.translatesAutoresizingMaskIntoConstraints = false

            let button = UIButton(type: .custom)
            button.accessibilityIdentifier = "fullScreen.book.appearance.font.\(family.rawValue)"
            button.accessibilityLabel = family.displayName
            button.addAction(
                UIAction { [weak self] _ in self?.select(fontFamily: family) },
                for: .touchUpInside
            )
            button.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                row.topAnchor.constraint(equalTo: button.topAnchor, constant: 8),
                row.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -8),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            ])
            fontButtons[family] = button
            fontChecks[family] = check
            list.addArrangedSubview(button)
        }
        return list
    }

    private func makeJustifyRow() -> UIView {
        let label = UILabel()
        label.text = String(localized: "Justify Text")
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0

        justifySwitch.accessibilityIdentifier = "fullScreen.book.appearance.justify"
        justifySwitch.accessibilityLabel = String(localized: "Justify Text")
        justifySwitch.addTarget(self, action: #selector(justifyChanged), for: .valueChanged)
        justifySwitch.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, justifySwitch])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    // MARK: - Actions

    private func select(theme: BookReaderTheme) {
        appearance.theme = theme
        commit()
    }

    private func select(fontFamily: BookFontFamily) {
        appearance.fontFamily = fontFamily
        commit()
    }

    @objc private func makeTextSmaller() {
        appearance.sizeStep = BookReaderAppearance.clampedSizeStep(appearance.sizeStep - 1)
        commit()
    }

    @objc private func makeTextLarger() {
        appearance.sizeStep = BookReaderAppearance.clampedSizeStep(appearance.sizeStep + 1)
        commit()
    }

    @objc private func spacingChanged() {
        appearance.lineSpacing = BookLineSpacing.allCases[spacingControl.selectedSegmentIndex]
        commit()
    }

    @objc private func marginsChanged() {
        appearance.margins = BookMargins.allCases[marginControl.selectedSegmentIndex]
        commit()
    }

    @objc private func layoutChanged() {
        appearance.layout = BookReadingLayout.allCases[layoutControl.selectedSegmentIndex]
        commit()
    }

    @objc private func justifyChanged() {
        appearance.justified = justifySwitch.isOn
        commit()
    }

    private func commit() {
        store.set(appearance)
        appearance = store.appearance
        updateControls()
        // The sheet's own height can change with the size row's label.
        measureHeight(for: view.bounds.width)
        updateSheetHeightIfNeeded()
    }

    /// Reflects the store in every control, including the states a screen
    /// reader announces.
    private func updateControls() {
        sizeValueLabel.text = String(
            format: String(localized: "%d pt"),
            Int(appearance.bodyPointSize().rounded())
        )
        smallerButton.isEnabled = appearance.sizeStep > BookReaderAppearance.sizeStepRange.lowerBound
        largerButton.isEnabled = appearance.sizeStep < BookReaderAppearance.sizeStepRange.upperBound

        for (theme, button) in themeButtons {
            button.setImage(swatchImage(for: theme), for: .normal)
            let isSelected = appearance.theme == theme
            if isSelected {
                button.accessibilityTraits.insert(.selected)
            } else {
                button.accessibilityTraits.remove(.selected)
            }
        }

        for (family, button) in fontButtons {
            let isSelected = appearance.fontFamily == family
            fontChecks[family]?.isHidden = !isSelected
            if isSelected {
                button.accessibilityTraits.insert(.selected)
            } else {
                button.accessibilityTraits.remove(.selected)
            }
        }

        spacingControl.selectedSegmentIndex = BookLineSpacing.allCases.firstIndex(of: appearance.lineSpacing) ?? 1
        marginControl.selectedSegmentIndex = BookMargins.allCases.firstIndex(of: appearance.margins) ?? 1
        layoutControl.selectedSegmentIndex = BookReadingLayout.allCases.firstIndex(of: appearance.layout) ?? 0
        justifySwitch.isOn = appearance.justified

        spacingControl.accessibilityLabel = String(localized: "Line Spacing")
        marginControl.accessibilityLabel = String(localized: "Margins")
        layoutControl.accessibilityLabel = String(localized: "Layout")
        spacingControl.accessibilityIdentifier = "fullScreen.book.appearance.spacing"
        marginControl.accessibilityIdentifier = "fullScreen.book.appearance.margins"
        layoutControl.accessibilityIdentifier = "fullScreen.book.appearance.layout"
    }
}
