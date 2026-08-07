@testable import Oppi
import Testing

@Suite("Provider setup prompt policy")
struct ProviderSetupPromptPolicyTests {
    @Test func unknownStatusShowsLoadingWithoutProviderSections() {
        let presentation = ProviderConfigurationPresentation(state: .unknown)

        #expect(!ProviderSetupPromptPolicy.shouldShow(for: .unknown))
        #expect(presentation.showsLoading)
        #expect(!presentation.showsProviderSections)
        #expect(presentation.summary(connectedCount: 0) == "Loading…")
    }

    @Test func failedStatusShowsUnavailableWithoutProviderSectionsOrPrompt() {
        let presentation = ProviderConfigurationPresentation(state: .unavailable)

        #expect(!ProviderSetupPromptPolicy.shouldShow(for: .unavailable))
        #expect(!presentation.showsLoading)
        #expect(!presentation.showsProviderSections)
        #expect(presentation.summary(connectedCount: 0) == "Unavailable")
    }

    @Test func confirmedMissingConfigurationPrompts() {
        #expect(ProviderSetupPromptPolicy.shouldShow(for: .needsConfiguration))
    }

    @Test func successfulEmptyOrUnauthenticatedStatusNeedsConfiguration() {
        #expect(ProviderSetupState(providerStatuses: []) == .needsConfiguration)
        #expect(ProviderSetupState(providerStatuses: [provider(authenticated: false)]) == .needsConfiguration)
    }

    @Test func authenticatedProviderMarksServerConfigured() {
        let state = ProviderSetupState(providerStatuses: [provider(authenticated: true)])

        #expect(state == .configured)
        #expect(!ProviderSetupPromptPolicy.shouldShow(for: state))
    }

    private func provider(authenticated: Bool) -> ProviderAuthProviderStatus {
        ProviderAuthProviderStatus(
            id: "provider",
            name: "Provider",
            supportsApiKey: true,
            oauth: nil,
            authenticated: authenticated,
            credentialType: authenticated ? .apiKey : nil,
            expiresAt: nil,
            maskedKey: nil
        )
    }
}
