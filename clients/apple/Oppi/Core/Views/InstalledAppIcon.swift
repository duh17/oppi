import UIKit

/// The installed app icon from the bundle, or nil when it has none: the
/// onboarding hero, the App Lock cover, and the sidebar show it.
enum InstalledAppIcon {
    /// The name the Home Screen shows under the icon, for the icon's
    /// accessibility label, so renaming the bundle renames the label.
    static let displayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName")) as? String ?? ""

    @MainActor static let image: UIImage? = {
        // The Mac build ships its icon as AppIcon.icns. Its asset catalog's
        // AppIcon is a Mac icon that `UIImage(named:)` raises on, so the
        // catalog lookup below is for iOS only (an iOS bundle has no .icns).
        if let icns = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return UIImage(contentsOfFile: icns.path)
        }
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        let names = (files ?? []).reversed() + [primary?["CFBundleIconName"] as? String, "AppIcon"].compactMap { $0 }
        return names.lazy.compactMap { UIImage(named: $0) }.first
    }()
}
