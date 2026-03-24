import SwiftUI

/// Provider brand badge — colored initial letter.
///
/// Renders the provider's first letter in a brand-associated color.
/// Designed for compact spaces: pills, list rows, toolbar items.
/// The color is applied directly, so parent `foregroundStyle` won't override it.
struct ProviderIcon: View {
    let provider: String

    var body: some View {
        Text(initial)
            .font(.system(.caption2, design: .rounded, weight: .heavy))
            .foregroundStyle(brandColor)
    }

    /// Provider brand color (uses theme palette for visual cohesion).
    var brandColor: Color {
        switch provider.lowercased() {
        case "anthropic": return .themeOrange
        case "openai", "openai-codex": return .themeGreen
        case "google": return .themeBlue
        case "lmstudio": return .themePurple
        default: return .themeComment
        }
    }

    private var initial: String {
        switch provider.lowercased() {
        case "anthropic": return "A"
        case "openai", "openai-codex": return "O"
        case "google": return "G"
        case "lmstudio": return "L"
        default:
            return provider.first.map { String($0).uppercased() } ?? "?"
        }
    }
}
