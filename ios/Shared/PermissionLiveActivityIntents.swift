import AppIntents
import Foundation
import Security

enum LiveActivityPermissionAction: String {
    case allow
    case deny
}

struct ApprovePermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Permission ID")
    var permissionId: String

    init() {}

    init(permissionId: String) {
        self.permissionId = permissionId
    }

    func perform() async throws -> some IntentResult {
        try await LiveActivityPermissionResponder.respond(
            permissionId: permissionId,
            action: .allow
        )
        return .result()
    }
}

struct DenyPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Permission ID")
    var permissionId: String

    init() {}

    init(permissionId: String) {
        self.permissionId = permissionId
    }

    func perform() async throws -> some IntentResult {
        try await LiveActivityPermissionResponder.respond(
            permissionId: permissionId,
            action: .deny
        )
        return .result()
    }
}

private enum LiveActivityPermissionResponder {
    private struct StoredServerCredential: Decodable {
        let id: String
        let host: String
        let port: Int
        let token: String
        let sortOrder: Int?
    }

    private struct RespondBody: Encodable {
        let action: String
        let scope: String
    }

    private struct ServerErrorBody: Decodable {
        let error: String
    }

    private enum ResponderError: LocalizedError {
        case noPairedServers
        case invalidServerAddress
        case permissionNotFound
        case serverError(status: Int, message: String?)

        var errorDescription: String? {
            switch self {
            case .noPairedServers:
                return "No paired servers available"
            case .invalidServerAddress:
                return "Invalid server address"
            case .permissionNotFound:
                return "Permission request not found"
            case .serverError(let status, let message):
                if let message, !message.isEmpty {
                    return "Server error (\(status)): \(message)"
                }
                return "Server error (\(status))"
            }
        }
    }

    private static let accountPrefix = SharedConstants.serverAccountPrefix
    private static let keychainService = SharedConstants.keychainService
    private static let keychainAccessGroup = SharedConstants.keychainAccessGroup

    static func respond(permissionId: String, action: LiveActivityPermissionAction) async throws {
        let servers = loadServers()
        guard !servers.isEmpty else {
            throw ResponderError.noPairedServers
        }

        var sawNotFound = false
        var lastError: Error?

        for server in servers {
            do {
                try await respond(to: server, permissionId: permissionId, action: action)
                return
            } catch let error as ResponderError {
                switch error {
                case .permissionNotFound:
                    sawNotFound = true
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        if sawNotFound {
            throw ResponderError.permissionNotFound
        }

        throw ResponderError.noPairedServers
    }

    private static func respond(
        to server: StoredServerCredential,
        permissionId: String,
        action: LiveActivityPermissionAction
    ) async throws {
        guard let url = permissionResponseURL(for: server, permissionId: permissionId) else {
            throw ResponderError.invalidServerAddress
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RespondBody(action: action.rawValue, scope: "once")
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ResponderError.serverError(status: 0, message: "Invalid response")
        }

        guard (200...299).contains(http.statusCode) else {
            let message = parseErrorMessage(from: data)
            if http.statusCode == 404 {
                throw ResponderError.permissionNotFound
            }
            throw ResponderError.serverError(status: http.statusCode, message: message)
        }
    }

    private static func permissionResponseURL(
        for server: StoredServerCredential,
        permissionId: String
    ) -> URL? {
        guard let baseURL = URL(string: "http://\(server.host):\(server.port)") else {
            return nil
        }

        let encodedPermissionId = encodePathSegment(permissionId)
        return URL(
            string: "/permissions/\(encodedPermissionId)/respond",
            relativeTo: baseURL
        )
    }

    private static func encodePathSegment(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func parseErrorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(ServerErrorBody.self, from: data), !decoded.error.isEmpty {
            return decoded.error
        }

        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func loadServers() -> [StoredServerCredential] {
        let ids = SharedConstants.sharedDefaults.stringArray(forKey: SharedConstants.pairedServerIdsKey) ?? []
        if !ids.isEmpty {
            let ordered = ids.compactMap { loadServer(id: $0) }
            if !ordered.isEmpty {
                return ordered
            }
        }

        return discoverAllServers()
    }

    private static func loadServer(id: String) -> StoredServerCredential? {
        let account = "\(accountPrefix)\(id)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(StoredServerCredential.self, from: data)
    }

    private static func discoverAllServers() -> [StoredServerCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccessGroup as String: keychainAccessGroup,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }

        var discoveredById: [String: StoredServerCredential] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix(accountPrefix),
                  let data = item[kSecValueData as String] as? Data,
                  let decoded = try? JSONDecoder().decode(StoredServerCredential.self, from: data)
            else {
                continue
            }

            if discoveredById[decoded.id] == nil {
                discoveredById[decoded.id] = decoded
            }
        }

        return discoveredById.values.sorted { lhs, rhs in
            let lhsOrder = lhs.sortOrder ?? Int.max
            let rhsOrder = rhs.sortOrder ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.id < rhs.id
        }
    }
}
