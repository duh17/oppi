import UIKit

/// Settings > Privacy & Security: App Lock, Confirm New Servers, Send
/// Diagnostics, and the Privacy Policy link. All of it is saved on this device.
///
/// App Lock and Confirm New Servers guard themselves: changing or turning off an
/// active App Lock, and turning Confirm New Servers off while App Lock is on,
/// ask for device authentication first, so someone holding the unlocked app
/// cannot quietly weaken them. A cancelled prompt leaves the control where it was.
@MainActor
final class SettingsPrivacyViewController: SettingsListViewController<SettingsPrivacyViewController.Section, SettingsPrivacyViewController.Item> {
    enum Section: Hashable, Sendable { case appLock, confirmNewServers, diagnostics, privacyPolicy }
    enum Item: Hashable, Sendable { case appLock, confirmNewServers, diagnostics, privacyPolicy }

    private let root: AppRootEnvironment
    private let appLock: AppLockService

    init(root: AppRootEnvironment, appLock: AppLockService = .shared) {
        self.root = root
        self.appLock = appLock
        super.init(
            title: String(localized: "Privacy & Security"),
            listIdentifier: "settings.privacy.list",
            scope: .device,
            footers: true
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Passcode and biometry can change in iOS Settings while Oppi is away.
        appLock.refreshAvailability()
    }

    // MARK: - Sections

    override func sections() -> [SettingsSectionModel<Section, Item>] {
        [
            SettingsSectionModel(
                .appLock,
                footer: SettingsPrivacyCopy.appLockFooter(
                    timeout: appLock.timeout,
                    isAvailable: appLock.isAvailable,
                    method: appLock.method,
                    deviceName: Self.deviceName
                ),
                items: [.appLock]
            ),
            SettingsSectionModel(
                .confirmNewServers,
                footer: SettingsPrivacyCopy.confirmNewServersFooter(
                    isOn: BiometricService.shared.isEnabled,
                    method: appLock.method,
                    deviceName: Self.deviceName
                ),
                items: [.confirmNewServers]
            ),
            SettingsSectionModel(
                .diagnostics,
                footer: AppPreferences.Telemetry.isEnabled
                    ? String(localized: "Diagnostics are sent only to your server.")
                    : String(localized: "Diagnostics uploads are off."),
                items: [.diagnostics]
            ),
            SettingsSectionModel(
                .privacyPolicy,
                footer: String(localized: "Explains where Oppi data goes. Opens using your Open Links setting."),
                items: [.privacyPolicy]
            ),
        ]
    }

    override func inputs(of item: Item) -> AnyHashable {
        switch item {
        case .appLock:
            AnyHashable([AnyHashable(shownTimeout), AnyHashable(appLock.isAvailable), AnyHashable(appLock.isAuthenticating)])
        case .confirmNewServers:
            AnyHashable([AnyHashable(BiometricService.shared.isEnabled), AnyHashable(appLock.isAuthenticating)])
        case .diagnostics:
            AnyHashable(AppPreferences.Telemetry.isEnabled)
        case .privacyPolicy:
            AnyHashable(0)
        }
    }

    // MARK: - Cells

    private lazy var menuRow = UICollectionView.CellRegistration<SettingsMenuRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: String(localized: "App Lock"),
            identifier: "settings.appLock",
            isEnabled: appLock.isAvailable && !appLock.isAuthenticating,
            options: AppLockTimeout.allCases.map { timeout in
                (timeout.title, timeout == shownTimeout, { [weak self] in self?.changeAppLock(to: timeout) })
            }
        )
    }

    private lazy var linkRow = UICollectionView.CellRegistration<SettingsActionRowCell, Item> { [weak self] cell, _, _ in
        guard let self else { return }
        cell.configure(
            title: String(localized: "Privacy Policy"),
            systemImage: "hand.raised",
            identifier: "settings.privacyPolicy",
            hint: String(localized: "Opens Oppi's public Privacy Policy")
        ) { [weak self] in
            self?.root.opener.open(.webLink(AppSupportLinks.privacyPolicyURL))
        }
    }

    override func prepareRegistrations() {
        _ = (menuRow, linkRow)
    }

    override func dequeue(_ item: Item, at indexPath: IndexPath) -> UICollectionViewCell {
        switch item {
        case .appLock: collectionView.dequeueConfiguredReusableCell(using: menuRow, for: indexPath, item: item)
        case .privacyPolicy: collectionView.dequeueConfiguredReusableCell(using: linkRow, for: indexPath, item: item)
        case .confirmNewServers, .diagnostics: super.dequeue(item, at: indexPath)
        }
    }

    override func configure(_ cell: UICollectionViewListCell, item: Item) {
        switch item {
        case .confirmNewServers:
            toggleRow(
                cell,
                title: String(localized: "Confirm New Servers"),
                isOn: BiometricService.shared.isEnabled,
                identifier: "settings.confirmNewServers",
                isEnabled: !appLock.isAuthenticating
            ) { [weak self] in self?.changeConfirmNewServers(to: $0) }
        case .diagnostics:
            toggleRow(
                cell,
                title: String(localized: "Send Diagnostics"),
                isOn: AppPreferences.Telemetry.isEnabled,
                identifier: "settings.sendDiagnostics"
            ) { [weak self] in self?.setDiagnostics($0) }
        case .appLock, .privacyPolicy:
            break
        }
    }

    // MARK: - Changes

    /// Shows Off while the device has no passcode, as App Lock cannot run there.
    private var shownTimeout: AppLockTimeout { appLock.isAvailable ? appLock.timeout : .off }

    /// Turning App Lock on is always allowed. Changing or turning off an active
    /// one asks for device authentication first. Returns once the change is
    /// made or refused.
    @discardableResult
    func changeAppLock(to timeout: AppLockTimeout) -> Task<Void, Never> {
        Task { [appLock] in
            guard timeout != appLock.timeout else { return }
            guard appLock.isEnabled else {
                appLock.setTimeout(timeout)
                return
            }
            if await appLock.authorizeProtectedAction(reason: String(localized: "Change App Lock")) {
                appLock.setTimeout(timeout)
            }
        }
    }

    /// Turning Confirm New Servers off while App Lock is on asks first; every
    /// other change is made at once. Returns once the change is made or refused.
    @discardableResult
    func changeConfirmNewServers(to enabled: Bool) -> Task<Void, Never> {
        Task { [appLock, weak self] in
            if !enabled, appLock.isEnabled {
                guard await appLock.authorizeProtectedAction(reason: String(localized: "Turn off Confirm New Servers")) else {
                    self?.setNeedsUpdateProperties()
                    return
                }
            }
            BiometricService.shared.isEnabled = enabled
            self?.setNeedsUpdateProperties()
        }
    }

    private func setDiagnostics(_ enabled: Bool) {
        AppPreferences.Telemetry.setEnabled(enabled)
        MetricKitService.shared.refreshAfterPreferenceChange()
        DeviceResourceSampler.shared.refreshAfterPreferenceChange()
        setNeedsUpdateProperties()
    }

    private static var deviceName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}

