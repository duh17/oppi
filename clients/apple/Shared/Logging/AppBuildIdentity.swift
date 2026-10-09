import Foundation

enum AppBuildIdentity {
    static let infoKey = "OPPIGitCommit"

    static var gitCommit: String {
        gitCommit(infoValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// Short SHA, optional `-dirty`. Unexpanded build settings and blanks are unknown.
    static func gitCommit(infoValue: String?) -> String {
        let trimmed = infoValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return "unknown" }
        return trimmed
    }
}
