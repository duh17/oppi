import Foundation
import XCTest

/// Workspace fixture for paired-server screenshot and layout labs.
///
/// Keep these fixtures small: they run against the real E2E server and should
/// make the product state visible without turning screenshots into endurance
/// tests.
struct E2ELabWorkspaceFixture {
    let name: String
    let activeSessionCount: Int
    let stoppedSessionCount: Int

    init(
        _ name: String,
        activeSessionCount: Int = 0,
        stoppedSessionCount: Int = 0
    ) {
        self.name = name
        self.activeSessionCount = activeSessionCount
        self.stoppedSessionCount = stoppedSessionCount
    }
}

struct E2ELabWorkspaceFileFixture {
    let hostMount: String
    let filePath: String
    let filename: String
}

extension E2ETestCase {
    /// Seeds a set of real server workspaces and optional active/stopped sessions.
    func seedLabWorkspaces(_ fixtures: [E2ELabWorkspaceFixture]) throws {
        for fixture in fixtures {
            let workspaceId = try createLabWorkspace(named: fixture.name)
            try createLabSessions(count: fixture.activeSessionCount, workspaceId: workspaceId, stopAfterCreate: false)
            try createLabSessions(count: fixture.stoppedSessionCount, workspaceId: workspaceId, stopAfterCreate: true)
        }
    }

