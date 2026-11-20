import Foundation

// MARK: - Models and provider auth

extension APIClient {
    /// Fetch available models from the server.
    func listModels() async throws -> [ModelInfo] {
        struct Response: Decodable { let models: [ModelInfo] }
        return try await get("/models", as: Response.self).models
    }

    /// List provider auth status (OAuth/API key) from the server.
    func listProviderAuthStatus() async throws -> [ProviderAuthProviderStatus] {
        struct Response: Decodable { let providers: [ProviderAuthProviderStatus] }
        return try await get("/provider-auth/status", as: Response.self).providers
    }

    /// The response of every provider-flow route.
    private struct FlowResponse: Decodable { let flow: ProviderAuthFlowSnapshot }

    /// Start an OAuth/device-code flow for a provider.
    func startProviderAuthFlow(
        providerId: String,
        launchMode: ProviderAuthFlowSnapshot.LaunchMode = .serverBrowser
    ) async throws -> ProviderAuthFlowSnapshot {
        struct Body: Encodable {
            let providerId: String
            let launchMode: ProviderAuthFlowSnapshot.LaunchMode
        }
        return try await post(
            "/provider-auth/flows",
            body: Body(providerId: providerId, launchMode: launchMode),
            as: FlowResponse.self
        ).flow
    }

    /// Fetch latest state for an in-flight provider auth flow.
    func getProviderAuthFlow(flowId: String) async throws -> ProviderAuthFlowSnapshot {
        try await get("/provider-auth/flows/\(flowId)", as: FlowResponse.self).flow
    }

    /// Submit response for a provider flow prompt.
    func submitProviderAuthPromptResponse(flowId: String, value: String) async throws -> ProviderAuthFlowSnapshot {
        struct Body: Encodable { let value: String }
        return try await post(
            "/provider-auth/flows/\(flowId)/prompt-response",
            body: Body(value: value),
            as: FlowResponse.self
        ).flow
    }

    /// Submit manually pasted callback URL/code for a provider flow.
    func submitProviderAuthManualCode(flowId: String, input: String) async throws -> ProviderAuthFlowSnapshot {
        struct Body: Encodable { let input: String }
        return try await post(
            "/provider-auth/flows/\(flowId)/manual-code",
            body: Body(input: input),
            as: FlowResponse.self
        ).flow
    }

    /// Cancel an in-flight provider auth flow.
    func cancelProviderAuthFlow(flowId: String, reason: String? = nil) async throws -> ProviderAuthFlowSnapshot {
        struct Body: Encodable { let reason: String? }
        return try await post(
            "/provider-auth/flows/\(flowId)/cancel",
            body: Body(reason: reason),
            as: FlowResponse.self
        ).flow
    }

    /// Save an API key credential for a provider.
    func setProviderAPIKey(providerId: String, key: String) async throws {
        struct Body: Encodable {
            let providerId: String
            let key: String
        }
        _ = try await put(
            "/provider-auth/api-key",
            body: Body(providerId: providerId, key: key)
        )
    }

    /// Remove saved credential for a provider.
    func removeProviderCredential(providerId: String) async throws {
        _ = try await delete("/provider-auth/\(providerId)")
    }
}
