#if DEBUG
import UIKit

/// Fixtures for `SCREENSHOT_SCREEN=app-lock-cover` (locked), `app-lock-cover-failed`
/// (locked after a failed attempt), and `app-lock-cover-obscured` (App Lock off:
/// only the app identity): the production `AppLockCoverViewController` over a
/// fixture `AppLockService`. `ScreenshotPreviewView` mounts it.
/// Dump with `UIValidateTests`, `OPPI_UI_VALIDATE_READY=appLock.cover`.
enum AppLockCoverScreenshotFixture {
    enum State {
        case locked, failed, obscured
    }

    @MainActor
    static func makeController(state: State) -> AppLockCoverViewController {
        let themeID: ThemeID = ProcessInfo.processInfo.environment["SCREENSHOT_COLOR_SCHEME"] == "light" ? .light : .dark
        ThemeRuntimeState.setThemeID(themeID)

        guard let defaults = UserDefaults(suiteName: "AppLockCoverScreenshotFixture-\(UUID().uuidString)") else {
            preconditionFailure("isolated UserDefaults suite")
        }
        AppLockSettings.setTimeout(state == .obscured ? .off : .fiveMinutes, in: defaults)
        let service = AppLockService(
            defaults: defaults,
            availability: { .available },
            method: { .faceID },
            authenticator: { _ in .failed },
            isProtectedDataAvailable: { true }
        )
        if state == .failed {
            Task { await service.unlock() }
        }
        let controller = AppLockCoverViewController(service: service)
        controller.overrideUserInterfaceStyle = themeID.preferredColorScheme == .light ? .light : .dark
        return controller
    }
}
#endif
