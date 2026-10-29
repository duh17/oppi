import UIKit

extension ServerNotificationsSection.Consent {
    /// The relay disclosure alert, the same title, words, and three buttons
    /// wherever push or Live Activities is turned on. Nothing leaves the device
    /// before Turn On. An alert cannot hold a link, so Privacy Policy is a
    /// button: it closes the alert without turning anything on, and the person
    /// reads the policy, then turns the setting on again.
    ///
    /// Not a `Confirmation`: it has a third button. It is the one alert this
    /// disclosure needs, so the two surfaces share it.
    ///
    /// - Parameters:
    ///   - identifier: the alert's accessibility identifier.
    ///   - onCancel: Cancel, and Privacy Policy before it opens the policy.
    @MainActor
    func present(
        from screen: UIViewController,
        identifier: String,
        onTurnOn: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onPrivacyPolicy: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: title,
            message: ServerNotificationsSection.message(for: self),
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = identifier
        alert.addAction(UIAlertAction(title: String(localized: "Turn On"), style: .default) { _ in onTurnOn() })
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in onCancel() })
        alert.addAction(UIAlertAction(title: String(localized: "Privacy Policy"), style: .default) { _ in
            onCancel()
            onPrivacyPolicy()
        })
        Router.topPresenter(from: screen).present(alert, animated: true)
    }
}
