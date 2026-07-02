import Foundation
import OSLog

private let remoteServerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OppiMac",
    category: "MacRemoteServerStore"
)

struct MacRemoteServer: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var nickname: String
    var url: URL
    var createdAt: Date

    var displayName: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.host() ?? url.absoluteString : trimmed
    }
}

enum MacRemoteServerStoreError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedScheme
    case duplicateURL

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid remote server URL."
        case .unsupportedScheme:
            "Remote servers must use http or https."
        case .duplicateURL:
            "That remote server is already saved."
        }
    }
}

@MainActor @Observable
final class MacRemoteServerStore {
    private static let storageKey = "OppiMac.remoteServers.v1"

    private let defaults: UserDefaults
    private(set) var servers: [MacRemoteServer] = []
    private(set) var lastError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(nickname: String, urlText: String) {
        do {
            let normalizedURL = try Self.normalizedURL(from: urlText)
            guard !servers.contains(where: { $0.url.absoluteString == normalizedURL.absoluteString }) else {
                throw MacRemoteServerStoreError.duplicateURL
            }
            servers.append(MacRemoteServer(
                id: UUID(),
                nickname: nickname.trimmingCharacters(in: .whitespacesAndNewlines),
                url: normalizedURL,
                createdAt: Date()
            ))
            servers.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            lastError = nil
            save()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func remove(_ server: MacRemoteServer) {
        servers.removeAll { $0.id == server.id }
        save()
    }

    static func normalizedURL(from text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MacRemoteServerStoreError.invalidURL }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw MacRemoteServerStoreError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw MacRemoteServerStoreError.unsupportedScheme
        }

        components.scheme = scheme
        components.host = host
        if components.path.isEmpty {
            components.path = ""
        }
        components.queryItems = nil
        components.fragment = nil

        guard let url = components.url else { throw MacRemoteServerStoreError.invalidURL }
        return url
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else { return }
        do {
            servers = try JSONDecoder().decode([MacRemoteServer].self, from: data)
        } catch {
            remoteServerLogger.warning("Remote server store decode failed: \(error.localizedDescription, privacy: .public)")
            servers = []
            lastError = "Could not read saved remote servers."
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(servers)
            defaults.set(data, forKey: Self.storageKey)
        } catch {
            remoteServerLogger.warning("Remote server store save failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Could not save remote servers."
        }
    }
}
