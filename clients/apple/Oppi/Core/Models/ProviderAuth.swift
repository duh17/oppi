import Foundation

/// OAuth/device-code flow behavior exposed by `/provider-auth/providers`.
struct ProviderAuthOAuthCapabilities: Codable, Sendable, Equatable {
    enum FlowType: String, Codable, Sendable {
        case oauthCallback = "oauth_callback"
        case deviceCode = "device_code"
        case oauth
    }

    let flowType: FlowType
    let supportsServerBrowserLaunch: Bool
    let supportsPhoneBrowserLaunch: Bool
    let supportsManualCodeInput: Bool
    let mayPromptForInput: Bool
}

/// Provider-level auth status exposed by `/provider-auth/status`.
struct ProviderAuthProviderStatus: Codable, Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let supportsApiKey: Bool
    let oauth: ProviderAuthOAuthCapabilities?
    let authenticated: Bool
    let credentialType: CredentialType?
    let expiresAt: Double?
    let maskedKey: String?

    enum CredentialType: String, Codable, Sendable {
        case oauth
        case apiKey = "api_key"
    }

    var expiresAtDate: Date? {
        guard let expiresAt else { return nil }
        return Date(timeIntervalSince1970: expiresAt / 1000)
    }
}

/// Snapshot of an in-flight provider auth flow.
struct ProviderAuthFlowSnapshot: Codable, Sendable, Identifiable, Equatable {
    let flowId: String
    let providerId: String
    let flowType: ProviderAuthOAuthCapabilities.FlowType
    let launchMode: LaunchMode
    let status: Status
    let auth: AuthInfo?
    let prompt: Prompt?
    let lastProgress: String?
    let error: String?
    let createdAt: Double
    let updatedAt: Double
    let expiresAt: Double

    var id: String { flowId }

    enum LaunchMode: String, Codable, Sendable {
        case serverBrowser = "server_browser"
        case phoneBrowser = "phone_browser"
        case none
    }

    enum Status: String, Codable, Sendable {
        case pending
        case awaitingExternal = "awaiting_external"
        case awaitingPrompt = "awaiting_prompt"
        case awaitingManualCode = "awaiting_manual_code"
        case completed
        case failed
        case cancelled
        case expired

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled, .expired:
                return true
            case .pending, .awaitingExternal, .awaitingPrompt, .awaitingManualCode:
                return false
            }
        }
    }

    struct AuthInfo: Codable, Sendable, Equatable {
        let url: String
        let instructions: String?
    }

    struct Prompt: Codable, Sendable, Equatable {
        let message: String
        let placeholder: String?
        let allowEmpty: Bool?
    }
}
