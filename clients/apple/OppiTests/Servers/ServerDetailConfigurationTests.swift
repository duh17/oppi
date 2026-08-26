import Testing
@testable import Oppi

@Suite("Server detail configuration")
struct ServerDetailConfigurationTests {
    @Test func mobileOutputGuideStateDistinguishesLoadingAvailableAndFailure() {
        #expect(ServerDetailMobileOutputGuideState.resolve(configuration: nil, isLoading: true, error: nil) == .loading)
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: MobileOutputGuideConfiguration(enabled: true, revision: 4),
            isLoading: false,
            error: nil
        ) == .available(enabled: true, revision: 4, error: nil))
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: nil,
            isLoading: false,
            error: "Offline"
        ) == .failed("Offline"))
    }

    @Test func mobileOutputGuideFailureKeepsLastTrustworthyValueAndSurfacesTheError() {
        let current = MobileOutputGuideConfiguration(enabled: false, revision: 7)

        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: current,
            isLoading: false,
            error: "Save failed"
        ) == .available(enabled: false, revision: 7, error: "Save failed"))
        #expect(ServerDetailMobileOutputGuideState.resolve(
            configuration: current,
            isLoading: true,
            error: "Refresh failed"
        ) == .available(enabled: false, revision: 7, error: "Refresh failed"))
    }
}
