import Foundation

extension APIClient {
    /// Lists the Pi skills configured at server scope. This route never carries a workspace cwd.
    func listServerSkills() async throws -> [ServerSkillSummary] {
        try await get(url: serverResourceURL(pathSegments: ["skills"]), as: ServerSkillsCatalog.self).skills
    }

    func getServerSkill(id: String) async throws -> ServerSkillDetail {
        try await get(url: serverResourceURL(pathSegments: ["skills", id]), as: ServerSkillDetail.self)
    }

    func setServerSkillEnabled(id: String, enabled: Bool) async throws -> ServerSkillSummary {
        try await put(
            url: serverResourceURL(pathSegments: ["skills", id, "enabled"]),
            body: ResourceEnabledRequest(enabled: enabled),
            as: ServerSkillSummary.self
        )
    }

    /// Lists server-global Pi extensions and their contributed tools. `plugins` adds the rows
    /// that are only a plugin (`plugins=true`); a caller that reads only the tool catalogs
    /// leaves it off. An Agent's selection offers only
    /// the Pi extensions (`ServerExtensionSummary.isPiExtension`).
    func listServerExtensions(plugins: Bool) async throws -> ServerExtensionCatalog {
        try await get(
            url: serverResourceURL(
                pathSegments: ["extensions"],
                queryItems: plugins ? [URLQueryItem(name: "plugins", value: "true")] : []
            ),
            as: ServerExtensionCatalog.self
        )
    }

    func getServerExtension(id: String) async throws -> ServerExtensionDetail {
        try await get(url: serverResourceURL(pathSegments: ["extensions", id]), as: ServerExtensionDetail.self)
    }

    /// Executes one explicitly selected user Extension only to inspect its Agent tools.
    func inspectAgentExtensionTools(id: String) async throws -> ServerExtensionDetail {
        try await get(
            url: serverResourceURL(
                pathSegments: ["extensions", id],
                queryItems: [URLQueryItem(name: "agentTools", value: "true")]
            ),
            as: ServerExtensionDetail.self
        )
    }

    func setServerExtensionEnabled(id: String, enabled: Bool) async throws -> ServerExtensionSummary {
        try await put(
            url: serverResourceURL(pathSegments: ["extensions", id, "enabled"]),
            body: ResourceEnabledRequest(enabled: enabled),
            as: ServerExtensionSummary.self
        )
    }

    /// Discovers and loads every plugin again in the running server, without a restart.
    func reloadServerExtensions() async throws -> ServerPluginReloadReport {
        try await post("/server/resources/extensions/reload", body: EmptyBody(), as: ServerPluginReloadReport.self)
    }

    func getPiSystemPrompt() async throws -> PiSystemPromptSnapshot {
        try await get(url: serverResourceURL(pathSegments: ["pi", "system-prompt"]), as: PiSystemPromptSnapshot.self)
    }

    func getPiDefaultTools() async throws -> PiDefaultToolsSnapshot {
        try await get(url: serverResourceURL(pathSegments: ["pi", "default-tools"]), as: PiDefaultToolsSnapshot.self)
    }

    func setPiDefaultTools(_ defaultTools: [String]?) async throws -> PiDefaultToolsSnapshot {
        try await put(
            url: serverResourceURL(pathSegments: ["pi", "default-tools"]),
            body: PiDefaultToolsRequest(defaultTools: defaultTools),
            as: PiDefaultToolsSnapshot.self
        )
    }

    func setPiDefaultModel(_ model: String) async throws {
        struct Request: Encodable { let model: String }
        _ = try await put(
            url: serverResourceURL(pathSegments: ["pi", "default-model"]),
            body: Request(model: model)
        )
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
        try await get(url: mobileOutputGuideURL(), as: MobileOutputGuideConfiguration.self)
    }

    func setMobileOutputGuideConfiguration(
        enabled: Bool,
        baseRevision: Int
    ) async throws -> MobileOutputGuideConfiguration {
        try await put(
            url: mobileOutputGuideURL(),
            body: MobileOutputGuideRequest(enabled: enabled, baseRevision: baseRevision),
            as: MobileOutputGuideConfiguration.self
        )
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
