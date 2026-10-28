#if DEBUG
import SwiftUI
import UIKit

/// Launch-argument dispatch for the debug harnesses and screenshot previews.
///
/// This folder (clients/apple/OppiDebugHarness) compiles into the Oppi app
/// target in Debug only; Release excludes it (`EXCLUDED_SOURCE_FILE_NAMES` in
/// project.yml). `OppiApp.makeRootViewController()` calls `rootViewController`
/// under `#if DEBUG`, and that call is the app's only reference to this folder.
@MainActor
enum DebugHarnessLaunch {
    /// The window root for the harness or screenshot preview the launch
    /// arguments chose, or nil for the app.
    static func rootViewController(root: AppRootEnvironment) -> UIViewController? {
        if ReviewCommentStashHarnessConfig.isEnabled {
            return ReviewCommentStashHarnessController(root: root)
        }
        guard let harness = harnessView else { return nil }
        // Harnesses and previews render app screens, the timeline, and
        // UIKit-hosted SwiftUI without the app's root controller. The
        // router and HostFactory need the app root above them there too,
        // and the window needs the theme applied the way the app root does.
        return HarnessRootViewController(
            content: HostFactory.content(harness, root: root),
            themeStore: root.themeStore
        )
    }

    /// A harness screen reads the saved top bar layout, and a UI test can leave
    /// one behind on a simulator that outlives the run: `SCREENSHOT_RESET_TOP_BAR=1`
    /// puts the device back on the default before any screen reads it. Lazy and
    /// once per launch, so a later root rebuild cannot wipe a write from the
    /// same session.
    private static let resetSavedTopBarForHarness: Void = {
        guard ProcessInfo.processInfo.environment["SCREENSHOT_RESET_TOP_BAR"] == "1" else { return }
        AppPreferences.ChatTopBar.reset(in: .standard)
    }()

    /// The harness or screenshot preview chosen by launch arguments, or nil
    /// for the app.
    private static var harnessView: AnyView? {
        _ = resetSavedTopBarForHarness
        if HTMLDOMAnnotationHarnessConfig.isEnabled {
            return AnyView(HTMLDOMAnnotationHarnessView().ignoresSafeArea())
        }
        if WikiLineAnchorHarnessConfig.isEnabled {
            return AnyView(WikiLineAnchorHarnessView().ignoresSafeArea())
        }
        if SemanticPickHarnessConfig.isEnabled {
            return AnyView(SemanticPickHarnessView().ignoresSafeArea())
        }
        if FullScreenReviewCommentHarnessConfig.isEnabled {
            return AnyView(FullScreenReviewCommentHarnessView().ignoresSafeArea())
        }
        if CodeGutterAlignmentHarnessConfig.isEnabled {
            return AnyView(CodeGutterAlignmentHarnessView().ignoresSafeArea())
        }
        if CodeBlockWrappingHarnessConfig.isEnabled {
            return AnyView(CodeBlockWrappingHarnessView().ignoresSafeArea())
        }
        if ChatOutlineColdHarnessConfig.isEnabled {
            return AnyView(ChatOutlineColdHarnessView())
        }
        if NavigationChromeProfileConfig.isEnabled {
            return AnyView(NavigationChromeProfileHarnessView())
        }
        if UIHangHarnessConfig.isEnabled {
            return AnyView(UIHangHarnessView())
        }
        if ScreenshotPreviewConfig.isEnabled {
            if ScreenshotPreviewConfig.screen == "usage" {
                return AnyView(UsageChromePreview())
            }
            return AnyView(ScreenshotPreviewView())
        }
        return nil
    }
}

/// The window root for debug harnesses and screenshot previews, which render
/// app screens without `AppRootViewController`: it applies the theme to the
/// window the same way, so a preview's sheets match its content.
final class HarnessRootViewController: UIViewController {
    private let themeStore: ThemeStore
    private let content: UIViewController
    private let appLock = AppLockService.shared

    init(content: UIViewController, themeStore: ThemeStore) {
        self.content = content
        self.themeStore = themeStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: Self, _: UITraitCollection) in
            controller.themeStore.followSystemAppearance(from: controller)
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        themeStore.applyToWindow(of: self)
    }

    override func updateProperties() {
        super.updateProperties()
        themeStore.applyToWindow(of: self)
        // VoiceOver skips the harness content while the App Lock cover
        // window is up above it.
        content.view.accessibilityElementsHidden = appLock.isLocked
    }
}
#endif
