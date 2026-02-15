import SwiftUI

extension Color {
    /// Risk-tier color palette for permission cards — tokyo night variant.
    static func riskColor(_ risk: RiskLevel) -> Color {
        switch risk {
        case .low: return .tokyoGreen
        case .medium: return .tokyoYellow
        case .high: return .tokyoOrange
        case .critical: return .tokyoRed
        }
    }
}

extension RiskLevel {
    /// Human-readable label.
    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .critical: return "Critical"
        }
    }

    /// SF Symbol name for risk indicators.
    var systemImage: String {
        switch self {
        case .low: return "checkmark.shield"
        case .medium: return "exclamationmark.shield"
        case .high: return "exclamationmark.triangle"
        case .critical: return "xmark.octagon"
        }
    }
}
