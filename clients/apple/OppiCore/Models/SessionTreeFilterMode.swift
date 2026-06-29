import Foundation

/// Filter mode sent with `get_session_tree` commands.
enum SessionTreeFilterMode: String, CaseIterable, Sendable {
    case standard = "default"
    case noTools = "no-tools"
    case userOnly = "user-only"
    case labeledOnly = "labeled-only"
    case all = "all"

    var title: String {
        switch self {
        case .standard: return "Default"
        case .noTools: return "No Tools"
        case .userOnly: return "Users"
        case .labeledOnly: return "Labeled"
        case .all: return "All"
        }
    }
}
