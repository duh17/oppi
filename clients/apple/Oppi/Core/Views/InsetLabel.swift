import UIKit

/// A label drawn with padding around its text, for small badges and pills.
/// `capsule` rounds it to its height; otherwise set `layer.cornerRadius`.
class InsetLabel: UILabel {
    var insets: UIEdgeInsets {
        didSet { invalidateIntrinsicContentSize() }
    }

    private let capsule: Bool

    init(insets: UIEdgeInsets, capsule: Bool) {
        self.insets = insets
        self.capsule = capsule
        super.init(frame: .zero)
        adjustsFontForContentSizeCategory = true
        layer.masksToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if capsule { layer.cornerRadius = bounds.height / 2 }
    }
}
