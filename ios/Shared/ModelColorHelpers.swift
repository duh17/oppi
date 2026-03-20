import SwiftUI

// MARK: - Shared model-color helpers (used by DailyCostChart + ModelBreakdownView + ActivityHeatmap + ModelDonutChart)

/// Brand-aligned model colors.
///
/// Anthropic (Claude): warm orange/sienna family — opus is deep amber,
/// sonnet is warm orange, haiku is light apricot.
/// OpenAI: ChatGPT teal green.
/// Google: Gemini blue.
/// Local/MLX: neutral gray.
func modelColor(_ model: String) -> Color {
    let lower = model.lowercased()
    // Anthropic — orange variants
    if lower.contains("opus")   { return Color(red: 0.80, green: 0.42, blue: 0.17) } // #CC6B2C deep amber
    if lower.contains("sonnet") { return Color(red: 0.91, green: 0.57, blue: 0.31) } // #E8924E warm orange
    if lower.contains("haiku")  { return Color(red: 0.94, green: 0.72, blue: 0.48) } // #F0B87A apricot
    // OpenAI — teal green
    if lower.contains("gpt") || lower.contains("codex") { return Color(red: 0.06, green: 0.64, blue: 0.50) } // #10A37F
    // Google — Gemini blue
    if lower.contains("gemini") { return Color(red: 0.26, green: 0.52, blue: 0.96) } // #4285F4
    // Local/MLX — neutral
    if lower.contains("mlx")    { return Color(red: 0.55, green: 0.55, blue: 0.60) } // #8C8C99
    // Deterministic fallback
    let hue = Double(abs(model.hashValue % 300) + 30) / 360.0
    return Color(hue: hue, saturation: 0.5, brightness: 0.65)
}

/// Shorten model names for display.
/// "anthropic/claude-sonnet-4-6-20250514" → "sonnet-4-6"
func displayModelName(_ model: String) -> String {
    // Strip provider prefix (e.g. "anthropic/")
    let last = String(model.split(separator: "/").last ?? Substring(model))
    var cleaned = last.replacingOccurrences(of: "claude-", with: "")
    // Drop trailing 8-digit date segment
    let parts = cleaned.split(separator: "-")
    if let tail = parts.last, tail.count >= 8, tail.allSatisfy(\.isNumber) {
        cleaned = parts.dropLast().joined(separator: "-")
    }
    return cleaned
}
