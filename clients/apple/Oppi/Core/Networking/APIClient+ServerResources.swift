import Foundation

extension APIClient {
    /// Lists the Pi skills configured at server scope. This route never carries a workspace cwd.
    func listServerSkills() async throws -> [ServerSkillSummary] {
        let data = try await get(url: serverResourceURL(pathSegments: ["skills"]))
        return try JSONDecoder().decode(ServerSkillsCatalog.self, from: data).skills
    }

    func getServerSkill(id: String) async throws -> ServerSkillDetail {
        let data = try await get(url: serverResourceURL(pathSegments: ["skills", id]))
        return try JSONDecoder().decode(ServerSkillDetail.self, from: data)
    }

    func getServerSkillFile(id: String, path: String) async throws -> String {
        struct Response: Decodable {
            let content: String
        }

        let data = try await get(url: serverResourceURL(
            pathSegments: ["skills", id, "file"],
            queryItems: [URLQueryItem(name: "path", value: path)]
        ))
        return try JSONDecoder().decode(Response.self, from: data).content
    }

    func setServerSkillEnabled(id: String, enabled: Bool) async throws -> ServerSkillSummary {
        let data = try await put(
            url: serverResourceURL(pathSegments: ["skills", id, "enabled"]),
            body: ResourceEnabledRequest(enabled: enabled)
        )
        return try JSONDecoder().decode(ServerSkillSummary.self, from: data)
    }

    /// Lists server-global extensions and the atomic built-in Oppi configuration snapshot.
    func listServerExtensions() async throws -> ServerExtensionCatalog {
        let data = try await get(url: serverResourceURL(pathSegments: ["extensions"]))
        return try JSONDecoder().decode(ServerExtensionCatalog.self, from: data)
    }

    func getServerExtension(id: String) async throws -> ServerExtensionDetail {
        let data = try await get(url: serverResourceURL(pathSegments: ["extensions", id]))
        return try JSONDecoder().decode(ServerExtensionDetail.self, from: data)
    }

    /// Executes one explicitly selected user Extension only to inspect its Agent tools.
    func inspectAgentExtensionTools(id: String) async throws -> ServerExtensionDetail {
        let data = try await get(url: serverResourceURL(
            pathSegments: ["extensions", id],
            queryItems: [URLQueryItem(name: "agentTools", value: "true")]
        ))
        return try JSONDecoder().decode(ServerExtensionDetail.self, from: data)
    }

    func setServerExtensionEnabled(id: String, enabled: Bool) async throws -> ServerExtensionSummary {
        let data = try await put(
            url: serverResourceURL(pathSegments: ["extensions", id, "enabled"]),
            body: ResourceEnabledRequest(enabled: enabled)
        )
        return try JSONDecoder().decode(ServerExtensionSummary.self, from: data)
    }

    func getOppiExtensionConfiguration() async throws -> OppiExtensionConfiguration {
        let data = try await get(url: oppiConfigurationURL())
        return try JSONDecoder().decode(OppiExtensionConfiguration.self, from: data)
    }

    /// Replaces the complete revisioned Oppi configuration in one compare-and-swap request.
    func setOppiExtensionConfiguration(
        enabled: Bool,
        approvalPolicy: OppiApprovalPolicy,
        baseRevision: Int
    ) async throws -> OppiExtensionConfiguration {
        let data = try await put(
            url: oppiConfigurationURL(),
            body: OppiConfigurationRequest(
                enabled: enabled,
                approvalPolicy: approvalPolicy,
                baseRevision: baseRevision
            )
        )
        return try JSONDecoder().decode(OppiExtensionConfiguration.self, from: data)
    }

    private func serverResourceURL(
        pathSegments: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        try makeURL(
            pathSegments: ["server", "resources"] + pathSegments,
            queryItems: queryItems
        )
    }

    private func oppiConfigurationURL() throws -> URL {
        try makeURL(pathSegments: ["server", "extensions", "oppi", "config"])
    }

    private struct ResourceEnabledRequest: Encodable {
        let enabled: Bool
    }

    private struct OppiConfigurationRequest: Encodable {
        let enabled: Bool
        let approvalPolicy: OppiApprovalPolicy
        let baseRevision: Int
    }
}
