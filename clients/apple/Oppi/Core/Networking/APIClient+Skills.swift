import Foundation

// MARK: - Skills and extensions for a workspace context

extension APIClient {
    /// List available skills from Pi resource discovery.
    func listSkills(cwd: String? = nil, workspaceId: String? = nil) async throws -> [SkillInfo] {
        var queryItems: [URLQueryItem] = []
        if let workspaceId, !workspaceId.isEmpty {
            queryItems.append(URLQueryItem(name: "workspaceId", value: workspaceId))
        } else if let cwd, !cwd.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd", value: cwd))
        }
        struct Response: Decodable { let skills: [SkillInfo] }
        return try await get(url: makeURL(pathSegments: ["skills"], queryItems: queryItems), as: Response.self).skills
    }

    /// Enable or disable a Pi resource by writing Pi user/project settings for the cwd.
    func setPiResourceEnabled(
        type: String,
        path: String,
        cwd: String? = nil,
        workspaceId: String? = nil,
        enabled: Bool
    ) async throws {
        struct Body: Encodable {
            let type: String
            let path: String
            let cwd: String?
            let workspaceId: String?
            let enabled: Bool
        }

        _ = try await post(
            "/pi/resources/enabled",
            body: Body(
                type: type,
                path: path,
                cwd: workspaceId == nil ? cwd : nil,
                workspaceId: workspaceId,
                enabled: enabled
            )
        )
    }

    /// List available host extensions for the current workspace context.
    ///
    /// The server resolves extensions using pi's resource resolver, including
    /// auto-discovered dirs, settings paths, and installed package extensions.
    func listExtensions(cwd: String? = nil, workspaceId: String? = nil) async throws -> WorkspaceExtensionList {
        var path = "/extensions"
        var queryItems: [URLQueryItem] = []
        if let workspaceId, !workspaceId.isEmpty {
            queryItems.append(URLQueryItem(name: "workspaceId", value: workspaceId))
        } else if let cwd, !cwd.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd", value: cwd))
        }
        if !queryItems.isEmpty {
            var components = URLComponents()
            components.queryItems = queryItems
            if let query = components.percentEncodedQuery {
                path += "?\(query)"
            }
        }

        return try await get(path, as: WorkspaceExtensionList.self)
    }

    /// Get full skill detail: metadata, SKILL.md content, and file tree.
    func getSkillDetail(name: String, cwd: String? = nil) async throws -> SkillDetail {
        var queryItems: [URLQueryItem] = []
        if let cwd, !cwd.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd", value: cwd))
        }
        return try await get(url: makeURL(pathSegments: ["skills", name], queryItems: queryItems), as: SkillDetail.self)
    }

    /// Get a single file's content from a skill directory.
    func getSkillFile(name: String, path: String, cwd: String? = nil) async throws -> String {
        var queryItems = [URLQueryItem(name: "path", value: path)]
        if let cwd, !cwd.isEmpty {
            queryItems.append(URLQueryItem(name: "cwd", value: cwd))
        }
        struct Response: Decodable { let content: String }
        return try await get(
            url: makeURL(pathSegments: ["skills", name, "file"], queryItems: queryItems),
            as: Response.self
        ).content
    }
}
