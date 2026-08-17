import Foundation

/// Canonical public documentation links used by Settings and first-run onboarding.
///
/// The repository path is stable after the change is merged to `main`; the
/// app never treats these pages as an account or server endpoint.
enum AppSupportLinks {
    static let privacyPolicyURL = publicURL("https://github.com/duh17/oppi/blob/main/docs/privacy.md")
    static let supportURL = publicURL("https://github.com/duh17/oppi/blob/main/docs/support.md")
    static let setupURL = publicURL("https://github.com/duh17/oppi/blob/main/docs/onboarding.md")

    static func open(_ url: URL) {
        NotificationCenter.default.post(name: .webLinkTapped, object: url)
    }

    private static func publicURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid public documentation URL")
        }
        return url
    }
}
