import UIKit

/// A full-width segmented control row (the MCP add-server form's transport).
final class AgentNativeEditSegmentedCell: UICollectionViewListCell {
    private let control = UISegmentedControl()
    private var onChange: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onChange?(control.selectedSegmentIndex)
        }, for: .valueChanged)
        contentView.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            control.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        accessibilityElements = [control]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(titles: [String], selectedIndex: Int, identifier: String, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        if (0..<control.numberOfSegments).map({ control.titleForSegment(at: $0) }) != titles {
            control.removeAllSegments()
            for (index, title) in titles.enumerated() {
                control.insertSegment(withTitle: title, at: index, animated: false)
            }
        }
        control.selectedSegmentIndex = selectedIndex
        control.accessibilityIdentifier = identifier
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onChange = nil
    }
}
