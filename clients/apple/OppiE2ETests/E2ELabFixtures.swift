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

struct E2ELabGitWorktreeFixture {
    let hostMount: String
    let worktreePath: String
    let branchName: String
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

    /// Returns the E2E workspace id for the named workspace created by the harness.
    func e2eWorkspaceId(named name: String = "e2e-workspace") throws -> String {
        let response = try e2eLabAPIJSON(method: "GET", path: "/workspaces")
        let workspaces = try XCTUnwrap(response["workspaces"] as? [[String: Any]], "Workspaces response missing workspaces")
        let workspace = try XCTUnwrap(
            workspaces.first { $0["name"] as? String == name },
            "Workspace \(name) not found"
        )
        return try XCTUnwrap(workspace["id"] as? String, "Workspace \(name) missing id")
    }

    /// Returns a session snapshot from the E2E server.
    func e2eSession(sessionId: String) throws -> [String: Any] {
        let response = try e2eLabAPIJSON(method: "GET", path: "/sessions/\(sessionId)")
        return try XCTUnwrap(response["session"] as? [String: Any], "Session response missing session")
    }

    /// Creates a local Pi JSONL session fixture in the E2E server's isolated Pi sessions root.
    func createLocalPiSessionFixture(
        directoryName: String,
        cwd: String,
        name: String,
        firstMessage: String,
        userEntryId: String? = nil
    ) throws -> (path: String, piSessionId: String) {
        var body: [String: Any] = [
            "directoryName": directoryName,
            "cwd": cwd,
            "name": name,
            "firstMessage": firstMessage,
        ]
        if let userEntryId {
            body["userEntryId"] = userEntryId
        }
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/local-pi-session",
            body: body
        )
        return (
            path: try XCTUnwrap(response["path"] as? String, "Local Pi fixture response missing path"),
            piSessionId: try XCTUnwrap(response["piSessionId"] as? String, "Local Pi fixture response missing piSessionId")
        )
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

