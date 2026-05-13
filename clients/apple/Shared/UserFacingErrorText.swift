import Foundation

enum UserFacingErrorText {
    private struct Details {
        var message: String? = nil
        var code: String? = nil
        var type: String? = nil
    }

    static func normalize(_ error: String, fallback: String = "Something went wrong. Please try again.") -> String {
        let trimmed = clean(error)
        guard !trimmed.isEmpty else { return fallback }

        let details = extractDetails(from: trimmed)
        if let message = details.message, !looksStructured(message) {
            return normalizedKnownPlainMessage(message) ?? message
        }
        if let known = knownCodeOnlyMessage(for: details) {
            return known
        }
        if looksStructured(trimmed) {
            return fallback
        }
        return trimmed
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseJSON(_ input: String) -> Any? {
        guard let data = input.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func parseStructuredCandidate(from input: String) -> Any? {
        if let parsed = parseJSON(input) {
            return parsed
        }
        guard let start = input.firstIndex(of: "{"),
              let end = input.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return parseJSON(String(input[start ... end]))
    }

    private static func extractDetails(from value: Any) -> Details {
        if let string = value as? String {
            let trimmed = clean(string)
            guard !trimmed.isEmpty else { return Details() }
            if let parsed = parseStructuredCandidate(from: trimmed) {
                let nested = extractDetails(from: parsed)
                if nested.message != nil || nested.code != nil || nested.type != nil {
                    return nested
                }
            }
            return Details(message: trimmed)
        }

        guard let dict = value as? [String: Any] else {
            return Details()
        }

        let nestedError = dict["error"].map { extractDetails(from: $0) } ?? Details()
        let nestedDetails = dict["details"].map { extractDetails(from: $0) } ?? Details()
        let nestedCause = dict["cause"].map { extractDetails(from: $0) } ?? Details()

        return Details(
            message: firstNonEmpty([
                (dict["message"] as? String).map(clean),
                (dict["errorMessage"] as? String).map(clean),
                nestedError.message,
                nestedDetails.message,
                nestedCause.message,
            ]),
            code: firstNonEmpty([
                (dict["code"] as? String).map(clean),
                nestedError.code,
                nestedDetails.code,
                nestedCause.code,
            ]),
            type: firstNonEmpty([
                (dict["type"] as? String).map(clean),
                nestedError.type,
                nestedDetails.type,
                nestedCause.type,
            ])
        )
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { $0 }.first { !$0.isEmpty }
    }

    private static func normalizedKnownPlainMessage(_ message: String) -> String? {
        let lower = message.lowercased()
        if lower.contains("request_too_large") ||
            lower.contains("context_length_exceeded") ||
            lower.contains("maximum context length") ||
            lower.contains("maximum request size") ||
            lower.contains("prompt is too long") {
            return "Request too large. Start a new session or reduce the message size and try again."
        }
        return nil
    }

    private static func knownCodeOnlyMessage(for details: Details) -> String? {
        let combined = [details.code, details.type]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        guard !combined.isEmpty else { return nil }

        if combined.contains("request_too_large") || combined.contains("context_length_exceeded") {
            return "Request too large. Start a new session or reduce the message size and try again."
        }

        if combined.contains("server_is_overloaded") || combined.contains("service_unavailable_error") {
            return "Servers are currently overloaded. Please try again later."
        }

        if combined.contains("rate_limit") {
            return "Rate limit reached. Please try again in a moment."
        }

        if combined.contains("insufficient_quota") {
            return "Quota exceeded. Check your provider billing or plan and try again."
        }

        if combined.contains("invalid_api_key") || combined.contains("authentication_error") {
            return "Authentication failed. Check the provider login or API key and try again."
        }

        return nil
    }

    private static func looksStructured(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") ||
            trimmed.hasPrefix("[") ||
            trimmed.range(of: #"\"(?:error|message|code|type)\"\s*:"#, options: .regularExpression) != nil
    }
}
