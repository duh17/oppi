import SwiftUI

/// Compact provider mark for model/provider UIs.
///
/// Prefers a bundled provider logo asset when available. Falls back to a
/// monogram mark when we don't have a vetted local asset yet.
struct ProviderIcon: View {
    @Environment(\.themeID) private var themeID

    let provider: String
    var size: CGFloat = Self.defaultIconSize

    private static let defaultIconSize: CGFloat = 11

    var body: some View {
        Group {
            if let assetName = Self.logoAssetName(for: provider) {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(providerIconTint(
                        Self.brandColor(for: provider),
                        palette: themeID.palette
                    ))
            } else {
                Text(Self.mark(for: provider))
                    .font(.system(size: max(8, size * 0.8), weight: .heavy, design: .rounded))
                    .foregroundStyle(providerIconTint(
                        Self.brandColor(for: provider),
                        palette: themeID.palette
                    ))
            }
        }
        .frame(width: size, height: size, alignment: .center)
    }

    /// Human-friendly label for provider IDs used by pi/SDK.
    static func displayName(for provider: String) -> String {
        providerDisplayLabel(provider)
    }

    /// Asset catalog image name for a provider logo, if we have one.
    static func logoAssetName(for provider: String) -> String? {
        providerLogoAssetName(provider)
    }

    /// Provider color mapped onto the active theme palette.
    static func brandColor(for provider: String) -> Color {
        let canonical = canonicalProviderColorKey(for: provider)
        return ProviderColor.color(
            forProvider: canonical,
            palette: ThemeRuntimeState.currentPalette()
        )
    }

    /// Single-character monogram mark for compact rendering.
    static func mark(for provider: String) -> String {
        providerMonogram(provider)
    }

    private static func canonicalProviderColorKey(for provider: String) -> String {
        switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "openai-codex":
            return "openai"
        case "google-gemini-cli", "google-antigravity":
            return "google"
        case "minimax-cn":
            return "minimax"
        case "opencode-go":
            return "opencode"
        default:
            return provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}
