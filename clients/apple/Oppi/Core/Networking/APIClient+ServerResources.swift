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

    /// Lists server-global Pi extensions and their contributed tools.
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

    func getPiSystemPrompt() async throws -> PiSystemPromptSnapshot {
        let data = try await get(url: serverResourceURL(pathSegments: ["pi", "system-prompt"]))
        return try JSONDecoder().decode(PiSystemPromptSnapshot.self, from: data)
    }

    func getPiDefaultTools() async throws -> PiDefaultToolsSnapshot {
        let data = try await get(url: serverResourceURL(pathSegments: ["pi", "default-tools"]))
        return try JSONDecoder().decode(PiDefaultToolsSnapshot.self, from: data)
    }

    func setPiDefaultTools(_ defaultTools: [String]?) async throws -> PiDefaultToolsSnapshot {
        let data = try await put(
            url: serverResourceURL(pathSegments: ["pi", "default-tools"]),
            body: PiDefaultToolsRequest(defaultTools: defaultTools)
        )
        return try JSONDecoder().decode(PiDefaultToolsSnapshot.self, from: data)
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

    func getMobileOutputGuideConfiguration() async throws -> MobileOutputGuideConfiguration {
        let data = try await get(url: mobileOutputGuideURL())
        return try JSONDecoder().decode(MobileOutputGuideConfiguration.self, from: data)
    }

    func setMobileOutputGuideConfiguration(
        enabled: Bool,
        baseRevision: Int
    ) async throws -> MobileOutputGuideConfiguration {
        let data = try await put(
            url: mobileOutputGuideURL(),
            body: MobileOutputGuideRequest(enabled: enabled, baseRevision: baseRevision)
        )
        return try JSONDecoder().decode(MobileOutputGuideConfiguration.self, from: data)
    }

    private func mobileOutputGuideURL() throws -> URL {
        try makeURL(pathSegments: ["server", "mobile-output-guide"])
    }

    private struct ResourceEnabledRequest: Encodable {
        let enabled: Bool
    }

    private struct MobileOutputGuideRequest: Encodable {
        let enabled: Bool
        let baseRevision: Int
    }

    private struct PiDefaultToolsRequest: Encodable {
        let defaultTools: [String]?

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(defaultTools, forKey: .defaultTools)
        }

        private enum CodingKeys: String, CodingKey {
            case defaultTools
        }
    }

}
