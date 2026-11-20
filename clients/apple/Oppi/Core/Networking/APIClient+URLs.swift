import Foundation

// MARK: - URLs

extension APIClient {
    func encodeQueryPath(_ path: String) throws -> String {
        try percentEncodeQueryComponent(path)
    }

    private func percentEncodeQueryComponent(_ component: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw APIError.server(status: 400, message: "Invalid query value")
        }
        return encoded
    }

    func makePercentEncodedQuery(_ queryItems: [URLQueryItem]) throws -> String? {
        guard !queryItems.isEmpty else { return nil }

        let parts = try queryItems.map { item in
            let name = try percentEncodeQueryComponent(item.name)
            guard let value = item.value else { return name }
            return "\(name)=\(try percentEncodeQueryComponent(value))"
        }
        return parts.joined(separator: "&")
    }

    func percentEncodePathSegment(_ segment: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%+?#&")
        guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw APIError.server(status: 400, message: "Invalid file path")
        }
        return encoded
    }

    func workspaceWorktreeQueryItems(_ worktreeId: String?) -> [URLQueryItem] {
        let trimmed = worktreeId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return [] }
        return [URLQueryItem(name: "worktreeId", value: trimmed)]
    }

    func makeURL(
        pathSegments: [String],
        appendedPath: String? = nil,
        queryItems: [URLQueryItem] = [],
        trailingSlash: Bool = false
    ) throws -> URL {
        let encodedSegments = try pathSegments.map(percentEncodePathSegment)
        let normalizedAppendedPath = appendedPath?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let appendedSegments = try normalizedAppendedPath.isEmpty
            ? []
            : normalizedAppendedPath.split(separator: "/", omittingEmptySubsequences: true).map {
                try percentEncodePathSegment(String($0))
            }
        let combined = encodedSegments + appendedSegments
        var percentEncodedPath = "/\(combined.joined(separator: "/"))"
        if trailingSlash {
            percentEncodedPath += "/"
        }
        return try makeURL(percentEncodedPath: percentEncodedPath, queryItems: queryItems)
    }

    private func makeURL(percentEncodedPath: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }

        let normalizedBasePath: String = {
            if components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" { return "" }
            if components.percentEncodedPath.hasSuffix("/") { return String(components.percentEncodedPath.dropLast()) }
            return components.percentEncodedPath
        }()

        let normalizedRequestPath = percentEncodedPath.hasPrefix("/") ? percentEncodedPath : "/\(percentEncodedPath)"
        components.percentEncodedPath = normalizedBasePath + normalizedRequestPath
        components.percentEncodedQuery = try makePercentEncodedQuery(queryItems)

        guard let url = components.url else {
            throw APIError.invalidResponse
        }

        return url
    }

    /// Build a request URL from an API path that may include a query string.
    ///
    /// `URL.appendingPathComponent` encodes `?` as a literal path character,
    /// which breaks routes with query strings and yields 404.
    func makeURL(path: String) throws -> URL {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? ""
        let rawQuery = parts.count > 1 ? String(parts[1]) : nil

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }

        let normalizedBasePath: String = {
            if components.path.isEmpty || components.path == "/" { return "" }
            if components.path.hasSuffix("/") { return String(components.path.dropLast()) }
            return components.path
        }()

        let normalizedRequestPath = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        components.path = normalizedBasePath + normalizedRequestPath
        components.percentEncodedQuery = rawQuery

        guard let url = components.url else {
            throw APIError.invalidResponse
        }

        return url
    }
}