    /// Creates a file fixture on the E2E server and returns a host mount path
    /// that can be attached to a workspace.
    func createLabWorkspaceFileFixture(
        directoryName: String,
        filename: String,
        base64: String
    ) throws -> E2ELabWorkspaceFileFixture {
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/workspace-file",
            body: [
                "directoryName": directoryName,
                "filename": filename,
                "base64": base64,
            ]
        )
        return E2ELabWorkspaceFileFixture(
            hostMount: try XCTUnwrap(response["hostMount"] as? String, "Fixture response missing hostMount"),
            filePath: try XCTUnwrap(response["filePath"] as? String, "Fixture response missing filePath"),
            filename: try XCTUnwrap(response["filename"] as? String, "Fixture response missing filename")
        )
    }

    /// Creates a workspace through the paired E2E server API.
    @discardableResult
    func createLabWorkspace(
        named name: String,
        skills: [String] = [],
        defaultModel: String? = nil,
        hostMount: String? = nil
    ) throws -> String {
        var body: [String: Any] = [
            "name": name,
            "skills": skills,
        ]
        if let defaultModel {
            body["defaultModel"] = defaultModel
        }
        if let hostMount {
            body["hostMount"] = hostMount
        }

        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/workspaces",
            body: body
        )
        let workspace = try XCTUnwrap(response["workspace"] as? [String: Any], "Workspace create response missing workspace")
        return try XCTUnwrap(workspace["id"] as? String, "Workspace create response missing id")
    }

    /// Creates sessions in a workspace, optionally stopping them immediately.
    @discardableResult
    func createLabSessions(count: Int, workspaceId: String, stopAfterCreate: Bool) throws -> [String] {
        guard count > 0 else { return [] }

        var sessionIds: [String] = []
        for index in 0..<count {
            let response = try e2eLabAPIJSON(
                method: "POST",
                path: "/workspaces/\(workspaceId)/sessions",
                body: ["name": "Screenshot Lab Session \(index + 1)"]
            )
            let session = try XCTUnwrap(response["session"] as? [String: Any], "Session create response missing session")
            let sessionId = try XCTUnwrap(session["id"] as? String, "Session create response missing id")
            sessionIds.append(sessionId)

            if stopAfterCreate {
                _ = try e2eLabAPIJSON(
                    method: "POST",
                    path: "/workspaces/\(workspaceId)/sessions/\(sessionId)/stop",
                    body: [:]
                )
            }
        }
        return sessionIds
    }

    /// Sends a synthetic session message through the paired E2E UI harness.
    @discardableResult
    func sendE2EHarnessMessage(sessionId: String, _ message: [String: Any]) throws -> [String: Any] {
        try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/sessions/\(sessionId)/message",
            body: message
        )
    }

    /// Calls the paired E2E server API using the harness token.
    func e2eLabAPIJSON(method: String, path: String, body: [String: Any] = [:]) throws -> [String: Any] {
        let response = try e2eLabAPIData(method: method, path: path, body: body)
        guard (200..<300).contains(response.statusCode) else {
            throw E2ELabAPIError.httpStatus(response.statusCode, response.bodyText)
        }
        guard !response.body.isEmpty else { return [:] }

        let object = try JSONSerialization.jsonObject(with: response.body)
        return object as? [String: Any] ?? [:]
    }

    /// Saves a full-device screenshot to `/tmp/oppi-screenshots` and attaches it
    /// to the XCTest result bundle.
    @discardableResult
    func saveLabScreenshot(name: String) throws -> URL {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let directory = URL(fileURLWithPath: "/tmp/oppi-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent("\(name).png")
        try screenshot.pngRepresentation.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private func e2eLabAPIData(method: String, path: String, body: [String: Any] = [:]) throws -> E2ELabHTTPResponse {
        var lastError: Error?
        for scheme in e2eLabSchemes() {
            do {
                return try e2eLabAPIData(method: method, path: path, body: body, scheme: scheme)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? E2ELabAPIError.missingHTTPResponse
    }

    private func e2eLabAPIData(
        method: String,
        path: String,
        body: [String: Any],
        scheme: String
    ) throws -> E2ELabHTTPResponse {
        let url = try e2eLabURL(path: path, scheme: scheme)
        let token = try e2eLabDeviceToken()
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if method != "GET" || !body.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = E2ELabHTTPResultBox()
        let session: URLSession
        if scheme == "https" {
            session = URLSession(configuration: .ephemeral, delegate: E2ELabHTTPSDelegate(), delegateQueue: nil)
        } else {
            session = .shared
        }
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                resultBox.set(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                resultBox.set(.failure(E2ELabAPIError.missingHTTPResponse))
                return
            }

            resultBox.set(.success(E2ELabHTTPResponse(statusCode: httpResponse.statusCode, body: data ?? Data())))
        }.resume()

        guard semaphore.wait(timeout: .now() + 30) == .success else {
            if scheme == "https" { session.invalidateAndCancel() }
            throw E2ELabAPIError.timeout(path)
        }
        if scheme == "https" { session.finishTasksAndInvalidate() }
        return try XCTUnwrap(resultBox.result, "API request did not complete").get()
    }

    private func e2eLabSchemes() -> [String] {
        let preferred = ProcessInfo.processInfo.environment["E2E_SCHEME"]?.lowercased()
        if preferred == "http" { return ["http", "https"] }
        if preferred == "https" { return ["https", "http"] }
        return ["http", "https"]
    }

    private func e2eLabURL(path: String, scheme: String) throws -> URL {
        let port = ProcessInfo.processInfo.environment["E2E_PORT"] ?? "17760"
        var components = URLComponents()
        components.scheme = scheme
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        return try XCTUnwrap(components.url, "Invalid E2E URL for \(path)")
    }

    private func e2eLabDeviceToken() throws -> String {
        if let token = Self.e2eDeviceTokenCache, !token.isEmpty {
            return token
        }

        if let token = ProcessInfo.processInfo.environment["OPPI_E2E_DEVICE_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty {
            Self.e2eDeviceTokenCache = token
            return token
        }

        let path = "/tmp/oppi-e2e-device-token.txt"
        let token = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedToken = try XCTUnwrap(token.isEmpty ? nil : token, "E2E device token file is empty")
        Self.e2eDeviceTokenCache = resolvedToken
        return resolvedToken
    }
}

private final class E2ELabHTTPSDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

private struct E2ELabHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data

    var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

private final class E2ELabHTTPResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: Result<E2ELabHTTPResponse, Error>?

    var result: Result<E2ELabHTTPResponse, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    func set(_ result: Result<E2ELabHTTPResponse, Error>) {
        lock.lock()
        defer { lock.unlock() }
        storedResult = result
    }
}

private enum E2ELabAPIError: Error, CustomStringConvertible {
    case missingHTTPResponse
    case httpStatus(Int, String)
    case timeout(String)

    var description: String {
        switch self {
        case .missingHTTPResponse:
            return "Missing HTTP response"
        case .httpStatus(let status, let body):
            return "HTTP \(status): \(body)"
        case .timeout(let path):
            return "Timed out waiting for \(path)"
        }
    }
}
