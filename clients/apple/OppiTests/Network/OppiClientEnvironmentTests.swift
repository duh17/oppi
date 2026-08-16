import Foundation
import Testing
@testable import Oppi

@Suite("Oppi client environment")
struct OppiClientEnvironmentTests {
    @Test func clientOnlyEnvironmentDoesNotRequireLocalProcessAdapter() throws {
        let baseURL = try #require(URL(string: "https://server.example.test"))
        let environment = OppiClientEnvironment(
            baseURL: baseURL,
            bearerToken: "device-token"
        )

        #expect(environment.baseURL == baseURL)
        #expect(environment.bearerToken == "device-token")
        #expect(environment.processOwnership == .clientOnly)
        #expect(environment.requiresLocalProcessAdapter == false)
        #expect(environment.usesPinnedCertificate == false)
    }

    @Test func localProcessEnvironmentKeepsTrustAndOwnershipExplicit() throws {
        let baseURL = try #require(URL(string: "https://localhost:7749"))
        let environment = OppiClientEnvironment(
            baseURL: baseURL,
            bearerToken: "owner-token",
            pinnedCertificateFingerprint: "sha256/example",
            processOwnership: .ownedLocalProcess
        )

        #expect(environment.baseURL == baseURL)
        #expect(environment.processOwnership == .ownedLocalProcess)
        #expect(environment.requiresLocalProcessAdapter == true)
        #expect(environment.usesPinnedCertificate == true)
    }

    @Test func apiClientInitializesFromSharedEnvironment() async throws {
        let baseURL = try #require(URL(string: "https://localhost:7749"))
        let environment = OppiClientEnvironment(
            baseURL: baseURL,
            bearerToken: "owner-token",
            pinnedCertificateFingerprint: "sha256/example",
            processOwnership: .ownedLocalProcess
        )

        let client = APIClient(environment: environment)
        let source = try await client.makeWorkspaceMediaSource(
            workspaceId: "w1",
            path: "image.png"
        )

        #expect(await client.environment == environment)
        #expect(await client.baseURL == baseURL)
        #expect(await client.token == "owner-token")
        #expect(try await source.authorizationProvider() == "Bearer owner-token")
        #expect(source.tlsCertFingerprint == "sha256/example")
    }
}
