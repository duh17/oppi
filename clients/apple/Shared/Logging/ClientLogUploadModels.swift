import Foundation

enum AppleClientKind: String, Codable, Sendable {
    case ios
    case mac
}

enum ClientLogUploadLevel: String, Codable, Sendable {
    case debug
    case info
    case warn
    case error
}

struct ClientLogUploadEntry: Codable, Sendable, Equatable {
    let ts: Int64
    let seq: Int
    let level: ClientLogUploadLevel
    let category: String
    let message: String
    let metadata: [String: String]?
    let sessionId: String?
    let workspaceId: String?
}

struct ClientLogUploadRequest: Codable, Sendable, Equatable {
    let generatedAt: Int64
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
    let clientKind: AppleClientKind
    let appInstanceId: String
    let bootId: String
    let droppedCount: Int?
    let entries: [ClientLogUploadEntry]
}

struct ClientLogUploadMetadata: Sendable, Equatable {
    let appVersion: String
    let buildNumber: String
    let osVersion: String
    let deviceModel: String
}

protocol ClientLogUploading: Sendable {
    func uploadClientLogs(request: ClientLogUploadRequest) async throws
}

enum ClientLogRedactor {
    static let redacted = "[REDACTED]"
    private static let truncated = "[TRUNCATED]"

    private static let valuePatterns: [(pattern: String, replacement: String, caseInsensitive: Bool)] = [
        (#"Bearer\s+[A-Za-z0-9\-._~+/]+=*"#, "Bearer [REDACTED]", true),
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]", false),
        (#"\bsk_(?:live|test|proj)-[A-Za-z0-9]{8,}\b"#, redacted, false),
        (#"\bgh[opusr]_[A-Za-z0-9]{20,}\b"#, redacted, false),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#, redacted, false),
        (#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, redacted, false),
        (#"\bAKIA[0-9A-Z]{16}\b"#, redacted, false),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9._-]{8,}\.[A-Za-z0-9._-]{8,}\b"#, redacted, false),
        (#"([?&](?:token|api[_-]?key|access[_-]?token|auth)=)[^&\s]+"#, "$1[REDACTED]", true),
    ]

    private static let sensitiveNormalizedKeyTerms = [
        "authorization",
        "cookie",
        "secret",
        "password",
        "passwd",
        "apikey",
        "accesskey",
        "privatekey",
        "refreshtoken",
        "clientsecret",
        "accesstoken",
        "authtoken",
    ]

    static func redactedText(_ value: String, maxLength: Int = 2_048) -> String {
        var output = value
        for item in valuePatterns {
            var options: String.CompareOptions = [.regularExpression]
            if item.caseInsensitive {
                options.insert(.caseInsensitive)
            }
            output = output.replacingOccurrences(
                of: item.pattern,
                with: item.replacement,
                options: options
            )
        }

        guard output.count > maxLength else { return output }
        let truncatedCount = output.count - maxLength
        return "\(String(output.prefix(maxLength)))…\(truncated)(\(truncatedCount) chars)"
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let boundaryPattern = #"(?:^|[_-])(authorization|auth|cookie|token|secret|password|passwd|api[_-]?key|access[_-]?key|private[_-]?key|refresh[_-]?token|client[_-]?secret)(?:$|[_-])"#
        if key.range(of: boundaryPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }

        let normalized = key
            .replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: "", options: .regularExpression)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized == "auth" || normalized == "token" {
            return true
        }
        if normalized.hasSuffix("token") && normalized != "tokens" {
            return true
        }

        return sensitiveNormalizedKeyTerms.contains { normalized.contains($0) }
    }

    static func redactedMetadata(
        _ metadata: [String: String],
        maxFields: Int = 24,
        keyMaxLength: Int = 96,
        valueMaxLength: Int = 512
    ) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(min(metadata.count, maxFields))

        for (key, value) in metadata {
            if out.count >= maxFields { break }
            let cleanKey = redactedText(
                key.trimmingCharacters(in: .whitespacesAndNewlines),
                maxLength: keyMaxLength
            )
            guard !cleanKey.isEmpty else { continue }
            out[cleanKey] = isSensitiveKey(key) || isSensitiveKey(cleanKey)
                ? redacted
                : redactedText(value, maxLength: valueMaxLength)
        }

        return out
    }
}