/// The words Privacy & Security shows under its App Lock and Confirm New
/// Servers controls, for the current setting and the device's authentication.
enum SettingsPrivacyCopy {
    static func authenticationPhrase(method: DeviceOwnerAuthentication.Method, deviceName: String) -> String {
        method == .passcode
            ? "your \(deviceName) passcode"
            : "\(method.name) or your \(deviceName) passcode"
    }

    static func confirmNewServersFooter(isOn: Bool, method: DeviceOwnerAuthentication.Method, deviceName: String) -> String {
        isOn
            ? "Asks for \(authenticationPhrase(method: method, deviceName: deviceName)) before Oppi trusts a new server or a server whose identity changed."
            : "New and changed servers are trusted without device authentication."
    }

    static func appLockFooter(
        timeout: AppLockTimeout,
        isAvailable: Bool,
        method: DeviceOwnerAuthentication.Method,
        deviceName: String
    ) -> String {
        guard isAvailable else {
            return "Set a passcode on this \(deviceName) to use App Lock."
        }
        let scope = "It does not protect data on your servers or other paired devices."
        let when: String
        switch timeout {
        case .off:
            return "Oppi opens without asking. App Lock guards Oppi from someone holding your unlocked \(deviceName). \(scope)"
        case .immediately:
            when = "every time you return"
        case .oneMinute:
            when = "after 1 minute away"
        case .fiveMinutes:
            when = "after 5 minutes away"
        case .fifteenMinutes:
            when = "after 15 minutes away"
        }
        let unlock = method == .passcode
            ? "Oppi asks for your \(deviceName) passcode \(when), never while it is open."
            : "Oppi asks for \(method.name) \(when), never while it is open. Your \(deviceName) passcode also unlocks it."
        let share = method == .passcode ? "your passcode" : method.name
        return "\(unlock) While App Lock is on, Oppi's own notifications and Live Activities never show session text, and Share asks for \(share) each time. \(scope)"
    }
}
