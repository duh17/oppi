import Foundation

/// Mac composer projection for the shared session thinking-level command.
///
/// The server stores this as an optional raw string on `Session`. Keep the UI
/// tolerant of missing or newer values while still sending the shared protocol
/// enum back to the session stream.
enum MacComposerThinkingLevel: String, CaseIterable, Identifiable, Sendable, Equatable, Hashable {
    case off
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    init(sessionValue: String?) {
        guard let normalized = sessionValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let value = Self(rawValue: normalized) else {
            self = .medium
            return
        }
        self = value
    }

    var protocolLevel: ThinkingLevel {
        switch self {
        case .off: .off
        case .minimal: .minimal
        case .low: .low
        case .medium: .medium
        case .high: .high
        case .xhigh: .xhigh
        case .max: .max
        }
    }

    var displayTitle: String {
        switch self {
        case .off: "Off"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "XHigh"
        case .max: "Max"
        }
    }
}
