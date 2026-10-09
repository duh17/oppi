import Foundation

enum AppBuildIdentity {
    static let infoKey = "OPPIGitCommit"

    static var gitCommit: String? {
        gitCommit(infoValue: Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// Short SHA, optional `-dirty`. Missing, blank, unexpanded, and non-SHA
    /// values are omitted so a failed stamp cannot upload as `unknown`.
    static func gitCommit(infoValue: String?) -> String? {
        let trimmed = infoValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.range(
            of: #"^[0-9a-f]{7,40}(?:-dirty)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return nil
        }
        return trimmed.lowercased()
    }
}
