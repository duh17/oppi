import UIKit

extension UISlider {
    /// The slider between a small-text mark at its low end and a large-text
    /// mark at its high end, in a row the caller places instead of the slider.
    ///
    /// The marks are image views beside the slider, not its
    /// `minimumValueImage` and `maximumValueImage`: those throw in the Mac
    /// build's Mac idiom, like every other UISlider image and track or thumb
    /// tint (`scripts/uikit-structure-guard.ts`). The marks take the tint of
    /// the view they sit in, as the slider's own value images did.
    func withTextSizeMarks(symbolConfiguration: UIImage.SymbolConfiguration? = nil) -> UIStackView {
        let marks = ["textformat.size.smaller", "textformat.size.larger"].map { name in
            let mark = UIImageView(image: UIImage(systemName: name, withConfiguration: symbolConfiguration))
            mark.isAccessibilityElement = false
            mark.setContentHuggingPriority(.required, for: .horizontal)
            mark.setContentCompressionResistancePriority(.required, for: .horizontal)
            return mark
        }
        let row = UIStackView(arrangedSubviews: [marks[0], self, marks[1]])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        return row
    }
}