    /// Creates a git repository fixture with a real linked worktree on the E2E server.
    func createLabGitWorktreeFixture(
        directoryName: String,
        branchName: String
    ) throws -> E2ELabGitWorktreeFixture {
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/git-worktree",
            body: [
                "directoryName": directoryName,
                "branchName": branchName,
            ]
        )
        return E2ELabGitWorktreeFixture(
            hostMount: try XCTUnwrap(response["hostMount"] as? String, "Fixture response missing hostMount"),
            worktreePath: try XCTUnwrap(response["worktreePath"] as? String, "Fixture response missing worktreePath"),
            branchName: try XCTUnwrap(response["branchName"] as? String, "Fixture response missing branchName")
        )
    }

    /// Creates a workspace through the paired E2E server API.
    @discardableResult
    func createLabWorkspace(
        named name: String,
        defaultModel: String? = nil,
        hostMount: String? = nil
    ) throws -> String {
        var body: [String: Any] = [
            "name": name,
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

    /// Creates stopped session metadata without starting agent runtimes.
    ///
    /// Dense list/navigation tests use this E2E-only route to reproduce high-volume
    /// history with deterministic calendar-day placement.
    @discardableResult
    func createStoppedSessionFixtures(
        count: Int,
        workspaceId: String,
        lastActivity: Date,
        namePrefix: String
    ) throws -> [String] {
        let response = try e2eLabAPIJSON(
            method: "POST",
            path: "/e2e/ui/fixtures/stopped-sessions",
            body: [
                "workspaceId": workspaceId,
                "count": count,
                "lastActivityMs": Int(lastActivity.timeIntervalSince1970 * 1_000),
                "namePrefix": namePrefix,
            ]
        )
        return try XCTUnwrap(
            response["sessionIds"] as? [String],
            "Stopped-session fixture response missing sessionIds"
        )
    }

    func deleteStoppedSessionFixtures(sessionIds: [String], workspaceId: String) throws {
        guard !sessionIds.isEmpty else { return }
        let response = try e2eLabAPIJSON(
            method: "DELETE",
            path: "/e2e/ui/fixtures/stopped-sessions",
            body: [
                "workspaceId": workspaceId,
                "sessionIds": sessionIds,
            ]
        )
        let deletedCount = try XCTUnwrap(
            response["deletedCount"] as? Int,
            "Stopped-session cleanup response missing deletedCount"
        )
        guard deletedCount == sessionIds.count else {
            throw E2ELabAPIError.fixtureCleanupMismatch(
                expected: sessionIds.count,
                actual: deletedCount
            )
        }
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

    func clearE2EHarnessResponses(sessionId: String) throws {
        _ = try e2eLabAPIJSON(
            method: "DELETE",
            path: "/e2e/ui/sessions/\(sessionId)/responses"
        )
    }

    func e2eHarnessResponses(sessionId: String) throws -> [[String: Any]] {
        let response = try e2eLabAPIJSON(
            method: "GET",
            path: "/e2e/ui/sessions/\(sessionId)/responses"
        )
        return response["responses"] as? [[String: Any]] ?? []
    }

    func waitForE2EHarnessResponse(
        sessionId: String,
        requestId: String,
        timeout: TimeInterval = 10
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                if let response = try e2eHarnessResponses(sessionId: sessionId)
                    .first(where: { $0["id"] as? String == requestId }) {
                    return response
                }
            } catch {
                lastError = error
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        if let lastError {
            throw lastError
        }
        XCTFail("No E2E harness response recorded for \(requestId)")
        return [:]
    }

    func settleE2EUIRequest(sessionId: String, requestId: String) throws {
        try sendE2EHarnessMessage(sessionId: sessionId, [
            "type": "extension_ui_settled",
            "id": requestId,
        ])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    func e2eHarnessSubscriberCount(sessionId: String) throws -> Int {
        let response = try e2eLabAPIJSON(
            method: "GET",
            path: "/e2e/ui/sessions/\(sessionId)/subscribers"
        )
        return try XCTUnwrap(response["subscriberCount"] as? Int, "Subscriber count response missing count")
    }

    func waitForE2EHarnessSubscriberCount(
        sessionId: String,
        _ expectedCount: Int,
        timeout: TimeInterval = 5
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = -1
        while Date() < deadline {
            latest = try e2eHarnessSubscriberCount(sessionId: sessionId)
            if latest == expectedCount {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(latest, expectedCount, "Unexpected E2E subscriber count for \(sessionId)")
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

    /// Calls the paired E2E server API for binary endpoints using the harness token.
    func e2eLabAPIBytes(method: String, path: String, body: [String: Any] = [:]) throws -> (statusCode: Int, body: Data) {
        let response = try e2eLabAPIData(method: method, path: path, body: body)
        return (response.statusCode, response.body)
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
        if let baseURL = try? E2ELabServerContext.baseURL(),
           let scheme = baseURL.scheme?.lowercased() {
            return scheme == "https" ? ["https", "http"] : ["http", "https"]
        }
        let preferred = E2ELabServerContext.environmentValue(for: ["E2E_SCHEME", "SIMCTL_CHILD_E2E_SCHEME"])?
            .lowercased()
        if preferred == "http" { return ["http", "https"] }
        if preferred == "https" { return ["https", "http"] }
        return ["http", "https"]
    }

    private func e2eLabURL(path: String, scheme: String) throws -> URL {
        let baseURL = try? E2ELabServerContext.baseURL()
        let port = baseURL?.port
            ?? Int(E2ELabServerContext.environmentValue(for: ["E2E_PORT", "SIMCTL_CHILD_E2E_PORT"]) ?? "17760")
            ?? 17760
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        var components = URLComponents()
        components.scheme = scheme
        components.host = "127.0.0.1"
        components.port = port
        if let queryStart = normalizedPath.firstIndex(of: "?") {
            components.path = String(normalizedPath[..<queryStart])
            components.percentEncodedQuery = String(normalizedPath[normalizedPath.index(after: queryStart)...])
        } else {
            components.path = normalizedPath
        }
        return try XCTUnwrap(components.url, "Invalid E2E URL for \(path)")
    }

    private func e2eLabDeviceToken() throws -> String {
        if let token = Self.e2eDeviceTokenCache, !token.isEmpty {
            return token
        }

        if let token = E2ELabServerContext.environmentValue(for: [
            "OPPI_E2E_DEVICE_TOKEN",
            "SIMCTL_CHILD_OPPI_E2E_DEVICE_TOKEN",
        ]) {
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

private enum E2ELabServerContext {
    static func baseURL() throws -> URL {
        let inviteURLString = try inviteURLString()
        guard let url = URL(string: inviteURLString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let inviteValue = components.queryItems?.first(where: { $0.name == "invite" })?.value,
              let envelopeData = Data(e2eBase64URLEncoded: inviteValue),
              let envelope = try JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
              let signedPayloadValue = envelope["signedPayload"] as? String,
              let payloadData = Data(e2eBase64URLEncoded: signedPayloadValue),
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let scheme = payload["scheme"] as? String,
              let host = payload["host"] as? String,
              let port = payload["port"] as? Int else {
            throw E2ELabAPIError.invalidInvite
        }

        var baseComponents = URLComponents()
        baseComponents.scheme = scheme
        baseComponents.host = host
        baseComponents.port = port
        guard let baseURL = baseComponents.url else {
            throw E2ELabAPIError.invalidInvite
        }
        return baseURL
    }

    static func environmentValue(for keys: [String]) -> String? {
        for key in keys {
            if let value = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func inviteURLString() throws -> String {
        if let url = environmentValue(for: ["PI_E2E_INVITE_URL", "SIMCTL_CHILD_PI_E2E_INVITE_URL"]) {
            return url
        }

        let path = "/tmp/oppi-e2e-invite.txt"
        let url = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            throw E2ELabAPIError.invalidInvite
        }
        return url
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
    case invalidInvite
    case missingHTTPResponse
    case httpStatus(Int, String)
    case timeout(String)
    case fixtureCleanupMismatch(expected: Int, actual: Int)

    var description: String {
        switch self {
        case .invalidInvite:
            return "E2E invite URL did not contain a valid signed payload"
        case .missingHTTPResponse:
            return "Missing HTTP response"
        case .httpStatus(let status, let body):
            return "HTTP \(status): \(body)"
        case .timeout(let path):
            return "Timed out waiting for \(path)"
        case .fixtureCleanupMismatch(let expected, let actual):
            return "Fixture cleanup deleted \(actual) of \(expected) stopped sessions"
        }
    }
}

private extension Data {
    init?(e2eBase64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: padding))
        }
        self.init(base64Encoded: base64)
    }
}
