import UIKit

/// The bar's popovers: one picker slot, Busy mode, and the test hook.
extension ComposerBarController {
    var presentedActionIDForTesting: String? { presentedActionID }

    func presentActionForTesting(id: String) {
        presentActionPopover(id: id)
    }

    func presentBusyModePicker() {
        guard let host else { return }
        let picker = ComposerBusyModePickerController(
            selected: host.content.busyStreamingBehavior,
            colors: host.content.colors,
            onSelect: { [weak self] behavior in
                self?.host?.setBusyStreamingBehavior(behavior)
                self?.applyChrome()
            }
        )
        presentPopover(picker, from: busyModeButton, actionID: "chat.busyMode")
    }

    func presentActionPopover(id: String) {
        guard let host else { return }
        let actions = host.content.actionRow.leading + host.content.actionRow.trailing
        guard let action = actions.first(where: { $0.id == id }),
              case .picker(let spec) = action.kind,
              let source = pillViews[id] else { return }
        let screen = spec.make()
        presentPopover(screen, from: source, actionID: id)
    }

    private func presentPopover(_ screen: UIViewController, from source: UIView, actionID: String) {
        presentedPicker = screen
        presentedActionID = actionID
        if let container = screen as? RouterModalContainer {
            container.onDismissed = { [weak self] in
                self?.presentedPicker = nil
                self?.presentedActionID = nil
            }
        }
        Router.present(
            screen,
            presentation: .popover.arrowDirections(.down).keepsPopoverInCompactWidth(),
            from: self,
            sourceView: source,
            onDismiss: { [weak self] in
                self?.presentedPicker = nil
                self?.presentedActionID = nil
            }
        )
    }

    func refreshPresentedPopover(_ row: ComposerActionRow) {
        guard let presentedActionID, let presentedPicker else { return }
        let actions = row.leading + row.trailing
        guard let action = actions.first(where: { $0.id == presentedActionID }),
              case .picker(let spec) = action.kind else { return }
        spec.update?(presentedPicker)
    }

    func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}
