import UIKit

extension UIViewController {
    /// Ends `list` at the top of the keyboard instead of the bottom of the view,
    /// so a field or editor in it can scroll above the keyboard. The list is
    /// pinned to the view's bottom already (`SettingsListStyle.pin`); this
    /// replaces that one constraint. Call it after the list is pinned, once.
    func endListAtKeyboard(_ list: UIScrollView) {
        guard let view = viewIfLoaded else { return }
        let bottoms = view.constraints.filter {
            $0.firstItem === list && $0.firstAttribute == .bottom && $0.secondItem === view
        }
        assert(!bottoms.isEmpty, "\(type(of: self)) pinned its list to something other than the view's bottom")
        NSLayoutConstraint.deactivate(bottoms)
        view.keyboardLayoutGuide.usesBottomSafeArea = false
        list.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
    }
}
